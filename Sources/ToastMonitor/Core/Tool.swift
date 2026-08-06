import SwiftUI

/// The AI tools ToastMonitor tracks, plus the cloud quota panel.
enum ToolKind: String, CaseIterable, Identifiable {
    case claude = "claude"
    case codex = "codex"
    case opencode = "opencode"
    case hermes = "hermes"
    case openrouter = "openrouter"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .opencode: return "OpenCode"
        case .hermes: return "Hermes"
        case .openrouter: return "OpenRouter"
        }
    }

    var symbol: String {
        switch self {
        case .claude: return "sparkles"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .opencode: return "terminal.fill"
        case .hermes: return "wand.and.stars"
        case .openrouter: return "arrow.triangle.2.circlepath"
        }
    }

    var color: Color {
        switch self {
        case .claude: return Color(red: 0.80, green: 0.46, blue: 0.24)   // anthropic-ish orange
        case .codex: return Color(red: 0.24, green: 0.55, blue: 0.91)    // codex blue
        case .opencode: return Color(red: 0.36, green: 0.72, blue: 0.44) // terminal green
        case .hermes: return Color(red: 0.72, green: 0.44, blue: 0.86)   // purple
        case .openrouter: return Color(red: 0.86, green: 0.36, blue: 0.36) // red-ish
        }
    }

    // MARK: - Source configuration (local Mac vs remote VPS)

    /// Where this tool's usage logs are read from.
    /// "local" = this Mac's files; "remote" = the VPS usage feed.
    var sourceIsRemote: Bool {
        (Database.shared.setting(sourceKey) ?? defaultSource) == "remote"
    }

    @discardableResult
    func setSource(remote: Bool) -> Bool {
        return Database.shared.setSetting(sourceKey, remote ? "remote" : "local")
    }

    var sourceKey: String { "src_\(rawValue)" }

    /// Local-first default. A remote feed is an explicit opt-in in Settings;
    /// a fresh Mac install must not silently depend on a VPS being reachable.
    var defaultSource: String {
        "local"
    }

    /// 主 token 口径：输入 + 输出。缓存命中输入是输入的计量明细，
    /// 单独展示但不再次加到主数字，避免与 provider 的 input 重复计数。
    func totalTokens(_ t: Database.ToolTotals) -> Int64 {
        totalTokens(input: t.input, output: t.output, cacheRead: t.cacheRead)
    }

    /// 缓存命中也是真实消耗的 token（只是单价便宜）——必须计入总 token
    /// （用户明确要求）。codex 的 cache 已含在 input 中（数据验证 0 行
    /// 超限），不重复加。
    var cacheIncludedInInput: Bool { self == .codex }

    func totalTokens(input: Int64, output: Int64, cacheRead: Int64) -> Int64 {
        input + output + (cacheIncludedInInput ? 0 : cacheRead)
    }
}

/// One LLM turn (one model call) extracted from a tool's logs.
struct TurnRecord: Equatable {
    let tool: ToolKind
    let sessionID: String
    let project: String?
    let model: String?
    let ts: Int64
    let inputTokens: Int64
    let outputTokens: Int64
    let cacheRead: Int64
    let cacheWrite: Int64
    let cost: Double
    /// Stable upstream identity (uuid / file:offset / source:key) — P0-3.
    let eventID: String?
    /// 'actual' | 'estimated' | 'unknown' — money semantics (spec §5.2).
    let costQuality: String
}

extension TurnRecord {
    init(tool: ToolKind, sessionID: String, project: String?, model: String?, ts: Int64,
         inputTokens: Int64, outputTokens: Int64, cacheRead: Int64, cacheWrite: Int64,
         cost: Double) {
        self.init(tool: tool, sessionID: sessionID, project: project, model: model, ts: ts,
                  inputTokens: inputTokens, outputTokens: outputTokens,
                  cacheRead: cacheRead, cacheWrite: cacheWrite, cost: cost,
                  eventID: nil, costQuality: "estimated")
    }
}

/// Session-level info upserted from sources that expose it.
struct SessionInfo: Equatable {
    let tool: ToolKind
    let sessionID: String
    let title: String?
    let project: String?
    let model: String?
    let created: Int64
    let updated: Int64
}
