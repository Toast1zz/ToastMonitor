import XCTest
@testable import ToastMonitor

final class QuotaWindowTests: XCTestCase {
    private let window = QuotaWindow(label: "5h", usedPercent: 80, resetIn: nil, elapsed: 0.25)

    func testUsedModeShowsUsage() {
        XCTAssertEqual(QuotaWindow.shownPercent(used: 80, showsRemaining: false), 80)
    }

    func testRemainingModeShowsWhatIsLeft() {
        XCTAssertEqual(QuotaWindow.shownPercent(used: 80, showsRemaining: true), 20)
    }

    func testRemainingModeAtBothEnds() {
        XCTAssertEqual(QuotaWindow.shownPercent(used: 0, showsRemaining: true), 100)
        XCTAssertEqual(QuotaWindow.shownPercent(used: 100, showsRemaining: true), 0)
    }

    func testOnlyUsedModeComparesAgainstTime() {
        XCTAssertEqual(window.barElapsed(showsRemaining: false), 0.25)
        XCTAssertNil(window.barElapsed(showsRemaining: true))
    }
}
