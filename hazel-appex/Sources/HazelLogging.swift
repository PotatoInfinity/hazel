// HazelLogging.swift
//
// Ported from Phosphene (MIT License, Copyright (c) 2026 kageroumado).
// Minimal file logging for the extension. The appex sandbox maps the home
// directory to its own container, so these logs land in
// ~/Library/Containers/com.live.hazel.wallpaper-extension/Data/Documents/.

import Foundation
import os

private let maxLogSize: UInt64 = 1_024 * 1_024

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
            try? FileManager.default.removeItem(at: hazelLogURL)
            FileManager.default.createFile(atPath: hazelLogURL.path, contents: nil)
            handle = try? FileHandle(forWritingTo: hazelLogURL)
        }
        guard let current = handle else { return }
        current.write(data)
    }
}
