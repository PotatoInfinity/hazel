import AppKit
import AVFoundation
import CoreGraphics

class DesktopPictureService {
    static let shared = DesktopPictureService()

    private let fileManager = FileManager.default
    /// Serializes originals load-modify-save. Blocks submitted here must NEVER
    /// call AppKit (NSWorkspace/NSScreen): AppKit may need the main thread.
    /// Main-thread callers never stateQueue.sync (they merge through the
    /// in-memory originalsCache and persist with async hops only), so AppKit
    /// on main can never deadlock against these blocks.
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
    /// Single-flight still extraction: one decode per wallpaper at a time.
    /// Rapid A->B->A would otherwise start two identical decodes (neither has
    /// hit the fast path yet). Guarded by requestLock.
    private var extractionInflight: Set<UUID> = []
    /// Latest guarded sync waiting on the in-flight extraction for its ID.
    /// Only the newest generation matters (older ones are stale by epoch).
    /// Guarded by requestLock.
    private var pendingSyncs: [UUID: (video: URL, generation: UInt64)] = [:]
    /// Last pointer target written (set synchronously on the caller thread).
    /// Lets the reconcile verify skip its file decode in steady state.
    /// Guarded by requestLock.
    private var cachedPointerID: UUID?
    /// Pointer-write coalescing: rapid switches collapse to at most two disk
    /// writes (the in-flight one + the latest arrival), not N queued writes.
    /// Guarded by pointerLock.
    private let pointerLock = NSLock()
    private var latestPointerParams: (video: URL, wallpaperID: UUID, isLooping: Bool, isMuted: Bool, fit: String)?
    private var pointerWriting = false

    /// In-memory mirror of desktop-originals.json. Main-thread paths
    /// read/merge through this cache under requestLock (no file I/O, never
    /// stateQueue.sync from main); stateQueue only persists. Warmed once at
    /// launch; cold paths delegate to stateQueue and re-enter on main.
    private var originalsCache: [String: String]?
    private var originalsCacheReady = false

    private init() { preloadOriginalsCache() }

    private func preloadOriginalsCache() {
        stateQueue.async { [weak self] in
            guard let self else { return }
            guard let loaded = self.loadOriginals() else {
                self.requestLock.lock()
                if !self.originalsCacheReady {
                    self.originalsCache = nil
                    self.originalsCacheReady = true
                }
                self.requestLock.unlock()
                return
            }
            self.requestLock.lock()
            if !self.originalsCacheReady {
                self.originalsCache = loaded
                self.originalsCacheReady = true
            }
            // Else the cache was already populated while this load was in
            // flight; disk may predate those merges, so keep the cache and
            // let the next async persist make disk cumulative.
            self.requestLock.unlock()
        }
    }

    /// Persists whatever the cache holds at execution time (not a stale
    /// submission-time snapshot), so overlapping remembers/restores can never
    /// clobber each other. Must be called after the cache was updated under
    /// requestLock. Never wipes on a nil (corrupt/unreadable) cache.
    private func persistOriginalsCacheAsync() {
        stateQueue.async { [weak self] in
            guard let self else { return }
            self.requestLock.lock()
            let current = self.originalsCache
            self.requestLock.unlock()
            guard let current else { return }
            if current.isEmpty {
                do {
                    try self.fileManager.removeItem(at: self.originalsURL)
                } catch {
                    NSLog("[Hazel] DesktopPictureService: originals cleanup remove failed %@ : %@", self.originalsURL.path, error.localizedDescription)
                }
            } else {
                self.saveOriginals(current)
            }
        }
    }

    private var stillsDir: URL {
        let dir = stillsDirForRead
        do {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            NSLog("[Hazel] DesktopPictureService: could not create stills dir %@ : %@", dir.path, error.localizedDescription)
        }
        return dir
    }

    /// Read-path stills dir: never creates directories. stillURL() and isOurs()
    /// run on the main thread during launch/apply; a mkdir there is pure
    /// first-frame cost. Writers (extractFrame) use stillsDir (which ensures).
    private var stillsDirForRead: URL {
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/LiveWallpaper/DesktopStills", isDirectory: true)
        }
        return appSupport.appendingPathComponent("LiveWallpaper/DesktopStills", isDirectory: true)
    }

    /// Resolved stills base, computed once. isOurs() runs per screen per apply;
    /// re-resolving the base's symlinks on every call is filesystem I/O on
    /// main. The base never moves within a launch, so cache it.
    private lazy var resolvedStillsBase: String = {
        stillsDirForRead.standardizedFileURL.resolvingSymlinksInPath().path
    }()

    private var originalsURL: URL {
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            NSLog("[Hazel] DesktopPictureService: application support URL missing, using home fallback for originals")
            return fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/LiveWallpaper/desktop-originals.json")
        }
        return appSupport.appendingPathComponent("LiveWallpaper/desktop-originals.json")
    }

    func stillURL(for wallpaperID: UUID) -> URL {
        stillsDirForRead.appendingPathComponent("\(wallpaperID.uuidString).jpg")
    }

    private func isOurs(_ url: URL?) -> Bool {
        guard let path = url?.standardizedFileURL.resolvingSymlinksInPath().path else { return false }
        let base = resolvedStillsBase
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
            // Write path ensures the dir: stillURL() is mkdir-free (main
            // thread), so first-launch extraction creates it here instead.
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
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
    /// Cached per displayID: CGDisplayCreateUUIDFromDisplayID + symlink
    /// resolution ran on main per screen per apply/verify/reconcile — pure
    /// vsync-hitch cost in steady state. Display IDs are stable per session.
    private var displayUUIDCache: [UInt32: String] = [:]
    func displayUUID(for screen: NSScreen) -> String {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return "unknown-display"
        }
        let displayID = number.uint32Value
        requestLock.lock()
        if let cached = displayUUIDCache[displayID] {
            requestLock.unlock()
            return cached
        }
        requestLock.unlock()
        let displayCGID = CGDirectDisplayID(displayID)
        var resolved: String?
        if let unmanaged = CGDisplayCreateUUIDFromDisplayID(displayCGID),
           unmanaged.toOpaque() != nil {
            let uuid = unmanaged.takeRetainedValue()
            if let cfString = CFUUIDCreateString(nil, uuid) as String? {
                resolved = cfString
            }
        }
        let result = resolved ?? "display-\(displayCGID)"
        requestLock.lock()
        displayUUIDCache[displayID] = result
        requestLock.unlock()
        return result
    }

    /// nil = unreadable/corrupt file present (callers must NOT overwrite it blindly).
    /// Must be called inside stateQueue. Retries once immediately (no sleep:
    /// a torn atomic rename resolves on the second read).
    private func loadOriginals() -> [String: String]? {
        guard fileManager.fileExists(atPath: originalsURL.path) else { return [:] }
        for _ in 0..<2 {
            if let data = try? Data(contentsOf: originalsURL),
               let dict = try? JSONDecoder().decode([String: String].self, from: data) {
                return dict
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

    /// Remembers every screen's non-Hazel desktop picture before we overwrite
    /// any of them. Must be called on the main thread (AppKit queries stay on
    /// main). Merges into the in-memory cache under lock (no file I/O on the
    /// caller) and persists asynchronously, so the main thread never blocks
    /// on stateQueue. Batched: one async persist per apply, not one per screen.
    private func rememberOriginals(of screens: [NSScreen]) {
        var candidates: [(key: String, path: String)] = []
        candidates.reserveCapacity(screens.count)
        for screen in screens {
            let key = displayUUID(for: screen)
            guard let current = NSWorkspace.shared.desktopImageURL(for: screen), !isOurs(current) else { continue }
            candidates.append((key, current.path))
        }
        guard !candidates.isEmpty else { return }
        requestLock.lock()
        let ready = originalsCacheReady
        if ready {
            // Corrupt/unreadable on disk: never overwrite blindly.
            guard var cache = originalsCache else {
                requestLock.unlock()
                return
            }
            var changed = false
            for candidate in candidates where cache[candidate.key] == nil {
                cache[candidate.key] = candidate.path
                changed = true
            }
            if changed {
                originalsCache = cache
            }
            requestLock.unlock()
            if changed {
                persistOriginalsCacheAsync()
            }
            return
        }
        requestLock.unlock()
        // Cache cold: serialize the load+merge on stateQueue, then mark warm.
        stateQueue.async { [weak self, candidates] in
            guard let self else { return }
            guard var originals = self.loadOriginals() else {
                self.requestLock.lock()
                if !self.originalsCacheReady {
                    self.originalsCache = nil
                    self.originalsCacheReady = true
                }
                self.requestLock.unlock()
                return
            }
            for candidate in candidates where originals[candidate.key] == nil {
                originals[candidate.key] = candidate.path
            }
            let final = originals
            self.requestLock.lock()
            if !self.originalsCacheReady {
                self.originalsCache = final
                self.originalsCacheReady = true
                self.requestLock.unlock()
                self.saveOriginals(final)
            } else if self.originalsCache != nil {
                // Warmed while this load was in flight: fold any keys the
                // disk read has that the cache lacks (cache wins on
                // conflict), so no remember is ever lost.
                var merged = self.originalsCache!
                var changed = false
                for (key, path) in final where merged[key] == nil {
                    merged[key] = path
                    changed = true
                }
                self.originalsCache = merged
                self.requestLock.unlock()
                if changed {
                    self.saveOriginals(merged)
                }
            } else {
                self.requestLock.unlock()
            }
        }
    }

    private func isCurrentGeneration(_ generation: UInt64) -> Bool {
        requestLock.lock()
        let current = (latestGeneration == generation)
        requestLock.unlock()
        return current
    }

    /// Test seams (additive, no behavior change). `beginTestGeneration`
    /// mirrors the epoch bump at the top of `syncCurrentVideo` without
    /// touching extraction, AppKit, or the filesystem, so epoch-guard tests
    /// stay hermetic.
    internal var generationForTesting: UInt64 {
        requestLock.lock()
        defer { requestLock.unlock() }
        return latestGeneration
    }
    internal var appliedGenerationForTesting: UInt64 {
        requestLock.lock()
        defer { requestLock.unlock() }
        return appliedGeneration
    }
    internal func isCurrentGenerationForTesting(_ generation: UInt64) -> Bool {
        isCurrentGeneration(generation)
    }
    @discardableResult
    internal func beginTestGeneration(for wallpaperID: UUID) -> UInt64 {
        requestLock.lock()
        latestGeneration &+= 1
        let generation = latestGeneration
        latestWallpaperID = wallpaperID
        requestLock.unlock()
        return generation
    }
    internal func applyOnMainForTesting(still: URL, generation: UInt64, wallpaperID: UUID) {
        applyOnMain(still: still, generation: generation, wallpaperID: wallpaperID)
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
    /// (possible because the extraction hop lets a newer request increment
    /// the epoch while an older one is still in flight).
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
        let screens = NSScreen.screens
        rememberOriginals(of: screens)
        for screen in screens {
            guard isCurrentGeneration(generation) else { return }
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
        let screens = NSScreen.screens
        rememberOriginals(of: screens)
        for screen in screens {
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
            self.rememberOriginals(of: mismatched)
            for screen in mismatched {
                guard self.isCurrentGeneration(generation) else { return }
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
    /// verify can never overwrite a NEWER video's still. Steady-state cost is
    /// one lock + URL compare: the in-memory pointer cache avoids the JSON
    /// decode unless no switch has been seen this launch.
    private func scheduleVerifyUnconditional(still: URL) {
        let expected = still.standardizedFileURL.resolvingSymlinksInPath()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            guard SettingsManager.shared.syncSystemWallpaper else { return }
            self.requestLock.lock()
            let cachedID = self.cachedPointerID
            self.requestLock.unlock()
            if let cachedID {
                let currentStill = self.stillURL(for: cachedID).standardizedFileURL.resolvingSymlinksInPath()
                guard currentStill == expected else { return }
            } else if let pointer = self.readSaverPointer(),
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
            self.rememberOriginals(of: mismatched)
            for screen in mismatched {
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
    ///
    /// Fast path: a prewarmed (or previously extracted) still applies at once.
    /// Library videos are immutable UUID-named copies, so an existing
    /// non-empty still is current and re-extraction is pure waste.
    ///
    /// Main-thread cost is one epoch bump under lock: the still-exists stat
    /// and the extraction both run on a background queue, never on the caller's
    /// (often main, often first-frame) thread. Background (not utility) so a
    /// 1920p decode + JPEG encode never contends the live AVPlayerLayer
    /// display decode for CPU/hardware-decoder time at presentation.
    func syncCurrentVideo(video: URL?, wallpaperID: UUID?) {
        guard let video, let wallpaperID else { return }
        requestLock.lock()
        latestGeneration &+= 1
        let generation = latestGeneration
        latestWallpaperID = wallpaperID
        pendingSyncs[wallpaperID] = (video, generation)
        if extractionInflight.contains(wallpaperID) {
            // Decode already running (prewarm or earlier sync): it drains the
            // newest waiter on completion. No second decode, no extra hop.
            requestLock.unlock()
            return
        }
        extractionInflight.insert(wallpaperID)
        requestLock.unlock()
        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let self else { return }
            let cached = self.stillURL(for: wallpaperID)
            if let size = (try? self.fileManager.attributesOfItem(atPath: cached.path)[.size] as? NSNumber)?.intValue,
               size > 0 {
                self.requestLock.lock()
                self.extractionInflight.remove(wallpaperID)
                let pending = self.pendingSyncs.removeValue(forKey: wallpaperID)
                self.requestLock.unlock()
                let applyGen = pending?.generation ?? generation
                DispatchQueue.main.async { [weak self] in
                    self?.applyOnMain(still: cached, generation: applyGen, wallpaperID: wallpaperID)
                }
                return
            }
            // Use the newest waiter video (same ID is immutable, but a
            // replacement could change bytes; never decode a stale capture).
            self.requestLock.lock()
            let latestVideo = self.pendingSyncs[wallpaperID]?.video ?? video
            self.requestLock.unlock()
            guard let still = self.extractFrame(video: latestVideo, wallpaperID: wallpaperID) else {
                NSLog("[Hazel] DesktopPictureService: sync aborted, no still for %@ wallpaper %@ (gen %llu) — desktop left unchanged", latestVideo.path, wallpaperID.uuidString, generation)
                self.requestLock.lock()
                self.extractionInflight.remove(wallpaperID)
                self.pendingSyncs.removeValue(forKey: wallpaperID)
                self.requestLock.unlock()
                return
            }
            self.requestLock.lock()
            self.extractionInflight.remove(wallpaperID)
            let pending = self.pendingSyncs.removeValue(forKey: wallpaperID)
            self.requestLock.unlock()
            let applyGen = pending?.generation ?? generation
            guard self.isCurrentGeneration(applyGen) else { return }
            DispatchQueue.main.async {
                self.applyOnMain(still: still, generation: applyGen, wallpaperID: wallpaperID)
            }
        }
    }

    /// Warms the still cache for the likely-next video: extracts in the
    /// background without touching the guarded epoch (never cancels in-flight
    /// work, never applies). A later syncCurrentVideo for the same wallpaper
    /// then hits the fast path and applies immediately. The exists-check runs
    /// inside the async hop so callers (often main, often first-frame) pay no
    /// stat. Single-flight: shares extractionInflight with syncCurrentVideo so
    /// a warm + sync race decodes once; a sync waiter arriving mid-prewarm is
    /// applied by the prewarm worker instead of being dropped.
    func prewarmStill(video: URL?, wallpaperID: UUID?) {
        guard let video, let wallpaperID else { return }
        requestLock.lock()
        if extractionInflight.contains(wallpaperID) {
            requestLock.unlock()
            return
        }
        extractionInflight.insert(wallpaperID)
        requestLock.unlock()
        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let self else { return }
            let destination = self.stillURL(for: wallpaperID)
            if let size = (try? self.fileManager.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.intValue,
               size > 0 {
                self.requestLock.lock()
                self.extractionInflight.remove(wallpaperID)
                let pending = self.pendingSyncs.removeValue(forKey: wallpaperID)
                self.requestLock.unlock()
                if let pending, self.isCurrentGeneration(pending.generation) {
                    DispatchQueue.main.async {
                        self.applyOnMain(still: destination, generation: pending.generation, wallpaperID: wallpaperID)
                    }
                }
                return
            }
            self.requestLock.lock()
            let latestVideo = self.pendingSyncs[wallpaperID]?.video ?? video
            self.requestLock.unlock()
            _ = self.extractFrame(video: latestVideo, wallpaperID: wallpaperID)
            self.requestLock.lock()
            self.extractionInflight.remove(wallpaperID)
            let pending = self.pendingSyncs.removeValue(forKey: wallpaperID)
            self.requestLock.unlock()
            if let pending, self.isCurrentGeneration(pending.generation) {
                let cached = self.stillURL(for: wallpaperID)
                DispatchQueue.main.async {
                    self.applyOnMain(still: cached, generation: pending.generation, wallpaperID: wallpaperID)
                }
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
        let url = saverPointerURLForRead
        do {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            NSLog("[Hazel] DesktopPictureService: could not create LiveWallpaper dir %@ : %@", url.deletingLastPathComponent().path, error.localizedDescription)
        }
        return url
    }

    /// Read-path pointer URL: never creates directories. readSaverPointer()
    /// runs on main (reconcile); a mkdir there is pure apply cost.
    private var saverPointerURLForRead: URL {
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/LiveWallpaper/hazel-current.json")
        }
        return appSupport.appendingPathComponent("LiveWallpaper/hazel-current.json")
    }

    /// Tolerates torn reads: saver writes atomically, but a reader mid-rename
    /// (or a crash) can still see a transient failure. One immediate second
    /// attempt (no sleep: cold paths call this on the main thread), then skip.
    /// Never crashes, never returns partial data.
    func readSaverPointer() -> SaverPointer? {
        let url = saverPointerURLForRead
        for _ in 0..<2 {
            if let data = try? Data(contentsOf: url),
               let pointer = try? JSONDecoder().decode(SaverPointer.self, from: data) {
                return pointer
            }
        }
        // Missing file on first launch is normal: stay silent then.
        if fileManager.fileExists(atPath: url.path) {
            let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? -1
            NSLog("[Hazel] DesktopPictureService: saver pointer unreadable, skipping %@ (size %d)", url.path, size)
        }
        return nil
    }

    /// Serializes pointer writes (ordering across rapid switches) without ever
    /// blocking the caller: setWallpaper calls this on the main thread.
    private let pointerQueue = DispatchQueue(label: "com.live.hazel.saver-pointer", qos: .background)

    /// Fire-and-forget: runs on pointerQueue so per-switch JSON encode +
    /// atomic write never blocks the main thread. Callers never depend on
    /// completion; readers tolerate torn/missing files.
    /// Coalesced: rapid switches collapse to at most two disk writes (the
    /// in-flight one + the latest arrival), not N queued writes. Ordering is
    /// preserved (writes execute in arrival order, latest wins) without ever
    /// blocking the caller.
    func writeCurrentPointer(video: URL, wallpaperID: UUID, isLooping: Bool, isMuted: Bool) {
        let fitRawValue = SettingsManager.shared.wallpaperFit.rawValue
        requestLock.lock()
        cachedPointerID = wallpaperID
        requestLock.unlock()
        pointerLock.lock()
        latestPointerParams = (video, wallpaperID, isLooping, isMuted, fitRawValue)
        let alreadyWriting = pointerWriting
        pointerWriting = true
        pointerLock.unlock()
        if alreadyWriting { return }
        pointerQueue.async { [weak self] in
            guard let self else { return }
            while true {
                self.pointerLock.lock()
                guard let params = self.latestPointerParams else {
                    self.pointerWriting = false
                    self.pointerLock.unlock()
                    return
                }
                self.latestPointerParams = nil
                self.pointerLock.unlock()
                self.writePointerNow(video: params.video, wallpaperID: params.wallpaperID,
                                     isLooping: params.isLooping, isMuted: params.isMuted,
                                     fitRawValue: params.fit)
            }
        }
    }

    private func writePointerNow(video: URL, wallpaperID: UUID, isLooping: Bool, isMuted: Bool, fitRawValue: String) {
        var path = video.path
        guard let appSupportBase = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            NSLog("[Hazel] DesktopPictureService: application support URL missing, skipping container-path rewrite")
            return
        }
        let realCandidate = appSupportBase
            .appendingPathComponent("LiveWallpaper/Videos/\(video.lastPathComponent)")
        if path.contains("Containers/com.live.hazel"),
           FileManager.default.fileExists(atPath: realCandidate.path) {
            path = realCandidate.path
        }
        let pointer = SaverPointer(
            videoPath: path,
            wallpaperID: wallpaperID.uuidString,
            fit: fitRawValue,
            isLooping: isLooping,
            isMuted: isMuted
        )
        guard let data = try? JSONEncoder().encode(pointer) else {
            NSLog("[Hazel] DesktopPictureService: pointer encode failed, not writing %@", self.saverPointerURL.path)
            self.requestLock.lock()
            self.pointerWriteHadFailure = true
            self.requestLock.unlock()
            return
        }
        do {
            try data.write(to: self.saverPointerURL, options: .atomic)
            self.requestLock.lock()
            let recovered = self.pointerWriteHadFailure
            self.pointerWriteHadFailure = false
            self.requestLock.unlock()
            if recovered {
                NSLog("[Hazel] DesktopPictureService: pointer write recovered %@", self.saverPointerURL.path)
            }
        } catch {
            self.requestLock.lock()
            // A failed write must not leave the intent ahead of the disk truth
            // the saver reads: clear only when no newer switch arrived meanwhile
            // (which re-set the cache to its own id). Readers then fall back to
            // the disk pointer — desktop and saver stay consistent (both stale)
            // instead of diverging, and the next switch re-sets the intent.
            if self.cachedPointerID == wallpaperID {
                self.cachedPointerID = nil
            }
            self.pointerWriteHadFailure = true
            self.requestLock.unlock()
            NSLog("[Hazel] DesktopPictureService: pointer write failed %@ : %@", self.saverPointerURL.path, error.localizedDescription)
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
        // Snapshot from the in-memory cache (no AppKit, no file I/O, never
        // stateQueue.sync, so main never blocks here).
        requestLock.lock()
        let ready = originalsCacheReady
        let snapshot = originalsCache
        requestLock.unlock()
        guard ready else {
            // Cache cold: warm it on stateQueue, then re-enter on main where
            // AppKit is legal.
            stateQueue.async { [weak self] in
                guard let self else { return }
                if let loaded = self.loadOriginals() {
                    self.requestLock.lock()
                    if !self.originalsCacheReady {
                        self.originalsCache = loaded
                        self.originalsCacheReady = true
                    }
                    self.requestLock.unlock()
                } else {
                    self.requestLock.lock()
                    if !self.originalsCacheReady {
                        self.originalsCache = nil
                        self.originalsCacheReady = true
                    }
                    self.requestLock.unlock()
                }
                DispatchQueue.main.async { [weak self] in self?.restoreAll() }
            }
            return
        }
        guard let originals = snapshot, !originals.isEmpty else { return }
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
        // The cache is the merge point (updated here under lock), so a
        // concurrent remember merged into the cache is never lost; the async
        // persist writes back whatever the cache holds at execution time.
        let keysToRemove = restoredKeys
        if keysToRemove.isEmpty { return }
        requestLock.lock()
        if var cache = originalsCache {
            for key in keysToRemove {
                cache.removeValue(forKey: key)
            }
            originalsCache = cache
        }
        requestLock.unlock()
        persistOriginalsCacheAsync()
    }

    func reconcile() {
        guard SettingsManager.shared.syncSystemWallpaper else { return }
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.reconcile() }
            return
        }
        // Snapshot from the in-memory cache (never stateQueue.sync, so main
        // never blocks on file I/O), then compute missing entries on main
        // where desktopImageURL is legal.
        requestLock.lock()
        let cacheReady = originalsCacheReady
        let cacheSnapshot = originalsCache
        requestLock.unlock()
        guard cacheReady else {
            stateQueue.async { [weak self] in
                guard let self else { return }
                if let loaded = self.loadOriginals() {
                    self.requestLock.lock()
                    if !self.originalsCacheReady {
                        self.originalsCache = loaded
                        self.originalsCacheReady = true
                    }
                    self.requestLock.unlock()
                } else {
                    self.requestLock.lock()
                    if !self.originalsCacheReady {
                        self.originalsCache = nil
                        self.originalsCacheReady = true
                    }
                    self.requestLock.unlock()
                }
                DispatchQueue.main.async { [weak self] in self?.reconcile() }
            }
            return
        }
        guard var originals = cacheSnapshot else { return }
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
            requestLock.lock()
            if var cache = originalsCache {
                for (key, path) in originals where cache[key] == nil {
                    cache[key] = path
                }
                originalsCache = cache
            }
            requestLock.unlock()
            persistOriginalsCacheAsync()
        }
        // New/replugged displays show the still, not the remembered original.
        // Prefer the synchronous in-memory intent over the disk pointer: the
        // pointer write runs on a background queue, so right after a switch
        // the disk still names the PREVIOUS video. Reconciling from disk
        // would re-apply the old still on top of the new desktop (stale
        // saver video / flicker). No switch seen this launch → disk fallback.
        let intentID: UUID? = requestLock.withLock { cachedPointerID }
        let id: UUID
        if let intentID {
            id = intentID
        } else {
            guard let pointer = readSaverPointer(),
                  let diskID = UUID(uuidString: pointer.wallpaperID) else { return }
            id = diskID
        }
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
