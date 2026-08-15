import XCTest
@testable import ToastMonitor

final class SubscriptionMathTests: XCTestCase {

    /// Fixed clock so cycle/amortization math is deterministic regardless of
    /// when the suite runs (2025-07-08T18:40Z; all windows land in
    /// June/July, which keeps day counts stable across time zones).
    private let now = Date(timeIntervalSince1970: 1_752_000_000)

    func testEndedSubscriptionAmortizesNothing() {
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
        let start = Int64(now.timeIntervalSince1970) - 10 * 86400
        let end = Int64(now.timeIntervalSince1970) + 5 * 86400   // ends inside the first monthly window
        guard let info = SubscriptionMath.cycleInfo(start: start, end: end, cycle: "monthly", now: now) else {
            return XCTFail("expected an active cycle")
        }
        XCTAssertLessThanOrEqual(info.end.timeIntervalSince1970, Double(end),
                                 "cycle window must not extend past the end date")
        XCTAssertEqual(info.totalDays, 15, "window truncated by end date: 10 days before + 5 after")
        XCTAssertEqual(info.dayOfCycle, 11, "10 days elapsed → 1-based day 11")
        XCTAssertEqual(info.progress, 10.0 / 15.0, accuracy: 0.001)
    }

    func testActiveSubscriptionWithoutEndDateUnchanged() {
        let start = Int64(now.timeIntervalSince1970) - 20 * 86400
        let sub = Database.Subscription(id: 2, name: "Y", plan: "",
                                        startDate: start, endDate: 0,
                                        cycle: "monthly", price: 30, currency: "USD")
        // June → July window is exactly 30 days, so daily = $1 and the
        // 7-day lookback amortizes exactly $7.
        let amortized = SubscriptionMath.amortized(days: 7, subscriptions: [sub], now: now)
        XCTAssertGreaterThan(amortized, 0, "active subscription still amortizes")
        XCTAssertEqual(amortized, 7.0, accuracy: 0.001, "30/30 per day over a 7-day window")
        guard let info = SubscriptionMath.cycleInfo(start: start, end: 0, cycle: "monthly", now: now) else {
            return XCTFail("expected an active cycle")
        }
        XCTAssertEqual(info.totalDays, 30)
        XCTAssertEqual(info.dayOfCycle, 21, "20 days elapsed → 1-based day 21")
        XCTAssertEqual(info.progress, 20.0 / 30.0, accuracy: 0.001)
    }

    /// Plans without a linked data source must degrade to no forecast rather
    /// than crashing or fabricating numbers. Unknown plan strings hit the
    /// default branch; ChatGPT/Codex share the OpenAI branch (Codex turns).
    func testUnlinkedPlanForecastIsNil() {
        let start = now.addingTimeInterval(-10 * 86400)
        let end = now.addingTimeInterval(20 * 86400)
        XCTAssertNil(SubscriptionMath.forecast(plan: "not-a-plan", cycleStart: start, cycleEnd: end, now: now),
                     "unknown plans must not fabricate a forecast")
        XCTAssertNil(SubscriptionMath.cycleValue(plan: "not-a-plan", cycle: "monthly", cycleStart: start),
                     "unknown plans must not fabricate a value")
    }

    /// SM-1: a weekly cycle must advance by adding 7 days (not week-of-year
    /// math, which misbehaves across year boundaries). A subscription that
    /// starts 2025-12-29 must have its window end exactly 2026-01-05.
    func testWeeklyCycleAcrossYearBoundaryIsSevenDayWindow() {
        let start: Int64 = 1_766_966_400                    // 2025-12-29T00:00:00Z
        let now = Date(timeIntervalSince1970: 1_767_312_000) // 2026-01-02T00:00:00Z
        guard let info = SubscriptionMath.cycleInfo(start: start, end: 0, cycle: "weekly", now: now) else {
            return XCTFail("weekly cycle must be active")
        }
        XCTAssertEqual(info.end.timeIntervalSince(info.start), 7 * 86400, accuracy: 1.0,
                       "weekly window must advance by exactly 7 days, not week-of-year math (SM-1)")
        XCTAssertEqual(info.totalDays, 7)
        XCTAssertEqual(info.dayOfCycle, 5, "Dec 29 → Jan 2 = 4 days elapsed → 1-based day 5")
    }

    /// SM-1: unknown cycle strings must return nil instead of silently
    /// falling into the monthly window.
    func testUnknownCycleReturnsNil() {
        let start: Int64 = 1_766_966_400
        let now = Date(timeIntervalSince1970: 1_767_312_000)
        XCTAssertNil(SubscriptionMath.cycleInfo(start: start, end: 0, cycle: "fortnightly", now: now))
        XCTAssertNil(SubscriptionMath.cycleInfo(start: start, end: 0, cycle: "", now: now))
        XCTAssertNil(SubscriptionMath.cycleInfo(start: start, end: 0, cycle: "Weekly", now: now),
                     "cycle matching is exact, not case-insensitive")
    }
}
