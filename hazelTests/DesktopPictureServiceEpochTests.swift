import XCTest
@testable import hazel

/// Hermetic coverage for the `DesktopPictureService` epoch guard: only the
/// newest guarded generation may apply; stale extractions are discarded both
/// before the main-thread hop and at apply entry.
///
/// Uses `beginTestGeneration` (epoch bump only — no extraction, no AppKit, no
/// filesystem) plus `applyOnMainForTesting` with `syncSystemWallpaper = false`,
/// which returns before touching `NSScreen`/`NSWorkspace`. Touched
/// UserDefaults keys are restored in `tearDown`.
@MainActor
final class DesktopPictureServiceEpochTests: XCTestCase {
    private var hadSync = false
    private var savedSync = true

    override func setUp() async throws {
        try await super.setUp()
        let defaults = UserDefaults.standard
        hadSync = defaults.object(forKey: "syncSystemWallpaper") != nil
        savedSync = defaults.bool(forKey: "syncSystemWallpaper")
        defaults.set(false, forKey: "syncSystemWallpaper")
    }

    override func tearDown() async throws {
        if hadSync {
            UserDefaults.standard.set(savedSync, forKey: "syncSystemWallpaper")
        } else {
            UserDefaults.standard.removeObject(forKey: "syncSystemWallpaper")
        }
        try await super.tearDown()
    }

    func testNewerGenerationSupersedesOlder() {
        let svc = DesktopPictureService.shared
        let idA = UUID()
        let idB = UUID()
        let gen1 = svc.beginTestGeneration(for: idA)
        let gen2 = svc.beginTestGeneration(for: idB)

        XCTAssertGreaterThan(gen2, gen1)
        XCTAssertTrue(svc.isCurrentGenerationForTesting(gen2))
        XCTAssertFalse(svc.isCurrentGenerationForTesting(gen1))
        XCTAssertEqual(svc.generationForTesting, gen2)
    }

    func testStaleApplyIsDiscardedWithoutSideEffects() {
        let svc = DesktopPictureService.shared
        let staleID = UUID()
        let currentID = UUID()
        let staleGen = svc.beginTestGeneration(for: staleID)
        let currentGen = svc.beginTestGeneration(for: currentID)
        let appliedBefore = svc.appliedGenerationForTesting

        let still = FileManager.default.temporaryDirectory
            .appendingPathComponent("stale-\(UUID().uuidString).jpg")
        // Stale generation: must return at the epoch guard, never reaching
        // the sync check, screens, or appliedGeneration.
        svc.applyOnMainForTesting(still: still, generation: staleGen, wallpaperID: staleID)

        XCTAssertFalse(svc.isCurrentGenerationForTesting(staleGen))
        XCTAssertTrue(svc.isCurrentGenerationForTesting(currentGen))
        XCTAssertEqual(svc.appliedGenerationForTesting, appliedBefore)
    }
}
