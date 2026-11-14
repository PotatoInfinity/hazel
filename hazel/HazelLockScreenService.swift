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
        /// Delay between the first verify pass and the mandatory re-read
        /// (H1: the agent can flush its in-memory store over our edit after
        /// the first read, so a single verify can pass on a transitional file).
        var verifyReReadDelay: Duration = .seconds(1)
        /// Extra settle after the final verify so the first frame composites
        /// before a locked/idle presentation arrives (H2). Additive only;
        /// existing waits are never shortened.
        var postVerifySettle: Duration = .seconds(2)
    }

    var timeouts = Timeouts()

    /// Sync mirror of the store state for UI rows; call `refresh()` to update.
    private(set) var isApplied = false

    private let fileManager = FileManager.default
    private let storeFile = StoreFile()

    /// Serializes every store-write + agent-restart sequence (manual apply,
    /// automatic apply, remove, restore) so switch storms and watchdog heals
    /// can never interleave writes and killalls (H3). Async handoff: the lock
    /// is only held to check/transfer ownership, never across awaits.
    /// Cancellable wait: a superseded switch waiting here aborts (throws
    /// CancellationError) instead of running a stale apply behind the newer
    /// video. Cancelled waiters are removed from the queue so they never
    /// block or leak.
    private final class ApplyGateWaiter {
        var continuation: CheckedContinuation<Void, Error>?
        var resumed = false
    }
    private let applyGateLock = NSLock()
    private var applyGateActive = false
    private var applyGateWaiters: [ApplyGateWaiter] = []

    private func acquireApplyGate() async throws {
        if Task.isCancelled { throw CancellationError() }
        let waiter = ApplyGateWaiter()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                var immediate: Result<Void, Error>? = nil
                self.applyGateLock.withLock {
                    if Task.isCancelled {
                        immediate = .failure(CancellationError())
                    } else if !self.applyGateActive {
                        self.applyGateActive = true
                        immediate = .success(())
                    } else {
                        waiter.continuation = continuation
                        self.applyGateWaiters.append(waiter)
                    }
                }
                if let immediate {
                    switch immediate {
                    case .success: continuation.resume()
                    case .failure(let error): continuation.resume(throwing: error)
                    }
                }
            }
        }, onCancel: {
            var toResume: CheckedContinuation<Void, Error>? = nil
            self.applyGateLock.withLock {
                if waiter.resumed { return }
                guard waiter.continuation != nil else { return }
                if let index = self.applyGateWaiters.firstIndex(where: { $0 === waiter }) {
                    self.applyGateWaiters.remove(at: index)
                    waiter.resumed = true
                    toResume = waiter.continuation
                    waiter.continuation = nil
                }
            }
            toResume?.resume(throwing: CancellationError())
        })
        // A cancel that lands after handoff (release already transferred
        // ownership) must not run a stale apply behind the newer video.
        if Task.isCancelled {
            releaseApplyGate()
            throw CancellationError()
        }
    }

    private func releaseApplyGate() {
        let next: ApplyGateWaiter? = applyGateLock.withLock {
            if applyGateWaiters.isEmpty {
                applyGateActive = false
                return nil
            }
            // Ownership transfers to the waiter; stays active.
            let waiter = applyGateWaiters.removeFirst()
            waiter.resumed = true
            return waiter
        }
        if let continuation = next?.continuation {
            next?.continuation = nil
            continuation.resume()
        }
    }

    /// Serializes every extension-container mutation (video copy, stale sweep,
    /// library.json + prefs rewrite + Darwin notifies) so concurrent stages
    /// (followSwitch vs apply vs automatic) can never interleave copies and
    /// sweeps (one stage deleting another's file) or race library.json.
    /// FIFO, never-drop: waits ignore cancellation so every video switch
    /// stages exactly once in arrival order. Separate from the apply gate
    /// (which serializes store writes + killalls): stages never block on long
    /// agent restarts, and store writes never block on file copies beyond the
    /// brief stage critical section.
    private let stageGateLock = NSLock()
    private var stageGateActive = false
    private var stageGateWaiters: [CheckedContinuation<Void, Never>] = []

    private func acquireStageGate() async {
        while true {
            let shouldWait: Bool = stageGateLock.withLock {
                if !stageGateActive {
                    stageGateActive = true
                    return false
                }
                return true
            }
            if !shouldWait { return }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let takeNow: Bool = stageGateLock.withLock {
                    // Re-check under the lock: the gate may have been released
                    // between the check above and now.
                    if !stageGateActive {
                        stageGateActive = true
                        return true
                    }
                    stageGateWaiters.append(continuation)
                    return false
                }
                if takeNow { continuation.resume() }
            }
        }
    }

    private func releaseStageGate() {
        let next: CheckedContinuation<Void, Never>? = stageGateLock.withLock {
            if stageGateWaiters.isEmpty {
                stageGateActive = false
                return nil
            }
            // Ownership transfers to the waiter; stays active.
            return stageGateWaiters.removeFirst()
        }
        next?.resume()
    }

    /// LSUIElement apps lose stdout; every failure path must NSLog with this
    /// stable tag so the next blackout is diagnosable from Console.app (H5).
    private func lsLog(_ message: String) {
        NSLog("[HazelLockScreen] %@", message)
    }

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
    /// single check can miss a per-Space override; we walk them all.
    /// Single-sourced with `nonUniformSectionKeys(_:)` so the boolean and the
    /// logged key list can never disagree.
    private func isUniformlyApplied(_ store: SystemWallpaperStore) -> Bool {
        nonUniformSectionKeys(store).isEmpty
    }

    /// `(section key, observed provider)` for every desktop-rendering section
    /// that does NOT point at our extension. Keys mirror the store layout so a
    /// blackout names the exact override (e.g. `Spaces/<uuid>/Displays/<uuid>`).
    /// Sections with no desktop/linked choice (idle-only) are neutral, matching
    /// `isUniformlyApplied`.
    private func nonUniformSectionKeys(_ store: SystemWallpaperStore) -> [(key: String, provider: String)] {
        let ours = ChoiceProvider(rawValue: Self.wallpaperExtensionID)
        var mismatched: [(key: String, provider: String)] = []
        func check(key: String, section: StoreSection?) {
            guard let section else { return }
            if let desktop = section.desktop, let provider = desktop.provider {
                if provider.isPlaceholder { return }
                if provider != ours { mismatched.append((key, provider.rawValue)) }
            } else if let linked = section.linked?.provider, !linked.isPlaceholder {
                if linked != ours { mismatched.append((key, linked.rawValue)) }
            }
        }
        check(key: "AllSpacesAndDisplays", section: store.allSpacesAndDisplays)
        check(key: "SystemDefault", section: store.systemDefault)
        for (spaceUUID, entry) in store.spaces {
            if let def = entry.default {
                check(key: "Spaces/\(spaceUUID)/Default", section: def)
            }
            for (displayUUID, section) in entry.displays {
                check(key: "Spaces/\(spaceUUID)/Displays/\(displayUUID)", section: section)
            }
        }
        for (displayUUID, section) in store.displays {
            check(key: "Displays/\(displayUUID)", section: section)
        }
        return mismatched
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
    /// Serialized through the stage gate: the check, copy, sweep and
    /// library rewrite are one atomic critical section, so concurrent stages
    /// can never interleave copies/sweeps or race library.json. FIFO and
    /// never-drop (waits ignore cancellation) so every switch stages exactly
    /// once in arrival order.
    ///
    /// NOTE: `videoFilename` is the bare basename — the extension prunes any
    /// entry containing "/" (path traversal guard); a subpath never resolves.
    @discardableResult
    func stage(video: URL, wallpaperID: UUID, title: String) async throws -> Bool {
        await acquireStageGate()
        defer { releaseStageGate() }
        let dest = stagedVideoURL(for: wallpaperID)
        if isStagedCurrent(video: video, wallpaperID: wallpaperID) {
            // Bytes unchanged, but library.json + notifications are the
            // extension's retarget signal: a missed notification or a pruned
            // library.json would otherwise desync the appex (black at lock)
            // while the skip predicate stays true. Re-assert cheaply.
            // TOCTOU: re-check the file still exists — it may have vanished
            // between the predicate and now; fall through to a full copy then.
            guard fileManager.fileExists(atPath: dest.path) else {
                lsLog("stage skip raced file missing id=\(wallpaperID.uuidString.prefix(8)) falling through to full copy")
                // Fall through to the full copy below.
                return try stageUnconditionally(video: video, wallpaperID: wallpaperID, title: title)
            }
            try writeLibraryAndPrefs(title: title, dest: dest)
            lsLog("stage skip bytes unchanged id=\(wallpaperID.uuidString.prefix(8)) re-asserted library+notify stagedExists=true")
            return false
        }
        return try stageUnconditionally(video: video, wallpaperID: wallpaperID, title: title)
    }

    /// Full copy + sweep + library/prefs rewrite + notifications. Factored so
    /// the skip path above can fall through here on a TOCTOU loss.
    private func stageUnconditionally(video: URL, wallpaperID: UUID, title: String) throws -> Bool {
        let dest = stagedVideoURL(for: wallpaperID)
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
        try writeLibraryAndPrefs(title: title, dest: dest)
        return true
    }

    /// Atomic library.json + prefs rewrite plus both Darwin notifications.
    /// Cheap (two tiny JSON writes + two notifies) so the skip path calls it
    /// on every switch even when the video bytes are unchanged.
    private func writeLibraryAndPrefs(title: String, dest: URL) throws {
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
    ///
    /// Serialized with ensureAutomatic/removeLockscreen through the apply gate
    /// (H3): concurrent callers wait, then re-check the no-op fast path, so
    /// writes and killalls never interleave.
    @discardableResult
    func applyLockscreen(video: URL, wallpaperID: UUID, title: String) async throws -> WriteOutcome {
        try await acquireApplyGate()
        defer { releaseApplyGate() }
        return try await performApplyLockscreen(video: video, wallpaperID: wallpaperID, title: title)
    }

    private func performApplyLockscreen(video: URL, wallpaperID: UUID, title: String) async throws -> WriteOutcome {
        lsLog("apply start id=\(wallpaperID.uuidString.prefix(8)) title=\(title)")
        try await ensureRegistered()
        try await stage(video: video, wallpaperID: wallpaperID, title: title)
        // Fast path with re-verify (H1): a single read can hit a transitional
        // file the agent is mid-rewrite on.
        if let current = try? storeFile.read(), verifyApplied(current, wallpaperID: wallpaperID) {
            try? await Task.sleep(for: timeouts.verifyReReadDelay)
            if let second = try? storeFile.read(), verifyApplied(second, wallpaperID: wallpaperID) {
                // Fast-path health: store bytes alone do not prove the agent
                // instantiated the extension. A dead extension + correct bytes
                // still reads black at lock, so fall through to the full pass
                // (bounded relaunch) instead of returning success.
                let fastRunning = WallpaperAgent.runningExtensionBundleIdentifiers()
                    .contains(Self.wallpaperExtensionID)
                if fastRunning {
                    lsLog("apply fast-path hit id=\(wallpaperID.uuidString.prefix(8)) already applied (double-verified) extensionRunning=true")
                    refresh()
                    if isApplied {
                        SettingsManager.shared.didAutoApplyLockscreen = true
                        SettingsManager.shared.didManualRemoveLockscreen = false
                    }
                    return .applied
                }
                lsLog("apply fast-path store verified but extension not running id=\(wallpaperID.uuidString.prefix(8)) detail=\(describeMismatch(second, wallpaperID: wallpaperID)) falling through to full apply")
            } else {
                let secondStore = try? storeFile.read()
                lsLog("apply fast-path re-verify failed id=\(wallpaperID.uuidString.prefix(8)) detail=\(describeMismatch(secondStore, wallpaperID: wallpaperID)) falling through to full apply")
            }
        }
        _ = try await backupStore()
        var lastError: Error?
        var didRestore = false
        // Outer pre-apply image for rollback: every verify failure restores to
        // the state before this apply began, not to a per-pass snapshot that
        // may itself be a failed edit. Captured from a stable read so a
        // half-written stub never becomes the rollback target (H4).
        let outerSnapshot: StoreSnapshot
        do {
            outerSnapshot = StoreSnapshot(previousContents: try await requireStableStore().raw, capturedAt: Date())
        } catch {
            lsLog("apply abort: no stable pre-apply snapshot error=\(error.localizedDescription)")
            throw error
        }
        for pass in 1...3 {
            lsLog("apply pass \(pass)/3 start id=\(wallpaperID.uuidString.prefix(8))")
            do {
                // Re-stage every pass (cheap re-assert when current): a
                // concurrent followSwitch sweep may have deleted our file
                // after the previous pass, and the store edit below must never
                // reference a missing file.
                try await stage(video: video, wallpaperID: wallpaperID, title: title)
                // Snapshot ONLY from a stable read (H4): restoring bytes taken
                // during an agent rewrite would install a half-written stub and
                // black-screen where the previous surface was fine. Abort the
                // pass before writing anything when the store never quiesces.
                let stable: (store: SystemWallpaperStore, raw: Data)
                do {
                    stable = try await requireStableStore()
                } catch {
                    lsLog("apply pass \(pass)/3 no stable read, aborting before write error=\(error.localizedDescription)")
                    throw error
                }
                _ = try storeFile.write(
                    try stable.store.setting(.desktop, to: lockscreenChoice(wallpaperID: wallpaperID),
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
                    do {
                        try storeFile.restore(outerSnapshot)
                        didRestore = true
                        lsLog("apply pass \(pass)/3 write/restart failed, restored pre-apply snapshot error=\(error.localizedDescription)")
                    } catch {
                        didRestore = false
                        lsLog("apply pass \(pass)/3 write/restart failed AND rollback failed error=\(error.localizedDescription)")
                    }
                    try? await restartAgent()
                    refresh()
                    throw error
                }
                await settle()
                // First verify on a fresh read.
                let firstStore = try? storeFile.read()
                guard let first = firstStore, verifyApplied(first, wallpaperID: wallpaperID) else {
                    let detail = describeMismatch(firstStore, wallpaperID: wallpaperID)
                    lsLog("apply pass \(pass)/3 first verify FAILED observed vs expected: \(detail)")
                    lastError = PaperSaverError.verificationFailed(
                        expected: "\(Self.wallpaperExtensionID) as desktop everywhere", rolledBack: false)
                    do {
                        try storeFile.restore(outerSnapshot)
                        didRestore = true
                        lsLog("apply pass \(pass)/3 rolled back to pre-apply snapshot")
                    } catch {
                        didRestore = false
                        lsLog("apply pass \(pass)/3 rollback FAILED error=\(error.localizedDescription)")
                    }
                    try? await restartAgent()
                    refresh()
                    continue
                }
                lsLog("apply pass \(pass)/3 first verify passed, re-reading after \(timeouts.verifyReReadDelay)")
                // H1: the agent can rewrite AFTER our verify read; sleep and
                // RE-READ before declaring success.
                try? await Task.sleep(for: timeouts.verifyReReadDelay)
                let secondStore = try? storeFile.read()
                guard let second = secondStore, verifyApplied(second, wallpaperID: wallpaperID) else {
                    let detail = describeMismatch(secondStore, wallpaperID: wallpaperID)
                    lsLog("apply pass \(pass)/3 re-verify FAILED observed vs expected: \(detail)")
                    lastError = PaperSaverError.verificationFailed(
                        expected: "\(Self.wallpaperExtensionID) as desktop everywhere (stable re-read)", rolledBack: false)
                    do {
                        try storeFile.restore(outerSnapshot)
                        didRestore = true
                        lsLog("apply pass \(pass)/3 rolled back to pre-apply snapshot after re-verify failure")
                    } catch {
                        didRestore = false
                        lsLog("apply pass \(pass)/3 rollback FAILED error=\(error.localizedDescription)")
                    }
                    try? await restartAgent()
                    refresh()
                    continue
                }
                lsLog("apply pass \(pass)/3 re-verify passed, confirming extension launch")
                let outcome = await confirmExtensionLaunched()
                let runningAfterConfirm = WallpaperAgent.runningExtensionBundleIdentifiers()
                    .contains(Self.wallpaperExtensionID)
                // H2 pre-warm: the extension process existing does not mean its
                // first frame has composited; a locked/idle presentation in the
                // gap reads as black. No cheap first-frame signal is observable
                // from the app, so extend the settle (additive; existing waits
                // untouched) before the final gate.
                try? await Task.sleep(for: timeouts.postVerifySettle)
                let extensionStillRunning = WallpaperAgent.runningExtensionBundleIdentifiers()
                    .contains(Self.wallpaperExtensionID)
                let finalStore = try? storeFile.read()
                let finalStoreOK: Bool
                if let final = finalStore {
                    finalStoreOK = verifyApplied(final, wallpaperID: wallpaperID)
                } else {
                    finalStoreOK = false
                }
                // Post-verify health with teeth: BOTH the process and a fresh
                // store read must hold. Either failing retries the pass
                // (bounded by the 3-pass loop) with WHICH check named — a black
                // lockscreen must never be reported as success.
                guard outcome == .applied, runningAfterConfirm, extensionStillRunning else {
                    let detail = describeMismatch(finalStore, wallpaperID: wallpaperID)
                    lsLog("apply pass \(pass)/3 extension health FAILED outcome=\(outcome) runningAfterConfirm=\(runningAfterConfirm) stillRunning=\(extensionStillRunning) finalStoreOK=\(finalStoreOK) detail: \(detail)")
                    lastError = PaperSaverError.verificationFailed(
                        expected: "\(Self.wallpaperExtensionID) extension running (post-confirm)", rolledBack: false)
                    do {
                        try storeFile.restore(outerSnapshot)
                        didRestore = true
                        lsLog("apply pass \(pass)/3 rolled back to pre-apply snapshot after extension health failure")
                    } catch {
                        didRestore = false
                        lsLog("apply pass \(pass)/3 rollback FAILED error=\(error.localizedDescription)")
                    }
                    try? await restartAgent()
                    refresh()
                    continue
                }
                guard finalStoreOK, let final = finalStore, verifyApplied(final, wallpaperID: wallpaperID) else {
                    let detail = describeMismatch(finalStore, wallpaperID: wallpaperID)
                    lsLog("apply pass \(pass)/3 final verify after extension confirm FAILED outcome=\(outcome) stillRunning=\(extensionStillRunning) detail: \(detail)")
                    lastError = PaperSaverError.verificationFailed(
                        expected: "\(Self.wallpaperExtensionID) as desktop everywhere (post-confirm)", rolledBack: false)
                    do {
                        try storeFile.restore(outerSnapshot)
                        didRestore = true
                        lsLog("apply pass \(pass)/3 rolled back to pre-apply snapshot after final verify failure")
                    } catch {
                        didRestore = false
                        lsLog("apply pass \(pass)/3 rollback FAILED error=\(error.localizedDescription)")
                    }
                    try? await restartAgent()
                    refresh()
                    continue
                }
                lsLog("apply pass \(pass)/3 SUCCESS outcome=\(outcome) extensionStillRunning=\(extensionStillRunning) finalStoreOK=\(finalStoreOK) provider=\(Self.wallpaperExtensionID)")
                refresh()
                if isApplied {
                    SettingsManager.shared.didAutoApplyLockscreen = true
                    SettingsManager.shared.didManualRemoveLockscreen = false
                }
                return outcome
            } catch {
                // A superseded apply must not spin the remaining passes: roll
                // back to the pre-apply image (best-effort) and propagate so
                // the gate releases immediately for the newer video.
                if error is CancellationError {
                    lsLog("apply pass \(pass)/3 cancelled, restoring pre-apply snapshot")
                    do {
                        try storeFile.restore(outerSnapshot)
                        didRestore = true
                    } catch {
                        didRestore = false
                    }
                    try? await restartAgent()
                    refresh()
                    throw error
                }
                lastError = error
            }
            refresh()
        }
        lsLog("apply give-up id=\(wallpaperID.uuidString.prefix(8)) error=\(lastError?.localizedDescription ?? "unknown") rolledBack=\(didRestore)")
        throw lastError ?? PaperSaverError.verificationFailed(
            expected: "\(Self.wallpaperExtensionID) as desktop everywhere", rolledBack: didRestore)
    }

    /// Verify against a freshly re-read store (not a stale in-memory copy).
    private func verifyAppliedStore(wallpaperID: UUID) throws -> Bool {
        verifyApplied(try storeFile.read(), wallpaperID: wallpaperID)
    }

    /// Stable store + the raw bytes it decoded from. Throws when the file
    /// never quiesces within the bound — callers must abort BEFORE writing.
    /// Throws CancellationError promptly so a superseded apply holding the
    /// gate releases it instead of blocking the newer video.
    private func requireStableStore() async throws -> (store: SystemWallpaperStore, raw: Data) {
        var previous: Data?
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            if Task.isCancelled { throw CancellationError() }
            let current = try? storeFile.readRaw()
            if let current, current == previous {
                if let store = try? storeFile.read() {
                    return (store, current)
                }
                throw PaperSaverError.plistReadError("stable bytes do not decode; aborting before write")
            }
            previous = current
            try? await Task.sleep(for: .milliseconds(500))
        }
        throw PaperSaverError.plistReadError("no stable store read within bound; aborting before write")
    }

    /// One-line observed-vs-expected for every verify failure (H5).
    private func describeMismatch(_ store: SystemWallpaperStore?, wallpaperID: UUID) -> String {
        let expectedProvider = Self.wallpaperExtensionID
        let expectedRelative = stagedVideoURL(for: wallpaperID).absoluteString
        guard let store else { return "store unreadable, expected provider=\(expectedProvider) relative=\(expectedRelative)" }
        let mismatched = nonUniformSectionKeys(store)
        let uniform = mismatched.isEmpty
        let mismatchKeys = mismatched.map { "\($0.key)=\($0.provider)" }.joined(separator: ",")
        let everywhereProvider = store.provider(of: .desktop, in: .everywhere)?.rawValue ?? "nil"
        var slotDetail = "slot-missing"
        if let slot = store.slot(.desktop, in: .everywhere), let choice = slot.choices.first {
            let configOK = choice.configuration == (wallpaperID.uuidString.data(using: .utf8) ?? Data())
            let relative = choice.files.first?.dictionaryValue?["relative"]?.stringValue ?? "nil"
            slotDetail = "provider=\(choice.provider.rawValue) configOK=\(configOK) relative=\(relative)"
        }
        let stagedExists = fileManager.fileExists(atPath: stagedVideoURL(for: wallpaperID).path)
        return "uniform=\(uniform) mismatched=[\(mismatchKeys)] everywhere=\(everywhereProvider) \(slotDetail) expectedProvider=\(expectedProvider) expectedRelative=\(expectedRelative) stagedExists=\(stagedExists)"
    }

    /// Silent first-run + follow-switch path: stage, then apply only if never
    /// auto-applied before (never fights a manual change afterwards).
    /// Serialization is via the gates, not via slot tasks: stages serialize
    /// through the stage gate (FIFO, never-drop), store writes + restarts
    /// serialize through the cancellable apply gate inside applyLockscreen
    /// (H3). No slot means no dropped switches, no waiter leaks, and no
    /// identity-clearing races: concurrent callers simply queue on the gates
    /// and the fast-path re-checks inside the gates collapse duplicates.

    /// Immediate per-switch staging (the lockscreen half of "swap immediately").
    /// Called on EVERY wallpaper switch so the video lockscreen retargets at
    /// once. `ensureAutomatic` below returns early once the extension is
    /// applied (provider check only), so without this path no switch after the
    /// first would ever reach the extension container.
    ///
    /// Copies the new video into the extension container and re-asserts
    /// library.json + the Darwin retarget notification. Never touches the
    /// wallpaper store and never (re-)applies: first-apply and healing stay in
    /// ensureAutomatic/runAutomaticOnce, whose manual-removal opt-out and
    /// hourly cap are untouched.
    ///
    /// Never-drop: waits ignore cancellation and every call stages exactly
    /// once in FIFO arrival order (stage gate). A cancelled (superseded)
    /// switch still stages — cheap when superseded (the newer switch stages
    /// right after and wins) and required when it is the latest (otherwise the
    /// container would keep the previous video while the desktop shows the
    /// new one: stale video).
    func followSwitch(video: URL, wallpaperID: UUID, title: String) async {
        do {
            let changed = try await stage(video: video, wallpaperID: wallpaperID, title: title)
            lsLog("followSwitch staged id=\(wallpaperID.uuidString.prefix(8)) changed=\(changed)")
        } catch {
            // CancellationError cannot occur (stage gate waits ignore cancel
            // and file ops do not check it); any other error is a real copy
            // failure that the next switch/heal will retry.
            if error is CancellationError {
                lsLog("followSwitch cancelled but staged anyway id=\(wallpaperID.uuidString.prefix(8))")
                return
            }
            lsLog("followSwitch stage failed id=\(wallpaperID.uuidString.prefix(8)) error=\(error.localizedDescription)")
        }
    }

    func ensureAutomatic(video: URL, wallpaperID: UUID, title: String) async {
        // Steady-state fast path: cached applied needs no store re-read.
        // Drift (external deselect) is healed by the watchdog/menu refresh;
        // per-switch re-reads were pure plist cost on every switch.
        if isApplied { return }
        refresh()
        if isApplied { return }
        if SettingsManager.shared.didAutoApplyLockscreen {
            // Heal path only: never revert an explicit manual removal, and at
            // most once an hour so a flapping agent cannot restart-loop.
            // A manual removal is the ONLY opt-out; a failed auto attempt must
            // NOT consume the hourly slot (runAutomaticOnce clears the stamp on
            // failure), so a black lockscreen keeps healing.
            if SettingsManager.shared.didManualRemoveLockscreen {
                lsLog("automatic skip manual opt-out id=\(wallpaperID.uuidString.prefix(8))")
                return
            }
            if let last = SettingsManager.shared.lastLockscreenAutoAttempt,
               Date().timeIntervalSince(last) < 3600 {
                lsLog("automatic skip cooldown id=\(wallpaperID.uuidString.prefix(8)) elapsed=\(Int(Date().timeIntervalSince(last)))s")
                return
            }
        }
        // No slot queue: concurrent callers serialize on the gates. Same-video
        // duplicates collapse on the fast-path re-checks inside
        // runAutomaticOnce/performApplyLockscreen (no extra writes/killalls);
        // different videos apply serially, last wins, none dropped.
        // A superseded (cancelled) caller aborts here to avoid stacking
        // restarts behind the newer video; the newer video's own call still
        // runs.
        if Task.isCancelled { return }
        await runAutomaticOnce(video: video, wallpaperID: wallpaperID, title: title)
    }

    private func runAutomaticOnce(video: URL, wallpaperID: UUID, title: String) async {
        if Task.isCancelled { return }
        do {
            _ = try await stage(video: video, wallpaperID: wallpaperID, title: title)
        } catch {
            if error is CancellationError { return }
            lsLog("automatic stage failed id=\(wallpaperID.uuidString.prefix(8)) error=\(error.localizedDescription)")
            return
        }
        if Task.isCancelled { return }
        refresh()
        if isApplied {
            lsLog("automatic skip already applied id=\(wallpaperID.uuidString.prefix(8))")
            return
        }
        // First run, or heal path (ensureAutomatic already enforced the
        // manual-removal opt-out and the hourly attempt cap). The attempt stamp
        // is written ONLY on success: a failed attempt must not poison the
        // hourly slot, or the lockscreen stays black for an hour. Restart
        // storms are absorbed by the cancellable apply gate (superseded
        // waiters abort instead of stacking killalls), not by pre-stamping.
        do {
            // applyLockscreen takes the shared apply gate, so a manual click
            // racing this heal serializes instead of interleaving killalls.
            // A superseded waiter throws CancellationError here and aborts
            // without writing; the newer video's call proceeds serially.
            let outcome = try await applyLockscreen(video: video, wallpaperID: wallpaperID, title: title)
            lsLog("automatic apply done id=\(wallpaperID.uuidString.prefix(8)) outcome=\(outcome)")
        } catch {
            if error is CancellationError {
                lsLog("automatic apply superseded id=\(wallpaperID.uuidString.prefix(8)) (cancelled while queued)")
                return
            }
            // Clear the stamp so the next watchdog/switch tick retries soon
            // instead of sitting out the hourly cooldown while black.
            SettingsManager.shared.lastLockscreenAutoAttempt = nil
            lsLog("automatic apply failed id=\(wallpaperID.uuidString.prefix(8)) error=\(error.localizedDescription) clearedAttemptStamp=true")
        }
        refresh()
        if isApplied {
            SettingsManager.shared.didAutoApplyLockscreen = true
            SettingsManager.shared.lastLockscreenAutoAttempt = Date()
            lsLog("automatic heal stamped id=\(wallpaperID.uuidString.prefix(8)) didAutoApply=true")
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
        try await acquireApplyGate()
        defer { releaseApplyGate() }
        return try await performRemoveLockscreen()
    }

    private func performRemoveLockscreen() async throws -> WriteOutcome {
        lsLog("remove start")
        _ = try await backupStore()
        if let latest = latestBackup(excludingMostRecent: true),
           let data = try? Data(contentsOf: latest) {
            // Snapshot ONLY from a stable read (H4); restoring an unstable
            // pre-image would black-screen where the current surface was fine.
            let stableRaw: Data?
            do {
                stableRaw = try await requireStableStore().raw
            } catch {
                lsLog("remove abort: no stable read before restore error=\(error.localizedDescription)")
                throw error
            }
            let stableSnapshot = StoreSnapshot(previousContents: stableRaw, capturedAt: Date())
            do {
                _ = try storeFile.writeRaw(data)
            } catch {
                lsLog("remove restore backup failed error=\(error.localizedDescription)")
                throw PaperSaverError.plistWriteError("\(storeFile.url.path): \(error.localizedDescription)")
            }
            try await restartAgent()
            await settle()
            if let after = try? storeFile.read(),
               after.provider(of: .desktop, in: .everywhere) != ChoiceProvider(rawValue: Self.wallpaperExtensionID) {
                let observed = after.provider(of: .desktop, in: .everywhere)?.rawValue ?? "nil"
                lsLog("remove success via backup restore observed=\(observed)")
                refresh()
                if isApplied == false {
                    SettingsManager.shared.didManualRemoveLockscreen = true
                }
                return .applied
            }
            let observed = (try? storeFile.read())?.provider(of: .desktop, in: .everywhere)?.rawValue ?? "unreadable"
            lsLog("remove verify FAILED still points at extension observed=\(observed), rolling back to stable snapshot")
            var rolledBack = false
            do {
                try storeFile.restore(stableSnapshot)
                rolledBack = true
                lsLog("remove rolled back to stable snapshot")
            } catch {
                lsLog("remove rollback FAILED error=\(error.localizedDescription)")
            }
            try? await restartAgent()
            refresh()
            throw PaperSaverError.verificationFailed(
                expected: "desktop without \(Self.wallpaperExtensionID)", rolledBack: rolledBack)
        }
        // Fallback: clear to system default. Base the edit on a stable read
        // and keep its bytes as the rollback image (H4).
        let stable: (store: SystemWallpaperStore, raw: Data)
        do {
            stable = try await requireStableStore()
        } catch {
            lsLog("remove abort: no stable read before clear error=\(error.localizedDescription)")
            throw error
        }
        let stableSnapshot = StoreSnapshot(previousContents: stable.raw, capturedAt: Date())
        var cleared = try stable.store.clearing(.desktop, in: .everywhere)
        if stable.store.provider(of: .screensaver, in: .everywhere) == ChoiceProvider(rawValue: Self.wallpaperExtensionID) {
            cleared = try cleared.clearing(.screensaver, in: .everywhere)
        }
        _ = try storeFile.write(cleared)
        lsLog("remove cleared to system default, restarting agent")
        try await restartAgent()
        await settle()
        if let after = try? storeFile.read(),
           after.provider(of: .desktop, in: .everywhere) != ChoiceProvider(rawValue: Self.wallpaperExtensionID) {
            let observed = after.provider(of: .desktop, in: .everywhere)?.rawValue ?? "nil"
            lsLog("remove success via clear observed=\(observed)")
            refresh()
            if isApplied == false {
                SettingsManager.shared.didManualRemoveLockscreen = true
            }
            return .applied
        }
        let observed = (try? storeFile.read())?.provider(of: .desktop, in: .everywhere)?.rawValue ?? "unreadable"
        lsLog("remove verify FAILED after clear observed=\(observed), rolling back to stable snapshot")
        var rolledBack = false
        do {
            try storeFile.restore(stableSnapshot)
            rolledBack = true
            lsLog("remove rolled back to stable snapshot after clear failure")
        } catch {
            lsLog("remove rollback FAILED error=\(error.localizedDescription)")
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
                if attempt > 0 { lsLog("confirm extension running after \(attempt) extra restart(s) provider=\(Self.wallpaperExtensionID)") }
                return .applied
            }
            let runningNow = WallpaperAgent.runningExtensionBundleIdentifiers()
            lsLog("confirm extension not running attempt=\(attempt) relaunchAttempts=\(timeouts.extensionRelaunchAttempts) timeout=\(timeouts.extensionLaunch) running=\(runningNow)")
            guard attempt < timeouts.extensionRelaunchAttempts else {
                lsLog("confirm extension still not running provider=\(Self.wallpaperExtensionID) running=\(runningNow); store is correct but desktop may show agent fallback (black at lock)")
                return .appliedButExtensionNotRunning
            }
            attempt += 1
            lsLog("confirm restarting agent again attempt=\(attempt)/\(timeouts.extensionRelaunchAttempts) provider=\(Self.wallpaperExtensionID)")
            try? await restartAgent()
            await settle()
        }
    }

    // MARK: - Backups

    private var lockscreenBackupDir: URL {
        guard let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            lsLog("application support URL missing, using home fallback for backups")
            return fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/LiveWallpaper/LockScreenStoreBackups", isDirectory: true)
        }
        return base
            .appendingPathComponent("LiveWallpaper/LockScreenStoreBackups", isDirectory: true)
    }

    /// Copies the current store bytes (when present) into the lockscreen backup
    /// directory. Reads are stabilized first: the agent rewrites this file from
    /// memory, and backing up a half-written stub would poison restores.
    /// Called before every destructive step; throws before anything is written
    /// when the copy fails.
    @discardableResult
    func backupStore() async throws -> URL? {
        guard let data = try await awaitStableStoreBytes() else { return nil }
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
    /// Returns nil only when the store is stably absent (nothing to back up).
    /// Throws when the file never quiesces or is unreadable — callers must
    /// abort BEFORE writing instead of snapshotting stale bytes.
    private func awaitStableStoreBytes() async throws -> Data? {
        var previous: Data?
        var previousMissing = false
        var sawPresent = false
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            if Task.isCancelled { throw CancellationError() }
            do {
                let current = try storeFile.readRaw()
                sawPresent = true
                if let prev = previous, !previousMissing, prev == current {
                    return current
                }
                previous = current
                previousMissing = false
            } catch let err as PaperSaverError {
                if case .fileNotFound = err {
                    if previousMissing {
                        return nil
                    }
                    previous = nil
                    previousMissing = true
                } else {
                    previousMissing = false
                    lsLog("stable-bytes read error: \(err.localizedDescription)")
                }
            } catch {
                previousMissing = false
                lsLog("stable-bytes read error: \(error.localizedDescription)")
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        if previousMissing, !sawPresent {
            return nil
        }
        throw PaperSaverError.plistReadError("no stable store bytes within bound; aborting before write")
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

    /// True when at least one full-store backup exists to restore.
    var hasBackup: Bool { latestBackup() != nil }

    /// Manual rollback for the "Restore backup" button: writes the newest
    /// full-store backup over the store, restarts the agent and verifies the
    /// extension is gone. Serialized through the apply gate like every other
    /// store-write + restart sequence. Failed verify rolls back to the
    /// pre-restore stable snapshot (never leaves a half-restored store).
    @discardableResult
    func restoreLatestBackup() async throws -> WriteOutcome {
        try await acquireApplyGate()
        defer { releaseApplyGate() }
        // Snapshot the pre-existing newest backup BEFORE snapshotting current
        // state: backupStore() appends a new file that would otherwise become
        // `latest`, restoring current state over itself (a no-op that fails
        // verification while Hazel is applied).
        guard let latest = latestBackup(),
              let data = try? Data(contentsOf: latest) else {
            throw PaperSaverError.fileNotFound(
                lockscreenBackupDir.appendingPathComponent("latest.plist"))
        }
        lsLog("restore-backup start from=\(latest.lastPathComponent)")
        _ = try await backupStore()
        // Rollback image: stable pre-restore bytes (H4). A failed verify below
        // restores these, so the store never ends in a half-restored state.
        let stableSnapshot: StoreSnapshot
        do {
            stableSnapshot = StoreSnapshot(previousContents: try await requireStableStore().raw, capturedAt: Date())
        } catch {
            lsLog("restore-backup abort: no stable read before restore error=\(error.localizedDescription)")
            throw error
        }
        do {
            _ = try storeFile.writeRaw(data)
        } catch {
            lsLog("restore-backup write failed error=\(error.localizedDescription)")
            throw error
        }
        try await restartAgent()
        await settle()
        refresh()
        if isApplied {
            lsLog("restore-backup verify FAILED still applied, rolling back to stable snapshot")
            var rolledBack = false
            do {
                try storeFile.restore(stableSnapshot)
                rolledBack = true
                lsLog("restore-backup rolled back to stable snapshot")
            } catch {
                lsLog("restore-backup rollback FAILED error=\(error.localizedDescription)")
            }
            try? await restartAgent()
            refresh()
            throw PaperSaverError.verificationFailed(
                expected: "desktop without \(Self.wallpaperExtensionID)", rolledBack: rolledBack)
        }
        SettingsManager.shared.didManualRemoveLockscreen = true
        lsLog("restore-backup success")
        return .applied
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
    /// stderr are drained continuously (no pipe deadlock on chatty tools,
    /// capped at 64KB to bound memory) and the process is SIGKILLed when the
    /// timeout fires or the task is cancelled.
    func runProcess(_ executable: String, _ arguments: [String], timeout: Duration) async throws -> ProcessResult {
        if Task.isCancelled { throw CancellationError() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        var output = Data()
        var truncated = false
        let maxOutputBytes = 64 * 1024
        let outputLock = NSLock()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty {
                outputLock.lock()
                if !truncated {
                    if output.count < maxOutputBytes {
                        let remaining = maxOutputBytes - output.count
                        if chunk.count <= remaining {
                            output.append(chunk)
                        } else {
                            output.append(chunk.prefix(remaining))
                            truncated = true
                        }
                    } else {
                        truncated = true
                    }
                }
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
        func sigkill() {
            let pid = process.processIdentifier
            if pid > 0 { kill(pid, SIGKILL) }
        }
        let deadline = ContinuousClock.now + timeout
        while process.isRunning {
            if Task.isCancelled {
                process.terminate()
                let grace = ContinuousClock.now + .seconds(1)
                while process.isRunning, ContinuousClock.now < grace {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                if process.isRunning {
                    sigkill()
                    try? await Task.sleep(for: .milliseconds(500))
                }
                throw CancellationError()
            }
            if ContinuousClock.now >= deadline {
                process.terminate()
                let grace = ContinuousClock.now + .seconds(1)
                while process.isRunning, ContinuousClock.now < grace {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                if process.isRunning {
                    sigkill()
                    try? await Task.sleep(for: .milliseconds(500))
                }
                throw LockScreenError.processTimeout(executable: executable)
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        outputLock.lock()
        let wasTruncated = truncated
        let text = String(decoding: output, as: UTF8.self)
        outputLock.unlock()
        if wasTruncated {
            lsLog("\(executable) output truncated to \(maxOutputBytes) bytes")
        }
        return ProcessResult(status: process.terminationStatus,
                             output: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
