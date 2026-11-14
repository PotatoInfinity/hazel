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

    /// Test seams (additive, no behavior change).
    internal var generationForTesting: Int { generation }
    internal var pendingURLForTesting: URL? { pendingURL }
    internal var currentURLForTesting: URL? { currentURL }

    var isPlaying: Bool {
        player?.rate ?? 0 > 0
    }

    /// Fired once when this view composites its first frame after having no
    /// video (cold start). The Bool reports whether the swapped video had
    /// been prewarmed (instance or static prewarm): the controller reveals
    /// the transparent window instantly when warm and keeps a short fade
    /// otherwise. Set before loadVideo.
    var onFirstFrameReady: ((Bool) -> Void)?
    /// One-shot hook fired when a pending pipeline promotes to live (or at
    /// once when the requested video is already live). The controller uses
    /// it to start the post-swap quiet before heavy follow-up work, so
    /// staging/extraction can never contend the swap decode. Set before
    /// loadVideo; cleared on fire.
    var onSwapCommitted: (() -> Void)?
    /// True once a video has been composited at least once in this view.
    private(set) var hasDisplayedFirstFrame = false
    /// Currently displayed video, if any. Main thread only.
    internal var currentURLValue: URL? { currentURL }
    /// True while playback is intentionally suspended (lock/saver/sleep
    /// pause or teardown). Stall/failure auto-recovery must never unpause
    /// behind the lockscreen: it only re-plays when this is false.
    private var suspended = false

    /// Notification tokens for the live item's stall/failure/end recovery.
    /// Installed on promotion, removed on the next swap or teardown.
    private var stallObserver: NSObjectProtocol?
    private var failObserver: NSObjectProtocol?
    private var endObserver: NSObjectProtocol?

    /// Warms the AVFoundation decode path for a URL without creating a
    /// player. Call before loadVideo on launch so the first frame arrives
    /// sooner. Fire-and-forget, never blocks. Also marks the URL warm so a
    /// later loadVideo can reveal instantly (zero fade).
    static func prewarm(url: URL) {
        markWarmed(url)
        let asset = AVURLAsset(url: url)
        asset.loadValuesAsynchronously(forKeys: ["playable", "tracks"]) { }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // Clear (not black): the window above starts transparent and only
        // reveals on the first composited frame. A black backing layer would
        // be the startup blackout if a reveal ever raced ahead of picture.
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func loadVideo(url: URL, isLooping: Bool = true, isMuted: Bool = true) {
        assert(Thread.isMainThread)
        // Snapshot warmth BEFORE clearing the prediction below: a URL the
        // prewarmer already touched (instance 320p prewarm or the launch
        // static prewarm) swaps onto hot caches and can reveal instantly.
        let wasPrewarmed = (prewarmURL == url) || Self.isWarmed(url)
        // A fresh switch invalidates the next-video prediction; the caller
        // re-prewarms afterwards when the new current is known.
        prewarmURL = nil
        let targetGravity = SettingsManager.shared.wallpaperFit.videoGravity
        // Fast path: same video already live. Kill any superseded pending
        // decode first (otherwise its callback could still swap in), then
        // update flags/gravity in place. No asset, no player, no layer.
        // Already displaying: fire the swap hook at once so a follow-up
        // gated on the swap does not sit out the timeout.
        if url == currentURL, player != nil {
            generation &+= 1
            let id = generation
            statusObservation?.invalidate()
            readyObservation?.invalidate()
            statusObservation = nil
            readyObservation = nil
            pendingPlayer?.pause()
            pendingLooper?.disableLooping()
            pendingPlayer = nil
            pendingLooper = nil
            pendingLayer?.removeFromSuperlayer()
            pendingLayer = nil
            pendingURL = nil
            _ = id
            currentIsLooping = isLooping
            currentIsMuted = isMuted
            player?.isMuted = isMuted
            playerLayer?.videoGravity = targetGravity
            if isLooping, playerLooper == nil, let player, let template = player.items().first {
                playerLooper = AVPlayerLooper(player: player, templateItem: template)
            } else if !isLooping {
                playerLooper?.disableLooping()
                playerLooper = nil
            }
            fireSwapCommitted()
            return
        }
        // Coalesce: same URL already pending (staged, or still building off
        // main). Only flags/gravity changed; retarget the in-flight pipeline
        // instead of starting a second decode. The pending swap still fires
        // the hook on commit; a mid-build flag change is picked up there.
        if url == pendingURL {
            pendingIsLooping = isLooping
            pendingIsMuted = isMuted
            if let pendingPlayer, let pendingLayer {
                pendingPlayer.isMuted = isMuted
                pendingLayer.videoGravity = targetGravity
                if isLooping, pendingLooper == nil, let template = pendingPlayer.items().first {
                    pendingLooper = AVPlayerLooper(player: pendingPlayer, templateItem: template)
                } else if !isLooping {
                    pendingLooper?.disableLooping()
                    pendingLooper = nil
                }
            }
            return
        }

        generation &+= 1
        let id = generation
        statusObservation?.invalidate()
        readyObservation?.invalidate()
        statusObservation = nil
        readyObservation = nil

        // Dispose superseded pending before overwrite (leak otherwise:
        // paused decoder + orphan layer would survive until swap/cleanup).
        // A build still in flight off-main (pendingPlayer nil) is disposed
        // by the generation bump: its main-thread commit aborts.
        pendingPlayer?.pause()
        pendingLooper?.disableLooping()
        pendingLooper = nil
        pendingPlayer = nil
        pendingLayer?.removeFromSuperlayer()
        pendingLayer = nil
        // Reserve synchronously so coalescing observes the intent
        // immediately; the heavy AVFoundation build happens off main.
        pendingURL = url
        pendingIsLooping = isLooping
        pendingIsMuted = isMuted
        pendingWasPrewarmed = wasPrewarmed
        let capturedMuted = isMuted
        let capturedLooping = isLooping

        // Pending pipeline construction off the main thread: asset + item +
        // player + looper init never blocks the swap kick, and the live
        // pipeline keeps playing untouched until the commit below swaps
        // layers on main. AVPlayerLooper is template-bound (one looping
        // item), so cross-video player reuse is impossible; building the
        // pending side alongside live (double-buffered) is the safe shape.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var securityScoped = false
            if url.startAccessingSecurityScopedResource() {
                securityScoped = true
            }
            defer {
                if securityScoped {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            let asset = AVURLAsset(url: url)
            let playerItem = AVPlayerItem(asset: asset)
            // Steady-state vsync: 1s forward buffer spreads decode into small
            // even bursts instead of 2s chunks that spike CPU and miss vsync.
            playerItem.preferredForwardBufferDuration = 1.0

            let queuePlayer = AVQueuePlayer(playerItem: playerItem)
            queuePlayer.isMuted = capturedMuted
            // Never stall to refill: a refill stall lands the next frame a
            // full vsync late (ImageQueue drop while decoder stays clean).
            queuePlayer.automaticallyWaitsToMinimizeStalling = false
            queuePlayer.pause() // pending stages paused: no dual-decode jank; swap plays live
            let looper: AVPlayerLooper? = capturedLooping
                ? AVPlayerLooper(player: queuePlayer, templateItem: playerItem)
                : nil
            DispatchQueue.main.async { [weak self] in
                self?.commitPendingBuild(id: id, url: url, item: playerItem,
                                         player: queuePlayer, looper: looper)
            }
        }
    }

    /// Main-thread commit for an off-main pending build. Superseded builds
    /// (generation/URL mismatch) are dropped; the commit retargets to the
    /// latest flags (a coalesced loadVideo may have changed them mid-build),
    /// then attaches the layer + readiness watches exactly as the old
    /// synchronous path did.
    private func commitPendingBuild(id: Int, url: URL, item: AVPlayerItem,
                                    player queuePlayer: AVQueuePlayer,
                                    looper: AVPlayerLooper?) {
        assert(Thread.isMainThread)
        // Superseded while the build was off-main: the caller already staged
        // a newer pending (or cleaned up). Park the built pipeline paused so
        // it can never play, then drop it — exactly one live video max.
        guard generation == id, pendingURL == url else {
            queuePlayer.pause()
            looper?.disableLooping()
            return
        }
        queuePlayer.isMuted = pendingIsMuted
        let layer = AVPlayerLayer(player: queuePlayer)
        layer.videoGravity = SettingsManager.shared.wallpaperFit.videoGravity
        layer.frame = bounds
        layer.opacity = 0

        pendingPlayer = queuePlayer
        pendingLayer = layer
        if pendingIsLooping {
            pendingLooper = looper ?? AVPlayerLooper(player: queuePlayer, templateItem: item)
        } else {
            looper?.disableLooping()
            pendingLooper = nil
        }

        // Swap the moment the item can play; require the first composited
        // frame before showing so the cut lands on picture, never black.
        // KVO may fire off-main (AVFoundation internals): hop to main where
        // generation, layers and players live, then re-check the generation
        // so a stale callback can never promote a superseded pipeline.
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let status = item.status
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == id else { return }
                if status == .readyToPlay {
                    self.watchFirstFrame(for: id, layer: layer, player: queuePlayer)
                } else if status == .failed {
                    self.abandonPending(id: id)
                }
            }
        }
        // The item may already be ready before the observer attaches (KVO
        // with [.new] only fires on change); check now so a pre-ready item
        // does not wait out the safety net below.
        if item.status == .readyToPlay {
            watchFirstFrame(for: id, layer: layer, player: queuePlayer)
        } else if item.status == .failed {
            abandonPending(id: id)
        }
        // Safety net: never leave the old video up forever if the new asset
        // stalls (broken file, slow disk). Only swap a ready frame; never
        // swap unready (black) — abandon instead and keep old video.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, self.generation == id else { return }
            if layer.isReadyForDisplay {
                self.swapIfPending(id: id, layer: layer, newPlayer: queuePlayer, fade: false)
            } else {
                self.abandonPending(id: id)
            }
        }
    }

    // MARK: - Pending handoff state (one in flight at most)

    private var pendingPlayer: AVQueuePlayer?
    private var pendingLooper: AVPlayerLooper?
    private var pendingLayer: AVPlayerLayer?
    private var pendingURL: URL?
    private var pendingIsLooping = true
    private var pendingIsMuted = true
    /// Whether the pending URL had been prewarmed when loadVideo reserved
    /// it. Reported through onFirstFrameReady so the window can reveal
    /// instantly (zero fade) on hot caches.
    private var pendingWasPrewarmed = false
    /// Next-cycle URL whose file/decode path is already warm. Warms the page
    /// cache + first-frame decode only; never displayed, never played.
    private var prewarmURL: URL?
    /// Cross-view single-flight: one decode per URL at a time. The controller
    /// fans prewarm out per window, but the page cache is process-wide, so the
    /// second view's decode is pure waste. Guarded by prewarmLock.
    private static let prewarmLock = NSLock()
    private static var prewarmInflight: URL?
    /// Cross-view + launch warmed set: every URL an instance or static
    /// prewarm has touched. Bounded in practice by the video library size;
    /// entries are tiny path strings, never purged within a launch.
    /// Guarded by prewarmLock.
    private static var warmedURLs = Set<String>()
    private static func isWarmed(_ url: URL) -> Bool {
        prewarmLock.lock()
        defer { prewarmLock.unlock() }
        return warmedURLs.contains(url.path)
    }
    private static func markWarmed(_ url: URL) {
        prewarmLock.lock()
        warmedURLs.insert(url.path)
        prewarmLock.unlock()
    }
    /// One-shot swap-hook fire. A teardown (cleanup) abandons instead of
    /// firing: the promotion will never come, and an early fire would
    /// release a newer switch's waiter before its own swap.
    private func fireSwapCommitted() {
        let callback = onSwapCommitted
        onSwapCommitted = nil
        callback?()
    }

    /// Warms the file/decoding path for the likely-next video without touching
    /// the live or pending pipeline (no generation bump, no layers, no
    /// playback). Fire-and-forget on a utility queue; harmless when superseded
    /// (a stale warm only ever populated the kernel page cache).
    /// Single-flight across views: the controller fans out per window, but one
    /// 320p first-frame decode warms the shared page cache for all of them.
    func prewarm(url: URL) {
        guard url != currentURL, url != pendingURL, url != prewarmURL else { return }
        Self.markWarmed(url)
        Self.prewarmLock.lock()
        if Self.prewarmInflight == url {
            Self.prewarmLock.unlock()
            return
        }
        Self.prewarmInflight = url
        Self.prewarmLock.unlock()
        prewarmURL = url
        // Worker is self-free by design: main-state (prewarmURL/currentURL/
        // pendingURL) is main-thread-only and must never be read off-main.
        // The pre-dispatch guards above already skipped live/pending/warm URLs;
        // a race that slips through only ever warms the shared page cache
        // (harmless by contract), never displays or plays.
        DispatchQueue.global(qos: .background).async {
            defer {
                Self.prewarmLock.lock()
                if Self.prewarmInflight == url {
                    Self.prewarmInflight = nil
                }
                Self.prewarmLock.unlock()
            }
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 320, height: 180)
            _ = try? generator.copyCGImage(at: .zero, actualTime: nil)
        }
    }

    private func watchFirstFrame(for id: Int, layer: AVPlayerLayer, player: AVQueuePlayer) {
        assert(Thread.isMainThread)
        guard generation == id else { return }
        readyObservation?.invalidate()
        if layer.isReadyForDisplay {
            swapIfPending(id: id, layer: layer, newPlayer: player, fade: true)
            return
        }
        // Same off-main hazard as the status observer above: hop to main and
        // re-check generation before promoting.
        readyObservation = layer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] _, change in
            let ready = change.newValue == true
            DispatchQueue.main.async { [weak self] in
                guard let self, ready, self.generation == id else { return }
                self.swapIfPending(id: id, layer: layer, newPlayer: player, fade: true)
            }
        }
    }

    private func swapIfPending(id: Int, layer: AVPlayerLayer, newPlayer: AVQueuePlayer, fade: Bool) {
        assert(Thread.isMainThread)
        guard generation == id, pendingPlayer === newPlayer else { return }
        _ = fade // instant cut always: crossfade overdraw dropped frames
        statusObservation?.invalidate()
        readyObservation?.invalidate()
        statusObservation = nil
        readyObservation = nil

        // Instant cut (no fade): a 0.2s crossfade keeps two opaque video
        // layers compositing (overdraw) and drops frames. Non-fade path must
        // also suppress the implicit opacity animation.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.layer?.addSublayer(layer)
        layer.opacity = 1.0
        CATransaction.commit()

        // Tear down the previous pipeline only after the new layer is up.
        let oldPlayer = player
        let oldLooper = playerLooper
        let oldLayer = playerLayer
        let wasColdStart = !hasDisplayedFirstFrame
        playerLooper = pendingLooper
        player = pendingPlayer
        playerLayer = layer
        currentURL = pendingURL
        currentIsLooping = pendingIsLooping
        currentIsMuted = pendingIsMuted
        hasDisplayedFirstFrame = true

        oldLooper?.disableLooping()
        oldPlayer?.pause()
        oldLayer?.removeFromSuperlayer()
        // Pending staged paused; live side resumes here.
        removeLiveItemObservers()
        suspended = false
        newPlayer.play()
        observeLiveItem()

        pendingPlayer = nil
        pendingLooper = nil
        pendingLayer = nil
        pendingURL = nil
        let swappedPrewarmed = pendingWasPrewarmed
        pendingWasPrewarmed = false

        // The pending pipeline is now live: release any follow-up gated on
        // the swap before the heavier launch work below.
        fireSwapCommitted()

        // Cold start: the window above this view is still transparent.
        // Signal now that picture (not black) is on screen. A prewarmed
        // video reveals instantly (zero fade); a cold decode keeps the
        // short fade so the cut does not pop.
        if wasColdStart {
            let callback = onFirstFrameReady
            DispatchQueue.main.async { callback?(swappedPrewarmed) }
        }
    }

    private func abandonPending(id: Int) {
        assert(Thread.isMainThread)
        guard generation == id else { return }
        statusObservation?.invalidate()
        readyObservation?.invalidate()
        statusObservation = nil
        readyObservation = nil
        pendingPlayer?.pause()
        pendingLooper?.disableLooping()
        pendingPlayer = nil
        pendingLooper = nil
        pendingLayer?.removeFromSuperlayer()
        pendingLayer = nil
        pendingURL = nil
        pendingWasPrewarmed = false
    }

    func setMuted(_ muted: Bool) {
        player?.isMuted = muted
        pendingPlayer?.isMuted = muted
        currentIsMuted = muted
    }

    func reloadWithSettings() {
        guard currentURL != nil else { return }
        // Fit/mute/loop changes need no redecode: retarget layers in place.
        // A full loadVideo here would rebuild the AV asset + player for the
        // same file (double-decode + black-gap risk) for zero benefit.
        let targetGravity = SettingsManager.shared.wallpaperFit.videoGravity
        player?.isMuted = currentIsMuted
        playerLayer?.videoGravity = targetGravity
        pendingPlayer?.isMuted = pendingIsMuted
        pendingLayer?.videoGravity = targetGravity
    }

    func play() {
        suspended = false
        player?.play()
    }

    func pause() {
        suspended = true
        player?.pause()
        pendingPlayer?.pause()
    }

    /// Idempotent re-assert: restarts the live video when it is not running.
    /// The controller gates this on active + visible and re-fires it on
    /// delayed retries after every unlock, so a play() that landed before
    /// the WindowServer/display was ready (the rare lock-screen freeze)
    /// heals without user interaction. Safe to call when already playing.
    func ensurePlaying() {
        assert(Thread.isMainThread)
        guard currentURL != nil, let player else { return }
        guard player.rate == 0 else {
            suspended = false
            return
        }
        suspended = false
        player.play()
    }

    /// Stall/failure/end recovery for the live item. Installed on promotion,
    /// removed on the next swap or teardown. The suspended guard keeps an
    /// intentional lock/saver/sleep pause paused: recovery only replays a
    /// video that should be running.
    private func observeLiveItem() {
        removeLiveItemObservers()
        let center = NotificationCenter.default
        stallObserver = center.addObserver(
            forName: .AVPlayerItemPlaybackStalled,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, !self.suspended, self.currentIsLooping else { return }
            self.player?.play()
        }
        failObserver = center.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, !self.suspended, self.currentIsLooping else { return }
            self.player?.play()
        }
        endObserver = center.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self, !self.suspended, self.currentIsLooping else { return }
            // Looping runs through AVPlayerLooper, so a natural end should
            // not arrive; if it does (looper hiccup across lock/sleep),
            // restart from the beginning instead of freezing on last frame.
            guard let item = note.object as? AVPlayerItem,
                  item == self.player?.currentItem else { return }
            self.player?.seek(to: .zero)
            self.player?.play()
        }
    }

    private func removeLiveItemObservers() {
        let center = NotificationCenter.default
        if let stallObserver {
            center.removeObserver(stallObserver)
            self.stallObserver = nil
        }
        if let failObserver {
            center.removeObserver(failObserver)
            self.failObserver = nil
        }
        if let endObserver {
            center.removeObserver(endObserver)
            self.endObserver = nil
        }
    }

    func cleanup() {
        generation &+= 1
        suspended = true
        removeLiveItemObservers()
        prewarmURL = nil
        pendingWasPrewarmed = false
        // Abandon, never fire: the promotion this hook waited on will never
        // come from this view, and an early fire would release a newer
        // switch's waiter before its own swap.
        onSwapCommitted = nil
        hasDisplayedFirstFrame = false
        statusObservation?.invalidate()
        readyObservation?.invalidate()
        statusObservation = nil
        readyObservation = nil
        pendingPlayer?.pause()
        pendingPlayer = nil
        pendingLooper?.disableLooping()
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
        // Match backing scale so the compositor never rescales every vsync.
        let scale = window?.backingScaleFactor ?? 2.0
        playerLayer?.contentsScale = scale
        pendingLayer?.contentsScale = scale
    }

    deinit {
        cleanup()
    }
}
