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
    func retargetToLibrary() {
        // Hop to the lifecycle queue; surfaces are owned there.
        HazelLifecycle.queue.async {
            let store = HazelSurfaceRegistry.shared
            store.lock.lock()
            let pairs = store.surfaces.map { ($0.key, $0.value) }
            store.lock.unlock()
            for (key, surface) in pairs {
                guard let url = HazelLibrary.shared.videoURL(forChoice: surface.videoID) else { continue }
                if let renderer = surface.renderer {
                    renderer.switchVideo(to: url)
                } else if store.claimRendererCreate(for: key) {
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
    }

    /// Recompute pause/play for every live surface from current mode + prefs.
    /// Called when hazel-prefs.json changes.
    func retargetAll() {
        // Hop to the lifecycle queue; surfaces are owned there.
        HazelLifecycle.queue.async {
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
    }

    func updateAll(mode: HazelPresentationMode, activity: HazelActivityState) {
        lock.lock()
        let all = Array(surfaces.values)
        lock.unlock()
        for surface in all {
            surface.mode = mode
            surface.activity = activity
            surface.renderer?.setPaused(!HazelPolicy.shouldPlay(
                mode: mode, activity: activity, prefs: HazelPrefsSource.current,
            ))
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

        let videoURL = HazelLibrary.shared.videoURL(forChoice: choice)
        let startPaused = !HazelPolicy.shouldPlay(
            mode: .default, activity: .active, prefs: HazelPrefsSource.current,
        )

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
                reply(nil, NSError(domain: "HazelWallpaperExtension", code: 3, userInfo: nil)); return
            }
            reply(replyObj, nil)
            if isPreview {
                // Settings preview: still only. Never start the decode loop here.
                return
            }
            if existing.videoID == choice, existing.renderer != nil { return }
            guard let videoURL else { return }
            if let renderer = existing.renderer {
                renderer.switchVideo(to: videoURL)
                registry.updateVideoID(choice, for: key)
            } else if registry.claimRendererCreate(for: key) {
                let boxedRoot = HazelSendableBox(value: existing.rootLayer)
                let boxedKey = HazelSendableBox(value: key)
                let boxedChoice = HazelSendableBox(value: choice)
                Task {
                    await HazelWallpaperHandler.attachRenderer(
                        rootLayer: boxedRoot.value, videoURL: videoURL,
                        key: boxedKey.value, choice: boxedChoice.value,
                        startPaused: HazelPolicy.shouldPlay(
                            mode: registry.surface(for: boxedKey.value)?.mode ?? .default,
                            activity: .active, prefs: HazelPrefsSource.current,
                        ) == false,
                    )
                }
            }
            return
        }

        // ---- CREATE: first acquire for this surface ----
        // NOTE: remoteContext + layer tree are built on the main thread. Core
        // Animation layer trees that cross into the WindowServer must be
        // created on the main thread; the lifecycle serial queue is a worker.
        let built: (CAContext, CALayer, UInt32)? = DispatchQueue.main.sync {
            guard let caContext = CAContext.remoteContext() as? CAContext, caContext.contextId != 0 else {
                return nil
            }
            let rootLayer = CALayer()
            rootLayer.frame = CGRect(origin: .zero, size: destSize)
            rootLayer.contentsScale = scale
            rootLayer.contentsGravity = .resizeAspectFill
            caContext.layer = rootLayer
            CATransaction.flush()
            return (caContext, rootLayer, caContext.contextId)
        }
        guard let (caContext, rootLayer, contextId) = built else {
            hazelLog("  ERROR: remote CAContext creation failed")
            reply(nil, NSError(domain: "HazelWallpaperExtension", code: 4,
                               userInfo: [NSLocalizedDescriptionKey: "Failed to create remote CAContext"]))
            return
        }

        guard let replyObj = hazelCreateRemoteContextXPC(contextId: contextId) else {
            reply(nil, NSError(domain: "HazelWallpaperExtension", code: 3, userInfo: nil)); return
        }

        let hosted = HazelHostedSurface(caContext: caContext, contextId: contextId,
                                        rootLayer: rootLayer, destSize: destSize, scale: scale)
        registry.install(hosted, for: key, wallpaperID: surfaceUUID)
        hazelLog("  Created context \(contextId) for \(key) at \(destSize) @\(scale)x")

        if isPreview {
            // Settings preview: seed a still and stop. No decode loop, no looper.
            seedPreviewStill(into: rootLayer, size: destSize, videoURL: videoURL, reply: reply, replyObj: replyObj)
            return
        }

        guard let videoURL else {
            // No video staged: solid fallback. Static, so ready at once.
            // Tracked as the placeholder so a later stage removes it.
            let gradient = CAGradientLayer()
            gradient.colors = [
                CGColor(red: 0.15, green: 0.1, blue: 0.25, alpha: 1.0),
                CGColor(red: 0.05, green: 0.1, blue: 0.2, alpha: 1.0),
            ]
            gradient.frame = CGRect(origin: .zero, size: destSize)
            CATransaction.begin(); CATransaction.setDisableActions(true)
            rootLayer.addSublayer(gradient)
            CATransaction.commit(); CATransaction.flush()
            hosted.placeholder = gradient
            reply(replyObj, nil)
            return
        }

        if registry.claimRendererCreate(for: key) {
            let boxedRoot = HazelSendableBox(value: rootLayer)
            let boxedReply = HazelSendableBox(value: replyObj)
            let boxedKey = HazelSendableBox(value: key)
            let boxedChoice = HazelSendableBox(value: choice)
            // Cold start: reply as soon as the still is seeded so the agent can
            // host our context without a black gap; the video plays over it.
            // Switch (re-acquire racing a live surface): covered by REUSE above.
            Task {
                do {
                    let renderer = try await HazelVideoRenderer.create(
                        rootLayer: boxedRoot.value, videoURL: videoURL,
                    )
                    let old = registry.setRenderer(renderer, videoID: boxedChoice.value, for: boxedKey.value)
                    old?.stop()
                    if let surface = registry.surface(for: boxedKey.value) {
                        surface.placeholder?.removeFromSuperlayer()
                        surface.placeholder = nil
                    }
                    if startPaused { renderer.setPaused(true) }
                    reply(boxedReply.value, nil)
                    await renderer.start()
                } catch {
                    hazelLog("  [Renderer] Failed to create: \(error)")
                    registry.clearRendererPending(for: key)
                    reply(boxedReply.value, nil)
                }
            }
        } else {
            reply(replyObj, nil)
        }
    }

    /// Seed a Settings preview surface with one still frame: no renderer, no
    /// loop, no audio pipeline. Cheap enough to rebuild on every preview open.
    private func seedPreviewStill(into rootLayer: CALayer, size: CGSize, videoURL: URL?,
                                  reply: @escaping @Sendable (Any?, (any Error)?) -> Void,
                                  replyObj: Any) {
        guard let videoURL else {
            reply(replyObj, nil)
            return
        }
        let boxedRoot = HazelSendableBox(value: rootLayer)
        let boxedReply = HazelSendableBox(value: replyObj)
        let boxedSize = HazelSendableBox(value: size)
        Task {
            let still = await HazelSnapshot.firstFrameImage(videoURL: videoURL)
            DispatchQueue.main.async {
                if let still {
                    boxedRoot.value.contents = still
                    boxedRoot.value.contentsGravity = .resizeAspectFill
                    boxedRoot.value.frame = CGRect(origin: .zero, size: boxedSize.value)
                }
                reply(boxedReply.value, nil)
            }
        }
    }

    /// Attach a renderer to an already-hosted surface (REUSE path with no
    /// renderer yet). Runs off the lifecycle queue.
    static func attachRenderer(rootLayer: CALayer, videoURL: URL, key: HazelSurfaceKey,
                                       choice: String?, startPaused: Bool) async {
        let registry = HazelSurfaceRegistry.shared
        do {
            let renderer = try await HazelVideoRenderer.create(rootLayer: rootLayer, videoURL: videoURL)
            let old = registry.setRenderer(renderer, videoID: choice, for: key)
            old?.stop()
            if let surface = registry.surface(for: key) {
                surface.placeholder?.removeFromSuperlayer()
                surface.placeholder = nil
            }
            if startPaused { renderer.setPaused(true) }
            await renderer.start()
        } catch {
            hazelLog("  [Renderer] attach failed: \(error)")
            registry.clearRendererPending(for: key)
        }
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
            surface.renderer?.setPaused(!HazelPolicy.shouldPlay(
                mode: mode, activity: activity, prefs: HazelPrefsSource.current,
            ))
            hazelLog("=== UPDATE === \(key) mode: \(mode), activity: \(activity)")
        } else {
            // Unknown or missing surface id: ignore. Fanning out to every
            // surface here caused unrelated desktops to freeze on stray updates.
            hazelLog("=== UPDATE === unknown surface id, ignoring (mode: \(mode))")
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
                reply(snapshotXPC, nil)
            } else {
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
