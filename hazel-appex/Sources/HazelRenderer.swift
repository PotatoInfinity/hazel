// HazelRenderer.swift
//
// Ported from Phosphene's VideoRenderer.swift
// (MIT License, Copyright (c) 2026 kageroumado).
//
// AVAssetReader + AVSampleBufferDisplayLayer loop. NOTE: AVPlayerLayer does
// NOT composite in a remote CAContext hosted cross-process by WallpaperAgent,
// so the reader-to-display-layer path is load-bearing, not incidental.

import AVFoundation
import CoreMedia
import ObjectiveC

/// Call AVSampleBufferDisplayLayer's private
/// `_setDisallowsVideoLayerDisplayCompositing:` (a BOOL setter Apple's
/// WallpaperExtensionKit sets on every AVSBDL). Resolved via the ObjC runtime
/// so the private selector never appears in a header; a no-op if the API ever
/// disappears. Prevents the layer painting opaque black before its first frame.
private func setDisallowsVideoLayerDisplayCompositing(_ layer: CALayer, _ flag: Bool) {
    let sel = NSSelectorFromString("_setDisallowsVideoLayerDisplayCompositing:")
    guard layer.responds(to: sel),
          let imp = class_getMethodImplementation(type(of: layer), sel) else { return }
    typealias SetBoolFn = @convention(c) (AnyObject, Selector, ObjCBool) -> Void
    unsafeBitCast(imp, to: SetBoolFn.self)(layer, sel, ObjCBool(flag))
}

final class HazelVideoRenderer: @unchecked Sendable {
    let displayLayer: AVSampleBufferDisplayLayer
    let timebase: CMTimebase
    private let renderer: AVSampleBufferVideoRenderer
    private let queue = DispatchQueue(label: "live.hazel.wallpaper.renderer", qos: .userInitiated)

    // Everything below is confined to `queue`.
    private var asset: AVURLAsset
    private var videoTrack: AVAssetTrack
    private var isRunning = true
    private var isPaused = false
    private var currentReader: AVAssetReader?
    private var currentOutput: AVAssetReaderTrackOutput?
    private var nextReader: AVAssetReader?
    private var nextOutput: AVAssetReaderTrackOutput?
    private var deepPauseTimer: (any DispatchSourceTimer)?

    /// Serialize the decoder reset: at most one flush is ever in flight, and a
    /// switch arriving mid-flush is coalesced. Two overlapping flushes corrupt
    /// the renderer. Touched ONLY on `queue`.
    private var flushInFlight = false
    private var restartPending = false

    // Gapless looping: ptsOffset accumulates across loops so DTS/PTS are
    // monotonically increasing; lastEnqueuedEnd tracks the highest sample end
    // time (max, not last — handles B-frames).
    private var ptsOffset: CMTime = .zero
    private var lastEnqueuedEnd: CMTime = .zero

    static func create(rootLayer: CALayer, videoURL: URL) async throws -> HazelVideoRenderer {
        // Zero-byte mid-copy stage: fail fast with a distinct log (caller
        // seeds a gradient and retries on the next library signal) instead of
        // letting loadTracks throw a generic error on an empty reply path.
        if let size = HazelLibrary.fileSize(at: videoURL), size == 0 {
            hazelLog("  [Renderer] create aborted: zero-byte file \(videoURL.lastPathComponent) (mid-copy) — caller holds gradient, retries later")
            throw CocoaError(.fileReadCorruptFile, userInfo: [
                NSLocalizedDescriptionKey: "Zero-byte (mid-copy) file \(videoURL.lastPathComponent)",
            ])
        }
        let asset = AVURLAsset(url: videoURL)
        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.loadTracks(withMediaType: .video)
        } catch {
            hazelLog("  [Renderer] create failed: track load threw for \(videoURL.lastPathComponent): \(error) (mid-copy/corrupt?)")
            throw error
        }
        guard let track = tracks.first else {
            hazelLog("  [Renderer] create failed: no video track in \(videoURL.lastPathComponent) (mid-copy/corrupt?)")
            throw CocoaError(.fileReadCorruptFile, userInfo: [
                NSLocalizedDescriptionKey: "No video track found in \(videoURL.lastPathComponent)",
            ])
        }
        // Seed the layer with the first frame as a still: on a cold start the
        // agent hosts our context the instant we reply, and a CALayer.contents
        // still reads black cross-process — only IOSurface-backed
        // AVSampleBufferDisplayLayer content composites remotely.
        // INFALLIBLE: seedImage falls back to cached last-good frame, then
        // solid color — never nil, so the layer always has content.
        hazelLog("  [Renderer] create \(videoURL.lastPathComponent): seeding still")
        let still: CGImage = await HazelSnapshot.seedImage(videoURL: videoURL)
        hazelLog("  [Renderer] still seeded \(still.width)x\(still.height)")
        return HazelVideoRenderer(rootLayer: rootLayer, asset: asset, videoTrack: track, stillImage: still)
    }

    private init(rootLayer: CALayer, asset: AVURLAsset, videoTrack: AVAssetTrack, stillImage: CGImage) {
        self.displayLayer = AVSampleBufferDisplayLayer()
        self.renderer = displayLayer.sampleBufferRenderer
        self.asset = asset
        self.videoTrack = videoTrack

        displayLayer.videoGravity = .resizeAspectFill
        displayLayer.frame = rootLayer.bounds
        displayLayer.contentsScale = rootLayer.contentsScale
        displayLayer.isOpaque = true
        setDisallowsVideoLayerDisplayCompositing(displayLayer, true)

        var tb: CMTimebase?
        CMTimebaseCreateWithSourceClock(
            allocator: kCFAllocatorDefault,
            sourceClock: CMClockGetHostTimeClock(),
            timebaseOut: &tb,
        )
        self.timebase = tb!
        CMTimebaseSetTime(timebase, time: .zero)
        // Rate stays 0 until start() — prevents the timebase advancing during
        // the async gap, which would make the first frames "late" and dropped.
        CMTimebaseSetRate(timebase, rate: 0.0)
        displayLayer.controlTimebase = timebase

        // Install the layer and seed the still in ONE action-free transaction,
        // so Core Animation plays no implicit "onOrderIn" animation (zoom/fade).
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rootLayer.addSublayer(displayLayer)
        if let stillBuffer = HazelVideoRenderer.makeStillSampleBuffer(from: stillImage) {
            HazelVideoRenderer.setDisplayImmediately(stillBuffer)
            renderer.enqueue(stillBuffer)
            hazelLog("  [Renderer] still composited (infallible seed)")
        } else {
            hazelLog("  [Renderer] ERROR: makeStillSampleBuffer failed even for infallible seed")
        }
        CATransaction.commit()
        // flush() (not just commit()) pushes the layer tree to the render
        // server for a REMOTE context — without it the still never reaches the
        // WindowServer and the surface stays black until a later flush.
        CATransaction.flush()
    }

    /// Start playback. Returns after the first frame is enqueued and flushed,
    /// i.e. once this surface is displaying video. The acquire path awaits this
    /// before replying on a switch, so WallpaperAgent keeps compositing the old
    /// wallpaper until then. Resolves on every path so a reply can never hang.
    func start() async {
        await withCheckedContinuation { (firstFrame: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                beginPlayback { firstFrame.resume() }
            }
        }
    }

    /// Runs on `queue`. Calls `firstFrameShown` exactly once.
    private func beginPlayback(firstFrameShown: () -> Void) {
        guard isRunning else { firstFrameShown(); return }
        hazelLog("[Renderer] beginPlayback \(asset.url.lastPathComponent) size=\(HazelLibrary.fileSize(at: asset.url).map(String.init) ?? "nil")")
        guard let reader = try? AVAssetReader(asset: asset) else {
            hazelLog("[Renderer] ERROR: AVAssetReader create failed for \(asset.url.lastPathComponent) — enqueuing fallback still (holds frame, not black), retrying")
            enqueueFallbackStill(reason: "reader-create-failed")
            firstFrameShown()
            schedulePlaybackRetry()
            return
        }
        let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        reader.startReading()

        CMTimebaseSetTime(timebase, time: .zero)

        if let firstSample = output.copyNextSampleBuffer() {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            renderer.enqueue(firstSample)
            CATransaction.commit()
            CATransaction.flush()
            hazelLog("[Renderer] first-frame VIDEO composited for \(asset.url.lastPathComponent) (not still-fallback)")
        } else {
            // Decoder not ready yet (cold file, slow disk): NEVER leave the
            // queue empty (rate 1 + no frames = black). The infallible still
            // from init is already composited; re-enqueue the fallback so the
            // surface holds a frame, then retry the read below.
            hazelLog("[Renderer] first sample nil for \(asset.url.lastPathComponent) — holding FALLBACK STILL (not black), will retry")
            enqueueFallbackStill(reason: "first-sample-nil")
        }

        currentReader = reader
        currentOutput = output
        ptsOffset = .zero
        lastEnqueuedEnd = .zero

        CMTimebaseSetRate(timebase, rate: 1.0)
        firstFrameShown()
        hazelLog("[Renderer] playback started rate=1")
        if isPaused {
            holdAfterFirstFrame()
            scheduleDeepPause()
        }
        prepareNextReader()
        feedFromCurrentReader()
    }

    /// Enqueue an infallible fallback still (cached last-good frame, else
    /// solid color) with DisplayImmediately so the surface always shows
    /// *something*. Synchronous on `queue`; caller holds the queue.
    private func enqueueFallbackStill(reason: String) {
        // Best-effort synchronous seed: the disk cache read is fast; if even
        // that fails we build a solid color on the spot.
        let img: CGImage? = HazelFrameCache.load() ?? HazelFrameCache.solidFallback()
        guard let img, let buf = Self.makeStillSampleBuffer(from: img) else {
            hazelLog("[Renderer] ERROR: fallback still construction failed (\(reason))")
            return
        }
        Self.setDisplayImmediately(buf)
        renderer.enqueue(buf)
        CATransaction.flush()
        hazelLog("[Renderer] fallback still enqueued (\(reason))")
    }

    /// Retry playback setup after a transient decode failure. Bounded: one
    /// retry after 0.5s; if the file is still unreadable the loop below keeps
    /// the fallback still on screen and swap/recreate paths will retry on the
    /// next library signal.
    private func schedulePlaybackRetry() {
        queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            guard isRunning, currentOutput == nil else { return }
            hazelLog("[Renderer] retrying playback setup")
            recreatePlayback(seamlessResume: false)
            if !isPaused { CMTimebaseSetRate(timebase, rate: 1.0) }
        }
    }

    /// Re-frame the video layer to a new destination geometry. Layer-tree work
    /// must happen on the main thread; the lifecycle queue calls here, so hop.
    func resize(to destSize: CGSize, scale: CGFloat) {
        guard !Thread.isMainThread else {
            resizeOnMain(to: destSize, scale: scale)
            return
        }
        DispatchQueue.main.sync {
            self.resizeOnMain(to: destSize, scale: scale)
        }
    }

    private func resizeOnMain(to destSize: CGSize, scale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = CGRect(origin: .zero, size: destSize)
        displayLayer.contentsScale = scale
        CATransaction.commit()
        CATransaction.flush()
    }

    /// Switch to a different video in place, reusing this `displayLayer`. A
    /// fresh AVSampleBufferDisplayLayer added to an already-hosted context does
    /// not composite, so the layer must be reused.
    func switchVideo(to url: URL) {
        hazelLog("[Renderer] switchVideo start → \(url.lastPathComponent)")
        queue.async { [self] in
            guard isRunning else {
                hazelLog("[Renderer] switchVideo ignored: not running")
                return
            }
            if asset.url == url {
                hazelLog("[Renderer] switchVideo ignored: same URL")
                return
            }
            open(url)
        }
    }

    /// Open `url` as the current asset and restart from its first frame.
    /// The track load is validated BEFORE touching the live pipeline, so a
    /// corrupt/mid-write file never tears down the currently showing video.
    private func open(_ url: URL) {
        hazelLog("[Renderer] open \(url.lastPathComponent)")
        let newAsset = AVURLAsset(url: url)
        guard let track = Self.loadFirstVideoTrackBlocking(newAsset) else {
            hazelLog("[Renderer] switchVideo aborted: no video track in \(url.lastPathComponent) — keeping current video")
            return
        }
        // Guard against a file that exists but has zero readable frames
        // (mid-copy stage): probe one frame before committing to the swap.
        guard Self.probeFirstSample(asset: newAsset, track: track) != nil else {
            hazelLog("[Renderer] switchVideo aborted: no decodable frame in \(url.lastPathComponent) (mid-write?) — keeping current video, will retry on next library signal")
            return
        }
        asset = newAsset
        videoTrack = track
        restartWithCurrentAsset()
    }

    /// Decode (then discard) one frame to prove the asset is readable. Runs
    /// on `queue`; opens a throwaway reader so the live pipeline is untouched.
    private static func probeFirstSample(asset: AVURLAsset, track: AVAssetTrack) -> Bool? {
        guard let reader = try? AVAssetReader(asset: asset) else { return nil }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { return nil }
        let sample = output.copyNextSampleBuffer()
        reader.cancelReading()
        return sample.map { _ in true }
    }

    /// Tag a sample buffer so the renderer displays it immediately, replacing
    /// all previously enqueued/displayed images regardless of timestamps.
    /// Used for the first frame of a switch so the swap is instant and doesn't
    /// wait on the control timebase.
    static func setDisplayImmediately(_ sample: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) else { return }
        let count = CFArrayGetCount(attachments)
        for i in 0 ..< count {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, i), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque(),
            )
        }
    }

    /// Load the first video track synchronously. Call ONLY on the renderer's
    /// serial `queue` (a real, owned thread that already blocks for decodes):
    /// the blocking window is one cached metadata read, and making this async
    /// would let a switch race the loop restart it is meant to precede.
    private static func loadFirstVideoTrackBlocking(_ asset: AVURLAsset) -> AVAssetTrack? {
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: AVAssetTrack?
        asset.loadTracks(withMediaType: .video) { tracks, _ in
            result = tracks?.first
            sem.signal()
        }
        sem.wait()
        return result
    }

    /// Stop playback for good. Synchronous with the renderer queue so no
    /// callback is mid-flight when the readers are cancelled. Must not be
    /// called on that queue. Layer-tree removal hops to the main thread.
    /// NOTE: the last composited frame stays in the torn-down layer; the
    /// context itself is going away (invalidate grace fired), so no black is
    /// observable — the host drops the context right after.
    func stop() {
        hazelLog("[Renderer] stop")
        queue.sync {
            isRunning = false
            cancelDeepPauseTimer()
            renderer.stopRequestingMediaData()
            currentReader?.cancelReading()
            nextReader?.cancelReading()
        }
        if Thread.isMainThread {
            displayLayer.removeFromSuperlayer()
        } else {
            DispatchQueue.main.sync {
                self.displayLayer.removeFromSuperlayer()
            }
        }
    }

    // MARK: - Pause (lock-screen-only playback)

    /// Pause or resume from any thread; applied in order on the renderer queue.
    func setPaused(_ paused: Bool) {
        queue.async { [self] in
            if paused {
                guard !isPaused else { return }
                isPaused = true
                CMTimebaseSetRate(timebase, rate: 0.0)
                hazelLog("[Policy] paused (rate=0, holding last frame)")
                scheduleDeepPause()
            } else {
                guard isPaused else { return }
                isPaused = false
                cancelDeepPauseTimer()
                hazelLog("[Policy] resumed (rate→1)")
                if currentReader == nil {
                    recreatePlayback(seamlessResume: true)
                }
                CMTimebaseSetRate(timebase, rate: 1.0)
            }
        }
    }

    /// Let the clock run briefly after a paused start, then stop it. A display
    /// layer whose clock stops at time 0 before it has shown a frame never
    /// shows one: the surface stays black until playback next runs.
    private func holdAfterFirstFrame() {
        queue.asyncAfter(deadline: .now() + 0.25) { [self] in
            guard isRunning, isPaused else { return }
            CMTimebaseSetRate(timebase, rate: 0.0)
        }
    }

    // MARK: - Deep pause

    /// After a sustained pause the asset readers still hold decoded buffers and
    /// the hardware decoder. Tear them down to idle fully; resume rebuilds.
    private static let deepPauseDelay: TimeInterval = 30

    private func scheduleDeepPause() {
        cancelDeepPauseTimer()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.deepPauseDelay)
        timer.setEventHandler { [weak self] in self?.enterDeepPause() }
        deepPauseTimer = timer
        timer.resume()
    }

    private func cancelDeepPauseTimer() {
        deepPauseTimer?.cancel()
        deepPauseTimer = nil
    }

    private func enterDeepPause() {
        deepPauseTimer = nil
        guard isRunning, isPaused, currentReader != nil else { return }
        renderer.stopRequestingMediaData()
        currentReader?.cancelReading()
        nextReader?.cancelReading()
        currentReader = nil
        currentOutput = nil
        nextReader = nil
        nextOutput = nil
        hazelLog("[Renderer] Deep-paused — freed asset readers")
    }

    /// Rebuild the pipeline. seamlessResume=true continues from the paused
    /// timebase position (no black flash, no restart-from-0); false resets to 0.
    /// NEVER removes the displayed image: flush(removingDisplayedImage:false)
    /// always, so a resume from time 0 (deep pause + lock arriving together)
    /// holds the last frame instead of flashing black.
    private func recreatePlayback(seamlessResume: Bool = false) {
        hazelLog("[Renderer] recreatePlayback seamless=\(seamlessResume)")
        renderer.stopRequestingMediaData()
        currentReader?.cancelReading()
        nextReader?.cancelReading()
        nextReader = nil
        nextOutput = nil

        let resumeTime = CMTimebaseGetTime(timebase)
        let continuing = seamlessResume && resumeTime.isValid && resumeTime.isNumeric && resumeTime > .zero
        // Load-bearing: always false. A resume from time 0 with `true` here
        // blanks the still and shows black until the first decode lands.
        renderer.flush(removingDisplayedImage: false)

        guard let reader = try? AVAssetReader(asset: asset) else {
            hazelLog("[Renderer] ERROR: recreate reader-create failed — holding still")
            currentReader = nil
            currentOutput = nil
            enqueueFallbackStill(reason: "recreate-reader-failed")
            return
        }
        if continuing {
            reader.timeRange = CMTimeRange(start: resumeTime, duration: .positiveInfinity)
        }
        let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        reader.startReading()
        currentReader = reader
        currentOutput = output

        ptsOffset = .zero
        lastEnqueuedEnd = continuing ? resumeTime : .zero
        if !continuing {
            CMTimebaseSetTime(timebase, time: .zero)
        }

        if let first = output.copyNextSampleBuffer() {
            Self.setDisplayImmediately(first)
            renderer.enqueue(first)
            CATransaction.flush()
            let pts = CMSampleBufferGetPresentationTimeStamp(first)
            let dur = CMSampleBufferGetDuration(first)
            if pts.isValid {
                lastEnqueuedEnd = dur.isValid && dur > .zero
                    ? CMTimeAdd(pts, dur)
                    : CMTimeAdd(pts, CMTime(value: 1, timescale: 60))
            }
            hazelLog("[Renderer] recreate first-frame composited")
        } else {
            hazelLog("[Renderer] recreate first-sample nil — holding still")
            enqueueFallbackStill(reason: "recreate-first-sample-nil")
        }

        prepareNextReader()
        feedFromCurrentReader()
    }

    /// Restart on the already-set asset from time 0. Freezes the clock (rate 0)
    /// so fresh PTS-0 frames aren't judged late, async-flushes the decoder
    /// (a flush is a decoder RESET and discards anything enqueued before it
    /// completes), then in the completion resets to 0 and resumes at rate 1.
    /// `removingDisplayedImage:false` holds the last frame — no black.
    /// Failure paths re-enqueue the fallback still and keep rate 0 + retry
    /// instead of running an empty queue at rate 1 (which reads as black).
    private func restartWithCurrentAsset() {
        if flushInFlight {
            hazelLog("[Renderer] restart coalesced (flush in flight)")
            restartPending = true
            return
        }
        hazelLog("[Renderer] switchVideo restart start")
        flushInFlight = true
        CMTimebaseSetRate(timebase, rate: 0.0)
        renderer.stopRequestingMediaData()
        currentReader?.cancelReading()
        nextReader?.cancelReading()
        nextReader = nil
        nextOutput = nil

        renderer.flush(removingDisplayedImage: false) { [weak self] in
            guard let self else { return }
            queue.async { [weak self] in
                guard let self else { return }
                flushInFlight = false
                if restartPending {
                    restartPending = false
                    hazelLog("[Renderer] running coalesced restart")
                    restartWithCurrentAsset()
                    return
                }
                guard isRunning else { return }
                guard let reader = try? AVAssetReader(asset: asset) else {
                    hazelLog("[Renderer] ERROR: switch restart reader-create failed — holding still, retrying")
                    currentReader = nil
                    currentOutput = nil
                    enqueueFallbackStill(reason: "switch-reader-failed")
                    scheduleSwitchRetry()
                    return
                }
                let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
                output.alwaysCopiesSampleData = false
                reader.add(output)
                reader.startReading()
                currentReader = reader
                currentOutput = output

                ptsOffset = .zero
                lastEnqueuedEnd = .zero
                CMTimebaseSetTime(timebase, time: .zero)

                if let first = output.copyNextSampleBuffer() {
                    Self.setDisplayImmediately(first)
                    renderer.enqueue(first)
                    CATransaction.flush()
                    let pts = CMSampleBufferGetPresentationTimeStamp(first)
                    let dur = CMSampleBufferGetDuration(first)
                    if pts.isValid {
                        lastEnqueuedEnd = dur.isValid && dur > .zero
                            ? CMTimeAdd(pts, dur)
                            : CMTimeAdd(pts, CMTime(value: 1, timescale: 60))
                    }
                    hazelLog("[Renderer] switchVideo done: first-frame composited")
                } else {
                    hazelLog("[Renderer] ERROR: switch restart first-sample nil — holding still, retrying")
                    enqueueFallbackStill(reason: "switch-first-sample-nil")
                    scheduleSwitchRetry()
                    return
                }

                CMTimebaseSetRate(timebase, rate: 1.0)
                if isPaused {
                    holdAfterFirstFrame()
                }
                prepareNextReader()
                feedFromCurrentReader()
            }
        }
    }

    /// Bounded retry for a failed switch restart. Re-runs the restart (which
    /// re-probes the file); the fallback still stays on screen meanwhile.
    private func scheduleSwitchRetry() {
        queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, isRunning, !flushInFlight else { return }
            // Only retry if we still have no live frames queued.
            guard currentOutput == nil || currentReader == nil else { return }
            hazelLog("[Renderer] retrying switch restart")
            restartWithCurrentAsset()
        }
    }

    // MARK: - Preloaded loop reader

    /// Deferred to a separate queue job so the brief blocking track load
    /// doesn't stall the caller — still strictly ordered on `queue`.
    private func prepareNextReader() {
        queue.async { [weak self] in
            guard let self, isRunning else { return }
            installNextReader(asset: asset, track: videoTrack)
        }
    }

    private func installNextReader(asset: AVURLAsset, track: AVAssetTrack) {
        guard let reader = try? AVAssetReader(asset: asset) else { return }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        nextReader = reader
        nextOutput = output
    }

    /// Swap to the preloaded next reader at a loop boundary, advancing the
    /// offset so the next loop's DTS/PTS continue the timeline — gapless, no
    /// flush, no timebase reset.
    private func swapToNextReader() {
        renderer.stopRequestingMediaData()
        ptsOffset = lastEnqueuedEnd

        if let nr = nextReader, let no = nextOutput {
            currentReader = nr
            currentOutput = no
            nextReader = nil
            nextOutput = nil
            hazelLog("[Renderer] loop swap (pre-rolled reader)")
        } else {
            hazelLog("[Renderer] loop swap: no pre-rolled reader — building inline")
            guard let reader = try? AVAssetReader(asset: asset) else {
                hazelLog("[Renderer] ERROR: loop-swap reader-create failed — holding still, retrying")
                enqueueFallbackStill(reason: "loop-swap-reader-failed")
                queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self, isRunning else { return }
                    swapToNextReader()
                }
                return
            }
            let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            reader.add(output)
            currentReader = reader
            currentOutput = output
        }

        currentReader?.startReading()
        prepareNextReader()
        feedFromCurrentReader()
    }

    // MARK: - Playback loop

    private func feedFromCurrentReader() {
        renderer.requestMediaDataWhenReady(on: queue) { [weak self] in
            guard let self, isRunning else {
                self?.renderer.stopRequestingMediaData()
                return
            }

            // Unrecoverable failure — full reset. Dispatched async:
            // requestMediaDataWhenReady is not reentrant.
            if renderer.status == .failed {
                hazelLog("[Renderer] Status failed: \(renderer.error?.localizedDescription ?? "unknown"), recovering")
                renderer.stopRequestingMediaData()
                queue.async { [weak self] in
                    self?.recreatePlayback()
                    if let s = self, !s.isPaused {
                        CMTimebaseSetRate(s.timebase, rate: 1.0)
                    }
                }
                return
            }

            if renderer.requiresFlushToResumeDecoding {
                renderer.flush()
            }

            while renderer.isReadyForMoreMediaData {
                if let sample = currentOutput?.copyNextSampleBuffer() {
                    let adjusted = offsetTimingForLoop(sample)
                    let pts = CMSampleBufferGetPresentationTimeStamp(adjusted)
                    let dur = CMSampleBufferGetDuration(adjusted)
                    if pts.isValid {
                        let sampleEnd = dur.isValid && dur > .zero
                            ? CMTimeAdd(pts, dur)
                            : CMTimeAdd(pts, CMTime(value: 1, timescale: 60))
                        if sampleEnd > lastEnqueuedEnd {
                            lastEnqueuedEnd = sampleEnd
                        }
                    }
                    renderer.enqueue(adjusted)
                } else {
                    // Reader exhausted — loop boundary. Dispatched async:
                    // requestMediaDataWhenReady is not reentrant.
                    renderer.stopRequestingMediaData()
                    queue.async { [weak self] in
                        self?.swapToNextReader()
                    }
                    return
                }
            }
        }
    }

    /// Offset both DTS and PTS of a sample for gapless looping. Returns the
    /// original sample unchanged for the first loop (no copy needed); later
    /// loops share the underlying data buffer, only timing metadata differs.
    private func offsetTimingForLoop(_ sample: CMSampleBuffer) -> CMSampleBuffer {
        guard ptsOffset > .zero else { return sample }

        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        let dts = CMSampleBufferGetDecodeTimeStamp(sample)
        let dur = CMSampleBufferGetDuration(sample)

        var timingInfo = CMSampleTimingInfo(
            duration: dur,
            presentationTimeStamp: pts.isValid ? CMTimeAdd(pts, ptsOffset) : pts,
            decodeTimeStamp: dts.isValid ? CMTimeAdd(dts, ptsOffset) : .invalid,
        )

        var adjusted: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(
            allocator: nil,
            sampleBuffer: sample,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingInfo,
            sampleBufferOut: &adjusted,
        )
        return adjusted ?? sample
    }

    /// Wrap a CGImage in a display-ready sample buffer (shares no state with
    /// any reader; used for the cold-start still seed).
    static func makeStillSampleBuffer(from image: CGImage) -> CMSampleBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        guard CVPixelBufferCreate(
            kCFAllocatorDefault, image.width, image.height,
            kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pixelBuffer,
        ) == kCVReturnSuccess, let pb = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(pb),
            width: image.width, height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue,
        ) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))

        var fmt: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: nil, imageBuffer: pb, formatDescriptionOut: &fmt,
        ) == noErr, let fmt else { return nil }
        var timing = CMSampleTimingInfo(
            duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid,
        )
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: nil, imageBuffer: pb, formatDescription: fmt,
            sampleTiming: &timing, sampleBufferOut: &sample,
        ) == noErr else { return nil }
        return sample
    }
}
