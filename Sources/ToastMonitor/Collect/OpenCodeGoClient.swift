import Foundation

/// OpenCode Go subscription quota (套餐).
/// There is no public quota API — the workspace dashboard page
/// (https://opencode.ai/workspace/<id>/go) embeds SolidJS SSR hydration
/// data with rollingUsage / weeklyUsage / monthlyUsage (usagePercent +
/// resetInSec). We fetch it with the session cookie and parse both the
/// SSR format and the newer data-slot HTML format.
final class OpenCodeGoClient: ObservableObject {
    nonisolated(unsafe) static let shared = OpenCodeGoClient()
    static let maxWorkspaceIDLength = 128
    static let maxCookieLength = 16_384
    static let maxHTMLLength = 10_000_000
    static let maxHTMLItemLength = 100_000

    /// Plan caps in USD (from opencode.ai/docs/go).
    static let rollingLimitUSD: Double = 12
    static let weeklyLimitUSD: Double = 30
    static let monthlyLimitUSD: Double = 60
    /// 订阅价（$10 买 $60 额度）；可在设置中修改，这里仅作兜底。
    static let monthlyPriceUSD: Double = 10

    struct State {
        var rollingPct: Double?
        var rollingReset: Int64?
        var weeklyPct: Double?
        var weeklyReset: Int64?
        var monthlyPct: Double?
        var monthlyReset: Int64?
        var lastOK: Int64 = 0
        var error: String?
        var isLoading = false
        /// Wall-clock fetch time (absolute reset = lastSync + resetInSec).
        var lastSync: Int64 = 0
    }

    @Published private(set) var state = State()
    @Published private(set) var configured = false

    private let session: URLSession
    /// Retained: URLSession holds its delegate weakly.
    private let redirectBlocker = NoRedirectDelegate()
    private var timer: Timer?
    private var started = false
    private var inFlight = false
    private var refreshGeneration: UInt64 = 0
    private var credentialsLoaded = false
    private var cachedCredentials: (workspaceId: String, cookie: String)?

    private init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 40
        // Credential-bearing request (auth cookie) — never follow redirects.
        session = URLSession(configuration: cfg, delegate: redirectBlocker, delegateQueue: nil)
        // Credential lookup may wait for the login/keychain agent. It is
        // loaded asynchronously after the UI has started.
        configured = false
    }

    private static func normalizedWorkspaceID(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        guard !value.isEmpty,
              value.count <= maxWorkspaceIDLength,
              value.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return value
    }

    private static func normalizedCookie(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.count <= maxCookieLength,
              value.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        return value
    }

    /// Credentials live in the Keychain (P0-5); legacy SQLite values are
    /// migrated on first read, then erased. Fail closed: when the Keychain
    /// is unavailable the app reports unconfigured instead of serving
    /// plaintext SQLite values to live API calls.
    private func credentials() -> (workspaceId: String, cookie: String)? {
        var ws = KeychainStore.get(account: "go-workspace-id")
        var ck = KeychainStore.get(account: "go-auth-cookie")
        if ws != nil && ck != nil {
            Database.shared.setSetting("go_workspace_id", nil)
            Database.shared.setSetting("go_auth_cookie", nil)
        }
        if ws == nil || ck == nil {
            let legacyWS = Database.shared.setting("go_workspace_id")
            let legacyCK = Database.shared.setting("go_auth_cookie")
            if let legacyWS, let legacyCK,
               let normalizedWS = Self.normalizedWorkspaceID(legacyWS),
               let normalizedCK = Self.normalizedCookie(legacyCK),
               KeychainStore.set(normalizedWS, account: "go-workspace-id"),
               KeychainStore.set(normalizedCK, account: "go-auth-cookie") {
                Database.shared.setSetting("go_workspace_id", nil)
                Database.shared.setSetting("go_auth_cookie", nil)
                Database.shared.setSetting("go_cred_storage", "keychain")
                ws = normalizedWS
                ck = normalizedCK
            } else if legacyWS != nil || legacyCK != nil {
                // Keychain unavailable or invalid legacy data: treat as
                // unconfigured. Plaintext stays as a recovery copy but is
                // never used for requests.
                Database.shared.setSetting("go_cred_storage", "keychain-unavailable")
                return nil
            }
        }
        guard let ws = ws.flatMap(Self.normalizedWorkspaceID),
              let ck = ck.flatMap(Self.normalizedCookie) else { return nil }
        return (ws, ck)
    }

    /// Stores only in Keychain. A locked/unavailable Keychain is an explicit
    /// provisioning failure; do not create a plaintext SQLite fallback.
    @discardableResult
    func provision(workspaceId: String, cookie: String) -> Bool {
        guard let workspaceID = Self.normalizedWorkspaceID(workspaceId),
              let authCookie = Self.normalizedCookie(cookie) else {
            configured = false
            state.error = "Invalid workspaceId or cookie"
            return false
        }
        let oldWorkspace = KeychainStore.get(account: "go-workspace-id")
        let oldCookie = KeychainStore.get(account: "go-auth-cookie")
        let wroteWorkspace = KeychainStore.set(workspaceID, account: "go-workspace-id",
                                               allowPrompt: true)
        let okKC = wroteWorkspace && KeychainStore.set(authCookie, account: "go-auth-cookie",
                                                       allowPrompt: true)
        if okKC {
            Database.shared.setSetting("go_workspace_id", nil)
            Database.shared.setSetting("go_auth_cookie", nil)
            Database.shared.setSetting("go_cred_storage", "keychain")
        } else {
            // Avoid leaving a mixed workspace/cookie pair when the second
            // Keychain write fails.
            if let oldWorkspace {
                _ = KeychainStore.set(oldWorkspace, account: "go-workspace-id")
            } else {
                KeychainStore.delete(account: "go-workspace-id")
            }
            if let oldCookie {
                _ = KeychainStore.set(oldCookie, account: "go-auth-cookie")
            } else {
                KeychainStore.delete(account: "go-auth-cookie")
            }
            configured = false
            state.error = "Keychain write failed — cookie not saved"
            return false
        }
        cachedCredentials = (workspaceID, authCookie)
        credentialsLoaded = true
        configured = true
        state.error = nil
        return true
    }

    func clear() {
        KeychainStore.delete(account: "go-workspace-id", allowPrompt: true)
        KeychainStore.delete(account: "go-auth-cookie", allowPrompt: true)
        Database.shared.setSetting("go_workspace_id", nil)
        Database.shared.setSetting("go_auth_cookie", nil)
        Database.shared.setSetting("go_cred_storage", nil)
        cachedCredentials = nil
        credentialsLoaded = true
        configured = false
        var cleared = State()
        cleared.error = "Not configured"
        state = cleared
    }

    func start() {
        guard !started else { return }
        started = true
        observeForeground()
        refresh() // one initial snapshot
        updateForeground()
    }

    private func startTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func refreshNow() { refresh() }

    private var popoverVisible = false
    private var dashboardVisible = false
    private var foreground = false

    private func updateForeground() {
        let fg = popoverVisible || dashboardVisible
        guard fg != foreground else { return }
        foreground = fg
        if fg {
            startTimer()
            refreshNow()
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    private func observeForeground() {
        for name in [TMNotifications.popoverVisibility, TMNotifications.dashboardVisibility] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
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

    func refresh() {
        guard !inFlight else { return }
        inFlight = true
        if credentialsLoaded {
            guard let cachedCredentials else {
                inFlight = false
                configured = false
                var cleared = State()
                cleared.error = "Not configured"
                state = cleared
                return
            }
            refresh(with: cachedCredentials)
            return
        }
        // The login Keychain may synchronously wait on securityd. Resolve the
        // pair once on a utility queue, then keep it in memory for every timer
        // and foreground refresh during this process lifetime.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let creds = self?.credentials()
            DispatchQueue.main.async {
                guard let self else { return }
                self.credentialsLoaded = true
                self.cachedCredentials = creds
                guard let creds else {
                    self.inFlight = false
                    self.configured = false
                    var cleared = State()
                    cleared.error = "Not configured"
                    self.state = cleared
                    return
                }
                self.refresh(with: creds)
            }
        }
    }

    private func refresh(with creds: (workspaceId: String, cookie: String)) {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        configured = true
        state.isLoading = true
        state.error = nil
        // 刷新期间保留上一次的数值：UI 继续显示旧快照，新数据到达后
        // 整块替换，Popover 状态行不会闪 Loading/Idle。失败响应仍会
        // 设置 error，由 UI 优先显示。

        let url = "https://opencode.ai/workspace/\(creds.workspaceId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? creds.workspaceId)/go"
        guard let u = URL(string: url) else {
            inFlight = false
            state.isLoading = false
            state.error = "Invalid URL"
            return
        }
        var req = URLRequest(url: u)
        req.httpMethod = "GET"
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Gecko/20100101 Firefox/148.0", forHTTPHeaderField: "User-Agent")
        req.setValue("text/html", forHTTPHeaderField: "Accept")
        req.setValue("auth=\(creds.cookie)", forHTTPHeaderField: "Cookie")

        redirectBlocker.boundedDataTask(in: session, request: req,
                                        maxBytes: Self.maxHTMLLength) { [weak self] data, resp, err in
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.refreshGeneration == generation else { return }
                self.inFlight = false
                self.state.isLoading = false
                self.state.lastSync = Int64(Date().timeIntervalSince1970)
                if let err {
                    self.state.error = err.localizedDescription
                    return
                }
                guard let data else {
                    self.state.error = "Empty response"
                    return
                }
                guard data.count <= Self.maxHTMLLength else {
                    self.state.error = "Response too large (>10MB)"
                    return
                }
                guard let http = resp as? HTTPURLResponse else {
                    self.state.error = "No HTTP response"
                    return
                }
                if (300..<400).contains(http.statusCode) {
                    self.state.error = "Redirect rejected (HTTP \(http.statusCode))"
                    return
                }
                // Reject oversized responses from the header before buffering.
                if http.expectedContentLength > 10_000_000 {
                    self.state.error = "Response too large (>10MB)"
                    return
                }
                guard http.statusCode == 200 else {
                    self.state.error = (http.statusCode == 401 || http.statusCode == 403)
                        ? "Cookie expired, reconfigure needed (HTTP \(http.statusCode))"
                        : "HTTP \(http.statusCode)"
                    return
                }
                if let mime = http.mimeType,
                   !mime.contains("html") && !mime.contains("json") && !mime.contains("text") {
                    self.state.error = "Non-web response (\(mime))"
                    return
                }
                guard let html = String(data: data, encoding: .utf8) else {
                    self.state.error = "Failed to parse response"
                    return
                }
                let parsed = Self.parse(html)
                guard let parsed, parsed.0 != nil || parsed.1 != nil || parsed.2 != nil else {
                    self.state.error = "No usage data found (page structure may have changed)"
                    return
                }
                self.state.rollingPct = parsed.0?.pct
                self.state.rollingReset = parsed.0?.reset
                self.state.weeklyPct = parsed.1?.pct
                self.state.weeklyReset = parsed.1?.reset
                self.state.monthlyPct = parsed.2?.pct
                self.state.monthlyReset = parsed.2?.reset
                self.state.lastOK = Int64(Date().timeIntervalSince1970)
                self.state.error = nil
                self.persist()
            }
        }.resume()
    }

    private func persist() {
        let s = state
        Database.shared.insertOGSnapshot(Database.OGSnapshot(
            ts: Int64(Date().timeIntervalSince1970),
            rollingPct: s.rollingPct, rollingReset: s.rollingReset,
            weeklyPct: s.weeklyPct, weeklyReset: s.weeklyReset,
            monthlyPct: s.monthlyPct, monthlyReset: s.monthlyReset))
    }

    private static func hasDisallowedControl(_ value: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "\t\n\r")
        return value.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0) && !allowed.contains($0)
        }
    }
    // MARK: - Parsing

    struct WindowUsage {
        let pct: Double
        let reset: Int64
    }
    /// Returns (rolling, weekly, monthly).
    static func parse(_ html: String) -> (WindowUsage?, WindowUsage?, WindowUsage?)? {
        guard html.count <= maxHTMLLength, !hasDisallowedControl(html) else { return nil }
        let rolling = parseWindow(html, key: "rollingUsage")
        let weekly = parseWindow(html, key: "weeklyUsage")
        let monthly = parseWindow(html, key: "monthlyUsage")
        if rolling == nil && weekly == nil && monthly == nil { return nil }
        return (rolling, weekly, monthly)
    }

    private static let numberPattern = "(-?\\d+(?:\\.\\d+)?)"
    private static func boundedPercent(_ raw: Double) -> Double? {
        guard raw.isFinite, raw >= 0, raw <= 100 else { return nil }
        return raw
    }
    private static func boundedReset(_ raw: Double) -> Int64? {
        guard raw.isFinite, raw >= 0, raw <= 366 * 86400 else { return nil }
        return Int64(raw)
    }

    /// SolidJS SSR hydration: `rollingUsage:$R[12]={usagePercent:3,resetInSec:8655}`
    /// (field order varies — try both).
    private static func parseWindow(_ html: String, key: String) -> WindowUsage? {
        let pctFirst = try? NSRegularExpression(
            pattern: "\(key):\\$R\\[\\d+\\]=\\{[^}]*usagePercent:\(numberPattern)[^}]*resetInSec:\(numberPattern)[^}]*\\}")
        let resetFirst = try? NSRegularExpression(
            pattern: "\(key):\\$R\\[\\d+\\]=\\{[^}]*resetInSec:\(numberPattern)[^}]*usagePercent:\(numberPattern)[^}]*\\}")

        if let m = pctFirst?.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
           let pct = Double(html[Range(m.range(at: 1), in: html)!]),
           let reset = Double(html[Range(m.range(at: 2), in: html)!]),
           let boundedPct = boundedPercent(pct),
           let boundedReset = boundedReset(reset) {
            return WindowUsage(pct: boundedPct, reset: boundedReset)
        }
        if let m = resetFirst?.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
           let reset = Double(html[Range(m.range(at: 1), in: html)!]),
           let pct = Double(html[Range(m.range(at: 2), in: html)!]),
           let boundedPct = boundedPercent(pct),
           let boundedReset = boundedReset(reset) {
            return WindowUsage(pct: boundedPct, reset: boundedReset)
        }

        // Newer data-slot HTML format fallback.
        let slotLabel = ["rolling": "rolling usage", "weekly": "weekly usage", "monthly": "monthly usage"]
            .first(where: { key.lowercased().hasPrefix($0.key) })?.value
        if let label = slotLabel {
            return parseDataSlot(html, label: label)
        }
        return nil
    }

    private static func parseDataSlot(_ html: String, label: String) -> WindowUsage? {
        let items = html.components(separatedBy: "data-slot=\"usage-item\"")
        for item in items.dropFirst().prefix(256) {
            guard item.count <= maxHTMLItemLength else { continue }
            guard item.range(of: "data-slot=\"usage-label\">\(label)", options: [.caseInsensitive]) != nil else { continue }
            let valueRe = try? NSRegularExpression(pattern: "data-slot=\"usage-value\">[^0-9]*(\\d+(?:\\.\\d+)?)")
            let resetRe = try? NSRegularExpression(pattern: "data-slot=\"(reset-time|reset-now)\">([\\s\\S]*?)<\\/span>")
            guard let vm = valueRe?.firstMatch(in: item, range: NSRange(item.startIndex..., in: item)),
                  let pct = Double(item[Range(vm.range(at: 1), in: item)!]),
                  let pct = boundedPercent(pct) else { continue }
            guard let rm = resetRe?.firstMatch(in: item, range: NSRange(item.startIndex..., in: item)) else { continue }
            var resetText = item[Range(rm.range(at: 2), in: item)!]
                .replacingOccurrences(of: "<!--$-->", with: "")
                .replacingOccurrences(of: "<!--/-->", with: "")
            resetText = resetText.replacingOccurrences(of: "Resets?\\s*in\\s*", with: "", options: .regularExpression)
            let reset = Self.parseHumanDuration(resetText.trimmingCharacters(in: .whitespacesAndNewlines))
            guard let boundedReset = boundedReset(Double(reset)) else { continue }
            return WindowUsage(pct: pct, reset: boundedReset)
        }
        return nil
    }

    /// "1 hour 56 minutes" / "6 days 2 hours" / "26 days 17 hours" -> seconds.
    static func parseHumanDuration(_ text: String) -> Int64 {
        guard text.count <= 256, !hasDisallowedControl(text) else { return -1 }
        let t = text.lowercased().trimmingCharacters(in: .whitespaces)
        if t.contains("now") { return 0 }
        var total = 0.0
        if let v = firstNumber(t, unit: "day") { total += v * 86400 }
        if let v = firstNumber(t, unit: "hour") { total += v * 3600 }
        if let v = firstNumber(t, unit: "minute") { total += v * 60 }
        if let v = firstNumber(t, unit: "second") { total += v }
        guard total.isFinite, total >= 0, total <= 366 * 86400 else { return -1 }
        return Int64(total)
    }

    private static func firstNumber(_ text: String, unit: String) -> Double? {
        let re = try? NSRegularExpression(pattern: "(\\d+(?:\\.\\d+)?)\\s*\(unit)s?")
        guard let m = re?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: 1), in: text),
              let v = Double(text[r]) else { return nil }
        return v
    }
}
