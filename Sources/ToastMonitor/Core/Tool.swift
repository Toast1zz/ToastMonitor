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

    /// The product's own brand color where it has one; tools whose brand is
    /// monochrome (OpenCode, Hermes) or unpublished (Oh My Pi) use a system
    /// color so they stay distinguishable and adapt to appearance.
    var color: Color {
        switch self {
        case .claude: return TMDesign.brand(0xD97757)       // Claude brand orange
        case .codex: return TMDesign.brand(0x7A9DFF)        // Codex app icon gradient midpoint
        case .dsh: return TMDesign.brand(0x4D6BFE)          // DeepSeek brand blue
        case .openrouter: return TMDesign.brand(0x7624F4, dark: 0xC8FF00) // OpenRouter Grape / Volt
        case .opencode: return Color(nsColor: .systemGreen)
        case .hermes: return Color(nsColor: .systemPurple)
        case .omp: return Color(nsColor: .systemTeal)
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

    /// Primary token measure: input + output + cache reads. Codex is the
    /// exception: its input already includes cache reads.
    func totalTokens(_ t: Database.ToolTotals) -> Int64 {
        totalTokens(input: t.input, output: t.output, cacheRead: t.cacheRead)
    }

    /// Cache reads are real (cheaper) tokens and count toward the total,
    /// except for Codex, whose input already contains them.
    var cacheIncludedInInput: Bool { self == .codex }

    static var totalTokensSQL: String {
        let included = allCases.filter(\.cacheIncludedInInput).map { "'\($0.rawValue)'" }.joined(separator: ",")
        guard !included.isEmpty else { return "input_tokens + output_tokens + cache_read" }
        return "input_tokens + output_tokens + CASE WHEN tool IN (\(included)) THEN 0 ELSE cache_read END"
    }

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
        /// How a later row with the same event id is combined with the stored one.
        let usageMerge: TurnUsageMerge

    /// Ceiling for one field of one turn. A trillion tokens is far above any
    /// real call, and two values near the old 9e15 ceiling could overflow
    /// Int64 sums and SQLite SUM.
    static let maxTokens: Int64 = 1_000_000_000_000
        /// Ceiling for a single turn's estimated/actual cost (USD).
        static let maxCost: Double = 1_000_000_000

        init(tool: ToolKind, sessionID: String, project: String?, model: String?, ts: Int64,
             inputTokens: Int64, outputTokens: Int64, reasoningTokens: Int64 = 0,
             cacheRead: Int64, cacheWrite: Int64, cost: Double,
             provider: String? = nil, sourceInstance: String = "local",
             pricingVersion: String? = Pricing.version, eventID: String? = nil,
             costQuality: String = "estimated",
             usageMerge: TurnUsageMerge = .ignore) {
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
            self.usageMerge = usageMerge
        }

        /// Field-wise maximum. Time and model follow the snapshot with the
        /// larger token sum. Cost is repriced from the merged tokens when
        /// the model has a rate; otherwise the winner's cost is kept.
        /// One-hour cache writes are not stored on the row, so a reprice
        /// uses the five-minute write rate.
        static func keepingGreater(_ older: TurnRecord, _ newer: TurnRecord) -> TurnRecord {
            let olderSum = older.inputTokens + older.outputTokens + older.reasoningTokens
                + older.cacheRead + older.cacheWrite
            let newerSum = newer.inputTokens + newer.outputTokens + newer.reasoningTokens
                + newer.cacheRead + newer.cacheWrite
            let winner = newerSum >= olderSum ? newer : older
            let model = winner.model ?? older.model ?? newer.model
            let input = max(older.inputTokens, newer.inputTokens)
            let output = max(older.outputTokens, newer.outputTokens)
            let reasoning = max(older.reasoningTokens, newer.reasoningTokens)
            let cacheRead = max(older.cacheRead, newer.cacheRead)
            let cacheWrite = max(older.cacheWrite, newer.cacheWrite)
            let repriced = Pricing.estimate(model: model, input: input, output: output,
                                            cacheRead: cacheRead, cacheWrite: cacheWrite,
                                            inputIncludesCache: winner.tool == .codex)
            return TurnRecord(tool: winner.tool, sessionID: winner.sessionID,
                              project: winner.project ?? older.project ?? newer.project,
                              model: model,
                              ts: winner.ts,
                              inputTokens: input,
                              outputTokens: output,
                              reasoningTokens: reasoning,
                              cacheRead: cacheRead,
                              cacheWrite: cacheWrite,
                              cost: repriced ?? winner.cost,
                              provider: winner.provider ?? older.provider,
                              sourceInstance: winner.sourceInstance,
                              pricingVersion: repriced == nil ? winner.pricingVersion : Pricing.version,
                              eventID: winner.eventID ?? older.eventID,
                              costQuality: repriced == nil ? winner.costQuality : "estimated",
                              usageMerge: .keepGreater)
        }
    }

/// What to do when a turn's event id is already stored.
enum TurnUsageMerge: Equatable {
    /// Keep the first row (`INSERT OR IGNORE`).
    case ignore
    /// Keep the greater token count in each field. A later Claude snapshot
    /// of the same message replaces an earlier partial one.
    case keepGreater
    /// The new row is authoritative (a DeepSeek step's final message).
    case replace
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
