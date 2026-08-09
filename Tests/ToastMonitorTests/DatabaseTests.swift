import XCTest
import SQLite3
@testable import ToastMonitor

/// P0-3 (事件身份) 与 P0-9 (订阅 ID) 的失败测试。
/// 每个测试使用独立临时 DB，绝不触碰真实存储。
final class DatabaseTests: XCTestCase {
    private var tmpPath: String!
    private var db: Database!

    override func setUp() {
        super.setUp()
        tmpPath = NSTemporaryDirectory() + "tm-test-\(UUID().uuidString).db"
        db = Database.testInstance(path: tmpPath)
    }

    override func tearDown() {
        db?.close()
        let fm = FileManager.default
        try? fm.removeItem(atPath: tmpPath)
        try? fm.removeItem(atPath: tmpPath + "-wal")
        try? fm.removeItem(atPath: tmpPath + "-shm")
        super.tearDown()
    }

    func testTokenMetricIncludesCacheReadExceptCodex() {
        XCTAssertEqual(ToolKind.claude.totalTokens(input: 100, output: 20, cacheRead: 1_000), 1_120)
        XCTAssertEqual(ToolKind.codex.totalTokens(input: 100, output: 20, cacheRead: 1_000), 120)
    }

    // P0-3: 重放去重（同一事件重复导入只保留一条）——当前行为正确。
    func testReplaySameEventDedupes() {
        let t = TurnRecord(tool: .codex, sessionID: "s1", project: nil, model: "gpt-5.6-sol",
                           ts: 1_000_000, inputTokens: 10, outputTokens: 5,
                           cacheRead: 0, cacheWrite: 0, cost: 0)
        db.insertTurns([t])
        db.insertTurns([t])
        XCTAssertEqual(db.turnCount(), 1, "同一事件重放被重复导入")
    }

    func testCanonicalEventSupersedesDerivedMigrationRow() {
        let legacy = TurnRecord(tool: .claude, sessionID: "s1", project: "p", model: "m",
                                ts: 100, inputTokens: 10, outputTokens: 5,
                                cacheRead: 2, cacheWrite: 1, cost: 0)
        let canonical = TurnRecord(tool: .claude, sessionID: "s1", project: "p", model: "m",
                                   ts: 100, inputTokens: 10, outputTokens: 5,
                                   cacheRead: 2, cacheWrite: 1, cost: 0,
                                   eventID: "claude:s1:msg-1", costQuality: "estimated")
        XCTAssertTrue(db.insertTurns([legacy]))
        XCTAssertTrue(db.insertTurns([canonical]))
        XCTAssertEqual(db.turnCount(), 1, "canonical replay must replace its migration-era derived row")
        XCTAssertTrue(db.insertTurns([canonical]))
        XCTAssertEqual(db.turnCount(), 1)
    }

    func testLocalRebuildPreviewBackupResetAndRestore() {
        let turn = TurnRecord(tool: .claude, sessionID: "s1", project: nil, model: "m",
                              ts: 100, inputTokens: 10, outputTokens: 5,
                              cacheRead: 2, cacheWrite: 0, cost: 0,
                              eventID: "claude:s1:m1")
        XCTAssertTrue(db.insertTurns([turn]))
        XCTAssertTrue(db.upsertSessions([
            SessionInfo(tool: .claude, sessionID: "s1", title: nil, project: nil,
                        model: "m", created: 100, updated: 100)
        ]))
        let preview = db.previewLocalRebuild(tools: [.claude])
        XCTAssertEqual(preview.turns, 1)
        XCTAssertEqual(preview.sessions, 1)
        XCTAssertEqual(preview.tokens, 17)

        let backup = tmpPath + ".backup"
        defer { try? FileManager.default.removeItem(atPath: backup) }
        XCTAssertTrue(db.backup(to: backup))
        XCTAssertTrue(db.resetLocalUsage([(.claude, ["/tmp/claude-root"])]))
        XCTAssertEqual(db.turnCount(), 0)
        XCTAssertTrue(db.restore(from: backup))
        XCTAssertEqual(db.turnCount(), 1)
    }

    func testDailyAggregatesCountCallsRatherThanDays() {
        let turns = [
            TurnRecord(tool: .claude, sessionID: "s1", project: nil, model: "m",
                       ts: Int64(Date().timeIntervalSince1970), inputTokens: 1, outputTokens: 1,
                       cacheRead: 0, cacheWrite: 0, cost: 0, eventID: "call-1"),
            TurnRecord(tool: .claude, sessionID: "s1", project: nil, model: "m",
                       ts: Int64(Date().timeIntervalSince1970) + 1, inputTokens: 2, outputTokens: 1,
                       cacheRead: 0, cacheWrite: 0, cost: 0, eventID: "call-2"),
        ]
        XCTAssertTrue(db.insertTurns(turns))
        XCTAssertEqual(db.dailyAggregates(days: 1).first?.count, 2)
        XCTAssertEqual(db.dailyAggregatesByModel(days: 1).first?.count, 2)
    }

    // P0-3: 同 session、同秒、相同 token 的两个不同真实事件必须都保留。
    // 现在靠上游 event_id 区分（parser 提供），不再被复合键误去重。
    func testSameSecondSameTokensSameSessionDistinctEvents() {
        let t1 = TurnRecord(tool: .codex, sessionID: "s1", project: nil, model: "gpt-5.6-sol",
                            ts: 1_000_000, inputTokens: 10, outputTokens: 5,
                            cacheRead: 0, cacheWrite: 0, cost: 0,
                            eventID: "codex:f1:100", costQuality: "estimated")
        let t2 = TurnRecord(tool: .codex, sessionID: "s1", project: nil, model: "gpt-5.6-sol",
                            ts: 1_000_000, inputTokens: 10, outputTokens: 5,
                            cacheRead: 0, cacheWrite: 0, cost: 0,
                            eventID: "codex:f1:200", costQuality: "estimated")
        db.insertTurns([t1, t2])
        XCTAssertEqual(db.turnCount(), 2, "同秒同 token 的两个不同事件被误去重 (P0-3)")

        // 同一事件重放（同 event_id）仍去重。
        db.insertTurns([t1])
        XCTAssertEqual(db.turnCount(), 2, "同一事件重放被重复导入")
    }

    // P0-2: 事务失败必须回滚 — turns 不落库，游标不得前进。
    func testIngestionTransactionRollsBack() {
        let t = TurnRecord(tool: .claude, sessionID: "s1", project: nil, model: "m",
                           ts: 100, inputTokens: 1, outputTokens: 1,
                           cacheRead: 0, cacheWrite: 0, cost: 0,
                           eventID: "e1", costQuality: "estimated")
        let ok = db.inTransaction {
            db.insertTurns([t])
            return false // simulate a downstream failure
        }
        XCTAssertFalse(ok)
        XCTAssertEqual(db.turnCount(), 0, "失败事务未回滚，turns 已落库 (P0-2)")

        // 下一轮正常提交仍工作。
        let ok2 = db.inTransaction {
            db.insertTurns([t])
            return true
        }
        XCTAssertTrue(ok2)
        XCTAssertEqual(db.turnCount(), 1)
    }

    func testFailedNestedWriteAbortsOuterTransaction() {
        let t = TurnRecord(tool: .codex, sessionID: "s-write", project: nil, model: "m",
                           ts: 200, inputTokens: 2, outputTokens: 1,
                           cacheRead: 0, cacheWrite: 0, cost: 0,
                           eventID: "write-e", costQuality: "estimated")
        let ok = db.inTransaction {
            XCTAssertTrue(db.insertTurns([t]))
            // Invalid composite key is a real write error, not a duplicate.
            XCTAssertFalse(db.setSessionTotals("malformed", tool: "codex", input: 1,
                                               output: 1, cacheRead: 0, cacheWrite: 0,
                                               cost: 0, updated: 200))
            return true
        }
        XCTAssertFalse(ok)
        XCTAssertEqual(db.turnCount(), 0)
    }

    func testSessionTotalsPersistReasoningSeparately() {
        XCTAssertTrue(db.setSessionTotals("opencode|s1", tool: "opencode",
                                          input: 10, output: 5, reasoning: 7,
                                          cacheRead: 3, cacheWrite: 2,
                                          cost: 0.1, updated: 100))
        let totals = db.sessionTotals()["opencode|s1"]
        XCTAssertEqual(totals?.input, 10)
        XCTAssertEqual(totals?.output, 5)
        XCTAssertEqual(totals?.reasoning, 7)
    }

    // P0-9: 旧库 id=0 记录迁移到真实自增 id，数据不丢失。
    // 使用独立路径（setUp 的 testInstance 已建好库，迁移不会重跑）。
    func testSubscriptionIDZeroMigration() throws {
        let legacyPath = tmpPath + "-legacy.db"
        defer {
            try? FileManager.default.removeItem(atPath: legacyPath)
            try? FileManager.default.removeItem(atPath: legacyPath + "-wal")
            try? FileManager.default.removeItem(atPath: legacyPath + "-shm")
        }
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(legacyPath, &raw, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil), SQLITE_OK)
        let legacy = """
        CREATE TABLE subscriptions (
          id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL,
          plan TEXT NOT NULL DEFAULT '', start_date INTEGER NOT NULL DEFAULT 0,
          cycle TEXT NOT NULL DEFAULT 'monthly', price REAL NOT NULL DEFAULT 0,
          currency TEXT NOT NULL DEFAULT 'USD');
        """
        sqlite3_exec(raw, legacy, nil, nil, nil)
        sqlite3_exec(raw, "INSERT INTO subscriptions (id, name, plan, start_date, cycle, price, currency) VALUES (0, 'LegacyGo', 'go', 1000, 'monthly', 10, 'USD');", nil, nil, nil)
        sqlite3_close(raw)

        // Open through the real migration path (fresh DB, user_version=0).
        let d = Database.testInstance(path: legacyPath)
        defer { d.close() }
        let subs = d.subscriptions()
        XCTAssertEqual(subs.count, 1)
        XCTAssertEqual(subs.first?.name, "LegacyGo")
        XCTAssertNotEqual(subs.first?.id, 0, "id=0 记录未被迁移")
        XCTAssertEqual(subs.first?.price, 10)
    }

    func testLegacyTurnsUniqueConstraintIsRebuilt() throws {
        let legacyPath = tmpPath + "-turns-legacy.db"
        defer {
            try? FileManager.default.removeItem(atPath: legacyPath)
            try? FileManager.default.removeItem(atPath: legacyPath + "-wal")
            try? FileManager.default.removeItem(atPath: legacyPath + "-shm")
        }
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(legacyPath, &raw, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil), SQLITE_OK)
        let schema = """
        CREATE TABLE turns (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          tool TEXT NOT NULL,
          session_id TEXT NOT NULL,
          project TEXT,
          model TEXT,
          ts INTEGER NOT NULL,
          input_tokens INTEGER NOT NULL DEFAULT 0,
          output_tokens INTEGER NOT NULL DEFAULT 0,
          cost REAL NOT NULL DEFAULT 0,
          UNIQUE(tool, session_id, ts, input_tokens, output_tokens)
        );
        PRAGMA user_version=1;
        INSERT INTO turns(tool, session_id, model, ts, input_tokens, output_tokens)
          VALUES ('codex', 'legacy', 'm', 100, 10, 5);
        """
        XCTAssertEqual(sqlite3_exec(raw, schema, nil, nil, nil), SQLITE_OK)
        sqlite3_close(raw)

        let migrated = Database.testInstance(path: legacyPath)
        defer { migrated.close() }
        XCTAssertEqual(migrated.turnCount(), 1)
        let distinct = TurnRecord(tool: .codex, sessionID: "legacy", project: nil, model: "m",
                                  ts: 100, inputTokens: 10, outputTokens: 5,
                                  cacheRead: 0, cacheWrite: 0, cost: 0,
                                  eventID: "second-event", costQuality: "estimated")
        XCTAssertTrue(migrated.insertTurns([distinct]))
        XCTAssertEqual(migrated.turnCount(), 2, "legacy compound UNIQUE 仍吞掉同秒同 token 事件")
    }

    func testOpenRouterCycleSpendSubtractsMiddayBaseline() {
        let day = Int64(2_000_000_000 / 86400) * 86400
        XCTAssertTrue(db.insertORSnapshot(.init(ts: day + 100, usage: 0, usageDaily: 2,
                                                usageWeekly: 2, usageMonthly: 2, limit: nil,
                                                limitRemaining: nil, limitReset: nil, isFreeTier: false,
                                                creditsTotal: nil, creditsUsage: nil, accountUsage: nil,
                                                accountBalance: nil, isManagementKey: false)))
        XCTAssertTrue(db.insertORSnapshot(.init(ts: day + 5_000, usage: 0, usageDaily: 5,
                                                usageWeekly: 5, usageMonthly: 5, limit: nil,
                                                limitRemaining: nil, limitReset: nil, isFreeTier: false,
                                                creditsTotal: nil, creditsUsage: nil, accountUsage: nil,
                                                accountBalance: nil, isManagementKey: false)))
        XCTAssertTrue(db.insertORSnapshot(.init(ts: day + 86_500, usage: 0, usageDaily: 4,
                                                usageWeekly: 4, usageMonthly: 4, limit: nil,
                                                limitRemaining: nil, limitReset: nil, isFreeTier: false,
                                                creditsTotal: nil, creditsUsage: nil, accountUsage: nil,
                                                accountBalance: nil, isManagementKey: false)))
        XCTAssertEqual(db.orSpendSince(day + 2_000), 7, accuracy: 0.0001)
    }

    // P0-9: 两条 id=0 订阅不得互相覆盖。
    func testZeroIDSubscriptionsDoNotOverwrite() {
        let a = Database.Subscription(id: 0, name: "OpenCode Go", plan: "go",
                                      startDate: 1000, cycle: "monthly", price: 10, currency: "USD")
        let b = Database.Subscription(id: 0, name: "Codex", plan: "",
                                      startDate: 2000, cycle: "monthly", price: 20, currency: "USD")
        db.upsertSubscription(a)
        db.upsertSubscription(b)
        let subs = db.subscriptions()
        XCTAssertEqual(subs.count, 2, "两条 id=0 订阅互相覆盖 (P0-9)")
        XCTAssertTrue(subs.contains { $0.name == "OpenCode Go" })
        XCTAssertTrue(subs.contains { $0.name == "Codex" })
    }

    // 编辑与删除互不影响 (规格 6.P0-9 验收)。
    func testEditAndDeleteAreIndependent() throws {
        db.upsertSubscription(Database.Subscription(id: 0, name: "A", plan: "", startDate: 1, cycle: "monthly", price: 10, currency: "USD"))
        db.upsertSubscription(Database.Subscription(id: 0, name: "B", plan: "", startDate: 2, cycle: "monthly", price: 5, currency: "USD"))
        var subs = db.subscriptions()
        XCTAssertEqual(subs.count, 2)

        // 编辑 A (改名)
        let a = try XCTUnwrap(subs.first { $0.name == "A" })
        var a2 = a
        a2.name = "A2"
        db.upsertSubscription(a2)
        subs = db.subscriptions()
        XCTAssertEqual(subs.count, 2)
        XCTAssertTrue(subs.contains { $0.name == "A2" })
        XCTAssertTrue(subs.contains { $0.name == "B" })

        // 删除 B
        let b = try XCTUnwrap(subs.first { $0.name == "B" })
        db.deleteSubscription(id: b.id)
        subs = db.subscriptions()
        XCTAssertEqual(subs.count, 1)
        XCTAssertEqual(subs.first?.name, "A2")
    }
}

extension DatabaseTests {
    func testUpdateSubscriptionDoesNotDuplicate() throws {
        let path = NSTemporaryDirectory() + "sub-update-\(UUID().uuidString).db"
        let db = Database.testInstance(path: path)
        defer {
            db.close()
            try? FileManager.default.removeItem(atPath: path)
            try? FileManager.default.removeItem(atPath: path + "-wal")
            try? FileManager.default.removeItem(atPath: path + "-shm")
        }

        let created = Database.Subscription(id: 0, name: "Claude Pro", plan: "claude",
                                            startDate: 1_700_000_000, endDate: 1_702_000_000,
                                            cycle: "monthly", price: 23.2, currency: "USD")
        XCTAssertTrue(db.upsertSubscription(created))
        var rows = db.subscriptions()
        XCTAssertEqual(rows.count, 1)
        let realID = rows[0].id
        XCTAssertGreaterThan(realID, 0, "insert must return a real id")

        // Edit the same row: same id, new price/name.
        let edited = Database.Subscription(id: realID, name: "Claude Pro (edited)", plan: "claude",
                                           startDate: 1_700_000_000, endDate: 1_702_000_000,
                                           cycle: "monthly", price: 25.0, currency: "USD")
        XCTAssertTrue(db.upsertSubscription(edited))
        rows = db.subscriptions()
        XCTAssertEqual(rows.count, 1, "updating an existing id must not insert a new row")
        XCTAssertEqual(rows[0].name, "Claude Pro (edited)")
        XCTAssertEqual(rows[0].price, 25.0)
    }
}
