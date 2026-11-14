import XCTest
@testable import hazel

/// Hermetic coverage for `WallpaperController.abortInvalidItem` via its only
/// public triggers (`setWallpaper` / `reloadCurrentWallpaper` with a dead
/// file). Asserts the documented cleanup contract: no windows, not active,
/// dead active-pointer cleared.
///
/// Hermeticity: tmp-dir URLs only; `syncSystemWallpaper = false` so the abort
/// path (which returns before any sync/reconcile call) performs no AppKit or
/// filesystem work; `cycleMode = .none` so `init` arms no timers; all touched
/// UserDefaults keys are snapshotted and restored.
@MainActor
final class WallpaperControllerAbortTests: XCTestCase {
    private var savedActiveID: Any?
    private var hadActiveID = false
    private var savedCycleMode: String?
    private var savedSync: Bool = true
    private var hadSync = false
    private var savedLastCycle: Any?
    private var hadLastCycle = false

    override func setUp() async throws {
        try await super.setUp()
        let defaults = UserDefaults.standard
        hadActiveID = defaults.object(forKey: "activeWallpaperID") != nil
        savedActiveID = defaults.object(forKey: "activeWallpaperID")
        savedCycleMode = defaults.string(forKey: "cycleMode")
        hadSync = defaults.object(forKey: "syncSystemWallpaper") != nil
        savedSync = defaults.bool(forKey: "syncSystemWallpaper")
        hadLastCycle = defaults.object(forKey: "lastCycleDate") != nil
        savedLastCycle = defaults.object(forKey: "lastCycleDate")

        defaults.set(CycleMode.none.rawValue, forKey: "cycleMode")
        defaults.set(false, forKey: "syncSystemWallpaper")
        defaults.removeObject(forKey: "lastCycleDate")
    }

    override func tearDown() async throws {
        let defaults = UserDefaults.standard
        if hadActiveID, let v = savedActiveID {
            defaults.set(v, forKey: "activeWallpaperID")
        } else {
            defaults.removeObject(forKey: "activeWallpaperID")
        }
        if let m = savedCycleMode {
            defaults.set(m, forKey: "cycleMode")
        } else {
            defaults.removeObject(forKey: "cycleMode")
        }
        if hadSync {
            defaults.set(savedSync, forKey: "syncSystemWallpaper")
        } else {
            defaults.removeObject(forKey: "syncSystemWallpaper")
        }
        if hadLastCycle, let v = savedLastCycle {
            defaults.set(v, forKey: "lastCycleDate")
        } else {
            defaults.removeObject(forKey: "lastCycleDate")
        }
        try await super.tearDown()
    }

    private func deadItem() throws -> (WallpaperItem, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hazelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Note: tmp dir itself leaks only if the test fails before cleanup;
        // the item URL never exists, which is the point.
        let missing = dir.appendingPathComponent("missing.mp4")
        let item = WallpaperItem(url: missing, title: "missing-\(UUID().uuidString)")
        return (item, dir)
    }

    func testSetWallpaperWithMissingFileAbortsAndCleansUp() throws {
        let (item, dir) = try deadItem()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = WallpaperStore(runMaintenance: false)
        store.wallpapers = [item]
        store.activeWallpaperID = item.id

        let controller = WallpaperController(store: store)
        controller.setWallpaper(item)

        XCTAssertFalse(controller.isActive)
        XCTAssertEqual(controller.windowCountForTesting, 0)
        XCTAssertNil(store.activeWallpaperID)
        XCTAssertNil(controller.pendingObscuredItemForTesting)
    }

    func testReloadWithMissingFileAbortsAndCleansUp() throws {
        let (item, dir) = try deadItem()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = WallpaperStore(runMaintenance: false)
        store.wallpapers = [item]
        store.activeWallpaperID = item.id

        let controller = WallpaperController(store: store)
        controller.reloadCurrentWallpaper()

        XCTAssertFalse(controller.isActive)
        XCTAssertEqual(controller.windowCountForTesting, 0)
        XCTAssertNil(store.activeWallpaperID)
    }

    func testAbortLeavesForeignActivePointerAlone() throws {
        let (dead, dir) = try deadItem()
        defer { try? FileManager.default.removeItem(at: dir) }
        let other = WallpaperItem(
            url: FileManager.default.temporaryDirectory
                .appendingPathComponent("other-\(UUID().uuidString).mp4"),
            title: "other")
        let store = WallpaperStore(runMaintenance: false)
        store.wallpapers = [dead, other]
        // Pointer targets a *different* item: aborting `dead` must not clear it.
        store.activeWallpaperID = other.id

        let controller = WallpaperController(store: store)
        controller.setWallpaper(dead)

        XCTAssertFalse(controller.isActive)
        XCTAssertEqual(store.activeWallpaperID, other.id)
    }
}
