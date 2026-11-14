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
    private var appBecomeActiveObserver: Any?
    private var dayChangeObserver: Any?
    private var distributedObservers: [Any] = []
    private var cycleTimer: Timer?
    /// One-shot decode warmer armed shortly before the next cycle fire so the
    /// swap at fire time lands on hot caches (page cache + still file) instead
    /// of paying a cold decode after the timer. Best-effort: firing late or
    /// not at all only loses the warmup, never the cycle itself.
    private var cyclePrewarmTimer: Timer?
    /// Independent obscured reasons. A single Bool clobbered across channels:
    /// a stale saver-stop arriving after a lock (session resign) cleared the
    /// flag while the session was still locked, or vice versa, leaving video
    /// paused forever (the rare lock-screen freeze). Per-channel flags make
    /// cross-channel reordering harmless; visible only when ALL are clear.
    private var sleepObscured = false
    private var sessionObscured = false
    private var saverObscured = false
    private var isObscured: Bool { sleepObscured || sessionObscured || saverObscured }
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
    /// Test seams (additive, no behavior change).
    internal var windowCountForTesting: Int { wallpaperWindows.count }
    internal var pendingObscuredItemForTesting: WallpaperItem? { pendingObscuredItem }
    internal var swapWaiterCountForTesting: Int {
        swapWaiterLock.withLock { swapWaiters.count }
    }
    internal var firstFrameWaiterCountForTesting: Int {
        firstFrameWaiterLock.withLock { firstFrameWaiters.count }
    }
    /// Fired once when the first video frame composites after a cold start
    /// (no video previously on screen). The app uses it to defer heavy
    /// launch work (saver reselect, lockscreen staging, sync extraction,
    /// next-video prewarm) off the first-frame critical path.
    var onFirstFrameReady: (() -> Void)?
    private var didSignalFirstFrame = false
    /// First-frame waiters for launch-deferred follow-ups. Signalled (not
    /// polled): waiters resume in signalFirstFrameIfNeeded or on the timeout
    /// hop below, never via a repeating timer.
    private final class FirstFrameWaiter {
        var continuation: CheckedContinuation<Void, Never>?
        var resumed = false
    }
    private var firstFrameWaiters: [FirstFrameWaiter] = []
    private let firstFrameWaiterLock = NSLock()

    /// Terse transition log for Console.app storm/freeze diagnosis. LSUIElement
    /// apps lose stdout, so NSLog (not print) is required.
    private func cycleLog(_ message: String) {
        NSLog("[HazelCycle] %@", message)
    }

    /// One-shot first-frame signal for launch deferral. Resumes any
    /// launch-deferred follow-up waiters before invoking the app callback.
    private func signalFirstFrameIfNeeded() {
        guard !didSignalFirstFrame else { return }
        didSignalFirstFrame = true
        let waiters: [FirstFrameWaiter] = firstFrameWaiterLock.withLock {
            let pending = firstFrameWaiters
            firstFrameWaiters.removeAll()
            for waiter in pending { waiter.resumed = true }
            return pending
        }
        for waiter in waiters { waiter.continuation?.resume() }
        let callback = onFirstFrameReady
        DispatchQueue.main.async { callback?() }
    }

    /// Suspends until the first frame composites or `timeout` elapses,
    /// whichever comes first. One-shot per call; no polling. Cancellation
    /// resumes immediately so a superseded launch wait never lingers.
    private func waitForFirstFrame(timeout: Duration = .seconds(8)) async {
        guard !didSignalFirstFrame else { return }
        let waiter = FirstFrameWaiter()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                waiter.continuation = continuation
                let alreadyDone: Bool = firstFrameWaiterLock.withLock {
                    if waiter.resumed { return true }
                    firstFrameWaiters.append(waiter)
                    return false
                }
                if alreadyDone {
                    continuation.resume()
                    return
                }
                Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    self?.resumeWaiter(waiter)
                }
            }
        } onCancel: {
            resumeWaiter(waiter)
        }
    }

    private func resumeWaiter(_ waiter: FirstFrameWaiter) {
        let continuation: CheckedContinuation<Void, Never>? = firstFrameWaiterLock.withLock {
            guard !waiter.resumed else { return nil }
            waiter.resumed = true
            if let index = firstFrameWaiters.firstIndex(where: { $0 === waiter }) {
                firstFrameWaiters.remove(at: index)
            }
            return waiter.continuation
        }
        continuation?.resume()
    }

    /// First-swap waiters for post-swap follow-up gating. Signalled (not
    /// polled): waiters resume when any window's pending pipeline promotes
    /// to live, or on the timeout hop below, never via a repeating timer.
    private final class SwapWaiter {
        var continuation: CheckedContinuation<Void, Never>?
        var resumed = false
    }
    private var swapWaiters: [SwapWaiter] = []
    private let swapWaiterLock = NSLock()

    private func resumeSwapWaiters() {
        let waiters: [SwapWaiter] = swapWaiterLock.withLock {
            let pending = swapWaiters
            swapWaiters.removeAll()
            for waiter in pending { waiter.resumed = true }
            return pending
        }
        for waiter in waiters { waiter.continuation?.resume() }
    }

    private func resumeSwapWaiter(_ waiter: SwapWaiter) {
        let continuation: CheckedContinuation<Void, Never>? = swapWaiterLock.withLock {
            guard !waiter.resumed else { return nil }
            waiter.resumed = true
            if let index = swapWaiters.firstIndex(where: { $0 === waiter }) {
                swapWaiters.remove(at: index)
            }
            return waiter.continuation
        }
        continuation?.resume()
    }

    /// Drains first-frame waiters without flipping didSignalFirstFrame.
    /// Teardown (abort/clear) uses this so a waiter never sits out its 8s
    /// timeout after the windows that could signal it are gone. Cancelled
    /// owners exit at their next guard; a newer waiter cannot exist here
    /// (teardown bumps the epoch and cancels first, all on main).
    private func drainFirstFrameWaiters() {
        let waiters: [FirstFrameWaiter] = firstFrameWaiterLock.withLock {
            let pending = firstFrameWaiters
            firstFrameWaiters.removeAll()
            for waiter in pending { waiter.resumed = true }
            return pending
        }
        for waiter in waiters { waiter.continuation?.resume() }
    }

    /// (Re)installs the one-shot swap hooks on every live window. Screen
    /// changes create windows outside the switch flow, after a waiter already
    /// installed its hooks: without a reinstall the new window's swap would
    /// never fire the waiter and the follow-up would sit out its timeout.
    private func installSwapHooks() {
        for (_, entry) in wallpaperWindows {
            entry.playerView.onSwapCommitted = { [weak self] in self?.resumeSwapWaiters() }
        }
    }

    private var hasSwapWaiters: Bool {
        swapWaiterLock.withLock { !swapWaiters.isEmpty }
    }

    /// Suspends until the first window swaps `url` onto the live layer (or
    /// the timeout elapses), whichever comes first. One-shot per call; no
    /// polling. Cancellation resumes immediately so a superseded switch
    /// never lingers. Already-live (post-swap or same-video fast path)
    /// returns without suspending.
    ///
    /// Hook install + live check run as one synchronous main-thread block,
    /// so no swap can slip between them: a swap committed before the block
    /// is caught by the live check, one after by the hook.
    private func waitForFirstSwap(of url: URL, timeout: Duration = .seconds(8)) async {
        let waiter: SwapWaiter? = await MainActor.run { [weak self] in
            guard let self else { return nil as SwapWaiter? }
            let waiter = SwapWaiter()
            self.installSwapHooks()
            for (_, entry) in self.wallpaperWindows {
                if entry.playerView.currentURLValue == url {
                    // Already promoted (or the same-video fast path fired the
                    // hook before it was installed): no suspend. Installed
                    // hooks above are stale one-shots; the next switch
                    // overwrites them, and firing with no waiters is a no-op.
                    return nil as SwapWaiter?
                }
            }
            self.swapWaiterLock.withLock { self.swapWaiters.append(waiter) }
            return waiter
        }
        guard let waiter else { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                waiter.continuation = continuation
                let alreadyDone: Bool = swapWaiterLock.withLock {
                    if waiter.resumed { return true }
                    return false
                }
                if alreadyDone {
                    continuation.resume()
                    return
                }
                Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    self?.resumeSwapWaiter(waiter)
                }
            }
        } onCancel: { [weak self] in
            self?.resumeSwapWaiter(waiter)
        }
    }

    /// Validation failure path: no windows, not active, system desktop left
    /// alone, active pointer cleared so the next launch does not retry the
    /// same dead file. Callers must return immediately after.
    private func abortInvalidItem(_ item: WallpaperItem, context: String) {
        cycleLog("\(context) aborted; bookmark unresolvable title=\(item.title)")
        NSLog("[Hazel] WallpaperController: %@ validation failed, no windows created title=%@ path=%@",
              context, item.title, item.url.path)
        switchEpoch &+= 1
        switchTask?.cancel()
        switchTask = nil
        pendingObscuredItem = nil
        didSignalFirstFrame = false
        for (_, entry) in wallpaperWindows {
            entry.window.conceal()
            entry.playerView.cleanup()
            entry.window.close()
        }
        wallpaperWindows.removeAll()
        // The promotion these waiters gated on will never come from these
        // windows: release them now instead of leaving them to time out.
        // Owners were cancelled above and exit at their next guard.
        resumeSwapWaiters()
        drainFirstFrameWaiters()
        // Only clear the pointer when it still targets this dead item;
        // a concurrent switch may already have staged a newer one.
        if store.activeWallpaperID == item.id {
            store.activeWallpaperID = nil
        }
        isActive = false
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
        cyclePrewarmTimer?.invalidate()
        cyclePrewarmTimer = nil
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
            self.sleepObscured = true
            self.cycleLog("sleep; timer invalidated")
            self.cycleTimer?.invalidate()
            self.cycleTimer = nil
            self.cyclePrewarmTimer?.invalidate()
            self.cyclePrewarmTimer = nil
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

        appBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleAppBecomeActive()
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
        saverObscured = true
        pauseAll()
    }

    /// Loads a switch that landed while obscured, now that pixels are visible.
    /// Drops the pending item when a newer switch already superseded it.
    private func flushPendingObscuredLoad() {
        guard !isObscured else {
            cycleLog("obscured-load flush skipped still-obscured")
            return
        }
        guard isActive else {
            cycleLog("obscured-load flush skipped inactive; clearing pending")
            pendingObscuredItem = nil
            return
        }
        guard let pending = pendingObscuredItem else { return }
        guard pending.id == store.activeWallpaperID else {
            pendingObscuredItem = nil
            cycleLog("obscured-load dropped superseded=\(pending.title)")
            return
        }
        pendingObscuredItem = nil
        guard let url = store.validatedURL(pending.url) else {
            cycleLog("obscured-load flush validation failed title=\(pending.title)")
            abortInvalidItem(pending, context: "obscured-flush")
            return
        }
        cycleLog("obscured-load flush title=\(pending.title)")
        for (_, entry) in wallpaperWindows {
            entry.playerView.loadVideo(url: url, isLooping: pending.isLooping, isMuted: pending.isMuted)
        }
        if SettingsManager.shared.syncSystemWallpaper {
            DesktopPictureService.shared.syncCurrentVideo(video: url, wallpaperID: pending.id)
        }
        prewarmNextWallpaper()
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
        saverObscured = false
        flushPendingObscuredLoad()
        resumeIfNeeded()
        scheduleResumeVerification()
        handleUnlockEvent()
    }

    private func handleSessionResign() {
        cycleLog("obscured session-resign; paused")
        sessionObscured = true
        pauseAll()
    }

    private func handleSessionBecomeActive() {
        cycleLog("visible session-active")
        sessionObscured = false
        flushPendingObscuredLoad()
        resumeIfNeeded()
        scheduleResumeVerification()
        handleUnlockEvent()
    }

    /// App activation proves the login session is visible: the user is
    /// interacting with our menu/panel, impossible behind the lockscreen.
    /// Heals a stuck obscured flag when a distributed unlock notification
    /// was missed/delayed (the rare freeze that a menu click used to clear
    /// by side effect). Saver/sleep channels are left to their own
    /// notifications; resume stays guarded so a still-covered desktop never
    /// unpauses from this path alone.
    private func handleAppBecomeActive() {
        cycleLog("visible app-active")
        sessionObscured = false
        flushPendingObscuredLoad()
        resumeIfNeeded()
        scheduleResumeVerification()
        handleUnlockEvent()
    }

    /// Explicit user interaction (menu open, panel open) proves visible.
    /// Same healing as app-activation, callable from the menu paths even
    /// when activation is not delivered (menu tracking without key status).
    /// A menu/panel interaction is impossible behind the lockscreen, under
    /// the screensaver, or with the display asleep, so all channels clear.
    func handleUserInteractionVisible() {
        sleepObscured = false
        sessionObscured = false
        saverObscured = false
        flushPendingObscuredLoad()
        resumeIfNeeded()
        scheduleResumeVerification()
    }

    /// Re-asserts playback shortly after every becoming-visible: a single
    /// play() can land before the WindowServer/display link is ready and
    /// silently not take effect (frozen frame, rate 0). The retries are
    /// one-shot, obscured-guarded at fire time, and idempotent when already
    /// playing, so they only heal the stuck case and never disturb steady
    /// playback.
    private func scheduleResumeVerification() {
        for delay in [0.5, 2.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.isActive, !self.isObscured else { return }
                for (_, entry) in self.wallpaperWindows {
                    entry.playerView.ensurePlaying()
                }
            }
        }
    }

    private func handleWake() {
        // Catch up while still obscured so a resulting switch stays silent;
        // only then mark visible and resume. Re-arm the timer dropped on sleep.
        handleWakeCatchUp()
        cycleLog("visible wake")
        sleepObscured = false
        flushPendingObscuredLoad()
        resumeIfNeeded()
        scheduleResumeVerification()
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
        if let observer = appBecomeActiveObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        appBecomeActiveObserver = nil
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

        // Validate BEFORE creating windows for new displays: a dead file must
        // log + repair/abort instead of leaving silent transparent windows.
        if isActive {
            guard let activeItem = store.activeWallpaper else {
                cycleLog("screen-change no active item while active; clearing windows")
                for (_, entry) in wallpaperWindows {
                    entry.playerView.cleanup()
                    entry.window.close()
                }
                wallpaperWindows.removeAll()
                isActive = false
                DesktopPictureService.shared.reconcile()
                return
            }
            guard let validatedURL = store.validatedURL(activeItem.url) else {
                cycleLog("screen-change validation failed title=\(activeItem.title)")
                abortInvalidItem(activeItem, context: "screen-change")
                DesktopPictureService.shared.reconcile()
                return
            }
            for (id, screen) in current where wallpaperWindows[id] == nil {
                createWallpaperWindow(for: screen, id: id)
                // New/replugged display starts transparent: feed it the current
                // video immediately so its first frame reveals it. Without this
                // the window would sit invisible forever.
                if !isObscured, let entry = wallpaperWindows[id] {
                    entry.playerView.loadVideo(url: validatedURL, isLooping: activeItem.isLooping, isMuted: activeItem.isMuted)
                } else if isObscured, pendingObscuredItem?.id != activeItem.id {
                    // New display while obscured gets no video now (silent
                    // switch rule); park the current item so the flush on
                    // becoming visible feeds every window, including this one.
                    // (Overwrites a stale pending too: the flush would drop a
                    // pending that no longer matches the active item.)
                    pendingObscuredItem = activeItem
                    cycleLog("obscured-load parked new display title=\(activeItem.title)")
                }
            }
        } else {
            for (id, screen) in current where wallpaperWindows[id] == nil {
                createWallpaperWindow(for: screen, id: id)
            }
        }

        for (id, screen) in current {
            if var entry = wallpaperWindows[id] {
                entry.screen = screen
                entry.window.setFrame(screen.frame, display: true)
                wallpaperWindows[id] = entry
            }
        }

        DesktopPictureService.shared.reconcile()
        // Windows created above post-date any in-flight swap waiter's hook
        // install: re-install so a new window's promotion still releases the
        // follow-up instead of leaving it to time out. When every window is
        // gone there is nothing left to satisfy a waiter — release it.
        if wallpaperWindows.isEmpty {
            resumeSwapWaiters()
        } else if hasSwapWaiters {
            installSwapHooks()
        }
        // resumeIfNeeded is obscured-guarded: a display change behind the
        // lockscreen must never unpause video.
        resumeIfNeeded()
    }

    private func createWallpaperWindow(for screen: NSScreen, id: UInt32) {
        let window = WallpaperWindow(screen: screen)
        let playerView = VideoPlayerView(frame: screen.frame)

        window.contentView = playerView
        // Order front while still transparent (alpha 0): the desktop stays
        // visible underneath until the first frame reveals the window.
        // Never order an opaque black window before the async decode.
        playerView.onFirstFrameReady = { [weak self, weak window] prewarmed in
            // Prewarmed swaps land on hot caches: reveal instantly (zero
            // fade). Cold decodes keep the short fade so the cut does not pop.
            window?.reveal(animated: !prewarmed)
            self?.signalFirstFrameIfNeeded()
        }
        window.orderFront(nil)

        NSLog("[HazelCycle] window created screen=%@ visible=%@", screen.localizedName, window.isVisible ? "yes" : "no")

        wallpaperWindows[id] = ScreenEntry(window: window, playerView: playerView, screen: screen)
    }

    /// - Parameter deferFollowUpUntilFirstFrame: launch only. The video still
    ///   loads and plays immediately, but the post-playback work (still
    ///   extraction, next-video prewarm, lockscreen staging, saver reselect,
    ///   lockscreen apply) waits for the first composited frame (or an 8s
    ///   timeout) so the initial decode never contends with file copies,
    ///   extractions, or agent restarts. Warm switches pass false and keep
    ///   the existing immediate behavior.
    func setWallpaper(_ item: WallpaperItem, deferFollowUpUntilFirstFrame: Bool = false) {
        // Validate FIRST: never create/order windows for a dead file.
        // Windows are created transparent below and revealed on first frame.
        guard let url = store.validatedURL(item.url) else {
            abortInvalidItem(item, context: "switch")
            return
        }
        isActive = true
        store.setActiveWallpaper(item)
        let activeItem = item

        for screen in NSScreen.screens {
            if let id = displayID(for: screen), wallpaperWindows[id] == nil {
                createWallpaperWindow(for: screen, id: id)
            }
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
        if deferFollowUpUntilFirstFrame, !didSignalFirstFrame {
            // Cold launch: everything below the pointer write waits for
            // picture on screen. The decode owns disk/CPU until then.
            switchTask?.cancel()
            switchEpoch &+= 1
            let epoch = switchEpoch
            let stagedID = activeItem.id
            let stagedTitle = activeItem.title
            let stagedURL = url
            cycleLog("switch title=\(stagedTitle) (launch follow-up deferred until first frame)")
            switchTask = Task { [weak self] in
                await self?.waitForFirstFrame()
                guard !Task.isCancelled else {
                    await MainActor.run { [weak self] in
                        guard let self, self.switchEpoch == epoch else { return }
                        self.switchTask = nil
                    }
                    return
                }
                // NOTE: no sync/prewarm here. The first frame just landed; the
                // still extraction (1920p decode + JPEG), the next-video
                // prewarm decode and the lockscreen staging must not pile onto
                // the settling decoder at first-frame+0. They all run inside
                // runSwitchFollowUp below, after its post-swap quiet, with the
                // longer launch quiet (5s) so the first seconds of playback
                // own disk/CPU uncontended.
                await self?.runSwitchFollowUp(epoch: epoch, stagedURL: stagedURL, stagedID: stagedID, stagedTitle: stagedTitle, quiet: .seconds(5))
            }
            if SettingsManager.shared.cycleMode == .interval || SettingsManager.shared.cycleMode == .daily {
                SettingsManager.shared.lastCycleDate = Date()
                scheduleCycle()
            }
            return
        }
        // Visible switches sync the desktop still inside runSwitchFollowUp,
        // after the post-swap quiet, so the extraction decode never contends
        // the swap decode. Only the obscured path warms here (nothing
        // visible plays behind the lockscreen, so no contention): the
        // extraction starts now so the still is ready at unlock, but nothing
        // applies behind the lockscreen — the flush syncs on becoming
        // visible (fast-pathed).
        if SettingsManager.shared.syncSystemWallpaper, isObscured {
            DesktopPictureService.shared.prewarmStill(video: url, wallpaperID: activeItem.id)
        }
        // Single in-flight follow-up: superseded Tasks exit at the first
        // cancellation check, so rapid switches never stack agent restarts.
        // Overlap with the watchdog/unlock paths is serialized inside the
        // services (reselect slot + automatic slot + follow-stage slot).
        // Order matters: the follow-up Task first waits for the actual swap
        // (runSwitchFollowUp's post-swap gate), then a short deferral runs
        // so the fresh frame's decode owns disk/CPU and the visible swap
        // lands immediately; then lockscreen staging, the saver reselect,
        // and lockscreen apply/heal (file copies + agent restarts + heavy
        // I/O) run, and the next-cycle prewarm warms last so it can never
        // contend the swap decode.
        switchTask?.cancel()
        switchEpoch &+= 1
        let epoch = switchEpoch
        let stagedID = activeItem.id
        let stagedTitle = activeItem.title
        let stagedURL = url
        cycleLog("switch title=\(stagedTitle)")
        switchTask = Task { [weak self] in
            await self?.runSwitchFollowUp(epoch: epoch, stagedURL: stagedURL, stagedID: stagedID, stagedTitle: stagedTitle)
        }
        if SettingsManager.shared.cycleMode == .interval || SettingsManager.shared.cycleMode == .daily {
            SettingsManager.shared.lastCycleDate = Date()
            scheduleCycle()
        }
    }

    /// Shared post-playback follow-up: waits for the actual swap first (so
    /// the quiet below starts when the first frame has promoted, not when
    /// the kick happened), then a short deferral so the fresh frame's decode
    /// owns disk/CPU uncontended and the visible swap lands immediately,
    /// then lockscreen staging, then the saver reselect and lockscreen
    /// apply/heal, and finally the next-cycle prewarm. Single in-flight:
    /// superseded Tasks exit at the first cancellation check so rapid
    /// switches never stack restarts. Launch passes a longer quiet (5s): the
    /// cold decoder + page cache need more settle than a warm switch (2s).
    private func runSwitchFollowUp(epoch: Int, stagedURL: URL, stagedID: UUID, stagedTitle: String, quiet: Duration = .seconds(2)) async {
        guard !Task.isCancelled else {
            await MainActor.run { [weak self] in
                guard let self, self.switchEpoch == epoch else { return }
                self.switchTask = nil
            }
            return
        }
        // Post-swap gate: already-live returns at once; a stalled decode
        // falls through after the timeout (same bound as the view's safety
        // net), so a failed swap can never wedge the follow-up. Skipped when
        // obscured: no decode was kicked (silent-switch rule), so there is
        // no swap to wait for.
        let shouldGateOnSwap: Bool = await MainActor.run { [weak self] in
            guard let self else { return false }
            return !self.isObscured
        }
        if shouldGateOnSwap {
            await waitForFirstSwap(of: stagedURL)
        }
        guard !Task.isCancelled else {
            await MainActor.run { [weak self] in
                guard let self, self.switchEpoch == epoch else { return }
                self.switchTask = nil
            }
            return
        }
        // Decode-tail quiet: it starts at the swap (gated above), not at the
        // kick, so the stage copy + extraction below can never contend
        // the first-frame decode and push the visible swap seconds late.
        // Launch uses a longer quiet (cold decoder + cold page cache).
        try? await Task.sleep(for: quiet)
        guard !Task.isCancelled else {
            await MainActor.run { [weak self] in
                guard let self, self.switchEpoch == epoch else { return }
                self.switchTask = nil
            }
            return
        }
        // Desktop still sync, deferred past the quiet so the extraction
        // decode (1920p + JPEG) never contends the swap decode. Obscurity is
        // re-read here, not at kick time, per the silent-switch rule: a
        // switch kicked visible but now obscured only warms, and one kicked
        // obscured but now visible syncs.
        let (syncEnabled, obscuredNow): (Bool, Bool) = await MainActor.run { [weak self] in
            guard let self else { return (false, true) }
            return (SettingsManager.shared.syncSystemWallpaper, self.isObscured)
        }
        if syncEnabled {
            if obscuredNow {
                DesktopPictureService.shared.prewarmStill(video: stagedURL, wallpaperID: stagedID)
            } else {
                DesktopPictureService.shared.syncCurrentVideo(video: stagedURL, wallpaperID: stagedID)
            }
        }
        guard !Task.isCancelled else {
            await MainActor.run { [weak self] in
                guard let self, self.switchEpoch == epoch else { return }
                self.switchTask = nil
            }
            return
        }
        await HazelLockScreenService.shared.followSwitch(video: stagedURL, wallpaperID: stagedID, title: stagedTitle)
        guard !Task.isCancelled else {
            await MainActor.run { [weak self] in
                guard let self, self.switchEpoch == epoch else { return }
                self.switchTask = nil
            }
            return
        }
        await ScreensaverSelectService.shared.followSwitch()
        guard !Task.isCancelled else {
            await MainActor.run { [weak self] in
                guard let self, self.switchEpoch == epoch else { return }
                self.switchTask = nil
            }
            return
        }
        await HazelLockScreenService.shared.ensureAutomatic(video: stagedURL, wallpaperID: stagedID, title: stagedTitle)
        guard !Task.isCancelled else {
            await MainActor.run { [weak self] in
                guard let self, self.switchEpoch == epoch else { return }
                self.switchTask = nil
            }
            return
        }
        // Next-cycle warm runs LAST, on the main thread, once the current
        // video + still are settled: it warms the page cache + still file
        // for the following switch without ever racing the swap decode
        // above. (Calling it at kick time instead would start the next
        // decode + extraction concurrently with the current first frame.)
        await MainActor.run { [weak self] in
            guard let self, self.switchEpoch == epoch else { return }
            self.prewarmNextWallpaper()
        }
        guard !Task.isCancelled else {
            await MainActor.run { [weak self] in
                guard let self, self.switchEpoch == epoch else { return }
                self.switchTask = nil
            }
            return
        }
        await MainActor.run { [weak self] in
            guard let self, self.switchEpoch == epoch else { return }
            self.cycleLog("follow-up done title=\(stagedTitle)")
            self.switchTask = nil
        }
    }

    func clearWallpaper() {
        cycleLog("clear; timer cancelled")
        isActive = false
        cycleTimer?.invalidate()
        cycleTimer = nil
        cyclePrewarmTimer?.invalidate()
        cyclePrewarmTimer = nil
        switchEpoch &+= 1
        switchTask?.cancel()
        switchTask = nil
        pendingObscuredItem = nil
        didSignalFirstFrame = false

        for (_, entry) in wallpaperWindows {
            entry.playerView.cleanup()
            entry.window.close()
        }
        wallpaperWindows.removeAll()
        // Same teardown contract as abortInvalidItem: no waiter may outlive
        // the windows that could satisfy it.
        resumeSwapWaiters()
        drainFirstFrameWaiters()
    }

    func pauseAll() {
        for (_, entry) in wallpaperWindows {
            entry.playerView.pause()
        }
    }

    func resumeIfNeeded() {
        guard isActive, !isObscured else { return }

        for (_, entry) in wallpaperWindows {
            entry.playerView.ensurePlaying()
        }
    }

    func reloadCurrentWallpaper() {
        guard let activeItem = store.activeWallpaper else { return }
        guard let url = store.validatedURL(activeItem.url) else {
            // Missing file on reload (e.g. fit change after external
            // delete): tear down instead of leaving stale/black windows.
            abortInvalidItem(activeItem, context: "reload")
            return
        }

        if isObscured {
            // Same silent-switch rule as setWallpaper: defer decode until visible.
            pendingObscuredItem = activeItem
            cycleLog("reload deferred (obscured)")
            pauseAll()
            return
        }
        pendingObscuredItem = nil
        // Windows may not exist yet (launch before setWallpaper, or after an
        // abort cleared them): create transparent shells first, reveal on
        // first frame — never an opaque window before picture.
        for screen in NSScreen.screens {
            if let id = displayID(for: screen), wallpaperWindows[id] == nil {
                createWallpaperWindow(for: screen, id: id)
            }
        }
        for (_, entry) in wallpaperWindows {
            // Only the cold view needs the reveal callback, but it is
            // idempotent so re-setting it here is harmless.
            if !entry.playerView.hasDisplayedFirstFrame {
                entry.playerView.onFirstFrameReady = { [weak self, weak window = entry.window] prewarmed in
                    window?.reveal(animated: !prewarmed)
                    self?.signalFirstFrameIfNeeded()
                }
            }
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
        cyclePrewarmTimer?.invalidate()
        cyclePrewarmTimer = nil
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
            let interval = TimeInterval(minutes * 60)
            let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                self?.fireCycleTimer()
            }
            // User-visible fire: keep tolerance tight (≤2s). The default 5%
            // (up to 60s) lets the system defer the fire 10-15s past the
            // expected time on common presets — the reported cycle lag.
            // These timers fire hourly at most, so the power cost is nil.
            timer.tolerance = min(2, max(0.5, interval * 0.01))
            RunLoop.main.add(timer, forMode: .common)
            cycleTimer = timer
            armCyclePrewarm(after: prewarmDelay(forInterval: interval))
            cycleLog("timer armed interval=\(minutes)m")
        case .daily:
            if let fireDate = nextDailyFireDate() {
                // One-shot armed for the next fire; fireCycleTimer re-arms the
                // following day, so DST shifts and sleep gaps self-correct.
                let delay = max(1, fireDate.timeIntervalSinceNow)
                let timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                    self?.fireCycleTimer()
                }
                timer.tolerance = 5
                RunLoop.main.add(timer, forMode: .common)
                cycleTimer = timer
                armCyclePrewarm(after: prewarmDelay(forInterval: delay))
                cycleLog("timer armed daily=\(fireDate)")
            } else {
                cycleLog("timer daily skipped; no fire date")
            }
        }
        // Vsync-friendly: menu refresh listens on this and walks submenu
        // rows on main. Post async so the sync swap + layer commit finish
        // this runloop's vsync before the menu work runs on the next one.
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .hazelCycleSettingsChanged, object: nil)
        }
    }

    /// Lead time for the pre-fire decode warmer: close enough to the fire that
    /// the warmed page cache + still file survive, far enough ahead that the
    /// background decode/extraction finishes before the swap. Short
    /// intervals skip it (the fire-time decode is the warmup).
    private func prewarmDelay(forInterval interval: TimeInterval) -> TimeInterval {
        if interval > 180 {
            return interval - 60
        }
        if interval > 30 {
            return interval / 2
        }
        return 0
    }

    /// Arms the one-shot pre-fire warmer. Non-positive delays mean the
    /// interval is too short for an early warm — the post-swap prewarm
    /// (end of runSwitchFollowUp) already covers it.
    private func armCyclePrewarm(after delay: TimeInterval) {
        cyclePrewarmTimer?.invalidate()
        cyclePrewarmTimer = nil
        guard delay > 0 else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.cyclePrewarmTimer = nil
            self?.prewarmNextWallpaper()
        }
        timer.tolerance = min(5, max(1, delay * 0.05))
        RunLoop.main.add(timer, forMode: .common)
        cyclePrewarmTimer = timer
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
        let mode = SettingsManager.shared.cycleMode
        guard isActive, !isObscured else {
            cycleLog("timer fire dropped active=\(isActive) obscured=\(isObscured)")
            // The main timer keeps its own cadence (repeating interval, or
            // daily re-armed on wake/day-change), but the consumed one-shot
            // prewarm does not — re-arm it so the next fire still swaps warm.
            // While obscured the warmer no-ops via its guards; harmless.
            if mode == .interval, cycleTimer != nil {
                let interval = TimeInterval(max(1, SettingsManager.shared.cycleIntervalMinutes) * 60)
                armCyclePrewarm(after: prewarmDelay(forInterval: interval))
            }
            return
        }
        cycleLog("timer fire mode=\(mode.rawValue)")
        advanceToNextWallpaper()
        SettingsManager.shared.lastCycleDate = Date()
        if mode == .daily {
            scheduleCycle()
        } else if mode == .interval, cycleTimer != nil, cyclePrewarmTimer == nil {
            // advanceToNextWallpaper -> setWallpaper -> scheduleCycle re-arms
            // both timers on the normal path; this covers the edge where the
            // advance was a no-op (single item) and the prewarm was consumed.
            let interval = TimeInterval(max(1, SettingsManager.shared.cycleIntervalMinutes) * 60)
            armCyclePrewarm(after: prewarmDelay(forInterval: interval))
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

    /// Prewarm exactly one wallpaper ahead (the next cycle target) so a
    /// timer fire or unlock-cycle advance swaps onto warm caches: the video
    /// file/decoding path is primed once and the still is extracted without
    /// applying. Called at the END of the switch follow-up (post-swap, once
    /// the current video + still are settled) and ~60s before the next fire
    /// (so the warmup survives page-cache eviction over long intervals).
    /// Never started at kick time: that would race the swap decode it is
    /// meant to precede. One video decode warms the shared page cache for
    /// every display (plus the cross-view single-flight in VideoPlayerView),
    /// so fanning out per window would only duplicate the same 320p decode
    /// N times.
    /// Never stages the lockscreen container (that would flip library.json
    /// before the switch); never touches the store or timers.
    private func prewarmNextWallpaper() {
        guard isActive, !isObscured, store.wallpapers.count > 1,
              let currentID = store.activeWallpaperID,
              let index = store.wallpapers.firstIndex(where: { $0.id == currentID }) else { return }
        let next = store.wallpapers[(index + 1) % store.wallpapers.count]
        guard let url = store.validatedURL(next.url) else { return }
        if let first = wallpaperWindows.values.first {
            first.playerView.prewarm(url: url)
        }
        if SettingsManager.shared.syncSystemWallpaper {
            DesktopPictureService.shared.prewarmStill(video: url, wallpaperID: next.id)
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
