import AppKit
import AVFoundation
import CoreGraphics

class DesktopPictureService {
    static let shared = DesktopPictureService()

    private let fileManager = FileManager.default
    /// Serializes originals load-modify-save. Blocks submitted here must NEVER
    /// call AppKit (NSWorkspace/NSScreen): AppKit may need the main thread,
    /// and these blocks are waited on via stateQueue.sync from the main
    /// thread, so AppKit-inside would be a main<->queue deadlock.
    private let stateQueue = DispatchQueue(label: "com.live.hazel.desktop-picture")
    private let requestLock = NSLock()
    /// Monotonic guarded-sync epoch. Incremented on every syncCurrentVideo
    /// and on restoreAll (invalidate). applyOnMain/verification only proceed
    /// when their captured generation still equals latestGeneration, so a
    /// stale extraction can never apply AFTER a newer request, even across
    /// the background->main hop or a mid-apply arrival.
    private var latestGeneration: UInt64 = 0
    /// Wallpaper the latest guarded sync targets. Guarded by requestLock.
    private var latestWallpaperID: UUID?
    /// Last generation whose initial apply pass completed. Guarded by
    /// requestLock. Lets reconcile() tell pending (defer to in-flight) apart
    /// from completed (new displays still need the still).
    private var appliedGeneration: UInt64 = 0
    /// Set only inside stateQueue; tracks first-success-after-failure logging.
    private var originalsSaveHadFailure = false
    /// Guarded by requestLock; pointer writes happen on every switch (no per-success log).
    private var pointerWriteHadFailure = false

    private var stillsDir: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("LiveWallpaper/DesktopStills", isDirectory: true)
        do {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            NSLog("[Hazel] DesktopPictureService: could not create stills dir %@ : %@", dir.path, error.localizedDescription)
        }
        return dir
    }

    private var originalsURL: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("LiveWallpaper/desktop-originals.json")
    }

    func stillURL(for wallpaperID: UUID) -> URL {
        stillsDir.appendingPathComponent("\(wallpaperID.uuidString).jpg")
    }

    private func isOurs(_ url: URL?) -> Bool {
        guard let path = url?.standardizedFileURL.resolvingSymlinksInPath().path else { return false }
        let base = stillsDir.standardizedFileURL.resolvingSymlinksInPath().path
        return path == base || path.hasPrefix(base + "/")
    }

    /// Best-effort duration clamp; falls back to the requested time when the
    /// asset metadata cannot be read synchronously.
    private func clampedTarget(for asset: AVURLAsset, seconds: Double) -> CMTime {
        let duration = asset.duration.seconds
        if duration.isFinite, duration > 0.2 {
            return CMTime(seconds: min(seconds, max(0, duration - 0.1)), preferredTimescale: 600)
        }
        return CMTime(seconds: seconds, preferredTimescale: 600)
    }

    func extractFrame(video: URL, wallpaperID: UUID, at seconds: Double = 5.0) -> URL? {
        guard fileManager.fileExists(atPath: video.path),
              ((try? fileManager.attributesOfItem(atPath: video.path)[.size] as? NSNumber)?.intValue ?? 0) > 0 else {
            NSLog("[Hazel] DesktopPictureService: video missing or empty: %@", video.path)
            return nil
        }
        let destination = stillURL(for: wallpaperID)
        let asset = AVURLAsset(url: video)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1920, height: 1920)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)

        // Bounded retry: one extra attempt after a short delay covers
        // momentarily-unreadable files and deprecated-API flakiness under
        // load. Runs on the background extraction queue, never the main
        // thread's hot path (callers dispatch here off-main).
        var cgImage: CGImage?
        var firstError: Error?
        do {
            cgImage = try generator.copyCGImage(at: clampedTarget(for: asset, seconds: seconds), actualTime: nil)
        } catch {
            firstError = error
            do {
                cgImage = try generator.copyCGImage(at: .zero, actualTime: nil)
            } catch {
                firstError = error
                Thread.sleep(forTimeInterval: 0.2)
                do {
                    cgImage = try generator.copyCGImage(at: .zero, actualTime: nil)
                    NSLog("[Hazel] DesktopPictureService: frame extraction recovered on retry for %@", video.path)
                } catch {
                    NSLog("[Hazel] DesktopPictureService: frame extraction FAILED (retry exhausted) for %@ wallpaper %@: %@ (first: %@)", video.path, wallpaperID.uuidString, error.localizedDescription, firstError?.localizedDescription ?? "unknown")
                    return nil
                }
            }
        }

        guard let image = cgImage else {
            NSLog("[Hazel] DesktopPictureService: frame extraction FAILED (nil image, no throw) for %@ wallpaper %@", video.path, wallpaperID.uuidString)
            return nil
        }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else {
            NSLog("[Hazel] DesktopPictureService: still JPEG encode FAILED for %@ wallpaper %@", video.path, wallpaperID.uuidString)
            return nil
        }
        do {
            // Atomic: saver may read this still mid-write.
            try jpeg.write(to: destination, options: .atomic)
            return destination
        } catch {
            NSLog("[Hazel] DesktopPictureService: still write failed %@ : %@", destination.path, error.localizedDescription)
            return nil
        }
    }

    /// Stable per-display key. Never the localized name (locale/reboot fragile);
    /// falls back to the numeric display id.
    func displayUUID(for screen: NSScreen) -> String {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return "unknown-display"
        }
        let displayID = CGDirectDisplayID(number.uint32Value)
        if let unmanaged = CGDisplayCreateUUIDFromDisplayID(displayID),
           unmanaged.toOpaque() != nil {
            let uuid = unmanaged.takeRetainedValue()
            if let cfString = CFUUIDCreateString(nil, uuid) as String? {
                return cfString
            }
        }
        return "display-\(displayID)"
    }

    /// nil = unreadable/corrupt file present (callers must NOT overwrite it blindly).
    /// Must be called inside stateQueue.
    private func loadOriginals() -> [String: String]? {
        guard fileManager.fileExists(atPath: originalsURL.path) else { return [:] }
        for attempt in 0..<2 {
            if let data = try? Data(contentsOf: originalsURL),
               let dict = try? JSONDecoder().decode([String: String].self, from: data) {
                return dict
            }
            // Atomic rename means a torn read is transient: one short retry.
            if attempt == 0 {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        let size = (try? fileManager.attributesOfItem(atPath: originalsURL.path)[.size] as? NSNumber)?.intValue ?? -1
        NSLog("[Hazel] DesktopPictureService: originals file unreadable/corrupt, preserving it untouched %@ (size %d)", originalsURL.path, size)
        return nil
    }

    /// Must be called on stateQueue (callers guarantee this).
    private func saveOriginals(_ dict: [String: String]) {
        guard let data = try? JSONEncoder().encode(dict) else {
            NSLog("[Hazel] DesktopPictureService: originals encode failed, not writing %@", originalsURL.path)
            originalsSaveHadFailure = true
            return
        }
        do {
            try data.write(to: originalsURL, options: .atomic)
            if originalsSaveHadFailure {
                originalsSaveHadFailure = false
                NSLog("[Hazel] DesktopPictureService: originals save recovered %@", originalsURL.path)
            }
        } catch {
            originalsSaveHadFailure = true
            NSLog("[Hazel] DesktopPictureService: originals save failed %@ : %@", originalsURL.path, error.localizedDescription)
        }
    }

    /// Remembers this screen's non-Hazel desktop picture before we overwrite
    /// it. Must be called on the main thread (AppKit query stays on main);
    /// only the dict load-modify-save runs serialized on stateQueue, which
    /// contains no AppKit and therefore cannot deadlock against the main
    /// thread's sync wait.
    private func rememberOriginal(of screen: NSScreen) {
        let key = displayUUID(for: screen)
        guard let current = NSWorkspace.shared.desktopImageURL(for: screen), !isOurs(current) else { return }
        let path = current.path
        stateQueue.sync {
            guard var originals = loadOriginals() else { return }
            if originals[key] != nil { return }
            originals[key] = path
            saveOriginals(originals)
        }
    }

    private func isCurrentGeneration(_ generation: UInt64) -> Bool {
        requestLock.lock()
        let current = (latestGeneration == generation)
        requestLock.unlock()
        return current
    }

    /// Cancels any in-flight guarded sync so a stale extraction can never
    /// apply after this point (used when sync is turned off / originals are
    /// being restored). Thread-safe from any thread.
    private func invalidatePending() {
        requestLock.lock()
        latestGeneration &+= 1
        latestWallpaperID = nil
        requestLock.unlock()
    }

    /// Applies `still` on the main thread; skips screens already showing it
    /// (symlink-resolved compare avoids redundant sets/flicker). Guarded by
    /// generation: stale requests are discarded at entry AND before every
    /// screen, closing the window where a newer sync arrives mid-apply
    /// (possible because rememberOriginal's brief stateQueue.sync lets a
    /// background caller increment the epoch while main is blocked).
    private func applyOnMain(still: URL, generation: UInt64, wallpaperID: UUID) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.applyOnMain(still: still, generation: generation, wallpaperID: wallpaperID)
            }
            return
        }
        guard isCurrentGeneration(generation) else { return }
        guard SettingsManager.shared.syncSystemWallpaper else {
            NSLog("[Hazel] DesktopPictureService: guarded apply skipped (sync off) for wallpaper %@", wallpaperID.uuidString)
            return
        }
        let expected = still.standardizedFileURL.resolvingSymlinksInPath()
        for screen in NSScreen.screens {
            guard isCurrentGeneration(generation) else { return }
            rememberOriginal(of: screen)
            let showing = NSWorkspace.shared.desktopImageURL(for: screen)?
                .standardizedFileURL.resolvingSymlinksInPath()
            if showing == expected {
                continue
            }
            do {
                try NSWorkspace.shared.setDesktopImageURL(still, for: screen, options: [:])
            } catch {
                NSLog("[Hazel] DesktopPictureService: setDesktopImageURL failed %@ : %@", still.path, error.localizedDescription)
            }
        }
        requestLock.lock()
        if latestGeneration == generation {
            appliedGeneration = generation
        }
        requestLock.unlock()
        scheduleVerify(still: still, generation: generation, wallpaperID: wallpaperID)
    }

    /// Unconditional apply for an already-extracted still (reconcile path).
    /// Deliberately does NOT touch the guarded epoch, so it can never cancel
    /// an in-flight syncCurrentVideo. Off-main callers hop async (never
    /// main.sync, so no main-thread blocking wait on background work).
    func apply(still: URL) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.apply(still: still) }
            return
        }
        guard SettingsManager.shared.syncSystemWallpaper else { return }
        let expected = still.standardizedFileURL.resolvingSymlinksInPath()
        for screen in NSScreen.screens {
            rememberOriginal(of: screen)
            let showing = NSWorkspace.shared.desktopImageURL(for: screen)?
                .standardizedFileURL.resolvingSymlinksInPath()
            if showing == expected {
                continue
            }
            do {
                try NSWorkspace.shared.setDesktopImageURL(still, for: screen, options: [:])
            } catch {
                NSLog("[Hazel] DesktopPictureService: setDesktopImageURL failed %@ : %@", still.path, error.localizedDescription)
            }
        }
        scheduleVerifyUnconditional(still: still)
    }

    /// setDesktopImageURL only throws on failure; a silent no-op still
    /// reports success. Re-read after one short delay and retry once on
    /// mismatch. Single one-shot asyncAfter per apply — no polling, no
    /// repeating timers, bounded to exactly one retry.
    private func scheduleVerify(still: URL, generation: UInt64, wallpaperID: UUID) {
        let expected = still.standardizedFileURL.resolvingSymlinksInPath()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            guard SettingsManager.shared.syncSystemWallpaper else { return }
            guard self.isCurrentGeneration(generation) else { return }
            var mismatched: [NSScreen] = []
            for screen in NSScreen.screens {
                let showing = NSWorkspace.shared.desktopImageURL(for: screen)?
                    .standardizedFileURL.resolvingSymlinksInPath()
                if showing != expected {
                    mismatched.append(screen)
                }
            }
            guard !mismatched.isEmpty else { return }
            NSLog("[Hazel] DesktopPictureService: verify mismatch for wallpaper %@ on %lu display(s), retrying once", wallpaperID.uuidString, mismatched.count)
            for screen in mismatched {
                guard self.isCurrentGeneration(generation) else { return }
                self.rememberOriginal(of: screen)
                do {
                    try NSWorkspace.shared.setDesktopImageURL(still, for: screen, options: [:])
                } catch {
                    NSLog("[Hazel] DesktopPictureService: verify-retry setDesktopImageURL failed %@ : %@", still.path, error.localizedDescription)
                }
            }
            var stillBad: [String] = []
            for screen in mismatched {
                let showing = NSWorkspace.shared.desktopImageURL(for: screen)?
                    .standardizedFileURL.resolvingSymlinksInPath()
                if showing != expected {
                    stillBad.append(self.displayUUID(for: screen))
                }
            }
            if !stillBad.isEmpty {
                NSLog("[Hazel] DesktopPictureService: verify FAILED after retry for %@ on %@ — will correct on next switch/reconcile", still.path, stillBad.joined(separator: ","))
            }
        }
    }

    /// Same one-shot verification for the unconditional (reconcile) path.
    /// Aborts the retry when the saver pointer has moved on, so a delayed
    /// verify can never overwrite a NEWER video's still.
    private func scheduleVerifyUnconditional(still: URL) {
        let expected = still.standardizedFileURL.resolvingSymlinksInPath()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            guard SettingsManager.shared.syncSystemWallpaper else { return }
            if let pointer = self.readSaverPointer(),
               let currentID = UUID(uuidString: pointer.wallpaperID) {
                let currentStill = self.stillURL(for: currentID).standardizedFileURL.resolvingSymlinksInPath()
                guard currentStill == expected else { return }
            }
            var mismatched: [NSScreen] = []
            for screen in NSScreen.screens {
                let showing = NSWorkspace.shared.desktopImageURL(for: screen)?
                    .standardizedFileURL.resolvingSymlinksInPath()
                if showing != expected {
                    mismatched.append(screen)
                }
            }
            guard !mismatched.isEmpty else { return }
            NSLog("[Hazel] DesktopPictureService: verify mismatch (reconcile) for %@ on %lu display(s), retrying once", still.path, mismatched.count)
            for screen in mismatched {
                self.rememberOriginal(of: screen)
                do {
                    try NSWorkspace.shared.setDesktopImageURL(still, for: screen, options: [:])
                } catch {
                    NSLog("[Hazel] DesktopPictureService: verify-retry setDesktopImageURL failed %@ : %@", still.path, error.localizedDescription)
                }
            }
            var stillBad: [String] = []
            for screen in mismatched {
                let showing = NSWorkspace.shared.desktopImageURL(for: screen)?
                    .standardizedFileURL.resolvingSymlinksInPath()
                if showing != expected {
                    stillBad.append(self.displayUUID(for: screen))
                }
            }
            if !stillBad.isEmpty {
                NSLog("[Hazel] DesktopPictureService: verify FAILED after retry for %@ on %@ — will correct on next switch/reconcile", still.path, stillBad.joined(separator: ","))
            }
        }
    }

    /// Extraction runs off the main thread so switching videos never hitches;
    /// only the latest request applies (stale extractions are discarded both
    /// before the main-thread hop and at apply entry, so ordering inversions
    /// across the hop are impossible).
    func syncCurrentVideo(video: URL?, wallpaperID: UUID?) {
        guard let video, let wallpaperID else { return }
        requestLock.lock()
        latestGeneration &+= 1
        let generation = latestGeneration
        latestWallpaperID = wallpaperID
        requestLock.unlock()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            guard let still = self.extractFrame(video: video, wallpaperID: wallpaperID) else {
                NSLog("[Hazel] DesktopPictureService: sync aborted, no still for %@ wallpaper %@ (gen %llu) — desktop left unchanged", video.path, wallpaperID.uuidString, generation)
                return
            }
            guard self.isCurrentGeneration(generation) else { return }
            DispatchQueue.main.async {
                self.applyOnMain(still: still, generation: generation, wallpaperID: wallpaperID)
            }
        }
    }

    /// Pointer the Hazel.saver bundle reads on every startAnimation.
    /// Stable path in the real (unsandboxed) Application Support dir.
    struct SaverPointer: Codable {
        var videoPath: String
        var wallpaperID: String
        var fit: String
        var isLooping: Bool
        var isMuted: Bool
    }

    private var saverPointerURL: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("LiveWallpaper", isDirectory: true)
        do {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            NSLog("[Hazel] DesktopPictureService: could not create LiveWallpaper dir %@ : %@", dir.path, error.localizedDescription)
        }
        return dir.appendingPathComponent("hazel-current.json")
    }

    /// Tolerates torn reads: saver writes atomically, but a reader mid-rename
    /// (or a crash) can still see a transient failure. Skips (nil) and retries
    /// once, never crashes, never returns partial data.
    func readSaverPointer() -> SaverPointer? {
        for attempt in 0..<2 {
            if let data = try? Data(contentsOf: saverPointerURL),
               let pointer = try? JSONDecoder().decode(SaverPointer.self, from: data) {
                return pointer
            }
            if attempt == 0 {
                Thread.sleep(forTimeInterval: 0.05)
                continue
            }
        }
        // Missing file on first launch is normal: stay silent then.
        if fileManager.fileExists(atPath: saverPointerURL.path) {
            let size = (try? fileManager.attributesOfItem(atPath: saverPointerURL.path)[.size] as? NSNumber)?.intValue ?? -1
            NSLog("[Hazel] DesktopPictureService: saver pointer unreadable, skipping %@ (size %d)", saverPointerURL.path, size)
        }
        return nil
    }

    func writeCurrentPointer(video: URL, wallpaperID: UUID, isLooping: Bool, isMuted: Bool) {
        var path = video.path
        let fileName = video.lastPathComponent
        let realCandidate = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("LiveWallpaper/Videos/\(fileName)")
        if path.contains("Containers/com.live.hazel"),
           FileManager.default.fileExists(atPath: realCandidate.path) {
            path = realCandidate.path
        }
        let pointer = SaverPointer(
            videoPath: path,
            wallpaperID: wallpaperID.uuidString,
            fit: SettingsManager.shared.wallpaperFit.rawValue,
            isLooping: isLooping,
            isMuted: isMuted
        )
        guard let data = try? JSONEncoder().encode(pointer) else {
            NSLog("[Hazel] DesktopPictureService: pointer encode failed, not writing %@", saverPointerURL.path)
            requestLock.lock()
            pointerWriteHadFailure = true
            requestLock.unlock()
            return
        }
        do {
            try data.write(to: saverPointerURL, options: .atomic)
            requestLock.lock()
            let recovered = pointerWriteHadFailure
            pointerWriteHadFailure = false
            requestLock.unlock()
            if recovered {
                NSLog("[Hazel] DesktopPictureService: pointer write recovered %@", saverPointerURL.path)
            }
        } catch {
            requestLock.lock()
            pointerWriteHadFailure = true
            requestLock.unlock()
            NSLog("[Hazel] DesktopPictureService: pointer write failed %@ : %@", saverPointerURL.path, error.localizedDescription)
        }
    }

    func restoreAll() {
        // Cancel in-flight guarded work FIRST so a stale extraction that
        // finishes after the restore cannot re-apply a Hazel still on top of
        // the just-restored original (rapid off/on correctness).
        invalidatePending()
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.restoreAll() }
            return
        }
        // Snapshot on the serialized queue (no AppKit inside the block).
        let snapshot: [String: String]? = stateQueue.sync { loadOriginals() }
        guard var originals = snapshot, !originals.isEmpty else { return }
        // AppKit work stays on main.
        var restoredKeys: [String] = []
        for screen in NSScreen.screens {
            let key = displayUUID(for: screen)
            guard let path = originals[key] else { continue }
            if let current = NSWorkspace.shared.desktopImageURL(for: screen), !isOurs(current) {
                continue
            }
            guard fileManager.fileExists(atPath: path) else { continue }
            do {
                try NSWorkspace.shared.setDesktopImageURL(URL(fileURLWithPath: path), for: screen, options: [:])
                restoredKeys.append(key)
            } catch {
                NSLog("[Hazel] DesktopPictureService: restore failed %@ : %@", path, error.localizedDescription)
            }
        }
        // Keep keys for unplugged displays and failed restores; never wipe blindly.
        // Re-load before saving so a concurrent rememberOriginal between the
        // snapshot and now is merged, never lost.
        let keysToRemove = restoredKeys
        if keysToRemove.isEmpty { return }
        stateQueue.sync {
            guard var current = loadOriginals() else { return }
            for key in keysToRemove {
                current.removeValue(forKey: key)
            }
            if current.isEmpty {
                do {
                    try fileManager.removeItem(at: originalsURL)
                } catch {
                    NSLog("[Hazel] DesktopPictureService: originals cleanup remove failed %@ : %@", originalsURL.path, error.localizedDescription)
                }
            } else {
                saveOriginals(current)
            }
            originals = current
        }
    }

    func reconcile() {
        guard SettingsManager.shared.syncSystemWallpaper else { return }
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.reconcile() }
            return
        }
        // Snapshot on the serialized queue (no AppKit inside the block), then
        // compute missing entries on main where desktopImageURL is legal.
        let snapshot: [String: String]? = stateQueue.sync { loadOriginals() }
        guard var originals = snapshot else { return }
        var changed = false
        for screen in NSScreen.screens {
            let key = displayUUID(for: screen)
            if originals[key] == nil {
                if let current = NSWorkspace.shared.desktopImageURL(for: screen), !isOurs(current) {
                    originals[key] = current.path
                    changed = true
                }
            }
        }
        if changed {
            let toSave = originals
            stateQueue.sync { saveOriginals(toSave) }
        }
        // New/replugged displays show the still, not the remembered original.
        guard let pointer = readSaverPointer(),
              let id = UUID(uuidString: pointer.wallpaperID) else { return }
        // Never fight in-flight guarded work for the same still: the pending
        // apply already loops every screen (including new ones), so a second
        // synchronous set here would only duplicate it. Defer only while the
        // latest sync has not yet applied; once applied, new displays below
        // still need the still, so fall through.
        requestLock.lock()
        let pendingID = latestWallpaperID
        let pendingGen = latestGeneration
        let appliedGen = appliedGeneration
        requestLock.unlock()
        let still = stillURL(for: id)
        if let pendingID, pendingID == id, appliedGen != pendingGen {
            var allShowing = true
            for screen in NSScreen.screens {
                let showing = NSWorkspace.shared.desktopImageURL(for: screen)?
                    .standardizedFileURL.resolvingSymlinksInPath()
                if showing != still.standardizedFileURL.resolvingSymlinksInPath() {
                    allShowing = false
                    break
                }
            }
            if !allShowing {
                NSLog("[Hazel] DesktopPictureService: reconcile deferred to in-flight sync for %@", id.uuidString)
                return
            }
            return
        }
        if fileManager.fileExists(atPath: still.path) {
            apply(still: still)
        } else {
            NSLog("[Hazel] DesktopPictureService: reconcile skipped, still missing for %@ at %@", id.uuidString, still.path)
        }
    }
}
