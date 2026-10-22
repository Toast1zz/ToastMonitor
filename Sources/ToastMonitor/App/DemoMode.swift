import Foundation

/// Made-up usage, quotas and balances for README screenshots (`--demo`).
/// Runs only against a throwaway store named by TM_DATABASE_PATH, so it can
/// never write into, or show, the user's real data.
@MainActor
enum DemoMode {
    static func requested(_ args: [String]) -> Bool { args.contains("--demo") }

    /// Seeds the isolated store and fills the account clients. Returns false
    /// (and does nothing) unless an isolated store is in use.
    static func install(now: Date = Date()) -> Bool {
        guard let path = ProcessInfo.processInfo.environment["TM_DATABASE_PATH"], !path.isEmpty else {
            return false
        }
        if Database.shared.subscriptions().isEmpty {
            seedStore(now: now)
        }
        showAccounts(now: now)
        return true
    }

    private static func seedStore(now: Date) {
        let db = Database.shared
        let day: Int64 = 86_400
        let nowSeconds = Int64(now.timeIntervalSince1970)
        let calendar = Calendar.current
        let today = Int64(calendar.startOfDay(for: now).timeIntervalSince1970)
        var rng = SplitMix(seed: 20)

        // (tool, model, share of a day's tokens, first active day back)
        let mix: [(ToolKind, String, Double, Int)] = [
            (.claude, "claude-opus-5-5", 0.52, 170),
            (.claude, "claude-sonnet-5-5", 0.16, 170),
            (.codex, "gpt-6-sol", 0.2, 120),
            (.opencode, "deepseek-v4.1-flash", 0.12, 80),
        ]
        var turns: [TurnRecord] = []
        for back in stride(from: 170, through: 0, by: -1) {
            // Busier toward the present, with quiet days and weekends.
            let ramp = 1 - Double(back) / 200
            guard rng.unit() < 0.35 + 0.55 * ramp else { continue }
            let dayTokens = (8 + 46 * ramp * rng.unit()) * 1_000_000
            let start = today - Int64(back) * day
            for (tool, model, share, firstBack) in mix where back <= firstBack {
                let tokens = dayTokens * share * (0.6 + 0.8 * rng.unit())
                let calls = 6 + Int(rng.unit() * 18)
                for call in 0..<calls {
                    let ts = start + 9 * 3_600 + Int64(call) * 1_500 + Int64(rng.unit() * 900)
                    guard ts < nowSeconds - 600 else { break }
                    let perCall = tokens / Double(calls)
                    let cacheRead = Int64(perCall * 0.82)
                    let input = Int64(perCall * 0.12)
                    let output = Int64(perCall * 0.05)
                    let cacheWrite = Int64(perCall * 0.01)
                    let cost = Double(input) * 3e-6 + Double(output) * 15e-6
                        + Double(cacheRead) * 0.3e-6 + Double(cacheWrite) * 3.75e-6
                    turns.append(TurnRecord(
                        tool: tool, sessionID: "demo-\(tool.rawValue)-\(back)", project: "demo",
                        model: model, ts: ts, inputTokens: input, outputTokens: output,
                        cacheRead: cacheRead, cacheWrite: cacheWrite, cost: cost,
                        eventID: "demo-\(tool.rawValue)-\(model)-\(back)-\(call)"))
                }
            }
        }
        _ = db.insertTurns(turns)

        let monthAgo = nowSeconds - 40 * day
        _ = db.upsertSubscription(Database.Subscription(
            id: 0, name: "Claude Pro", plan: "claude", startDate: monthAgo,
            cycle: "monthly", price: 20, currency: "USD"))
        _ = db.upsertSubscription(Database.Subscription(
            id: 0, name: "X Subscription Premium", plan: "grok", startDate: nowSeconds - 9 * day,
            cycle: "monthly", price: 30, currency: "USD"))
        // Accounts the demo does not fill would otherwise fold into a
        // "Not connected" line.
        for key in ["go", "codex", "cc"] {
            _ = db.setSetting("hide_quota_row_\(key)", "1")
        }
    }

    private static func showAccounts(now: Date) {
        let nowSeconds = Int64(now.timeIntervalSince1970)
        var claude = ClaudeQuotaClient.State()
        claude.configured = true
        claude.planType = "pro"
        claude.fiveHour = .init(label: "5h", usedPercent: 38, resetAt: nowSeconds + 8_200)
        claude.sevenDay = .init(label: "weekly", usedPercent: 46, resetAt: nowSeconds + 278_000)
        claude.lastSync = nowSeconds
        ClaudeQuotaClient.shared.showDemo(claude)

        var grok = GrokQuotaClient.State()
        grok.configured = true
        grok.planName = "SuperGrok"
        grok.usedPercent = 24
        grok.resetAt = nowSeconds + 390_000
        grok.windowSeconds = 7 * 86_400
        grok.lastSync = nowSeconds
        GrokQuotaClient.shared.showDemo(grok)

        var router = OpenRouterClient.State()
        router.creditsTotal = 20
        router.creditsUsage = 7.6
        router.accountUsage = 7.6
        router.accountBalance = 12.4
        router.lastOK = nowSeconds
        OpenRouterClient.shared.showDemo(router)

        var deepseek = DeepSeekBillingClient.State()
        deepseek.kind = .apiKey
        deepseek.balance = DeepSeekBilling.Balance(
            wallets: [DeepSeekBilling.Wallet(currency: "CNY", paid: 40, granted: Decimal(string: "8.2")!)],
            available: true)
        deepseek.balanceUpdated = now
        DeepSeekBillingClient.shared.showDemo(deepseek)
    }
}

/// Deterministic generator so every demo run draws the same screenshots.
private struct SplitMix {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func unit() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }
}
