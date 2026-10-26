import XCTest
@testable import ToastMonitor

final class ModelNameTests: XCTestCase {
    /// Every distinct model id seen in a real store, with what a reader should see.
    private let table: [(raw: String, shown: String)] = [
        ("claude-opus-5-5", "Opus 5.5"),
        ("claude-opus-5", "Opus 5"),
        ("claude-opus-4-8", "Opus 4.8"),
        ("claude-sonnet-5-5", "Sonnet 5.5"),
        ("claude-sonnet-5", "Sonnet 5"),
        ("claude-sonnet-4-6", "Sonnet 4.6"),
        ("claude-fable-5", "Fable 5"),
        ("gpt-5.6-sol", "GPT-5.6 Sol"),
        ("gpt-5.6-luna", "GPT-5.6 Luna"),
        ("gpt-5.6-terra", "GPT-5.6 Terra"),
        ("gpt-6-sol", "GPT-6 Sol"),
        ("gpt-6-luna", "GPT-6 Luna"),
        ("gpt-6-astra", "GPT-6 Astra"),
        ("gpt-6.1-sol", "GPT-6.1 Sol"),
        ("codex-auto-review", "Codex Auto Review"),
        ("deepseek-v4-flash", "DeepSeek V4 Flash"),
        ("deepseek/deepseek-v4-flash", "DeepSeek V4 Flash"),
        ("deepseek/deepseek-v4.1-flash", "DeepSeek V4.1 Flash"),
        ("deepseek/deepseek-v4-flash-0731", "DeepSeek V4 Flash 0731"),
        ("deepseek-v4-flash-vision-exp", "DeepSeek V4 Flash Vision Exp"),
        ("deepseek-v4-pro", "DeepSeek V4 Pro"),
        ("deepseek-flash", "DeepSeek Flash"),
        ("glm-5.3-flash", "GLM 5.3 Flash"),
        ("z-ai/glm-5.3-flash", "GLM 5.3 Flash"),
        ("zai-org/GLM-5.3", "GLM 5.3"),
        ("grok-4.7", "Grok 4.7"),
        ("grok-4.6", "Grok 4.6"),
        ("mimo-v2.5", "MiMo V2.5"),
        ("xiaomi/mimo-v2.5", "MiMo V2.5"),
        ("minimax-m3", "MiniMax M3"),
        ("qwen3.7-plus", "Qwen 3.7 Plus"),
        ("qwen/qwen3.7-flash", "Qwen 3.7 Flash"),
        ("hermes-agent", "Hermes Agent"),
        ("ox-alpha-free", "Ox Alpha Free"),
        // Shapes the rules do not know stay as they were.
        ("hy3", "hy3"),
        ("Qwen3.6-35B-A3B-ConfigI-MLX", "Qwen3.6-35B-A3B-ConfigI-MLX"),
    ]

    func testEveryKnownModelReadsWell() {
        for (raw, shown) in table {
            XCTAssertEqual(ModelName.display(raw), shown, "raw id: \(raw)")
        }
    }

    func testDifferentSpellingsOfOneModelShareADisplayName() {
        XCTAssertEqual(ModelName.display("deepseek-v4-flash"), ModelName.display("deepseek/deepseek-v4-flash"))
        XCTAssertEqual(ModelName.display("glm-5.3-flash"), ModelName.display("z-ai/glm-5.3-flash"))
        XCTAssertEqual(ModelName.display("mimo-v2.5"), ModelName.display("xiaomi/mimo-v2.5"))
    }

    func testDifferentModelsNeverShareOne() {
        let shown = [
            "claude-sonnet-5", "claude-sonnet-5-5", "gpt-5.6-sol", "gpt-6-sol", "gpt-6.1-sol",
            "deepseek-v4-flash", "deepseek-v4.1-flash", "deepseek-v4-flash-0731",
        ].map(ModelName.display)
        XCTAssertEqual(Set(shown).count, shown.count)
    }

    func testSnapshotDateIsDropped() {
        XCTAssertEqual(ModelName.display("claude-sonnet-4-5-20250929"), "Sonnet 4.5")
    }

    func testOlderClaudeOrderPutsVersionFirst() {
        XCTAssertEqual(ModelName.display("claude-3-5-sonnet-20241022"), "Sonnet 3.5")
    }

    func testEmptyAndOddInputDoNotCrash() {
        XCTAssertEqual(ModelName.display(""), "")
        XCTAssertEqual(ModelName.display("  "), "")
        XCTAssertEqual(ModelName.display("/"), "/")
        XCTAssertEqual(ModelName.display("-"), "-")
    }
}

final class AnalysisCSVTests: XCTestCase {
    func testCSVKeepsEveryRawIdWhileTheScreenMergesThem() {
        let aggs: [(day: Int64, model: String, input: Int64, output: Int64, cacheRead: Int64, cost: Double, count: Int64, totalTokens: Int64)] = [
            (1, "deepseek-v4-flash", 100, 50, 850, 0.5, 4, 1000),
            (2, "deepseek-v4-flash", 10, 5, 85, 0.05, 1, 100),
            (1, "deepseek/deepseek-v4-flash", 20, 10, 170, 0.1, 2, 200),
            (1, "claude-opus-5-5", 300, 100, 600, 3, 6, 1000),
        ]
        let rows = AnalysisCSVRow.perModelID(aggs)
        // Three ids, three rows; the two deepseek spellings are not merged.
        XCTAssertEqual(rows.map(\.name), ["deepseek-v4-flash", "claude-opus-5-5", "deepseek/deepseek-v4-flash"])
        XCTAssertEqual(rows.map(\.tokens), [1100, 1000, 200])
        XCTAssertEqual(rows[0].calls, 5)
        XCTAssertEqual(rows[0].cost, 0.55, accuracy: 1e-9)
        XCTAssertEqual(rows.map(\.ratio).reduce(0, +), 1, accuracy: 1e-9)
    }

    func testEmptyInputGivesNoRows() {
        XCTAssertEqual(AnalysisCSVRow.perModelID([]), [])
    }
}
