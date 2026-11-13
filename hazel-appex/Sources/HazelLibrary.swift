// HazelLibrary.swift
//
// Ported from Phosphene's VideoLibrary.swift + PrefsSource.swift
// (MIT License, Copyright (c) 2026 kageroumado). Simplified: single-video
// library driven by library.json, prefs driven by hazel-prefs.json.
//
// Container bridge contract (extension container Documents):
//   videos/<id>/wallpaper.mov
//   library.json  { "wallpapers": [{ "id": "...", "title": "...",
//                                   "videoFilename": "wallpaper.mov" }] }
//   hazel-prefs.json { "alwaysPauseDesktop": true }
// Darwin signals (posted by the app):
//   "com.live.hazel.wallpaper.library-changed"
//   "com.live.hazel.wallpaper.prefs-changed"

import Foundation
import Darwin
import os

// MARK: - Library

struct HazelWallpaperEntry: Codable {
    var id: String
    var title: String
    var videoFilename: String
}

private struct HazelLibraryFile: Codable {
    var wallpapers: [HazelWallpaperEntry]
}

final class HazelLibrary: Sendable {
    static let shared = HazelLibrary()

    private let docsDir: URL
    private let videosDir: URL
    private let indexURL: URL
    private let lock = OSAllocatedUnfairLock(initialState: [HazelWallpaperEntry]())

    static let libraryChangedSignal = "com.live.hazel.wallpaper.library-changed"

    private init() {
        // Primary home: inside this sandbox it resolves to our own container.
        var docs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents")
        // Fallback: POSIX home can differ if the host remaps the sandbox home.
        // Probe (never write through) the real user's container path instead.
        if !FileManager.default.fileExists(atPath: docs.appendingPathComponent("library.json").path),
           let pwDir = HazelLibrary.posixHome() {
            let alt = pwDir
                .appendingPathComponent("Library/Containers/com.live.hazel.wallpaper-extension/Data/Documents")
            if FileManager.default.fileExists(atPath: alt.appendingPathComponent("library.json").path) {
                docs = alt
            }
        }
        self.docsDir = docs
        self.videosDir = docs.appendingPathComponent("videos")
        self.indexURL = docs.appendingPathComponent("library.json")
        try? FileManager.default.createDirectory(at: videosDir, withIntermediateDirectories: true)
    }

    private static func posixHome() -> URL? {
        guard let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir else { return nil }
        let path = String(cString: dir)
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    var entries: [HazelWallpaperEntry] {
        lock.withLock { $0 }
    }

    func entry(for id: String) -> HazelWallpaperEntry? {
        lock.withLock { $0.first { $0.id == id } }
    }

    /// URL of the staged video for an entry. Only a plain basename is honored;
    /// anything else is rejected so a corrupt library.json cannot steer us
    /// outside videos/<id>/.
    func videoURL(for entry: HazelWallpaperEntry) -> URL? {
        let name = entry.videoFilename
        guard !name.isEmpty, !name.contains("/"), !name.contains("\\"), name != ".", name != ".." else {
            return nil
        }
        return videosDir.appendingPathComponent(entry.id).appendingPathComponent(name)
    }

    /// A staged file counts as usable only if it exists AND has nonzero size.
    /// A zero-byte file is a mid-copy stage (writer created the path but has
    /// not flushed bytes yet) — treating it as valid leads CREATE down the
    /// throw-before-seed path, which used to reply an empty (black) context.
    static func isUsableVideoFile(at url: URL) -> Bool {
        let path = url.path
        guard FileManager.default.fileExists(atPath: path) else { return false }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? UInt64, size > 0 else {
            return false
        }
        return true
    }

    /// Nonzero file size, or nil when the file is missing/unreadable.
    /// Logged at the call site so each failure mode is distinguishable.
    static func fileSize(at url: URL) -> UInt64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? UInt64 else {
            return nil
        }
        return size
    }

    func videoURL(for id: String) -> URL? {
        guard let entry = entry(for: id) else { return nil }
        return videoURL(for: entry)
    }

    /// The single video to play: the chosen entry when it exists, else the
    /// first entry in the library. Files must exist with size>0; a zero-byte
    /// mid-copy stage is skipped (logged by the caller with fileSize).
    func videoURL(forChoice choice: String?) -> URL? {
        if let choice, let url = videoURL(for: choice) {
            if Self.isUsableVideoFile(at: url) { return url }
        }
        for entry in entries {
            if let url = videoURL(for: entry),
               Self.isUsableVideoFile(at: url) {
                return url
            }
        }
        return nil
    }

    /// Re-read library.json and drop entries whose video file is missing.
    /// Torn-read safe: a missing file / partial-JSON read keeps the
    /// last-known entries instead of clobbering to zero (which used to drive
    /// a lock-time CREATE down the gradient/no-video path while the staged
    /// file was actually mid-rename). Pruned-to-empty while we previously had
    /// entries (files mid-copy) also keeps last-known; an explicitly emptied
    /// library.json (zero wallpapers) is still honored.
    func scan() {
        guard let data = try? Data(contentsOf: indexURL) else {
            hazelLog("[Library] scan: index unreadable (torn atomic rewrite?) — keeping \(entries.count) known video(s)")
            return
        }
        guard let file = try? JSONDecoder().decode(HazelLibraryFile.self, from: data) else {
            hazelLog("[Library] scan: index decode failed (partial JSON?) — keeping \(entries.count) known video(s)")
            return
        }
        if file.wallpapers.isEmpty {
            let previous = entries
            lock.withLock { $0 = [] }
            if !previous.isEmpty { hazelLog("[Library] Scanned: library emptied by app (was \(previous.count))") }
            else { hazelLog("[Library] Scanned: 0 video(s)") }
            return
        }
        let fm = FileManager.default
        let pruned = file.wallpapers.filter { entry in
            guard !entry.id.isEmpty, !entry.id.contains("/") else { return false }
            guard let url = videoURL(for: entry) else { return false }
            return fm.fileExists(atPath: url.path)
        }
        if pruned.isEmpty {
            hazelLog("[Library] scan: \(file.wallpapers.count) entrie(s) but 0 files present (mid-copy?) — keeping \(entries.count) known video(s)")
            return
        }
        let result = pruned
        lock.withLock { $0 = result }
        hazelLog("[Library] Scanned: \(result.count) video(s)")
    }

    func startObserving() {
        scan()
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            nil,
            { _, _, _, _, _ in
                HazelLibrary.shared.scan()
                HazelSurfaceRegistry.shared.retargetToLibrary()
                hazelLog("[Library] library-changed signal received, re-scanned + retargeted")
            },
            Self.libraryChangedSignal as CFString,
            nil,
            .deliverImmediately,
        )
    }
}

// MARK: - Prefs

/// Playback prefs written by the Hazel app to hazel-prefs.json.
/// alwaysPauseDesktop == true: the wallpaper plays only on the lock screen
/// (presentationMode == locked) and in our own screensaver slot
/// (presentationMode == idle); on the desktop it holds a still frame.
struct HazelPrefs: Decodable, Equatable, Sendable {
    var alwaysPauseDesktop = true

    init(alwaysPauseDesktop: Bool = true) {
        self.alwaysPauseDesktop = alwaysPauseDesktop
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        alwaysPauseDesktop = try container.decodeIfPresent(Bool.self, forKey: .alwaysPauseDesktop) ?? true
    }

    private enum CodingKeys: String, CodingKey {
        case alwaysPauseDesktop
    }
}

enum HazelPrefsSource {
    static let prefsChangedSignal = "com.live.hazel.wallpaper.prefs-changed"

    private static var prefsURL: URL {
        let primary = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/hazel-prefs.json")
        if FileManager.default.fileExists(atPath: primary.path) { return primary }
        // Same sandbox-home remap probe as HazelLibrary: never write through,
        // just read the real container path when the primary is absent.
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            let path = String(cString: dir)
            if !path.isEmpty {
                let alt = URL(fileURLWithPath: path, isDirectory: true)
                    .appendingPathComponent("Library/Containers/com.live.hazel.wallpaper-extension/Data/Documents/hazel-prefs.json")
                if FileManager.default.fileExists(atPath: alt.path) { return alt }
            }
        }
        return primary
    }

    private static let lock = OSAllocatedUnfairLock(initialState: HazelPrefs())

    static var current: HazelPrefs {
        lock.withLock { $0 }
    }

    static func start() {
        postCurrent()
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            nil,
            { _, _, _, _, _ in HazelPrefsSource.postCurrent() },
            prefsChangedSignal as CFString,
            nil,
            .deliverImmediately,
        )
    }

    /// Re-read prefs and re-target every live surface.
    /// Atomic-replace window: if the file is momentarily missing mid-write
    /// (or holds partial JSON), the read/decode fails and we KEEP the
    /// last-known prefs — failing toward playing on locked/idle (which play
    /// under either prefs value) rather than toward black.
    private static func postCurrent() {
        if let data = try? Data(contentsOf: prefsURL),
           let prefs = try? JSONDecoder().decode(HazelPrefs.self, from: data) {
            let changed = prefs != lock.withLock({ $0 })
            lock.withLock { $0 = prefs }
            hazelLog("[Prefs] Loaded: alwaysPauseDesktop=\(prefs.alwaysPauseDesktop)")
            if changed {
                hazelLog("[Prefs] policy changed — retargeting (locked/idle always PLAY)")
            }
        } else {
            // No prefs file yet (app hasn't staged one), or a torn read during
            // an atomic replace: keep the default/last-known, which plays on
            // locked/idle. Never pause locked for lack of prefs.
            hazelLog("[Prefs] No prefs file (or torn read), keeping alwaysPauseDesktop=\(current.alwaysPauseDesktop) — locked/idle still PLAY")
        }
        HazelSurfaceRegistry.shared.retargetAll()
    }
}
