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
    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private func subscription(start: Date, end: Date? = nil, cycle: String = "monthly", price: Double = 20) -> Database.Subscription {
        Database.Subscription(id: 99, name: "Test", plan: "", startDate: Int64(start.timeIntervalSince1970),
                              endDate: end.map { Int64($0.timeIntervalSince1970) } ?? 0,
                              cycle: cycle, price: price, currency: "USD")
    }

    func testMonthEndRenewalRestoresOriginalBillingDay() throws {
        let start = Int64(date(2026, 1, 31).timeIntervalSince1970)
        XCTAssertEqual(try XCTUnwrap(SubscriptionMath.cycleInfo(start: start, cycle: "monthly", now: date(2026, 2, 15))).end, date(2026, 2, 28))
        XCTAssertEqual(try XCTUnwrap(SubscriptionMath.cycleInfo(start: start, cycle: "monthly", now: date(2026, 3, 1))).end, date(2026, 3, 31))
    }

    func testLeapYearRenewalRestoresFebruary29() throws {
        let start = Int64(date(2024, 2, 29).timeIntervalSince1970)
        XCTAssertEqual(try XCTUnwrap(SubscriptionMath.cycleInfo(start: start, cycle: "yearly", now: date(2025, 2, 15))).end, date(2025, 2, 28))
        XCTAssertEqual(try XCTUnwrap(SubscriptionMath.cycleInfo(start: start, cycle: "yearly", now: date(2028, 2, 1))).end, date(2028, 2, 29))
    }

    func testEndedSubscriptionChargesEachStartedCycle() {
        let sub = subscription(start: date(2026, 1, 1), end: date(2026, 4, 1))
        XCTAssertEqual(SubscriptionMath.amortized(days: 90, subscriptions: [sub], now: date(2026, 4, 1)), 60, accuracy: 0.0001)
        XCTAssertEqual(SubscriptionMath.amortized(days: 28, subscriptions: [sub], now: date(2026, 3, 1)), 20, accuracy: 0.0001)
    }

    func testActiveWindowUsesEachCyclesActualDailyRate() {
        let sub = subscription(start: date(2026, 1, 1))
        XCTAssertEqual(SubscriptionMath.amortized(days: 42, subscriptions: [sub], now: date(2026, 3, 15)), 20 + 20 * 14 / 31, accuracy: 0.0001)
    }

    func testTruncatedFinalCyclesChargeFullPriceAcrossYearBoundary() {
        let weekly = subscription(start: date(2025, 12, 29), end: date(2026, 1, 8), cycle: "weekly", price: 7)
        XCTAssertEqual(SubscriptionMath.amortized(days: 10, subscriptions: [weekly], now: date(2026, 1, 8)), 14, accuracy: 0.0001)
        let monthly = subscription(start: date(2026, 1, 1), end: date(2026, 2, 10))
        XCTAssertEqual(SubscriptionMath.amortized(days: 40, subscriptions: [monthly], now: date(2026, 2, 10)), 40, accuracy: 0.0001)
        XCTAssertEqual(SubscriptionMath.amortized(days: 9, subscriptions: [monthly], now: date(2026, 2, 10)), 20, accuracy: 0.0001)
    }


    /// Calendar "Weekly" a day after its start pays for one day, not seven.
    func testAmortizedFollowsTheCalendarPeriod() {
        let sub = Database.Subscription(id: 1, name: "Plan", plan: "", startDate: 1_700_000_000,
                                        cycle: "monthly", price: 30, currency: "USD")
        var calendar = Calendar.current
        calendar.firstWeekday = 2
        let monday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 0))!
        let tuesdayNoon = monday.addingTimeInterval(36 * 3600)
        var configuration = UsagePeriodConfiguration()
        configuration.mode = .calendar
        configuration.weekStart = .monday
        let week = SubscriptionMath.amortized(slot: .week, configuration: configuration,
                                              subscriptions: [sub], now: tuesdayNoon)
        let sevenDays = SubscriptionMath.amortized(days: 7, subscriptions: [sub], now: tuesdayNoon)
        XCTAssertEqual(week / sevenDays, 1.5 / 7, accuracy: 0.03)
    }
}
