import XCTest
@testable import ToastMonitor

final class PopoverHeatmapTests: XCTestCase {
    func testOneHugeDayDoesNotFlattenTheRest() {
        // Linear share of the peak put every ordinary day in the lowest shade.
        let days: [Int64] = [1, 2, 3, 4, 5, 6, 7, 8, 9_000]
        let cuts = PopoverHeatmap.thresholds(days)
        let levels = days.map { PopoverHeatmap.level($0, thresholds: cuts) }
        XCTAssertEqual(Set(levels), [1, 2, 3, 4])
        XCTAssertEqual(levels.first, 1)
        XCTAssertEqual(levels.last, 4)
    }

    func testEmptyDayIsLevelZero() {
        let cuts = PopoverHeatmap.thresholds([0, 10, 20])
        XCTAssertEqual(PopoverHeatmap.level(0, thresholds: cuts), 0)
        XCTAssertGreaterThan(PopoverHeatmap.level(10, thresholds: cuts), 0)
    }

    func testNoActivityHasNoThresholds() {
        XCTAssertEqual(PopoverHeatmap.thresholds([0, 0]), [])
        XCTAssertEqual(PopoverHeatmap.level(5, thresholds: []), 1)
    }

    func testLevelsRiseWithUsage() {
        let days: [Int64] = (1...40).map { Int64($0 * $0) }
        let cuts = PopoverHeatmap.thresholds(days)
        let levels = days.map { PopoverHeatmap.level($0, thresholds: cuts) }
        XCTAssertEqual(levels, levels.sorted())
    }
}
