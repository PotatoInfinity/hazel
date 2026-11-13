// HazelLogging.swift
//
// Ported from Phosphene (MIT License, Copyright (c) 2026 kageroumado).
// Minimal file logging for the extension. The appex sandbox maps the home
// directory to its own container, so these logs land in
// ~/Library/Containers/com.live.hazel.wallpaper-extension/Data/Documents/.

import Foundation
import os

private let maxLogSize: UInt64 = 100 * 1_024

/// Lines retained when the log rolls over. Bounded history instead of a full
/// wipe so post-mortem debugging survives the rollover.
private let maxLogLinesKept = 200

private let hazelLogURL: URL = {
    let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("hazel-extension.log")
}()

private let hazelLogLock = OSAllocatedUnfairLock(initialState: nil as FileHandle?)

func hazelLog(_ message: String) {
    hazelLogLock.withLock { handle in
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
        let data = Data(line.utf8)
        if handle == nil {
            FileManager.default.createFile(atPath: hazelLogURL.path, contents: nil)
            handle = try? FileHandle(forWritingTo: hazelLogURL)
            _ = try? handle?.seekToEnd()
        }
        if let current = handle, ((try? current.seekToEnd()) ?? 0) >= maxLogSize {
            try? current.close()
            hazelTrimLogFileLocked()
            handle = try? FileHandle(forWritingTo: hazelLogURL)
            _ = try? handle?.seekToEnd()
        }
        guard let current = handle else { return }
        current.write(data)
    }
}

/// Trim the log to the last `maxLogLinesKept` lines. Called with
/// `hazelLogLock` held, after the open handle is closed. Keeps the file
/// bounded at ~100KB without losing the most recent (most relevant) history.
private func hazelTrimLogFileLocked() {
    guard let data = try? Data(contentsOf: hazelLogURL), !data.isEmpty else {
        FileManager.default.createFile(atPath: hazelLogURL.path, contents: nil)
        return
    }
    let text = String(decoding: data, as: UTF8.self)
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    guard lines.count > maxLogLinesKept else {
        // Under the line budget but over the byte budget (e.g. very long
        // lines): drop the oldest half by bytes to guarantee shrinkage.
        let half = data.count / 2
        let trimmed = data.dropFirst(half)
        // Re-align to the next newline so we never keep a partial line.
        if let nl = trimmed.firstIndex(of: UInt8(ascii: "\n")) {
            try? trimmed[trimmed.index(after: nl)...].write(to: hazelLogURL)
        } else {
            try? Data().write(to: hazelLogURL)
        }
        return
    }
    let kept = lines.suffix(maxLogLinesKept).joined(separator: "\n")
    try? Data((kept + "\n").utf8).write(to: hazelLogURL)
}
