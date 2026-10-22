import Foundation

/// Reader-friendly model names for display ("claude-opus-5-5" → "Opus 5.5").
///
/// Display only: the raw id stays in the database, where pricing and
/// aggregation depend on it. Different raw ids that read the same ("deepseek-v4-flash"
/// and "deepseek/deepseek-v4-flash") share one display name, so a screen that
/// groups by `display` shows them as one row.
///
/// Names that do not fit the rules come back as they were (minus a provider
/// prefix). A wrong version number would mislead more than an unpolished id.
enum ModelName {
    /// Known brands: lowercase id word → display word. A brand may be glued
    /// to its version ("qwen3.7"); `hyphenated` brands join it with a dash
    /// ("GPT-5.6").
    private static let brands: [String: (display: String, hyphenated: Bool)] = [
        "gpt": ("GPT", true),
        "glm": ("GLM", false),
        "qwen": ("Qwen", false),
        "grok": ("Grok", false),
        "mimo": ("MiMo", false),
        "minimax": ("MiniMax", false),
        "deepseek": ("DeepSeek", false),
    ]
    private static let claudeFamilies: Set<String> = ["opus", "sonnet", "haiku", "fable"]

    static func display(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // "deepseek/deepseek-v4-flash", "z-ai/glm-5.3-flash": the part after
        // the last slash is the model.
        let id = trimmed.split(separator: "/").last.map(String.init) ?? trimmed
        guard !id.isEmpty else { return trimmed }

        var tokens = id.lowercased()
            .split(whereSeparator: { "-_: ".contains($0) })
            .map(String.init)
        // A trailing snapshot date ("-20250929") says nothing a reader needs.
        if let last = tokens.last, tokens.count > 1, last.count == 8, last.allSatisfy(\.isNumber) {
            tokens.removeLast()
        }
        guard !tokens.isEmpty else { return id }

        // "qwen3.7-plus": split the glued version off a known brand.
        if let glued = splitBrand(tokens[0]) {
            tokens.replaceSubrange(0...0, with: glued)
        }

        if tokens[0] == "claude", let name = claude(Array(tokens.dropFirst())) { return name }

        var words: [String] = []
        var versionRun = ""          // "5" then "5" → "5.5"
        func flushVersion() {
            if !versionRun.isEmpty { words.append(versionRun); versionRun = "" }
        }
        for token in tokens {
            if isVersion(token) {
                if token.first?.isNumber == true, versionRun.hasSuffix(where: \.isNumber) {
                    // Consecutive plain numbers are one dotted version.
                    if token.contains(".") || versionRun.contains(".") {
                        flushVersion(); versionRun = token
                    } else {
                        versionRun += "." + token
                    }
                } else {
                    flushVersion()
                    versionRun = token.first?.isLetter == true ? token.prefix(1).uppercased() + token.dropFirst() : token
                }
            } else if token.allSatisfy(\.isLetter) {
                flushVersion()
                words.append(brands[token]?.display ?? token.prefix(1).uppercased() + token.dropFirst())
            } else {
                return id   // shape we do not know: keep it as it was
            }
        }
        flushVersion()

        // "GPT-5.6 Sol": a hyphenated brand sits against its version.
        if let brand = brands[tokens[0]], brand.hyphenated, words.count > 1, words[1].first?.isNumber == true {
            words.replaceSubrange(0...1, with: [words[0] + "-" + words[1]])
        }
        return words.joined(separator: " ")
    }

    /// "Opus 5.5" from the tokens after "claude" (family and version in any
    /// order: "opus-5-5", or the older "3-5-sonnet"). Nil when no family.
    private static func claude(_ tokens: [String]) -> String? {
        guard let family = tokens.first(where: { claudeFamilies.contains($0) }) else { return nil }
        var version = ""
        var extras: [String] = []
        for token in tokens where token != family {
            if token.allSatisfy(\.isNumber) {
                version += version.isEmpty ? token : "." + token
            } else if token.allSatisfy(\.isLetter) {
                extras.append(token.prefix(1).uppercased() + token.dropFirst())
            } else {
                return nil
            }
        }
        let name = family.prefix(1).uppercased() + family.dropFirst()
        return ([name] + (version.isEmpty ? [] : [version]) + extras).joined(separator: " ")
    }

    /// "qwen3.7" → ["qwen", "3.7"] for a known brand; nil otherwise.
    private static func splitBrand(_ token: String) -> [String]? {
        let letters = token.prefix(while: \.isLetter)
        let rest = token.dropFirst(letters.count)
        guard !rest.isEmpty, rest.first?.isNumber == true, brands[String(letters)] != nil else { return nil }
        return [String(letters), String(rest)]
    }

    /// "5.6", "6", "v4.1", "m3": digits with at most one letter in front.
    private static func isVersion(_ token: String) -> Bool {
        var body = Substring(token)
        if body.first?.isLetter == true { body = body.dropFirst() }
        guard let first = body.first, first.isNumber else { return false }
        return body.allSatisfy { $0.isNumber || $0 == "." } && !body.hasSuffix(".")
    }
}

private extension String {
    func hasSuffix(where predicate: (Character) -> Bool) -> Bool {
        last.map(predicate) ?? false
    }
}
