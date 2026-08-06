import Foundation

/// Approximate per-1M-token pricing (USD) for common models.
/// Unknown models fall back to nil cost (tokens still shown).
/// Order matters: first matching pattern wins, longest prefix matched first.
struct ModelPrice {
    let input: Double      // per 1M input tokens
    let output: Double     // per 1M output tokens
    let cacheRead: Double  // per 1M cache-read input tokens
    let cacheWrite: Double // per 1M cache-write input tokens
}

enum Pricing {
    static let table: [(pattern: String, price: ModelPrice)] = [
        // Claude
        ("claude-opus-4", ModelPrice(input: 15, output: 75, cacheRead: 1.5, cacheWrite: 18.75)),
        ("claude-opus", ModelPrice(input: 15, output: 75, cacheRead: 1.5, cacheWrite: 18.75)),
        ("claude-sonnet-4", ModelPrice(input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75)),
        ("claude-sonnet", ModelPrice(input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75)),
        ("claude-3.7", ModelPrice(input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75)),
        ("claude-3.5", ModelPrice(input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75)),
        ("claude-3-haiku", ModelPrice(input: 0.25, output: 1.25, cacheRead: 0.03, cacheWrite: 0.3)),
        ("claude-haiku", ModelPrice(input: 0.25, output: 1.25, cacheRead: 0.03, cacheWrite: 0.3)),
        ("claude", ModelPrice(input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75)),
        // GPT-5 family
        ("gpt-5.6-luna", ModelPrice(input: 1.25, output: 10, cacheRead: 0.125, cacheWrite: 1.875)),
        ("gpt-5.6", ModelPrice(input: 1.25, output: 10, cacheRead: 0.125, cacheWrite: 1.875)),
        ("gpt-5.4-mini", ModelPrice(input: 0.25, output: 2, cacheRead: 0.025, cacheWrite: 0.375)),
        ("gpt-5.4", ModelPrice(input: 1.25, output: 10, cacheRead: 0.125, cacheWrite: 1.875)),
        ("gpt-5", ModelPrice(input: 1.25, output: 10, cacheRead: 0.125, cacheWrite: 1.875)),
        ("gpt-4.1-mini", ModelPrice(input: 0.4, output: 1.6, cacheRead: 0.05, cacheWrite: 0.6)),
        ("gpt-4.1", ModelPrice(input: 2, output: 8, cacheRead: 0.5, cacheWrite: 3)),
        ("gpt-4o-mini", ModelPrice(input: 0.15, output: 0.6, cacheRead: 0.075, cacheWrite: 0.15)),
        ("gpt-4o", ModelPrice(input: 2.5, output: 10, cacheRead: 1.25, cacheWrite: 2.5)),
        ("gpt-4", ModelPrice(input: 2.5, output: 10, cacheRead: 1.25, cacheWrite: 2.5)),
        // DeepSeek
        ("deepseek-v4-flash", ModelPrice(input: 0.28, output: 0.42, cacheRead: 0.028, cacheWrite: 0.28)),
        ("deepseek-v4", ModelPrice(input: 0.28, output: 0.42, cacheRead: 0.028, cacheWrite: 0.28)),
        ("deepseek-chat", ModelPrice(input: 0.28, output: 0.42, cacheRead: 0.028, cacheWrite: 0.28)),
        ("deepseek-reasoner", ModelPrice(input: 0.56, output: 1.68, cacheRead: 0.056, cacheWrite: 0.56)),
        ("deepseek", ModelPrice(input: 0.28, output: 0.42, cacheRead: 0.028, cacheWrite: 0.28)),
        // Others
        ("gemini-2.5", ModelPrice(input: 1.25, output: 10, cacheRead: 0.0625, cacheWrite: 1.875)),
        ("gemini-2.0", ModelPrice(input: 1.25, output: 10, cacheRead: 0.0625, cacheWrite: 1.875)),
        ("gemini", ModelPrice(input: 1.25, output: 10, cacheRead: 0.0625, cacheWrite: 1.875)),
        ("qwen3", ModelPrice(input: 0.5, output: 2, cacheRead: 0.05, cacheWrite: 0.75)),
        ("qwen", ModelPrice(input: 0.5, output: 2, cacheRead: 0.05, cacheWrite: 0.75)),
        ("kimi", ModelPrice(input: 0.6, output: 2.5, cacheRead: 0.06, cacheWrite: 0.9)),
        ("glm-4", ModelPrice(input: 0.1, output: 0.1, cacheRead: 0.01, cacheWrite: 0.05)),
        ("glm", ModelPrice(input: 0.1, output: 0.1, cacheRead: 0.01, cacheWrite: 0.05)),
        ("o3", ModelPrice(input: 2, output: 8, cacheRead: 0.5, cacheWrite: 3)),
        ("o4", ModelPrice(input: 2, output: 8, cacheRead: 0.5, cacheWrite: 3)),
    ]

    /// Returns estimated cost in USD for a turn, or nil when the model is unknown.
    static func estimate(model: String?, input: Int64, output: Int64, cacheRead: Int64, cacheWrite: Int64) -> Double? {
        guard let model = model?.lowercased(), !model.isEmpty else { return nil }
        for entry in table where model.contains(entry.pattern) {
            let p = entry.price
            return Double(input) / 1e6 * p.input
                + Double(output) / 1e6 * p.output
                + Double(cacheRead) / 1e6 * p.cacheRead
                + Double(cacheWrite) / 1e6 * p.cacheWrite
        }
        return nil
    }
}
