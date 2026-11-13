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
            self?.isObscured = true
            self?.pauseAll()
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
        isObscured = true
        pauseAll()
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
        isObscured = false
        resumeIfNeeded()
        handleUnlockEvent()
    }

    private func handleSessionResign() {
        isObscured = true
        pauseAll()
    }

    private func handleSessionBecomeActive() {
        isObscured = false
        resumeIfNeeded()
        handleUnlockEvent()
    }

    private func handleWake() {
        isObscured = false
        resumeIfNeeded()
        handleWakeCatchUp()
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
        resumeIfNeeded()
    }

    private func createWallpaperWindow(for screen: NSScreen, id: UInt32) {
        let window = WallpaperWindow(screen: screen)
        let playerView = VideoPlayerView(frame: screen.frame)

        window.contentView = playerView
        window.orderFront(nil)

        print("Wallpaper window created for screen: \(screen.localizedName), visible: \(window.isVisible)")

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
            print("Failed to resolve bookmark URL")
            return
        }

        for (_, entry) in wallpaperWindows {
            entry.playerView.loadVideo(url: url, isLooping: activeItem.isLooping, isMuted: activeItem.isMuted)
        }
        if isObscured {
            pauseAll()
        }

        DesktopPictureService.shared.writeCurrentPointer(
            video: url, wallpaperID: activeItem.id,
            isLooping: activeItem.isLooping, isMuted: activeItem.isMuted
        )
        if SettingsManager.shared.syncSystemWallpaper {
            DesktopPictureService.shared.syncCurrentVideo(video: url, wallpaperID: activeItem.id)
        }
        switchTask?.cancel()
        let stagedID = activeItem.id
        let stagedTitle = activeItem.title
        let stagedURL = url
        switchTask = Task {
            await ScreensaverSelectService.shared.followSwitch()
            await HazelLockScreenService.shared.ensureAutomatic(video: stagedURL, wallpaperID: stagedID, title: stagedTitle)
        }
        if SettingsManager.shared.cycleMode == .interval || SettingsManager.shared.cycleMode == .daily {
            SettingsManager.shared.lastCycleDate = Date()
            scheduleCycle()
        }
    }

    func clearWallpaper() {
        isActive = false
        cycleTimer?.invalidate()
        cycleTimer = nil
        switchTask?.cancel()
        switchTask = nil

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
        guard isActive else { return }

        for (_, entry) in wallpaperWindows {
            entry.playerView.play()
        }
    }

    func reloadCurrentWallpaper() {
        guard let activeItem = store.activeWallpaper,
              let url = store.validatedURL(activeItem.url) else { return }

        for (_, entry) in wallpaperWindows {
            entry.playerView.loadVideo(url: url, isLooping: activeItem.isLooping, isMuted: activeItem.isMuted)
        }
        if isObscured {
            pauseAll()
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
        SettingsManager.shared.cycleMode = mode
        SettingsManager.shared.lastCycleDate = mode == .none ? nil : Date()
        scheduleCycle()
    }

    func scheduleCycle() {
        cycleTimer?.invalidate()
        cycleTimer = nil
        let mode = SettingsManager.shared.cycleMode
        switch mode {
        case .none, .onUnlock:
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
        guard isActive, !isObscured else { return }
        advanceToNextWallpaper()
        SettingsManager.shared.lastCycleDate = Date()
        if SettingsManager.shared.cycleMode == .daily {
            scheduleCycle()
        }
    }

    private func handleUnlockAdvance() {
        guard SettingsManager.shared.cycleMode == .onUnlock else { return }
        guard store.wallpapers.count > 1 else { return }
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
                advanceToNextWallpaper()
                SettingsManager.shared.lastCycleDate = Date()
                scheduleCycle()
            }
        } else if mode == .daily {
            if let fire = nextDailyFireDate() {
                let lastFire = fire.addingTimeInterval(-24 * 60 * 60)
                if let last = SettingsManager.shared.lastCycleDate, last < lastFire {
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
