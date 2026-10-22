import XCTest
@testable import ToastMonitor

final class SourceBarTests: XCTestCase {
    private func assertFills(_ widths: [CGFloat], _ width: CGFloat, file: StaticString = #filePath, line: UInt = #line) {
        let used = widths.reduce(0, +) + SourceBar.gap * CGFloat(max(widths.count - 1, 0))
        XCTAssertEqual(used, width, accuracy: 0.001, file: file, line: line)
    }

    func testSplitsProportionallyAroundGaps() {
        let widths = SourceBar.widths(for: [3, 1], in: 202)
        XCTAssertEqual(widths[0], 150, accuracy: 0.001)
        XCTAssertEqual(widths[1], 50, accuracy: 0.001)
        assertFills(widths, 202)
    }

    func testTinyShareStaysVisibleAndBarStillFills() {
        let widths = SourceBar.widths(for: [999, 1], in: 300)
        XCTAssertEqual(widths[1], SourceBar.minSegment, accuracy: 0.001)
        assertFills(widths, 300)
    }

    func testSingleSourceTakesFullWidth() {
        XCTAssertEqual(SourceBar.widths(for: [42], in: 300), [300])
    }

    func testNoValuesOrZeroTotalDrawsNothing() {
        XCTAssertEqual(SourceBar.widths(for: [], in: 300), [])
        XCTAssertEqual(SourceBar.widths(for: [0, 0], in: 300), [])
    }

    func testNarrowWidthNeverGoesNegative() {
        let widths = SourceBar.widths(for: [5, 1, 1, 1], in: 10)
        XCTAssertTrue(widths.allSatisfy { $0 >= 0 })
        assertFills(widths, 10)
    }
}
