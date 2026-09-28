import Foundation

/// Whether each quota/balance account counts as connected. The popover and
/// the dashboard share these definitions so the same account never reads
/// "Not configured" on one surface while showing numbers on the other.
///
/// Cached numbers count as connected: `configured` is only set once the
/// credential read finishes, and an account with data must not fold away
/// (or show as unconfigured) while that async read is in flight or when the
/// Keychain is locked.
@MainActor
enum AccountConnection {
    static var claude: Bool {
        let quota = ClaudeQuotaClient.shared
        return quota.enabled
            && (quota.state.configured || quota.state.sevenDay != nil
                || quota.state.lastSync > 0 || quota.state.error != nil)
    }

    static var openCodeGo: Bool {
        let client = OpenCodeGoClient.shared
        let keychainLocked = client.state.error?.localizedCaseInsensitiveContains("keychain") == true
        return client.configured || keychainLocked || client.state.lastSync > 0
    }

    static func codex(subscriptions: [Database.Subscription]) -> Bool {
        let subscribed = subscriptions.contains { $0.plan == "openai" || $0.plan == "codex" }
        return subscribed || CodexQuotaClient.shared.state.lastSync > 0
    }

    /// A failing source (expired cookie, locked Keychain) is still a connected
    /// one — its card has to stay visible to show the error.
    static var commandCode: Bool {
        let state = CommandCodeQuotaClient.shared.state
        return state.configured || state.lastSync > 0 || state.monthlyUsedPercent != nil
            || (state.error.map { $0 != "Not configured" } ?? false)
    }

    static var openRouter: Bool { OpenRouterClient.shared.hasKey }

    static var deepSeek: Bool { DeepSeekBillingClient.shared.state.kind != nil }
}
