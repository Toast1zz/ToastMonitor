import XCTest
@testable import ToastMonitor

final class UsagePeriodTests: XCTestCase {
    func testRecentLabelsUseCompactTitles() {
        let config = UsagePeriodConfiguration(mode: .recent, weekStart: .monday)
        XCTAssertEqual(config.label(for: .today), "Today")
        XCTAssertEqual(config.label(for: .week), "7 Days")
        XCTAssertEqual(config.label(for: .month), "30 Days")
        XCTAssertEqual(config.label(for: .all), "All Time")
    }

    func testCalendarLabelsUseWeeklyAndMonthly() {
        let config = UsagePeriodConfiguration(mode: .calendar, weekStart: .monday)
        XCTAssertEqual(config.label(for: .week), "Weekly")
        XCTAssertEqual(config.label(for: .month), "Monthly")
        XCTAssertEqual(config.title(for: .week), "Weekly Usage")
        XCTAssertEqual(config.title(for: .month), "Monthly Usage")
    }

    func testCalendarWeekRespectsMondayOrSunday() {
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 19 // Wednesday
        let calendar = Calendar(identifier: .gregorian)
        let date = calendar.date(from: components)!

        let monday = UsagePeriodConfiguration(mode: .calendar, weekStart: .monday)
        let sunday = UsagePeriodConfiguration(mode: .calendar, weekStart: .sunday)
        let mondayRange = monday.range(for: .week, now: date)
        let sundayRange = sunday.range(for: .week, now: date)

        XCTAssertEqual(calendar.component(.weekday, from: Date(timeIntervalSince1970: TimeInterval(mondayRange.start))), 2)
        XCTAssertEqual(calendar.component(.weekday, from: Date(timeIntervalSince1970: TimeInterval(sundayRange.start))), 1)
    }

    func testRecentPeriodsUseInclusiveLocalDayWindows() {
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 19
        components.hour = 12
        let date = Calendar.current.date(from: components)!
        let config = UsagePeriodConfiguration(mode: .recent, weekStart: .monday)
        let todayStart = Calendar.current.startOfDay(for: date)

        XCTAssertEqual(
            config.range(for: .week, now: date).start,
            Int64(Calendar.current.date(byAdding: .day, value: -6, to: todayStart)!.timeIntervalSince1970)
        )
        XCTAssertEqual(
            config.range(for: .month, now: date).start,
            Int64(Calendar.current.date(byAdding: .day, value: -29, to: todayStart)!.timeIntervalSince1970)
        )
    }
}
