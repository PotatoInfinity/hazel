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

    func videoURL(for id: String) -> URL? {
        guard let entry = entry(for: id) else { return nil }
        return videoURL(for: entry)
    }

    /// The single video to play: the chosen entry when it exists, else the
    /// first entry in the library.
    func videoURL(forChoice choice: String?) -> URL? {
        if let choice, let url = videoURL(for: choice) {
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        for entry in entries {
            if let url = videoURL(for: entry),
               FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    /// Re-read library.json and drop entries whose video file is missing.
    func scan() {
        var loaded: [HazelWallpaperEntry] = []
        if let data = try? Data(contentsOf: indexURL),
           let file = try? JSONDecoder().decode(HazelLibraryFile.self, from: data) {
            loaded = file.wallpapers
        }
        let fm = FileManager.default
        let pruned = loaded.filter { entry in
            guard !entry.id.isEmpty, !entry.id.contains("/") else { return false }
            guard let url = videoURL(for: entry) else { return false }
            return fm.fileExists(atPath: url.path)
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
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/hazel-prefs.json")
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
    private static func postCurrent() {
        if let data = try? Data(contentsOf: prefsURL),
           let prefs = try? JSONDecoder().decode(HazelPrefs.self, from: data) {
            lock.withLock { $0 = prefs }
            hazelLog("[Prefs] Loaded: alwaysPauseDesktop=\(prefs.alwaysPauseDesktop)")
        } else {
            // No prefs file yet (app hasn't staged one): keep the default,
            // which is lock-screen-only playback.
            hazelLog("[Prefs] No prefs file, keeping alwaysPauseDesktop=\(current.alwaysPauseDesktop)")
        }
        HazelSurfaceRegistry.shared.retargetAll()
    }
}
