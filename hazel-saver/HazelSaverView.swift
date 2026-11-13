import ScreenSaver
import AVFoundation
import AppKit
import Darwin

/// Hazel screensaver: plays the current Hazel video full-screen.
/// Reads ~/Library/Application Support/LiveWallpaper/hazel-current.json
/// (written by the Hazel app on every wallpaper change) and pre-builds the
/// player in `init` so the first frame is ready when the animation starts.
/// Previews never decode video: they draw black only.
@objc(HazelSaverView)
class HazelSaverView: ScreenSaverView {

    private struct SaverPointer: Codable {
        var videoPath: String
        var wallpaperID: String
        var fit: String
        var isLooping: Bool
        var isMuted: Bool
    }

    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var playerLayer: AVPlayerLayer?
    private var willStopObserver: NSObjectProtocol?
    private var actualIsPreview: Bool = true
    private var started = false

    override init(frame: NSRect, isPreview: Bool) {
        var preview = isPreview
        if #available(macOS 26.0, *) {
            let locked = (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
            preview = !locked
        } else if frame.width > 400 && frame.height > 300 {
            preview = false
        }
        actualIsPreview = preview
        super.init(frame: frame, isPreview: preview)!
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        animationTimeInterval = 1.0 / 30.0
        if !actualIsPreview, frame != .zero {
            prewarmPlayer()
        }
    }

    required init?(coder: NSCoder) {
        actualIsPreview = true
        super.init(coder: coder)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        animationTimeInterval = 1.0 / 30.0
    }

    /// Candidate homes: POSIX home first (sandbox-proof), then Foundation guesses.
    /// homeDirectoryForCurrentUser can resolve into the host's container, hiding the pointer.
    private func candidateHomes() -> [URL] {
        var homes: [URL] = []
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            let path = String(cString: dir)
            if !path.isEmpty {
                homes.append(URL(fileURLWithPath: path, isDirectory: true))
            }
        }
        if !NSUserName().isEmpty {
            homes.append(URL(fileURLWithPath: "/Users/\(NSUserName())", isDirectory: true))
        }
        homes.append(FileManager.default.homeDirectoryForCurrentUser)
        var seen = Set<String>()
        return homes.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private func newestVideo(in dir: URL) -> URL? {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        let videos = files.filter { ["mp4", "mov", "m4v"].contains($0.pathExtension.lowercased()) }
        return videos.sorted {
            let d0 = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
            let d1 = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
            return d0 > d1
        }.first
    }

    private func resolveVideoURL() -> (URL, SaverPointer?)? {
        for home in candidateHomes() {
            let pointerURL = home
                .appendingPathComponent("Library/Application Support/LiveWallpaper/hazel-current.json")
            if let data = try? Data(contentsOf: pointerURL),
               let pointer = try? JSONDecoder().decode(SaverPointer.self, from: data) {
                let url = URL(fileURLWithPath: pointer.videoPath)
                if FileManager.default.fileExists(atPath: url.path) {
                    return (url, pointer)
                }
            }
            let realVideos = home
                .appendingPathComponent("Library/Application Support/LiveWallpaper/Videos", isDirectory: true)
            if let newest = newestVideo(in: realVideos) {
                return (newest, nil)
            }
            let containerVideos = home
                .appendingPathComponent("Library/Containers/com.live.hazel/Data/Library/Application Support/LiveWallpaper/Videos", isDirectory: true)
            if let newest = newestVideo(in: containerVideos) {
                return (newest, nil)
            }
        }
        return nil
    }

    private func gravity(for fit: String) -> AVLayerVideoGravity {
        switch fit {
        case "Fit", "Center": return .resizeAspect
        case "Stretch": return .resize
        default: return .resizeAspectFill
        }
    }

    /// Builds the player and layer without starting playback, so `startAnimation`
    /// only has to press play (no black flash while the first frame decodes).
    private func prewarmPlayer() {
        guard player == nil, let (url, pointer) = resolveVideoURL() else { return }
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        let queuePlayer = AVQueuePlayer(playerItem: item)
        if pointer?.isLooping != false {
            looper = AVPlayerLooper(player: queuePlayer, templateItem: item)
        }
        let layer = AVPlayerLayer(player: queuePlayer)
        layer.videoGravity = gravity(for: pointer?.fit ?? "Fill")
        layer.frame = bounds
        self.layer?.addSublayer(layer)
        playerLayer = layer
        player = queuePlayer
        queuePlayer.isMuted = true
    }

    private func stopPlayer() {
        player?.pause()
        playerLayer?.removeFromSuperlayer()
        looper?.disableLooping()
        looper = nil
        player = nil
        playerLayer = nil
    }

    override func startAnimation() {
        super.startAnimation()
        if started { return }
        started = true
        if actualIsPreview {
            return
        }
        if player == nil {
            prewarmPlayer()
        }
        player?.play()
        if willStopObserver == nil {
            willStopObserver = DistributedNotificationCenter.default().addObserver(
                forName: NSNotification.Name("com.apple.screensaver.willstop"),
                object: nil, queue: .main
            ) { [weak self] _ in
                self?.stopPlayer()
                self?.started = false
            }
        }
    }

    override func stopAnimation() {
        super.stopAnimation()
        stopPlayer()
        started = false
        if let observer = willStopObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
            willStopObserver = nil
        }
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        playerLayer?.frame = bounds
    }

    override func draw(_ rect: NSRect) {
        super.draw(rect)
        NSColor.black.set()
        NSBezierPath(rect: bounds).fill()
        if actualIsPreview, player == nil {
            let msg = "Pick a video in Hazel to preview it here"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            let size = msg.size(withAttributes: attrs)
            msg.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
                     withAttributes: attrs)
        }
    }

    deinit {
        stopPlayer()
        if let observer = willStopObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
    }
}
