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

    func testMedian() {
        XCTAssertNil(PerfStats.median([]))
        XCTAssertEqual(PerfStats.median([3, 1, 2]), 2)
        XCTAssertEqual(PerfStats.median([4, 1, 2, 3]), 2.5)
    }
}
