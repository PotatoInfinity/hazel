import SwiftUI

/// System Settings panel (opens via Cmd+, or Hazel menu > Settings).
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
    @State private var cycleChoice: CycleChoice = Self.currentChoice()
    @State private var cycleValue = SettingsManager.shared.cycleIntervalValue
    @State private var cycleUnit = SettingsManager.shared.cycleIntervalUnit
    @State private var cycleDailyHour = SettingsManager.shared.cycleDailyHour
    @State private var cycleDailyMinute = SettingsManager.shared.cycleDailyMinute
    @State private var isSaverSelected = ScreensaverSelectService.shared.isSelected
    @State private var isSelectingSaver = false
    @State private var lockscreenActive = HazelLockScreenService.shared.isApplied
    @State private var isApplyingLockscreen = false
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
            Section("Wallpaper") {
                Toggle("Sync system wallpaper", isOn: $syncSystemWallpaper)
                    .onChange(of: syncSystemWallpaper) { _, newValue in
                        controller?.setSyncEnabled(newValue)
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
                    Text("Video screensaver and lockscreen")
                    Text(screensaverStatusText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Button(screensaverButtonTitle) {
                        Task { await runCombinedActivation() }
                    }
                    .disabled(isSelectingSaver || isApplyingLockscreen)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 430)
        .padding(8)
        .onAppear(perform: refreshAll)
        .alert("Settings error", isPresented: $showingError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage)
        }
    }

    private func refreshAll() {
        syncSystemWallpaper = SettingsManager.shared.syncSystemWallpaper
        wallpaperFit = SettingsManager.shared.wallpaperFit
        cycleChoice = Self.currentChoice()
        cycleValue = SettingsManager.shared.cycleIntervalValue
        cycleUnit = SettingsManager.shared.cycleIntervalUnit
        cycleDailyHour = SettingsManager.shared.cycleDailyHour
        cycleDailyMinute = SettingsManager.shared.cycleDailyMinute
        ScreensaverSelectService.shared.refresh()
        isSaverSelected = ScreensaverSelectService.shared.isSelected
        HazelLockScreenService.shared.refresh()
        lockscreenActive = HazelLockScreenService.shared.isApplied
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

    private var screensaverStatusText: String {
        if isSelectingSaver || isApplyingLockscreen { return "Working…" }
        switch (isSaverSelected, lockscreenActive) {
        case (true, true): return "On — plays the current video."
        case (true, false): return "Screensaver on, lockscreen off."
        case (false, true): return "Lockscreen on, screensaver off."
        case (false, false): return "Off"
        }
    }

    private var screensaverButtonTitle: String {
        (isSaverSelected && lockscreenActive) ? "Re-apply" : "Use Hazel for screensaver and lockscreen"
    }

    private func runCombinedActivation() async {
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
        ScreensaverSelectService.shared.refresh()
        isSaverSelected = ScreensaverSelectService.shared.isSelected
        HazelLockScreenService.shared.refresh()
        lockscreenActive = HazelLockScreenService.shared.isApplied
    }
}
