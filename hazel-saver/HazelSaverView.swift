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
    /// Mid-run retarget: the app rewrites the pointer on every switch — even
    /// obscured (deferred-decode) ones — so a running saver would otherwise
    /// play the previous video until the next start. The replacement player
    /// prewarms hidden and promotes only on ready (no unready swap); a
    /// failure discards it and keeps the current video.
    private var nextPlayer: AVQueuePlayer?
    private var nextLooper: AVPlayerLooper?
    private var nextLayer: AVPlayerLayer?
    private var nextItem: AVPlayerItem?
    private var nextItemObservation: NSKeyValueObservation?
    private var nextFailedObserver: NSObjectProtocol?
    private var nextURL: URL?
    /// Polls the pointer for mid-run switches (2s, main thread, one stat when
    /// healthy). Resolve itself runs on pointerResolveQueue (serial
    /// background) so getpwuid + directory scans never race each other or
    /// hitch main at presentation. Started on full-mode start, stopped on stop/deinit.
    private var pointerPollTimer: Timer?
    private let pointerResolveQueue = DispatchQueue(label: "com.live.hazel.saver.pointer-resolve", qos: .background)

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
        animationTimeInterval = 0
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
        animationTimeInterval = 0
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
        item.preferredForwardBufferDuration = 1.0
        let queuePlayer = AVQueuePlayer(playerItem: item)
        queuePlayer.isMuted = true
        queuePlayer.volume = 0
        queuePlayer.automaticallyWaitsToMinimizeStalling = false
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
            // Re-apply occlusion policy at ready time: startAnimation may have
            // run while occluded/hidden, so pause instead of playing overdraw.
            applyOcclusionPolicy()
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
        stopNext()
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
        // Policy-gated: play only when visible/unoccluded; otherwise hold paused.
        applyOcclusionPolicy()
        startPointerPolling()
        Self.log("play start \(url.path)")
        if willStopObserver == nil {
            willStopObserver = DistributedNotificationCenter.default().addObserver(
                forName: NSNotification.Name("com.apple.screensaver.willstop"),
                object: nil, queue: .main
            ) { [weak self] _ in
                self?.stopPointerPolling()
                self?.stopPlayer()
                self?.started = false
            }
        }
    }

    override func stopAnimation() {
        super.stopAnimation()
        stopPointerPolling()
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
        // No window yet (pre-attach): hold paused instead of playing over an
        // occluded surface. viewDidMoveToWindow re-applies once attached.
        let visible = window?.occlusionState.contains(.visible) ?? false
        if visible {
            player?.isMuted = true
            player?.play()
        } else {
            player?.pause() // covered: stop decoding, keep layer for instant resume
        }
    }

    /// Picks up a wallpaper switch that landed while running. Hidden/covered
    /// rebuilds paused (nothing on screen to flash); visible ones hand off
    /// through a hidden prewarm that promotes only when ready.
    /// Vsync-safe: the pointer resolve (JSON decode + directory listing +
    /// mtime sort) runs on a background queue, never on main at presentation
    /// time. The timer fire itself stays a cheap main-thread guard + dispatch;
    /// only a genuine URL change hops back to touch player state.
    private func maybeReloadForPointerChange() {
        guard started, !actualIsPreview, !playbackFailed, player != nil else { return }
        let knownCurrent = currentURL?.path
        let knownNext = nextURL?.path
        pointerResolveQueue.async { [weak self] in
            guard let (freshURL, freshPointer) = self?.resolveVideoURL(),
                  self?.fileValidationError(for: freshURL) == nil else { return }
            guard freshURL.path != knownCurrent, freshURL.path != knownNext else { return }
            DispatchQueue.main.async { [weak self] in
                self?.applyPointerChange(url: freshURL, pointer: freshPointer)
            }
        }
    }

    /// Main-thread half of the pointer poll: re-checks liveness (the poll may
    /// have been stopped while the resolve was off-main) and promotes.
    private func applyPointerChange(url freshURL: URL, pointer freshPointer: SaverPointer?) {
        guard started, !actualIsPreview, !playbackFailed, player != nil else { return }
        guard freshURL.path != currentURL?.path, freshURL.path != nextURL?.path else { return }
        if isHiddenOrHasHiddenAncestor || !(window?.occlusionState.contains(.visible) ?? false) {
            stopNext()
            stopPlayer()
            _ = buildPlayer(url: freshURL, pointer: freshPointer)
            player?.pause()
            applyOcclusionPolicy()
            return
        }
        startHandoff(url: freshURL, pointer: freshPointer)
    }

    private func startHandoff(url: URL, pointer: SaverPointer?) {
        stopNext()
        let item = AVPlayerItem(asset: AVURLAsset(url: url))
        item.preferredForwardBufferDuration = 1.0
        let queuePlayer = AVQueuePlayer(playerItem: item)
        queuePlayer.isMuted = true
        queuePlayer.volume = 0
        queuePlayer.automaticallyWaitsToMinimizeStalling = false
        queuePlayer.pause() // prewarm only: promotes on ready, never plays hidden
        let layer = AVPlayerLayer(player: queuePlayer)
        layer.videoGravity = gravity(for: pointer?.fit ?? "Fill")
        layer.frame = bounds
        layer.opacity = 0 // hidden until ready; the live layer stays up meanwhile
        nextPlayer = queuePlayer
        nextItem = item
        nextURL = url
        if pointer?.isLooping != false {
            nextLooper = AVPlayerLooper(player: queuePlayer, templateItem: item)
        }
        nextItemObservation = item.observe(\.status, options: [.new]) { [weak self] observed, _ in
            DispatchQueue.main.async { [weak self] in self?.handleHandoffStatus(observed) }
        }
        nextFailedObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
        ) { [weak self] note in
            let reason = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError)?.localizedDescription ?? "play-to-end-failed"
            self?.discardNext(reason: reason)
        }
        self.layer?.addSublayer(layer)
        nextLayer = layer
        Self.log("handoff prewarm \(url.path)")
    }

    private func handleHandoffStatus(_ item: AVPlayerItem) {
        guard item === nextItem else { return }
        switch item.status {
        case .readyToPlay:
            promoteNext()
        case .failed:
            discardNext(reason: item.error?.localizedDescription ?? "handoff-item-failed")
        case .unknown:
            break
        @unknown default:
            break
        }
    }

    /// Ready-gated promotion: the old player is torn down only now, so the
    /// last good frame stays up until the first fresh frame is ready (no
    /// black flash, no unready swap). Playback then follows the occlusion
    /// policy (covered → stays paused).
    private func promoteNext() {
        guard let freshPlayer = nextPlayer, let layer = nextLayer, let freshURL = nextURL,
              let freshItem = nextItem else { return }
        detachItemObservers()
        player?.pause()
        looper?.disableLooping()
        playerLayer?.removeFromSuperlayer()
        player = freshPlayer
        looper = nextLooper
        playerLayer = layer
        currentURL = freshURL
        clearNextObservers()
        nextPlayer = nil
        nextLooper = nil
        nextLayer = nil
        nextItem = nil
        nextURL = nil
        isReady = true
        playbackFailed = false
        player?.isMuted = true
        attachItemObservers(to: freshItem)
        revealLayer()
        applyOcclusionPolicy()
        Self.log("handoff promote \(freshURL.path)")
    }

    private func discardNext(reason: String) {
        guard nextPlayer != nil || nextLayer != nil else { return }
        Self.log("handoff discard (\(reason)) keeping \(currentURL?.path ?? "?")")
        stopNext()
    }

    private func clearNextObservers() {
        nextItemObservation?.invalidate()
        nextItemObservation = nil
        if let token = nextFailedObserver {
            NotificationCenter.default.removeObserver(token)
            nextFailedObserver = nil
        }
    }

    private func stopNext() {
        clearNextObservers()
        nextPlayer?.pause()
        nextLooper?.disableLooping()
        nextLayer?.removeFromSuperlayer()
        nextPlayer = nil
        nextLooper = nil
        nextLayer = nil
        nextItem = nil
        nextURL = nil
    }

    private func startPointerPolling() {
        guard pointerPollTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.maybeReloadForPointerChange()
        }
        // Wide leeway lets the system coalesce this wake with other timers
        // instead of waking main on its own 2s cadence at presentation time.
        timer.tolerance = 1.0
        RunLoop.main.add(timer, forMode: .common)
        pointerPollTimer = timer
    }

    private func stopPointerPolling() {
        pointerPollTimer?.invalidate()
        pointerPollTimer = nil
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
            ) { [weak self] _ in
                self?.maybeReloadForPointerChange()
                self?.applyOcclusionPolicy()
            }
            // Attached late (window was nil at start): re-apply now that a
            // visibility verdict exists, and pick up any switch that landed
            // while unattached.
            maybeReloadForPointerChange()
            applyOcclusionPolicy()
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
        maybeReloadForPointerChange()
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
        // Skip the black fill once video content exists: overdraw that costs a
        // full-screen fill every frame and can flash over the player layer.
        guard playerLayer == nil else { return }
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
        stopPointerPolling()
        stopNext()
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
