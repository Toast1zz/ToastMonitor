import XCTest
import SQLite3
@testable import ToastMonitor

final class PerfCollectorTests: XCTestCase {
    private var dir: String!
    private var db: Database!
    /// Today, so perfPoints(days: 1) sees every sample.
    private let base = Int64(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970 * 1000) + 60_000

    override func setUp() {
        super.setUp()
        dir = NSTemporaryDirectory() + "tm-perf-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        db = Database.testInstance(path: dir + "/store.db")
    }

    override func tearDown() {
        db?.close()
        try? FileManager.default.removeItem(atPath: dir)
        super.tearDown()
    }

    private func iso(_ ms: Int64) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    private func line(_ obj: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)! + "\n"
    }

    private func assistant(ref: String, block: Int, at ms: Int64, thinkingMs: Int64? = nil,
                           output: Int64 = 600) -> String {
        var obj: [String: Any] = [
            "type": "assistant", "timestamp": iso(ms), "requestRef": ref, "requestId": "req_\(ref)",
            "apiBlockIndex": block,
            "message": ["id": "msg_\(ref)", "model": "claude-opus-5-5",
                        "usage": ["output_tokens": output]],
        ]
        if let thinkingMs { obj["thinkingDurationMs"] = thinkingMs }
        return line(obj)
    }

    func testClaudeMeasuresFromThinkingStartAcrossAppends() throws {
        let file = dir + "/session.jsonl"
        // Sent at 0, thinking streamed 1.0s–3.0s, tool call finished at 6.0s.
        let first = line(["type": "api-request", "id": "r1", "timestamp": iso(base)])
            + assistant(ref: "r1", block: 0, at: base + 3_000, thinkingMs: 2_000)
        try first.write(toFile: file, atomically: true, encoding: .utf8)
        PerfCollector.scanClaude(file: file, database: db)

        let handle = try XCTUnwrap(FileHandle(forWritingAtPath: file))
        handle.seekToEndOfFile()
        handle.write(assistant(ref: "r1", block: 1, at: base + 6_000).data(using: .utf8)!)
        handle.closeFile()
        PerfCollector.scanClaude(file: file, database: db)

        let points = db.perfPoints(days: 1)
        XCTAssertEqual(points.count, 1)
        XCTAssertEqual(points.first?.model, "claude-opus-5-5")
        XCTAssertEqual(points.first?.ttftMs, 1_000)
        // 600 tokens over 5 seconds.
        XCTAssertEqual(try XCTUnwrap(points.first?.tokensPerSecond), 120, accuracy: 0.001)
    }

    func testClaudeCallWithoutLeadingThinkingIsNotMeasured() throws {
        let file = dir + "/plain.jsonl"
        let text = line(["type": "api-request", "id": "r2", "timestamp": iso(base)])
            + assistant(ref: "r2", block: 0, at: base + 2_000)
        try text.write(toFile: file, atomically: true, encoding: .utf8)
        PerfCollector.scanClaude(file: file, database: db)
        XCTAssertTrue(db.perfPoints(days: 1).isEmpty)
    }

    func testOlderTranscriptWithoutRequestLineStillGivesSpeed() throws {
        let file = dir + "/old.jsonl"
        try (assistant(ref: "r3", block: 0, at: base + 2_000, thinkingMs: 1_000)
             + assistant(ref: "r3", block: 1, at: base + 5_000))
            .write(toFile: file, atomically: true, encoding: .utf8)
        PerfCollector.scanClaude(file: file, database: db)
        let point = try XCTUnwrap(db.perfPoints(days: 1).first)
        XCTAssertNil(point.ttftMs)
        XCTAssertEqual(try XCTUnwrap(point.tokensPerSecond), 150, accuracy: 0.001)
    }

    func testOpenCodeUsesPartTimesAndSkipsMultiStepMessages() throws {
        let path = dir + "/opencode.db"
        var src: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &src), SQLITE_OK)
        defer { sqlite3_close(src) }
        func exec(_ sql: String) { XCTAssertEqual(sqlite3_exec(src, sql, nil, nil, nil), SQLITE_OK, sql) }
        exec("""
        CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, time_updated INTEGER, data TEXT);
        CREATE TABLE part (id TEXT PRIMARY KEY, message_id TEXT, session_id TEXT, time_created INTEGER, time_updated INTEGER, data TEXT);
        """)
        func message(_ id: String, completed: Int64, output: Int, reasoning: Int) {
            exec("""
            INSERT INTO message VALUES ('\(id)', 's', \(base), \(completed),
              '{"role":"assistant","modelID":"deepseek-v4-flash","time":{"created":\(base),"completed":\(completed)},"tokens":{"output":\(output),"reasoning":\(reasoning)}}');
            """)
        }
        func part(_ id: String, _ message: String, _ json: String) {
            exec("INSERT INTO part VALUES ('\(id)', '\(message)', 's', 0, 0, '\(json)');")
        }
        // Text streamed 1.0s–2.0s, then a tool ran 2.5s–9.0s; completed at 9.0s.
        message("m1", completed: base + 9_000, output: 80, reasoning: 20)
        part("a", "m1", #"{"type":"step-start"}"#)
        part("b", "m1", #"{"type":"text","time":{"start":\#(base + 1_000),"end":\#(base + 2_000)}}"#)
        part("c", "m1", #"{"type":"tool","state":{"time":{"start":\#(base + 2_500),"end":\#(base + 9_000)}}}"#)
        message("m2", completed: base + 9_000, output: 500, reasoning: 0)
        part("d", "m2", #"{"type":"step-start"}"#)
        part("e", "m2", #"{"type":"step-start"}"#)
        part("f", "m2", #"{"type":"text","time":{"start":\#(base + 1_000),"end":\#(base + 2_000)}}"#)

        PerfCollector.scanOpenCode(database: db, path: path)
        let points = db.perfPoints(days: 1)
        XCTAssertEqual(points.count, 1)
        XCTAssertEqual(points.first?.ttftMs, 1_000)
        // 100 tokens over 1.5 seconds: generation ends when the tool starts.
        XCTAssertEqual(try XCTUnwrap(points.first?.tokensPerSecond), 100 / 1.5, accuracy: 0.001)
        XCTAssertEqual(db.perfCursor(path)?.size, base + 9_000)
    }

    private func append(_ text: String, to file: String) throws {
        let handle = try XCTUnwrap(FileHandle(forWritingAtPath: file))
        handle.seekToEndOfFile()
        handle.write(text.data(using: .utf8)!)
        handle.closeFile()
    }

    private func codex(_ type: String, at ms: Int64, _ payload: [String: Any]) -> String {
        line(["timestamp": iso(ms), "type": type, "payload": payload])
    }

    private func codexItem(_ kind: String, start: Int64, end: Int64) -> String {
        codex("event_msg", at: end, ["type": "item_completed", "started_at_ms": start,
                                     "completed_at_ms": end, "item": ["type": kind, "id": UUID().uuidString]])
    }

    private func codexUsage(_ id: String, at ms: Int64, output: Int) -> String {
        codex("token_usage_record", at: ms, ["response_id": id, "usage": ["output_tokens": output]])
    }

    func testCodexMeasuresEachResponseAcrossAppends() throws {
        let file = dir + "/rollout.jsonl"
        // Prompt at 0. Response 1: reasoning 2.0–3.0s, tool call done at 4.0s.
        // The read stops mid-turn, before response 2 has its usage record.
        try (codex("event_msg", at: base, ["type": "task_started"])
             + codex("turn_context", at: base, ["model": "gpt-6.1-sol"])
             + codexItem("UserMessage", start: base, end: base)
             + codexItem("Reasoning", start: base + 2_000, end: base + 3_000)
             + codex("response_item", at: base + 4_000, ["type": "custom_tool_call"])
             + codexItem("CommandExecution", start: base + 4_100, end: base + 4_200)
             + codexUsage("resp_1", at: base + 4_500, output: 300)
             + codex("response_item", at: base + 5_000, ["type": "custom_tool_call_output"])
             + codexItem("Reasoning", start: base + 7_000, end: base + 7_500))
            .write(toFile: file, atomically: true, encoding: .utf8)
        PerfCollector.scanCodex(file: file, database: db, nowMs: base + 8_000)
        XCTAssertEqual(db.perfPoints(days: 1).count, 1)

        // The usage parser has recorded the file's model by the next run.
        db.setScanState(file, size: 0, mtime: 0, identity: 0, context: #"{"model":"gpt-6.1-sol"}"#)
        // Response 2 ends with a message at 9.0s; the turn completes.
        try append(codexItem("AgentMessage", start: base + 8_000, end: base + 9_000)
                   + codexUsage("resp_2", at: base + 9_100, output: 400)
                   + codex("event_msg", at: base + 9_200, ["type": "task_complete"]), to: file)
        PerfCollector.scanCodex(file: file, database: db, nowMs: base + 10_000)

        let points = db.perfPoints(days: 1).sorted { ($0.ttftMs ?? 0) < ($1.ttftMs ?? 0) }
        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points.map(\.model), ["gpt-6.1-sol", "gpt-6.1-sol"])
        // Response 1: sent at 0, first token at 2.0s, 300 tokens over 2.0s.
        XCTAssertEqual(points[0].ttftMs, 2_000)
        XCTAssertEqual(try XCTUnwrap(points[0].tokensPerSecond), 150, accuracy: 0.001)
        // Response 2: sent with the tool output at 5.0s, 400 tokens over 2.0s.
        XCTAssertEqual(points[1].ttftMs, 2_000)
        XCTAssertEqual(try XCTUnwrap(points[1].tokensPerSecond), 200, accuracy: 0.001)
        let size = try XCTUnwrap(FileScanner.fileStat(file)).size
        XCTAssertEqual(db.perfCursor(file)?.size, size, "a closed turn leaves nothing to re-read")
    }

    func testCodexResponseWithoutStreamedItemIsNotMeasured() throws {
        let file = dir + "/rollout-tools.jsonl"
        try (codexItem("UserMessage", start: base, end: base)
             + codex("response_item", at: base + 3_000, ["type": "function_call"])
             + codexUsage("resp_3", at: base + 3_100, output: 200))
            .write(toFile: file, atomically: true, encoding: .utf8)
        PerfCollector.scanCodex(file: file, database: db, nowMs: base + 4_000)
        XCTAssertTrue(db.perfPoints(days: 1).isEmpty)
    }

    private func dsh(_ type: String, seq: Int, at ms: Int64, _ data: [String: Any]) -> String {
        line(["type": type, "seq": seq, "time": ms, "data": data])
    }

    func testDSHVersionedLogUsesStreamTimes() throws {
        let sessionDir = dir + "/session-abc"
        try FileManager.default.createDirectory(atPath: sessionDir, withIntermediateDirectories: true)
        let file = sessionDir + "/session.v4.jsonl"
        // Step sent at 0; reasoning block 1.0s, text chunks 2.0s + 0.5s + 0.5s,
        // block end at 3.0s, usage chunk late at 3.4s.
        let stream: [[String: Any]] = [
            ["type": "chunk", "time": base + 1_000, "chunk": ["type": "block-start", "index": 0]],
            ["type": "text-chunks", "time0": base + 2_000, "index": 1, "dt": [500, 500]],
            ["type": "chunk", "time": base + 3_000, "chunk": ["type": "block-end", "index": 1]],
            ["type": "chunk", "time": base + 3_400, "chunk": ["type": "usage"]],
        ]
        try (dsh("step/start", seq: 1, at: base, ["turn": 1, "step": 1])
             + dsh("assistant/message", seq: 2, at: base + 3_500, [
                "turn": 1, "step": 1, "usage": ["outputTokens": 400],
                "message": ["role": "assistant", "source": ["model": "deepseek-v4-flash"]],
                "stream": stream]))
            .write(toFile: file, atomically: true, encoding: .utf8)
        PerfCollector.scanDSH(file: file, database: db)

        let point = try XCTUnwrap(db.perfPoints(days: 1).first)
        XCTAssertEqual(point.model, "deepseek-v4-flash")
        XCTAssertEqual(point.ttftMs, 1_000)
        XCTAssertEqual(try XCTUnwrap(point.tokensPerSecond), 200, accuracy: 0.001)
    }

    func testDSHChunkLinesMergeAcrossAppends() throws {
        let sessionDir = dir + "/session-old"
        try FileManager.default.createDirectory(atPath: sessionDir, withIntermediateDirectories: true)
        let file = sessionDir + "/session.jsonl"
        try (dsh("step/start", seq: 1, at: base, ["turn": 2, "step": 3])
             + dsh("assistant/chunk", seq: 2, at: base + 1_500,
                   ["turn": 2, "step": 3, "chunk": ["type": "block-start", "index": 0]]))
            .write(toFile: file, atomically: true, encoding: .utf8)
        PerfCollector.scanDSH(file: file, database: db)
        try append(dsh("assistant/chunk", seq: 3, at: base + 4_000,
                       ["turn": 2, "step": 3, "chunk": ["type": "block-end", "index": 0]])
                   + dsh("assistant/chunk", seq: 4, at: base + 4_000,
                         ["turn": 2, "step": 3, "chunk": ["type": "usage", "usage": ["outputTokens": 250]]])
                   + dsh("assistant/chunk", seq: 5, at: base + 4_000,
                         ["turn": 2, "step": 3, "chunk": ["type": "finish", "replayState":
                            ["response": ["model": "deepseek-v4-pro"]]]]), to: file)
        PerfCollector.scanDSH(file: file, database: db)

        let point = try XCTUnwrap(db.perfPoints(days: 1).first)
        XCTAssertEqual(point.model, "deepseek-v4-pro")
        XCTAssertEqual(point.ttftMs, 1_500)
        XCTAssertEqual(try XCTUnwrap(point.tokensPerSecond), 100, accuracy: 0.001)
    }

    func testOmpUsesRecordedFirstTokenAndDuration() throws {
        let file = dir + "/omp.jsonl"
        func message(_ id: String, extra: [String: Any]) -> String {
            var m: [String: Any] = ["role": "assistant", "model": "gpt-6-sol", "timestamp": base,
                                    "responseId": id, "usage": ["output": 300]]
            m.merge(extra) { $1 }
            return line(["type": "message", "id": "e_\(id)", "timestamp": iso(base), "message": m])
        }
        try (message("r1", extra: ["ttft": 1_200.4, "duration": 3_200.2])
             + message("r2", extra: ["duration": 3_000]))
            .write(toFile: file, atomically: true, encoding: .utf8)
        PerfCollector.scanOmp(file: file, database: db)

        let points = db.perfPoints(days: 1)
        XCTAssertEqual(points.count, 1, "a message without ttft is not measured")
        XCTAssertEqual(points.first?.ttftMs, 1_200)
        XCTAssertEqual(try XCTUnwrap(points.first?.tokensPerSecond), 150, accuracy: 0.001)
    }

    func testMedian() {
        XCTAssertNil(PerfStats.median([]))
        XCTAssertEqual(PerfStats.median([3, 1, 2]), 2)
        XCTAssertEqual(PerfStats.median([4, 1, 2, 3]), 2.5)
    }
}
