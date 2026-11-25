import Foundation

/// The company behind a model, read from its id. The tool that made the call
/// says nothing here: Codex, omp and dsh all run OpenAI models.
///
/// An id that names no known maker is `other`; guessing would put a model
/// under the wrong company.
enum ModelProvider {
    static let other = "Other"

    /// Router prefixes ("z-ai/glm-5.3-flash") name the maker outright.
    private static let prefixes: [String: String] = [
        "anthropic": "Anthropic",
        "openai": "OpenAI",
        "google": "Google",
        "deepseek": "DeepSeek",
        "qwen": "Qwen",
        "z-ai": "Z.ai",
        "zai-org": "Z.ai",
        "x-ai": "xAI",
        "xiaomi": "Xiaomi",
        "minimax": "MiniMax",
        "moonshotai": "Moonshot",
    ]

    /// First word of the model id → maker.
    private static let families: [(prefix: String, provider: String)] = [
        ("claude", "Anthropic"), ("opus", "Anthropic"), ("sonnet", "Anthropic"),
        ("haiku", "Anthropic"), ("fable", "Anthropic"), ("mythos", "Anthropic"),
        ("gpt", "OpenAI"), ("chatgpt", "OpenAI"), ("codex", "OpenAI"),
        ("gemini", "Google"), ("gemma", "Google"),
        ("deepseek", "DeepSeek"),
        ("qwen", "Qwen"),
        ("glm", "Z.ai"),
        ("grok", "xAI"),
        ("mimo", "Xiaomi"),
        ("minimax", "MiniMax"),
        ("kimi", "Moonshot"),
    ]

    static func name(for raw: String) -> String {
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let dot = id.range(of: "anthropic."),
           !id[..<dot.lowerBound].contains("/"),
           dot.lowerBound == id.startIndex || id[id.index(before: dot.lowerBound)] == "." {
            return "Anthropic"
        }
        let parts = id.split(separator: "/")
        if parts.count > 1, let maker = prefixes[String(parts[0])] { return maker }
        guard let model = parts.last else { return other }
        let firstToken = model.split { !$0.isLetter && !$0.isNumber }.first
        if firstToken == "o1" || firstToken == "o3" || firstToken == "o4" { return "OpenAI" }
        let first = model.prefix { $0.isLetter }
        return families.first { first == $0.prefix }?.provider ?? other
    }
}
