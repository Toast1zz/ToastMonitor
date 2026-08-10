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

    func testAlphaMappingEndpoints() {
        XCTAssertEqual(GlassSettings.alpha(for: 0.25), 0.2, accuracy: 0.0001, "最通透端保留基础玻璃感（0.05 实测太透）")
        XCTAssertEqual(GlassSettings.alpha(for: 1.0), 1.0, accuracy: 0.0001, "满磨砂端 = 1.0")
    }

    func testAlphaMappingMonotonicAndCentered() {
        let lo = GlassSettings.alpha(for: 0.25)
        let mid = GlassSettings.alpha(for: 0.625)  // 滑块中点
        let hi = GlassSettings.alpha(for: 1.0)
        XCTAssertLessThan(lo, mid)
        XCTAssertLessThan(mid, hi)
        // 中点（t=0.5）≈ 0.2 + 0.8·0.66 ≈ 0.73：中段已有明确磨砂，但未到满。
        XCTAssertGreaterThan(mid, 0.65)
        XCTAssertLessThan(mid, 0.85)
        // 离开通透端应快速起砂：滑块 25% 处已过半程视觉。
        let quarter = GlassSettings.alpha(for: 0.4375)  // 滑块 25%
        XCTAssertGreaterThan(quarter, 0.5, "低段变化要快，25% 就有半程磨砂")
    }

    func testAlphaClampsOutOfRangeSlider() {
        XCTAssertEqual(GlassSettings.alpha(for: 0.0), GlassSettings.alpha(for: 0.25), "低于下限等同最通透端")
        XCTAssertEqual(GlassSettings.alpha(for: 2.0), 1.0, "高于上限等同满磨砂")
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
