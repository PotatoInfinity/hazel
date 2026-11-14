import Foundation
import AVFoundation
import ServiceManagement

enum CycleMode: String, CaseIterable, Codable {
    case none = "None"
    case onUnlock = "On Unlock"
    case interval = "Every N Minutes"
    case daily = "Daily"
}

enum CycleUnit: String, CaseIterable, Codable {
    case minutes = "Minutes"
    case hours = "Hours"
    case days = "Days"

    var multiplier: Int {
        switch self {
        case .minutes: return 1
        case .hours: return 60
        case .days: return 1440
        }
    }
}

/// Named interval presets shown in the menu bar and Settings. All of them run
/// the `.interval` engine; the preset only fixes value + unit.
enum CyclePreset: CaseIterable {
    case halfHour
    case oneHour
    case fiveHours

    var title: String {
        switch self {
        case .halfHour: return "Every 30 Minutes"
        case .oneHour: return "Every Hour"
        case .fiveHours: return "Every 5 Hours"
        }
    }

    var value: Int {
        switch self {
        case .halfHour: return 30
        case .oneHour: return 1
        case .fiveHours: return 5
        }
    }

    var unit: CycleUnit {
        switch self {
        case .halfHour: return .minutes
        case .oneHour: return .hours
        case .fiveHours: return .hours
        }
    }

    var minutes: Int { value * unit.multiplier }

    static func matching(minutes: Int) -> CyclePreset? {
        allCases.first { $0.minutes == minutes }
    }
}

enum WallpaperFit: String, CaseIterable, Codable {
    case fill = "Fill"
    case fit = "Fit"
    case center = "Center"
    case stretch = "Stretch"
    
    var videoGravity: AVLayerVideoGravity {
        switch self {
        case .fill: return .resizeAspectFill
        case .fit: return .resizeAspect
        case .center: return .resizeAspect
        case .stretch: return .resize
        }
    }
}

@Observable
/// Thin UserDefaults wrapper. Deliberately not `@MainActor`: every property is
/// an independent key with no read-modify-write, and UserDefaults itself is
/// thread-safe, so background reads (follow-up Tasks) cannot corrupt state.
/// Callers must still mutate model objects (WallpaperStore) on the main thread.
class SettingsManager {
    static let shared = SettingsManager()
    
    var wallpaperFit: WallpaperFit {
        get {
            if let rawValue = UserDefaults.standard.string(forKey: "wallpaperFit"),
               let fit = WallpaperFit(rawValue: rawValue) {
                return fit
            }
            return .fill
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "wallpaperFit")
        }
    }

    var menuBarIcon: MenuBarIcon {
        get {
            if let rawValue = UserDefaults.standard.string(forKey: "menuBarIcon"),
               let icon = MenuBarIcon(rawValue: rawValue) {
                return icon
            }
            return .hazelLight
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "menuBarIcon")
            NotificationCenter.default.post(name: .hazelMenuBarIconChanged, object: nil)
        }
    }
    
    var openOnStartup: Bool {
        get {
            UserDefaults.standard.bool(forKey: "openOnStartup")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "openOnStartup")
            updateLoginItem(enabled: newValue)
        }
    }

    var syncSystemWallpaper: Bool {
        get {
            if UserDefaults.standard.object(forKey: "syncSystemWallpaper") == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: "syncSystemWallpaper")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "syncSystemWallpaper")
        }
    }

    var cycleMode: CycleMode {
        get {
            if let rawValue = UserDefaults.standard.string(forKey: "cycleMode"),
               let mode = CycleMode(rawValue: rawValue) {
                return mode
            }
            return .interval
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "cycleMode")
        }
    }

    var cycleIntervalMinutes: Int {
        get {
            let value = UserDefaults.standard.integer(forKey: "cycleIntervalMinutes")
            return value > 0 ? value : 30
        }
        set {
            UserDefaults.standard.set(max(1, newValue), forKey: "cycleIntervalMinutes")
        }
    }

    /// Display value/unit for the custom interval. The scheduler only reads
    /// `cycleIntervalMinutes`; presets and the Custom row keep all three in sync.
    var cycleIntervalValue: Int {
        get {
            let value = UserDefaults.standard.integer(forKey: "cycleIntervalValue")
            return value > 0 ? value : 30
        }
        set {
            UserDefaults.standard.set(max(1, newValue), forKey: "cycleIntervalValue")
        }
    }

    var cycleIntervalUnit: CycleUnit {
        get {
            if let rawValue = UserDefaults.standard.string(forKey: "cycleIntervalUnit"),
               let unit = CycleUnit(rawValue: rawValue) {
                return unit
            }
            return .minutes
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "cycleIntervalUnit")
            cycleIntervalMinutes = max(1, cycleIntervalValue * newValue.multiplier)
        }
    }

    /// Applies a preset (or custom value+unit) atomically: display fields and
    /// the scheduler's minute count never disagree.
    func applyCycleInterval(value: Int, unit: CycleUnit) {
        let clamped = max(1, value)
        UserDefaults.standard.set(clamped, forKey: "cycleIntervalValue")
        UserDefaults.standard.set(unit.rawValue, forKey: "cycleIntervalUnit")
        UserDefaults.standard.set(max(1, clamped * unit.multiplier), forKey: "cycleIntervalMinutes")
    }

    func applyCyclePreset(_ preset: CyclePreset) {
        cycleMode = .interval
        applyCycleInterval(value: preset.value, unit: preset.unit)
    }

    var cycleDailyHour: Int {
        get {
            if UserDefaults.standard.object(forKey: "cycleDailyHour") == nil {
                return 8
            }
            return UserDefaults.standard.integer(forKey: "cycleDailyHour")
        }
        set {
            UserDefaults.standard.set(min(23, max(0, newValue)), forKey: "cycleDailyHour")
        }
    }

    var cycleDailyMinute: Int {
        get {
            if UserDefaults.standard.object(forKey: "cycleDailyMinute") == nil {
                return 0
            }
            return UserDefaults.standard.integer(forKey: "cycleDailyMinute")
        }
        set {
            UserDefaults.standard.set(min(59, max(0, newValue)), forKey: "cycleDailyMinute")
        }
    }

    var lastCycleDate: Date? {
        get {
            UserDefaults.standard.object(forKey: "lastCycleDate") as? Date
        }
        set {
            if let date = newValue {
                UserDefaults.standard.set(date, forKey: "lastCycleDate")
            } else {
                UserDefaults.standard.removeObject(forKey: "lastCycleDate")
            }
        }
    }

    var didAutoManageSaver: Bool {
        get {
            UserDefaults.standard.bool(forKey: "didAutoManageSaver")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "didAutoManageSaver")
        }
    }

    var didAutoApplyLockscreen: Bool {
        get {
            UserDefaults.standard.bool(forKey: "didAutoApplyLockscreen")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "didAutoApplyLockscreen")
        }
    }

    /// Set when the user explicitly removes the video lockscreen. While set,
    /// automatic healing stays off — a manual removal is never reverted behind
    /// the user's back. Cleared by the next successful apply.
    var didManualRemoveLockscreen: Bool {
        get {
            UserDefaults.standard.bool(forKey: "didManualRemoveLockscreen")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "didManualRemoveLockscreen")
        }
    }

    /// Last automatic apply attempt (any outcome). Bounds heal frequency so a
    /// flapping agent cannot trigger an agent-restart storm.
    var lastLockscreenAutoAttempt: Date? {
        get {
            UserDefaults.standard.object(forKey: "lastLockscreenAutoAttempt") as? Date
        }
        set {
            if let date = newValue {
                UserDefaults.standard.set(date, forKey: "lastLockscreenAutoAttempt")
            } else {
                UserDefaults.standard.removeObject(forKey: "lastLockscreenAutoAttempt")
            }
        }
    }
    
    private init() {
        // No work here: SMAppService hits launchd over XPC and must not run
        // anywhere near the first-frame decode. The UserDefaults value is
        // already authoritative; daemon convergence happens in
        // syncLoginItemAfterWarmup (first frame + quiet, via the app's
        // deferred launch block) and on every explicit toggle below.
    }

    /// Converges the launchd registration with the stored preference. Called
    /// once from the app's deferred launch block (after the first frame, off
    /// the critical path), never during init.
    func syncLoginItemAfterWarmup() {
        updateLoginItem(enabled: UserDefaults.standard.bool(forKey: "openOnStartup"))
    }
    
    private func updateLoginItem(enabled: Bool) {
        // Fire-and-forget off the caller (often main during launch):
        // registration is idempotent, callers never depend on completion.
        // Background so launchd XPC never contends display decode.
        DispatchQueue.global(qos: .background).async {
            if #available(macOS 13.0, *) {
                do {
                    if enabled {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    print("Failed to update login item: \(error)")
                }
            }
        }
    }
}
