import AppKit
import Combine
import AVFoundation

class WallpaperController: ObservableObject {
    @Published private(set) var isActive: Bool = false

    private struct ScreenEntry {
        var window: WallpaperWindow
        var playerView: VideoPlayerView
        var screen: NSScreen
    }

    /// Keyed by stable display ID: NSScreen instances are not stable across
    /// sleep/resolution changes, display IDs are.
    private var wallpaperWindows: [UInt32: ScreenEntry] = [:]
    private var store: WallpaperStore
    private var screenObserver: Any?
    private var sleepObserver: Any?
    private var wakeObserver: Any?
    private var sessionResignObserver: Any?
    private var sessionBecomeActiveObserver: Any?
    private var dayChangeObserver: Any?
    private var distributedObservers: [Any] = []
    private var cycleTimer: Timer?
    /// True while the saver runs, the session is inactive, or the machine sleeps.
    /// Switches landing in this state stay paused instead of auto-playing.
    private var isObscured = false
    private var lastUnlockEvent = Date.distantPast
    /// Latest follow-up wins; previous in-flight follow-up is cancelled.
    private var switchTask: Task<Void, Never>?
    /// Main-thread epoch: incremented on every setWallpaper/clearWallpaper so a
    /// superseded follow-up Task can tell it lost (Tasks are structs, no identity).
    private var switchEpoch = 0
    /// Item whose video decode was deferred because the switch landed while
    /// obscured (lock/saver/sleep). Loaded on the next becoming-visible.
    private var pendingObscuredItem: WallpaperItem?
    /// Collapses re-entrant scheduleCycle calls (setWallpaper chains) to one arm.
    private var isSchedulingCycle = false

    /// Terse transition log for Console.app storm/freeze diagnosis. LSUIElement
    /// apps lose stdout, so NSLog (not print) is required.
    private func cycleLog(_ message: String) {
        NSLog("[HazelCycle] %@", message)
    }

    init(store: WallpaperStore) {
        self.store = store
        setupNotifications()
        scheduleCycle()
    }

    deinit {
        removeNotifications()
        cycleTimer?.invalidate()
        cycleTimer = nil
        for (_, entry) in wallpaperWindows {
            entry.playerView.cleanup()
            entry.window.close()
        }
        wallpaperWindows.removeAll()
        switchTask?.cancel()
    }

    private func displayID(for screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    private func setupNotifications() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleScreenChange()
        }

        let workspace = NSWorkspace.shared
        let notificationCenter = workspace.notificationCenter

        sleepObserver = notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.isObscured = true
            self.cycleLog("sleep; timer invalidated")
            self.cycleTimer?.invalidate()
            self.cycleTimer = nil
            self.pauseAll()
        }

        wakeObserver = notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleWake()
        }

        sessionResignObserver = notificationCenter.addObserver(
            forName: NSWorkspace.sessionDidResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleSessionResign()
        }

        sessionBecomeActiveObserver = notificationCenter.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleSessionBecomeActive()
        }

        dayChangeObserver = NotificationCenter.default.addObserver(
            forName: .NSCalendarDayChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleCycle()
        }

        let distributed = DistributedNotificationCenter.default()
        for name in [NSNotification.Name("com.apple.screensaver.didstart"), NSNotification.Name("com.apple.screensaver.willstart"),
                    NSNotification.Name("com.apple.screenIsLocked")] {
            let observer = distributed.addObserver(forName: name, object: nil, queue: .main, using: { [weak self] _ in
                self?.handleScreensaverStart()
            })
            distributedObservers.append(observer)
        }
        for name in [NSNotification.Name("com.apple.screensaver.didstop"), NSNotification.Name("com.apple.screensaver.willstop"),
                    NSNotification.Name("com.apple.screenIsUnlocked")] {
            let observer = distributed.addObserver(forName: name, object: nil, queue: .main, using: { [weak self] _ in
                self?.handleScreensaverStop()
            })
            distributedObservers.append(observer)
        }
    }

    private func handleScreensaverStart() {
        cycleLog("obscured saver-start; paused")
        isObscured = true
        pauseAll()
    }

    /// Loads a switch that landed while obscured, now that pixels are visible.
    /// Drops the pending item when a newer switch already superseded it.
    private func flushPendingObscuredLoad() {
        guard !isObscured, isActive else { return }
        guard let pending = pendingObscuredItem else { return }
        guard pending.id == store.activeWallpaperID else {
            pendingObscuredItem = nil
            cycleLog("obscured-load dropped superseded=\(pending.title)")
            return
        }
        pendingObscuredItem = nil
        guard let url = store.validatedURL(pending.url) else { return }
        cycleLog("obscured-load flush title=\(pending.title)")
        for (_, entry) in wallpaperWindows {
            entry.playerView.loadVideo(url: url, isLooping: pending.isLooping, isMuted: pending.isMuted)
        }
        if SettingsManager.shared.syncSystemWallpaper {
            DesktopPictureService.shared.syncCurrentVideo(video: url, wallpaperID: pending.id)
        }
    }

    /// Saver-stop, session-active and wake all converge here; coalesced so one
    /// unlock advances at most once.
    private func handleUnlockEvent() {
        let now = Date()
        guard now.timeIntervalSince(lastUnlockEvent) > 2 else { return }
        lastUnlockEvent = now
        handleUnlockAdvance()
    }

    private func handleScreensaverStop() {
        cycleLog("visible saver-stop")
        isObscured = false
        flushPendingObscuredLoad()
        resumeIfNeeded()
        handleUnlockEvent()
    }

    private func handleSessionResign() {
        cycleLog("obscured session-resign; paused")
        isObscured = true
        pauseAll()
    }

    private func handleSessionBecomeActive() {
        cycleLog("visible session-active")
        isObscured = false
        flushPendingObscuredLoad()
        resumeIfNeeded()
        handleUnlockEvent()
    }

    private func handleWake() {
        // Catch up while still obscured so a resulting switch stays silent;
        // only then mark visible and resume. Re-arm the timer dropped on sleep.
        handleWakeCatchUp()
        cycleLog("visible wake")
        isObscured = false
        flushPendingObscuredLoad()
        resumeIfNeeded()
        let mode = SettingsManager.shared.cycleMode
        if cycleTimer == nil && (mode == .interval || mode == .daily) {
            scheduleCycle()
        }
        handleUnlockEvent()
    }

    private func removeNotifications() {
        if let observer = screenObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        screenObserver = nil
        if let observer = dayChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        dayChangeObserver = nil
        if let observer = sleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        sleepObserver = nil
        if let observer = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        wakeObserver = nil
        if let observer = sessionResignObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        sessionResignObserver = nil
        if let observer = sessionBecomeActiveObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        sessionBecomeActiveObserver = nil
        for observer in distributedObservers {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        distributedObservers.removeAll()
    }

    private func handleScreenChange() {
        var current: [UInt32: NSScreen] = [:]
        for screen in NSScreen.screens {
            if let id = displayID(for: screen) {
                current[id] = screen
            }
        }

        for id in Set(wallpaperWindows.keys).subtracting(Set(current.keys)) {
            if let entry = wallpaperWindows.removeValue(forKey: id) {
                entry.playerView.cleanup()
                entry.window.close()
            }
        }

        for (id, screen) in current where wallpaperWindows[id] == nil {
            createWallpaperWindow(for: screen, id: id)
        }

        for (id, screen) in current {
            if var entry = wallpaperWindows[id] {
                entry.screen = screen
                entry.window.setFrame(screen.frame, display: true)
                wallpaperWindows[id] = entry
            }
        }

        DesktopPictureService.shared.reconcile()
        // resumeIfNeeded is obscured-guarded: a display change behind the
        // lockscreen must never unpause video.
        resumeIfNeeded()
    }

    private func createWallpaperWindow(for screen: NSScreen, id: UInt32) {
        let window = WallpaperWindow(screen: screen)
        let playerView = VideoPlayerView(frame: screen.frame)

        window.contentView = playerView
        window.orderFront(nil)

        NSLog("[HazelCycle] window created screen=%@ visible=%@", screen.localizedName, window.isVisible ? "yes" : "no")

        wallpaperWindows[id] = ScreenEntry(window: window, playerView: playerView, screen: screen)
    }

    func setWallpaper(_ item: WallpaperItem) {
        isActive = true
        store.setActiveWallpaper(item)

        for screen in NSScreen.screens {
            if let id = displayID(for: screen), wallpaperWindows[id] == nil {
                createWallpaperWindow(for: screen, id: id)
            }
        }

        guard let activeItem = store.activeWallpaper,
              let url = store.validatedURL(activeItem.url) else {
            cycleLog("switch aborted; bookmark unresolvable")
            return
        }

        if isObscured {
            // Silent switch: no decode/play behind lock/saver/sleep. The video
            // loads on the next becoming-visible (flushPendingObscuredLoad);
            // pointer + follow-up below still run so state never goes stale.
            pendingObscuredItem = activeItem
            cycleLog("switch deferred title=\(activeItem.title) (obscured)")
            pauseAll()
        } else {
            pendingObscuredItem = nil
            for (_, entry) in wallpaperWindows {
                entry.playerView.loadVideo(url: url, isLooping: activeItem.isLooping, isMuted: activeItem.isMuted)
            }
        }

        DesktopPictureService.shared.writeCurrentPointer(
            video: url, wallpaperID: activeItem.id,
            isLooping: activeItem.isLooping, isMuted: activeItem.isMuted
        )
        if SettingsManager.shared.syncSystemWallpaper, !isObscured {
            DesktopPictureService.shared.syncCurrentVideo(video: url, wallpaperID: activeItem.id)
        }
        // Single in-flight follow-up: superseded Tasks exit at the first
        // cancellation check, so rapid switches never stack agent restarts.
        // Overlap with the watchdog/unlock paths is serialized inside the
        // services (reselect slot + automatic slot).
        switchTask?.cancel()
        switchEpoch &+= 1
        let epoch = switchEpoch
        let stagedID = activeItem.id
        let stagedTitle = activeItem.title
        let stagedURL = url
        cycleLog("switch title=\(stagedTitle)")
        switchTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            await ScreensaverSelectService.shared.followSwitch()
            guard !Task.isCancelled else { return }
            await HazelLockScreenService.shared.ensureAutomatic(video: stagedURL, wallpaperID: stagedID, title: stagedTitle)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, self.switchEpoch == epoch else { return }
                self.cycleLog("follow-up done title=\(stagedTitle)")
                self.switchTask = nil
            }
        }
        if SettingsManager.shared.cycleMode == .interval || SettingsManager.shared.cycleMode == .daily {
            SettingsManager.shared.lastCycleDate = Date()
            scheduleCycle()
        }
    }

    func clearWallpaper() {
        cycleLog("clear; timer cancelled")
        isActive = false
        cycleTimer?.invalidate()
        cycleTimer = nil
        switchEpoch &+= 1
        switchTask?.cancel()
        switchTask = nil
        pendingObscuredItem = nil

        for (_, entry) in wallpaperWindows {
            entry.playerView.cleanup()
            entry.window.close()
        }
        wallpaperWindows.removeAll()
    }

    func pauseAll() {
        for (_, entry) in wallpaperWindows {
            entry.playerView.pause()
        }
    }

    func resumeIfNeeded() {
        guard isActive, !isObscured else { return }

        for (_, entry) in wallpaperWindows {
            entry.playerView.play()
        }
    }

    func reloadCurrentWallpaper() {
        guard let activeItem = store.activeWallpaper,
              let url = store.validatedURL(activeItem.url) else { return }

        if isObscured {
            // Same silent-switch rule as setWallpaper: defer decode until visible.
            pendingObscuredItem = activeItem
            cycleLog("reload deferred (obscured)")
            pauseAll()
            return
        }
        pendingObscuredItem = nil
        for (_, entry) in wallpaperWindows {
            entry.playerView.loadVideo(url: url, isLooping: activeItem.isLooping, isMuted: activeItem.isMuted)
        }
    }

    // MARK: - System wallpaper sync

    func setSyncEnabled(_ enabled: Bool) {
        SettingsManager.shared.syncSystemWallpaper = enabled
        if enabled {
            if let activeItem = store.activeWallpaper,
               let url = store.validatedURL(activeItem.url) {
                DesktopPictureService.shared.syncCurrentVideo(video: url, wallpaperID: activeItem.id)
            }
            DesktopPictureService.shared.reconcile()
        } else {
            DesktopPictureService.shared.restoreAll()
        }
    }

    // MARK: - Cycle

    func setCycleMode(_ mode: CycleMode) {
        cycleLog("mode \(SettingsManager.shared.cycleMode.rawValue)->\(mode.rawValue)")
        SettingsManager.shared.cycleMode = mode
        SettingsManager.shared.lastCycleDate = mode == .none ? nil : Date()
        scheduleCycle()
    }

    func scheduleCycle() {
        // Re-entrant calls (setWallpaper -> scheduleCycle chains, day-change
        // racing a timer fire) collapse: invalidate-first means one arm max.
        guard !isSchedulingCycle else { return }
        isSchedulingCycle = true
        defer { isSchedulingCycle = false }
        cycleTimer?.invalidate()
        cycleTimer = nil
        let mode = SettingsManager.shared.cycleMode
        switch mode {
        case .none, .onUnlock:
            cycleLog("timer cleared mode=\(mode.rawValue)")
            break
        case .interval:
            let minutes = max(1, SettingsManager.shared.cycleIntervalMinutes)
            if SettingsManager.shared.lastCycleDate == nil {
                SettingsManager.shared.lastCycleDate = Date()
            }
            let timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(minutes * 60), repeats: true) { [weak self] _ in
                self?.fireCycleTimer()
            }
            timer.tolerance = min(60, TimeInterval(minutes * 60) * 0.05)
            RunLoop.main.add(timer, forMode: .common)
            cycleTimer = timer
            cycleLog("timer armed interval=\(minutes)m")
        case .daily:
            if let fireDate = nextDailyFireDate() {
                // One-shot armed for the next fire; fireCycleTimer re-arms the
                // following day, so DST shifts and sleep gaps self-correct.
                let delay = max(60, fireDate.timeIntervalSinceNow)
                let timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                    self?.fireCycleTimer()
                }
                timer.tolerance = 60
                RunLoop.main.add(timer, forMode: .common)
                cycleTimer = timer
                cycleLog("timer armed daily=\(fireDate)")
            } else {
                cycleLog("timer daily skipped; no fire date")
            }
        }
        NotificationCenter.default.post(name: .hazelCycleSettingsChanged, object: nil)
    }

    private func nextDailyFireDate() -> Date? {
        var calendar = Calendar.current
        calendar.timeZone = TimeZone.current
        let now = Date()
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = SettingsManager.shared.cycleDailyHour
        components.minute = SettingsManager.shared.cycleDailyMinute
        components.second = 0
        if let today = calendar.date(from: components) {
            if today > now {
                return today
            }
            return calendar.date(byAdding: .day, value: 1, to: today)
        }
        // DST gap: fall back to the next matching wall-clock time.
        var matching = DateComponents()
        matching.hour = SettingsManager.shared.cycleDailyHour
        matching.minute = SettingsManager.shared.cycleDailyMinute
        return calendar.nextDate(after: now, matching: matching, matchingPolicy: .nextTime)
    }

    private func fireCycleTimer() {
        guard isActive, !isObscured else {
            cycleLog("timer fire dropped active=\(isActive) obscured=\(isObscured)")
            return
        }
        cycleLog("timer fire mode=\(SettingsManager.shared.cycleMode.rawValue)")
        advanceToNextWallpaper()
        SettingsManager.shared.lastCycleDate = Date()
        if SettingsManager.shared.cycleMode == .daily {
            scheduleCycle()
        }
    }

    private func handleUnlockAdvance() {
        guard SettingsManager.shared.cycleMode == .onUnlock else { return }
        guard store.wallpapers.count > 1 else { return }
        cycleLog("unlock advance")
        advanceToNextWallpaper()
    }

    private func handleWakeCatchUp() {
        let mode = SettingsManager.shared.cycleMode
        guard store.wallpapers.count > 1 else { return }
        if mode == .interval {
            let minutes = max(1, SettingsManager.shared.cycleIntervalMinutes)
            guard let last = SettingsManager.shared.lastCycleDate else {
                SettingsManager.shared.lastCycleDate = Date()
                return
            }
            if Date().timeIntervalSince(last) >= TimeInterval(minutes * 60) {
                cycleLog("wake catch-up interval; advancing once")
                advanceToNextWallpaper()
                SettingsManager.shared.lastCycleDate = Date()
                scheduleCycle()
            }
        } else if mode == .daily {
            if let fire = nextDailyFireDate() {
                let lastFire = fire.addingTimeInterval(-24 * 60 * 60)
                if let last = SettingsManager.shared.lastCycleDate, last < lastFire {
                    cycleLog("wake catch-up daily; advancing once")
                    advanceToNextWallpaper()
                    SettingsManager.shared.lastCycleDate = Date()
                }
            }
            scheduleCycle()
        }
    }

    func advanceToNextWallpaper() {
        guard isActive else { return }
        guard store.wallpapers.count > 1 else { return }
        guard let currentID = store.activeWallpaperID,
              let index = store.wallpapers.firstIndex(where: { $0.id == currentID }) else {
            if let first = store.wallpapers.first {
                setWallpaper(first)
            }
            return
        }
        let next = store.wallpapers[(index + 1) % store.wallpapers.count]
        setWallpaper(next)
    }
}
