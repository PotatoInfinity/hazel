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
        let asset = AVURLAsset(url: videoURL)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [
                NSLocalizedDescriptionKey: "No video track found in \(videoURL.lastPathComponent)",
            ])
        }
        // Seed the layer with the first frame as a still: on a cold start the
        // agent hosts our context the instant we reply, and a CALayer.contents
        // still reads black cross-process — only IOSurface-backed
        // AVSampleBufferDisplayLayer content composites remotely.
        let still: CGImage? = await HazelSnapshot.firstFrameImage(videoURL: videoURL)
        return HazelVideoRenderer(rootLayer: rootLayer, asset: asset, videoTrack: track, stillImage: still)
    }

    private init(rootLayer: CALayer, asset: AVURLAsset, videoTrack: AVAssetTrack, stillImage: CGImage?) {
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
        if let stillImage, let stillBuffer = HazelVideoRenderer.makeStillSampleBuffer(from: stillImage) {
            HazelVideoRenderer.setDisplayImmediately(stillBuffer)
            renderer.enqueue(stillBuffer)
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
        guard let reader = try? AVAssetReader(asset: asset) else {
            firstFrameShown()
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
        }

        currentReader = reader
        currentOutput = output
        ptsOffset = .zero
        lastEnqueuedEnd = .zero

        CMTimebaseSetRate(timebase, rate: 1.0)
        firstFrameShown()
        if isPaused {
            holdAfterFirstFrame()
            scheduleDeepPause()
        }
        prepareNextReader()
        feedFromCurrentReader()
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
        queue.async { [self] in
            guard isRunning else { return }
            if asset.url == url { return }
            open(url)
        }
    }

    /// Open `url` as the current asset and restart from its first frame.
    private func open(_ url: URL) {
        let newAsset = AVURLAsset(url: url)
        guard let track = Self.loadFirstVideoTrackBlocking(newAsset) else { return }
        asset = newAsset
        videoTrack = track
        restartWithCurrentAsset()
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
    func stop() {
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
                scheduleDeepPause()
            } else {
                guard isPaused else { return }
                isPaused = false
                cancelDeepPauseTimer()
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
    private func recreatePlayback(seamlessResume: Bool = false) {
        renderer.stopRequestingMediaData()
        currentReader?.cancelReading()
        nextReader?.cancelReading()
        nextReader = nil
        nextOutput = nil

        let resumeTime = CMTimebaseGetTime(timebase)
        let continuing = seamlessResume && resumeTime.isValid && resumeTime.isNumeric && resumeTime > .zero
        renderer.flush(removingDisplayedImage: !continuing)

        guard let reader = try? AVAssetReader(asset: asset) else {
            currentReader = nil
            currentOutput = nil
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
            let pts = CMSampleBufferGetPresentationTimeStamp(first)
            let dur = CMSampleBufferGetDuration(first)
            if pts.isValid {
                lastEnqueuedEnd = dur.isValid && dur > .zero
                    ? CMTimeAdd(pts, dur)
                    : CMTimeAdd(pts, CMTime(value: 1, timescale: 60))
            }
        }

        prepareNextReader()
        feedFromCurrentReader()
    }

    /// Restart on the already-set asset from time 0. Freezes the clock (rate 0)
    /// so fresh PTS-0 frames aren't judged late, async-flushes the decoder
    /// (a flush is a decoder RESET and discards anything enqueued before it
    /// completes), then in the completion resets to 0 and resumes at rate 1.
    /// `removingDisplayedImage:false` holds the last frame — no black.
    private func restartWithCurrentAsset() {
        if flushInFlight {
            restartPending = true
            return
        }
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
                    restartWithCurrentAsset()
                    return
                }
                guard isRunning else { return }
                guard let reader = try? AVAssetReader(asset: asset) else {
                    currentReader = nil
                    currentOutput = nil
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
                    let pts = CMSampleBufferGetPresentationTimeStamp(first)
                    let dur = CMSampleBufferGetDuration(first)
                    if pts.isValid {
                        lastEnqueuedEnd = dur.isValid && dur > .zero
                            ? CMTimeAdd(pts, dur)
                            : CMTimeAdd(pts, CMTime(value: 1, timescale: 60))
                    }
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
        } else {
            guard let reader = try? AVAssetReader(asset: asset) else { return }
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
