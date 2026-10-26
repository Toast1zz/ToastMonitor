import Foundation
import Combine

/// Codex subscription quota via the official ChatGPT backend usage endpoint
/// (same approach as CodexBar / steipete): reads the OAuth token from
/// ~/.codex/auth.json (never persisted anywhere in ToastMonitor) and GETs
/// https://chatgpt.com/backend-api/wham/usage.
///
/// The token lives only in memory for the request; failures are explicit
/// states, never guessed numbers.
    @MainActor
final class CodexQuotaClient: ObservableObject {
    static let shared = CodexQuotaClient()
    static let maxResponseBytes = 10_000_000
    static let enabledSettingKey = "codex_quota_enabled"
    struct State {
        var planType: String?
        var primaryPct: Int?       // primary_window used_percent
        var windowSeconds: Int?    // limit_window_seconds (604800 = weekly)
        var resetAt: Int64?        // absolute reset time (unix seconds)
        var lastSync: Int64 = 0
        var error: String?
    }

    private static func boundedPercent(_ value: NSNumber?) -> Int? {
        guard let value else { return nil }
        let d = value.doubleValue
        guard d.isFinite, d >= 0, d <= 100 else { return nil }
        return Int(d.rounded())
    }

    private static func boundedWindow(_ value: NSNumber?) -> Int? {
        guard let value else { return nil }
        let d = value.doubleValue
        guard d.isFinite, d >= 0, d <= 366 * 86400 else { return nil }
        return Int(d.rounded())
    }

    private static func boundedReset(_ value: NSNumber?) -> Int64? {
        guard let value else { return nil }
        let d = value.doubleValue
        let now = Date().timeIntervalSince1970
        guard d.isFinite, d >= now - 10 * 365 * 86400, d <= now + 366 * 86400 else { return nil }
        return Int64(d)
    }
    @Published private(set) var state = State()
    private var started = false
    private var inFlight = false
    private var refreshGeneration: UInt64 = 0
    private var backoff = RefreshBackoff()
    private let poller = ForegroundPoller()

    private let session: URLSession
    /// Retained because URLSession delegates are weak.
    private let redirectBlocker = NoRedirectDelegate()

    private init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 30
        session = URLSession(configuration: cfg, delegate: redirectBlocker, delegateQueue: nil)
    }


    @Published private(set) var enabled = false
    private var loadedPreference = false

    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        loadedPreference = true
        DispatchQueue.global(qos: .utility).async {
            _ = Database.shared.setSetting(Self.enabledSettingKey, on ? "1" : nil)
        }
        if on {
            started = false
            start()
        } else {
            started = false
            poller.stop()
            refreshGeneration &+= 1
            inFlight = false
        }
    }

    func start() {
        if !loadedPreference {
            enabled = Database.shared.setting(Self.enabledSettingKey) == "1"
            loadedPreference = true
        }
        guard enabled, !started else { return }
        started = true
        refresh()
        poller.start { [weak self] in MainActor.assumeIsolated { self?.refresh() } }
    }

    func refresh() {
        guard enabled, !inFlight else { return }
        // Backoff gate: skip attempts inside the backoff window.
        if backoff.isWaiting { return }
        inFlight = true
        refreshGeneration &+= 1
        let generation = refreshGeneration

        // Dashboard visibility and native toolbar actions must never perform
        // synchronous disk I/O on the main actor.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let accessToken = Self.loadAccessToken()
            Task { @MainActor [weak self] in
                guard let self, self.refreshGeneration == generation else { return }
                guard let accessToken else {
                    self.inFlight = false
                    self.state.error = "Codex login not found (sign in with codex to restore)"
                    return
                }
                self.requestUsage(accessToken: accessToken, generation: generation)
            }
        }
    }

    private nonisolated static func loadAccessToken() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let authPath = home.appendingPathComponent(".codex/auth.json").path

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: authPath)),
              data.count <= 1_000_000,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = json["tokens"] as? [String: Any],
              let accessToken = tokens["access_token"] as? String,
              !accessToken.isEmpty, accessToken.count <= 16_384,
              accessToken.rangeOfCharacter(from: .controlCharacters) == nil else {
            return nil
        }
        return accessToken
    }

    private func requestUsage(accessToken: String, generation: UInt64) {
        guard let url = URL(string: "https://chatgpt.com/backend-api/wham/usage") else {
            inFlight = false
            return
        }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        req.httpMethod = "GET"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("ToastMonitor", forHTTPHeaderField: "User-Agent")

        redirectBlocker.boundedDataTask(in: session, request: req,
                                        maxBytes: Self.maxResponseBytes) { [weak self] data, resp, err in
            guard let self else { return }
            // This completion runs on a URLSession delegate queue; all
            // state mutations below are @MainActor-isolated.
            DispatchQueue.main.async {
                // Always clear inFlight — even for a stale generation —
                // or the guard would never recover from an old response.
                self.inFlight = false
                guard self.refreshGeneration == generation else { return }
                if let err {
                    self.state.error = err.localizedDescription
                    self.backoff.failed()
                    return
                }
                guard let http = resp as? HTTPURLResponse else {
                    self.state.error = "No HTTP response"
                    self.backoff.failed()
                    return
                }
                if (300..<400).contains(http.statusCode) {
                    self.state.error = "Redirect rejected (HTTP \(http.statusCode))"
                    self.backoff.failed()
                    return
                }
                guard http.statusCode == 200 else {
                    self.state.error = (http.statusCode == 401 || http.statusCode == 403)
                        ? "Codex login expired — reconfigure (sign in with codex to restore)"
                        : "usage API HTTP \(http.statusCode)"
                    self.backoff.failed()
                    return
                }
                guard http.expectedContentLength <= 10_000_000,
                      let data, data.count <= 10_000_000,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    self.state.error = "Failed to parse usage response"
                    self.backoff.failed()
                    return
                }
                if let rawPlan = json["plan_type"] as? String,
                   rawPlan.count <= 128,
                   rawPlan.rangeOfCharacter(from: .controlCharacters) == nil {
                    self.state.planType = rawPlan
                } else {
                    self.state.planType = nil
                }
                self.state.primaryPct = nil
                self.state.windowSeconds = nil
                self.state.resetAt = nil
                if let rl = json["rate_limit"] as? [String: Any],
                   let pw = rl["primary_window"] as? [String: Any] {
                    self.state.primaryPct = Self.boundedPercent(pw["used_percent"] as? NSNumber)
                    self.state.windowSeconds = Self.boundedWindow(pw["limit_window_seconds"] as? NSNumber)
                    self.state.resetAt = Self.boundedReset(pw["reset_at"] as? NSNumber)
                }
                self.state.lastSync = Int64(Date().timeIntervalSince1970)
                self.state.error = nil
                self.backoff.succeeded()
            }
        }.resume()
    }

}

/// Display name for the Codex quota row. A user-set name wins; otherwise the
/// plan the usage API reports, then the plan implied by the subscription's
/// price, then plain "Codex".
enum CodexPlanName {
    static let customNameKey = "codexDisplayName"

    static func resolve(custom: String?, apiPlan: String?,
                        subscription: Database.Subscription?) -> String {
        if let custom = custom?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
            return custom
        }
        if let tier = tier(apiPlan: apiPlan) ?? subscription.flatMap(tier(subscription:)) {
            return "Codex \(tier)"
        }
        return "Codex"
    }

    /// ChatGPT `plan_type` values; unknown ones are title-cased as-is.
    static func tier(apiPlan: String?) -> String? {
        guard let raw = apiPlan?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty else { return nil }
        switch raw {
        case "free": return "Free"
        case "go": return "Go"
        case "plus": return "Plus"
        case "pro": return "Pro"
        // OpenAI renamed Team to Business; the API still says "team".
        case "team", "business": return "Business"
        case "enterprise": return "Enterprise"
        case "edu", "education": return "Edu"
        default:
            return raw.split(whereSeparator: { $0 == "_" || $0 == "-" || $0 == " " })
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
        }
    }

    /// Monthly price bands: Go is under $14, Plus around $20 (with local tax
    /// up to ~$25), Pro $200. Business is per-seat and overlaps Plus, so it
    /// is left to the API or a custom name.
    static func tier(subscription: Database.Subscription) -> String? {
        let monthly = subscription.cycle == "yearly" ? subscription.price / 12 : subscription.price
        guard monthly.isFinite, monthly > 0 else { return nil }
        if monthly < 14 { return "Go" }
        if monthly < 100 { return "Plus" }
        return "Pro"
    }
}
