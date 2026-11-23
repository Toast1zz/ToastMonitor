import XCTest
@testable import ToastMonitor

final class ModelProviderTests: XCTestCase {
    /// Model ids seen in a real store.
    func testRealIDs() {
        let table: [(String, String)] = [
            ("claude-opus-5-5", "Anthropic"),
            ("claude-haiku-4-5-20251001", "Anthropic"),
            ("gpt-6.1-sol", "OpenAI"),
            ("gpt-6-luna-900k", "OpenAI"),
            ("codex-auto-review", "OpenAI"),
            ("gemini-4-hydrogen-tiered-high", "Google"),
            ("deepseek-flash", "DeepSeek"),
            ("deepseek/deepseek-v4.1-flash", "DeepSeek"),
            ("qwen3.7-plus", "Qwen"),
            ("qwen/qwen3.7-flash", "Qwen"),
            ("Qwen3.6-35B-A3B-ConfigI-MLX", "Qwen"),
            ("glm-5.3-flash", "Z.ai"),
            ("z-ai/glm-5.3-flash", "Z.ai"),
            ("zai-org/GLM-5.3", "Z.ai"),
            ("grok-4.7", "xAI"),
            ("mimo-v2.5", "Xiaomi"),
            ("xiaomi/mimo-v2.5", "Xiaomi"),
            ("minimax-m3", "MiniMax"),
        ]
        for (raw, maker) in table {
            XCTAssertEqual(ModelProvider.name(for: raw), maker, raw)
        }
    }

    func testUnknownMakerIsOther() {
        for raw in ["hy3", "hermes-agent", "ox-alpha-free", "(unknown)", "", "gptx"] {
            XCTAssertEqual(ModelProvider.name(for: raw), ModelProvider.other, raw)
        }
    }
}
