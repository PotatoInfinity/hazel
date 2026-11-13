import Foundation

/// One-click selection of Hazel as the macOS screensaver.
/// Thin wrapper over the vendored PaperSaverKit (same-module compile).
///
/// Threading: the service is a shared mutable singleton touched from both the
/// main thread (menu/Settings rows) and background follow-up Tasks. All state
/// lives behind `stateLock`; PaperSaver's reads/writes are synchronous plist
/// operations, so a short lock is sufficient (no lock is held across await).
final class ScreensaverSelectService {
    static let shared = ScreensaverSelectService()

    private static let moduleName = "Hazel"
    /// Minimum gap between automatic re-selections: follow-up switches must
    /// not restart the agent in a tight loop if selection drifts mid-cycle.
    private static let reassertCooldown: TimeInterval = 300

    private let saver = PaperSaver()
    private let stateLock = NSLock()
    private var _isSelected = false
    private var lastReassert: Date?
    /// Serializes automatic re-selections (each restarts the agent via the
    /// StoreWriter): concurrent triggers coalesce onto one in-flight reselect
    /// instead of stacking killalls. Manual makeHazelScreensaver calls bypass
    /// the slot (user-initiated) but share the pre-stamped cooldown.
    private final class ReselectSlot {
        var task: Task<Void, Never>?
    }
    private let reselectSlot = ReselectSlot()

    /// Terse transition log for Console.app storm/freeze diagnosis.
    private func cycleLog(_ message: String) {
        NSLog("[HazelCycle] %@", message)
    }

    /// Cached: the bundled saver's version never changes within a launch.
    private lazy var cachedBundledVersion: String?? = ScreensaverSelectService.readBundledVersion()

    /// True when "Hazel" is among the active screensavers.
    var isSelected: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _isSelected
    }

    private init() {
        _isSelected = PaperSaver().getActiveScreensavers().contains(Self.moduleName)
    }

    private static func readBundledVersion() -> String? {
        guard let url = SaverInstallService.shared.bundledSaverURL else { return nil }
        let plistURL = url.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return dict["CFBundleShortVersionString"] as? String
    }

    private var bundledVersion: String? { cachedBundledVersion ?? nil }

    /// A version counts as current only when both sides report a real version.
    /// (nil == nil must never read as "up to date".)
    private func bundleCurrent() -> Bool {
        guard let installed = SaverInstallService.shared.version,
              let bundled = bundledVersion else { return false }
        return installed == bundled
    }

    private func setSelected(_ value: Bool) {
        stateLock.lock()
        _isSelected = value
        stateLock.unlock()
    }

    /// Re-reads the store so `isSelected` reflects the live selection.
    func refresh() {
        setSelected(saver.getActiveScreensavers().contains(Self.moduleName))
    }

    /// Selects Hazel everywhere. Errors pass through (PaperSaverError is LocalizedError).
    func makeHazelScreensaver() async throws {
        try await saver.setScreensaverEverywhere(module: Self.moduleName)
        refresh()
        stateLock.lock()
        lastReassert = Date()
        stateLock.unlock()
    }

    /// Full activation in one tap: bundle in place, screensaver selected, and
    /// video lockscreen applied (needs the active wallpaper).
    func activateForScreensaverAndLockscreen() async throws {
        if !SaverInstallService.shared.isInstalled || !bundleCurrent() {
            try SaverInstallService.shared.install()
        }
        if !SettingsManager.shared.syncSystemWallpaper {
            SettingsManager.shared.syncSystemWallpaper = true
            DesktopPictureService.shared.reconcile()
        }
        try await makeHazelScreensaver()
        if isSelected {
            SettingsManager.shared.didAutoManageSaver = true
        }
        guard let item = AppContext.shared.store?.activeWallpaper,
              let url = AppContext.shared.store?.validatedURL(item.url) else {
            throw HazelLockScreenService.LockScreenError.noActiveVideo
        }
        try await HazelLockScreenService.shared.applyLockscreen(video: url, wallpaperID: item.id, title: item.title)
        HazelLockScreenService.shared.refresh()
        guard HazelLockScreenService.shared.isApplied else {
            throw HazelLockScreenService.LockScreenError.processFailed(
                executable: "WallpaperAgent", status: -1,
                output: "Video lockscreen did not verify after apply.")
        }
    }

    /// Called on every wallpaper switch/cycle: keep bundle + selection following. Silent.
    /// Re-selection is cooldown-gated so rapid switches cannot restart the agent in a loop.
    func followSwitch() async {
        if Task.isCancelled { return }
        if !SaverInstallService.shared.isInstalled || !bundleCurrent() {
            try? SaverInstallService.shared.install()
        }
        if Task.isCancelled { return }
        refresh()
        stateLock.lock()
        let cooledDown = lastReassert.map { Date().timeIntervalSince($0) > Self.reassertCooldown } ?? true
        let shouldReassert = !isSelectedUnsafe && SettingsManager.shared.didAutoManageSaver && cooledDown
        stateLock.unlock()
        if !shouldReassert { return }
        cycleLog("followSwitch reselect requested")
        await requestReselect(reason: "followSwitch")
    }

    /// Single choke point for every automatic re-selection. The attempt is
    /// stamped BEFORE the restart (not after success) so rapid callers back
    /// off instead of each passing the cooldown check mid-flight (TOCTOU
    /// double-restart). A running reselect is joined, never duplicated.
    private func requestReselect(reason: String) async {
        if Task.isCancelled { return }
        stateLock.lock()
        if let running = reselectSlot.task {
            stateLock.unlock()
            cycleLog("reselect (\(reason)) coalesced onto in-flight")
            await running.value
            return
        }
        lastReassert = Date()
        let created: Task<Void, Never> = Task { [weak self] in
            guard let self else { return }
            await self.runReselect(reason: reason)
        }
        reselectSlot.task = created
        stateLock.unlock()
        await created.value
        stateLock.lock()
        // Only the running task clears: creation happens under this lock and
        // only when nil, so no successor can exist while we run.
        reselectSlot.task = nil
        stateLock.unlock()
    }

    private func runReselect(reason: String) async {
        guard !Task.isCancelled else { return }
        do {
            try await makeHazelScreensaver()
            cycleLog("reselect (\(reason)) applied")
        } catch {
            cycleLog("reselect (\(reason)) failed: \(error.localizedDescription)")
        }
    }

    private var isSelectedUnsafe: Bool { _isSelected }

    /// Zero-touch setup: keeps the bundled saver in place and selects Hazel
    /// unless it already took over once (never fights a manual change).
    /// Silent by design — callers surface nothing; the Settings row shows status.
    func ensureAutomatic() async {
        if Task.isCancelled { return }
        if !SaverInstallService.shared.isInstalled || !bundleCurrent() {
            try? SaverInstallService.shared.install()
        }
        if Task.isCancelled { return }
        refresh()
        if isSelected || SettingsManager.shared.didAutoManageSaver { return }
        cycleLog("ensureAutomatic first-run select requested")
        await requestReselect(reason: "ensureAutomatic")
        if isSelected {
            SettingsManager.shared.didAutoManageSaver = true
        }
    }
}
