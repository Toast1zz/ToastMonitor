import Foundation
import Combine

/// Claude subscription quota via the OAuth usage endpoint that Claude Code's
/// own status line is fed from: reads the OAuth access token Claude Code
/// already stored on this machine (never persisted anywhere in ToastMonitor
/// beyond the throttle/cache bookkeeping below) and GETs
/// https://api.anthropic.com/api/oauth/usage.
///
/// The endpoint is undocumented and not an officially supported integration
/// point — Anthropic's Consumer Terms restrict OAuth tokens from Free/Pro/Max
/// accounts to Claude Code and claude.ai. This client cannot make that
/// restriction go away; it only avoids making the traffic look worse than it
/// has to: off by default (opt-in via `setEnabled`), a conservative request
/// cadence, a cross-launch cooldown so an app restart can't reset a real
/// server-side backoff, and Retry-After-aware jittered backoff on failure.
/// Modeled after the polling discipline documented by community tools that
/// hit the same endpoint (e.g. github.com/Javis603/token-monitor).
///
/// Parsing is deliberately tolerant: window names and percent/reset field
/// names are each matched against the spellings seen in the wild, and
/// anything unrecognised leaves the state empty rather than producing a
/// guessed number.
@MainActor
final class ClaudeQuotaClient: ObservableObject {
    static let shared = ClaudeQuotaClient()
    static let maxResponseBytes = 10_000_000

    /// One rate-limit window as reported by the usage endpoint.
    struct Window: Equatable, Codable {
        var label: String      // "5h" | "weekly" | "weekly Opus"
        var usedPercent: Int   // 0...100
        var resetAt: Int64?    // unix seconds
    }

    struct State {
        var configured = false
        var planType: String?
        var fiveHour: Window?
        var sevenDay: Window?
        var sevenDayOpus: Window?
        var lastSync: Int64 = 0
        var error: String?

        /// The window(s) besides the weekly one that are close enough to
        /// exhaustion to be worth flagging (5h and, rarely, a weekly-Opus
        /// window). The popover shows weekly as the primary number and
        /// these underneath, so a critical 5h window still needs its own
        /// signal — this is what puts the star on the row.
        var hasCriticalSecondaryWindow: Bool {
            [fiveHour, sevenDayOpus].compactMap { $0 }.contains { $0.usedPercent > 80 }
        }
    }

    /// Opt-in: unlike Go/OpenRouter/Command Code, this source needs no
    /// credentials the user has to paste — it reads Claude Code's login the
    /// moment it's built. Given the ToS ambiguity around third-party use of
    /// that login, requiring an explicit switch makes "this is running"
    /// something the user chose, not something that shipped on by default.
    @Published private(set) var enabled: Bool
    @Published private(set) var state = State()

    private var timer: Timer?
    private var started = false
    private var inFlight = false
    private var refreshGeneration: UInt64 = 0

    /// Consecutive-failure counter driving the backoff schedule (reset on
    /// any success). Wall-clock based and persisted, not systemUptime-based —
    /// systemUptime resets on every relaunch, which previously meant
    /// restarting the app silently discarded a server-imposed backoff.
    private var backoffAttempt = 0
    private var nextAllowedRefresh: TimeInterval = 0
    /// Last attempt time (success or failure), independent of the backoff
    /// above. This is the soft cooldown that keeps passive triggers (app
    /// launch, the periodic timer, popover/dashboard becoming visible) from
    /// stacking into a burst — a `force: true` caller (the explicit refresh
    /// button) bypasses only this, never the real backoff.
    private var lastAttemptAt: TimeInterval = 0

    private let session: URLSession
    /// Retained because URLSession delegates are weak.
    private let redirectBlocker = NoRedirectDelegate()

    private init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 30
        session = URLSession(configuration: cfg, delegate: redirectBlocker, delegateQueue: nil)
        enabled = Database.shared.setting(Self.enabledSettingKey) == "1"
        if let raw = Database.shared.setting(Self.lastAttemptSettingKey), let v = TimeInterval(raw) {
            lastAttemptAt = v
        }
        if let raw = Database.shared.setting(Self.backoffUntilSettingKey), let v = TimeInterval(raw) {
            nextAllowedRefresh = v
        }
        loadCache()
        observeForeground()
    }

    // MARK: - Enable/disable

    static let enabledSettingKey = "claude_quota_enabled"

    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        DispatchQueue.global(qos: .utility).async {
            _ = Database.shared.setSetting(Self.enabledSettingKey, on ? "1" : nil)
        }
        if on {
            start()
        } else {
            started = false
            timer?.invalidate()
            timer = nil
            refreshGeneration &+= 1 // orphan any in-flight request's completion
            inFlight = false
            state = State()
        }
    }

    // MARK: - Foreground-gated polling

    private var popoverVisible = false
    private var dashboardVisible = false
    private var foreground = false

    private func updateForeground() {
        guard enabled else { return }
        let fg = popoverVisible || dashboardVisible
        guard fg != foreground || (fg && timer == nil) else { return }
        foreground = fg
        if fg {
            startTimer(interval: Self.foregroundInterval)
            refresh()
        } else {
            // No background polling at all: nobody is looking at the numbers,
            // so there is nothing to refresh for. This is stricter than every
            // other quota source in the app, deliberately — this one alone
            // carries ToS risk the others don't.
            timer?.invalidate()
            timer = nil
        }
    }

    private func observeForeground() {
        for name in [TMNotifications.popoverVisibility, TMNotifications.dashboardVisibility] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let visible = (note.object as? Bool) ?? false
                Task { @MainActor [weak self] in
                    guard let self else { return }
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
        guard enabled, !started else { return }
        started = true
        refresh()
        updateForeground()
    }

    private func startTimer(interval: TimeInterval) {
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: - Refresh

    /// Passive cadence once foregrounded (app launch, popover/dashboard open,
    /// the timer): 5 minutes, matching the default community tools converged
    /// on for this same endpoint. No separate background interval — see
    /// updateForeground.
    static let foregroundInterval: TimeInterval = 5 * 60
    /// Minimum spacing between passive attempts, independent of the timer —
    /// this is what stops four different call sites (launch, timer,
    /// popover/dashboard appearing) from adding up to a burst.
    private static let minPassiveInterval: TimeInterval = 3 * 60

    /// - Parameter force: bypasses only the soft passive-cooldown above (used
    ///   by the explicit "Refresh" button); a real server-imposed backoff
    ///   from `nextAllowedRefresh` still applies even when forced.
    func refresh(force: Bool = false) {
        guard enabled else { return }
        guard !inFlight else { return }
        let now = Date().timeIntervalSince1970
        guard now >= nextAllowedRefresh else { return }
        if !force, lastAttemptAt > 0, now - lastAttemptAt < Self.minPassiveInterval { return }

        inFlight = true
        persistLastAttempt(now)
        refreshGeneration &+= 1
        let generation = refreshGeneration

        // Credential lookup touches disk (and possibly the Keychain); never
        // on the main actor.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let credentials = Self.loadCredentials()
            Task { @MainActor [weak self] in
                guard let self, self.refreshGeneration == generation else { return }
                guard let credentials else {
                    self.inFlight = false
                    self.state.configured = false
                    self.state.error = "Claude login not found (run claude /login to restore)"
                    return
                }
                self.state.configured = true
                if let expiresAt = credentials.expiresAt,
                   expiresAt <= Int64(Date().timeIntervalSince1970) {
                    // Claude Code refreshes the token itself on its next run;
                    // refreshing it here would race that and rewrite the file.
                    self.inFlight = false
                    self.state.error = "Claude login expired (run claude to refresh)"
                    self.applyBackoff(retryAfterHeader: nil)
                    return
                }
                if self.state.planType == nil {
                    self.state.planType = credentials.subscriptionType
                }
                self.requestUsage(accessToken: credentials.accessToken, generation: generation)
            }
        }
    }

    struct Credentials {
        var accessToken: String
        var expiresAt: Int64?      // unix seconds
        var subscriptionType: String?
    }

    /// Claude Code keeps its OAuth blob either in ~/.claude/.credentials.json
    /// or, on macOS, in the login Keychain under "Claude Code-credentials".
    /// Recent Claude Code versions write only to the Keychain on macOS, so
    /// the file can be left behind stale (a revoked token that never gets
    /// cleaned up) while the Keychain holds the current one. Both sources
    /// are read and the one with the later expiry — i.e. the more recent
    /// login/refresh — wins, rather than trusting whichever happens to be
    /// tried first.
    private nonisolated static func loadCredentials() -> Credentials? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let path = home.appendingPathComponent(".claude/.credentials.json").path
        let fromFile = (try? Data(contentsOf: URL(fileURLWithPath: path))).flatMap(parseCredentials)
        let fromKeychain = keychainCredentials().flatMap(parseCredentials)
        switch (fromFile, fromKeychain) {
        case (let f?, let k?):
            // Missing expiresAt can't be compared; prefer whichever has one.
            switch (f.expiresAt, k.expiresAt) {
            case (let fe?, let ke?): return fe >= ke ? f : k
            case (nil, .some): return k
            default: return f
            }
        case (let f?, nil): return f
        case (nil, let k?): return k
        case (nil, nil): return nil
        }
    }

    /// Read the raw Claude Code credential blob from the login Keychain.
    /// Non-interactive: a locked keychain or a denied ACL returns nil rather
    /// than blocking the refresh behind a system prompt.
    private nonisolated static func keychainCredentials() -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, data.count <= 1_000_000 else { return nil }
        return data
    }

    nonisolated static func parseCredentials(_ data: Data) -> Credentials? {
        guard data.count <= 1_000_000,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        // Claude Code nests the blob under claudeAiOauth; older/hand-written
        // files put the same fields at the top level.
        let oauth = (json["claudeAiOauth"] as? [String: Any]) ?? json
        guard let accessToken = oauth["accessToken"] as? String ?? oauth["access_token"] as? String,
              !accessToken.isEmpty, accessToken.count <= 16_384,
              accessToken.rangeOfCharacter(from: .controlCharacters) == nil else {
            return nil
        }
        // expiresAt is milliseconds since epoch in the Claude Code blob.
        var expiresAt: Int64?
        if let ms = (oauth["expiresAt"] ?? oauth["expires_at"]) as? NSNumber {
            let d = ms.doubleValue
            if d.isFinite, d > 0 {
                expiresAt = Int64(d > 4_000_000_000 ? d / 1000 : d)
            }
        }
        var plan: String?
        if let raw = (oauth["subscriptionType"] ?? oauth["subscription_type"]) as? String,
           raw.count <= 128, raw.rangeOfCharacter(from: .controlCharacters) == nil, !raw.isEmpty {
            plan = raw
        }
        return Credentials(accessToken: accessToken, expiresAt: expiresAt, subscriptionType: plan)
    }

    private func requestUsage(accessToken: String, generation: UInt64) {
        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else {
            inFlight = false
            return
        }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        req.httpMethod = "GET"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        // Deliberately not Claude Code's own User-Agent: this is a
        // third-party tool and says so, rather than disguising its traffic
        // as the official client.
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
                    self.applyBackoff(retryAfterHeader: nil)
                    return
                }
                guard let http = resp as? HTTPURLResponse else {
                    self.state.error = "No HTTP response"
                    self.applyBackoff(retryAfterHeader: nil)
                    return
                }
                let retryAfter = http.value(forHTTPHeaderField: "Retry-After")
                if (300..<400).contains(http.statusCode) {
                    self.state.error = "Redirect rejected (HTTP \(http.statusCode))"
                    self.applyBackoff(retryAfterHeader: retryAfter)
                    return
                }
                guard http.statusCode == 200 else {
                    self.state.error = (http.statusCode == 401 || http.statusCode == 403)
                        ? "Claude login expired — run claude /login to restore"
                        : "usage API HTTP \(http.statusCode)"
                    self.applyBackoff(retryAfterHeader: retryAfter)
                    return
                }
                guard http.expectedContentLength <= Self.maxResponseBytes,
                      let data, data.count <= Self.maxResponseBytes,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    self.state.error = "Failed to parse usage response"
                    self.applyBackoff(retryAfterHeader: retryAfter)
                    return
                }
                let parsed = Self.parseUsage(json)
                guard parsed.fiveHour != nil || parsed.sevenDay != nil || parsed.sevenDayOpus != nil else {
                    // A 200 with no window we recognise means the response
                    // shape moved; say so instead of showing a stale percent.
                    self.state.error = "usage API returned no known rate-limit window"
                    self.applyBackoff(retryAfterHeader: retryAfter)
                    return
                }
                self.state.fiveHour = parsed.fiveHour
                self.state.sevenDay = parsed.sevenDay
                self.state.sevenDayOpus = parsed.sevenDayOpus
                if let plan = parsed.planType { self.state.planType = plan }
                self.state.lastSync = Int64(Date().timeIntervalSince1970)
                self.state.error = nil
                self.clearBackoff()
                self.persistCache()
            }
        }.resume()
    }

    struct Usage {
        var planType: String?
        var fiveHour: Window?
        var sevenDay: Window?
        var sevenDayOpus: Window?
    }

    /// Tolerant reader for the undocumented usage payload. Windows may arrive
    /// at the top level or nested under a container key, and each carries its
    /// percentage under one of several spellings.
    nonisolated static func parseUsage(_ json: [String: Any]) -> Usage {
        let root = (json["rate_limits"] as? [String: Any])
            ?? (json["usage"] as? [String: Any])
            ?? json
        var out = Usage()
        if let raw = (json["subscription_type"] ?? json["plan_type"] ?? json["plan"]) as? String,
           raw.count <= 128, raw.rangeOfCharacter(from: .controlCharacters) == nil, !raw.isEmpty {
            out.planType = raw
        }
        out.fiveHour = window(in: root, keys: ["five_hour", "fiveHour", "5h"], label: "5h")
        out.sevenDay = window(in: root, keys: ["seven_day", "sevenDay", "7d"], label: "weekly")
        out.sevenDayOpus = window(in: root,
                                  keys: ["seven_day_opus", "sevenDayOpus", "seven_day_oauth_opus", "7d_opus"],
                                  label: "weekly Opus")
        return out
    }

    private nonisolated static func window(in root: [String: Any], keys: [String], label: String) -> Window? {
        for key in keys {
            guard let dict = root[key] as? [String: Any] else { continue }
            guard let pct = percent(dict["utilization"] ?? dict["used_percent"]
                                    ?? dict["percent_used"] ?? dict["usedPercent"]) else { continue }
            return Window(label: label, usedPercent: pct, resetAt: resetAt(dict["resets_at"] ?? dict["reset_at"]))
        }
        return nil
    }

    /// Percentages arrive as 0–100. A 0–1 fraction is not assumed: it would
    /// silently turn a 100%-used window into 1%.
    private nonisolated static func percent(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        let d = number.doubleValue
        guard d.isFinite, d >= 0, d <= 100 else { return nil }
        return Int(d.rounded())
    }

    /// Reset timestamps are ISO-8601 strings here (unix seconds are accepted
    /// too, since the field is undocumented).
    private nonisolated static func resetAt(_ value: Any?) -> Int64? {
        let now = Date().timeIntervalSince1970
        func bounded(_ d: Double) -> Int64? {
            guard d.isFinite, d >= now - 366 * 86400, d <= now + 366 * 86400 else { return nil }
            return Int64(d)
        }
        if let number = value as? NSNumber {
            return bounded(number.doubleValue)
        }
        guard let text = value as? String, text.count <= 64 else { return nil }
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: text) { return bounded(date.timeIntervalSince1970) }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: text) { return bounded(date.timeIntervalSince1970) }
        return nil
    }

    // MARK: - Backoff (Retry-After aware, jittered)

    private nonisolated static let retryBaseSeconds: TimeInterval = 5
    private nonisolated static let retryMaxSeconds: TimeInterval = 5 * 60
    private nonisolated static let maxRetryAfterSeconds: TimeInterval = 60 * 60
    private nonisolated static let retryAfterJitterCapSeconds: TimeInterval = 5

    /// Retry-After is either a delay in seconds or an HTTP-date. Anthropic's
    /// usage endpoint has been observed sending "0" (i.e. no real guidance),
    /// so a present-but-zero header still falls through to the exponential
    /// schedule below rather than permitting an immediate retry.
    nonisolated static func parseRetryAfter(_ value: String?) -> TimeInterval? {
        guard let raw = value?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if let secs = Double(raw), secs.isFinite {
            return min(maxRetryAfterSeconds, max(0, secs))
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: raw) else { return nil }
        return min(maxRetryAfterSeconds, max(0, date.timeIntervalSinceNow))
    }

    /// A positive Retry-After becomes the delay (plus a small jitter, so
    /// simultaneous clients don't all retry on the same tick). Otherwise:
    /// full-jitter exponential backoff — a random value between half and all
    /// of `min(retryMaxSeconds, base * 2^attempt)` — same shape as the
    /// community tools polling this same endpoint converged on, and gentler
    /// than a fixed 60s→2m→5m→15m ladder with no randomness.
    nonisolated static func computeBackoffDelay(attempt: Int, retryAfterHeader: String?) -> TimeInterval {
        if let retryAfter = parseRetryAfter(retryAfterHeader), retryAfter > 0 {
            let jitterCap = min(retryAfterJitterCapSeconds, retryAfter * 0.1)
            return retryAfter + Double.random(in: 0...max(jitterCap, 0))
        }
        let exponent = max(0, min(30, attempt - 1))
        let cap = min(retryMaxSeconds, retryBaseSeconds * pow(2, Double(exponent)))
        return (cap / 2) + Double.random(in: 0...max(cap / 2, 0))
    }

    private func applyBackoff(retryAfterHeader: String?) {
        backoffAttempt += 1
        let delay = Self.computeBackoffDelay(attempt: backoffAttempt, retryAfterHeader: retryAfterHeader)
        persistBackoffUntil(Date().timeIntervalSince1970 + delay)
    }

    private func clearBackoff() {
        backoffAttempt = 0
        persistBackoffUntil(0)
    }

    // MARK: - Cross-launch persistence

    /// A relaunch must not reset a real server-imposed backoff or make the
    /// app think it hasn't checked recently when it has — both are wall-clock
    /// (not systemUptime) so they carry meaning across process restarts.
    private static let lastAttemptSettingKey = "claude_quota_last_attempt_ts"
    private static let backoffUntilSettingKey = "claude_quota_backoff_until_ts"
    private static let cacheSettingKey = "claude_quota_cache_v1"

    private func persistLastAttempt(_ t: TimeInterval) {
        lastAttemptAt = t
        let v = String(t)
        DispatchQueue.global(qos: .utility).async { _ = Database.shared.setSetting(Self.lastAttemptSettingKey, v) }
    }

    private func persistBackoffUntil(_ t: TimeInterval) {
        nextAllowedRefresh = t
        let v = t > 0 ? String(t) : nil
        DispatchQueue.global(qos: .utility).async { _ = Database.shared.setSetting(Self.backoffUntilSettingKey, v) }
    }

    private struct CacheBlob: Codable {
        var planType: String?
        var fiveHour: Window?
        var sevenDay: Window?
        var sevenDayOpus: Window?
        var lastSync: Int64
    }

    /// Last known good numbers, so a relaunch shows them immediately instead
    /// of a blank "Loading" row while waiting out the cooldown/backoff.
    private func persistCache() {
        let blob = CacheBlob(planType: state.planType, fiveHour: state.fiveHour,
                             sevenDay: state.sevenDay, sevenDayOpus: state.sevenDayOpus,
                             lastSync: state.lastSync)
        guard let data = try? JSONEncoder().encode(blob), let json = String(data: data, encoding: .utf8) else { return }
        DispatchQueue.global(qos: .utility).async { _ = Database.shared.setSetting(Self.cacheSettingKey, json) }
    }

    private func loadCache() {
        guard let json = Database.shared.setting(Self.cacheSettingKey),
              let data = json.data(using: .utf8),
              let blob = try? JSONDecoder().decode(CacheBlob.self, from: data) else { return }
        state.planType = blob.planType
        state.fiveHour = blob.fiveHour
        state.sevenDay = blob.sevenDay
        state.sevenDayOpus = blob.sevenDayOpus
        state.lastSync = blob.lastSync
    }
}
