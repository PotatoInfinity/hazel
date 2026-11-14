import XCTest
@testable import hazel

/// Hermetic coverage for `WallpaperStore.validatedURL`.
///
/// Uses a fresh `WallpaperStore(runMaintenance: false)` so no background
/// migration/repair touches the real Library, and all fixtures live under a
/// per-test tmp dir. Only reads the real library JSON/UserDefaults (via
/// `load()`); never calls `save()`/`add`/`remove`.
@MainActor
final class WallpaperStoreValidationTests: XCTestCase {
    private var tmpDir: URL!
    private var store: WallpaperStore!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hazelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        store = WallpaperStore(runMaintenance: false)
    }

    override func tearDown() async throws {
        if let tmpDir {
            try? FileManager.default.removeItem(at: tmpDir)
        }
        tmpDir = nil
        store = nil
        try await super.tearDown()
    }

    func testMissingFileReturnsNil() {
        let missing = tmpDir.appendingPathComponent("does-not-exist-\(UUID().uuidString).mp4")
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        XCTAssertNil(store.validatedURL(missing))
    }

    func testZeroByteFileReturnsNil() throws {
        let empty = tmpDir.appendingPathComponent("empty.mp4")
        try Data().write(to: empty)
        XCTAssertNil(store.validatedURL(empty))
    }

    func testDirectoryReturnsNil() throws {
        let dir = tmpDir.appendingPathComponent("asubdir", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
        XCTAssertNil(store.validatedURL(dir))
    }

    func testValidNonEmptyFileReturnsURL() throws {
        let good = tmpDir.appendingPathComponent("clip.mp4")
        try Data([0x00, 0x01, 0x02, 0x03]).write(to: good)
        XCTAssertEqual(store.validatedURL(good), good)
    }
}
