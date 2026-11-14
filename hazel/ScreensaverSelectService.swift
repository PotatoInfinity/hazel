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
    /// Last time followSwitch paid a store re-read. Healthy per-switch calls
    /// (cached selected) skip the plist decode and only re-verify at the
    /// cooldown boundary, bounding drift staleness without per-switch cost.
    private var lastFollowCheck: Date?
    /// Serializes every screensaver selection (each restarts the agent via
    /// the StoreWriter): concurrent triggers join one in-flight select
    /// instead of stacking killalls. Automatic waiters re-check after
    /// joining and skip a second restart when healed; manual selects always
    /// run their own attempt after joining (errors propagate to the UI).
    private final class ReselectSlot {
        var task: Task<Void, any Error>?
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

    // MARK: - Support gating

    /// Video lockscreen rides the `com.apple.wallpaper` extension point via an
    /// appex whose LSMinimumSystemVersion is 26.0. Below that the single
    /// toggle must stay disabled (with a tooltip), never half-apply.
    static let minimumOSVersion = OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)

    static func isOSSupported(_ v: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) -> Bool {
        if v.majorVersion != minimumOSVersion.majorVersion { return v.majorVersion > minimumOSVersion.majorVersion }
        if v.minorVersion != minimumOSVersion.minorVersion { return v.minorVersion > minimumOSVersion.minorVersion }
        return v.patchVersion >= minimumOSVersion.patchVersion
    }

    /// Installed saver's version string, if present.
    var installedSaverVersion: String? { SaverInstallService.shared.version }

    /// Bundled saver's version string, if the app bundle embeds one.
    var bundledSaverVersion: String? { cachedBundledVersion ?? nil }

    /// Version check behind the toggle: installed saver matches the bundled one.
    /// A mismatch is recoverable (activation reinstalls), so it gates nothing —
    /// it is surfaced in the UI caption instead.
    var isBundleCurrent: Bool { bundleCurrent() }

    /// Nil when the feature can run; a human-readable reason when the toggle
    /// must stay disabled.
    var supportReason: String? {
        if !Self.isOSSupported() {
            let v = ProcessInfo.processInfo.operatingSystemVersion
            return "Requires macOS 26.0 or later (running \(v.majorVersion).\(v.minorVersion).\(v.patchVersion))."
        }
        guard SaverInstallService.shared.bundledSaverURL != nil else {
            return "Bundled Hazel.saver is missing; rebuild the app to embed it."
        }
        return nil
    }

    var isSupported: Bool { supportReason == nil }

    /// A version counts as current only when both sides report a real version.
    /// (nil == nil must never read as "up to date".)
    private func bundleCurrent() -> Bool {
        guard let installed = SaverInstallService.shared.version,
              let bundled = bundledSaverVersion else { return false }
        return installed == bundled
    }

    private func setSelected(_ value: Bool) {
        stateLock.lock()
        _isSelected = value
        stateLock.unlock()
    }

    /// Re-reads the store so `isSelected` reflects the live selection.
    /// Explicit UI opens call this; per-switch followSwitch skips it when the
    /// cached state is healthy (see lastFollowCheck).
    func refresh() {
        setSelected(saver.getActiveScreensavers().contains(Self.moduleName))
        stateLock.lock()
        lastFollowCheck = Date()
        stateLock.unlock()
    }

    /// Selects Hazel everywhere. Errors pass through (PaperSaverError is LocalizedError).
    /// Serialized with automatic reselections through the slot: a tap racing
    /// an in-flight reselect waits for it, then runs its own select (user
    /// intent always applies); concurrent taps serialize instead of stacking
    /// two agent restarts. The attempt is pre-stamped so rapid callers back off.
    func makeHazelScreensaver() async throws {
        if Task.isCancelled { throw CancellationError() }
        while true {
            stateLock.lock()
            let running = reselectSlot.task
            stateLock.unlock()
            if let running {
                // Join, but never inherit the failure: an in-flight auto may
                // fail while the user's explicit tap can still succeed.
                _ = await running.result
                if Task.isCancelled { throw CancellationError() }
                continue
            }
            stateLock.lock()
            if reselectSlot.task != nil {
                stateLock.unlock()
                continue
            }
            lastReassert = Date()
            let created: Task<Void, any Error> = Task { [weak self] in
                guard let self else { return }
                try await self.runSelect(reason: "manual")
            }
            reselectSlot.task = created
            stateLock.unlock()
            let result = await created.result
            stateLock.lock()
            reselectSlot.task = nil
            stateLock.unlock()
            try result.get()
            return
        }
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

    /// Disable path for the single toggle: back to the system default.
    /// Restores the newest backup first (lockscreen backup, else the PaperSaver
    /// backup), then deselects Hazel as the screensaver and removes the video
    /// lockscreen extension as fallback for whatever is still on. Never fights
    /// a state that is already off. Sets the same opt-out flags an explicit
    /// manual removal sets so automatic healing (`ensureAutomatic`, watchdog)
    /// stays off afterwards.
    func deactivateToSystemDefault() async throws {
        guard supportReason == nil else {
            throw PaperSaverError.unsupportedOperation(supportReason ?? "Unsupported on this system.")
        }
        // Restore-first: put the pre-Hazel surface back from backup (newest
        // lockscreen backup, else the PaperSaver backup). Best-effort — any
        // failure (or no backup) falls through to the explicit deselect /
        // remove below, which also re-verifies whatever is still on.
        try? await restoreSystemBackup()
        HazelLockScreenService.shared.refresh()
        if HazelLockScreenService.shared.isApplied {
            try await HazelLockScreenService.shared.removeLockscreen()
        } else {
            SettingsManager.shared.didManualRemoveLockscreen = true
        }
        refresh()
        if isSelected {
            try await saver.clearWallpaperExtension(slot: .screensaver)
            refresh()
        }
        // Stickiness: an explicit OFF must never be re-taken over behind the
        // user's back. `didAutoManageSaver = true` stops first-run reselect;
        // `didManualRemoveLockscreen = true` stops lockscreen healing.
        SettingsManager.shared.didAutoManageSaver = true
        SettingsManager.shared.didManualRemoveLockscreen = true
        HazelLockScreenService.shared.refresh()
        refresh()
    }

    /// Manual rollback for the separate "Restore backup" button. Prefers the
    /// lockscreen backup directory (full-store images covering both slots) and
    /// falls back to the store's own `.backup` file. Like OFF, it opts out of
    /// automatic re-takeover afterwards.
    func restoreSystemBackup() async throws {
        if HazelLockScreenService.shared.hasBackup {
            try await HazelLockScreenService.shared.restoreLatestBackup()
        } else {
            try await saver.restoreFromBackup()
        }
        SettingsManager.shared.didAutoManageSaver = true
        SettingsManager.shared.didManualRemoveLockscreen = true
        HazelLockScreenService.shared.refresh()
        refresh()
    }

    /// Called on every wallpaper switch/cycle: keep bundle + selection following. Silent.
    /// Re-selection is cooldown-gated so rapid switches cannot restart the agent in a loop.
    /// Steady-state cost is zero plist decodes: the install check is TTL-cached
    /// and a cached-selected state skips the store re-read (drift is healed by
    /// the watchdog/menu refresh, bounded to the cooldown window).
    func followSwitch() async {
        if Task.isCancelled { return }
        if !SaverInstallService.shared.isInstalled || !bundleCurrent() {
            try? SaverInstallService.shared.install()
        }
        if Task.isCancelled { return }
        stateLock.lock()
        if isSelectedUnsafe {
            let due = lastFollowCheck.map { Date().timeIntervalSince($0) > Self.reassertCooldown } ?? true
            if !due {
                stateLock.unlock()
                return
            }
            lastFollowCheck = Date()
            stateLock.unlock()
        } else {
            stateLock.unlock()
        }
        refresh()
        stateLock.lock()
        lastFollowCheck = Date()
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
    /// double-restart). A running reselect is joined and re-checked: if it
    /// already healed the selection, the waiter returns without a second
    /// restart; otherwise it claims the slot and runs serially.
    private func requestReselect(reason: String) async {
        if Task.isCancelled { return }
        while true {
            stateLock.lock()
            let running = reselectSlot.task
            stateLock.unlock()
            if let running {
                cycleLog("reselect (\(reason)) coalesced onto in-flight")
                _ = await running.result
                if Task.isCancelled { return }
                refresh()
                if isSelected { return }
                continue
            }
            stateLock.lock()
            if reselectSlot.task != nil {
                stateLock.unlock()
                continue
            }
            lastReassert = Date()
            let created: Task<Void, any Error> = Task { [weak self] in
                guard let self else { return }
                try await self.runSelect(reason: reason)
            }
            reselectSlot.task = created
            stateLock.unlock()
            _ = await created.result
            stateLock.lock()
            reselectSlot.task = nil
            stateLock.unlock()
            return
        }
    }

    /// The raw select every path above funnels through. Failures are logged
    /// here; automatic callers swallow them (slot result), manual callers
    /// rethrow to the UI.
    private func runSelect(reason: String) async throws {
        guard !Task.isCancelled else { throw CancellationError() }
        do {
            try await saver.setScreensaverEverywhere(module: Self.moduleName)
            refresh()
            stateLock.lock()
            lastReassert = Date()
            stateLock.unlock()
            cycleLog("reselect (\(reason)) applied")
        } catch {
            if error is CancellationError { throw error }
            cycleLog("reselect (\(reason)) failed: \(error.localizedDescription)")
            throw error
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
