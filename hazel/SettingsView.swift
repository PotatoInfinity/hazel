import SwiftUI

/// System Settings panel (opens via Cmd+, or menu bar > Hazel Settings).
/// Owns every user-facing setting; the library window stays a pure gallery.
struct SettingsView: View {
    private enum CycleChoice: Hashable {
        case none
        case onUnlock
        case preset(CyclePreset)
        case daily
        case custom
    }

    @State private var syncSystemWallpaper = SettingsManager.shared.syncSystemWallpaper
    @State private var wallpaperFit = SettingsManager.shared.wallpaperFit
    @State private var menuBarIcon = SettingsManager.shared.menuBarIcon
    @State private var cycleChoice: CycleChoice = Self.currentChoice()
    @State private var cycleValue = SettingsManager.shared.cycleIntervalValue
    @State private var cycleUnit = SettingsManager.shared.cycleIntervalUnit
    @State private var cycleDailyHour = SettingsManager.shared.cycleDailyHour
    @State private var cycleDailyMinute = SettingsManager.shared.cycleDailyMinute
    @State private var isSaverSelected = ScreensaverSelectService.shared.isSelected
    @State private var isSelectingSaver = false
    @State private var lockscreenActive = HazelLockScreenService.shared.isApplied
    @State private var isApplyingLockscreen = false
    @State private var hasBackup = HazelLockScreenService.shared.hasBackup
    @State private var supportReason: String? = ScreensaverSelectService.shared.supportReason
    @State private var installedSaverVersion: String? = ScreensaverSelectService.shared.installedSaverVersion
    @State private var bundledSaverVersion: String? = ScreensaverSelectService.shared.bundledSaverVersion
    @State private var isBundleCurrent = ScreensaverSelectService.shared.isBundleCurrent
    @State private var errorMessage = ""
    @State private var showingError = false

    private static func currentChoice() -> CycleChoice {
        switch SettingsManager.shared.cycleMode {
        case .none:
            return .none
        case .onUnlock:
            return .onUnlock
        case .daily:
            return .daily
        case .interval:
            if let preset = CyclePreset.matching(minutes: SettingsManager.shared.cycleIntervalMinutes) {
                return .preset(preset)
            }
            return .custom
        }
    }

    private var controller: WallpaperController? {
        AppContext.shared.controller
    }

    var body: some View {
        Form {
            Section("Menu Bar") {
                Picker("Menu icon", selection: $menuBarIcon) {
                    ForEach(MenuBarIcon.allCases, id: \.self) { icon in
                        Text(icon.title).tag(icon)
                    }
                }
                .onChange(of: menuBarIcon) { _, newValue in
                    SettingsManager.shared.menuBarIcon = newValue
                }
            }

            Section("Wallpaper") {
                Toggle("Sync system wallpaper", isOn: $syncSystemWallpaper)
                    .onChange(of: syncSystemWallpaper) { _, newValue in
                        controller?.setSyncEnabled(newValue)
                        NotificationCenter.default.post(name: .hazelCycleSettingsChanged, object: nil)
                    }
                Text("Keeps the system wallpaper in sync when Hazel quits or the screen locks.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Picker("Fit", selection: $wallpaperFit) {
                    ForEach(WallpaperFit.allCases, id: \.self) { fit in
                        Text(fit.rawValue).tag(fit)
                    }
                }
                .onChange(of: wallpaperFit) { _, newValue in
                    SettingsManager.shared.wallpaperFit = newValue
                    controller?.reloadCurrentWallpaper()
                    NotificationCenter.default.post(name: .hazelCycleSettingsChanged, object: nil)
                }
            }

            Section("Cycling") {
                Picker("Cycle", selection: $cycleChoice) {
                    Text("None").tag(CycleChoice.none)
                    Text("On Unlock").tag(CycleChoice.onUnlock)
                    ForEach(CyclePreset.allCases, id: \.title) { preset in
                        Text(preset.title).tag(CycleChoice.preset(preset))
                    }
                    Text("Daily").tag(CycleChoice.daily)
                    Text("Custom…").tag(CycleChoice.custom)
                }
                .onChange(of: cycleChoice) { _, newValue in
                    applyChoice(newValue)
                }

                if cycleChoice == .custom {
                    HStack {
                        Stepper("Every \(cycleValue)", value: $cycleValue, in: 1...999)
                        Picker("", selection: $cycleUnit) {
                            ForEach(CycleUnit.allCases, id: \.self) { unit in
                                Text(unit.rawValue).tag(unit)
                            }
                        }
                        .frame(width: 110)
                    }
                    .onChange(of: cycleValue) { _, _ in applyCustom() }
                    .onChange(of: cycleUnit) { _, _ in applyCustom() }
                }

                if cycleChoice == .daily {
                    HStack {
                        Stepper("\(cycleDailyHour)h", value: $cycleDailyHour, in: 0...23)
                            .onChange(of: cycleDailyHour) { _, newValue in
                                SettingsManager.shared.cycleDailyHour = newValue
                                controller?.scheduleCycle()
                            }
                        Stepper("\(cycleDailyMinute)m", value: $cycleDailyMinute, in: 0...59, step: 5)
                            .onChange(of: cycleDailyMinute) { _, newValue in
                                SettingsManager.shared.cycleDailyMinute = newValue
                                controller?.scheduleCycle()
                            }
                    }
                }

                if cycleChoice == .onUnlock {
                    Text("Advances on unlock / wake")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Section("Screensaver and lockscreen") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Use Hazel for screensaver and lockscreen", isOn: Binding(
                        get: { isSaverSelected && lockscreenActive },
                        set: { on in Task { on ? await runCombinedActivation() : await runDisable() } }
                    ))
                    .disabled(!isSupported || isWorking)
                    .help(supportReason ?? "On: screensaver and lockscreen play the current video. Off: system default.")
                    Text(combinedStatusText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(versionCaption)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    HStack {
                        Button("Re-apply") {
                            Task { await runCombinedActivation() }
                        }
                        .disabled(!isSupported || isWorking)
                        Button("Restore backup") {
                            Task { await runRestoreBackup() }
                        }
                        .disabled(!isSupported || isWorking || !hasBackup)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 500)
        .padding(8)
        .onAppear(perform: refreshAll)
        .onReceive(NotificationCenter.default.publisher(for: .hazelCycleSettingsChanged)) { _ in
            // Cycle-only: this fires on every wallpaper switch. The saver/
            // lockscreen store re-reads stay in refreshAll (appear + explicit
            // activation) so switches never cost plist decodes on main.
            refreshCycleFields()
        }
        .onReceive(NotificationCenter.default.publisher(for: .hazelMenuBarIconChanged)) { _ in
            menuBarIcon = SettingsManager.shared.menuBarIcon
        }
        .alert("Settings error", isPresented: $showingError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage)
        }
    }

    private func refreshAll() {
        refreshCycleFields()
        ScreensaverSelectService.shared.refresh()
        isSaverSelected = ScreensaverSelectService.shared.isSelected
        HazelLockScreenService.shared.refresh()
        lockscreenActive = HazelLockScreenService.shared.isApplied
        hasBackup = HazelLockScreenService.shared.hasBackup
        supportReason = ScreensaverSelectService.shared.supportReason
        installedSaverVersion = ScreensaverSelectService.shared.installedSaverVersion
        bundledSaverVersion = ScreensaverSelectService.shared.bundledSaverVersion
        isBundleCurrent = ScreensaverSelectService.shared.isBundleCurrent
    }

    private func refreshCycleFields() {
        syncSystemWallpaper = SettingsManager.shared.syncSystemWallpaper
        wallpaperFit = SettingsManager.shared.wallpaperFit
        menuBarIcon = SettingsManager.shared.menuBarIcon
        cycleChoice = Self.currentChoice()
        cycleValue = SettingsManager.shared.cycleIntervalValue
        cycleUnit = SettingsManager.shared.cycleIntervalUnit
        cycleDailyHour = SettingsManager.shared.cycleDailyHour
        cycleDailyMinute = SettingsManager.shared.cycleDailyMinute
    }

    private func applyChoice(_ choice: CycleChoice) {
        switch choice {
        case .none:
            controller?.setCycleMode(.none)
        case .onUnlock:
            controller?.setCycleMode(.onUnlock)
        case .preset(let preset):
            SettingsManager.shared.applyCyclePreset(preset)
            cycleValue = preset.value
            cycleUnit = preset.unit
            controller?.setCycleMode(.interval)
        case .daily:
            controller?.setCycleMode(.daily)
        case .custom:
            applyCustom()
        }
    }

    private func applyCustom() {
        SettingsManager.shared.applyCycleInterval(value: cycleValue, unit: cycleUnit)
        controller?.setCycleMode(.interval)
        cycleChoice = .custom
    }

    /// Single-toggle truth: ON only when BOTH saver and lockscreen run Hazel.
    /// A mixed state (e.g. saver on, lockscreen off) is drift, never "on" —
    /// it reads as Partial with a pointer to fix it.
    private var combinedStatusText: String {
        if isWorking { return "Working…" }
        if !isSupported { return supportReason ?? "Unsupported on this Mac." }
        switch (isSaverSelected, lockscreenActive) {
        case (true, true): return "On — screensaver and lockscreen play the current video."
        case (false, false): return "Off — using the system default."
        case (true, false): return "Partial — screensaver on, lockscreen off. Turn off then on, or restore the backup."
        case (false, true): return "Partial — lockscreen on, screensaver off. Turn off then on, or restore the backup."
        }
    }

    private var isSupported: Bool { supportReason == nil }

    private var isWorking: Bool { isSelectingSaver || isApplyingLockscreen }

    private var versionCaption: String {
        if !isSupported { return supportReason ?? "" }
        switch (installedSaverVersion, bundledSaverVersion) {
        case let (installed?, bundled?):
            return isBundleCurrent
                ? "Saver v\(installed) — up to date."
                : "Saver v\(installed) installed, v\(bundled) bundled — Re-apply to update."
        case (_, let bundled?):
            return "Saver not installed yet — bundled v\(bundled)."
        default:
            return ""
        }
    }

    private func runCombinedActivation() async {
        guard isSupported else { return }
        isSelectingSaver = true
        isApplyingLockscreen = true
        defer {
            isSelectingSaver = false
            isApplyingLockscreen = false
        }
        do {
            try await ScreensaverSelectService.shared.activateForScreensaverAndLockscreen()
        } catch {
            errorMessage = error.localizedDescription
            showingError = true
        }
        refreshAll()
    }

    private func runDisable() async {
        isSelectingSaver = true
        isApplyingLockscreen = true
        defer {
            isSelectingSaver = false
            isApplyingLockscreen = false
        }
        do {
            try await ScreensaverSelectService.shared.deactivateToSystemDefault()
        } catch {
            errorMessage = error.localizedDescription
            showingError = true
        }
        refreshAll()
    }

    private func runRestoreBackup() async {
        isSelectingSaver = true
        isApplyingLockscreen = true
        defer {
            isSelectingSaver = false
            isApplyingLockscreen = false
        }
        do {
            try await ScreensaverSelectService.shared.restoreSystemBackup()
        } catch {
            errorMessage = error.localizedDescription
            showingError = true
        }
        refreshAll()
    }
}
