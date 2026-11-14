import SwiftUI
import AppKit

extension Notification.Name {
    /// Posted by WallpaperController.scheduleCycle() so the menu bar titles
    /// stay in sync when intervals change from the Settings panel.
    static let hazelCycleSettingsChanged = Notification.Name("com.live.hazel.cycleSettingsChanged")
    /// Posted by SettingsManager.menuBarIcon's setter so the status item
    /// swaps art immediately without relaunch.
    static let hazelMenuBarIconChanged = Notification.Name("com.live.hazel.menuBarIconChanged")
}

@main
struct LiveWallpaperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var store: WallpaperStore?
    private var controller: WallpaperController?
    private var managementWindowController: ManagementWindowController?
    /// Periodic drift check: re-reads both selections and re-applies when
    /// missing. All heavy work stays behind the existing guards (5-min saver
    /// cooldown, 1-h lockscreen cooldown, no fighting a manual removal), so a
    /// healthy system costs at most two TTL-cached reads per tick and nothing
    /// else. Ticks never overlap: a slow tick is cancelled before the next
    /// starts (no stacked agent restarts).
    private var watchdogTimer: Timer?
    /// Latest watchdog tick. Cancelled + replaced each fire so a slow heal
    /// can never overlap the next tick or a switch follow-up storm.
    private var watchdogTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let launchStart = Date()
        NSLog("[HazelLaunch] open")
        // NOTE: font registration is intentionally NOT here. It reads the
        // bundled .otf off disk and contends with the first-frame video
        // decode; the management/settings panels that need it open much
        // later. Registered in the deferred block below (first frame + 8s
        // fallback), same gate as the saver reselect.

        let wallpaperStore = WallpaperStore()
        self.store = wallpaperStore
        AppContext.shared.store = wallpaperStore

        let wallpaperController = WallpaperController(store: wallpaperStore)
        self.controller = wallpaperController
        AppContext.shared.controller = wallpaperController

        if let activeItem = wallpaperStore.activeWallpaper {
            if wallpaperStore.validatedURL(activeItem.url) != nil {
                // Prewarm the decode before anything else contends for
                // disk/CPU, then start playback. Windows stay transparent
                // until the first frame reveals them — no black flash.
                // Heavy follow-up (lockscreen staging, still extraction,
                // saver reselect, lockscreen apply/heal) waits for the first
                // frame inside the controller (8s timeout fallback), so the
                // initial decode owns the machine until picture is up.
                VideoPlayerView.prewarm(url: activeItem.url)
                wallpaperController.setWallpaper(activeItem, deferFollowUpUntilFirstFrame: true)
            } else {
                // Stale active (deleted/moved file): idle with the system
                // desktop visible instead of ordering black windows. Clear
                // the dead pointer so relaunches do not retry it.
                NSLog("[Hazel] AppDelegate: launch skipped, active file missing title=%@ path=%@",
                      activeItem.title, activeItem.url.path)
                wallpaperStore.activeWallpaperID = nil
                wallpaperController.clearWallpaper()
            }
        }

        setupStatusItem()

        NotificationCenter.default.addObserver(
            forName: .hazelCycleSettingsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshCycleMenu()
        }

        NotificationCenter.default.addObserver(
            forName: .hazelMenuBarIconChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateMenuBarIcon()
        }

        managementWindowController = ManagementWindowController()

        // Deferred off the first-frame critical path: font registration
        // (bundled .otf disk read, only needed by the panels) plus the saver
        // selection (agent restarts + plist I/O) must not contend with the
        // initial video decode. Fire after the first frame composites, with
        // a fallback delay in case there is no active video (or the frame
        // never arrives) so selection still converges.
        var launchDeferredEnsured = false
        let launchDeferredLock = NSLock()
        let bundledFontURL = Bundle.main.url(forResource: "GeistPixel-Square", withExtension: "otf")
        func ensureDeferredLaunchWorkOnce() {
            let shouldRun: Bool = launchDeferredLock.withLock {
                if launchDeferredEnsured { return false }
                launchDeferredEnsured = true
                return true
            }
            guard shouldRun else { return }
            // Cheap dispatches stay inline (each just hops to a background
            // queue): the library maintenance the store skipped at init
            // (migration copies, stale-URL repair, thumbnail decodes) and
            // the login-item convergence SettingsManager skipped at init.
            // Fonts (bundled .otf disk read, panels only) plus the saver
            // reselect (agent restarts + plist I/O) run below on a utility
            // queue after an extra quiet, so the first seconds of playback
            // own the machine uncontended.
            wallpaperStore.startDeferredMaintenance()
            SettingsManager.shared.syncLoginItemAfterWarmup()
            Task.detached(priority: .utility) {
                AppDelegate.registerFont(at: bundledFontURL)
                NSLog("[HazelLaunch] deferred work start (fonts done) in %.2fs", Date().timeIntervalSince(launchStart))
                try? await Task.sleep(for: .seconds(5))
                await ScreensaverSelectService.shared.ensureAutomatic()
            }
        }
        wallpaperController.onFirstFrameReady = {
            NSLog("[HazelLaunch] first frame in %.2fs", Date().timeIntervalSince(launchStart))
            ensureDeferredLaunchWorkOnce()
        }
        Task {
            try? await Task.sleep(for: .seconds(8))
            await MainActor.run { ensureDeferredLaunchWorkOnce() }
        }

        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 900, repeats: true) { [weak self] _ in
            guard let self else { return }
            // Coalesce: never stack ticks. A previous slow heal is cancelled;
            // the follow-up slots inside the services (reselect/automatic/
            // follow-stage) further coalesce with any in-flight switch work
            // instead of restarting the agent twice.
            self.watchdogTask?.cancel()
            self.watchdogTask = Task { [weak self] in
                if Task.isCancelled { return }
                await ScreensaverSelectService.shared.followSwitch()
                if Task.isCancelled { return }
                guard let store = self?.store,
                      let item = store.activeWallpaper,
                      let url = store.validatedURL(item.url) else { return }
                // Per-switch staging first (cheap re-assert when current):
                // ensureAutomatic alone returns early once the provider is
                // applied and would never re-stage a pruned/missed file.
                await HazelLockScreenService.shared.followSwitch(video: url, wallpaperID: item.id, title: item.title)
                if Task.isCancelled { return }
                await HazelLockScreenService.shared.ensureAutomatic(video: url, wallpaperID: item.id, title: item.title)
            }
        }
        // Steady-state drift check: drift tolerates minutes of delay, so use
        // wide leeway (180s on a 900s interval) and let the system coalesce
        // this wake with other timers instead of waking main on its own
        // vsync. The fire itself only cancels + spawns the background Task;
        // all heavy work (store re-reads, staging, agent checks) stays off
        // main inside that Task.
        watchdogTimer?.tolerance = 180
        if let watchdogTimer {
            RunLoop.main.add(watchdogTimer, forMode: .common)
        }
    }
    
    /// Deferred font registration: runs on a utility queue after the first
    /// frame (see ensureDeferredLaunchWorkOnce), never on the launch path.
    /// Static + Sendable-safe so the deferred Task.detached needs no `self`.
    private static func registerFont(at fontURL: URL?) {
        guard let fontURL,
              let fontDataProvider = CGDataProvider(url: fontURL as CFURL),
              let font = CGFont(fontDataProvider) else {
            print("Failed to load custom font")
            return
        }

        var error: Unmanaged<CFError>?
        if CTFontManagerRegisterGraphicsFont(font, &error) {
            print("Custom font registered successfully")
        } else {
            print("Failed to register custom font: \(error?.takeRetainedValue().localizedDescription ?? "unknown error")")
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem?.button {
            button.image = SettingsManager.shared.menuBarIcon.makeStatusImage()
                ?? NSImage(systemSymbolName: "play.rectangle.fill", accessibilityDescription: "Hazel-Live wallpaper")
            button.action = #selector(statusItemClicked)
            button.target = self
        }

        let menu = NSMenu()

        let openItem = NSMenuItem(title: "Hazel", action: #selector(openManagement), keyEquivalent: "h")
        openItem.target = self
        menu.addItem(openItem)

        // Titled "Hazel Settings" (not "Settings…"): macOS decorates an item
        // named exactly "Settings…" with a gear icon we don't want.
        let settingsItem = NSMenuItem(title: "Hazel Settings", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        let fitMenu = NSMenu()
        for fit in WallpaperFit.allCases {
            let item = NSMenuItem(title: fit.rawValue, action: #selector(fitSelected(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = fit
            if fit == SettingsManager.shared.wallpaperFit {
                item.state = .on
            }
            fitMenu.addItem(item)
        }
        
        let fitItem = NSMenuItem(title: "Wallpaper Fit", action: nil, keyEquivalent: "")
        fitItem.submenu = fitMenu
        menu.addItem(fitItem)

        let startupItem = NSMenuItem(title: "Open on Startup", action: #selector(toggleStartup(_:)), keyEquivalent: "")
        startupItem.target = self
        startupItem.state = SettingsManager.shared.openOnStartup ? .on : .off
        menu.addItem(startupItem)

        let syncItem = NSMenuItem(title: "Sync system wallpaper", action: #selector(toggleSyncWallpaper(_:)), keyEquivalent: "")
        syncItem.target = self
        syncItem.state = SettingsManager.shared.syncSystemWallpaper ? .on : .off
        menu.addItem(syncItem)

        let useSaverItem = NSMenuItem(title: "Use Hazel for screensaver and lockscreen", action: #selector(useHazelAsScreensaver(_:)), keyEquivalent: "")
        useSaverItem.target = self
        menu.addItem(useSaverItem)

        let cycleMenu = NSMenu()
        for (title, id) in AppDelegate.cycleMenuEntries() {
            if title.isEmpty {
                cycleMenu.addItem(NSMenuItem.separator())
                continue
            }
            let item = NSMenuItem(title: title, action: #selector(cycleSelected(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id as NSString
            cycleMenu.addItem(item)
        }

        let cycleItem = NSMenuItem(title: "Cycle Wallpaper", action: nil, keyEquivalent: "")
        cycleItem.submenu = cycleMenu
        menu.addItem(cycleItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu
        menu.delegate = self
        cycleMenu.delegate = self
        fitMenu.delegate = self
    }

    /// Refreshes all checkmarks/titles on open so the menu never shows stale
    /// state edited from a Settings window while the menu was closed.
    /// The store re-reads live here (user-opened menu only): refreshCycleMenu
    /// also runs on every cycle-settings notification (each switch), where
    /// synchronous plist decodes on main would be pure per-switch cost.
    /// Per-switch paths stay on TTL/cached reads; only this explicit open
    /// pays for fresh install + selection state.
    func menuWillOpen(_ menu: NSMenu) {
        // Menu open proves the session is visible (impossible behind the
        // lockscreen): heal a stuck obscured flag and re-assert playback
        // before the refresh work. Previously this interaction only resumed
        // playback by side effect; now it is the deterministic heal path.
        controller?.handleUserInteractionVisible()
        SaverInstallService.shared.refreshInstallCache()
        ScreensaverSelectService.shared.refresh()
        HazelLockScreenService.shared.refresh()
        refreshCycleMenu()
    }

    @objc private func statusItemClicked() {
        openManagement()
    }

    @objc private func openManagement() {
        guard let store = store, let controller = controller else { return }
        controller.handleUserInteractionVisible()
        managementWindowController?.showPanel(store: store, controller: controller)
    }

    @objc private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        settingsPanelController.show()
    }

    private lazy var settingsPanelController = SettingsPanelController()

    /// Menu rows for the cycle submenu. Empty title = separator. IDs are
    /// stable strings so the menu survives Settings edits elsewhere.
    static func cycleMenuEntries() -> [(title: String, id: String)] {
        var entries: [(title: String, id: String)] = [
            ("None", CycleMenuID.none.rawValue),
            ("On Unlock", CycleMenuID.onUnlock.rawValue),
            ("", ""),
        ]
        for preset in CyclePreset.allCases {
            let id: String
            switch preset {
            case .halfHour: id = CycleMenuID.halfHour.rawValue
            case .oneHour: id = CycleMenuID.oneHour.rawValue
            case .fiveHours: id = CycleMenuID.fiveHours.rawValue
            }
            entries.append((preset.title, id))
        }
        entries.append(("Daily", CycleMenuID.daily.rawValue))
        entries.append(("", ""))
        entries.append(("Custom…", CycleMenuID.custom.rawValue))
        return entries
    }

    @objc private func fitSelected(_ sender: NSMenuItem) {
        guard let fit = sender.representedObject as? WallpaperFit else { return }
        SettingsManager.shared.wallpaperFit = fit

        refreshFitMenu()

        controller?.reloadCurrentWallpaper()
        NotificationCenter.default.post(name: .hazelCycleSettingsChanged, object: nil)
    }

    @objc private func toggleStartup(_ sender: NSMenuItem) {
        let newValue = !SettingsManager.shared.openOnStartup
        SettingsManager.shared.openOnStartup = newValue
        sender.state = newValue ? .on : .off
    }

    private enum CycleMenuID: String {
        case none, onUnlock, halfHour, oneHour, fiveHours, daily, custom
    }

    @objc private func toggleSyncWallpaper(_ sender: NSMenuItem) {
        let newValue = !SettingsManager.shared.syncSystemWallpaper
        controller?.setSyncEnabled(newValue)
        sender.state = newValue ? .on : .off
        NotificationCenter.default.post(name: .hazelCycleSettingsChanged, object: nil)
    }

    @objc private func cycleSelected(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let id = CycleMenuID(rawValue: raw) else { return }
        switch id {
        case .none:
            controller?.setCycleMode(.none)
        case .onUnlock:
            controller?.setCycleMode(.onUnlock)
        case .halfHour:
            SettingsManager.shared.applyCyclePreset(.halfHour)
            controller?.setCycleMode(.interval)
        case .oneHour:
            SettingsManager.shared.applyCyclePreset(.oneHour)
            controller?.setCycleMode(.interval)
        case .fiveHours:
            SettingsManager.shared.applyCyclePreset(.fiveHours)
            controller?.setCycleMode(.interval)
        case .daily:
            controller?.setCycleMode(.daily)
        case .custom:
            openSettings()
            return
        }
        refreshCycleMenu()
    }

    @objc private func useHazelAsScreensaver(_ sender: NSMenuItem) {
        ScreensaverSelectService.shared.refresh()
        HazelLockScreenService.shared.refresh()
        let combinedOn = ScreensaverSelectService.shared.isSelected
            && HazelLockScreenService.shared.isApplied
        Task {
            do {
                if combinedOn {
                    try await ScreensaverSelectService.shared.deactivateToSystemDefault()
                } else {
                    if let reason = ScreensaverSelectService.shared.supportReason {
                        throw PaperSaverError.unsupportedOperation(reason)
                    }
                    try await ScreensaverSelectService.shared.activateForScreensaverAndLockscreen()
                }
                await MainActor.run {
                    ScreensaverSelectService.shared.refresh()
                    HazelLockScreenService.shared.refresh()
                    self.refreshCycleMenu()
                }
            } catch {
                let wasOn = combinedOn
                await MainActor.run {
                    let alert = NSAlert(error: error)
                    alert.messageText = wasOn
                        ? "Could not restore the system default"
                        : "Could not set Hazel as screensaver"
                    alert.runModal()
                }
            }
        }
    }

    private func refreshCycleMenu() {
        guard let menu = statusItem?.menu,
              let cycleItem = menu.item(withTitle: "Cycle Wallpaper"),
              let submenu = cycleItem.submenu else { return }
        // Hoisted: one UserDefaults read per key per notification, not one
        // per submenu row. This runs on every switch (scheduleCycle posts),
        // so per-row defaults reads were pure per-switch cost.
        let mode = SettingsManager.shared.cycleMode
        let minutes = SettingsManager.shared.cycleIntervalMinutes
        let dailyHour = SettingsManager.shared.cycleDailyHour
        let dailyMinute = SettingsManager.shared.cycleDailyMinute
        let customSelected = mode == .interval && CyclePreset.matching(minutes: minutes) == nil
        for item in submenu.items {
            guard let raw = item.representedObject as? String,
                  let id = CycleMenuID(rawValue: raw) else { continue }
            switch id {
            case .none:
                item.state = mode == .none ? .on : .off
            case .onUnlock:
                item.state = mode == .onUnlock ? .on : .off
            case .halfHour:
                item.state = (mode == .interval && minutes == CyclePreset.halfHour.minutes) ? .on : .off
            case .oneHour:
                item.state = (mode == .interval && minutes == CyclePreset.oneHour.minutes) ? .on : .off
            case .fiveHours:
                item.state = (mode == .interval && minutes == CyclePreset.fiveHours.minutes) ? .on : .off
            case .daily:
                item.state = mode == .daily ? .on : .off
                item.title = String(format: "Daily %02d:%02d", dailyHour, dailyMinute)
            case .custom:
                item.state = customSelected ? .on : .off
            }
        }
        if let syncItem = menu.item(withTitle: "Sync system wallpaper") {
            syncItem.state = SettingsManager.shared.syncSystemWallpaper ? .on : .off
        }
        if let startupItem = menu.item(withTitle: "Open on Startup") {
            startupItem.state = SettingsManager.shared.openOnStartup ? .on : .off
        }
        refreshFitMenu()
        // No store re-reads here: this runs on every cycle-settings
        // notification (each switch). Freshness comes from menuWillOpen and
        // the post-activation paths, which refresh explicitly. isSelected /
        // isApplied are cached mirrors (no plist decode); supportReason is
        // hoisted to one evaluation (OS check + bundle URL, no plist read).
        let saverSelected = ScreensaverSelectService.shared.isSelected
        let lockscreenApplied = HazelLockScreenService.shared.isApplied
        let reason = ScreensaverSelectService.shared.supportReason
        if let useItem = menu.item(withTitle: "Use Hazel for screensaver and lockscreen") {
            useItem.state = (saverSelected && lockscreenApplied) ? .on : .off
            if let reason {
                useItem.isEnabled = false
                useItem.toolTip = reason
            } else {
                useItem.isEnabled = true
                useItem.toolTip = "On: screensaver and lockscreen play the current video. Off: system default."
            }
        }
    }

    private func refreshFitMenu() {
        guard let menu = statusItem?.menu,
              let fitItem = menu.item(withTitle: "Wallpaper Fit"),
              let submenu = fitItem.submenu else { return }
        let fit = SettingsManager.shared.wallpaperFit
        for item in submenu.items {
            item.state = item.representedObject as? WallpaperFit == fit ? .on : .off
        }
    }

    private func updateMenuBarIcon() {
        statusItem?.button?.image = SettingsManager.shared.menuBarIcon.makeStatusImage()
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        watchdogTask?.cancel()
        watchdogTask = nil
        controller?.clearWallpaper()
    }
}
