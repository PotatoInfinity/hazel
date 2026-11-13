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
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appFolder = appSupport.appendingPathComponent("LiveWallpaper", isDirectory: true)
        ensureDirectory(at: appFolder)
        return appFolder
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

    init() {
        migrateContainerIfNeeded()
        load()
        repairMissingThumbnails()
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

        let realAppSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("LiveWallpaper", isDirectory: true)
        ensureDirectory(at: realAppSupport)

        var migratedAnything = false
        guard let data = try? Data(contentsOf: containerJSON),
              let items = try? JSONDecoder().decode([WallpaperItem].self, from: data) else {
            let size = fileSize(at: containerJSON) ?? -1
            NSLog("[Hazel] WallpaperStore: container library unreadable, leaving real library untouched %@ (size %d)", containerJSON.path, size)
            return
        }
        ensureDirectory(at: realAppSupport.appendingPathComponent("Videos", isDirectory: true))
        for item in items {
            let dst = realAppSupport.appendingPathComponent("Videos/\(item.url.lastPathComponent)")
            if fileManager.fileExists(atPath: dst.path) {
                // Retry a previous partial copy: size mismatch means truncated.
                // atomicCopyItem replaces dst itself, so just re-copy.
                if fileManager.fileExists(atPath: item.url.path),
                   let srcSize = fileSize(at: item.url), srcSize > 0,
                   fileSize(at: dst) != srcSize {
                    if atomicCopyItem(from: item.url, to: dst) { migratedAnything = true }
                }
            } else if fileManager.fileExists(atPath: item.url.path) {
                if atomicCopyItem(from: item.url, to: dst) { migratedAnything = true }
            }
            if let thumb = item.thumbnailPath {
                let thumbName = URL(fileURLWithPath: thumb).lastPathComponent
                let containerThumb = containerBase
                    .appendingPathComponent("Caches/LiveWallpaper/Thumbnails/\(thumbName)")
                let realThumbs = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
                    .appendingPathComponent("LiveWallpaper/Thumbnails", isDirectory: true)
                let dstThumb = realThumbs.appendingPathComponent(thumbName)
                if fileManager.fileExists(atPath: dstThumb.path) {
                    if fileManager.fileExists(atPath: containerThumb.path),
                       let srcSize = fileSize(at: containerThumb), srcSize > 0,
                       fileSize(at: dstThumb) != srcSize {
                        ensureDirectory(at: realThumbs)
                        if atomicCopyItem(from: containerThumb, to: dstThumb) { migratedAnything = true }
                    }
                } else if fileManager.fileExists(atPath: containerThumb.path) {
                    ensureDirectory(at: realThumbs)
                    if atomicCopyItem(from: containerThumb, to: dstThumb) { migratedAnything = true }
                }
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

    /// Regenerates thumbnails whose files went missing. Generation runs off the
    /// main thread; only the model update + save hop back.
    private func repairMissingThumbnails() {
        let missing = wallpapers.indices.filter { index in
            guard let path = wallpapers[index].thumbnailPath else { return true }
            return !FileManager.default.fileExists(atPath: path)
        }
        guard !missing.isEmpty else { return }
        let items = missing.map { (index: $0, url: wallpapers[$0].url, id: wallpapers[$0].id) }
        DispatchQueue.global(qos: .utility).async { [weak self] in
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
    /// then keeps the existing model (never caches garbage).
    func load() {
        guard fileManager.fileExists(atPath: storageURL.path) else { return }
        do {
            let data = try Data(contentsOf: storageURL)
            wallpapers = try JSONDecoder().decode([WallpaperItem].self, from: data)
            if let idString = UserDefaults.standard.string(forKey: "activeWallpaperID"),
               let id = UUID(uuidString: idString),
               wallpapers.contains(where: { $0.id == id }) {
                activeWallpaperID = id
            }
            if loadHadFailure {
                loadHadFailure = false
                NSLog("[Hazel] WallpaperStore: library load recovered %@", storageURL.path)
            }
        } catch {
            // Possible torn read mid-rename: one short retry before giving up.
            Thread.sleep(forTimeInterval: 0.05)
            do {
                let data = try Data(contentsOf: storageURL)
                wallpapers = try JSONDecoder().decode([WallpaperItem].self, from: data)
                if let idString = UserDefaults.standard.string(forKey: "activeWallpaperID"),
                   let id = UUID(uuidString: idString),
                   wallpapers.contains(where: { $0.id == id }) {
                    activeWallpaperID = id
                }
                if loadHadFailure {
                    loadHadFailure = false
                    NSLog("[Hazel] WallpaperStore: library load recovered %@", storageURL.path)
                }
            } catch {
                loadHadFailure = true
                let size = fileSize(at: storageURL) ?? -1
                NSLog("[Hazel] WallpaperStore: library load failed %@ (size %d) : %@ — keeping existing model", storageURL.path, size, (error as NSError).localizedDescription)
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
        var item = WallpaperItem(url: itemURL, title: title)

        if let thumbnailPath = generateThumbnail(for: itemURL, id: id) {
            item.thumbnailPath = thumbnailPath
        }

        wallpapers.insert(item, at: 0)
        save()
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
        guard fileManager.fileExists(atPath: url.path) else {
            NSLog("[Hazel] WallpaperStore: file missing at path: %@", url.path)
            return nil
        }
        return url
    }

    private func generateThumbnail(for url: URL, id: UUID) -> String? {
        let cachesDir = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
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
