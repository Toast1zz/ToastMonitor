import XCTest
@testable import ToastMonitor

final class OmpParserTests: XCTestCase {

    private var fixturePath: String {
        // swift-test-resources: Fixtures are copied into the test bundle
        // as a subdirectory (Package.swift resources: .copy("Fixtures")).
        Bundle.module.url(forResource: "omp-sample", withExtension: "jsonl",
                          subdirectory: "Fixtures")!.path
    }

    func testParsesAssistantUsageEvents() {
        let (turns, sessions) = OmpParser.scan(knownPaths: [fixturePath])
        // Two assistant messages carry usage; the user message is skipped.
        XCTAssertEqual(turns.count, 2, "only assistant usage events become turns")
        let first = turns[0]
        XCTAssertEqual(first.tool, .omp)
        XCTAssertEqual(first.inputTokens, 18585)
        XCTAssertEqual(first.outputTokens, 241)
        XCTAssertEqual(first.cacheRead, 0)
        XCTAssertEqual(first.model, "deepseek-v4-flash")
        XCTAssertEqual(first.cost, 0.0027, accuracy: 0.0001)
        XCTAssertEqual(first.costQuality, "estimated")
        // Session id derives from the transcript's session event UUID.
        XCTAssertEqual(first.sessionID, "019f0000-0000-7000-0000-000000000001")
        XCTAssertEqual(first.project, "Fixtures") // encoded parent dir last component
        // The second turn carries cacheRead separately from input.
        XCTAssertEqual(turns[1].cacheRead, 18816)
        XCTAssertEqual(turns[1].inputTokens, 22)
        // Stable per-message event ids.
        XCTAssertEqual(turns[0].eventID, "omp:omp-sample.jsonl:msg2")
        XCTAssertEqual(turns[1].eventID, "omp:omp-sample.jsonl:msg3")
        XCTAssertNotEqual(turns[0].eventID, turns[1].eventID)
        // One session summary with the real time range.
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].created, 1_786_096_805) // 2026-08-07T10:00:05Z
        XCTAssertEqual(sessions[0].updated, 1_786_096_808)
        XCTAssertEqual(sessions[0].model, "deepseek-v4-flash")
    }

    func testIgnoresMalformedLinesAndNonAssistantMessages() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("omp-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("s.jsonl").path
        try? """
        {"type":"session","version":3,"id":"s1","timestamp":"2026-08-07T10:00:00.000Z","cwd":"/tmp"}
        not json at all
        {"type":"message","id":"a1","timestamp":"2026-08-07T10:00:01.000Z","message":{"role":"assistant","usage":{"input":10,"output":5}}}
        {"type":"message","id":"a2","timestamp":"2026-08-07T10:00:02.000Z","message":{"role":"assistant","usage":{"input":0,"output":0}}}
        """.write(toFile: path, atomically: true, encoding: .utf8)
        let (turns, _) = OmpParser.scan(knownPaths: [path])
        XCTAssertEqual(turns.count, 1, "malformed lines and zero-token events are skipped")
        XCTAssertEqual(turns[0].inputTokens, 10)
        try? FileManager.default.removeItem(at: dir)
    }
}
