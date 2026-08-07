import XCTest
@testable import ToastMonitor

final class SubscriptionMathTests: XCTestCase {

    func testEndedSubscriptionAmortizesNothing() {
        let now = Date()
        let start = Int64(now.timeIntervalSince1970) - 40 * 86400  // 40 days ago
        let end = Int64(now.timeIntervalSince1970) - 10 * 86400   // ended 10 days ago
        let sub = Database.Subscription(id: 1, name: "X", plan: "",
                                        startDate: start, endDate: end,
                                        cycle: "monthly", price: 30, currency: "USD")
        XCTAssertEqual(SubscriptionMath.amortized(days: 1, subscriptions: [sub], now: now),
                       0, accuracy: 0.0001, "ended subscriptions contribute no amortization")
        XCTAssertNil(SubscriptionMath.cycleInfo(start: start, end: end, cycle: "monthly", now: now),
                     "ended subscriptions have no active cycle")
    }

    func testEndInsideCycleTruncatesWindow() {
        let now = Date()
        let start = Int64(now.timeIntervalSince1970) - 10 * 86400
        let end = Int64(now.timeIntervalSince1970) + 5 * 86400   // ends inside the first monthly window
        guard let info = SubscriptionMath.cycleInfo(start: start, end: end, cycle: "monthly", now: now) else {
            return XCTFail("expected an active cycle")
        }
        XCTAssertLessThanOrEqual(info.end.timeIntervalSince1970, Double(end),
                                 "cycle window must not extend past the end date")
        XCTAssertGreaterThan(info.totalDays, 0)
    }

    func testActiveSubscriptionWithoutEndDateUnchanged() {
        let now = Date()
        let start = Int64(now.timeIntervalSince1970) - 20 * 86400
        let sub = Database.Subscription(id: 2, name: "Y", plan: "",
                                        startDate: start, endDate: 0,
                                        cycle: "monthly", price: 30, currency: "USD")
        let amortized = SubscriptionMath.amortized(days: 7, subscriptions: [sub], now: now)
        XCTAssertGreaterThan(amortized, 0, "active subscription still amortizes")
        XCTAssertEqual(amortized, 30.0 / 30.0 * 7, accuracy: 0.5) // ~monthly window
    }
}
