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
    private var timer: Timer?
    private var started = false
    private var inFlight = false
    private var refreshGeneration: UInt64 = 0
    /// Backoff (M1): failed refreshes wait 60s → 2m → 5m → 15m; success resets.
    private var backoffBase: TimeInterval = 0
    private var nextAllowedRefresh: TimeInterval = 0

    private let session: URLSession
    /// Retained because URLSession delegates are weak.
    private let redirectBlocker = NoRedirectDelegate()

    private init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 30
        session = URLSession(configuration: cfg, delegate: redirectBlocker, delegateQueue: nil)
        observeForeground()
    }

    private var popoverVisible = false
    private var dashboardVisible = false
    private var foreground = false

    private func updateForeground() {
        let fg = popoverVisible || dashboardVisible
        // At launch the app is hidden and the timer has not been installed
        // yet, so the missing timer is also a valid state transition.
        guard fg != foreground || timer == nil else { return }
        foreground = fg
        startTimer(interval: TMRefreshPolicy.quotaInterval(foreground: fg))
        if fg {
            refresh()
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
        guard !started else { return }
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

    func refresh() {
        guard !inFlight else { return }
        // Backoff gate (M1): skip attempts inside the backoff window.
        if ProcessInfo.processInfo.systemUptime < nextAllowedRefresh { return }
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
                    self.applyBackoff()
                    return
                }
                guard let http = resp as? HTTPURLResponse else {
                    self.state.error = "No HTTP response"
                    self.applyBackoff()
                    return
                }
                if (300..<400).contains(http.statusCode) {
                    self.state.error = "Redirect rejected (HTTP \(http.statusCode))"
                    self.applyBackoff()
                    return
                }
                guard http.statusCode == 200 else {
                    self.state.error = (http.statusCode == 401 || http.statusCode == 403)
                        ? "Codex login expired — reconfigure (sign in with codex to restore)"
                        : "usage API HTTP \(http.statusCode)"
                    self.applyBackoff()
                    return
                }
                guard http.expectedContentLength <= 10_000_000,
                      let data, data.count <= 10_000_000,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    self.state.error = "Failed to parse usage response"
                    self.applyBackoff()
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
                self.backoffBase = 0
            }
        }.resume()
    }

    /// Exponential backoff (M1): 60s → 2m → 5m → 15m, capped.
    private func applyBackoff() {
        let now = ProcessInfo.processInfo.systemUptime
        backoffBase = min(max(backoffBase, 60), 15 * 60)
        nextAllowedRefresh = now + backoffBase
        backoffBase *= 2
    }
}
