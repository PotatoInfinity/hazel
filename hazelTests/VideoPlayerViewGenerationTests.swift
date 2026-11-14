import XCTest
import AppKit
@testable import hazel

/// Hermetic coverage for the `VideoPlayerView` generation guard: rapid
/// switches must leave only the newest request pending; a stale (superseded)
/// async callback must never win.
///
/// Uses empty tmp files (never valid video, never the real library), so no
/// swap to "current" happens synchronously and assertions are deterministic.
/// Runs `@MainActor` because `NSView`/player layers are main-thread bound.
@MainActor
final class VideoPlayerViewGenerationTests: XCTestCase {
    private var tmpDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hazelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tmpDir {
            try? FileManager.default.removeItem(at: tmpDir)
        }
        tmpDir = nil
        try await super.tearDown()
    }

    private func tmpFile(named name: String) throws -> URL {
        let url = tmpDir.appendingPathComponent(name)
        try Data([0x00, 0x01]).write(to: url)
        return url
    }

    func testRapidSwitchKeepsOnlyNewestPending() throws {
        let view = VideoPlayerView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        defer { view.cleanup() }
        let urlA = try tmpFile(named: "a.mp4")
        let urlB = try tmpFile(named: "b.mp4")

        XCTAssertEqual(view.generationForTesting, 0)
        view.loadVideo(url: urlA)
        XCTAssertEqual(view.generationForTesting, 1)
        XCTAssertEqual(view.pendingURLForTesting, urlA)

        // Rapid supersede: the first pending pipeline must be disposed and
        // replaced, never promoted later (stale ids fail the guard).
        view.loadVideo(url: urlB)
        XCTAssertEqual(view.generationForTesting, 2)
        XCTAssertEqual(view.pendingURLForTesting, urlB)
        XCTAssertNil(view.currentURLForTesting)
    }

    func testCleanupInvalidatesPendingGeneration() throws {
        let view = VideoPlayerView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        let urlA = try tmpFile(named: "a.mp4")
        view.loadVideo(url: urlA)
        XCTAssertNotNil(view.pendingURLForTesting)
        let genBefore = view.generationForTesting

        view.cleanup()
        XCTAssertNil(view.pendingURLForTesting)
        XCTAssertNil(view.currentURLForTesting)
        XCTAssertGreaterThan(view.generationForTesting, genBefore)
    }

    func testRapidABASwitchKeepsOnlyNewestPending() throws {
        let view = VideoPlayerView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        defer { view.cleanup() }
        let urlA = try tmpFile(named: "a.mp4")
        let urlB = try tmpFile(named: "b.mp4")

        // A -> B -> A: each kick supersedes the last; exactly one pending
        // (the newest) may survive, never a stale promotion.
        view.loadVideo(url: urlA)
        view.loadVideo(url: urlB)
        view.loadVideo(url: urlA)
        XCTAssertEqual(view.generationForTesting, 3)
        XCTAssertEqual(view.pendingURLForTesting, urlA)
        XCTAssertNil(view.currentURLForTesting)
    }
}
