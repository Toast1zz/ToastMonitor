import Foundation
import Combine

/// Command Code subscription quota (GOAT plan) via the private billing API.
///
/// EXPERIMENTAL: the endpoint (api.commandcode.ai/internal/billing/*) is not
/// a documented public API and may change without notice. Enabled only when
/// the user explicitly provides their Studio session cookie.
///
/// Auth: Better Auth session cookie stored ONLY in the macOS Keychain. The
/// cookie is read once per refresh and kept in memory only for the request.
///
/// Fetch policy: background refresh only while the Popover or Dashboard is
/// visible, at most once per 60 seconds. Failures keep the last good snapshot
/// and are labelled stale — never zeroed or fabricated.
@MainActor
final class CommandCodeQuotaClient: ObservableObject {
    static let shared = CommandCodeQuotaClient()
    static let maxCookieLength = 16_384
    static let maxResponseBytes = 10_000_000

    /// Keychain account used for the full `Cookie:` header value.
    static let keychainAccount = "commandcode-cookie"

    /// The three Better Auth session cookie names the app accepts. Provisioning
    /// stores whatever the user pastes as the full Cookie header; this list is
    /// only used for the token-only convenience form.
    ///
    /// NOTE: the live cookie name is Command Code's production prefix
    /// (`__Secure-commandcode_prod_.session_token`), NOT the stock Better Auth
    /// name the original skill assumed — verified against the real API on
    /// 2026-08-18. The token-only convenience form wraps bare tokens in the
    /// real name so they work without the session_data cookie.
    static let sessionCookieNames = [
        "__Secure-commandcode_prod_.session_token",
        "__Host-commandcode_prod_.session_token",
        "__Secure-better-auth.session_token",
        "better-auth.session_token",
    ]

    struct State {
        var configured = false
        var planID: String?
        var planName: String?
        var monthlyCreditsRemaining: Double?
        var monthlyCreditsTotal: Double?
        var monthlyCreditsUsed: Double?
        var monthlyUsedPercent: Double?
        var purchasedCredits: Double?
        var billingPeriodEnd: Date?
        var subscriptionStatus: String?
        var lastSync: Int64 = 0
        var error: String?
        var isLoading = false
    }

    @Published private(set) var state = State()
    private var timer: Timer?
    private var started = false
    private var inFlight = false
    private var refreshGeneration: UInt64 = 0

    private let session: URLSession
    /// Retained because URLSession delegates are weak.
    private let redirectBlocker = NoRedirectDelegate()
    private var cachedCookie: String?
    private var keychainLocked = false

    private init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 30
        session = URLSession(configuration: cfg, delegate: redirectBlocker, delegateQueue: nil)
        observeForeground()
    }

    // MARK: - Foreground-aware refresh

    private var popoverVisible = false
    private var dashboardVisible = false
    private var foreground = false

    private func updateForeground() {
        let fg = popoverVisible || dashboardVisible
        guard fg != foreground else { return }
        foreground = fg
        if fg {
            startTimer()
            refresh()
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    private func observeForeground() {
        for name in [TMNotifications.popoverVisibility, TMNotifications.dashboardVisibility] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let visible = (note.object as? Bool) ?? false
                    if name == TMNotifications.popoverVisibility {
                        self.popoverVisible = visible
                    } else {
                        self.dashboardVisible = visible
                    }
                    self.updateForeground()
                }
            }
        }
    }

    func start() {
        guard !started else { return }
        started = true
        refresh()
        updateForeground()
    }

    private func startTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: - Provisioning

    /// Stores the full Cookie header in the Keychain. Accepts either a
    /// complete `Cookie:` header or a bare session token (wrapped in the
    /// standard Better Auth cookie). Only the Keychain is written; nothing
    /// plaintext is persisted.
    @discardableResult
    func provision(cookie raw: String) -> Bool {
        guard let normalized = Self.normalizedCookie(raw) else {
            state.error = "Invalid cookie"
            return false
        }
        if KeychainStore.set(normalized, account: Self.keychainAccount, allowPrompt: true) {
            cachedCookie = normalized
            state.configured = true
            state.error = nil
            keychainLocked = false
            refresh()
            return true
        }
        keychainLocked = KeychainStore.lastWasInteractionNotAllowed
        state.error = keychainLocked
            ? "Keychain locked — cookie not saved"
            : "Keychain write failed — cookie not saved"
        return false
    }

    func clear() {
        KeychainStore.delete(account: Self.keychainAccount, allowPrompt: true)
        cachedCookie = nil
        state = State()
        state.error = "Not configured"
        keychainLocked = false
    }

    private static func normalizedCookie(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Bare token convenience: wrap in the real production cookie name.
        // (The stock Better Auth name is NOT what the live API accepts.)
        if !value.contains("=") {
            value = "__Secure-commandcode_prod_.session_token=\(value)"
        }
        guard !value.isEmpty,
              value.count <= maxCookieLength,
              value.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        return value
    }

    // MARK: - Refresh

    func refresh() {
        guard !inFlight else { return }
        inFlight = true
        refreshGeneration &+= 1
        let generation = refreshGeneration

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let cookie = self?.loadCookie()
            Task { @MainActor [weak self] in
                guard let self, self.refreshGeneration == generation else { return }
                guard let cookie else {
                    self.inFlight = false
                    self.state.error = self.keychainLocked
                        ? "Keychain locked — unlock to refresh"
                        : "Not configured"
                    self.state.isLoading = false
                    return
                }
                self.requestUsage(cookie: cookie, generation: generation)
            }
        }
    }

    private nonisolated func loadCookie() -> String? {
        let ck = KeychainStore.get(account: Self.keychainAccount)
        let locked = KeychainStore.lastWasInteractionNotAllowed
        Task { @MainActor in
            self.keychainLocked = locked
        }
        return ck
    }

    private func requestUsage(cookie: String, generation: UInt64) {
        state.isLoading = true
        state.error = nil
        let host = URL(string: "https://api.commandcode.ai")!
        let creditsURL = host.appendingPathComponent("internal/billing/credits")
        let subsURL = host.appendingPathComponent("internal/billing/subscriptions")

        func makeRequest(_ url: URL) -> URLRequest {
            var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 15)
            req.httpMethod = "GET"
            req.setValue(cookie, forHTTPHeaderField: "Cookie")
            req.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
            req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
            req.setValue("https://commandcode.ai", forHTTPHeaderField: "Origin")
            req.setValue("https://commandcode.ai/", forHTTPHeaderField: "Referer")
            req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36",
                         forHTTPHeaderField: "User-Agent")
            return req
        }

        let group = DispatchGroup()
        var creditsResult: Result<Data, HTTPError>?
        var subsResult: Result<Data, HTTPError>?

        // Enter BEFORE resume: group.notify must observe a non-zero count.
        // Entering inside the completion (asynchronously) let notify fire
        // immediately with nil results, leaving isLoading stuck true.
        group.enter()
        let creditsTask = redirectBlocker.boundedDataTask(
            in: session, request: makeRequest(creditsURL),
            maxBytes: Self.maxResponseBytes
        ) { data, resp, err in
            creditsResult = Self.validate(data: data, response: resp, error: err)
            group.leave()
        }
        group.enter()
        let subsTask = redirectBlocker.boundedDataTask(
            in: session, request: makeRequest(subsURL),
            maxBytes: Self.maxResponseBytes
        ) { data, resp, err in
            subsResult = Self.validate(data: data, response: resp, error: err)
            group.leave()
        }
        creditsTask.resume()
        subsTask.resume()

        group.notify(queue: .main) { [weak self] in
            guard let self, self.refreshGeneration == generation else { return }
            self.inFlight = false
            self.state.isLoading = false
            self.state.lastSync = Int64(Date().timeIntervalSince1970)

            // Prefer a hard error over partial data: if either endpoint
            // failed at the HTTP layer, report it and keep the old snapshot.
            switch (creditsResult, subsResult) {
            case (.failure(let creditsError), _):
                self.state.error = Self.message(for: creditsError)
                return
            case (_, .failure(let subsError)):
                self.state.error = Self.message(for: subsError)
                return
            default:
                break
            }
            guard case .success(let creditsData)? = creditsResult,
                  case .success(let subsData)? = subsResult else {
                // Defensive: both endpoints completed (group notified) but a
                // result is missing — never leave a stuck Loading state.
                self.state.error = "Billing request failed"
                return
            }

            let parsed = Self.parse(creditsData: creditsData, subsData: subsData)
            self.apply(parsed)
        }
    }

    enum HTTPError: Equatable, Error {
        case transport(String)
        case redirect(Int)
        case status(Int)
        case parse
        case tooLarge
    }

    nonisolated static func validate(data: Data?, response: URLResponse?, error: Error?)
        -> Result<Data, HTTPError> {
        if let error {
            return .failure(.transport(error.localizedDescription))
        }
        guard let http = response as? HTTPURLResponse else {
            return .failure(.transport("No HTTP response"))
        }
        if (300..<400).contains(http.statusCode) {
            return .failure(.redirect(http.statusCode))
        }
        guard (200..<300).contains(http.statusCode) else {
            return .failure(.status(http.statusCode))
        }
        guard let data, data.count <= maxResponseBytes,
              http.expectedContentLength <= maxResponseBytes else {
            return .failure(.tooLarge)
        }
        return .success(data)
    }

    nonisolated static func message(for error: HTTPError) -> String {
        switch error {
        case .transport(let message):
            return message
        case .redirect(let code):
            return "Redirect rejected (HTTP \(code))"
        case .status(let code):
            if code == 401 || code == 403 {
                return "Studio session expired — reconfigure"
            }
            return "Command Code billing API HTTP \(code)"
        case .parse:
            return "Failed to parse billing response"
        case .tooLarge:
            return "Billing response too large"
        }
    }

    // MARK: - Parsing

    struct Parsed: Equatable {
        var monthlyCreditsRemaining: Double?
        var purchasedCredits: Double?
        var planID: String?
        var subscriptionStatus: String?
        var billingPeriodEnd: Date?
    }

    /// Decodes both endpoints with strict types. `data: null` (no active
    /// subscription) is valid; a missing/unfinite `monthlyCredits` is a
    /// distinct error state.
    nonisolated static func parse(creditsData: Data, subsData: Data) -> Result<Parsed, HTTPError> {
        guard let creditsJSON = try? JSONSerialization.jsonObject(with: creditsData) as? [String: Any],
              let credits = creditsJSON["credits"] as? [String: Any] else {
            return .failure(.parse)
        }
        let monthly = boundedAmount(credits["monthlyCredits"])
        let purchased = boundedAmount(credits["purchasedCredits"])

        var planID: String?
        var status: String?
        var periodEnd: Date?
        if let subsJSON = try? JSONSerialization.jsonObject(with: subsData) as? [String: Any],
           let data = subsJSON["data"] as? [String: Any] {
            if let rawPlan = data["planId"] as? String,
               !rawPlan.isEmpty, rawPlan.count <= 128,
               rawPlan.rangeOfCharacter(from: .controlCharacters) == nil {
                planID = rawPlan
            }
            if let rawStatus = data["status"] as? String,
               !rawStatus.isEmpty, rawStatus.count <= 64,
               rawStatus.rangeOfCharacter(from: .controlCharacters) == nil {
                status = rawStatus
            }
            if let raw = data["currentPeriodEnd"] as? String,
               let date = Self.isoDate(raw) {
                periodEnd = date
            }
        }

        var parsed = Parsed()
        parsed.monthlyCreditsRemaining = monthly
        parsed.purchasedCredits = purchased
        parsed.planID = planID
        parsed.subscriptionStatus = status
        parsed.billingPeriodEnd = periodEnd
        return .success(parsed)
    }

    /// Accepts string or numeric amounts; rejects non-finite or negative.
    nonisolated static func boundedAmount(_ value: Any?) -> Double? {
        let d: Double?
        if let n = value as? NSNumber {
            d = n.doubleValue
        } else if let s = value as? String, let v = Double(s) {
            d = v
        } else {
            return nil
        }
        guard let d, d.isFinite, d >= 0 else { return nil }
        return d
    }

    nonisolated static func isoDate(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = formatter.date(from: raw) { return d }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }

    /// Core computation: used = total − remaining, clamped to 0…100%.
    nonisolated static func computeUsed(remaining: Double?, total: Double?) -> (used: Double?, percent: Double?)? {
        guard let remaining, let total, total > 0, remaining.isFinite, total.isFinite else {
            return nil
        }
        let used = max(0, min(total, total - remaining))
        let percent = max(0, min(100, used / total * 100))
        return (used, percent)
    }

    private func apply(_ result: Result<Parsed, HTTPError>) {
        guard case .success(let parsed) = result else {
            state.error = Self.message(for: .parse)
            return
        }
        state.monthlyCreditsRemaining = parsed.monthlyCreditsRemaining
        state.purchasedCredits = parsed.purchasedCredits
        state.planID = parsed.planID
        state.subscriptionStatus = parsed.subscriptionStatus
        state.billingPeriodEnd = parsed.billingPeriodEnd

        // Plan name/allowance: only from a known planId; unknown plans show
        // an explicit unknown state and never fabricate a percentage.
        if let planID = parsed.planID {
            state.planID = planID
            if let total = CommandCodePlanCatalog.allowance(forPlanID: planID) {
                state.planName = planID
                state.monthlyCreditsTotal = total
                if let computed = Self.computeUsed(remaining: parsed.monthlyCreditsRemaining,
                                                   total: total) {
                    state.monthlyCreditsUsed = computed.used
                    state.monthlyUsedPercent = computed.percent
                } else {
                    state.monthlyCreditsUsed = nil
                    state.monthlyUsedPercent = nil
                }
                state.error = nil
            } else {
                // Unknown plan: keep remaining/purchased/reset displayable,
                // but no percentage and no fabricated allowance.
                state.planName = nil
                state.monthlyCreditsTotal = nil
                state.monthlyCreditsUsed = nil
                state.monthlyUsedPercent = nil
                state.error = "Unknown Command Code plan: \(planID)"
            }
        } else if parsed.monthlyCreditsRemaining == nil {
            state.planID = nil
            state.planName = nil
            state.monthlyCreditsTotal = nil
            state.monthlyCreditsUsed = nil
            state.monthlyUsedPercent = nil
            state.error = "Missing monthly credits"
        } else {
            // Credits present but no subscription object (data: null).
            state.planID = nil
            state.planName = nil
            state.monthlyCreditsTotal = nil
            state.monthlyCreditsUsed = nil
            state.monthlyUsedPercent = nil
            state.error = "Credits available, no subscription plan"
        }
    }
}
