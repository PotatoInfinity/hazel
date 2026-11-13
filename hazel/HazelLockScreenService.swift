import Foundation

/// App side of the video lockscreen.
///
/// The lockscreen renders the desktop role (Muro model: lockscreen = desktop role
/// surfaces), so applying the video lockscreen means writing the wallpaper-extension
/// choice into the store's **desktop** slot with `otherSlot: .keep`.
///
/// Why a hand-ported writer instead of `PaperSaver.setWallpaperExtension`:
/// - The contract needs `Files=[{relative: <staged file absoluteString>}]` in the
///   choice; the library writes `files: []` with no way to inject.
/// - Verification must cover role (desktop provider) + target (everywhere) + file
///   (configuration bytes and the staged-file relative), not just the provider.
/// - Backups go to a dedicated `LockScreenStoreBackups/` directory (restore surface
///   for `removeLockscreen`), on top of the store's own `.backup`.
/// - The apply path needs a double-write+sleep around the agent restart.
///
/// Read paths and all store/agent/pluginkit model types are reused from the vendored
/// PaperSaverKit (same-module compile): `StoreFile`, `SystemWallpaperStore.setting /
/// clearing`, `WallpaperChoice`, `ChoiceProvider`, `OptionValues`, `WriteOutcome`,
/// `PaperSaverError`, `WallpaperAgent`, `PluginkitOutputParser`.
final class HazelLockScreenService {
    static let shared = HazelLockScreenService()

    /// Bundle identifier of the wallpaper extension (owned by the extension worker).
    static let wallpaperExtensionID = "com.live.hazel.wallpaper-extension"

    private static let libraryChangedNote = "com.live.hazel.wallpaper.library-changed"
    private static let prefsChangedNote = "com.live.hazel.wallpaper.prefs-changed"

    /// Bounded waits for every step; no infinite waits anywhere.
    struct Timeouts: Sendable {
        var process: Duration = .seconds(15)
        var respawn: Duration = .seconds(5)
        var quietPeriod: Duration = .milliseconds(750)
        var settle: Duration = .seconds(4)
        var doubleWriteSleep: Duration = .seconds(1)
        var extensionLaunch: Duration = .seconds(6)
        var extensionRelaunchAttempts = 1
    }

    var timeouts = Timeouts()

    /// Sync mirror of the store state for UI rows; call `refresh()` to update.
    private(set) var isApplied = false

    private let fileManager = FileManager.default
    private let storeFile = StoreFile()

    private init() {
        refresh()
    }

    // MARK: - Status

    /// Re-reads the store so `isApplied` reflects the live desktop-role selection.
    /// Keeps the previous value when the store cannot be read.
    func refresh() {
        if let store = try? storeFile.read(),
           let provider = store.provider(of: .desktop, in: .everywhere) {
            isApplied = provider == ChoiceProvider(rawValue: Self.wallpaperExtensionID)
        }
    }

    private func currentDesktopProvider() -> ChoiceProvider? {
        (try? storeFile.read())?.provider(of: .desktop, in: .everywhere)
    }

    /// Every section that renders the desktop role must point at our extension.
    /// `provider(of:in:)` answers from the most-specific sections first, so a
    /// single check can miss a per-Space override; walk them all.
    private func isUniformlyApplied(_ store: SystemWallpaperStore) -> Bool {
        let ours = ChoiceProvider(rawValue: Self.wallpaperExtensionID)
        for section in store.allSections {
            if let desktop = section.desktop, let provider = desktop.provider {
                if provider.isPlaceholder { continue }
                guard provider == ours else { return false }
            } else if let linked = section.linked?.provider, !linked.isPlaceholder {
                guard linked == ours else { return false }
            }
        }
        return true
    }

    // MARK: - Extension container staging

    private var containerDocumentsURL: URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/\(Self.wallpaperExtensionID)/Data/Documents", isDirectory: true)
    }

    /// Stable library id. The store choice and library entry use this FIXED id
    /// so switching videos never touches the wallpaper store: only the staged
    /// FILE changes (name carries the video id), and the extension retargets
    /// live renderers on the library-changed notification. No agent restarts
    /// per switch — applying happens once, following is free.
    static let stagedID = "hazel-current"

    /// Staged file for a video: name carries the video id so a switch changes
    /// the URL (the appex switches readers by URL) while old files are swept.
    private func stagedFileName(for wallpaperID: UUID) -> String {
        "wallpaper-\(wallpaperID.uuidString.prefix(8).lowercased()).mov"
    }

    func stagedVideoURL(for wallpaperID: UUID) -> URL {
        containerDocumentsURL
            .appendingPathComponent("videos/\(Self.stagedID)/\(stagedFileName(for: wallpaperID))", isDirectory: false)
    }

    private struct LibraryEntry: Codable {
        var id: String
        var title: String
        var videoFilename: String
    }

    private struct ExtensionLibrary: Codable {
        var wallpapers: [LibraryEntry]
    }

    private struct ExtensionPrefs: Codable {
        var alwaysPauseDesktop: Bool
    }

    /// The wallpaper id currently staged in the extension container, if any.
    func stagedWallpaperID() -> String? {
        let url = containerDocumentsURL.appendingPathComponent("library.json")
        guard let data = try? Data(contentsOf: url),
              let library = try? JSONDecoder().decode(ExtensionLibrary.self, from: data) else { return nil }
        return library.wallpapers.first?.id
    }

    /// The library.json the extension will accept: single entry with the fixed
    /// staged id and a bare basename filename (the extension prunes any entry
    /// containing "/" or "..").
    private func isStagedCurrent(video: URL, wallpaperID: UUID) -> Bool {
        let dest = stagedVideoURL(for: wallpaperID)
        guard stagedWallpaperID() == Self.stagedID,
              fileManager.fileExists(atPath: dest.path),
              sameFile(dest, video) else { return false }
        let url = containerDocumentsURL.appendingPathComponent("library.json")
        guard let data = try? Data(contentsOf: url),
              let library = try? JSONDecoder().decode(ExtensionLibrary.self, from: data),
              let entry = library.wallpapers.first,
              entry.id == Self.stagedID,
              entry.videoFilename == stagedFileName(for: wallpaperID) else { return false }
        return true
    }

    /// Copies `video` into the extension container as
    /// `videos/hazel-current/wallpaper-<id8>.mov` (atomically), refreshes `library.json` + `hazel-prefs.json`, and posts the
    /// Darwin library/prefs notifications. Returns `false` when nothing changed,
    /// so callers can stage on every wallpaper switch cheaply.
    /// Never touches the wallpaper store.
    ///
    /// NOTE: `videoFilename` is the bare basename — the extension prunes any
    /// entry containing "/" (path traversal guard); a subpath never resolves.
    @discardableResult
    func stage(video: URL, wallpaperID: UUID, title: String) throws -> Bool {
        let dest = stagedVideoURL(for: wallpaperID)
        if isStagedCurrent(video: video, wallpaperID: wallpaperID) {
            return false
        }
        try fileManager.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Unique temp name: two overlapping stages must never share a path.
        let tmp = dest.deletingLastPathComponent()
            .appendingPathComponent("wallpaper.\(UUID().uuidString.prefix(8)).download")
        try? fileManager.removeItem(at: tmp)
        do {
            try fileManager.copyItem(at: video, to: tmp)
        } catch {
            throw PaperSaverError.plistWriteError("\(tmp.path): stage copy failed: \(error.localizedDescription)")
        }
        do {
            if fileManager.fileExists(atPath: dest.path) {
                _ = try fileManager.replaceItemAt(dest, withItemAt: tmp)
            } else {
                try fileManager.moveItem(at: tmp, to: dest)
            }
        } catch {
            throw PaperSaverError.plistWriteError("\(dest.path): stage replace failed: \(error.localizedDescription)")
        }
        sweepStaleStaged(except: dest)
        let library = ExtensionLibrary(wallpapers: [LibraryEntry(
            id: Self.stagedID,
            title: title,
            videoFilename: dest.lastPathComponent)])
        do {
            let data = try JSONEncoder().encode(library)
            try data.write(to: containerDocumentsURL.appendingPathComponent("library.json"), options: .atomic)
        } catch {
            throw PaperSaverError.plistWriteError("library.json: \(error.localizedDescription)")
        }
        postDarwinNotification(Self.libraryChangedNote)
        do {
            let data = try JSONEncoder().encode(ExtensionPrefs(alwaysPauseDesktop: true))
            try data.write(to: containerDocumentsURL.appendingPathComponent("hazel-prefs.json"), options: .atomic)
        } catch {
            throw PaperSaverError.plistWriteError("hazel-prefs.json: \(error.localizedDescription)")
        }
        postDarwinNotification(Self.prefsChangedNote)
        return true
    }

    /// Removes staged files from previous videos (old per-id dirs from the
    /// earlier layout plus superseded files). Cheap directory listing; the live
    /// file is never touched.
    private func sweepStaleStaged(except current: URL) {
        let videos = containerDocumentsURL.appendingPathComponent("videos", isDirectory: true)
        guard let entries = try? fileManager.contentsOfDirectory(at: videos, includingPropertiesForKeys: nil) else { return }
        for entry in entries {
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: entry.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                if entry.lastPathComponent == "hazel-current" {
                    let files = (try? fileManager.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil)) ?? []
                    for file in files where file.lastPathComponent != current.lastPathComponent
                        && !file.pathExtension.lowercased().hasPrefix("downloa")
                        && file.pathExtension.lowercased() != "download" {
                        try? fileManager.removeItem(at: file)
                    }
                } else {
                    // Legacy per-id directory from the old staging layout.
                    try? fileManager.removeItem(at: entry)
                }
            }
        }
    }

    private func sameFile(_ a: URL, _ b: URL) -> Bool {
        guard let attrsA = try? fileManager.attributesOfItem(atPath: a.path),
              let attrsB = try? fileManager.attributesOfItem(atPath: b.path),
              let sizeA = attrsA[.size] as? NSNumber,
              let sizeB = attrsB[.size] as? NSNumber,
              sizeA == sizeB,
              let mtimeA = attrsA[.modificationDate] as? Date,
              let mtimeB = attrsB[.modificationDate] as? Date else { return false }
        return abs(mtimeA.timeIntervalSince(mtimeB)) < 1.0
    }

    private func postDarwinNotification(_ name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name as CFString), nil, nil, true)
    }

    // MARK: - Registration

    enum LockScreenError: LocalizedError {
        case noActiveVideo
        case appexNotFoundInBundle
        case processTimeout(executable: String)
        case processFailed(executable: String, status: Int32, output: String)

        var errorDescription: String? {
            switch self {
            case .noActiveVideo:
                return "No active wallpaper video to use for the lockscreen."
            case .appexNotFoundInBundle:
                return "Wallpaper extension not found in Hazel.app (Contents/Extensions or Contents/PlugIns)."
            case .processTimeout(let executable):
                return "\(executable) timed out."
            case .processFailed(let executable, let status, let output):
                return "\(executable) failed (exit \(status))\(output.isEmpty ? "" : ": \(output)")"
            }
        }
    }

    /// The extension appex bundled inside Hazel.app, matched by bundle identifier so
    /// the file name the extension worker chooses does not matter.
    func appexURL() -> URL? {
        let bundleURL = Bundle.main.bundleURL
        for sub in ["Contents/Extensions", "Contents/PlugIns"] {
            let dir = bundleURL.appendingPathComponent(sub)
            guard let items = try? fileManager.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) else { continue }
            for url in items where url.pathExtension == "appex" {
                if Bundle(url: url)?.bundleIdentifier == Self.wallpaperExtensionID { return url }
            }
        }
        return nil
    }

    /// `true` when the extension is registered on the `com.apple.wallpaper` point.
    func isRegistered() async throws -> Bool {
        let result = try await runProcess("/usr/bin/pluginkit",
                                         ["-m", "-v", "-p", "com.apple.wallpaper"],
                                         timeout: timeouts.process)
        return PluginkitOutputParser.parse(result.output)
            .contains {
                $0.bundleIdentifier == Self.wallpaperExtensionID
                && ($0.status == nil || $0.status == "+" || $0.status == "?")
            }
    }

    /// Registers the bundled appex (`pluginkit -a`, then `-e use -i <id>`) and
    /// verifies the registration. Never touches the wallpaper store.
    func ensureRegistered() async throws {
        guard let appex = appexURL() else { throw LockScreenError.appexNotFoundInBundle }
        // pluginkit refuses quarantined bundles copied outside the App Store flow;
        // best-effort strip before registering (ignored when xattr is unavailable).
        _ = try? await runProcess("/usr/bin/xattr",
                                  ["-dr", "com.apple.quarantine", appex.path],
                                  timeout: timeouts.process)
        let add = try await runProcess("/usr/bin/pluginkit", ["-a", appex.path], timeout: timeouts.process)
        if add.status != 0 {
            throw PaperSaverError.pluginkitFailed(add.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let enable = try await runProcess("/usr/bin/pluginkit",
                                          ["-e", "use", "-i", Self.wallpaperExtensionID],
                                          timeout: timeouts.process)
        if enable.status != 0 {
            throw PaperSaverError.pluginkitFailed(enable.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard try await isRegistered() else {
            throw PaperSaverError.pluginkitFailed("\(Self.wallpaperExtensionID) is not registered after pluginkit -a")
        }
    }

    // MARK: - Apply / remove

    /// Writes the extension choice into the desktop role (everywhere, other slot
    /// kept): provider = extension id, configuration = wallpaperID utf8 bytes,
    /// files = [{relative: staged file absoluteString}].
    private func lockscreenChoice(wallpaperID: UUID) -> SlotConfiguration {
        let token = wallpaperID.uuidString.data(using: .utf8) ?? Data()
        let staged = stagedVideoURL(for: wallpaperID)
        let files: [PlistValue] = [.dictionary(["relative": .string(staged.absoluteString)])]
        return SlotConfiguration(
            choice: WallpaperChoice(
                provider: ChoiceProvider(rawValue: Self.wallpaperExtensionID),
                configuration: token,
                files: files),
            optionValues: .values(.image()),
            shuffle: .null)
    }

    private func verifyApplied(_ store: SystemWallpaperStore, wallpaperID: UUID) -> Bool {
        guard isUniformlyApplied(store) else { return false }
        guard let slot = store.slot(.desktop, in: .everywhere),
              let choice = slot.choices.first else { return false }
        guard choice.configuration == (wallpaperID.uuidString.data(using: .utf8) ?? Data()) else { return false }
        let expected = stagedVideoURL(for: wallpaperID).absoluteString
        guard let relative = choice.files.first?.dictionaryValue?["relative"]?.stringValue,
              relative == expected else { return false }
        return fileManager.fileExists(atPath: stagedVideoURL(for: wallpaperID).path)
    }

    /// Full user-initiated surgery: register, stage, backup-first double-write,
    /// agent restart, verify-after with rollback. Retries the write/restart/
    /// verify sequence up to 3 passes: the agent can flush its in-memory store
    /// over our edit, so a single pass can verify against a transitional file.
    /// No-op when this exact wallpaper is already applied everywhere.
    @discardableResult
    func applyLockscreen(video: URL, wallpaperID: UUID, title: String) async throws -> WriteOutcome {
        try await ensureRegistered()
        try stage(video: video, wallpaperID: wallpaperID, title: title)
        if let current = try? storeFile.read(), verifyApplied(current, wallpaperID: wallpaperID) {
            refresh()
            return .applied
        }
        _ = try await backupStore()
        var lastError: Error?
        var didRestore = false
        for _ in 1...3 {
            do {
                let snapshot = try storeFile.write(
                    try (try storeFile.read()).setting(.desktop, to: lockscreenChoice(wallpaperID: wallpaperID),
                                                       in: .everywhere, otherSlot: .keep))
                do {
                    // Double-write: the agent can rewrite the file around our restart; re-assert
                    // our edit (freshly stamped) on a fresh read after a short sleep.
                    try await Task.sleep(for: timeouts.doubleWriteSleep)
                    _ = try storeFile.write(
                        try (try storeFile.read()).setting(.desktop, to: lockscreenChoice(wallpaperID: wallpaperID),
                                                           in: .everywhere, otherSlot: .keep))
                    try await restartAgent()
                } catch {
                    try? storeFile.restore(snapshot)
                    try? await restartAgent()
                    refresh()
                    throw error
                }
                await settle()
                if try verifyAppliedStore(wallpaperID: wallpaperID) {
                    refresh()
                    if isApplied {
                        SettingsManager.shared.didAutoApplyLockscreen = true
                        SettingsManager.shared.didManualRemoveLockscreen = false
                    }
                    return await confirmExtensionLaunched()
                }
                lastError = PaperSaverError.verificationFailed(
                    expected: "\(Self.wallpaperExtensionID) as desktop everywhere", rolledBack: false)
                if (try? storeFile.restore(snapshot)) != nil {
                    didRestore = true
                }
                try? await restartAgent()
            } catch {
                lastError = error
            }
            refresh()
        }
        throw lastError ?? PaperSaverError.verificationFailed(
            expected: "\(Self.wallpaperExtensionID) as desktop everywhere", rolledBack: didRestore)
    }

    /// Verify against a freshly re-read store (not a stale in-memory copy).
    private func verifyAppliedStore(wallpaperID: UUID) throws -> Bool {
        verifyApplied(try storeFile.read(), wallpaperID: wallpaperID)
    }

    /// Silent first-run + follow-switch path: stage, then apply only if never
    /// auto-applied before (never fights a manual change afterwards).
    /// Concurrent callers coalesce onto one in-flight task (no agent-restart storms).
    private final class AutomaticSlot {
        var task: Task<Void, Never>?
    }
    private let automaticSlot = AutomaticSlot()
    private let automaticLock = NSLock()

    func ensureAutomatic(video: URL, wallpaperID: UUID, title: String) async {
        refresh()
        if isApplied { return }
        if SettingsManager.shared.didAutoApplyLockscreen {
            // Heal path only: never revert an explicit manual removal, and at
            // most once an hour so a flapping agent cannot restart-loop.
            guard !SettingsManager.shared.didManualRemoveLockscreen else { return }
            if let last = SettingsManager.shared.lastLockscreenAutoAttempt,
               Date().timeIntervalSince(last) < 3600 { return }
        }
        automaticLock.lock()
        if let running = automaticSlot.task {
            automaticLock.unlock()
            await running.value
            return
        }
        let created = Task { await self.runAutomaticOnce(video: video, wallpaperID: wallpaperID, title: title) }
        automaticSlot.task = created
        automaticLock.unlock()
        await created.value
        automaticLock.lock()
        if automaticSlot.task?.hashValue == created.hashValue { automaticSlot.task = nil }
        automaticLock.unlock()
    }

    private func runAutomaticOnce(video: URL, wallpaperID: UUID, title: String) async {
        do {
            guard (try? stage(video: video, wallpaperID: wallpaperID, title: title)) != nil else {
                return
            }
        } catch {
            return
        }
        refresh()
        guard !isApplied else { return }
        // First run, or heal path (ensureAutomatic already enforced the
        // manual-removal opt-out and the hourly attempt cap). Stamp the attempt
        // BEFORE applying so concurrent/rapid callers cannot stack agent restarts.
        SettingsManager.shared.lastLockscreenAutoAttempt = Date()
        do {
            let outcome = try await applyLockscreen(video: video, wallpaperID: wallpaperID, title: title)
        } catch {
        }
        refresh()
        if isApplied {
            SettingsManager.shared.didAutoApplyLockscreen = true
        }
    }

    /// Restores the newest pre-apply backup (backup-first: snapshots the
    /// current store before restoring), restarts the agent and verifies the
    /// extension is no longer the desktop provider. Falls back to clearing the
    /// desktop slot to the system default when no backup exists. The Idle slot
    /// is cleared only when it still points at Hazel (never touches the user's
    /// own screensaver choice).
    @discardableResult
    func removeLockscreen() async throws -> WriteOutcome {
        _ = try await backupStore()
        if let latest = latestBackup(excludingMostRecent: true),
           let data = try? Data(contentsOf: latest) {
            let snapshot = try? storeFile.readRaw()
            do {
                _ = try storeFile.writeRaw(data)
            } catch {
                throw PaperSaverError.plistWriteError("\(storeFile.url.path): \(error.localizedDescription)")
            }
            try await restartAgent()
            await settle()
            if let after = try? storeFile.read(),
               after.provider(of: .desktop, in: .everywhere) != ChoiceProvider(rawValue: Self.wallpaperExtensionID) {
                refresh()
                return .applied
            }
            var rolledBack = false
            if let snapshotData = snapshot {
                rolledBack = (try? storeFile.writeRaw(snapshotData)) != nil
                try? await restartAgent()
            }
            refresh()
            throw PaperSaverError.verificationFailed(
                expected: "desktop without \(Self.wallpaperExtensionID)", rolledBack: rolledBack)
        }
        var cleared = try (try storeFile.read()).clearing(.desktop, in: .everywhere)
        if let idle = try? storeFile.read(),
           idle.provider(of: .screensaver, in: .everywhere) == ChoiceProvider(rawValue: Self.wallpaperExtensionID) {
            cleared = try cleared.clearing(.screensaver, in: .everywhere)
        }
        let snapshot = try storeFile.write(cleared)
        try await restartAgent()
        await settle()
        if let after = try? storeFile.read(),
           after.provider(of: .desktop, in: .everywhere) != ChoiceProvider(rawValue: Self.wallpaperExtensionID) {
            refresh()
            if isApplied == false {
                SettingsManager.shared.didManualRemoveLockscreen = true
            }
            return .applied
        }
        var rolledBack = false
        do {
            try storeFile.restore(snapshot)
            rolledBack = true
        } catch {
            rolledBack = false
        }
        try? await restartAgent()
        refresh()
        throw PaperSaverError.verificationFailed(
            expected: "desktop without \(Self.wallpaperExtensionID)", rolledBack: rolledBack)
    }

    private func confirmExtensionLaunched() async -> WriteOutcome {
        var attempt = 0
        while true {
            if await WallpaperAgent().waitForExtension(
                bundleIdentifier: Self.wallpaperExtensionID, timeout: timeouts.extensionLaunch) {
                return .applied
            }
            guard attempt < timeouts.extensionRelaunchAttempts else {
                return .appliedButExtensionNotRunning
            }
            attempt += 1
            try? await restartAgent()
            await settle()
        }
    }

    // MARK: - Backups

    private var lockscreenBackupDir: URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("LiveWallpaper/LockScreenStoreBackups", isDirectory: true)
    }

    /// Copies the current store bytes (when present) into the lockscreen backup
    /// directory. Reads are stabilized first: the agent rewrites this file from
    /// memory, and backing up a half-written stub would poison restores.
    /// Called before every destructive step; throws before anything is written
    /// when the copy fails.
    @discardableResult
    func backupStore() async throws -> URL? {
        guard let data = try? await awaitStableStoreBytes() else { return nil }
        try fileManager.createDirectory(at: lockscreenBackupDir, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let url = lockscreenBackupDir
            .appendingPathComponent("Index-\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(8)).plist")
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw PaperSaverError.plistWriteError("\(url.path): backup failed: \(error.localizedDescription)")
        }
        pruneBackups(keeping: 5)
        return url
    }

    /// Reads the store until two consecutive reads agree (or ~3s passes).
    /// Returns nil when the store cannot be read at all.
    private func awaitStableStoreBytes() async throws -> Data? {
        var previous: Data?
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            let current = try? storeFile.readRaw()
            if let current, current == previous {
                return current
            }
            previous = current
            try? await Task.sleep(for: .milliseconds(500))
        }
        return previous
    }
    private func sortedBackups() -> [URL] {
        let urls = ((try? fileManager.contentsOfDirectory(
            at: lockscreenBackupDir, includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles)) ?? [])
            .filter { $0.pathExtension == "plist" }
        return urls.sorted {
            let d0 = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
            let d1 = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
            if d0 != d1 { return d0 < d1 }
            return $0.lastPathComponent < $1.lastPathComponent
        }
    }

    /// Newest backup, optionally skipping the one `backupStore()` just wrote so
    /// `removeLockscreen` restores the pre-apply surface.
    func latestBackup(excludingMostRecent: Bool = false) -> URL? {
        let all = sortedBackups()
        guard !all.isEmpty else { return nil }
        if excludingMostRecent, all.count > 1 { return all[all.count - 2] }
        if excludingMostRecent { return nil }
        return all.last
    }

    private func pruneBackups(keeping: Int) {
        let all = sortedBackups()
        guard all.count > keeping else { return }
        for url in all.prefix(all.count - keeping) {
            try? fileManager.removeItem(at: url)
        }
    }

    // MARK: - Agent control (bounded)

    private func restartAgent() async throws {
        let before = WallpaperAgent.runningProcessIdentifiers()
        let result = try await runProcess("/usr/bin/killall", [WallpaperAgent.processName],
                                          timeout: timeouts.process)
        // killall exits 1 when no process matched; the agent starts on demand anyway.
        guard result.status == 0 || result.status == 1 else {
            throw PaperSaverError.agentRestartFailed(
                "killall exited \(result.status)\(result.output.isEmpty ? "" : ": \(result.output)")")
        }
        do {
            try await waitForRespawn(notIn: before, timeout: timeouts.respawn)
        } catch {
            // Continue like the vendored writer: the agent may already be settling.
        }
    }

    private func waitForRespawn(notIn before: Set<pid_t>, timeout: Duration) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let now = WallpaperAgent.runningProcessIdentifiers()
            if !now.isEmpty, now.isDisjoint(with: before) { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw PaperSaverError.agentRestartFailed("no new WallpaperAgent process within \(timeout)")
    }

    private func settle() async {
        let deadline = ContinuousClock.now + timeouts.settle
        var last = storeFile.modificationStamp()
        var stableSince = ContinuousClock.now
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
            let stamp = storeFile.modificationStamp()
            if stamp != last {
                last = stamp
                stableSince = ContinuousClock.now
            } else if ContinuousClock.now - stableSince >= timeouts.quietPeriod {
                return
            }
        }
    }

    // MARK: - Processes (bounded)

    struct ProcessResult: Sendable {
        var status: Int32
        var output: String
    }

    /// Runs an executable from an absolute path with a hard timeout. Stdout +
    /// stderr are drained continuously (no pipe deadlock on chatty tools) and the
    /// process is terminated when the timeout fires, with a SIGKILL-grade grace
    /// wait before giving up and reporting the timeout.
    func runProcess(_ executable: String, _ arguments: [String], timeout: Duration) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        var output = Data()
        let outputLock = NSLock()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty {
                outputLock.lock()
                output.append(chunk)
                outputLock.unlock()
            }
        }
        defer { pipe.fileHandleForReading.readabilityHandler = nil }
        do {
            try process.run()
        } catch {
            throw LockScreenError.processFailed(executable: executable, status: -1,
                                                output: error.localizedDescription)
        }
        let deadline = ContinuousClock.now + timeout
        while process.isRunning {
            if ContinuousClock.now >= deadline {
                process.terminate()
                let grace = ContinuousClock.now + .seconds(1)
                while process.isRunning, ContinuousClock.now < grace {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                if process.isRunning {
                    process.interrupt()
                    try? await Task.sleep(for: .milliseconds(500))
                }
                throw LockScreenError.processTimeout(executable: executable)
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        outputLock.lock()
        let text = String(decoding: output, as: UTF8.self)
        outputLock.unlock()
        return ProcessResult(status: process.terminationStatus,
                             output: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
