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
    static let version = "2026-10-03"
    static let table: [(pattern: String, price: ModelPrice)] = [
        // Claude
        // Five-minute cache writes only; one-hour writes cost twice the input rate.
        ("claude-fable-5-1", ModelPrice(input: 10, output: 50, cacheRead: 0.25, cacheWrite: 12.5)),
        ("claude-fable-5", ModelPrice(input: 10, output: 50, cacheRead: 1, cacheWrite: 12.5)),
        ("claude-mythos-5-1", ModelPrice(input: 10, output: 50, cacheRead: 0.25, cacheWrite: 12.5)),
        ("claude-mythos-5", ModelPrice(input: 10, output: 50, cacheRead: 1, cacheWrite: 12.5)),
        ("claude-opus-5-5", ModelPrice(input: 4, output: 20, cacheRead: 0.2, cacheWrite: 5)),
        ("claude-opus-5", ModelPrice(input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25)),
        ("claude-opus-4-8", ModelPrice(input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25)),
        ("claude-opus-4-7", ModelPrice(input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25)),
        ("claude-opus-4-6", ModelPrice(input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25)),
        ("claude-opus-4-5", ModelPrice(input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25)),
        ("claude-opus-4-1", ModelPrice(input: 15, output: 75, cacheRead: 1.5, cacheWrite: 18.75)),
        ("claude-opus-4", ModelPrice(input: 15, output: 75, cacheRead: 1.5, cacheWrite: 18.75)),
        ("claude-sonnet-5-5", ModelPrice(input: 2, output: 10, cacheRead: 0.2, cacheWrite: 2.5)),
        ("claude-sonnet-5", ModelPrice(input: 2, output: 10, cacheRead: 0.2, cacheWrite: 2.5)),
        ("claude-sonnet-4-6", ModelPrice(input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75)),
        ("claude-sonnet-4-5", ModelPrice(input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75)),
        ("claude-sonnet-4", ModelPrice(input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75)),
        ("claude-3-7-sonnet", ModelPrice(input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75)),
        // Dashed variants: "claude-3-5-haiku" does NOT contain "claude-3.5"
        // or "claude-3-haiku" — without these entries it would fall to the
        // catch-all claude rate (3/15), pricing haiku ~12x too high.
        ("claude-3-5-haiku", ModelPrice(input: 0.8, output: 4, cacheRead: 0.08, cacheWrite: 1)),
        ("claude-3-5-opus", ModelPrice(input: 15, output: 75, cacheRead: 1.5, cacheWrite: 18.75)),
        ("claude-3-5-sonnet", ModelPrice(input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75)),
        ("claude-3-haiku", ModelPrice(input: 0.25, output: 1.25, cacheRead: 0.03, cacheWrite: 0.3)),
        ("claude-haiku-4-5", ModelPrice(input: 1, output: 5, cacheRead: 0.1, cacheWrite: 1.25)),
        // GPT-5 family
        ("gpt-5.6-luna", ModelPrice(input: 1.25, output: 10, cacheRead: 0.125, cacheWrite: 1.875)),
        ("gpt-5.6", ModelPrice(input: 1.25, output: 10, cacheRead: 0.125, cacheWrite: 1.875)),
        ("gpt-5.4-mini", ModelPrice(input: 0.25, output: 2, cacheRead: 0.025, cacheWrite: 0.375)),
        ("gpt-5.4", ModelPrice(input: 2.5, output: 15, cacheRead: 0.25, cacheWrite: 1.875)),
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
        ("deepseek-r1", ModelPrice(input: 0.55, output: 2.19, cacheRead: 0.055, cacheWrite: 0.55)),
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
        ("o3-mini", ModelPrice(input: 1.1, output: 4.4, cacheRead: 0.55, cacheWrite: 1.65)),
        ("o3", ModelPrice(input: 2, output: 8, cacheRead: 0.5, cacheWrite: 3)),
        ("o4", ModelPrice(input: 2, output: 8, cacheRead: 0.5, cacheWrite: 3)),
    ]

    /// Returns estimated cost in USD for a turn, or nil when the model is unknown.
    static func estimate(model: String?, input: Int64, output: Int64, cacheRead: Int64, cacheWrite: Int64,
                         inputIncludesCache: Bool = false) -> Double? {
        guard let model = model?.lowercased(), !model.isEmpty else { return nil }
        for entry in table where matches(model, pattern: entry.pattern) {
            let p = entry.price
            let billableInput = inputIncludesCache ? max(input - cacheRead, 0) : input
            return Double(billableInput) / 1e6 * p.input
                + Double(output) / 1e6 * p.output
                + Double(cacheRead) / 1e6 * p.cacheRead
                + Double(cacheWrite) / 1e6 * p.cacheWrite
        }
        return nil
    }

    private static func matches(_ model: String, pattern: String) -> Bool {
        guard pattern.hasPrefix("claude-") else { return model.contains(pattern) }
        let normalized = model.replacingOccurrences(of: ".", with: "-")
            .split(separator: "/").last.map(String.init) ?? model
        guard normalized.hasPrefix(pattern) else { return false }
        let suffix = String(normalized.dropFirst(pattern.count))
        return suffix.isEmpty || suffix == "-latest"
            || suffix.range(of: "^-[0-9]{8}$", options: .regularExpression) != nil
    }
}
