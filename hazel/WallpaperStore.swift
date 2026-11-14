import Foundation
import AVFoundation
import AppKit
import Combine

class WallpaperStore: ObservableObject {
    @Published var wallpapers: [WallpaperItem] = []
    var activeWallpaperID: UUID? {
        didSet {
            if let id = activeWallpaperID {
                UserDefaults.standard.set(id.uuidString, forKey: "activeWallpaperID")
            } else {
                UserDefaults.standard.removeObject(forKey: "activeWallpaperID")
            }
        }
    }

    private let fileManager = FileManager.default

    /// Guards migrateContainerIfNeeded against double-run (two stores in one
    /// process) racing normal saves. Migration itself runs synchronously in
    /// init before any save can occur; this flag only dedupes within process.
    /// Across launches, existence + size checks make partial copies retry.
    private static let migrationLock = NSLock()
    private static var migrationDidRun = false
    /// First-success-after-failure logging (avoids logging every success).
    private var saveHadFailure = false
    private var loadHadFailure = false

    private func ensureDirectory(at url: URL) {
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            NSLog("[Hazel] WallpaperStore: could not create dir %@ : %@", url.path, error.localizedDescription)
        }
    }

    private func fileSize(at url: URL) -> Int? {
        (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
    }

    /// Copies via temp sibling + rename so readers never see a partial file
    /// and a crash never leaves a truncated destination that later runs skip.
    /// Verifies size when the source size is known.
    private func atomicCopyItem(from src: URL, to dst: URL) -> Bool {
        let tmp = dst.deletingLastPathComponent()
            .appendingPathComponent(dst.lastPathComponent + ".part-\(UUID().uuidString)")
        do {
            try fileManager.copyItem(at: src, to: tmp)
            if let srcSize = fileSize(at: src), srcSize > 0 {
                guard fileSize(at: tmp) == srcSize else {
                    try? fileManager.removeItem(at: tmp)
                    NSLog("[Hazel] WallpaperStore: copy size mismatch %@ -> %@ (src %d)", src.path, dst.path, srcSize)
                    return false
                }
            }
            if fileManager.fileExists(atPath: dst.path) {
                try fileManager.removeItem(at: dst)
            }
            try fileManager.moveItem(at: tmp, to: dst)
            return true
        } catch {
            try? fileManager.removeItem(at: tmp)
            NSLog("[Hazel] WallpaperStore: copy failed %@ -> %@ : %@", src.path, dst.path, error.localizedDescription)
            return false
        }
    }

    private var appSupportURL: URL {
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            NSLog("[Hazel] WallpaperStore: application support URL missing, using home fallback")
            return fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/LiveWallpaper", isDirectory: true)
        }
        let appFolder = appSupport.appendingPathComponent("LiveWallpaper", isDirectory: true)
        ensureDirectory(at: appFolder)
        return appFolder
    }

    /// Read-path base: same location as appSupportURL but never creates
    /// directories. load() runs synchronously on the main thread at launch;
    /// a mkdir syscall there is pure first-frame cost. Writers keep using
    /// appSupportURL/videosURL/storageURL (which ensure).
    private var appSupportURLForRead: URL {
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/LiveWallpaper", isDirectory: true)
        }
        return appSupport.appendingPathComponent("LiveWallpaper", isDirectory: true)
    }

    private var storageURLForRead: URL {
        appSupportURLForRead.appendingPathComponent("wallpapers.json")
    }

    private var videosURL: URL {
        let videosFolder = appSupportURL.appendingPathComponent("Videos", isDirectory: true)
        ensureDirectory(at: videosFolder)
        return videosFolder
    }

    private var storageURL: URL {
        return appSupportURL.appendingPathComponent("wallpapers.json")
    }

    var activeWallpaper: WallpaperItem? {
        guard let id = activeWallpaperID else { return nil }
        return wallpapers.first { $0.id == id }
    }

    init(runMaintenance: Bool = true) {
        load()
        wantsMaintenance = runMaintenance
    }

    /// Whether deferred maintenance was requested at init. The actual work
    /// starts only via `startDeferredMaintenance()`, which the app calls
    /// after the first video frame composites (or the launch fallback fires):
    /// migration copies (100s of MB), stale-URL repair scans and thumbnail
    /// decodes must never contend with the first-frame decode for disk/CPU/
    /// decoder in the first minute.
    private var wantsMaintenance = false
    private var maintenanceStarted = false
    private let maintenanceLock = NSLock()

    /// Starts the deferred maintenance queued at init. Idempotent: safe to
    /// call from both the first-frame callback and the launch fallback.
    func startDeferredMaintenance() {
        maintenanceLock.lock()
        guard wantsMaintenance, !maintenanceStarted else {
            maintenanceLock.unlock()
            return
        }
        maintenanceStarted = true
        maintenanceLock.unlock()
        scheduleDeferredMaintenance()
    }

    /// Heavy library I/O stays off the launch critical path: load() above is
    /// the only synchronous work (small JSON decode). Migration, stale-URL
    /// repair and thumbnail repair run on a background queue after init returns,
    /// so the first frame can composite while they work. Model mutations hop
    /// back to the main thread. Background (not utility) so bulk copies and
    /// thumbnail decodes never contend the live display decode.
    private func scheduleDeferredMaintenance() {
        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let self else { return }
            self.migrateContainerIfNeeded()
            self.repairStaleURLs()
            self.repairMissingThumbnails()
        }
    }

    /// One-way move from the old sandboxed container to the real Library paths
    /// after Hazel dropped the app sandbox. Idempotent and resumable: every
    /// artifact is verified by existence + size (and JSON decodability), so a
    /// crash or partial copy retries on the next launch instead of being
    /// skipped because a truncated file happens to exist. Never deletes the
    /// container source; never overwrites a valid real library with the old
    /// container copy. Serialized against double-run via migrationLock.
    private func migrateContainerIfNeeded() {
        Self.migrationLock.lock()
        defer { Self.migrationLock.unlock() }
        if Self.migrationDidRun { return }
        Self.migrationDidRun = true

        let home = FileManager.default.homeDirectoryForCurrentUser
        let containerBase = home
            .appendingPathComponent("Library/Containers/com.live.hazel/Data/Library", isDirectory: true)
        let containerAppSupport = containerBase
            .appendingPathComponent("Application Support/LiveWallpaper", isDirectory: true)
        let containerJSON = containerAppSupport.appendingPathComponent("wallpapers.json")
        guard fileManager.fileExists(atPath: containerJSON.path) else { return }

        guard let appSupportBase = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            NSLog("[Hazel] WallpaperStore: real application support URL missing, skipping migration")
            return
        }
        let realAppSupport = appSupportBase
            .appendingPathComponent("LiveWallpaper", isDirectory: true)
        ensureDirectory(at: realAppSupport)

        var migratedAnything = false
        var containerItems: [WallpaperItem]?
        for attempt in 0..<2 {
            if let data = try? Data(contentsOf: containerJSON),
               let items = try? JSONDecoder().decode([WallpaperItem].self, from: data) {
                containerItems = items
                if attempt > 0 {
                    NSLog("[Hazel] WallpaperStore: container library read recovered on retry %@", containerJSON.path)
                }
                break
            } else if attempt == 0 {
                NSLog("[Hazel] WallpaperStore: container library first read failed, retrying once %@", containerJSON.path)
            }
        }
        guard let items = containerItems else {
            let size = fileSize(at: containerJSON) ?? -1
            NSLog("[Hazel] WallpaperStore: container library unreadable, leaving real library untouched %@ (size %d)", containerJSON.path, size)
            return
        }
        ensureDirectory(at: realAppSupport.appendingPathComponent("Videos", isDirectory: true))
        // Bulk video/thumbnail copies can be hundreds of MB: never block the
        // main thread (launch) on them. The JSON below keeps referencing the
        // container paths (the source is never deleted), so deferring the
        // copies is safe; size checks retry anything outstanding next launch.
        let itemsToMigrate = items
        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let self else { return }
            var migratedAnything = false
            for item in itemsToMigrate {
                let dst = realAppSupport.appendingPathComponent("Videos/\(item.url.lastPathComponent)")
                if self.fileManager.fileExists(atPath: dst.path) {
                    // Retry a previous partial copy: size mismatch means truncated.
                    // atomicCopyItem replaces dst itself, so just re-copy.
                    if self.fileManager.fileExists(atPath: item.url.path),
                       let srcSize = self.fileSize(at: item.url), srcSize > 0,
                       self.fileSize(at: dst) != srcSize {
                        if self.atomicCopyItem(from: item.url, to: dst) { migratedAnything = true }
                    }
                } else if self.fileManager.fileExists(atPath: item.url.path) {
                    if self.atomicCopyItem(from: item.url, to: dst) { migratedAnything = true }
                }
                if let thumb = item.thumbnailPath {
                    let thumbName = URL(fileURLWithPath: thumb).lastPathComponent
                    let containerThumb = containerBase
                        .appendingPathComponent("Caches/LiveWallpaper/Thumbnails/\(thumbName)")
                    guard let cachesBase = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
                        NSLog("[Hazel] WallpaperStore: caches URL missing, skipping thumbnail migration title=%@", item.title)
                        continue
                    }
                    let realThumbs = cachesBase
                        .appendingPathComponent("LiveWallpaper/Thumbnails", isDirectory: true)
                    let dstThumb = realThumbs.appendingPathComponent(thumbName)
                    if self.fileManager.fileExists(atPath: dstThumb.path) {
                        if self.fileManager.fileExists(atPath: containerThumb.path),
                           let srcSize = self.fileSize(at: containerThumb), srcSize > 0,
                           self.fileSize(at: dstThumb) != srcSize {
                            self.ensureDirectory(at: realThumbs)
                            if self.atomicCopyItem(from: containerThumb, to: dstThumb) { migratedAnything = true }
                        }
                    } else if self.fileManager.fileExists(atPath: containerThumb.path) {
                        self.ensureDirectory(at: realThumbs)
                        if self.atomicCopyItem(from: containerThumb, to: dstThumb) { migratedAnything = true }
                    }
                }
            }
            if migratedAnything {
                NSLog("[Hazel] WallpaperStore: migrated library out of sandbox container")
            }
        }
        let realJSON = realAppSupport.appendingPathComponent("wallpapers.json")
        let needsJSON: Bool = {
            guard fileManager.fileExists(atPath: realJSON.path) else { return true }
            guard let size = fileSize(at: realJSON), size > 0,
                  let d = try? Data(contentsOf: realJSON),
                  (try? JSONDecoder().decode([WallpaperItem].self, from: d)) != nil else {
                return true
            }
            return false
        }()
        if needsJSON {
            if atomicCopyItem(from: containerJSON, to: realJSON) { migratedAnything = true }
        }
        if migratedAnything {
            NSLog("[Hazel] WallpaperStore: migrated library out of sandbox container")
        }

        let containerPrefs = containerBase
            .appendingPathComponent("Preferences/com.live.hazel.plist")
        if fileManager.fileExists(atPath: containerPrefs.path) {
            if let data = try? Data(contentsOf: containerPrefs),
               let prefs = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                let defaults = UserDefaults.standard
                for key in ["activeWallpaperID", "wallpaperFit", "openOnStartup", "syncSystemWallpaper",
                            "cycleMode", "cycleIntervalMinutes", "cycleDailyHour", "cycleDailyMinute",
                            "lastCycleDate", "didAutoManageSaver", "didAutoApplyLockscreen"] {
                    if defaults.object(forKey: key) == nil, let value = prefs[key] {
                        defaults.set(value, forKey: key)
                    }
                }
            } else {
                NSLog("[Hazel] WallpaperStore: container prefs unreadable, keeping current defaults %@", containerPrefs.path)
            }
        }
    }

    /// Rewrites stored video URLs that no longer resolve (sandbox-container
    /// move, renamed Videos dir, id-based rename). Runs once on load: for each
    /// item whose file is missing, probes the real Videos dir for (a) the same
    /// filename, (b) the container-path rewritten filename, (c) the
    /// id-based name with the same extension, (d) any file prefixed with the
    /// item id. Repairs in place and saves. Items with no candidate are left
    /// untouched — validatedURL still returns nil and the controller aborts
    /// gracefully instead of showing black.
    ///
    /// Deferred-maintenance context: called on a utility queue (see
    /// scheduleDeferredMaintenance), so file probing stays off the main
    /// thread; only the snapshot read and the model update hop to main.
    private func repairStaleURLs() {
        let snapshot: [WallpaperItem] = Thread.isMainThread
            ? wallpapers
            : DispatchQueue.main.sync { wallpapers }
        guard !snapshot.isEmpty else { return }
        let videosDir = videosURL
        let existingFiles: [String]
        do {
            existingFiles = try fileManager.contentsOfDirectory(atPath: videosDir.path)
        } catch {
            NSLog("[Hazel] WallpaperStore: videos dir unreadable %@ : %@ — repair skipped", videosDir.path, error.localizedDescription)
            return
        }
        var repairs: [(id: UUID, url: URL)] = []
        var missingTitles: [(title: String, path: String)] = []
        for item in snapshot {
            if fileManager.fileExists(atPath: item.url.path) { continue }
            let ext = item.url.pathExtension
            var candidates: [URL] = []
            // Same filename in the real library (covers container-path items
            // whose name survived the move).
            candidates.append(videosDir.appendingPathComponent(item.url.lastPathComponent))
            // Id-based name with the same extension (current addWallpaper layout).
            if !ext.isEmpty {
                candidates.append(videosDir.appendingPathComponent("\(item.id.uuidString).\(ext)"))
            }
            // Any file carrying the item id prefix (extension changed, etc.).
            let prefix = item.id.uuidString.lowercased()
            if let prefixed = existingFiles.first(where: { $0.lowercased().hasPrefix(prefix) }) {
                candidates.append(videosDir.appendingPathComponent(prefixed))
            }
            if let hit = candidates.first(where: { fileManager.fileExists(atPath: $0.path) }) {
                NSLog("[Hazel] WallpaperStore: repaired stale URL title=%@ %@ -> %@",
                      item.title, item.url.path, hit.path)
                repairs.append((item.id, hit))
            } else {
                missingTitles.append((item.title, item.url.path))
            }
        }
        for missing in missingTitles {
            NSLog("[Hazel] WallpaperStore: file missing, no repair candidate title=%@ path=%@",
                  missing.title, missing.path)
        }
        guard !repairs.isEmpty || !missingTitles.isEmpty else { return }
        let activeID: UUID? = Thread.isMainThread
            ? activeWallpaperID
            : DispatchQueue.main.sync { activeWallpaperID }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            var changed = false
            for repair in repairs {
                if let index = self.wallpapers.firstIndex(where: { $0.id == repair.id }) {
                    self.wallpapers[index].url = repair.url
                    changed = true
                }
            }
            if changed {
                self.save()
            }
            // Active pointer into a still-missing file must not auto-play black:
            // leave the item for the user, but the controller will abort (isActive
            // stays false) instead of ordering windows.
            if let id = activeID,
               let active = self.wallpapers.first(where: { $0.id == id }),
               !self.fileManager.fileExists(atPath: active.url.path) {
                NSLog("[Hazel] WallpaperStore: active wallpaper missing file title=%@ path=%@ — launch will idle until reselected",
                      active.title, active.url.path)
            }
        }
    }

    /// Regenerates thumbnails whose files went missing. Generation runs off the
    /// main thread; only the model update + save hop back.
    private func repairMissingThumbnails() {
        let missing = wallpapers.indices.filter { index in
            guard let path = wallpapers[index].thumbnailPath else { return true }
            return !FileManager.default.fileExists(atPath: path)
        }
        guard !missing.isEmpty else { return }
        let items = missing.map { (index: $0, url: wallpapers[$0].url, id: wallpapers[$0].id) }
        DispatchQueue.global(qos: .background).async { [weak self] in
            var repaired: [(Int, String)] = []
            for item in items {
                if let path = self?.generateThumbnail(for: item.url, id: item.id) {
                    repaired.append((item.index, path))
                }
            }
            guard !repaired.isEmpty else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                for (index, path) in repaired where wallpapers.indices.contains(index) {
                    self.wallpapers[index].thumbnailPath = path
                }
                self.save()
            }
        }
    }

    /// Tolerates a torn read from an in-flight atomic save: one short retry,
    /// then keeps the existing model (never caches garbage). Read path never
    /// creates directories (see storageURLForRead): launch must not pay a
    /// mkdir before the first frame.
    func load() {
        let url = storageURLForRead
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            wallpapers = try JSONDecoder().decode([WallpaperItem].self, from: data)
            if let idString = UserDefaults.standard.string(forKey: "activeWallpaperID"),
               let id = UUID(uuidString: idString),
               wallpapers.contains(where: { $0.id == id }) {
                activeWallpaperID = id
            }
            if loadHadFailure {
                loadHadFailure = false
                NSLog("[Hazel] WallpaperStore: library load recovered %@", url.path)
            }
        } catch {
            // Possible torn read mid-rename: one immediate retry before giving
            // up. No sleep: this runs on the main thread at launch and the
            // second read of an atomic rename almost always wins.
            // Log the first failure so torn reads are visible in Console.app.
            NSLog("[Hazel] WallpaperStore: library load first read failed %@ : %@ — retrying once", url.path, (error as NSError).localizedDescription)
            do {
                let data = try Data(contentsOf: url)
                wallpapers = try JSONDecoder().decode([WallpaperItem].self, from: data)
                if let idString = UserDefaults.standard.string(forKey: "activeWallpaperID"),
                   let id = UUID(uuidString: idString),
                   wallpapers.contains(where: { $0.id == id }) {
                    activeWallpaperID = id
                }
                if loadHadFailure {
                    loadHadFailure = false
                    NSLog("[Hazel] WallpaperStore: library load recovered %@", url.path)
                }
            } catch {
                loadHadFailure = true
                let size = fileSize(at: url) ?? -1
                NSLog("[Hazel] WallpaperStore: library load failed %@ (size %d) : %@ — keeping existing model", url.path, size, (error as NSError).localizedDescription)
            }
        }
    }

    func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(wallpapers)
            try data.write(to: storageURL, options: .atomic)
            if saveHadFailure {
                saveHadFailure = false
                NSLog("[Hazel] WallpaperStore: library save recovered %@", storageURL.path)
            }
        } catch {
            saveHadFailure = true
            NSLog("[Hazel] WallpaperStore: library save failed %@ : %@", storageURL.path, error.localizedDescription)
        }
    }

    func addWallpaper(url: URL) -> WallpaperItem? {
        // Best-effort scoped access: non-sandboxed URLs return false and need
        // no stopAccessing; sandboxed ones do.
        let needsStop = url.startAccessingSecurityScopedResource()
        defer { if needsStop { url.stopAccessingSecurityScopedResource() } }

        let fileName = url.deletingPathExtension().lastPathComponent

        if wallpapers.contains(where: { $0.title == fileName }) {
            NSLog("[Hazel] WallpaperStore: video already in library: %@", fileName)
            return nil
        }

        let id = UUID()
        let title = fileName
        let videoExtension = url.pathExtension
        let destinationURL = videosURL.appendingPathComponent("\(id.uuidString).\(videoExtension)")

        guard atomicCopyItem(from: url, to: destinationURL) else {
            return nil
        }

        let itemURL = destinationURL
        let item = WallpaperItem(url: itemURL, title: title)

        wallpapers.insert(item, at: 0)
        save()
        // Thumbnail decode must not block the caller (main thread during
        // import): AVAssetImageGenerator can stall up to 10s on a slow file.
        // Insert first, fill the thumbnail in when the background pass lands.
        let insertedID = item.id
        DispatchQueue.global(qos: .background).async { [weak self, itemURL] in
            guard let self, let path = self.generateThumbnail(for: itemURL, id: insertedID) else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      let index = self.wallpapers.firstIndex(where: { $0.id == insertedID }) else { return }
                self.wallpapers[index].thumbnailPath = path
                self.save()
            }
        }
        return item
    }

    func removeWallpaper(_ item: WallpaperItem) {
        if let index = wallpapers.firstIndex(where: { $0.id == item.id }) {
            if let thumbnailPath = wallpapers[index].thumbnailPath {
                do {
                    try fileManager.removeItem(atPath: thumbnailPath)
                } catch {
                    NSLog("[Hazel] WallpaperStore: thumbnail remove failed %@ : %@", thumbnailPath, error.localizedDescription)
                }
            }

            do {
                try fileManager.removeItem(at: item.url)
            } catch {
                NSLog("[Hazel] WallpaperStore: video remove failed %@ : %@", item.url.path, error.localizedDescription)
            }

            wallpapers.remove(at: index)
            save()
        }

        if activeWallpaperID == item.id {
            activeWallpaperID = nil
        }
    }

    func setActiveWallpaper(_ item: WallpaperItem) {
        activeWallpaperID = item.id
    }

    func toggleLoop(for item: WallpaperItem) {
        if let index = wallpapers.firstIndex(where: { $0.id == item.id }) {
            wallpapers[index].isLooping.toggle()
            save()
        }
    }

    func toggleMute(for item: WallpaperItem) {
        if let index = wallpapers.firstIndex(where: { $0.id == item.id }) {
            wallpapers[index].isMuted.toggle()
            save()
        }
    }

    /// Validates that a stored library URL still resolves to a real file.
    /// (No security-scoped bookmarks are used: Hazel copies imports into its
    /// own folder and validates plain paths instead.)
    func validatedURL(_ url: URL) -> URL? {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir) else {
            NSLog("[Hazel] WallpaperStore: file missing at path: %@", url.path)
            return nil
        }
        if isDir.boolValue {
            NSLog("[Hazel] WallpaperStore: path is directory, not a file: %@", url.path)
            return nil
        }
        if let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue, size == 0 {
            NSLog("[Hazel] WallpaperStore: file is zero bytes: %@", url.path)
            return nil
        }
        guard fileManager.isReadableFile(atPath: url.path) else {
            NSLog("[Hazel] WallpaperStore: file unreadable at path: %@", url.path)
            return nil
        }
        return url
    }

    private func generateThumbnail(for url: URL, id: UUID) -> String? {
        guard let cachesDir = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            NSLog("[Hazel] WallpaperStore: caches URL missing, cannot generate thumbnail id=%@", id.uuidString)
            return nil
        }
        let thumbnailsDir = cachesDir.appendingPathComponent("LiveWallpaper/Thumbnails", isDirectory: true)
        ensureDirectory(at: thumbnailsDir)

        let thumbnailPath = thumbnailsDir.appendingPathComponent("\(id.uuidString).png").path

        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 440, height: 248)

        let time = CMTime(seconds: 2, preferredTimescale: 600)

        var resultImage: CGImage?
        let semaphore = DispatchSemaphore(value: 0)

        generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, cgImage, _, _, _ in
            resultImage = cgImage
            semaphore.signal()
        }

        _ = semaphore.wait(timeout: .now() + 10)

        guard let cgImage = resultImage else {
            return nil
        }

        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        if let tiffData = nsImage.tiffRepresentation,
           let bitmapRep = NSBitmapImageRep(data: tiffData),
           let pngData = bitmapRep.representation(using: .png, properties: [:]) {
            do {
                // Atomic: repairMissingThumbnails readers + thumbnail UI may read mid-write.
                try pngData.write(to: URL(fileURLWithPath: thumbnailPath), options: .atomic)
                return thumbnailPath
            } catch {
                NSLog("[Hazel] WallpaperStore: thumbnail write failed %@ : %@", thumbnailPath, error.localizedDescription)
            }
        }

        return nil
    }

    func loadThumbnailImage(for item: WallpaperItem) -> NSImage? {
        guard let thumbnailPath = item.thumbnailPath else { return nil }
        let url = URL(fileURLWithPath: thumbnailPath)
        return NSImage(contentsOf: url)
    }
}
