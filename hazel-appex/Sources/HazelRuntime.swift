// HazelRuntime.swift
//
// Ported from Phosphene's RuntimeHelpers.swift, SnapshotCreation.swift and
// WallpaperIDProbe.swift (MIT License, Copyright (c) 2026 kageroumado).
// Runtime bridging to WallpaperExtensionKit XPC classes + snapshot stills.

import AVFoundation
import CoreMedia
import Foundation
@preconcurrency import IOSurface

// MARK: - Remote context / snapshot XPC construction

/// Construct a WallpaperRemoteContextXPC wrapping the given CAContext ID.
/// The real class has a `box` ivar (or offset 8 fallback) containing a
/// WallpaperExtensionRemoteContext with a single UInt32 remoteContextID.
func hazelCreateRemoteContextXPC(contextId: UInt32) -> AnyObject? {
    guard let realClass = objc_getClass("WallpaperRemoteContextXPC") as? AnyClass,
          let raw = class_createInstance(realClass, 0) else {
        hazelLog("  ERROR: Could not create WallpaperRemoteContextXPC")
        return nil
    }
    let obj = raw as AnyObject
    let ptr = Unmanaged.passUnretained(obj).toOpaque()
    let ivarOffset: Int = if let ivar = class_getInstanceVariable(realClass, "box") {
        ivar_getOffset(ivar)
    } else {
        8
    }
    // Bounds-check before the raw write: if the runtime layout shrank or the
    // offset assumption is stale, writing past the instance would corrupt the
    // heap. Fail closed instead.
    guard ivarOffset >= 0,
          ivarOffset + MemoryLayout<UInt32>.size <= class_getInstanceSize(realClass) else {
        hazelLog("  ERROR: WallpaperRemoteContextXPC layout unexpected")
        return nil
    }
    ptr.advanced(by: ivarOffset).storeBytes(of: contextId, as: UInt32.self)
    return obj
}

/// Construct a WallpaperSnapshotXPC wrapping the given IOSurface.
/// The real class has a single `rawValue` ivar at offset 8 containing a
/// WallpaperSnapshot struct (8 bytes = IOSurface refcounted pointer).
func hazelCreateSnapshotXPC(surface: IOSurface) -> AnyObject? {
    guard let snapshotXPCClass = objc_getClass("WallpaperSnapshotXPC") as? AnyClass,
          let instance = class_createInstance(snapshotXPCClass, 0) else {
        hazelLog("  [Snapshot] Failed to create WallpaperSnapshotXPC")
        return nil
    }
    let snapshotOffset = 8
    guard snapshotOffset + MemoryLayout<UnsafeRawPointer>.size <= class_getInstanceSize(snapshotXPCClass) else {
        hazelLog("  [Snapshot] WallpaperSnapshotXPC layout unexpected")
        return nil
    }
    HazelSnapshotSurfaces.keepAlive(surface)
    let surfaceRef = Unmanaged.passUnretained(surface).toOpaque()
    let instancePtr = Unmanaged.passUnretained(instance as AnyObject).toOpaque()
    instancePtr.advanced(by: snapshotOffset).storeBytes(of: surfaceRef, as: UnsafeRawPointer.self)
    return instance as AnyObject
}

/// Bounded registry of IOSurfaces handed to WallpaperSnapshotXPC. The XPC
/// object stores a raw pointer with no documented ownership, so surfaces are
/// kept alive here (capped, oldest evicted) instead of leaking one ref per
/// snapshot with no upper bound.
private enum HazelSnapshotSurfaces {
    private static var live: [IOSurface] = []
    private static let lock = NSLock()
    private static let cap = 4

    static func keepAlive(_ surface: IOSurface) {
        lock.lock()
        live.append(surface)
        while live.count > cap { live.removeFirst() }
        lock.unlock()
    }
}

// MARK: - WallpaperID / request introspection

/// The `WallpaperID` UUID inside a WallpaperIDXPC (`box.rawValue.id`), or nil.
/// Returns the first UUID found in the Mirror tree.
func hazelExtractWallpaperUUID(fromID id: Any?) -> UUID? {
    guard let id else { return nil }
    return hazelSearchUUID(id, depth: 0)
}

private func hazelSearchUUID(_ value: Any, depth: Int) -> UUID? {
    guard depth < 8 else { return nil }
    if let u = value as? UUID { return u }
    for child in Mirror(reflecting: value).children {
        if let found = hazelSearchUUID(child.value, depth: depth + 1) { return found }
    }
    return nil
}

/// Recursively search a value's Mirror for a stored property with the given
/// label, to a shallow depth. Robust to the XPC wrapper nesting, unlike
/// scanning a stringified description.
func hazelMirrorFindProperty(_ label: String, in value: Any, depth: Int = 0) -> Any? {
    guard depth < 6 else { return nil }
    for child in Mirror(reflecting: value).children {
        if child.label == label { return child.value }
        if let found = hazelMirrorFindProperty(label, in: child.value, depth: depth + 1) {
            return found
        }
    }
    return nil
}

/// Extract an enum case name from a value: `.idle` -> `"idle"`,
/// `.suspended(reason)` -> `"suspended"`.
func hazelEnumCaseName(_ value: Any) -> String {
    let mirror = Mirror(reflecting: value)
    if mirror.displayStyle == .enum, let label = mirror.children.first?.label {
        return label
    }
    return String(describing: value)
}

/// Read presentationMode / activityState case names from an update request via
/// Mirror. Unreadable fields read as the benign desktop-active value.
func hazelReadPresentation(request: Any?) -> (mode: HazelPresentationMode, activity: HazelActivityState) {
    var mode = HazelPresentationMode.default
    var activity = HazelActivityState.active
    if let request {
        if let value = hazelMirrorFindProperty("presentationMode", in: request) {
            mode = HazelPresentationMode(caseName: hazelEnumCaseName(value))
        }
        if let value = hazelMirrorFindProperty("activityState", in: request) {
            activity = HazelActivityState(caseName: hazelEnumCaseName(value))
        }
    }
    return (mode, activity)
}

/// Extract the wallpaper choice: the raw wallpaperID, written by the app as
/// UTF-8 bytes in the descriptor's `configuration`.
/// Path: WallpaperCreationRequestXPC.rawValue.descriptor.{configuration, files}.
func hazelExtractChoice(fromRequest request: Any?) -> (choice: String?, files: [URL]) {
    var choice: String?
    var files: [URL] = []
    guard let reqObj = request as? NSObject else { return (nil, []) }
    let mirror = Mirror(reflecting: reqObj)
    if let rawValue = mirror.children.first?.value {
        let rawMirror = Mirror(reflecting: rawValue)
        for prop in rawMirror.children where prop.label == "descriptor" {
            for descProp in Mirror(reflecting: prop.value).children {
                if descProp.label == "configuration" {
                    if let data = descProp.value as? Data, !data.isEmpty {
                        choice = String(data: data, encoding: .utf8)
                    }
                } else if descProp.label == "files" {
                    if let urls = descProp.value as? [URL] { files = urls }
                }
            }
        }
    }
    return (choice, files)
}

/// Extract destination size / scale / preview flag / display id from an acquire request.
func hazelExtractDestination(fromRequest request: Any?) -> (destSize: CGSize, scale: CGFloat, isPreview: Bool, displayID: UInt32?) {
    var destSize = CGSize(width: 2_560, height: 1_440)
    var scale: CGFloat = 2.0
    var isPreview = false
    var displayID: UInt32?
    guard let reqObj = request as? NSObject else { return (destSize, scale, isPreview, displayID) }
    let mirror = Mirror(reflecting: reqObj)
    for child in mirror.children {
        let reqMirror = Mirror(reflecting: child.value)
        for prop in reqMirror.children {
            if prop.label == "isPreview", let preview = prop.value as? Bool {
                isPreview = preview
            } else if prop.label == "directDisplayID" {
                if let id = prop.value as? UInt32 { displayID = id }
                else if let id = prop.value as? Int, id >= 0 { displayID = UInt32(id) }
            } else if prop.label == "destination" {
                for destProp in Mirror(reflecting: prop.value).children {
                    if destProp.label == "size", let size = destProp.value as? CGSize {
                        destSize = size
                    } else if destProp.label == "scaleFactor", let sf = destProp.value as? CGFloat {
                        scale = sf
                    } else if destProp.label == "directDisplayID" {
                        if let id = destProp.value as? UInt32 { displayID = id }
                        else if let id = destProp.value as? Int, id >= 0 { displayID = UInt32(id) }
                    }
                }
            }
        }
    }
    return (destSize, scale, isPreview, displayID)
}

// MARK: - Snapshot

enum HazelSnapshot {
    /// First-frame CGImage of a video, for the cold-start still seed.
    static func firstFrameImage(videoURL: URL) async -> CGImage? {
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        return try? await generator.image(at: .zero).image
    }

    /// Create a WallpaperSnapshotXPC containing an IOSurface with a video
    /// frame. Prefers the live renderer's timebase position; falls back to a
    /// random time within the duration so the picker doesn't always see frame 0.
    static func createSnapshotViaRuntime(videoURL: URL?, currentTime: CMTime? = nil) async -> AnyObject? {
        guard let videoURL else {
            hazelLog("  [Snapshot] No video file found")
            return nil
        }
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true

        let requestTime: CMTime
        if let currentTime, currentTime.isValid, currentTime.seconds > 0 {
            requestTime = currentTime
        } else if let duration = try? await asset.load(.duration),
                  duration.isValid, duration.seconds > 0 {
            let offset = Double.random(in: 0 ..< duration.seconds)
            requestTime = CMTime(seconds: offset, preferredTimescale: duration.timescale)
        } else {
            requestTime = .zero
        }

        let image: CGImage
        do {
            image = try await generator.image(at: requestTime).image
        } catch {
            hazelLog("  [Snapshot] Failed to get video frame: \(error)")
            return nil
        }
        return renderToIOSurface(image: downscaled(image, maxWidth: 1920))
    }

    /// Downscale snapshots bound for the login screen: a 4K frame costs 4x
    /// the IOSurface memory for pixels nobody can see on the login window.
    private static func downscaled(_ image: CGImage, maxWidth: Int) -> CGImage {
        guard image.width > maxWidth else { return image }
        let scale = Double(maxWidth) / Double(image.width)
        let w = maxWidth
        let h = max(1, Int(Double(image.height) * scale))
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
            return image
        }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }

    /// Render a CGImage to an IOSurface and wrap it in a WallpaperSnapshotXPC.
    /// Synchronous to avoid async Sendable constraints on IOSurface's
    /// `[Key: Any]` dictionary.
    static func renderToIOSurface(image: CGImage) -> AnyObject? {
        let width = image.width
        let height = image.height
        let surfaceProps: [IOSurfacePropertyKey: any Sendable] = [
            .width: width,
            .height: height,
            .bytesPerElement: 4,
            .pixelFormat: 0x4247_5241, // 'BGRA'
        ]
        guard let surface = IOSurface(properties: surfaceProps) else {
            hazelLog("  [Snapshot] Failed to create IOSurface")
            return nil
        }
        surface.lock(options: [], seed: nil)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        if let ctx = CGContext(
            data: surface.baseAddress,
            width: width, height: height,
            bitsPerComponent: 8,
            bytesPerRow: surface.bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue,
        ) {
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        } else {
            hazelLog("  [Snapshot] Failed to create CGContext for IOSurface")
            surface.unlock(options: [], seed: nil)
            return nil
        }
        surface.unlock(options: [], seed: nil)
        return hazelCreateSnapshotXPC(surface: surface)
    }
}
