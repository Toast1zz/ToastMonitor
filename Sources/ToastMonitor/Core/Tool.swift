import SwiftUI

/// The AI tools ToastMonitor tracks, plus the cloud quota panel.
enum ToolKind: String, CaseIterable, Identifiable {
    case claude = "claude"
    case codex = "codex"
    case opencode = "opencode"
    case hermes = "hermes"
    case omp = "omp"
    case dsh = "dsh"
    case openrouter = "openrouter"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .opencode: return "OpenCode"
        case .hermes: return "Hermes"
        case .omp: return "Oh My Pi"
        case .dsh: return "DeepSeek Harness"
        case .openrouter: return "OpenRouter"
        }
    }

    var symbol: String {
        switch self {
        case .claude: return "sparkles"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .opencode: return "terminal.fill"
        case .hermes: return "wand.and.stars"
        case .omp: return "cpu"
        case .dsh: return "atom"
        case .openrouter: return "arrow.triangle.2.circlepath"
        }
    }

    var color: Color {
        // Each product keeps its brand hue; all share one saturation/
        // brightness family so the page reads harmoniously in both
        // appearances (see Tool.swift palette comment).
        switch self {
        case .claude: return TMDesign.toolColor(hue: 22, sat: 0.55, bri: 0.74)
        case .codex: return TMDesign.toolColor(hue: 214, sat: 0.60, bri: 0.74)
        case .opencode: return TMDesign.toolColor(hue: 150, sat: 0.50, bri: 0.72)
        case .hermes: return TMDesign.toolColor(hue: 272, sat: 0.48, bri: 0.78)
        case .omp: return TMDesign.toolColor(hue: 190, sat: 0.52, bri: 0.72)
        case .dsh: return TMDesign.toolColor(hue: 226, sat: 0.55, bri: 0.74)
        case .openrouter: return TMDesign.toolColor(hue: 356, sat: 0.62, bri: 0.72)
        }
    }

    // MARK: - Source configuration (local Mac vs remote VPS)

    /// Where this tool's usage logs are read from.
    /// "local" = this Mac's files; "remote" = the VPS usage feed.
    var sourceIsRemote: Bool {
        (Database.shared.setting(sourceKey) ?? defaultSource) == "remote"
    }

    /// Whether this collector has a remote-feed implementation. Oh My Pi and
    /// DeepSeek Harness are intentionally local-only; exposing a Remote choice
    /// for them creates a configuration that can never produce data.
    var supportsRemoteSource: Bool {
        switch self {
        case .omp, .dsh, .openrouter:
            return false
        case .claude, .codex, .opencode, .hermes:
            return true
        }
    }

    @discardableResult
    func setSource(remote: Bool) -> Bool {
        guard !remote || supportsRemoteSource else { return false }
        return Database.shared.setSetting(sourceKey, remote ? "remote" : "local")
    }

    var sourceKey: String { "src_\(rawValue)" }

    /// Local-first default. A remote feed is an explicit opt-in in Settings;
    /// a fresh Mac install must not silently depend on a VPS being reachable.
    var defaultSource: String {
        "local"
    }

    /// 主 token 口径：输入 + 输出 + 缓存命中（cacheRead 计入总量；
    /// 唯一例外是 codex——其 input 已含缓存，不重复加）。
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
        /// Reasoning is recorded separately. Providers commonly include it in
        /// output_tokens, so aggregate token totals must not add it a second time.
        let reasoningTokens: Int64
        let cacheRead: Int64
        let cacheWrite: Int64
        let cost: Double
        let provider: String?
        /// Stable source namespace ("local", or a hash of the remote feed URL).
        let sourceInstance: String
        /// Price-table revision used when costQuality == "estimated".
        let pricingVersion: String?
        /// Stable upstream or canonical content identity.
        let eventID: String?
        /// 'actual' | 'estimated' | 'unknown'.
        let costQuality: String

        /// Ceiling for token counts (DB-6): hostile/malformed logs must not be
        /// able to overflow Int64 sums or poison daily/weekly aggregates.
        static let maxTokens: Int64 = 9_000_000_000_000_000
        /// Ceiling for a single turn's estimated/actual cost (USD).
        static let maxCost: Double = 1_000_000_000

        init(tool: ToolKind, sessionID: String, project: String?, model: String?, ts: Int64,
             inputTokens: Int64, outputTokens: Int64, reasoningTokens: Int64 = 0,
             cacheRead: Int64, cacheWrite: Int64, cost: Double,
             provider: String? = nil, sourceInstance: String = "local",
             pricingVersion: String? = Pricing.version, eventID: String? = nil,
             costQuality: String = "estimated") {
            self.tool = tool
            self.sessionID = sessionID
            self.project = project
            self.model = model
            self.ts = ts
            self.inputTokens = min(max(inputTokens, 0), Self.maxTokens)
            self.outputTokens = min(max(outputTokens, 0), Self.maxTokens)
            self.reasoningTokens = min(max(reasoningTokens, 0), Self.maxTokens)
            self.cacheRead = min(max(cacheRead, 0), Self.maxTokens)
            self.cacheWrite = min(max(cacheWrite, 0), Self.maxTokens)
            self.cost = cost.isFinite ? min(max(cost, 0), Self.maxCost) : 0
            self.provider = provider
            self.sourceInstance = sourceInstance
            self.pricingVersion = costQuality == "estimated" ? pricingVersion : nil
            self.eventID = eventID
            self.costQuality = costQuality
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
