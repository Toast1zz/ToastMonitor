import AppKit
import SQLite3
import SwiftUI
import XCTest
@testable import ToastMonitor

final class AuditPostFixPolishTests: XCTestCase {
    private var dbPath = ""
    private var db: Database!

    override func setUp() {
        super.setUp()
        dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("tm-postfix-\(UUID().uuidString).sqlite").path
        db = Database.testInstance(path: dbPath)
    }

    override func tearDown() {
        db.close()
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: dbPath + suffix)
        }
        super.tearDown()
    }

    @MainActor
    func testCLIRenewalRetryActiveStateAndRescheduleInsideCallback() {
        let retry = CLIRenewalRetry(interval: 0.02)
        XCTAssertFalse(retry.hasActiveRetry)

        let firstFired = expectation(description: "first callback runs")
        let secondFired = expectation(description: "rescheduled callback runs")
        retry.schedule(counting: true) {
            firstFired.fulfill()
            retry.schedule(counting: false) {
                secondFired.fulfill()
            }
        }
        XCTAssertTrue(retry.hasActiveRetry)
        wait(for: [firstFired, secondFired], timeout: 2.0)
        retry.reset()
        XCTAssertFalse(retry.hasActiveRetry)
    }

    func testQuotaParsersRejectCFBooleanValues() {
        XCTAssertNil(CommandCodeQuotaClient.boundedAmount(kCFBooleanTrue))
        XCTAssertEqual(CommandCodeQuotaClient.boundedAmount(12.5), 12.5)

        let credJSON = Data(#"{"claudeAiOauth":{"accessToken":"tok-abc","expiresAt":true}}"#.utf8)
        let creds = ClaudeQuotaClient.parseCredentials(credJSON)
        XCTAssertEqual(creds?.accessToken, "tok-abc")
        XCTAssertNil(creds?.expiresAt)

        let usage = ClaudeQuotaClient.parseUsage([
            "five_hour": ["utilization": kCFBooleanTrue as Any, "resets_at": kCFBooleanTrue as Any],
            "seven_day": ["utilization": 42, "resets_at": 1_800_000_000],
        ])
        XCTAssertNil(usage.fiveHour)
        XCTAssertEqual(usage.sevenDay?.usedPercent, 42)
        XCTAssertEqual(usage.sevenDay?.resetAt, 1_800_000_000)
    }

    func testSQLiteReadOnlyRejectsNonENOENTWalStatAndAllowsAbsentWal() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tm-wal-ro-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let target = dir.appendingPathComponent("source.db").path
        let local = Database.testInstance(path: target)
        XCTAssertTrue(local.isOpen)
        local.close()
        // sqlite3_close_v2 can leave -wal/-shm behind; clear them so the
        // directory permission test exercises SQLITE_CANTOPEN -> immutable=1.
        try? FileManager.default.removeItem(atPath: target + "-shm")
        try? FileManager.default.removeItem(atPath: target + "-wal")

        let walPath = target + "-wal"
        if geteuid() != 0 {
            // Read-only directory forces SQLITE_OPEN_READONLY into the immutable=1
            // fallback path because SQLite cannot create `-shm`.
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }

            // No -wal exists (ENOENT): immutable fallback succeeds.
            let handle = SQLiteReadOnly.open(target)
            XCTAssertNotNil(handle)
            if let handle { sqlite3_close(handle) }

            // Non-empty -wal exists: immutable=1 must be rejected.
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            try Data(repeating: 0x01, count: 32).write(to: URL(fileURLWithPath: walPath))
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
            if let opened = SQLiteReadOnly.open(target) {
                sqlite3_close(opened)
                XCTFail("Expected nil when non-empty -wal exists")
            }

            // Unreadable empty -wal (chmod 000): must also fail closed.
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            try Data().write(to: URL(fileURLWithPath: walPath))
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: walPath)
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
            defer {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: walPath)
            }
            if let opened = SQLiteReadOnly.open(target) {
                sqlite3_close(opened)
                XCTFail("Expected nil when -wal is unreadable")
            }
        }
    }

    func testReadOnlyDatabaseReportsReadOnlyProblemNotDamaged() throws {
        let roPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("tm-ro-db-\(UUID().uuidString).sqlite").path
        let writer = Database.testInstance(path: roPath)
        XCTAssertTrue(writer.isHealthyOpen)
        writer.close()

        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: roPath)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: roPath)
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: roPath + suffix)
            }
        }

        if geteuid() != 0 {
            let ro = Database.testInstance(path: roPath)
            defer { ro.close() }
            if case .readOnly? = ro.openProblem {
                XCTAssertTrue(ro.isReadableOpen)
                XCTAssertFalse(ro.isHealthyOpen)
            } else {
                XCTFail("Expected .readOnly openProblem, got \(String(describing: ro.openProblem))")
            }
        }
    }

    func testGreaterMergeCacheWrite1hClearsStalePricingVersionAndBackfillRepricesClaude() throws {
        let now: Int64 = 1_750_000_000
        let first = TurnRecord(
            tool: .claude, sessionID: "s1", project: "p", model: "claude-sonnet-4-6",
            ts: now, inputTokens: 100, outputTokens: 0, cacheRead: 0, cacheWrite: 100,
            cacheWrite1h: 80, cost: Pricing.estimate(model: "claude-sonnet-4-6", input: 100, output: 0, cacheRead: 0, cacheWrite: 100, cacheWrite1h: 80) ?? 0,
            eventID: "c1", costQuality: "estimated", usageMerge: .keepGreater
        )
        let second = TurnRecord(
            tool: .claude, sessionID: "s1", project: "p", model: "claude-sonnet-4-6",
            ts: now + 1, inputTokens: 200, outputTokens: 0, cacheRead: 0, cacheWrite: 100,
            cacheWrite1h: 20, cost: Pricing.estimate(model: "claude-sonnet-4-6", input: 200, output: 0, cacheRead: 0, cacheWrite: 100, cacheWrite1h: 20) ?? 0,
            eventID: "c1", costQuality: "estimated", usageMerge: .keepGreater
        )
        let unversionedClaude = TurnRecord(
            tool: .claude, sessionID: "s2", project: "p", model: "claude-sonnet-4-6",
            ts: now + 2, inputTokens: 1_000, outputTokens: 500, cacheRead: 0, cacheWrite: 100,
            cacheWrite1h: nil, cost: 999.0, pricingVersion: nil, eventID: "c2",
            costQuality: "estimated", usageMerge: .ignore
        )

        XCTAssertTrue(db.insertTurns([first]))
        XCTAssertTrue(db.insertTurns([second, unversionedClaude]))

        db.backfillCosts()

        let expectedC1 = Pricing.estimate(model: "claude-sonnet-4-6", input: 200, output: 0,
                                          cacheRead: 0, cacheWrite: 20, cacheWrite1h: 80)!
        let expectedC2 = Pricing.estimate(model: "claude-sonnet-4-6", input: 1_000, output: 500,
                                          cacheRead: 0, cacheWrite: 100)!
        let totals = db.totals(from: 0, to: now + 100, tool: .claude)
        XCTAssertEqual(totals.cost, expectedC1 + expectedC2, accuracy: 1e-9)
        XCTAssertEqual(db.rollupMismatchCount(), 0)
    }

    func testRollupLongPromptMatchesPricingVariantsAndExcludesMiniNanoCyber() {
        let now: Int64 = 1_750_000_000
        let bigPrompt: Int64 = 300_000
        let models = ["gpt-5.4-thinking", "gpt-5.4-mini", "gpt-5.6-cyber"]
        let turns = models.enumerated().map { idx, model in
            TurnRecord(
                tool: .opencode, sessionID: "lp-\(idx)", project: "p", model: model,
                ts: now + Int64(idx), inputTokens: bigPrompt, outputTokens: 100,
                cacheRead: 0, cacheWrite: 0,
                cost: Pricing.estimate(model: model, input: bigPrompt, output: 100, cacheRead: 0, cacheWrite: 0) ?? 0,
                eventID: "lp-\(idx)", costQuality: "estimated"
            )
        }
        XCTAssertTrue(db.insertTurns(turns))
        XCTAssertEqual(db.rollupMismatchCount(), 0)
    }

    func testBalanceSeriesEpochsAcceptSameSecondPostResetSamples() {
        db.insertDeepSeekBalance(currency: "CNY", amount: 10.0, ts: 5_000)
        XCTAssertTrue(db.beginDeepSeekBalanceSeries(at: 5_000))
        XCTAssertTrue(db.deepSeekBalances(currency: "CNY", since: 0).isEmpty)
        db.insertDeepSeekBalance(currency: "CNY", amount: 10.0, ts: 5_000)
        XCTAssertEqual(db.deepSeekBalances(currency: "CNY", since: 0).map(\.value), [10.0])

        let snap = Database.ORSnapshot(
            ts: 5_000, usage: 5, usageDaily: 1, usageWeekly: 1, usageMonthly: 1,
            limit: nil, limitRemaining: nil, limitReset: nil, isFreeTier: false,
            creditsTotal: 100, creditsUsage: 5, accountUsage: 5, accountBalance: 95,
            isManagementKey: false
        )
        XCTAssertTrue(db.insertORSnapshot(snap))
        XCTAssertTrue(db.beginOpenRouterCreditSeries(at: 5_000))
        XCTAssertTrue(db.orCreditUsage(since: 0).isEmpty)
        XCTAssertTrue(db.insertORSnapshot(snap))
        XCTAssertEqual(db.orCreditUsage(since: 0).count, 1)
    }

    func testFormatMoneyExtremeMagnitudeAndNegativeSubPrecisionZero() {
        let huge = Format.money(1e100)
        XCTAssertNotEqual(huge, "$0.00")
        XCTAssertFalse(huge.lowercased().contains("inf"))
        XCTAssertFalse(huge.lowercased().contains("nan"))

        let hugeShort = Format.moneyShort(1e100)
        XCTAssertNotEqual(hugeShort, "$0.00")
        XCTAssertFalse(hugeShort.lowercased().contains("inf"))
        XCTAssertFalse(hugeShort.lowercased().contains("nan"))

        XCTAssertEqual(Format.money(-0.00001), "$0.00")
        XCTAssertEqual(Format.moneyShort(-0.0001), "$0.00")
    }

    func testSessionSearchMatchesModelPunctuationAndInsertTurnsCountingPerTool() {
        let now: Int64 = 1_750_000_000
        XCTAssertTrue(db.upsertSessions([
            SessionInfo(tool: .claude, sessionID: "s-punct", title: "Alpha", project: "Proj",
                        model: "claude-sonnet-4-6", created: now, updated: now),
        ]))
        XCTAssertEqual(db.sessionCount(search: "sonnet 4.6"), 1)
        XCTAssertEqual(db.sessionCount(search: "sonnet_4_6"), 1)

        let existing = TurnRecord(
            tool: .claude, sessionID: "s-punct", project: "Proj", model: "claude-sonnet-4-6",
            ts: now, inputTokens: 10, outputTokens: 5, cacheRead: 0, cacheWrite: 0,
            cost: 0.01, eventID: "e-existing", costQuality: "estimated"
        )
        XCTAssertTrue(db.insertTurns([existing]))

        let codex1 = TurnRecord(
            tool: .codex, sessionID: "c-1", project: "Proj", model: "gpt-5.4",
            ts: now + 1, inputTokens: 20, outputTokens: 10, cacheRead: 0, cacheWrite: 0,
            cost: 0.02, eventID: "e-codex-1", costQuality: "estimated"
        )
        let codex2 = TurnRecord(
            tool: .codex, sessionID: "c-2", project: "Proj", model: "gpt-5.4",
            ts: now + 2, inputTokens: 30, outputTokens: 15, cacheRead: 0, cacheWrite: 0,
            cost: 0.03, eventID: "e-codex-2", costQuality: "estimated"
        )
        let res = db.insertTurnsCounting([existing, codex1, codex2])
        XCTAssertTrue(res.ok)
        XCTAssertEqual(res.changed, 2)
        XCTAssertEqual(res.changedByTool, ["codex": 2])
    }

    func testOmpRootPrefixBoundaryAndDSHIncrementalPreservesCreated() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tm-omp-root-\(UUID().uuidString)")
        let sessionsDir = root.appendingPathComponent("sessions")
        let siblingDir = root.appendingPathComponent("sessions-extra/sub")
        let insideDir = sessionsDir.appendingPathComponent("proj")
        try FileManager.default.createDirectory(at: siblingDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: insideDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let line = #"{"type":"session","id":"omp-s1","cwd":"/tmp/app"}"# + "\n"
            + #"{"type":"message","id":"m1","timestamp":"2026-08-05T10:00:00Z","message":{"role":"assistant","model":"claude-sonnet-4-6","usage":{"input":10,"output":5,"cacheRead":0,"cacheWrite":0}}}"# + "\n"
        let siblingFile = siblingDir.appendingPathComponent("sib.jsonl").path
        let insideFile = insideDir.appendingPathComponent("in.jsonl").path
        try line.write(toFile: siblingFile, atomically: true, encoding: .utf8)
        try line.write(toFile: insideFile, atomically: true, encoding: .utf8)

        let ompTurns = TestEnvironment.withVariable("TM_OMP_SESSIONS_ROOT", value: sessionsDir.path) {
            OmpParser.scan(knownPaths: [siblingFile, insideFile], database: db).turns
        }
        XCTAssertEqual(ompTurns.count, 2)
        XCTAssertTrue(ompTurns.contains { $0.eventID == "omp:sib.jsonl:m1" })
        XCTAssertTrue(ompTurns.contains { $0.eventID == "omp:proj/in.jsonl:m1" })

        let dshDir = root.appendingPathComponent("dsh")
        try FileManager.default.createDirectory(at: dshDir, withIntermediateDirectories: true)
        let dshFile = dshDir.appendingPathComponent("sess.jsonl").path
        let part1 = #"{"type":"session","version":0,"id":"dsh-created-s1","createdAt":1786628702000,"cwd":"/tmp/dsh"}"# + "\n"
            + #"{"type":"step/start","seq":1,"time":1786628702500,"data":{"turn":1,"step":1}}"# + "\n"
            + #"{"type":"assistant/chunk","seq":2,"time":1786628704000,"data":{"turn":1,"step":1,"chunk":{"type":"usage","usage":{"inputTokens":100,"outputTokens":20}}}}"# + "\n"
            + #"{"type":"assistant/message","seq":3,"time":1786628704100,"data":{"turn":1,"step":1,"message":{"role":"assistant","content":[]}}}"# + "\n"
        try part1.write(toFile: dshFile, atomically: true, encoding: .utf8)

        let first = DSHParser.scanLogs(knownPaths: [dshFile], database: db)
        XCTAssertEqual(first.sessions.first?.created, 1_786_628_702)

        let part2 = part1
            + #"{"type":"step/start","seq":4,"time":1786628710000,"data":{"turn":1,"step":2}}"# + "\n"
            + #"{"type":"assistant/chunk","seq":5,"time":1786628711000,"data":{"turn":1,"step":2,"chunk":{"type":"usage","usage":{"inputTokens":200,"outputTokens":40}}}}"# + "\n"
            + #"{"type":"assistant/message","seq":6,"time":1786628711100,"data":{"turn":1,"step":2,"message":{"role":"assistant","content":[]}}}"# + "\n"
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: dshFile))
        try handle.seekToEnd()
        let appendData = Data(part2.dropFirst(part1.count).utf8)
        try handle.write(contentsOf: appendData)
        try handle.close()

        let second = DSHParser.scanLogs(knownPaths: [dshFile], database: db)
        XCTAssertEqual(second.sessions.count, 1)
        XCTAssertEqual(second.sessions.first?.created, 1_786_628_702)
    }

    @MainActor
    func testSubscriptionFormTextFieldsAdvanceCaretOnTrailingSpaces() {
        let host = NSHostingView(rootView: SubscriptionSettingsSection().subscriptionForm)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()

        var fields: [NSTextField] = []
        func collect(_ view: NSView) {
            if let tf = view as? NSTextField, tf.isEditable {
                fields.append(tf)
            }
            for child in view.subviews {
                collect(child)
            }
        }
        collect(host)

        XCTAssertEqual(fields.count, 2)
        for field in fields {
            XCTAssertNotEqual(field.alignment, .right)
            XCTAssertTrue(field.isBezeled)
        }

        let nameField = fields[0]
        window.makeFirstResponder(nameField)
        guard let editor = nameField.currentEditor() as? NSTextView,
              let layoutManager = editor.layoutManager,
              let textContainer = editor.textContainer else {
            return XCTFail("Expected active field editor for Name text field")
        }

        editor.string = "Gemini AI Ultra"
        editor.selectedRange = NSRange(location: editor.string.utf16.count, length: 0)
        layoutManager.ensureLayout(for: textContainer)
        let xBefore = layoutManager.location(forGlyphAt: layoutManager.numberOfGlyphs).x

        editor.string = "Gemini AI Ultra "
        editor.selectedRange = NSRange(location: editor.string.utf16.count, length: 0)
        layoutManager.ensureLayout(for: textContainer)
        let xAfter = layoutManager.location(forGlyphAt: layoutManager.numberOfGlyphs).x

        XCTAssertGreaterThan(xAfter - xBefore, 2.0,
                             "Trailing space must visibly advance the caret in Subscription Name field")
    }

    func testDashBarSegmentShapeTopRadiusBehavior() {
        let rect = CGRect(x: 0, y: 0, width: 12, height: 1.5)

        let interiorPath = DashBarSegmentShape(topRadius: 0).path(in: rect)
        XCTAssertEqual(interiorPath.boundingRect, rect)

        let topPath = DashBarSegmentShape(topRadius: 2.5).path(in: rect)
        XCTAssertEqual(topPath.boundingRect.minX, rect.minX, accuracy: 0.01)
        XCTAssertEqual(topPath.boundingRect.maxX, rect.maxX, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(topPath.boundingRect.minY, rect.minY - 0.01)
        XCTAssertLessThanOrEqual(topPath.boundingRect.maxY, rect.maxY + 0.01)

        XCTAssertTrue(DashBarSegmentShape(topRadius: 2.5).path(in: .zero).isEmpty)
    }
}
