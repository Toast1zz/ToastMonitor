import XCTest
@testable import ToastMonitor

final class BalanceRunwayTests: XCTestCase {
    private let day: Int64 = 86_400

    func testCumulativeUsageGivesDailyPace() {
        let pace = BalanceRunway.dailySpend(cumulative: [(0, 1.0), (day, 1.5), (2 * day, 3.0)])
        XCTAssertEqual(pace!, 1.0, accuracy: 1e-9)
    }

    func testBalanceDropsIgnoreTopUps() {
        // 10 → 8 (spent 2), top-up to 20, → 19 (spent 1): 3 over 3 days.
        let samples: [(ts: Int64, value: Double)] = [(0, 10), (day, 8), (2 * day, 20), (3 * day, 19)]
        XCTAssertEqual(BalanceRunway.dailySpend(balances: samples)!, 1.0, accuracy: 1e-9)
    }

    func testUnderADayOfHistoryIsUnknown() {
        XCTAssertNil(BalanceRunway.dailySpend(cumulative: [(0, 1), (day - 1, 2)]))
        XCTAssertNil(BalanceRunway.dailySpend(balances: [(0, 5)]))
        XCTAssertNil(BalanceRunway.dailySpend(balances: []))
    }

    func testOnlyARunningOutBalanceSaysAnything() {
        XCTAssertEqual(BalanceRunway.lowText(balance: 3, dailySpend: 1), "~3.0d left")
        XCTAssertEqual(BalanceRunway.lowText(balance: 0.5, dailySpend: 1), "~12.0h left")
        XCTAssertNil(BalanceRunway.lowText(balance: 7, dailySpend: 1))      // exactly a week: fine
        XCTAssertNil(BalanceRunway.lowText(balance: 1.74, dailySpend: 0.0001)) // idle
    }

    func testUnknownPaceOrEmptyBalanceSaysNothing() {
        XCTAssertNil(BalanceRunway.lowText(balance: 5, dailySpend: nil))
        XCTAssertNil(BalanceRunway.lowText(balance: 0, dailySpend: 1))
        XCTAssertNil(BalanceRunway.lowText(balance: .nan, dailySpend: 1))
    }

    func testDeepSeekSamplesRoundTrip() throws {
        let path = NSTemporaryDirectory() + "runway-\(UUID().uuidString).db"
        let db = Database.testInstance(path: path)
        defer { db.close(); try? FileManager.default.removeItem(atPath: path) }
        // Recent timestamps: anything older than 400 days is pruned on write.
        let t = Int64(Date().timeIntervalSince1970) - 3_600
        db.insertDeepSeekBalance(currency: "CNY", amount: 10, ts: t)
        db.insertDeepSeekBalance(currency: "CNY", amount: 10, ts: t + 100)   // unchanged, <10 min: skipped
        db.insertDeepSeekBalance(currency: "CNY", amount: 9, ts: t + 200)
        // Wallets read in one refresh share a timestamp; neither may replace the other.
        db.insertDeepSeekBalance(currency: "USD", amount: 3, ts: t + 200)
        let cny = db.deepSeekBalances(currency: "CNY", since: 0)
        XCTAssertEqual(cny.map { $0.ts }, [t, t + 200])
        XCTAssertEqual(cny.map { $0.value }, [10, 9])
        XCTAssertEqual(db.deepSeekBalances(currency: "USD", since: 0).map { $0.value }, [3])
    }
}
