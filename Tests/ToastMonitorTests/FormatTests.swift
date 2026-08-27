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
        XCTAssertEqual(Format.money(100), "$100", "whole dollars drop cents")
        XCTAssertEqual(Format.money(123.45), "$123.45", ">= 100 keeps cents (FM-1)")
        XCTAssertEqual(Format.money(99.99), "$99.99", ">= 1 keeps cents")
        XCTAssertEqual(Format.money(1), "$1.00")
        XCTAssertEqual(Format.money(1.234), "$1.23")
        XCTAssertEqual(Format.money(0.5), "$0.500", ">= 0.01 gets 3 decimals")
        XCTAssertEqual(Format.money(0.01), "$0.010")
        XCTAssertEqual(Format.money(0.001), "$0.0010", "below 0.01 gets 4 decimals")
        XCTAssertEqual(Format.money(0.0001), "$0.0001")
    }

    // MARK: - money: NaN / negative / locale stability (FM-1)

    func testMoneyNonFiniteAndNegative() {
        XCTAssertEqual(Format.money(.nan), "$0.00", "NaN must never render as $nan (FM-1)")
        XCTAssertEqual(Format.money(Double.infinity), "$0.00")
        XCTAssertEqual(Format.money(-Double.infinity), "$0.00")
        XCTAssertEqual(Format.money(-0.5), "-$0.500", "negative mirrors the positive precision tier")
        XCTAssertEqual(Format.money(-99.99), "-$99.99")
        XCTAssertEqual(Format.money(-123.45), "-$123.45", ">= $100 keeps cents on negatives too")
        XCTAssertEqual(Format.money(-100), "-$100")
    }

    func testMoneyAndFullUsePOSIXGroupingUnderAnyLocale() {
        // These exact strings must hold regardless of the machine's locale:
        // the formatters are pinned to en_US_POSIX.
        XCTAssertEqual(Format.money(123_456.78), "$123,456.78", "POSIX comma grouping (FM-1)")
        XCTAssertEqual(Format.money(123_456.789), "$123,456.79", "cents rounded at 2 digits")
        XCTAssertEqual(Format.full(1_234_567), "1,234,567", "POSIX grouping independent of system locale (FM-1)")
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
        XCTAssertEqual(Format.countdown(0), "resetting soon")
        XCTAssertEqual(Format.countdown(-5), "resetting soon")
        XCTAssertEqual(Format.countdown(45), "in 0m", "sub-minute values round down")
        XCTAssertEqual(Format.countdown(90), "in 1m")
        XCTAssertEqual(Format.countdown(3_661), "1h 1m")
        XCTAssertEqual(Format.countdown(86_400), "1d 0h")
        XCTAssertEqual(Format.countdown(90_061), "1d 1h")
    }
}
