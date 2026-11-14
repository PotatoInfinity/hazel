// HazelHandler.swift
//
// Ported from Phosphene's WallpaperXPCHandler.swift + PlaybackModel.swift
// (MIT License, Copyright (c) 2026 kageroumado). Simplified: one surface per
// WallpaperID UUID, serial lifecycle queue, lock-screen-only playback policy
// (play when locked/idle-ours, still otherwise), stub settings/choices.

import AppKit
import AVFoundation
import CoreMedia
import QuartzCore

// MARK: - Model

/// One hosted wallpaper surface: a distinct CAContext that WallpaperAgent
/// hosts in one CALayerHost. One per WallpaperID UUID (Space, lock-screen
/// surface, Settings preview).
struct HazelSurfaceKey: Hashable, Sendable, CustomStringConvertible {
    let surfaceUUID: UUID
    var description: String { "surface \(surfaceUUID.uuidString.prefix(8))" }
}

nonisolated enum HazelPresentationMode: Equatable, Sendable, CustomStringConvertible {
    case `default`
    case locked
    case idle
    case other(String)

    init(caseName: String) {
        switch caseName {
        case "default": self = .default
        case "locked": self = .locked
        case "idle": self = .idle
        default: self = .other(caseName)
        }
    }

    var description: String {
        switch self {
        case .default: "default"
        case .locked: "locked"
        case .idle: "idle"
        case let .other(name): name
        }
    }
}

nonisolated enum HazelActivityState: Equatable, Sendable {
    case active
    case suspended
    case other(String)

    init(caseName: String) {
        if caseName == "active" { self = .active }
        else if caseName.contains("suspended") { self = .suspended }
        else { self = .other(caseName) }
    }
}

final class HazelHostedSurface {
    let caContext: CAContext
    let contextId: UInt32
    let rootLayer: CALayer
    var renderer: HazelVideoRenderer?
    var placeholder: CALayer?
    var videoID: String?
    var mode: HazelPresentationMode = .default
    var activity: HazelActivityState = .active
    var destSize: CGSize
    var scale: CGFloat

    init(caContext: CAContext, contextId: UInt32, rootLayer: CALayer,
         destSize: CGSize, scale: CGFloat) {
        self.caContext = caContext
        self.contextId = contextId
        self.rootLayer = rootLayer
        self.destSize = destSize
        self.scale = scale
    }
}

/// Registry of live surfaces. All access on the serial lifecycle queue except
/// where noted.
enum HazelSurfaceRegistry {
    static let shared = HazelRegistryStore()

    /// Grace between an invalidate and the actual teardown. A re-acquire
    /// cancels it; only a surface that stays gone lets it fire.
    static let teardownGrace: TimeInterval = 15.0
}

final class HazelRegistryStore: @unchecked Sendable {
    private let lock = NSLock()
    private nonisolated(unsafe) var surfaces: [HazelSurfaceKey: HazelHostedSurface] = [:]
    private nonisolated(unsafe) var idToKey: [UUID: HazelSurfaceKey] = [:]
    private nonisolated(unsafe) var pendingTeardown: [HazelSurfaceKey: DispatchWorkItem] = [:]
    private nonisolated(unsafe) var rendererInFlight: Set<HazelSurfaceKey> = []
    private nonisolated(unsafe) var retargetLibraryWork: DispatchWorkItem?
    private nonisolated(unsafe) var retargetAllWork: DispatchWorkItem?

    func surface(for key: HazelSurfaceKey) -> HazelHostedSurface? {
        lock.lock(); defer { lock.unlock() }
        return surfaces[key]
    }

    func key(forWallpaperID uuid: UUID) -> HazelSurfaceKey? {
        lock.lock(); defer { lock.unlock() }
        return idToKey[uuid]
    }

    func install(_ surface: HazelHostedSurface, for key: HazelSurfaceKey, wallpaperID: UUID) {
        lock.lock(); defer { lock.unlock() }
        surfaces[key] = surface
        idToKey[wallpaperID] = key
    }

    func updateVideoID(_ videoID: String?, for key: HazelSurfaceKey) {
        lock.lock(); defer { lock.unlock() }
        surfaces[key]?.videoID = videoID
    }

    func forget(wallpaperID: UUID) -> HazelSurfaceKey? {
        lock.lock(); defer { lock.unlock() }
        let key = idToKey.removeValue(forKey: wallpaperID)
        return key
    }

    func claimRendererCreate(for key: HazelSurfaceKey) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if rendererInFlight.contains(key) { return false }
        rendererInFlight.insert(key)
        return true
    }

    func clearRendererPending(for key: HazelSurfaceKey) {
        lock.lock(); defer { lock.unlock() }
        rendererInFlight.remove(key)
    }

    @discardableResult
    func setRenderer(_ renderer: HazelVideoRenderer, videoID: String?, for key: HazelSurfaceKey) -> HazelVideoRenderer? {
        lock.lock(); defer { lock.unlock() }
        rendererInFlight.remove(key)
        let old = surfaces[key]?.renderer
        surfaces[key]?.renderer = renderer
        surfaces[key]?.videoID = videoID
        return old
    }

    /// Must be called on the lifecycle queue.
    func scheduleTeardown(for key: HazelSurfaceKey, on queue: DispatchQueue) {
        lock.lock()
        pendingTeardown[key]?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.pendingTeardown[key] = nil
            let surface = self.surfaces.removeValue(forKey: key)
            self.lock.unlock()
            surface?.renderer?.stop()
            hazelLog("  [teardown] grace fired for \(key)")
        }
        pendingTeardown[key] = item
        lock.unlock()
        queue.asyncAfter(deadline: .now() + HazelSurfaceRegistry.teardownGrace, execute: item)
    }

    /// Must be called on the lifecycle queue.
    func cancelTeardown(for key: HazelSurfaceKey) {
        lock.lock(); defer { lock.unlock() }
        if let item = pendingTeardown.removeValue(forKey: key) {
            item.cancel()
            hazelLog("  [teardown] cancelled pending teardown for \(key) (re-acquired)")
        }
    }

    /// Re-resolve every live surface against the freshly scanned library:
    /// video changed on disk -> switch in place; surface still showing the
    /// no-video placeholder -> attach a renderer now.
    /// Debounced: rapid library-changed signals coalesce into one retarget.
    func retargetToLibrary() {
        lock.lock()
        retargetLibraryWork?.cancel()
        let work = DispatchWorkItem {
            let store = HazelSurfaceRegistry.shared
            store.lock.lock()
            let pairs = store.surfaces.map { ($0.key, $0.value) }
            store.lock.unlock()
            for (key, surface) in pairs {
                guard let url = HazelLibrary.shared.videoURL(forChoice: surface.videoID) else {
                    // No usable file for this surface's choice (mid-copy /
                    // torn scan): keep the current frame/placeholder in place.
                    // switchVideo's probe would abort anyway; staying put holds
                    // a frame instead of gaping to black.
                    hazelLog("  [library] retarget skip \(key) choice=\(surface.videoID ?? "nil") (no usable file — holding current frame)")
                    continue
                }
                if let renderer = surface.renderer {
                    hazelLog("  [library] retarget switch start \(key) mode=\(surface.mode) activity=\(surface.activity) → \(url.lastPathComponent) (holds last frame during swap, never gaps to black)")
                    renderer.switchVideo(to: url)
                } else if store.claimRendererCreate(for: key) {
                    hazelLog("  [library] retarget attach start \(key) mode=\(surface.mode) activity=\(surface.activity) → \(url.lastPathComponent)")
                    let boxedRoot = HazelSendableBox(value: surface.rootLayer)
                    let boxedVideoID = HazelSendableBox(value: surface.videoID)
                    let boxedMode = HazelSendableBox(value: surface.mode)
                    let boxedActivity = HazelSendableBox(value: surface.activity)
                    Task {
                        await HazelWallpaperHandler.attachRenderer(
                            rootLayer: boxedRoot.value, videoURL: url,
                            key: key, choice: boxedVideoID.value,
                            startPaused: !HazelPolicy.shouldPlay(
                                mode: boxedMode.value, activity: boxedActivity.value,
                                prefs: HazelPrefsSource.current),
                        )
                        if let s = store.surface(for: key) {
                            s.placeholder?.removeFromSuperlayer()
                            s.placeholder = nil
                        }
                    }
                }
            }
        }
        retargetLibraryWork = work
        lock.unlock()
        // Hop to the lifecycle queue; surfaces are owned there. Debounce so a
        // burst of library-changed signals runs one retarget, never stacked.
        HazelLifecycle.queue.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// Recompute pause/play for every live surface from current mode + prefs.
    /// Called when hazel-prefs.json changes. Debounced like retargetToLibrary.
    func retargetAll() {
        lock.lock()
        retargetAllWork?.cancel()
        let work = DispatchWorkItem {
            let store = HazelSurfaceRegistry.shared
            store.lock.lock()
            let pairs = store.surfaces.map { ($0.key, $0.value) }
            store.lock.unlock()
            for (_, surface) in pairs {
                surface.renderer?.setPaused(!HazelPolicy.shouldPlay(
                    mode: surface.mode, activity: surface.activity,
                    prefs: HazelPrefsSource.current,
                ))
            }
        }
        retargetAllWork = work
        lock.unlock()
        // Hop to the lifecycle queue; surfaces are owned there.
        HazelLifecycle.queue.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    func updateAll(mode: HazelPresentationMode, activity: HazelActivityState) {
        // Surface mode/activity are owned by the lifecycle queue; mutate there
        // so a burst of updates serializes with acquire/update/invalidate.
        HazelLifecycle.queue.async { [mode, activity] in
            let store = HazelSurfaceRegistry.shared
            store.lock.lock()
            let all = Array(store.surfaces.values)
            store.lock.unlock()
            for surface in all {
                surface.mode = mode
                surface.activity = activity
                surface.renderer?.setPaused(!HazelPolicy.shouldPlay(
                    mode: mode, activity: activity, prefs: HazelPrefsSource.current,
                ))
            }
        }
    }

    func forEachRenderer(_ body: (HazelVideoRenderer) -> Void) {
        lock.lock()
        let renderers = surfaces.values.compactMap { $0.renderer }
        lock.unlock()
        for r in renderers { body(r) }
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return surfaces.count
    }
}

// MARK: - Lifecycle serialization

/// Process-wide serialization for wallpaper lifecycle XPC. Every connection
/// gets its own handler, but the Agent multiplexes desktop + preview +
/// thumbnail connections, so lifecycle callbacks can otherwise interleave.
/// One serial queue funnels them all.
enum HazelLifecycle {
    static let queue = DispatchQueue(label: "live.hazel.wallpaper.lifecycle")
}

// MARK: - Playback policy

/// Simplified policy: with alwaysPauseDesktop (the default and the Hazel
/// contract), the wallpaper plays only on the lock screen and in our own
/// screensaver slot; the desktop holds a still frame. A suspended surface is
/// never composited, so it never plays.
/// INVARIANT: locked/idle ALWAYS play, for either prefs value. Prefs only
/// decide the desktop; a missing/corrupt prefs file therefore fails toward
/// playing on locked (never toward black) — see HazelPrefsSource.postCurrent,
/// which keeps the last-known prefs on any read/decode failure.
enum HazelPolicy {
    static func shouldPlay(mode: HazelPresentationMode, activity: HazelActivityState,
                           prefs: HazelPrefs) -> Bool {
        if activity == .suspended { return false }
        if prefs.alwaysPauseDesktop {
            return mode == .locked || mode == .idle
        }
        return true
    }
}

// MARK: - XPC handler

final class HazelWallpaperHandler: NSObject, WallpaperExtensionXPCProtocol {
    /// Stable per-display surface UUID for acquires carrying no WallpaperID.
    static func fallbackSurfaceUUID(forDisplay displayID: UInt32) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", displayID))
            ?? UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    }

    // MARK: acquire

    func acquire(withId id: Any?, request: Any?, reply: @escaping @Sendable (Any?, (any Error)?) -> Void) {
        nonisolated(unsafe) let unsafeRequest = request
        nonisolated(unsafe) let unsafeID = id
        nonisolated(unsafe) let handler = self
        HazelLifecycle.queue.async { handler.acquireBody(id: unsafeID, request: unsafeRequest, reply: reply) }
    }

    private func acquireBody(id: Any?, request: Any?, reply: @escaping @Sendable (Any?, (any Error)?) -> Void) {
        hazelLog("=== ACQUIRE ===")
        let (destSize, scale, isPreview, displayID) = hazelExtractDestination(fromRequest: request)
        let (choice, _) = hazelExtractChoice(fromRequest: request)
        hazelLog("  destination: \(destSize) @\(scale)x preview=\(isPreview), choice: \(choice ?? "nil")")

        let surfaceUUID = hazelExtractWallpaperUUID(fromID: id) ?? Self.fallbackSurfaceUUID(forDisplay: displayID ?? 0)
        let key = HazelSurfaceKey(surfaceUUID: surfaceUUID)
        let registry = HazelSurfaceRegistry.shared
        registry.cancelTeardown(for: key)

        var videoURL = HazelLibrary.shared.videoURL(forChoice: choice)
        if videoURL == nil {
            // Lock-time race: the agent can spawn us in the middle of the
            // app's atomic library.json/video replace. An init-time scan may
            // have seen the pre-rename state, so re-scan immediately — this
            // covers already-completed renames without stalling the serial
            // lifecycle queue (no Thread.sleep here: every other surface's
            // acquire/update/invalidate would wait). A still-missing file is
            // a genuine mid-copy window: CREATE seeds a placeholder and
            // schedules a short delayed re-scan below.
            hazelLog("  [acquire] no usable video for choice \(choice ?? "nil") entries=\(HazelLibrary.shared.entries.count) display=\(displayID.map(String.init) ?? "nil") — immediate re-scan (no queue block)")
            HazelLibrary.shared.scan()
            videoURL = HazelLibrary.shared.videoURL(forChoice: choice)
            if videoURL == nil {
                hazelLog("  [acquire] RETRY miss: still no video for choice \(choice ?? "nil") — gradient fallback (not black)")
            } else {
                hazelLog("  [acquire] RETRY hit: \(videoURL!.lastPathComponent) size=\(HazelLibrary.fileSize(at: videoURL!).map(String.init) ?? "nil")")
            }
        }
        if let url = videoURL {
            hazelLog("  [acquire] video \(url.lastPathComponent) size=\(HazelLibrary.fileSize(at: url).map(String.init) ?? "nil") display=\(displayID.map(String.init) ?? "nil") mode-at-acquire=\(registry.surface(for: key)?.mode ?? .default) (mode arrives via update)")
        }
        // Fail toward PLAYING: the mode is unknown at acquire time (it arrives
        // via a later update). Starting paused risks a lockscreen surface
        // staying a still forever if that update is lost; starting playing
        // self-corrects on the desktop via the first update's pause. Locked
        // and idle ALWAYS play per policy, so playing is the safe default.
        _ = false as Bool // startPaused always false: fail toward playing

        // ---- REUSE: this surface's context already exists ----
        if let existing = registry.surface(for: key) {
            hazelLog("  [acquire] REUSE ctx=\(existing.contextId) \(key)")
            if existing.destSize != destSize || existing.scale != scale {
                existing.destSize = destSize
                existing.scale = scale
                existing.rootLayer.frame = CGRect(origin: .zero, size: destSize)
                existing.rootLayer.contentsScale = scale
                existing.renderer?.resize(to: destSize, scale: scale)
            }
            guard let replyObj = hazelCreateRemoteContextXPC(contextId: existing.contextId) else {
                hazelLog("  [acquire] ERROR: remote-context XPC build failed")
                reply(nil, NSError(domain: "HazelWallpaperExtension", code: 3, userInfo: nil)); return
            }
            reply(replyObj, nil)
            hazelLog("  [acquire] REUSE replied ctx=\(existing.contextId) (already composited, no gap)")
            if isPreview {
                // Settings preview: still only. Never start the decode loop here.
                return
            }
            if existing.videoID == choice, existing.renderer != nil {
                hazelLog("  [acquire] REUSE same video, renderer live — no switch")
                return
            }
            guard let videoURL else {
                hazelLog("  [acquire] REUSE no video staged — keeping current surface")
                return
            }
            if let renderer = existing.renderer {
                hazelLog("  [acquire] REUSE switchVideo start choice=\(choice ?? "nil") url=\(videoURL.lastPathComponent)")
                renderer.switchVideo(to: videoURL)
                registry.updateVideoID(choice, for: key)
            } else if registry.claimRendererCreate(for: key) {
                let boxedRoot = HazelSendableBox(value: existing.rootLayer)
                let boxedKey = HazelSendableBox(value: key)
                let boxedChoice = HazelSendableBox(value: choice)
                let snapMode = existing.mode
                let snapActivity = existing.activity
                Task {
                    await HazelWallpaperHandler.attachRenderer(
                        rootLayer: boxedRoot.value, videoURL: videoURL,
                        key: boxedKey.value, choice: boxedChoice.value,
                        startPaused: HazelPolicy.shouldPlay(
                            mode: snapMode,
                            activity: snapActivity, prefs: HazelPrefsSource.current,
                        ) == false,
                    )
                }
            } else {
                // Renderer build already in flight for this surface: the reply
                // below hosts whatever is composited NOW. If the layer is
                // still empty (CREATE task hasn't installed its display layer
                // yet) the host would show black — seed a gradient first so
                // the surface never presents empty. The in-flight build
                // replaces this placeholder when its first frame lands.
                hazelLog("  [acquire] REUSE renderer build in flight for \(key) — ensuring placeholder before reply (never empty)")
                Self.ensureGradientPlaceholder(for: key, size: destSize)
            }
            return
        }

        // ---- CREATE: first acquire for this surface ----
        // NOTE: remoteContext + layer tree are built on the main thread. Core
        // Animation layer trees that cross into the WindowServer must be
        // created on the main thread; the lifecycle serial queue is a worker.
        // Async (never main.sync): blocking the lifecycle queue on main
        // deadlocks when main waits on lifecycle work and stalls every other
        // surface. Reply happens in the lifecycle continuation below.
        let createDestSize = destSize
        let createScale = scale
        let createSurfaceUUID = surfaceUUID
        let createKey = key
        let createChoice = choice
        let createVideoURL = videoURL
        let createIsPreview = isPreview
        let boxedHandler = HazelSendableBox(value: self)
        DispatchQueue.main.async {
            guard let caContext = CAContext.remoteContext() as? CAContext, caContext.contextId != 0 else {
                HazelLifecycle.queue.async {
                    hazelLog("  ERROR: remote CAContext creation failed")
                    reply(nil, NSError(domain: "HazelWallpaperExtension", code: 4,
                                       userInfo: [NSLocalizedDescriptionKey: "Failed to create remote CAContext"]))
                }
                return
            }
            let rootLayer = CALayer()
            rootLayer.frame = CGRect(origin: .zero, size: createDestSize)
            rootLayer.contentsScale = createScale
            rootLayer.contentsGravity = .resizeAspectFill
            caContext.layer = rootLayer
            CATransaction.flush()
            let boxedContext = HazelSendableBox(value: caContext)
            let boxedRoot = HazelSendableBox(value: rootLayer)
            HazelLifecycle.queue.async {
                let caContext = boxedContext.value
                let rootLayer = boxedRoot.value
                let contextId = caContext.contextId
                let registry = HazelSurfaceRegistry.shared
                guard let replyObj = hazelCreateRemoteContextXPC(contextId: contextId) else {
                    reply(nil, NSError(domain: "HazelWallpaperExtension", code: 3, userInfo: nil)); return
                }

                let hosted = HazelHostedSurface(caContext: caContext, contextId: contextId,
                                                rootLayer: rootLayer, destSize: createDestSize, scale: createScale)
                registry.install(hosted, for: createKey, wallpaperID: createSurfaceUUID)
                hazelLog("  Created context \(contextId) for \(createKey) at \(createDestSize) @\(createScale)x")

                if createIsPreview {
                    // Settings preview: seed a still and stop. No decode loop, no looper.
                    boxedHandler.value.seedPreviewStill(into: rootLayer, size: createDestSize, videoURL: createVideoURL, reply: reply, replyObj: replyObj)
                    return
                }

                guard let videoURL = createVideoURL else {
                    // No video staged: solid fallback on main, then reply.
                    // Tracked as the placeholder so a later stage removes it.
                    let boxedReply2 = HazelSendableBox(value: replyObj)
                    DispatchQueue.main.async {
                        let gradient = CAGradientLayer()
                        gradient.colors = [
                            CGColor(red: 0.15, green: 0.1, blue: 0.25, alpha: 1.0),
                            CGColor(red: 0.05, green: 0.1, blue: 0.2, alpha: 1.0),
                        ]
                        gradient.frame = CGRect(origin: .zero, size: createDestSize)
                        CATransaction.begin(); CATransaction.setDisableActions(true)
                        rootLayer.addSublayer(gradient)
                        CATransaction.commit(); CATransaction.flush()
                        HazelLifecycle.queue.async {
                            HazelSurfaceRegistry.shared.surface(for: createKey)?.placeholder = gradient
                            reply(boxedReply2.value, nil)
                            // Mid-copy window: the staged file may land just after this
                            // reply. Re-scan shortly and retarget so the video attaches
                            // without waiting for the next library-changed signal.
                            // asyncAfter, never sleep: the lifecycle queue stays live.
                            HazelLifecycle.queue.asyncAfter(deadline: .now() + 0.35) {
                                HazelLibrary.shared.scan()
                                HazelSurfaceRegistry.shared.retargetToLibrary()
                            }
                        }
                    }
                    return
                }

                if registry.claimRendererCreate(for: createKey) {
                    let boxedRoot2 = HazelSendableBox(value: rootLayer)
                    let boxedReply = HazelSendableBox(value: replyObj)
                    let boxedKey = HazelSendableBox(value: createKey)
                    let boxedChoice = HazelSendableBox(value: createChoice)
                    let boxedSeedSize = HazelSendableBox(value: createDestSize)
                    let createT0 = Date()
                    // Cold-start fast start: reply after the STILL is composited
                    // (create installs an infallible still — cached frame →
                    // solid color — so the hosted context is never empty/black),
                    // then refine with full-res video frames after. Blocking the
                    // reply on the first full-4K video decode serializes two
                    // HEVC decodes + a PNG persist before the agent may host us
                    // (the ~8s cold); the still already satisfies
                    // transparent-until-ready, and start() refines it in place
                    // on the same layer. Switch racing a live surface is
                    // covered by REUSE above.
                    Task {
                        do {
                            let renderer = try await HazelVideoRenderer.create(
                                rootLayer: boxedRoot2.value, videoURL: videoURL,
                                seedTargetSize: boxedSeedSize.value,
                            )
                            let old = registry.setRenderer(renderer, videoID: boxedChoice.value, for: boxedKey.value)
                            old?.stop()
                            if let surface = registry.surface(for: boxedKey.value) {
                                surface.placeholder?.removeFromSuperlayer()
                                surface.placeholder = nil
                            }
                            hazelLog("  [acquire] CREATE still composited (seed \(videoURL.lastPathComponent)), replying ctx=\(contextId) in \(String(format: "%.2f", Date().timeIntervalSince(createT0)))s — video refines after")
                            reply(boxedReply.value, nil)
                            await renderer.start()
                            hazelLog("  [acquire] CREATE first-frame VIDEO composited (video \(videoURL.lastPathComponent)) in \(String(format: "%.2f", Date().timeIntervalSince(createT0)))s")
                        } catch {
                            // create() throws BEFORE installing any layer (no track /
                            // mid-copy file). Replying now would host an empty context
                            // = BLACK on the lockscreen, permanently (no retry was
                            // scheduled). Seed the gradient fallback so the surface
                            // never presents empty, then rely on the next
                            // library-changed signal (retargetToLibrary) to attach.
                            hazelLog("  [Renderer] CREATE failed for \(videoURL.lastPathComponent): \(error) — gradient fallback, replying (never empty-black)")
                            Self.ensureGradientPlaceholder(for: createKey, size: createDestSize) {
                                registry.clearRendererPending(for: boxedKey.value)
                                reply(boxedReply.value, nil)
                            }
                        }
                    }
                } else {
                    // Defensive: claim failed on a fresh surface (second CREATE racing
                    // the first on the serial queue should be impossible — it would
                    // have hit REUSE — but fail toward a visible gradient, never an
                    // empty reply).
                    hazelLog("  [acquire] CREATE claim contention for \(createKey) — gradient fallback, replying (never empty-black)")
                    Self.ensureGradientPlaceholder(for: createKey, size: createDestSize) {
                        reply(replyObj, nil)
                    }
                }
            }
        }
        return
    }

    /// Seed a Settings preview surface with one still frame: no renderer, no
    /// loop, no audio pipeline. Cheap enough to rebuild on every preview open.
    /// Infallible: falls back to cached frame / solid color so preview never
    /// shows an empty (black) layer.
    private func seedPreviewStill(into rootLayer: CALayer, size: CGSize, videoURL: URL?,
                                  reply: @escaping @Sendable (Any?, (any Error)?) -> Void,
                                  replyObj: Any) {
        guard let videoURL else {
            hazelLog("  [acquire] preview: no video — replying with empty surface (placeholder)")
            reply(replyObj, nil)
            return
        }
        let boxedRoot = HazelSendableBox(value: rootLayer)
        let boxedReply = HazelSendableBox(value: replyObj)
        let boxedSize = HazelSendableBox(value: size)
        Task {
            // Preview decodes at display size, not full 4K: the still is only
            // ever shown scaled into `size`, so a full-res hvc1 decode is pure
            // cold cost on the preview path too.
            let still = await HazelSnapshot.seedImage(
                videoURL: videoURL,
                maximumSize: HazelSnapshot.seedSize(forDestination: boxedSize.value))
            DispatchQueue.main.async {
                boxedRoot.value.contents = still
                boxedRoot.value.contentsGravity = .resizeAspectFill
                boxedRoot.value.frame = CGRect(origin: .zero, size: boxedSize.value)
                CATransaction.flush()
                hazelLog("  [acquire] preview still seeded (infallible)")
                reply(boxedReply.value, nil)
            }
        }
    }

    /// Attach a renderer to an already-hosted surface (REUSE path with no
    /// renderer yet). Runs off the lifecycle queue.
    /// On create failure the surface keeps its gradient placeholder (seeded
    /// by the caller) so the host never composites an empty layer; the next
    /// library-changed signal retries the attach.
    static func attachRenderer(rootLayer: CALayer, videoURL: URL, key: HazelSurfaceKey,
                                       choice: String?, startPaused: Bool) async {
        hazelLog("  [acquire] attachRenderer start \(key) choice=\(choice ?? "nil") url=\(videoURL.lastPathComponent) startPaused=\(startPaused)")
        let registry = HazelSurfaceRegistry.shared
        do {
            let seedSize: CGSize? = registry.surface(for: key).map { HazelSnapshot.seedSize(forDestination: $0.destSize) }
            let renderer = try await HazelVideoRenderer.create(rootLayer: rootLayer, videoURL: videoURL,
                                                               seedTargetSize: seedSize)
            let old = registry.setRenderer(renderer, videoID: choice, for: key)
            old?.stop()
            if let surface = registry.surface(for: key) {
                surface.placeholder?.removeFromSuperlayer()
                surface.placeholder = nil
            }
            if startPaused { renderer.setPaused(true) }
            await renderer.start()
            hazelLog("  [acquire] attachRenderer done \(key): first-frame composited (still-then-video fast start \(videoURL.lastPathComponent))")
        } catch {
            hazelLog("  [Renderer] attach failed for \(videoURL.lastPathComponent): \(error) — placeholder kept, retry on next library signal")
            registry.clearRendererPending(for: key)
            ensureGradientPlaceholder(for: key, size: nil)
        }
    }

    /// Guarantee the surface's layer never presents empty: if it currently has
    /// no video sublayer and no placeholder, install the dark gradient. Used
    /// on every path that replies without a composited video frame, so a
    /// reply can never precede seeding. Layer work hops to main (remote
    /// contexts must be mutated there). No-op when content already exists.
    /// Async (never main.sync): callers needing order pass a completion that
    /// runs after the placeholder is installed.
    static func ensureGradientPlaceholder(for key: HazelSurfaceKey, size: CGSize?,
                                          completion: (@Sendable () -> Void)? = nil) {
        guard let surface = HazelSurfaceRegistry.shared.surface(for: key) else {
            completion?()
            return
        }
        let frameSize = size ?? surface.destSize
        let work: @Sendable () -> Void = {
            let hasContent = !(surface.rootLayer.sublayers?.isEmpty ?? true)
            if hasContent {
                completion?()
                return
            }
            if surface.placeholder != nil {
                completion?()
                return
            }
            let gradient = CAGradientLayer()
            gradient.colors = [
                CGColor(red: 0.15, green: 0.1, blue: 0.25, alpha: 1.0),
                CGColor(red: 0.05, green: 0.1, blue: 0.2, alpha: 1.0),
            ]
            gradient.frame = CGRect(origin: .zero, size: frameSize)
            CATransaction.begin(); CATransaction.setDisableActions(true)
            surface.rootLayer.addSublayer(gradient)
            CATransaction.commit(); CATransaction.flush()
            surface.placeholder = gradient
            hazelLog("  [acquire] gradient placeholder installed for \(key) (never empty-black)")
            completion?()
        }
        if Thread.isMainThread { work() }
        else { DispatchQueue.main.async(execute: work) }
    }

    // MARK: update

    func update(withId id: Any?, request: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        nonisolated(unsafe) let unsafeRequest = request
        nonisolated(unsafe) let unsafeID = id
        nonisolated(unsafe) let handler = self
        HazelLifecycle.queue.async { handler.updateBody(id: unsafeID, request: unsafeRequest, reply: reply) }
    }

    private func updateBody(id: Any?, request: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        let (mode, activity) = hazelReadPresentation(request: request)
        let registry = HazelSurfaceRegistry.shared
        if let uuid = hazelExtractWallpaperUUID(fromID: id),
           let key = registry.key(forWallpaperID: uuid),
           let surface = registry.surface(for: key) {
            surface.mode = mode
            surface.activity = activity
            let prefs = HazelPrefsSource.current
            let play = HazelPolicy.shouldPlay(mode: mode, activity: activity, prefs: prefs)
            surface.renderer?.setPaused(!play)
            // Distinguish every park reason: suspended/other/mode drive
            // different fixes, and "PAUSE (hold last frame)" must never be
            // confused with black (empty layer) in post-mortem logs.
            hazelLog("=== UPDATE === \(key) mode=\(mode) activity=\(activity) alwaysPauseDesktop=\(prefs.alwaysPauseDesktop) renderer=\(surface.renderer == nil ? "nil" : "live") → \(play ? "PLAY" : "PAUSE (hold last frame, not black)")")
        } else {
            // Unknown or missing surface id: ignore. Fanning out to every
            // surface here caused unrelated desktops to freeze on stray updates.
            // Fallback per-display surfaces (no WallpaperID) land here: they
            // keep their acquire-time playing state, logged distinctly.
            hazelLog("=== UPDATE === unknown surface id, ignoring (mode=\(mode) activity=\(activity)); fallback surfaces keep acquire-time state")
        }
        reply(nil)
    }

    // MARK: invalidate

    func invalidate(withId id: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        nonisolated(unsafe) let unsafeID = id
        nonisolated(unsafe) let handler = self
        HazelLifecycle.queue.async { handler.invalidateBody(id: unsafeID, reply: reply) }
    }

    private func invalidateBody(id: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        let registry = HazelSurfaceRegistry.shared
        guard let uuid = hazelExtractWallpaperUUID(fromID: id) else {
            hazelLog("=== INVALIDATE === no UUID in id → ignore")
            reply(nil); return
        }
        guard let key = registry.forget(wallpaperID: uuid) else {
            hazelLog("=== INVALIDATE === UUID \(uuid) unknown → ignore")
            reply(nil); return
        }
        registry.scheduleTeardown(for: key, on: HazelLifecycle.queue)
        hazelLog("=== INVALIDATE === \(key) → tear down in \(HazelSurfaceRegistry.teardownGrace)s unless re-acquired")
        reply(nil)
    }

    // MARK: snapshot

    func snapshot(withId id: Any?, reply: @escaping @Sendable (Any?, (any Error)?) -> Void) {
        // Snapshot the surface the agent asked about (login-screen export shows
        // the wrong video if we answer with an arbitrary surface's frame).
        // Never touches the live layer: decode goes generator → IOSurface →
        // XPC, so live playback cannot blank here by construction.
        hazelLog("=== SNAPSHOT === (live layer untouched)")
        let uuid = hazelExtractWallpaperUUID(fromID: id)
        let key = uuid.flatMap { HazelSurfaceRegistry.shared.key(forWallpaperID: $0) }
        let surface = key.flatMap { HazelSurfaceRegistry.shared.surface(for: $0) }
        let videoID = surface?.videoID
        let timebase: CMTime? = {
            guard let renderer = surface?.renderer else { return nil }
            return CMTimebaseGetTime(renderer.timebase)
        }()
        let boxedTime = HazelSendableBox(value: timebase)
        let boxedVideoID = HazelSendableBox(value: videoID)
        Task {
            let videoURL: URL?
            if let vid = boxedVideoID.value {
                videoURL = HazelLibrary.shared.videoURL(forChoice: vid)
            } else {
                videoURL = HazelLibrary.shared.videoURL(forChoice: nil)
            }
            if let snapshotXPC = await HazelSnapshot.createSnapshotViaRuntime(
                videoURL: videoURL, currentTime: boxedTime.value,
            ) {
                hazelLog("=== SNAPSHOT === done (live layer untouched)")
                reply(snapshotXPC, nil)
            } else {
                hazelLog("=== SNAPSHOT === failed: no frame (live layer untouched)")
                reply(nil, nil)
            }
        }
    }

    // MARK: - Settings (minimal: no Settings UI in this build)

    func provideSettingsViewModels(withContentTypes _: Any?, reply: @escaping @Sendable (Any?, (any Error)?) -> Void) {
        reply(nil, nil)
    }

    // MARK: - Choices (stubs)

    func addChoiceRequest(withChoiceRequest _: Any?, onBehalfOfProcess _: Any?, reply: @escaping @Sendable (Any?, (any Error)?) -> Void) {
        reply(nil, nil)
    }

    func removeChoiceRequest(withChoiceRequest _: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        reply(nil)
    }

    func selectedChoicesDidChange(for _: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        reply(nil)
    }

    func invokeContextMenuAction(withMenuItemID _: Any?, groupItemID _: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        reply(nil)
    }

    // MARK: - Downloads (single staged video is always "downloaded")

    func isChoiceDownloaded(with _: Any?, reply: @escaping @Sendable (NSNumber?, (any Error)?) -> Void) {
        reply(NSNumber(value: true), nil)
    }

    func download(withChoiceID _: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) -> Any? {
        reply(nil)
        return nil
    }

    func pauseDownload(for _: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        reply(nil)
    }

    func cancelDownload(for _: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        reply(nil)
    }

    func resumeDownload(for _: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        reply(nil)
    }

    func removeDownload(for _: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        reply(nil)
    }

    // MARK: - Migration (stubs)

    func migrateSelectedChoice(for _: Any?, reply: @escaping @Sendable (Any?, (any Error)?) -> Void) {
        reply(nil, nil)
    }

    func migrate(from _: Any?, to _: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        reply(nil)
    }

    // MARK: - Shuffle (single video: nothing to skip)

    func skipShuffledContent(withId _: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        reply(nil)
    }

    func canSkipShuffledContent(withId _: Any?, reply: @escaping @Sendable (Bool, (any Error)?) -> Void) {
        reply(false, nil)
    }

    // MARK: - Debug & notifications (stubs)

    func handleDebugRequest(for _: Any?, reply: @escaping @Sendable (Any?, (any Error)?) -> Void) {
        reply(nil, nil)
    }

    func handleNotification(withNamed _: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        reply(nil)
    }
}

/// Box a non-Sendable value (e.g. a CALayer) into a Task without tainting the
/// closure's isolation region.
struct HazelSendableBox<T>: @unchecked Sendable {
    let value: T
}
