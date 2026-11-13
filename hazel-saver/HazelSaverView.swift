import ScreenSaver
import AVFoundation
import AppKit
import QuartzCore
import Darwin

/// Hazel screensaver: plays the current Hazel video full-screen.
/// Reads ~/Library/Application Support/LiveWallpaper/hazel-current.json
/// (written by the Hazel app on every wallpaper change) and pre-builds the
/// player in `init` so the first frame is ready when the animation starts.
/// Previews never decode video: they draw black only.
/// Hardened: single player max, fail-fast file checks, KVO-gated reveal
/// (no black flash), last-frame preserved on mid-play failure, pause on
/// hide/occlusion, full teardown on stop/deinit, NSLog diagnostics.
@objc(HazelSaverView)
class HazelSaverView: ScreenSaverView {

    private struct SaverPointer: Codable {
        var videoPath: String
        var wallpaperID: String
        var fit: String
        var isLooping: Bool
        var isMuted: Bool
    }

    private static func log(_ message: String) {
        NSLog("[HazelSaver] %@", message)
    }

    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var playerLayer: AVPlayerLayer?
    private var willStopObserver: NSObjectProtocol?
    private var itemStatusObservation: NSKeyValueObservation?
    private var itemFailedObserver: NSObjectProtocol?
    private var windowOcclusionObserver: NSObjectProtocol?
    private var currentURL: URL?
    private var isReady = false
    private var playbackFailed = false
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
        Self.log("init preview=\(preview) frame=\(Int(frame.width))x\(Int(frame.height))")
        if !actualIsPreview, frame != .zero {
            _ = prewarmPlayer()
        }
    }

    required init?(coder: NSCoder) {
        actualIsPreview = true
        super.init(coder: coder)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        animationTimeInterval = 1.0 / 30.0
        Self.log("init coder preview=true (no decode until start)")
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

    /// Fail-fast file check. Returns nil when playable, else a short reason.
    private func fileValidationError(for url: URL) -> String? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            return "missing"
        }
        if isDir.boolValue {
            return "is-directory"
        }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            return "unreadable-permissions"
        }
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            if let size = attrs[.size] as? NSNumber, size.int64Value <= 0 {
                return "zero-byte"
            }
        } catch {
            return "stat-failed"
        }
        return nil
    }

    private func newestVideo(in dir: URL) -> URL? {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        let videos = files.filter { ["mp4", "mov", "m4v"].contains($0.pathExtension.lowercased()) }
        let sorted = videos.sorted {
            let d0 = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
            let d1 = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
            return d0 > d1
        }
        // Return the newest file that passes fail-fast checks (skips zero-byte/unreadable).
        for url in sorted where fileValidationError(for: url) == nil {
            return url
        }
        return nil
    }

    private func resolveVideoURL() -> (URL, SaverPointer?)? {
        var notes: [String] = []
        for home in candidateHomes() {
            let pointerURL = home
                .appendingPathComponent("Library/Application Support/LiveWallpaper/hazel-current.json")
            if FileManager.default.fileExists(atPath: pointerURL.path) {
                guard let data = try? Data(contentsOf: pointerURL) else {
                    notes.append("pointer-unreadable")
                    continue
                }
                if data.isEmpty {
                    notes.append("pointer-empty")
                } else {
                    do {
                        let pointer = try JSONDecoder().decode(SaverPointer.self, from: data)
                        if pointer.videoPath.isEmpty {
                            notes.append("pointer-empty-path")
                        } else {
                            let url = URL(fileURLWithPath: pointer.videoPath)
                            if let err = fileValidationError(for: url) {
                                notes.append("pointer-target-\(err)")
                            } else {
                                Self.log("resolve ok pointer \(url.path)")
                                return (url, pointer)
                            }
                        }
                    } catch {
                        notes.append("pointer-corrupt")
                    }
                }
            }
            let realVideos = home
                .appendingPathComponent("Library/Application Support/LiveWallpaper/Videos", isDirectory: true)
            if let newest = newestVideo(in: realVideos) {
                Self.log("resolve ok videos-fallback \(newest.path)")
                return (newest, nil)
            }
            let containerVideos = home
                .appendingPathComponent("Library/Containers/com.live.hazel/Data/Library/Application Support/LiveWallpaper/Videos", isDirectory: true)
            if let newest = newestVideo(in: containerVideos) {
                Self.log("resolve ok container-fallback \(newest.path)")
                return (newest, nil)
            }
        }
        if notes.isEmpty {
            Self.log("resolve failed no-pointer-no-videos")
        } else {
            Self.log("resolve failed \(notes.joined(separator: "; "))")
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

    /// Core builder: validates then builds one player. Caller must have torn
    /// down any existing player (single-instance invariant).
    private func buildPlayer(url: URL, pointer: SaverPointer?) -> Bool {
        if let err = fileValidationError(for: url) {
            Self.log("prewarm reject \(url.path) (\(err))")
            return false
        }
        if !["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased()) {
            Self.log("prewarm warn non-video-extension \(url.path), trying anyway")
        }
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        let queuePlayer = AVQueuePlayer(playerItem: item)
        queuePlayer.isMuted = true
        queuePlayer.volume = 0
        if pointer?.isLooping != false {
            looper = AVPlayerLooper(player: queuePlayer, templateItem: item)
        }
        let layer = AVPlayerLayer(player: queuePlayer)
        layer.videoGravity = gravity(for: pointer?.fit ?? "Fill")
        layer.frame = bounds
        layer.opacity = 0 // hidden until item reports ready; revealed without implicit fade
        self.layer?.addSublayer(layer)
        playerLayer = layer
        player = queuePlayer
        currentURL = url
        isReady = false
        playbackFailed = false
        attachItemObservers(to: item)
        queuePlayer.pause() // prewarm only: first frame renders while paused, no autoplay
        Self.log("prewarm ok \(url.path)")
        return true
    }

    /// Builds the player and layer without starting playback, so `startAnimation`
    /// only has to press play (no black flash while the first frame decodes).
    @discardableResult
    private func prewarmPlayer() -> Bool {
        guard !actualIsPreview else { return false }
        guard player == nil, playerLayer == nil else { return true }
        guard let (url, pointer) = resolveVideoURL() else { return false }
        return buildPlayer(url: url, pointer: pointer)
    }

    private func attachItemObservers(to item: AVPlayerItem) {
        detachItemObservers()
        itemStatusObservation = item.observe(\.status, options: [.new]) { [weak self] observed, _ in
            DispatchQueue.main.async { [weak self] in self?.handleItemStatus(observed) }
        }
        itemFailedObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
        ) { [weak self] note in
            let reason = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError)?.localizedDescription ?? "play-to-end-failed"
            self?.handleItemFailure(reason: reason)
        }
    }

    private func detachItemObservers() {
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        if let token = itemFailedObserver {
            NotificationCenter.default.removeObserver(token)
            itemFailedObserver = nil
        }
    }

    private func revealLayer() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer?.opacity = 1
        CATransaction.commit()
    }

    private func handleItemStatus(_ item: AVPlayerItem) {
        switch item.status {
        case .readyToPlay:
            isReady = true
            playbackFailed = false
            player?.isMuted = true
            revealLayer()
            Self.log("ready \(currentURL?.path ?? "?")")
        case .failed:
            handleItemFailure(reason: item.error?.localizedDescription ?? "item-failed")
        case .unknown:
            break
        @unknown default:
            break
        }
    }

    /// Pre-ready failure: nothing was ever shown, tear down for a clean retry.
    /// Mid-play failure: keep the paused player+layer so the last good frame
    /// stays on screen instead of flashing to black.
    private func handleItemFailure(reason: String) {
        Self.log("playback error (\(reason)) url=\(currentURL?.path ?? "?")")
        playbackFailed = true
        player?.pause()
        player?.isMuted = true
        guard isReady else {
            detachItemObservers()
            playerLayer?.removeFromSuperlayer()
            looper?.disableLooping()
            looper = nil
            player = nil
            playerLayer = nil
            currentURL = nil
            return
        }
        detachItemObservers() // stop further callbacks, but keep player+layer for last frame
    }

    private func stopPlayer() {
        detachItemObservers()
        player?.pause()
        looper?.disableLooping()
        playerLayer?.removeFromSuperlayer()
        looper = nil
        player = nil
        playerLayer = nil
        currentURL = nil
        isReady = false
        playbackFailed = false
    }

    override func startAnimation() {
        super.startAnimation()
        if started {
            Self.log("start ignored already-started")
            return
        }
        // init(coder:) always starts as preview (safe: no decode). Promote here
        // when bounds prove this is a full-screen run, not a thumbnail.
        if actualIsPreview, bounds.width > 400, bounds.height > 300 {
            actualIsPreview = false
            Self.log("start promote-to-full bounds=\(Int(bounds.width))x\(Int(bounds.height))")
        }
        if actualIsPreview {
            started = true
            return
        }
        started = true
        if playbackFailed, player != nil {
            // A mid-play failure preserved the last frame. Validate a fresh
            // candidate BEFORE destroying it; keep last frame when none exists.
            if let (freshURL, freshPointer) = resolveVideoURL(),
               fileValidationError(for: freshURL) == nil {
                Self.log("start retry-after-failure \(freshURL.path)")
                stopPlayer()
                _ = buildPlayer(url: freshURL, pointer: freshPointer)
            } else {
                Self.log("start keep-last-frame no-fresh-candidate")
                return
            }
        } else if player == nil {
            _ = prewarmPlayer()
        }
        guard let queuePlayer = player, let url = currentURL else {
            Self.log("start no-video staying-black (will retry next start)")
            return
        }
        queuePlayer.isMuted = true
        queuePlayer.volume = 0
        playerLayer?.frame = bounds
        if isReady {
            revealLayer()
        }
        queuePlayer.play()
        Self.log("play start \(url.path)")
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
        stopPlayer() // idempotent: safe when start never ran
        started = false
        if let observer = willStopObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
            willStopObserver = nil
        }
    }

    private func applyOcclusionPolicy() {
        guard started, !actualIsPreview, !playbackFailed, player != nil else { return }
        guard !isHiddenOrHasHiddenAncestor else { return }
        let visible = window?.occlusionState.contains(.visible) ?? true
        if visible {
            player?.isMuted = true
            player?.play()
        } else {
            player?.pause() // covered: stop decoding, keep layer for instant resume
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        playerLayer?.frame = bounds
        if let old = windowOcclusionObserver {
            NotificationCenter.default.removeObserver(old)
            windowOcclusionObserver = nil
        }
        if let win = window {
            windowOcclusionObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: win, queue: .main
            ) { [weak self] _ in self?.applyOcclusionPolicy() }
        }
    }

    override func viewDidHide() {
        super.viewDidHide()
        if started {
            player?.pause()
        }
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        applyOcclusionPolicy()
    }

    override func layout() {
        super.layout()
        playerLayer?.frame = bounds
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        playerLayer?.frame = bounds
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        playerLayer?.frame = bounds // moved across displays / Retina change
    }

    override func draw(_ rect: NSRect) {
        super.draw(rect)
        NSColor.black.set()
        NSBezierPath(rect: bounds).fill()
        // Help text in preview only. Full mode stays pure black on failure
        // (never bare-black-plus-help), with last frame preserved when possible.
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
        // Teardown order: notification observers first (no callbacks during
        // teardown), then KVO, then pause/loop-off/layer-remove, then nil.
        if let observer = willStopObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        if let observer = windowOcclusionObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        detachItemObservers()
        player?.pause()
        looper?.disableLooping()
        playerLayer?.removeFromSuperlayer()
    }
}
