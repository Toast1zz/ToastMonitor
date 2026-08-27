import XCTest
@testable import ToastMonitor

final class QuotaAlertTests: XCTestCase {
    func testLowQuotaOnlyFiresWhenCrossingIntoCriticalState() {
        XCTAssertEqual(QuotaAlertPolicy.transition(previous: nil, remaining: 20, threshold: 20), .low)
        XCTAssertNil(QuotaAlertPolicy.transition(previous: "low", remaining: 10, threshold: 20))
        XCTAssertNil(QuotaAlertPolicy.transition(previous: "ok", remaining: 50, threshold: 20))
    }

    func testQuotaRecoveryFiresAfterCriticalState() {
        XCTAssertEqual(QuotaAlertPolicy.transition(previous: "low", remaining: 21, threshold: 20), .recovered)
        XCTAssertNil(QuotaAlertPolicy.transition(previous: nil, remaining: 100, threshold: 20))
    }
}
