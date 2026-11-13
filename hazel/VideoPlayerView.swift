import AppKit
import AVFoundation

/// Double-buffered video view: the current video keeps playing until the next
/// one has its first frame composited, then the layers swap with no black gap.
/// Rapid switches are generation-guarded so only the newest request wins.
class VideoPlayerView: NSView {
    private var player: AVQueuePlayer?
    private var playerLooper: AVPlayerLooper?
    private var playerLayer: AVPlayerLayer?
    private var currentURL: URL?
    private var currentIsLooping: Bool = true
    private var currentIsMuted: Bool = true

    /// Monotonically increasing switch id. Async prep callbacks whose id does
    /// not match are stale (superseded by a newer switch) and discarded.
    private var generation = 0
    private var statusObservation: NSKeyValueObservation?
    private var readyObservation: NSKeyValueObservation?

    var isPlaying: Bool {
        player?.rate ?? 0 > 0
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func loadVideo(url: URL, isLooping: Bool = true, isMuted: Bool = true) {
        // Fast path: same video, only flags changed. No layer swap, no flash.
        if url == currentURL, player != nil {
            currentIsLooping = isLooping
            currentIsMuted = isMuted
            player?.isMuted = isMuted
            if isLooping, playerLooper == nil, let player, let template = player.items().first {
                playerLooper = AVPlayerLooper(player: player, templateItem: template)
            } else if !isLooping {
                playerLooper?.disableLooping()
                playerLooper = nil
            }
            return
        }

        generation &+= 1
        let id = generation
        statusObservation?.invalidate()
        readyObservation?.invalidate()
        statusObservation = nil
        readyObservation = nil

        var securityScoped = false
        if url.startAccessingSecurityScopedResource() {
            securityScoped = true
        }

        let asset = AVURLAsset(url: url)
        let playerItem = AVPlayerItem(asset: asset)
        playerItem.preferredForwardBufferDuration = 2.0

        let queuePlayer = AVQueuePlayer(playerItem: playerItem)
        queuePlayer.isMuted = isMuted

        let layer = AVPlayerLayer(player: queuePlayer)
        layer.videoGravity = SettingsManager.shared.wallpaperFit.videoGravity
        layer.frame = bounds
        layer.opacity = 0

        if isLooping {
            playerLooper = nil
            pendingLooper = AVPlayerLooper(player: queuePlayer, templateItem: playerItem)
        } else {
            pendingLooper = nil
        }
        pendingPlayer = queuePlayer
        pendingLayer = layer
        pendingURL = url
        pendingIsLooping = isLooping
        pendingIsMuted = isMuted

        if securityScoped {
            url.stopAccessingSecurityScopedResource()
        }

        // Swap the moment the item can play; require the first composited
        // frame before showing so the cut lands on picture, never black.
        statusObservation = playerItem.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard let self, self.generation == id else { return }
            if item.status == .readyToPlay {
                self.watchFirstFrame(for: id, layer: layer, player: queuePlayer)
            } else if item.status == .failed {
                self.abandonPending(id: id)
            }
        }
        // Safety net: never leave the old video up forever if the new asset
        // stalls (broken file, slow disk). Matches old behavior as fallback.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, self.generation == id else { return }
            self.swapIfPending(id: id, layer: layer, newPlayer: queuePlayer, fade: false)
        }

        queuePlayer.play()
    }

    // MARK: - Pending handoff state (one in flight at most)

    private var pendingPlayer: AVQueuePlayer?
    private var pendingLooper: AVPlayerLooper?
    private var pendingLayer: AVPlayerLayer?
    private var pendingURL: URL?
    private var pendingIsLooping = true
    private var pendingIsMuted = true

    private func watchFirstFrame(for id: Int, layer: AVPlayerLayer, player: AVQueuePlayer) {
        guard generation == id else { return }
        readyObservation?.invalidate()
        if layer.isReadyForDisplay {
            swapIfPending(id: id, layer: layer, newPlayer: player, fade: true)
            return
        }
        readyObservation = layer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] _, change in
            guard let self, self.generation == id, change.newValue == true else { return }
            self.swapIfPending(id: id, layer: layer, newPlayer: player, fade: true)
        }
    }

    private func swapIfPending(id: Int, layer: AVPlayerLayer, newPlayer: AVQueuePlayer, fade: Bool) {
        guard generation == id, pendingPlayer === newPlayer else { return }
        statusObservation?.invalidate()
        readyObservation?.invalidate()
        statusObservation = nil
        readyObservation = nil

        self.layer?.addSublayer(layer)

        if fade, let oldLayer = playerLayer {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.2)
            layer.opacity = 1.0
            CATransaction.setCompletionBlock { [weak oldLayer] in
                oldLayer?.removeFromSuperlayer()
            }
            CATransaction.commit()
        } else {
            layer.opacity = 1.0
        }

        // Tear down the previous pipeline only after the new layer is up.
        let oldPlayer = player
        let oldLooper = playerLooper
        let oldLayer = playerLayer
        playerLooper = pendingLooper
        player = pendingPlayer
        playerLayer = layer
        currentURL = pendingURL
        currentIsLooping = pendingIsLooping
        currentIsMuted = pendingIsMuted

        oldLooper?.disableLooping()
        oldPlayer?.pause()
        if !fade {
            oldLayer?.removeFromSuperlayer()
        }

        pendingPlayer = nil
        pendingLooper = nil
        pendingLayer = nil
        pendingURL = nil
    }

    private func abandonPending(id: Int) {
        guard generation == id else { return }
        statusObservation?.invalidate()
        readyObservation?.invalidate()
        statusObservation = nil
        readyObservation = nil
        pendingPlayer?.pause()
        pendingPlayer = nil
        pendingLooper = nil
        pendingLayer = nil
        pendingURL = nil
    }

    func setMuted(_ muted: Bool) {
        player?.isMuted = muted
        pendingPlayer?.isMuted = muted
        currentIsMuted = muted
    }

    func reloadWithSettings() {
        guard let url = currentURL else { return }
        loadVideo(url: url, isLooping: currentIsLooping, isMuted: currentIsMuted)
    }

    func play() {
        player?.play()
        pendingPlayer?.play()
    }

    func pause() {
        player?.pause()
        pendingPlayer?.pause()
    }

    func cleanup() {
        generation &+= 1
        statusObservation?.invalidate()
        readyObservation?.invalidate()
        statusObservation = nil
        readyObservation = nil
        pendingPlayer?.pause()
        pendingPlayer = nil
        pendingLooper = nil
        if let pendingLayer {
            pendingLayer.removeFromSuperlayer()
        }
        pendingLayer = nil
        pendingURL = nil
        player?.pause()
        playerLayer?.removeFromSuperlayer()
        playerLooper?.disableLooping()
        playerLooper = nil
        player = nil
        playerLayer = nil
        currentURL = nil
    }

    override func layout() {
        super.layout()
        playerLayer?.frame = bounds
        pendingLayer?.frame = bounds
    }

    deinit {
        cleanup()
    }
}
