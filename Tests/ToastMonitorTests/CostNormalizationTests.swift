import XCTest
@testable import ToastMonitor

final class CostNormalizationTests: XCTestCase {
    private var database: Database!
    private var path: String!

    override func setUp() {
        super.setUp()
        path = NSTemporaryDirectory() + "tm-cost-\(UUID().uuidString).db"
        database = Database.testInstance(path: path)
    }

    override func tearDown() {
        database.close()
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
        super.tearDown()
    }

    func testCodexAPIValueDiscountsIncludedCachePerRowAndTool() {
        let rows: [(ToolKind, Int64, Int64, Double)] = [
            (.codex, 1_000_000, 800_000, 1.5),
            (.codex, 100_000, 200_000, 0.25),
            (.codex, 1_000_000, 0, 2.5),
            (.opencode, 1_000_000, 800_000, 3.5)
        ]
        for (index, row) in rows.enumerated() {
            XCTAssertTrue(database.insertTurns([TurnRecord(tool: row.0, sessionID: "cost-\(index)",
                project: nil, model: "gpt-4o", ts: 100, inputTokens: row.1,
                outputTokens: 0, cacheRead: row.2, cacheWrite: 0, cost: 0, costQuality: "unknown")]))
        }
        XCTAssertEqual(database.apiValue(from: 0, to: 200), 7.75, accuracy: 0.00001)
        XCTAssertEqual(database.apiValue(from: 0, to: 200, tool: "codex"), 4.25, accuracy: 0.00001)
        XCTAssertTrue(database.setSetting("codex_billing_mode", "subscription"))
        XCTAssertEqual(database.apiValue(from: 0, to: 200, tool: "codex"), 4.25, accuracy: 0.00001)
        database.backfillCosts()
        XCTAssertTrue(database.setSetting("codex_billing_mode", "api"))
        XCTAssertEqual(database.totals(from: 0, to: 200).cost, 7.75, accuracy: 0.00001)
    }
}
