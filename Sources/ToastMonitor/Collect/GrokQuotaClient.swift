import Foundation
import Combine

/// Grok plan (SuperGrok, now sold as part of The X Subscription) weekly quota via the Grok CLI
/// billing proxy (same approach as CodexBar): reads the bearer token `grok login` stores in
/// ~/.grok/auth.json (never persisted anywhere in ToastMonitor) and GETs
/// https://cli-chat-proxy.grok.com/v1/billing?format=credits, plus
/// /v1/settings for the plan name.
///
/// EXPERIMENTAL: the proxy is the Grok CLI's own backend, not a documented
/// public API. Paid plans share one weekly pool across Grok Chat, Imagine,
/// Build / CLI and Grok Bot, so this one query covers all of them; the API
/// reports it as a percentage and optionally breaks it down per product.
///
/// The token lives only in memory for the request; auth.json is never
/// written. Failures are explicit states, never guessed numbers.
@MainActor
final class GrokQuotaClient: ObservableObject {
    static let shared = GrokQuotaClient()
    nonisolated static let maxResponseBytes = 10_000_000
    nonisolated static let billingURL = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!
    nonisolated static let settingsURL = URL(string: "https://cli-chat-proxy.grok.com/v1/settings")!
    /// `grok login` writes one entry per scope; the OIDC scope is SuperGrok.
    nonisolated static let oidcScopePrefix = "https://auth.x.ai::"
    nonisolated static let legacySessionScope = "https://accounts.x.ai/sign-in"
    static let enabledSettingKey = "grok_quota_enabled"
    static let notConfigured = "Grok login not found (run grok login)"
    nonisolated static let expired = "Grok login expired — run grok once"

    struct ProductUsage: Equatable {
        let product: String
        let usedPercent: Double

        /// "GrokBuild" → "Grok Build"; unknown products are split the same way.
        var displayName: String {
            var out = ""
            for ch in product {
                if ch.isUppercase, let last = out.last, last.isLowercase { out.append(" ") }
                out.append(ch)
            }
            return out
        }
    }

    struct Snapshot: Equatable {
        var usedPercent: Double?
        var resetAt: Int64?
        var windowSeconds: Int?
        var planName: String?
        var products: [ProductUsage] = []
        var prepaidBalanceUSD: Double?
    }

    struct State {
        var configured = false
        var planName: String?
        var usedPercent: Double?
        var resetAt: Int64?
        var windowSeconds: Int?
        var products: [ProductUsage] = []
        var prepaidBalanceUSD: Double?
        var lastSync: Int64 = 0
        var error: String?
        var isLoading = false
    }

    struct Credentials: Equatable {
        let accessToken: String
        let expiresAt: Date?
    }

    @Published private(set) var state = State()

    /// README screenshots only (`--demo`): shows made-up numbers instead of
    /// fetching anything.
    func showDemo(_ demo: State) {
        isDemo = true
        state = demo
    }
    /// Set by `showDemo`; a demo client never fetches, so nothing real can
    /// replace the made-up numbers.
    private var isDemo = false
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

    // MARK: - Foreground-aware refresh

    @Published private(set) var enabled = false
    private var loadedPreference = false

    /// Off until the user opts in. Enabling can run `grok` in the background
    /// when the saved access token is expired.
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

    // MARK: - Refresh

    func refresh() {
        guard enabled, !inFlight, !isDemo else { return }
        // Backoff gate: skip attempts inside the backoff window.
        if backoff.isWaiting { return }
        inFlight = true
        refreshGeneration &+= 1
        let generation = refreshGeneration

        // Never read auth.json on the main actor.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var credentials = Self.loadCredentials()
            // The access token lasts about six hours; let the Grok CLI renew
            // it from the refresh token instead of asking for a new login.
            if let expiresAt = credentials?.expiresAt, expiresAt <= Date(), GrokCLIRefresher.refresh() {
                credentials = Self.loadCredentials()
            }
            Task { @MainActor [weak self] in
                guard let self, self.refreshGeneration == generation else { return }
                guard let credentials else {
                    self.inFlight = false
                    self.state.configured = false
                    self.state.isLoading = false
                    self.state.error = Self.notConfigured
                    return
                }
                self.state.configured = true
                if let expiresAt = credentials.expiresAt, expiresAt <= Date() {
                    self.inFlight = false
                    self.state.isLoading = false
                    self.state.error = Self.expired
                    return
                }
                self.requestUsage(token: credentials.accessToken, generation: generation)
            }
        }
    }

    nonisolated static func authFileURL(env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let custom = env["GROK_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
                .appendingPathComponent("auth.json")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".grok/auth.json")
    }

    private nonisolated static func loadCredentials() -> Credentials? {
        guard let data = try? Data(contentsOf: authFileURL()), data.count <= 1_000_000 else { return nil }
        return parseCredentials(data)
    }

    /// auth.json is a map keyed by scope URL. Prefer the OIDC (SuperGrok)
    /// entry, then the legacy session entry; only entries with a usable
    /// bearer token count, so a half-written OIDC record cannot shadow a
    /// healthy legacy one.
    nonisolated static func parseCredentials(_ data: Data) -> Credentials? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var oidc: [String: Any]?
        var legacy: [String: Any]?
        for (scope, value) in root.sorted(by: { $0.key < $1.key }) {
            guard let entry = value as? [String: Any], validToken(entry["key"]) != nil else { continue }
            if scope.hasPrefix(oidcScopePrefix) {
                oidc = oidc ?? entry
            } else if scope == legacySessionScope || scope.contains("/sign-in") {
                legacy = legacy ?? entry
            }
        }
        guard let entry = oidc ?? legacy, let token = validToken(entry["key"]) else { return nil }
        return Credentials(accessToken: token,
                           expiresAt: (entry["expires_at"] as? String).flatMap(isoDate))
    }

    private nonisolated static func validToken(_ raw: Any?) -> String? {
        guard let token = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty, token.count <= 16_384,
              token.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        return token
    }

    private func requestUsage(token: String, generation: UInt64) {
        state.isLoading = true

        func makeRequest(_ url: URL) -> URLRequest {
            var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            req.httpMethod = "GET"
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("xai-grok-cli", forHTTPHeaderField: "x-xai-token-auth")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.setValue("ToastMonitor", forHTTPHeaderField: "User-Agent")
            return req
        }

        let group = DispatchGroup()
        var billingResult: Result<Data, CommandCodeQuotaClient.HTTPError>?
        var settingsData: Data?

        // Enter BEFORE resume: group.notify must observe a non-zero count.
        group.enter()
        let billingTask = redirectBlocker.boundedDataTask(
            in: session, request: makeRequest(Self.billingURL), maxBytes: Self.maxResponseBytes
        ) { data, resp, err in
            billingResult = CommandCodeQuotaClient.validate(data: data, response: resp, error: err)
            group.leave()
        }
        // The plan name is optional enrichment: a settings failure never
        // discards a valid quota reading.
        group.enter()
        let settingsTask = redirectBlocker.boundedDataTask(
            in: session, request: makeRequest(Self.settingsURL), maxBytes: Self.maxResponseBytes
        ) { data, resp, err in
            if case .success(let data) = CommandCodeQuotaClient.validate(data: data, response: resp, error: err) {
                settingsData = data
            }
            group.leave()
        }
        billingTask.resume()
        settingsTask.resume()

        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            // Always clear inFlight — even for a stale generation.
            self.inFlight = false
            guard self.refreshGeneration == generation else { return }
            self.state.isLoading = false
            switch billingResult {
            case .success(let data)?:
                guard var snapshot = Self.parseBilling(data) else {
                    self.state.error = "Failed to parse Grok billing response"
                    self.backoff.failed()
                    return
                }
                if let plan = settingsData.flatMap(Self.parsePlanName) {
                    snapshot.planName = plan
                }
                self.apply(snapshot)
            case .failure(.status(let code))? where code == 401 || code == 403:
                // Rejected before its expiry (revoked, or the clock is off):
                // one CLI renewal, then a normal refresh with the new token.
                self.state.error = Self.expired
                self.renewAfterRejection()
            case .failure(let error)?:
                self.state.error = Self.message(for: error)
                self.backoff.failed()
            case nil:
                self.state.error = "Grok billing request failed"
                self.backoff.failed()
            }
        }
    }

    private func renewAfterRejection() {
        inFlight = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let renewed = GrokCLIRefresher.refresh()
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.inFlight = false
                if renewed {
                    self.refresh()
                } else {
                    self.backoff.failed()
                }
            }
        }
    }

    private func apply(_ snapshot: Snapshot) {
        state.usedPercent = snapshot.usedPercent
        state.resetAt = snapshot.resetAt
        state.windowSeconds = snapshot.windowSeconds
        // Keep the last known plan when settings was unavailable this round.
        state.planName = snapshot.planName ?? state.planName
        state.products = snapshot.products
        state.prepaidBalanceUSD = snapshot.prepaidBalanceUSD
        state.lastSync = Int64(Date().timeIntervalSince1970)
        state.error = nil
        backoff.succeeded()
    }


    nonisolated static func message(for error: CommandCodeQuotaClient.HTTPError) -> String {
        switch error {
        case .transport(let message):
            return message
        case .redirect(let code):
            return "Redirect rejected (HTTP \(code))"
        case .status(let code):
            if code == 401 || code == 403 {
                return expired
            }
            return "Grok billing API HTTP \(code)"
        case .parse:
            return "Failed to parse Grok billing response"
        case .tooLarge:
            return "Grok billing response too large"
        }
    }

    // MARK: - Parsing

    /// Decodes `/v1/billing?format=credits`. The weekly percentage is
    /// `config.creditUsagePercent`, falling back to on-demand used/cap.
    /// Proto3 JSON omits zero scalars, so a current period with no
    /// percentage means nothing used yet. Returns nil when the payload has
    /// neither a percentage, a period nor a balance.
    nonisolated static func parseBilling(_ data: Data, now: Date = Date()) -> Snapshot? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let config = root["config"] as? [String: Any] else { return nil }

        let current = config["currentPeriod"] as? [String: Any]
        let currentEnd = (current?["end"] as? String).flatMap(isoDate)
        let end = currentEnd ?? (config["billingPeriodEnd"] as? String).flatMap(isoDate)
        // Never pair a start and end from different periods.
        let start = (currentEnd == nil ? config["billingPeriodStart"] : current?["start"])
            .flatMap { $0 as? String }.flatMap(isoDate)

        var percent = finite(config["creditUsagePercent"])
        if percent == nil,
           let cap = finite((config["onDemandCap"] as? [String: Any])?["val"]), cap > 0,
           let used = finite((config["onDemandUsed"] as? [String: Any])?["val"]) {
            percent = used / cap * 100
        }
        if percent == nil, let end, end > now {
            percent = 0
        }

        let balance = prepaidBalanceUSD(config["prepaidBalance"])
        guard percent != nil || end != nil || balance != nil else { return nil }

        var snapshot = Snapshot()
        snapshot.usedPercent = percent.map { min(max($0, 0), 100) }
        snapshot.resetAt = end.map { Int64($0.timeIntervalSince1970) }
        if let start, let end, end > start, start <= now {
            snapshot.windowSeconds = Int(end.timeIntervalSince(start))
        }
        snapshot.planName = planDisplayName(root["subscriptionTier"] as? String)
            ?? planDisplayName(config["subscriptionTier"] as? String)
        snapshot.products = products(config["productUsage"], total: percent)
        snapshot.prepaidBalanceUSD = balance
        return snapshot
    }

    /// Per-product shares of the weekly pool. They must add up to the
    /// reported total (±1 point); otherwise the breakdown is dropped rather
    /// than shown inconsistent with the bar.
    nonisolated static func products(_ raw: Any?, total: Double?) -> [ProductUsage] {
        guard let total, let items = raw as? [[String: Any]], !items.isEmpty else { return [] }
        var out: [ProductUsage] = []
        for item in items {
            guard let name = (item["product"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty, name.count <= 64,
                  name.rangeOfCharacter(from: .controlCharacters) == nil,
                  let pct = finite(item["usagePercent"]), pct >= 0 else { return [] }
            out.append(ProductUsage(product: name, usedPercent: pct))
        }
        let sum = out.reduce(0) { $0 + $1.usedPercent }
        guard abs(sum - total) <= 1 else { return [] }
        return out.filter { $0.usedPercent > 0 }.sorted { $0.usedPercent > $1.usedPercent }
    }

    /// The plan recorded under Settings › Sources › Subscriptions (plan
    /// "grok") wins over the API's tier: the API still reports some X
    /// Subscription accounts as "SuperGrok".
    nonisolated static func plan(subscriptions: [Database.Subscription], apiPlan: String?,
                                 now: Date = Date()) -> String? {
        let nowSeconds = Int64(now.timeIntervalSince1970)
        return subscriptions.first { $0.plan == "grok" && ($0.endDate == 0 || $0.endDate > nowSeconds) }?.name
            ?? apiPlan
    }

    /// `/v1/settings` → `subscription_tier_display`.
    nonisolated static func parsePlanName(_ data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return planDisplayName(root["subscription_tier_display"] as? String)
    }

    nonisolated static func planDisplayName(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty,
              trimmed.count <= 64, trimmed.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        switch trimmed.lowercased().filter(\.isLetter) {
        case "supergrokheavy", "heavy": return "SuperGrok Heavy"
        case "supergrok": return "SuperGrok"
        default: return trimmed
        }
    }

    /// The Cent object is USD cents; an empty object is proto3 for zero.
    nonisolated static func prepaidBalanceUSD(_ raw: Any?) -> Double? {
        guard let object = raw as? [String: Any] else { return nil }
        guard let value = object["val"] else { return object.isEmpty ? 0 : nil }
        let cents: Double?
        if let s = value as? String { cents = Double(s) } else { cents = finite(value) }
        guard let cents, cents.isFinite, cents >= 0 else { return nil }
        return cents / 100
    }

    private nonisolated static func finite(_ raw: Any?) -> Double? {
        guard let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let d = n.doubleValue
        return d.isFinite ? d : nil
    }

    /// ISO 8601 with or without fractional seconds; fractions longer than
    /// milliseconds (the proxy sends microseconds) are truncated first.
    nonisolated static func isoDate(_ raw: String) -> Date? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let dot = value.firstIndex(of: ".") {
            let digits = value[value.index(after: dot)...].prefix(while: \.isNumber)
            if digits.count > 3 {
                value.replaceSubrange(value.index(after: dot)..<digits.endIndex, with: digits.prefix(3))
            }
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = formatter.date(from: value) { return d }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}
