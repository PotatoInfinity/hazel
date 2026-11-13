import AppKit
import AVFoundation
import CoreGraphics

class DesktopPictureService {
    static let shared = DesktopPictureService()

    private let fileManager = FileManager.default
    /// Serializes originals load-modify-save and still apply ordering.
    private let stateQueue = DispatchQueue(label: "com.live.hazel.desktop-picture")
    private let requestLock = NSLock()
    private var latestRequestID: UUID?

    private var stillsDir: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("LiveWallpaper/DesktopStills", isDirectory: true)
        do {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            print("DesktopPictureService: could not create stills dir: \(error)")
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
            print("DesktopPictureService: video missing or empty: \(video.path)")
            return nil
        }
        let destination = stillURL(for: wallpaperID)
        let asset = AVURLAsset(url: video)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1920, height: 1920)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)

        var cgImage: CGImage?
        do {
            cgImage = try generator.copyCGImage(at: clampedTarget(for: asset, seconds: seconds), actualTime: nil)
        } catch {
            do {
                cgImage = try generator.copyCGImage(at: .zero, actualTime: nil)
            } catch {
                print("DesktopPictureService: frame extraction failed: \(error)")
                return nil
            }
        }

        guard let image = cgImage else { return nil }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else {
            return nil
        }
        do {
            try jpeg.write(to: destination, options: .atomic)
            return destination
        } catch {
            print("DesktopPictureService: write failed: \(error)")
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
    private func loadOriginals() -> [String: String]? {
        guard fileManager.fileExists(atPath: originalsURL.path) else { return [:] }
        guard let data = try? Data(contentsOf: originalsURL),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
            print("DesktopPictureService: originals file corrupt, preserving it untouched")
            return nil
        }
        return dict
    }

    private func saveOriginals(_ dict: [String: String]) {
        guard let data = try? JSONEncoder().encode(dict) else { return }
        do {
            try data.write(to: originalsURL, options: .atomic)
        } catch {
            print("DesktopPictureService: originals save failed: \(error)")
        }
    }

    private func rememberOriginal(of screen: NSScreen) {
        stateQueue.sync {
            guard var originals = loadOriginals() else { return }
            let key = displayUUID(for: screen)
            if originals[key] != nil { return }
            if let current = NSWorkspace.shared.desktopImageURL(for: screen), !isOurs(current) {
                originals[key] = current.path
                saveOriginals(originals)
            }
        }
    }

    /// Applies `still` on the main thread; skips screens already showing it
    /// (symlink-resolved compare avoids redundant sets/flicker).
    private func applyOnMain(still: URL, requestID: UUID) {
        requestLock.lock()
        let current = latestRequestID == requestID
        requestLock.unlock()
        guard current else { return }
        for screen in NSScreen.screens {
            rememberOriginal(of: screen)
            let showing = NSWorkspace.shared.desktopImageURL(for: screen)?
                .standardizedFileURL.resolvingSymlinksInPath()
            if showing == still.standardizedFileURL.resolvingSymlinksInPath() {
                continue
            }
            do {
                try NSWorkspace.shared.setDesktopImageURL(still, for: screen, options: [:])
            } catch {
                print("DesktopPictureService: setDesktopImageURL failed: \(error)")
            }
        }
    }

    func apply(still: URL) {
        if Thread.isMainThread {
            requestLock.lock()
            latestRequestID = nil
            requestLock.unlock()
            for screen in NSScreen.screens {
                rememberOriginal(of: screen)
                let showing = NSWorkspace.shared.desktopImageURL(for: screen)?
                    .standardizedFileURL.resolvingSymlinksInPath()
                if showing == still.standardizedFileURL.resolvingSymlinksInPath() {
                    continue
                }
                do {
                    try NSWorkspace.shared.setDesktopImageURL(still, for: screen, options: [:])
                } catch {
                    print("DesktopPictureService: setDesktopImageURL failed: \(error)")
                }
            }
        } else {
            DispatchQueue.main.sync {
                self.apply(still: still)
            }
        }
    }

    /// Extraction runs off the main thread so switching videos never hitches;
    /// only the latest request applies (stale extractions are discarded).
    func syncCurrentVideo(video: URL?, wallpaperID: UUID?) {
        guard let video, let wallpaperID else { return }
        requestLock.lock()
        latestRequestID = wallpaperID
        requestLock.unlock()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            guard let still = self.extractFrame(video: video, wallpaperID: wallpaperID) else { return }
            DispatchQueue.main.async {
                self.applyOnMain(still: still, requestID: wallpaperID)
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
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("hazel-current.json")
    }

    func readSaverPointer() -> SaverPointer? {
        guard let data = try? Data(contentsOf: saverPointerURL) else { return nil }
        return try? JSONDecoder().decode(SaverPointer.self, from: data)
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
        if let data = try? JSONEncoder().encode(pointer) {
            try? data.write(to: saverPointerURL, options: .atomic)
        }
    }

    func restoreAll() {
        stateQueue.sync {
            guard var originals = loadOriginals(), !originals.isEmpty else { return }
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
                    print("DesktopPictureService: restore failed: \(error)")
                }
            }
            // Keep keys for unplugged displays and failed restores; never wipe blindly.
            for key in restoredKeys {
                originals.removeValue(forKey: key)
            }
            if originals.isEmpty {
                try? fileManager.removeItem(at: originalsURL)
            } else {
                saveOriginals(originals)
            }
        }
    }

    func reconcile() {
        guard SettingsManager.shared.syncSystemWallpaper else { return }
        let needsStill = stateQueue.sync { () -> Bool in
            guard var originals = loadOriginals() else { return false }
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
                saveOriginals(originals)
            }
            return true
        }
        // New/replugged displays show the still, not the remembered original.
        guard needsStill,
              let pointer = readSaverPointer(),
              let id = UUID(uuidString: pointer.wallpaperID) else { return }
        let still = stillURL(for: id)
        if fileManager.fileExists(atPath: still.path) {
            apply(still: still)
        }
    }
}
