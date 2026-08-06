import XCTest
@testable import ToastMonitor

/// P0-1: Codex rollout 文件名解析。真实文件名格式:
/// rollout-<YYYY-MM-DDTHH-MM-SS>-<uuid>.jsonl
/// removeFirst(7) 会把 UUID 第一段当时间戳删掉 → session 无法 join threads。
final class CodexParserTests: XCTestCase {

    func testSessionIDFromRealRolloutName() {
        // 真实样本 (脱敏): ~/.codex/sessions/2026/08/04/
        let name = "rollout-2026-08-04T09-22-33-019fcb70-2990-7ae3-897a-826135c6b1c5.jsonl"
        let expected = "019fcb70-2990-7ae3-897a-826135c6b1c5"
        let got = CodexParser.sessionID(fromRolloutName: name)
        XCTAssertEqual(got, expected, "UUID 第一段被 removeFirst(7) 删除 (P0-1)")
    }

    func testSessionIDFromZeroPaddedDate() {
        // 日期/时间全是双位
        let name = "rollout-2026-01-05T00-03-09-019f0000-1111-2222-3333-444455556666.jsonl"
        XCTAssertEqual(CodexParser.sessionID(fromRolloutName: name),
                       "019f0000-1111-2222-3333-444455556666")
    }

    func testMalformedNamesReturnNil() {
        XCTAssertNil(CodexParser.sessionID(fromRolloutName: "rollout-not-a-timestamp.jsonl"))
        XCTAssertNil(CodexParser.sessionID(fromRolloutName: "random.txt"))
        XCTAssertNil(CodexParser.sessionID(fromRolloutName: "2026-08-04T09-22-33-nouuid.jsonl"))
    }
}
