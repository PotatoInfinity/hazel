import SwiftUI
import AppKit

extension Notification.Name {
    /// Posted by WallpaperController.scheduleCycle() so the menu bar titles
    /// stay in sync when intervals change from the Settings panel.
    static let hazelCycleSettingsChanged = Notification.Name("com.live.hazel.cycleSettingsChanged")
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

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var store: WallpaperStore?
    private var controller: WallpaperController?
    private var managementWindowController: ManagementWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        registerFonts()
        
        let wallpaperStore = WallpaperStore()
        self.store = wallpaperStore
        AppContext.shared.store = wallpaperStore

        let wallpaperController = WallpaperController(store: wallpaperStore)
        self.controller = wallpaperController
        AppContext.shared.controller = wallpaperController

        if let activeItem = wallpaperStore.activeWallpaper {
            wallpaperController.setWallpaper(activeItem)
        }

        setupStatusItem()

        NotificationCenter.default.addObserver(
            forName: .hazelCycleSettingsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshCycleMenu()
        }

        managementWindowController = ManagementWindowController()

        Task {
            await ScreensaverSelectService.shared.ensureAutomatic()
        }
    }
    
    private func registerFonts() {
        guard let fontURL = Bundle.main.url(forResource: "GeistPixel-Square", withExtension: "otf"),
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
            if let image = NSImage(named: "Logo") {
                image.size = NSSize(width: 24, height: 24)
                button.image = image
            } else {
                button.image = NSImage(systemSymbolName: "play.rectangle.fill", accessibilityDescription: "Hazel-Live wallpaper")
            }
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
    }

    @objc private func statusItemClicked() {
        openManagement()
    }

    @objc private func openManagement() {
        guard let store = store, let controller = controller else { return }
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
        
        if let menu = statusItem?.menu {
            if let fitItem = menu.item(withTitle: "Wallpaper Fit"),
               let submenu = fitItem.submenu {
                for item in submenu.items {
                    item.state = item.representedObject as? WallpaperFit == fit ? .on : .off
                }
            }
        }
        
        controller?.reloadCurrentWallpaper()
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
        Task {
            do {
                try await ScreensaverSelectService.shared.activateForScreensaverAndLockscreen()
                await MainActor.run { self.refreshCycleMenu() }
            } catch {
                await MainActor.run {
                    let alert = NSAlert(error: error)
                    alert.messageText = "Could not set Hazel as screensaver"
                    alert.runModal()
                }
            }
        }
    }

    private func refreshCycleMenu() {
        guard let menu = statusItem?.menu,
              let cycleItem = menu.item(withTitle: "Cycle Wallpaper"),
              let submenu = cycleItem.submenu else { return }
        for item in submenu.items {
            guard let raw = item.representedObject as? String,
                  let id = CycleMenuID(rawValue: raw) else { continue }
            let mode = SettingsManager.shared.cycleMode
            let minutes = SettingsManager.shared.cycleIntervalMinutes
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
                item.title = String(format: "Daily %02d:%02d", SettingsManager.shared.cycleDailyHour, SettingsManager.shared.cycleDailyMinute)
            case .custom:
                item.state = (mode == .interval && CyclePreset.matching(minutes: minutes) == nil) ? .on : .off
            }
        }
        if let syncItem = menu.item(withTitle: "Sync system wallpaper") {
            syncItem.state = SettingsManager.shared.syncSystemWallpaper ? .on : .off
        }
        ScreensaverSelectService.shared.refresh()
        HazelLockScreenService.shared.refresh()
        if let useItem = menu.item(withTitle: "Use Hazel for screensaver and lockscreen") {
            useItem.state = (ScreensaverSelectService.shared.isSelected && HazelLockScreenService.shared.isApplied) ? .on : .off
        }
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.clearWallpaper()
    }
}
