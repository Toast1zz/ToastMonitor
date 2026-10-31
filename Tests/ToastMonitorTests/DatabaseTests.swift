import XCTest
import SQLite3
@testable import ToastMonitor

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

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

    func testModelAndCSVTokenTotalsMatchMixedToolTotals() {
        let now = Int64(Date().timeIntervalSince1970)
        XCTAssertTrue(db.insertTurns([
            TurnRecord(tool: .codex, sessionID: "codex-test", project: nil, model: "mixed-model", ts: now,
                       inputTokens: 100, outputTokens: 20, cacheRead: 80, cacheWrite: 0, cost: 0),
            TurnRecord(tool: .claude, sessionID: "claude-test", project: nil, model: "mixed-model", ts: now,
                       inputTokens: 10, outputTokens: 5, cacheRead: 30, cacheWrite: 0, cost: 0),
        ]))
        let toolTotal = db.totalsByTool(from: 0, to: .max).reduce(Int64(0)) {
            $0 + (ToolKind(rawValue: $1.tool)?.totalTokens(input: $1.input, output: $1.output, cacheRead: $1.cacheRead) ?? 0)
        }
        XCTAssertEqual(toolTotal, 165)
        let models = db.dailyAggregatesByModel(days: 1)
        XCTAssertEqual(models.reduce(0) { $0 + $1.totalTokens }, 165)
        XCTAssertEqual(AnalysisCSVRow.perModelID(models).reduce(0) { $0 + $1.tokens }, 165)
    }

    func testTokenMetricIncludesCacheReadExceptCodex() {
        XCTAssertEqual(ToolKind.claude.totalTokens(input: 100, output: 20, cacheRead: 1_000), 1_120)
        XCTAssertEqual(ToolKind.codex.totalTokens(input: 100, output: 20, cacheRead: 1_000), 120)
    }

    func testDeepSeekCoveredActualOnlyMatchesDirectProviderAndPeriod() {
        let providers = ["deepseek", "openrouter", "custom", "deepseek"]
        let turns = providers.enumerated().map { index, provider in
            TurnRecord(tool: .opencode, sessionID: "ds-\(index)", project: nil,
                       model: "deepseek-chat", ts: index == 3 ? 500 : 100,
                       inputTokens: 1, outputTokens: 1, cacheRead: 0, cacheWrite: 0,
                       cost: 2, provider: provider, costQuality: "actual")
        }
        XCTAssertTrue(db.insertTurns(turns))
        let result = db.costBreakdown(from: 0, to: 200)
        XCTAssertEqual(result.actual, 6)
        XCTAssertEqual(result.deepseekActual, 2)
    }

    func testScanStateTableCacheInvalidatesAfterWrite() {
        XCTAssertTrue(db.setScanState("cached-source", size: 10, mtime: 20,
                                      identity: 30, context: "first"))
        XCTAssertEqual(db.scanStates()["cached-source"]?.size, 10)
        XCTAssertTrue(db.setScanState("cached-source", size: 40, mtime: 50,
                                      identity: 60, context: "second"))
        let refreshed = db.scanState("cached-source")
        XCTAssertEqual(refreshed.size, 40)
        XCTAssertEqual(refreshed.mtime, 50)
        XCTAssertEqual(refreshed.identity, 60)
        XCTAssertEqual(refreshed.context, "second")
    }

    /// P: Codex billed inside a ChatGPT/Codex subscription must not show up as
    /// API variable spend: tokens stay counted, cost is zeroed. Switching the
    /// billing mode back to API restores the cost.
    func testCodexBillingModeFiltersEstimatedCost() {
        let now = Int64(Date().timeIntervalSince1970)
        let codexTurn = TurnRecord(tool: .codex, sessionID: "s-codex", project: nil,
                                   model: "gpt-5.6-sol", ts: now - 60, inputTokens: 100,
                                   outputTokens: 50, cacheRead: 0, cacheWrite: 0, cost: 12.5)
        let claudeTurn = TurnRecord(tool: .claude, sessionID: "s-claude", project: nil,
                                    model: "claude-sonnet-4-5", ts: now - 60, inputTokens: 100,
                                    outputTokens: 50, cacheRead: 0, cacheWrite: 0, cost: 3.0)
        XCTAssertTrue(db.insertTurns([codexTurn, claudeTurn]))

        // Default (API mode): Codex cost is variable spend.
        let apiTotals = db.totals(from: now - 3600, to: now)
        XCTAssertEqual(apiTotals.cost, 15.5, accuracy: 0.001)
        let apiByTool = db.totalsByTool(from: now - 3600, to: now)
        XCTAssertEqual(apiByTool.first { $0.tool == "codex" }?.cost ?? -1, 12.5, accuracy: 0.001)

        // Subscription mode: Codex cost covered, tokens still counted.
        XCTAssertTrue(db.setSetting("codex_billing_mode", "subscription"))
        let subTotals = db.totals(from: now - 3600, to: now)
        XCTAssertEqual(subTotals.cost, 3.0, accuracy: 0.001, "Codex cost must not appear as variable spend")
        XCTAssertEqual(subTotals.input, 200, "tokens are still counted")
        let subByTool = db.totalsByTool(from: now - 3600, to: now)
        XCTAssertEqual(subByTool.first { $0.tool == "codex" }?.cost ?? -1, 0.0, accuracy: 0.001)
        XCTAssertEqual(subByTool.first { $0.tool == "codex" }?.input ?? 0, 100, "codex token row survives")
        XCTAssertEqual(db.codexBilledBySubscription(), true)

        // Back to API mode: cost restored.
        XCTAssertTrue(db.setSetting("codex_billing_mode", "api"))
        XCTAssertEqual(db.totals(from: now - 3600, to: now).cost, 15.5, accuracy: 0.001)
        XCTAssertEqual(db.codexBilledBySubscription(), false)
    }

    /// apiValue groups tokens by model at the SQL level before pricing
    /// (rather than pricing every row) — this checks that the grouped total
    /// still equals the sum of per-row Pricing.estimate results, including
    /// multiple turns of the same model across different tools, a distinct
    /// model that only one tool used, and cache read/write tokens.
    func testAPIValueMatchesPerRowPricingAfterGrouping() {
        let now = Int64(Date().timeIntervalSince1970)
        let turns = [
            TurnRecord(tool: .claude, sessionID: "s1", project: nil, model: "claude-sonnet-4-5",
                      ts: now - 300, inputTokens: 1_000, outputTokens: 200,
                      cacheRead: 500, cacheWrite: 100, cost: 0),
            TurnRecord(tool: .opencode, sessionID: "s2", project: nil, model: "claude-sonnet-4-5",
                      ts: now - 200, inputTokens: 2_000, outputTokens: 400,
                      cacheRead: 0, cacheWrite: 0, cost: 0),
            TurnRecord(tool: .codex, sessionID: "s3", project: nil, model: "gpt-5.6-sol",
                      ts: now - 100, inputTokens: 3_000, outputTokens: 600,
                      cacheRead: 0, cacheWrite: 0, cost: 0),
        ]
        XCTAssertTrue(db.insertTurns(turns))

        let expected = turns.reduce(0.0) { partial, t in
            partial + (Pricing.estimate(model: t.model, input: t.inputTokens,
                                        output: t.outputTokens, cacheRead: t.cacheRead,
                                        cacheWrite: t.cacheWrite) ?? 0)
        }
        XCTAssertEqual(db.apiValue(from: now - 3600, to: now), expected, accuracy: 0.0001)

        let claudeOnly = turns.filter { $0.tool == .claude }.reduce(0.0) { partial, t in
            partial + (Pricing.estimate(model: t.model, input: t.inputTokens,
                                        output: t.outputTokens, cacheRead: t.cacheRead,
                                        cacheWrite: t.cacheWrite) ?? 0)
        }
        XCTAssertEqual(db.apiValue(from: now - 3600, to: now, tool: "claude"), claudeOnly, accuracy: 0.0001)
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

    func testLateRemoteEventIsImportedDespiteExistingWatermark() {
        let now = Int64(Date().timeIntervalSince1970)
        let oldTimestamp = now - 3_600
        XCTAssertTrue(db.setSetting("src_claude", "remote"))
        XCTAssertTrue(db.setSetting("remote_watermark_claude", "\(now):z"))

        let row: [String: Any] = [
            "tool": "claude",
            "session_id": "late-session",
            "model": "claude-3-5-sonnet",
            "last_seen": NSNumber(value: oldTimestamp),
            "first_seen": NSNumber(value: oldTimestamp),
            "input_tokens": NSNumber(value: 10),
            "output_tokens": NSNumber(value: 5),
            "event_id": "late-event"
        ]
        HermesRemoteClient.shared.importFeed(["rows": [row]], database: db)

        let turns = db.turns(sessionTool: "claude", sessionID: "late-session")
        XCTAssertEqual(turns.count, 1, "event identity must admit rows older than the timestamp watermark")
        XCTAssertEqual(turns.first?.ts, oldTimestamp)
    }

    func testRemoteFeedAcceptsNullOptionalStrings() {
        let now = Int64(Date().timeIntervalSince1970)
        XCTAssertTrue(db.setSetting("src_claude", "remote"))
        let row: [String: Any] = [
            "tool": "claude",
            "session_id": "null-title-session",
            "model": "claude-3-5-sonnet",
            "title": NSNull(),
            "project": NSNull(),
            "last_seen": NSNumber(value: now),
            "first_seen": NSNumber(value: now),
            "input_tokens": NSNumber(value: 10),
            "output_tokens": NSNumber(value: 5),
            "event_id": "null-title-event"
        ]

        HermesRemoteClient.shared.importFeed(["rows": [row]], database: db)

        let turns = db.turns(sessionTool: "claude", sessionID: "null-title-session")
        XCTAssertEqual(turns.count, 1, "JSON null must be treated like a missing optional field")
    }
    func testHermesCumulativeBaselineReplaysAfterTransactionRollback() {
        XCTAssertTrue(db.setSetting("src_hermes", "remote"))
        let first = hermesCumulativeRow(input: 100, id: "feed-100")
        HermesRemoteClient.shared.importFeed(["rows": [first]], database: db)
        XCTAssertEqual(db.turns(sessionTool: "hermes", sessionID: "remote-cumulative").reduce(Int64(0)) { $0 + $1.input }, 100)

        // Fail after the hm_d baseline was written, while the watermark is
        // being persisted. The outer transaction rolls back both writes.
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open(tmpPath, &raw), SQLITE_OK)
        defer { if let raw { sqlite3_close(raw) } }
        XCTAssertEqual(sqlite3_exec(raw, "CREATE TRIGGER fail_hermes_watermark BEFORE INSERT ON settings WHEN NEW.k='remote_watermark_hermes' BEGIN SELECT RAISE(ABORT, 'forced watermark failure'); END;", nil, nil, nil), SQLITE_OK)
        HermesRemoteClient.shared.importFeed(["rows": [hermesCumulativeRow(input: 200, id: "feed-200")]], database: db)
        XCTAssertEqual(db.turns(sessionTool: "hermes", sessionID: "remote-cumulative").reduce(Int64(0)) { $0 + $1.input }, 100,
                       "failed transaction must not retain staged turns")
        XCTAssertEqual(sqlite3_exec(raw, "DROP TRIGGER fail_hermes_watermark;", nil, nil, nil), SQLITE_OK)

        HermesRemoteClient.shared.importFeed(["rows": [hermesCumulativeRow(input: 200, id: "feed-200")]], database: db)
        XCTAssertEqual(db.turns(sessionTool: "hermes", sessionID: "remote-cumulative").reduce(Int64(0)) { $0 + $1.input }, 200,
                       "replay must import the 100-token delta after rollback")
    }

    private func hermesCumulativeRow(input: Int64, id: String) -> [String: Any] {
        let now = Int64(Date().timeIntervalSince1970)
        return ["tool": "hermes", "session_id": "remote-cumulative", "model": "m",
                "first_seen": NSNumber(value: now - 10), "last_seen": NSNumber(value: now),
                "input_tokens": NSNumber(value: input), "output_tokens": NSNumber(value: 0),
                "event_id": id]
    }

    func testSettingsCacheChangesOnlyAfterOutermostTransactionCommits() {
        XCTAssertTrue(db.setSetting("transaction-cache", "old"))
        XCTAssertFalse(db.inTransaction {
            XCTAssertTrue(db.setSetting("transaction-cache", "new"))
            XCTAssertEqual(db.setting("transaction-cache"), "old")
            XCTAssertTrue(db.inTransaction {
                XCTAssertTrue(db.setSetting("transaction-cache", "nested"))
                return true
            })
            XCTAssertEqual(db.setting("transaction-cache"), "old")
            return false
        })
        XCTAssertEqual(db.setting("transaction-cache"), "old")

        XCTAssertTrue(db.inTransaction {
            XCTAssertTrue(db.setSetting("transaction-cache", "committed"))
            XCTAssertEqual(db.setting("transaction-cache"), "old")
            return true
        })
        XCTAssertEqual(db.setting("transaction-cache"), "committed")
    }
    func testClearAllRetainsHermesHighWatermarkAndPreferencesButClearsQuotaSamples() {
        let now = Int64(Date().timeIntervalSince1970)
        XCTAssertTrue(db.setSetting("user_preference", "kept"))
        XCTAssertTrue(db.setSetting("hm_d|remote-cumulative|m||", "100,0,0,0,0,0"))
        XCTAssertTrue(db.setSetting("src_hermes", "remote"))
        XCTAssertTrue(db.insertClaudeQuotaSample(.init(ts: now, weeklyPct: 50, weeklyReset: now + 1000,
                                                       fiveHourPct: 25, fiveHourReset: now + 100)))
        XCTAssertTrue(db.clearAllData())
        XCTAssertTrue(db.claudeQuotaSamples(since: 0).isEmpty)
        XCTAssertEqual(db.claudeQuotaSampleMarker(), "0:0")
        XCTAssertEqual(db.setting("user_preference"), "kept")
        XCTAssertEqual(db.setting("hm_d|remote-cumulative|m||"), "100,0,0,0,0,0")

        HermesRemoteClient.shared.importFeed(["rows": [hermesCumulativeRow(input: 150, id: "post-clear")]], database: db)
        XCTAssertEqual(db.turns(sessionTool: "hermes", sessionID: "remote-cumulative").reduce(Int64(0)) { $0 + $1.input }, 50,
                       "post-clear polling must import only growth beyond retained remote high-water")
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
        let preview = db.previewLocalRebuild(claudePaths: ["/tmp/claude-root/s1.jsonl"], codexPaths: [])
        XCTAssertEqual(preview.turns, 1)
        XCTAssertEqual(preview.sessions, 1)
        XCTAssertEqual(preview.tokens, 17)
        XCTAssertEqual(preview.keptSessions, 0)

        let backup = tmpPath + ".backup"
        defer { try? FileManager.default.removeItem(atPath: backup) }
        XCTAssertTrue(db.backup(to: backup))
        XCTAssertTrue(db.resetLocalUsage(claudePaths: ["/tmp/claude-root/s1.jsonl"], codexPaths: []))
        XCTAssertEqual(db.turnCount(), 0)
        XCTAssertTrue(db.restore(from: backup))
        XCTAssertEqual(db.turnCount(), 1)
    }

    func testRebuildKeepsHistoryWhoseLogIsGoneAndRewindsCowork() {
        func turn(_ tool: ToolKind, _ sid: String) -> TurnRecord {
            TurnRecord(tool: tool, sessionID: sid, project: nil, model: "m", ts: 100,
                       inputTokens: 10, outputTokens: 5, cacheRead: 0, cacheWrite: 0, cost: 1,
                       eventID: "\(tool.rawValue):\(sid):1")
        }
        XCTAssertTrue(db.insertTurns([turn(.claude, "live"), turn(.claude, "gone"), turn(.claude, "cowork"),
                                      turn(.codex, "codex-live"), turn(.codex, "codex-gone")]))
        let cowork = "/tmp/Claude/local-agent-mode-sessions/o/p/local_1/.claude/projects/x/cowork.jsonl"
        let codexLog = "/tmp/rollout-2026-01-01T00-00-00-codex-live.jsonl"
        XCTAssertTrue(db.setScanState(cowork, size: 1152, mtime: 9, identity: 1))
        let claude = ["/tmp/projects/x/live.jsonl", cowork]

        let preview = db.previewLocalRebuild(claudePaths: claude, codexPaths: [codexLog])
        XCTAssertEqual(preview.sessions, 3)
        XCTAssertEqual(preview.keptSessions, 2)
        XCTAssertEqual(preview.keptTokens, 30)

        XCTAssertTrue(db.resetLocalUsage(claudePaths: claude, codexPaths: [codexLog]))
        XCTAssertEqual(db.turnCount(), 2, "only the sessions with no log survive untouched")
        XCTAssertEqual(db.totals(from: 0, to: .max, tool: .claude).count, 1)
        XCTAssertEqual(db.totals(from: 0, to: .max, tool: .codex).count, 1)
        XCTAssertEqual(db.scanState(cowork).size, 0, "Cowork logs must be read again too")
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
        XCTAssertEqual(migrated.setting("usage_recount_v7"), "pending")
    }

    func testUsageRecountReplacesOnlySessionsThatCanBeRebuilt() throws {
        XCTAssertEqual(db.setting("usage_recount_v7"), "pending")
        XCTAssertTrue(db.insertTurns([
            TurnRecord(tool: .claude, sessionID: "s", project: nil, model: "m", ts: 10,
                       inputTokens: 1, outputTokens: 1, cacheRead: 0, cacheWrite: 0, cost: 0,
                       eventID: "claude:s:msg"),
            TurnRecord(tool: .claude, sessionID: "claude", project: nil, model: "m", ts: 10,
                       inputTokens: 1, outputTokens: 1, cacheRead: 0, cacheWrite: 0, cost: 0,
                       eventID: "claude:claude:msg"),
            TurnRecord(tool: .codex, sessionID: "s", project: nil, model: "m", ts: 10,
                       inputTokens: 2, outputTokens: 2, cacheRead: 0, cacheWrite: 0, cost: 0,
                       eventID: "codex:s:evt"),
            TurnRecord(tool: .dsh, sessionID: "s", project: nil, model: "m", ts: 10,
                       inputTokens: 3, outputTokens: 3, cacheRead: 0, cacheWrite: 0, cost: 0,
                       eventID: "dsh-log:s:1:1"),
            TurnRecord(tool: .omp, sessionID: "s", project: nil, model: "m", ts: 10,
                       inputTokens: 4, outputTokens: 4, cacheRead: 0, cacheWrite: 0, cost: 0,
                       eventID: "omp:keep"),
        ]))
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(tmpPath, &raw, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(raw, """
        INSERT INTO turns (tool, session_id, ts, input_tokens, output_tokens, event_id)
        VALUES ('codex', 'legacy-null', 1, 9, 8, NULL);
        """, nil, nil, nil), SQLITE_OK)
        sqlite3_close(raw)
        XCTAssertTrue(db.setScanState("/tmp/claude.jsonl", size: 20, mtime: 20, identity: 3, context: "{\"sid\":\"s\"}"))
        XCTAssertTrue(db.setScanState("/tmp/dsh.jsonl", size: 8, mtime: 8, identity: 4, context: "{}"))

        db.recountMiscountedUsage(claudePaths: ["/tmp/claude.jsonl"], codexPaths: [],
                                  dshPaths: ["/tmp/dsh.jsonl"])
        XCTAssertEqual(db.setting("usage_recount_v7"), "done")
        XCTAssertEqual(db.turns(sessionTool: "claude", sessionID: "claude").count, 0,
                       "the listed transcript's filename is the session that can be rebuilt")
        XCTAssertEqual(db.turns(sessionTool: "claude", sessionID: "s").count, 1,
                       "a session whose log is not in the rescan list stays")
        XCTAssertEqual(db.turns(sessionTool: "codex", sessionID: "s").count, 1)
        XCTAssertEqual(db.turns(sessionTool: "dsh", sessionID: "s").count, 1,
                       "a log with no session id is not deleted")
        XCTAssertEqual(db.turns(sessionTool: "omp", sessionID: "s").count, 1)
        XCTAssertEqual(db.turns(sessionTool: "codex", sessionID: "legacy-null").count, 1)
        XCTAssertEqual(db.scanState("/tmp/claude.jsonl").size, 0)
        XCTAssertEqual(db.scanState("/tmp/claude.jsonl").mtime, 0)
        XCTAssertNil(db.scanState("/tmp/claude.jsonl").context)
        XCTAssertEqual(db.scanState("/tmp/dsh.jsonl").size, 8,
                       "an unidentified DeepSeek log keeps its cursor")

        db.recountMiscountedUsage(claudePaths: ["/tmp/claude.jsonl"], codexPaths: ["/tmp/codex.jsonl"],
                                  dshPaths: ["/tmp/dsh.jsonl"])
        XCTAssertEqual(db.turns(sessionTool: "codex", sessionID: "s").count, 1,
                       "a finished recount must not run again")
    }

    func testRecountKeepsTurnsWhoseSourceLogIsGone() throws {
        let root = NSTemporaryDirectory() + "recount-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        func write(_ path: String, _ text: String) throws {
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                     withIntermediateDirectories: true)
            try Data(text.utf8).write(to: URL(fileURLWithPath: path))
        }
        let claudeLive = "\(root)/projects/enc/a_b.jsonl"
        let claudePrefix = "\(root)/projects/enc/ab.jsonl"
        let claudeSub = "\(root)/projects/enc/gone-parent/subagents/agent-1.jsonl"
        try write(claudeLive, "{}\n")
        try write(claudePrefix, "{}\n")
        try write(claudeSub, "{}\n")

        let codexContext = "\(root)/sessions/2026/10/17/rollout-2026-10-17T01-02-03-file-uuid.jsonl"
        let codexName = "\(root)/sessions/2026/10/17/rollout-2026-10-17T01-02-03-filename-only.jsonl"
        let codexMystery = "\(root)/sessions/not-a-rollout.jsonl"
        try write(codexContext, "{}\n")
        try write(codexName, "{}\n")
        try write(codexMystery, "{}\n")

        let dshHeader = "\(root)/session-decoy/session.jsonl"
        let dshContext = "\(root)/dsh-context/session.jsonl"
        let dshZstd = "\(root)/session-old/session.jsonl.zstd"
        try write(dshHeader, "{\"type\":\"session\",\"id\":\"live-dsh\",\"cwd\":\"/tmp/session-decoy\"}\n")
        try write(dshContext, "{\"type\":\"session\",\"id\":\"header-ignored\"}\n")
        try write(dshZstd, "")

        func row(_ tool: ToolKind, _ session: String, _ event: String) -> TurnRecord {
            TurnRecord(tool: tool, sessionID: session, project: nil, model: "m", ts: 10,
                       inputTokens: 1, outputTokens: 1, cacheRead: 0, cacheWrite: 0, cost: 0,
                       eventID: event)
        }
        XCTAssertTrue(db.insertTurns([
            row(.claude, "old-claude", "claude:old-claude:m"),
            row(.claude, "a_b", "claude:a_b:m"),
            row(.claude, "aXb", "claude:aXb:m"),
            row(.claude, "ab", "claude:ab:m"),
            row(.claude, "abcd", "claude:abcd:m"),
            row(.claude, "gone-parent", "claude:gone-parent:m"),
            row(.codex, "old-codex", "codex:old-codex:m"),
            row(.codex, "context-wins", "codex:context-wins:m"),
            row(.codex, "file-uuid", "codex:file-uuid:m"),
            row(.codex, "filename-only", "codex:filename-only:m"),
            row(.dsh, "old-dsh", "dsh-log:old-dsh:1:1"),
            row(.dsh, "live-dsh", "dsh-log:live-dsh:1:1"),
            row(.dsh, "decoy", "dsh-log:decoy:1:1"),
            row(.dsh, "session-decoy", "dsh-log:session-decoy:1:1"),
            row(.dsh, "context-dsh", "dsh-log:context-dsh:1:1"),
            row(.dsh, "header-ignored", "dsh-log:header-ignored:1:1"),
            row(.omp, "s", "omp:keep"),
        ]))
        XCTAssertTrue(db.setScanState(codexContext, size: 11, mtime: 11, identity: 1, context: "{\"sid\":\"context-wins\"}"))
        XCTAssertTrue(db.setScanState(codexName, size: 16, mtime: 16, identity: 6, context: nil))
        XCTAssertTrue(db.setScanState(codexMystery, size: 12, mtime: 12, identity: 2, context: nil))
        XCTAssertTrue(db.setScanState(dshHeader, size: 17, mtime: 17, identity: 7, context: nil))
        XCTAssertTrue(db.setScanState(dshContext, size: 13, mtime: 13, identity: 3, context: "{\"sid\":\"context-dsh\"}"))
        XCTAssertTrue(db.setScanState(dshZstd, size: 14, mtime: 14, identity: 4, context: nil))
        XCTAssertTrue(db.setScanState(claudeLive, size: 15, mtime: 15, identity: 5, context: nil))
        XCTAssertTrue(db.setScanState(claudePrefix, size: 18, mtime: 18, identity: 8, context: nil))
        XCTAssertTrue(db.setScanState(claudeSub, size: 19, mtime: 19, identity: 9, context: nil))

        db.recountMiscountedUsage(
            claudePaths: [claudeLive, claudePrefix, claudeSub],
            codexPaths: [codexContext, codexName, codexMystery],
            dshPaths: [dshHeader, dshContext, dshZstd])

        func kept(_ tool: String, _ session: String) {
            XCTAssertEqual(db.turns(sessionTool: tool, sessionID: session).count, 1, "\(tool) \(session)")
        }
        func rebuilt(_ tool: String, _ session: String) {
            XCTAssertEqual(db.turns(sessionTool: tool, sessionID: session).count, 0, "\(tool) \(session)")
        }
        kept("claude", "old-claude")
        rebuilt("claude", "a_b")
        kept("claude", "aXb")
        rebuilt("claude", "ab")
        kept("claude", "abcd")
        kept("claude", "gone-parent")
        kept("codex", "old-codex")
        rebuilt("codex", "context-wins")
        kept("codex", "file-uuid")
        rebuilt("codex", "filename-only")
        kept("dsh", "old-dsh")
        rebuilt("dsh", "live-dsh")
        kept("dsh", "decoy")
        kept("dsh", "session-decoy")
        rebuilt("dsh", "context-dsh")
        kept("dsh", "header-ignored")
        kept("omp", "s")

        XCTAssertEqual(db.scanState(claudeLive).size, 0)
        XCTAssertEqual(db.scanState(claudeSub).size, 0)
        XCTAssertEqual(db.scanState(codexContext).size, 0)
        XCTAssertEqual(db.scanState(codexName).size, 0)
        XCTAssertEqual(db.scanState(codexMystery).size, 12)
        XCTAssertEqual(db.scanState(dshHeader).size, 0)
        XCTAssertEqual(db.scanState(dshContext).size, 0)
        XCTAssertEqual(db.scanState(dshZstd).size, 14)

        db.recountMiscountedUsage(claudePaths: [claudeLive], codexPaths: [codexName], dshPaths: [dshHeader])
        kept("claude", "old-claude")
        kept("codex", "old-codex")
        kept("dsh", "old-dsh")
    }

    func testRecountWithNoFilesStillFinishes() {
        XCTAssertTrue(db.insertTurns([
            TurnRecord(tool: .codex, sessionID: "s", project: nil, model: "m", ts: 10,
                       inputTokens: 1, outputTokens: 1, cacheRead: 0, cacheWrite: 0, cost: 0,
                       eventID: "codex:s:evt"),
        ]))
        db.recountMiscountedUsage(claudePaths: [], codexPaths: [], dshPaths: [])
        XCTAssertEqual(db.setting("usage_recount_v7"), "done")
        XCTAssertEqual(db.turns(sessionTool: "codex", sessionID: "s").count, 1)
    }

    func testFreshInstallLeavesCodexAndGrokQuotaOff() {
        XCTAssertNil(db.setting("codex_quota_enabled"))
        XCTAssertNil(db.setting("grok_quota_enabled"))
    }

    func testExistingDatabaseKeepsCodexAndGrokQuotaOn() throws {
        let path = NSTemporaryDirectory() + "quota-migrate-\(UUID().uuidString).db"
        defer {
            try? FileManager.default.removeItem(atPath: path)
            try? FileManager.default.removeItem(atPath: path + "-wal")
            try? FileManager.default.removeItem(atPath: path + "-shm")
        }
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(path, &raw, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(raw, """
        PRAGMA user_version=6;
        CREATE TABLE settings (k TEXT PRIMARY KEY, v TEXT);
        INSERT INTO settings (k, v) VALUES ('codex_quota_enabled', '0');
        """, nil, nil, nil), SQLITE_OK)
        sqlite3_close(raw)

        let migrated = Database.testInstance(path: path)
        defer { migrated.close() }
        XCTAssertEqual(migrated.setting("codex_quota_enabled"), "0",
                       "an explicit off survives the upgrade")
        XCTAssertEqual(migrated.setting("grok_quota_enabled"), "1")
        XCTAssertEqual(migrated.setting("usage_recount_v7"), "pending")
    }

    func testBackfillStampsAComputedZeroInsteadOfRetrying() throws {
        XCTAssertTrue(db.insertTurns([
            TurnRecord(tool: .opencode, sessionID: "free", project: nil, model: "gpt-4o", ts: 10,
                       inputTokens: 0, outputTokens: 0, cacheRead: 0, cacheWrite: 0, cost: 0,
                       costQuality: "estimated"),
            TurnRecord(tool: .opencode, sessionID: "already-zero", project: nil, model: "gpt-4o", ts: 10,
                       inputTokens: 1_000_000, outputTokens: 0, cacheRead: 0, cacheWrite: 0, cost: 0,
                       costQuality: "estimated"),
        ]))
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(tmpPath, &raw, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        let stamp = Pricing.zeroCostStamp.replacingOccurrences(of: "'", with: "''")
        XCTAssertEqual(sqlite3_exec(raw, """
        UPDATE turns SET pricing_version='\(stamp)' WHERE session_id='already-zero';
        """, nil, nil, nil), SQLITE_OK)
        sqlite3_close(raw)

        db.setSetting("backfill_costs_last", nil)
        db.backfillCosts()
        XCTAssertEqual(db.turns(sessionTool: "opencode", sessionID: "free").first?.cost, 0)
        XCTAssertEqual(pricingVersion(session: "free"), Pricing.zeroCostStamp)
        XCTAssertEqual(db.turns(sessionTool: "opencode", sessionID: "already-zero").first?.cost, 0,
                       "a zero stamp is not repriced into a real rate")

        db.setSetting("backfill_costs_last", nil)
        db.backfillCosts()
        XCTAssertEqual(pricingVersion(session: "free"), Pricing.zeroCostStamp)
        XCTAssertEqual(db.turns(sessionTool: "opencode", sessionID: "already-zero").first?.cost, 0)
    }

    private func pricingVersion(session: String) -> String? {
        var raw: OpaquePointer?
        guard sqlite3_open_v2(tmpPath, &raw, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_close(raw) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(raw, "SELECT pricing_version FROM turns WHERE session_id=?;", -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (session as NSString).utf8String, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW, let rawText = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: rawText)
    }

    func testBumpingThePriceTableLeavesStoredCostsAlone() {
        let priced = TurnRecord(tool: .codex, sessionID: "s", project: nil, model: "gpt-5-mini", ts: 10,
                                inputTokens: 1_000_000, outputTokens: 0, cacheRead: 0, cacheWrite: 0,
                                cost: 9, pricingVersion: "1999-01-01", eventID: "codex:s:old")
        XCTAssertTrue(db.insertTurns([priced]))
        db.setSetting("backfill_costs_last", nil)
        db.backfillCosts()
        XCTAssertEqual(db.turns(sessionTool: "codex", sessionID: "s")[0].cost, 9, accuracy: 0.0001)
    }

    func testBackfillCorrectsOnlyModelsWithAWrongTableEntry() {
        let wrong = TurnRecord(tool: .codex, sessionID: "s", project: nil, model: "gpt-5.6-sol", ts: 10,
                               inputTokens: 1_000_000, outputTokens: 0, cacheRead: 0, cacheWrite: 0,
                               cost: 1.25, pricingVersion: "2026-10-27", eventID: "codex:s:1")
        XCTAssertTrue(db.insertTurns([wrong]))
        db.setSetting("backfill_costs_last", nil)
        db.backfillCosts()
        XCTAssertEqual(db.turns(sessionTool: "codex", sessionID: "s")[0].cost, 4, accuracy: 0.0001)
    }

    func testCorrectionKeepsOneHourWritesAndSkipsUnknownSplits() {
        func turn(_ sid: String, split: Int64?) -> TurnRecord {
            TurnRecord(tool: .claude, sessionID: sid, project: nil, model: "claude-sonnet-5-5", ts: 10,
                       inputTokens: 0, outputTokens: 0, cacheRead: 0, cacheWrite: 1_000_000,
                       cacheWrite1h: split, cost: 3.7, pricingVersion: "2026-10-27", eventID: "claude:\(sid):1")
        }
        XCTAssertTrue(db.insertTurns([turn("known", split: 800_000), turn("unknown", split: nil)]))
        db.setSetting("backfill_costs_last", nil)
        db.backfillCosts()
        XCTAssertEqual(db.turns(sessionTool: "claude", sessionID: "known")[0].cost,
                       0.2 * 2.5 + 0.8 * 4, accuracy: 0.0001, "one-hour writes cost 2× input")
        XCTAssertEqual(db.turns(sessionTool: "claude", sessionID: "unknown")[0].cost, 3.7, accuracy: 0.0001,
                       "the five-minute rate would silently lower this")
    }

    func testReplayFillsTheOneHourShareWithoutAddingRows() {
        let old = TurnRecord(tool: .claude, sessionID: "s", project: nil, model: "claude-opus-5-5", ts: 10,
                             inputTokens: 1, outputTokens: 1, cacheRead: 0, cacheWrite: 1_000, cost: 1,
                             pricingVersion: "2026-10-27", eventID: "claude:s:m", usageMerge: .keepGreater)
        XCTAssertTrue(db.insertTurns([old]))
        XCTAssertEqual(db.setting("cache_split_replay"), "pending")
        XCTAssertTrue(db.setScanState("/tmp/s.jsonl", size: 10, mtime: 1, identity: 1))
        db.replayClaudeForCacheSplit(paths: ["/tmp/s.jsonl"])
        XCTAssertEqual(db.scanState("/tmp/s.jsonl").size, 0)
        XCTAssertEqual(db.setting("cache_split_replay"), "done")
        XCTAssertTrue(db.setScanState("/tmp/s.jsonl", size: 10, mtime: 1, identity: 1))
        db.replayClaudeForCacheSplit(paths: ["/tmp/s.jsonl"])
        XCTAssertEqual(db.scanState("/tmp/s.jsonl").size, 10, "runs once")

        let parsed = TurnRecord(tool: .claude, sessionID: "s", project: nil, model: "claude-opus-5-5", ts: 10,
                                inputTokens: 1, outputTokens: 1, cacheRead: 0, cacheWrite: 1_000,
                                cacheWrite1h: 1_000, cost: 0.008, eventID: "claude:s:m", usageMerge: .keepGreater)
        XCTAssertTrue(db.insertTurns([parsed]))
        XCTAssertEqual(db.turnCount(), 1)
        XCTAssertEqual(db.turns(sessionTool: "claude", sessionID: "s")[0].cost, 0.008, accuracy: 0.00001)
        XCTAssertEqual(db.rollupMismatchCount(), 0)
    }

    /// Value and Estimated Cost must agree: same split and tier, row or sum.
    func testAPIValueMatchesPerRowPricingAcrossTiers() {
        func turn(_ i: Int, input: Int64, read: Int64, write: Int64, write1h: Int64) -> TurnRecord {
            let cost = Pricing.estimate(model: "claude-haiku-5-5", input: input, output: 10, cacheRead: read,
                                        cacheWrite: write - write1h, cacheWrite1h: write1h)!
            return TurnRecord(tool: .claude, sessionID: "s", project: nil, model: "claude-haiku-5-5", ts: 1_000 + Int64(i),
                              inputTokens: input, outputTokens: 10, cacheRead: read, cacheWrite: write,
                              cacheWrite1h: write1h, cost: cost, eventID: "claude:s:\(i)")
        }
        let rows = [turn(0, input: 10, read: 50_000, write: 1_000, write1h: 500),
                    turn(1, input: 10, read: 150_000, write: 1_000, write1h: 1_000),
                    turn(2, input: 90_000, read: 9_000, write: 2_000, write1h: 0)]
        XCTAssertTrue(db.insertTurns(rows))
        let expected = rows.reduce(0) { $0 + $1.cost }
        XCTAssertEqual(db.apiValue(from: 0, to: .max), expected, accuracy: 1e-9)
        XCTAssertEqual(db.apiValue(from: 1_000, to: 1_001, tool: "claude"), rows[0].cost + rows[1].cost, accuracy: 1e-9)
        XCTAssertEqual(db.rollupMismatchCount(), 0)
    }

    func testSessionWithoutADateUsesItsLastTurnAndStubsAreHidden() {
        func session(_ id: String) -> SessionInfo {
            SessionInfo(tool: .codex, sessionID: id, title: nil, project: nil, model: nil, created: 0, updated: 0)
        }
        XCTAssertTrue(db.upsertSessions([session("used"), session("stub")]))
        XCTAssertTrue(db.insertTurns([TurnRecord(tool: .codex, sessionID: "used", project: nil, model: "m", ts: 5_000,
                                                 inputTokens: 1, outputTokens: 1, cacheRead: 0, cacheWrite: 0,
                                                 cost: 0, eventID: "e1")]))
        let rows = db.sessions()
        XCTAssertEqual(rows.map(\.sessionID), ["used"])
        XCTAssertEqual(rows.first?.updated, 5_000)
        XCTAssertEqual(db.sessionCount(), 1)
        XCTAssertEqual(db.sessionCount(tool: .claude), 0)
    }

    func testCodexCoveredBySubscriptionCostsNothingEverywhere() {
        let now = Int64(Date().timeIntervalSince1970)
        XCTAssertTrue(db.upsertSessions([SessionInfo(tool: .codex, sessionID: "s", title: nil, project: nil,
                                                     model: "m", created: now, updated: now)]))
        XCTAssertTrue(db.insertTurns([TurnRecord(tool: .codex, sessionID: "s", project: nil, model: "m", ts: now,
                                                 inputTokens: 1, outputTokens: 1, cacheRead: 0, cacheWrite: 0,
                                                 cost: 5, eventID: "e1")]))
        XCTAssertEqual(db.modelAggregates(from: 0, to: .max).first?.cost ?? 0, 5, accuracy: 0.001)
        db.setSetting("codex_billing_mode", "subscription")
        XCTAssertEqual(db.modelAggregates(from: 0, to: .max).first?.cost ?? 1, 0, accuracy: 0.001)
        XCTAssertEqual(db.dailyAggregates(days: 2).first?.cost ?? 1, 0, accuracy: 0.001)
        XCTAssertEqual(db.dailyAggregatesByModel(days: 2).first?.cost ?? 1, 0, accuracy: 0.001)
        XCTAssertEqual(db.sessions().first?.cost ?? 1, 0, accuracy: 0.001)
        XCTAssertEqual(db.turns(sessionTool: "codex", sessionID: "s").first?.cost ?? 1, 0, accuracy: 0.001)
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

// MARK: - 快照缓存失效键（P0 回归：data_version 设置缺失时键曾恒为 "err"，
// 快照缓存永不失效，UI 冻结在首次快照；见 toastmonitor db scan 诊断）

extension DatabaseTests {
    func testDataVersionKeyNeverErrsWithoutDataVersionRow() {
        // 全新 DB 没有 data_version 行；键必须仍是有效字符串。
        let key = db.dataVersionKey()
        XCTAssertNotEqual(key, "err", "missing data_version row must not poison the cache key")
        XCTAssertNotEqual(key, "closed")
        XCTAssertTrue(key.contains("|"), "key must be the concatenated version stamp")
    }

    func testDataVersionKeyChangesWhenTurnsInserted() {
        let before = db.dataVersionKey()
        let t = TurnRecord(tool: .codex, sessionID: "s1", project: nil, model: "gpt-5.6-sol",
                           ts: Int64(Date().timeIntervalSince1970), inputTokens: 10, outputTokens: 5,
                           cacheRead: 0, cacheWrite: 0, cost: 0)
        XCTAssertTrue(db.insertTurns([t]))
        let after = db.dataVersionKey()
        XCTAssertNotEqual(after, before, "inserting turns must invalidate the snapshot cache key")
        XCTAssertNotEqual(after, "err")
    }
}

// MARK: - DB-1/DB-3/DB-5/DB-6/DB-7/DB-8 regression tests

extension DatabaseTests {
    /// DB-1: delete paths that do not move MAX(id) must still invalidate the
    /// snapshot-cache key via the `data_version` bump. resetLocalUsage deletes
    /// only the codex rows while a claude row keeps MAX(id) untouched — with
    /// the MAX(id)-based turns key and no bump, the key would not change.
    func testDataVersionKeyChangesAfterResetAndClear() {
        let now = Int64(Date().timeIntervalSince1970)
        let codex = TurnRecord(tool: .codex, sessionID: "s-codex", project: nil, model: "m",
                               ts: now, inputTokens: 10, outputTokens: 5,
                               cacheRead: 0, cacheWrite: 0, cost: 0, eventID: "c1")
        let claude = TurnRecord(tool: .claude, sessionID: "s-claude", project: nil, model: "m",
                                ts: now + 1, inputTokens: 20, outputTokens: 5,
                                cacheRead: 0, cacheWrite: 0, cost: 0, eventID: "c2")
        XCTAssertTrue(db.insertTurns([codex, claude]))
        let keyAfterInsert = db.dataVersionKey()

        XCTAssertTrue(db.resetLocalUsage(claudePaths: [],
                                         codexPaths: ["/tmp/rollout-2026-01-01T00-00-00-s-codex.jsonl"]))
        XCTAssertNotEqual(db.dataVersionKey(), keyAfterInsert,
                          "resetLocalUsage must invalidate the snapshot cache key (DB-1)")

        XCTAssertTrue(db.clearAllData())
        XCTAssertNotEqual(db.dataVersionKey(), keyAfterInsert,
                          "clearAllData must invalidate the snapshot cache key (DB-1)")
    }

    /// DB-3: after a successful restore the connection is re-opened so
    /// migrate()/ensureBaseTables() re-run against the restored (possibly
    /// older) schema. A v1-era store missing the v3 columns must work again
    /// once restored.
    func testRestoreRemigratesOlderSchema() throws {
        let legacyPath = tmpPath + "-v1-schema.db"
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
          tool TEXT NOT NULL, session_id TEXT NOT NULL, project TEXT, model TEXT,
          ts INTEGER NOT NULL, input_tokens INTEGER NOT NULL DEFAULT 0,
          output_tokens INTEGER NOT NULL DEFAULT 0, reasoning_tokens INTEGER NOT NULL DEFAULT 0,
          cache_read INTEGER NOT NULL DEFAULT 0, cache_write INTEGER NOT NULL DEFAULT 0,
          cost REAL NOT NULL DEFAULT 0, provider TEXT,
          source_instance TEXT NOT NULL DEFAULT 'local', pricing_version TEXT,
          event_id TEXT, cost_quality TEXT NOT NULL DEFAULT 'estimated'
        );
        CREATE TABLE sessions (
          tool TEXT NOT NULL, session_id TEXT NOT NULL, title TEXT, project TEXT, model TEXT,
          created INTEGER NOT NULL DEFAULT 0, updated INTEGER NOT NULL DEFAULT 0,
          PRIMARY KEY(tool, session_id)
        );
        CREATE TABLE scan_state (
          source TEXT PRIMARY KEY, size INTEGER NOT NULL DEFAULT 0,
          mtime INTEGER NOT NULL DEFAULT 0, last_scan INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE session_totals (
          tool TEXT NOT NULL, session_id TEXT NOT NULL, input INTEGER NOT NULL DEFAULT 0,
          output INTEGER NOT NULL DEFAULT 0, cache_read INTEGER NOT NULL DEFAULT 0,
          cache_write INTEGER NOT NULL DEFAULT 0, cost REAL NOT NULL DEFAULT 0,
          updated INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(tool, session_id)
        );
        CREATE TABLE openrouter_snapshots (
          ts INTEGER PRIMARY KEY, usage REAL NOT NULL DEFAULT 0, usage_daily REAL NOT NULL DEFAULT 0,
          usage_weekly REAL NOT NULL DEFAULT 0, usage_monthly REAL NOT NULL DEFAULT 0,
          limit_amount REAL, limit_remaining REAL, limit_reset TEXT,
          is_free_tier INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE opencodego_snapshots (
          ts INTEGER PRIMARY KEY, rolling_pct REAL, rolling_reset INTEGER,
          weekly_pct REAL, weekly_reset INTEGER, monthly_pct REAL, monthly_reset INTEGER
        );
        CREATE TABLE subscriptions (
          id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL,
          plan TEXT NOT NULL DEFAULT '', start_date INTEGER NOT NULL DEFAULT 0,
          cycle TEXT NOT NULL DEFAULT 'monthly', price REAL NOT NULL DEFAULT 0,
          currency TEXT NOT NULL DEFAULT 'USD'
        );
        CREATE TABLE settings (k TEXT PRIMARY KEY, v TEXT);
        PRAGMA user_version=1;
        """
        XCTAssertEqual(sqlite3_exec(raw, schema, nil, nil, nil), SQLITE_OK)
        sqlite3_close(raw)

        XCTAssertTrue(db.restore(from: legacyPath), "restore of a valid older store must succeed")

        // Re-opening re-ran the migrations: the v3-only columns exist again.
        XCTAssertTrue(db.setScanState("src", size: 1, mtime: 2, identity: 3),
                      "restored schema must be re-migrated so scan_state.identity exists (DB-3)")
        XCTAssertEqual(db.scanState("src").identity, 3)
        XCTAssertEqual(db.diagnosticsSummary()["user_version"] as? Int32, Database.schemaVersion,
                       "restore must re-run migrations against the restored file (DB-3)")
        XCTAssertTrue(db.upsertSubscription(Database.Subscription(id: 0, name: "X", plan: "",
                                                                  startDate: 1_700_000_000, cycle: "monthly",
                                                                  price: 10, currency: "USD")),
                      "subscriptions.end_date must be re-added by the re-run migration (DB-3)")
    }

    /// DB-5: backup destinations are created private (0600) and must be real
    /// SQLite files; non-SQLite leftovers are excluded from backup discovery.
    func testBackupFileIsPrivateSQLiteAndRoundTrips() throws {
        XCTAssertTrue(db.insertTurns([TurnRecord(tool: .claude, sessionID: "s1", project: nil, model: "m",
                                                 ts: 100, inputTokens: 10, outputTokens: 5,
                                                 cacheRead: 0, cacheWrite: 0, cost: 0)]))
        let dest = tmpPath + ".backup"
        defer { try? FileManager.default.removeItem(atPath: dest) }
        XCTAssertTrue(db.backup(to: dest))
        let attrs = try FileManager.default.attributesOfItem(atPath: dest)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? -1
        XCTAssertEqual(perms & 0o777, 0o600, "backup file must be private, never world-readable (DB-5)")
        let head = try Data(contentsOf: URL(fileURLWithPath: dest)).prefix(16)
        XCTAssertEqual(head, Data("SQLite format 3\u{0}".utf8), "backup must be a real SQLite database (DB-5)")
        XCTAssertTrue(db.restore(from: dest), "backup must round-trip through restore")
        XCTAssertEqual(db.turnCount(), 1)
    }

    /// DB-5: backup discovery skips non-SQLite leftovers (partial/aborted
    /// writes, foreign files) so rotation cannot be polluted by them.
    func testBackupDiscoverySkipsNonSQLiteLeftovers() throws {
        let dir = NSTemporaryDirectory() + "tm-backups-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let garbage = dir + "/garbage.db"
        try Data("not a sqlite database at all, just leftover bytes".utf8).write(to: URL(fileURLWithPath: garbage))
        XCTAssertFalse(DataMaintenance.isSQLiteFile(URL(fileURLWithPath: garbage)),
                       "non-SQLite leftovers must be excluded from the backup list (DB-5)")

        XCTAssertTrue(db.insertTurns([TurnRecord(tool: .claude, sessionID: "s1", project: nil, model: "m",
                                                 ts: 100, inputTokens: 10, outputTokens: 5,
                                                 cacheRead: 0, cacheWrite: 0, cost: 0)]))
        let real = dir + "/real.db"
        XCTAssertTrue(db.backup(to: real))
        XCTAssertTrue(DataMaintenance.isSQLiteFile(URL(fileURLWithPath: real)))
    }

    /// DB-6: hostile/malformed parser values are clamped at the boundary —
    /// negative tokens and non-finite cost become 0, oversized values cap.
    func testTurnRecordClampsTokensAndCost() {
        let t = TurnRecord(tool: .codex, sessionID: "s1", project: nil, model: "m",
                           ts: 100, inputTokens: -50, outputTokens: -10, reasoningTokens: -5,
                           cacheRead: -20, cacheWrite: -2, cost: .nan)
        XCTAssertEqual(t.inputTokens, 0)
        XCTAssertEqual(t.outputTokens, 0)
        XCTAssertEqual(t.reasoningTokens, 0)
        XCTAssertEqual(t.cacheRead, 0)
        XCTAssertEqual(t.cacheWrite, 0)
        XCTAssertEqual(t.cost, 0)

        let capped = TurnRecord(tool: .codex, sessionID: "s2", project: nil, model: "m",
                                ts: 200, inputTokens: TurnRecord.maxTokens + 1,
                                outputTokens: 1, cacheRead: 0, cacheWrite: 0,
                                cost: 2_000_000_000)
        XCTAssertEqual(capped.inputTokens, TurnRecord.maxTokens)
        XCTAssertEqual(capped.cost, TurnRecord.maxCost)

        // Totals stay sane after a real insert.
        XCTAssertTrue(db.insertTurns([t, capped]))
        let totals = db.totals(from: 0, to: 1_000_000)
        XCTAssertEqual(totals.count, 2)
        XCTAssertEqual(totals.input, TurnRecord.maxTokens)
        XCTAssertEqual(totals.cost, TurnRecord.maxCost, accuracy: 0.001)
    }

    /// DB-7: quota-snapshot tables are bounded — rows older than 400 days are
    /// pruned by the retention helper.
    func testSnapshotRetentionPrunesOlderThan400Days() {
        let now = Int64(Date().timeIntervalSince1970)
        let old = now - 401 * 86400
        let recent = now - 100 * 86400
        // Warm the auto-prune throttle (inserts prune at most once/hour when
        // unset) so the fixtures below are not pruned on arrival; this test
        // drives pruneOldSnapshots explicitly.
        db.setSetting("snapshot_prune_last", "\(now)")
        let snap = { (ts: Int64) in Database.ORSnapshot(ts: ts, usage: 1, usageDaily: 1, usageWeekly: 1,
                                                        usageMonthly: 1, limit: nil, limitRemaining: nil,
                                                        limitReset: nil, isFreeTier: false, creditsTotal: nil,
                                                        creditsUsage: nil, accountUsage: nil, accountBalance: nil,
                                                        isManagementKey: false) }
        XCTAssertTrue(db.insertORSnapshot(snap(old)))
        XCTAssertTrue(db.insertORSnapshot(snap(recent)))
        let og = { (ts: Int64) in Database.OGSnapshot(ts: ts, rollingPct: 1, rollingReset: ts,
                                                      weeklyPct: 1, weeklyReset: ts, monthlyPct: 1, monthlyReset: ts) }
        XCTAssertTrue(db.insertOGSnapshot(og(old)))
        XCTAssertTrue(db.insertOGSnapshot(og(recent)))
        XCTAssertEqual(db.orSnapshots(limit: 100).count, 2)
        XCTAssertEqual(db.ogSnapshots(limit: 100).count, 2)

        db.pruneOldSnapshots(now: now)
        XCTAssertEqual(db.orSnapshots(limit: 100).count, 1)
        XCTAssertEqual(db.orSnapshots(limit: 100).first?.ts, recent)
        XCTAssertEqual(db.ogSnapshots(limit: 100).count, 1)
        XCTAssertEqual(db.ogSnapshots(limit: 100).first?.ts, recent)
    }

    /// DB-7: the snapshot insert paths prune at most once per hour
    /// (settings-key throttle, same pattern as backfillCosts).
    func testSnapshotPruneThrottledToOncePerHourOnInsert() {
        let now = Int64(Date().timeIntervalSince1970)
        let old = now - 401 * 86400
        let snap = Database.ORSnapshot(ts: old, usage: 1, usageDaily: 1, usageWeekly: 1,
                                       usageMonthly: 1, limit: nil, limitRemaining: nil, limitReset: nil,
                                       isFreeTier: false, creditsTotal: nil, creditsUsage: nil,
                                       accountUsage: nil, accountBalance: nil, isManagementKey: false)
        // Throttle armed: inserting an old row must NOT prune.
        XCTAssertTrue(db.setSetting("snapshot_prune_last", "\(now)"))
        XCTAssertTrue(db.insertORSnapshot(snap))
        XCTAssertEqual(db.orSnapshots(limit: 100).count, 1)

        // Throttle expired: the next insert prunes the old row.
        XCTAssertTrue(db.setSetting("snapshot_prune_last", "0"))
        XCTAssertTrue(db.insertORSnapshot(.init(ts: now, usage: 2, usageDaily: 2, usageWeekly: 2,
                                                usageMonthly: 2, limit: nil, limitRemaining: nil, limitReset: nil,
                                                isFreeTier: false, creditsTotal: nil, creditsUsage: nil,
                                                accountUsage: nil, accountBalance: nil, isManagementKey: false)))
        let remaining = db.orSnapshots(limit: 100)
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.ts, now)
    }

}
