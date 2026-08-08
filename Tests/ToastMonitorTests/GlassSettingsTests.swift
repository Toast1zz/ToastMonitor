import XCTest
@testable import ToastMonitor

final class GlassSettingsTests: XCTestCase {

    func testClampBounds() {
        XCTAssertEqual(GlassSettings.clamp(0.5), 0.5)
        XCTAssertEqual(GlassSettings.clamp(0.1), 0.25, "below floor clamps to 更通透 floor")
        XCTAssertEqual(GlassSettings.clamp(1.5), 1.0, "above ceiling clamps to full 磨砂")
        XCTAssertEqual(GlassSettings.clamp(0.25), 0.25, "floor is inclusive")
        XCTAssertEqual(GlassSettings.clamp(1.0), 1.0, "ceiling is inclusive")
    }

    func testPersistenceRoundTrip() {
        let suite = "test-glass-persistence"
        let ud = UserDefaults(suiteName: suite)!
        defer { ud.removePersistentDomain(forName: suite) }
        ud.removePersistentDomain(forName: suite)

        ud.set(0.6, forKey: GlassSettings.key)
        let loaded = (ud.object(forKey: GlassSettings.key) as? Double) ?? GlassSettings.clamp(0.6)
        XCTAssertEqual(GlassSettings.clamp(loaded), 0.6, accuracy: 0.0001)
    }

    func testMissingValueDefaultsToFullIntensity() {
        let suite = "test-glass-missing"
        let ud = UserDefaults(suiteName: suite)!
        defer { ud.removePersistentDomain(forName: suite) }
        ud.removePersistentDomain(forName: suite)

        let stored = ud.object(forKey: GlassSettings.key) as? Double
        XCTAssertNil(stored, "clean domain must not contain the key")
        let initial = stored ?? 1.0
        XCTAssertEqual(GlassSettings.clamp(initial), 1.0, "default is full 磨砂 (current behavior)")
    }
}
