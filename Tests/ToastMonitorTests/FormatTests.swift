import XCTest
@testable import ToastMonitor

final class FormatTests: XCTestCase {

    // MARK: - compact (tokens)

    func testCompactThresholds() {
        XCTAssertEqual(Format.compact(999), "999", "below 1k stays raw")
        XCTAssertEqual(Format.compact(1_000), "1.0k")
        XCTAssertEqual(Format.compact(999_999), "1000.0k", "still in the k band until 1M")
        XCTAssertEqual(Format.compact(1_000_000), "1.0M")
        XCTAssertEqual(Format.compact(1_000_000_000), "1.00B")
        XCTAssertEqual(Format.compact(1_000_000_000_000), "1.00T")
    }

    func testCompactRepresentativeValues() {
        XCTAssertEqual(Format.compact(1_234), "1.2k")
        XCTAssertEqual(Format.compact(1_234_567), "1.2M")
        XCTAssertEqual(Format.compact(4_150_000_000), "4.15B")
        XCTAssertEqual(Format.compact(1_020_000_000_000), "1.02T")
        XCTAssertEqual(Format.compact(0), "0")
    }

    // MARK: - money

    func testMoneyPrecisionTiers() {
        XCTAssertEqual(Format.money(0), "$0.00")
        XCTAssertEqual(Format.money(100), "$100", ">= 100 drops cents")
        XCTAssertEqual(Format.money(123.45), "$123")
        XCTAssertEqual(Format.money(99.99), "$99.99", ">= 1 keeps cents")
        XCTAssertEqual(Format.money(1), "$1.00")
        XCTAssertEqual(Format.money(1.234), "$1.23")
        XCTAssertEqual(Format.money(0.5), "$0.500", ">= 0.01 gets 3 decimals")
        XCTAssertEqual(Format.money(0.01), "$0.010")
        XCTAssertEqual(Format.money(0.001), "$0.0010", "below 0.01 gets 4 decimals")
        XCTAssertEqual(Format.money(0.0001), "$0.0001")
    }

    // MARK: - dayKeyString

    func testDayKeyString() {
        XCTAssertEqual(Format.dayKeyString(20260805), "2026-08-05")
        XCTAssertEqual(Format.dayKeyString(20260101), "2026-01-01", "zero-padded month/day")
        XCTAssertEqual(Format.dayKeyString(20261231), "2026-12-31")
        XCTAssertEqual(Format.dayKeyString(19700101), "1970-01-01")
    }

    // MARK: - countdown

    func testCountdown() {
        XCTAssertEqual(Format.countdown(0), "即将重置")
        XCTAssertEqual(Format.countdown(-5), "即将重置")
        XCTAssertEqual(Format.countdown(45), "0分后", "sub-minute rounds to 0分")
        XCTAssertEqual(Format.countdown(90), "1分后")
        XCTAssertEqual(Format.countdown(3_661), "1小时1分")
        XCTAssertEqual(Format.countdown(86_400), "1天0小时")
        XCTAssertEqual(Format.countdown(90_061), "1天1小时")
    }
}
