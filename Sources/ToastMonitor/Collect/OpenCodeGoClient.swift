import Foundation

/// OpenCode Go subscription quota (套餐).
/// There is no public quota API — the workspace dashboard page
/// (https://opencode.ai/workspace/<id>/go) embeds SolidJS SSR hydration
/// data with rollingUsage / weeklyUsage / monthlyUsage (usagePercent +
/// resetInSec). We fetch it with the session cookie and parse both the
/// SSR format and the newer data-slot HTML format.
final class OpenCodeGoClient: ObservableObject {
    static let shared = OpenCodeGoClient()

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
    private var timer: Timer?
    private var started = false
    private var inFlight = false
    private var refreshGeneration: UInt64 = 0

    private init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 40
        session = URLSession(configuration: cfg)
        // Credential lookup may wait for the login/keychain agent. It is
        // loaded asynchronously after the UI has started.
        configured = false
        observeForeground()
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
            if let legacyWS, let legacyCK {
                if KeychainStore.set(legacyWS, account: "go-workspace-id"),
                   KeychainStore.set(legacyCK, account: "go-auth-cookie") {
                    Database.shared.setSetting("go_workspace_id", nil)
                    Database.shared.setSetting("go_auth_cookie", nil)
                    Database.shared.setSetting("go_cred_storage", "keychain")
                    ws = legacyWS
                    ck = legacyCK
                } else {
                    // Keychain unavailable: treat as unconfigured. Plaintext
                    // stays on disk (0600) as a recovery copy but is never
                    // used for requests.
                    Database.shared.setSetting("go_cred_storage", "keychain-unavailable")
                    return nil
                }
            }
        }
        guard let ws, !ws.isEmpty, let ck, !ck.isEmpty else { return nil }
        return (ws, ck)
    }

    /// Stores only in Keychain. A locked/unavailable Keychain is an explicit
    /// provisioning failure; do not create a plaintext SQLite fallback.
    @discardableResult
    func provision(workspaceId: String, cookie: String) -> Bool {
        guard !workspaceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !cookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            configured = false
            state.error = "workspaceId 或 cookie 为空"
            return false
        }
        let oldWorkspace = KeychainStore.get(account: "go-workspace-id")
        let oldCookie = KeychainStore.get(account: "go-auth-cookie")
        let wroteWorkspace = KeychainStore.set(workspaceId, account: "go-workspace-id")
        let okKC = wroteWorkspace && KeychainStore.set(cookie, account: "go-auth-cookie")
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
            state.error = "无法写入 macOS 钥匙串，未保存 cookie"
            return false
        }
        configured = true
        state.error = nil
        return true
    }

    func clear() {
        refreshGeneration &+= 1
        inFlight = false
        KeychainStore.delete(account: "go-workspace-id")
        KeychainStore.delete(account: "go-auth-cookie")
        Database.shared.setSetting("go_workspace_id", nil)
        Database.shared.setSetting("go_auth_cookie", nil)
        Database.shared.setSetting("go_cred_storage", nil)
        configured = false
        var cleared = State()
        cleared.error = "未配置"
        state = cleared
    }

    func start() {
        guard !started else { return }
        started = true
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
        // Keychain reads (credentials) must run on the main thread — every
        // read unlocks the vault, which needs the main-thread UI session.
        let creds = credentials()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                guard let creds else {
                    self.inFlight = false
                    self.configured = false
                    var cleared = State()
                    cleared.error = "未配置"
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
        // Do not keep rendering an old quota snapshot as if it belonged to
        // the request currently in flight. A failed response will show an
        // explicit error with empty quota fields.
        state.rollingPct = nil
        state.rollingReset = nil
        state.weeklyPct = nil
        state.weeklyReset = nil
        state.monthlyPct = nil
        state.monthlyReset = nil
        state.lastOK = 0

        let url = "https://opencode.ai/workspace/\(creds.workspaceId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? creds.workspaceId)/go"
        guard let u = URL(string: url) else {
            inFlight = false
            state.isLoading = false
            state.error = "URL 无效"
            return
        }
        var req = URLRequest(url: u)
        req.httpMethod = "GET"
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Gecko/20100101 Firefox/148.0", forHTTPHeaderField: "User-Agent")
        req.setValue("text/html", forHTTPHeaderField: "Accept")
        req.setValue("auth=\(creds.cookie)", forHTTPHeaderField: "Cookie")

        session.dataTask(with: req) { [weak self] data, resp, err in
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
                    self.state.error = "空响应"
                    return
                }
                guard data.count < 10_000_000 else {
                    self.state.error = "响应过大 (>10MB)"
                    return
                }
                guard let http = resp as? HTTPURLResponse else {
                    self.state.error = "无 HTTP 响应"
                    return
                }
                // Reject oversized responses from the header before buffering.
                if http.expectedContentLength > 10_000_000 {
                    self.state.error = "响应过大 (>10MB)"
                    return
                }
                guard http.statusCode == 200 else {
                    self.state.error = (http.statusCode == 401 || http.statusCode == 403)
                        ? "cookie 失效，需重新配置 (HTTP \(http.statusCode))"
                        : "HTTP \(http.statusCode)"
                    return
                }
                if let mime = http.mimeType,
                   !mime.contains("html") && !mime.contains("json") && !mime.contains("text") {
                    self.state.error = "非网页响应 (\(mime))"
                    return
                }
                guard let html = String(data: data, encoding: .utf8) else {
                    self.state.error = "响应解析失败"
                    return
                }
                let parsed = Self.parse(html)
                guard let parsed, parsed.0 != nil || parsed.1 != nil || parsed.2 != nil else {
                    self.state.error = "未找到用量数据（页面结构可能已变）"
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

    // MARK: - Parsing

    struct WindowUsage {
        let pct: Double
        let reset: Int64
    }

    /// Returns (rolling, weekly, monthly).
    static func parse(_ html: String) -> (WindowUsage?, WindowUsage?, WindowUsage?)? {
        let rolling = parseWindow(html, key: "rollingUsage")
        let weekly = parseWindow(html, key: "weeklyUsage")
        let monthly = parseWindow(html, key: "monthlyUsage")
        if rolling == nil && weekly == nil && monthly == nil { return nil }
        return (rolling, weekly, monthly)
    }

    private static let numberPattern = "(-?\\d+(?:\\.\\d+)?)"

    /// SolidJS SSR hydration: `rollingUsage:$R[12]={usagePercent:3,resetInSec:8655}`
    /// (field order varies — try both).
    private static func parseWindow(_ html: String, key: String) -> WindowUsage? {
        let pctFirst = try? NSRegularExpression(
            pattern: "\(key):\\$R\\[\\d+\\]=\\{[^}]*usagePercent:\(numberPattern)[^}]*resetInSec:\(numberPattern)[^}]*\\}")
        let resetFirst = try? NSRegularExpression(
            pattern: "\(key):\\$R\\[\\d+\\]=\\{[^}]*resetInSec:\(numberPattern)[^}]*usagePercent:\(numberPattern)[^}]*\\}")

        if let m = pctFirst?.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
           let pct = Double(html[Range(m.range(at: 1), in: html)!]),
           let reset = Double(html[Range(m.range(at: 2), in: html)!]) {
            return WindowUsage(pct: pct, reset: Int64(reset))
        }
        if let m = resetFirst?.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
           let reset = Double(html[Range(m.range(at: 1), in: html)!]),
           let pct = Double(html[Range(m.range(at: 2), in: html)!]) {
            return WindowUsage(pct: pct, reset: Int64(reset))
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
        for item in items.dropFirst() {
            guard item.range(of: "data-slot=\"usage-label\">\(label)", options: [.caseInsensitive]) != nil else { continue }
            let valueRe = try? NSRegularExpression(pattern: "data-slot=\"usage-value\">[^0-9]*(\\d+(?:\\.\\d+)?)")
            let resetRe = try? NSRegularExpression(pattern: "data-slot=\"(reset-time|reset-now)\">([\\s\\S]*?)<\\/span>")
            guard let vm = valueRe?.firstMatch(in: item, range: NSRange(item.startIndex..., in: item)),
                  let pct = Double(item[Range(vm.range(at: 1), in: item)!]) else { continue }
            guard let rm = resetRe?.firstMatch(in: item, range: NSRange(item.startIndex..., in: item)) else { continue }
            var resetText = item[Range(rm.range(at: 2), in: item)!]
                .replacingOccurrences(of: "<!--$-->", with: "")
                .replacingOccurrences(of: "<!--/-->", with: "")
            resetText = resetText.replacingOccurrences(of: "Resets?\\s*in\\s*", with: "", options: .regularExpression)
            let reset = Self.parseHumanDuration(resetText.trimmingCharacters(in: .whitespacesAndNewlines))
            return WindowUsage(pct: pct, reset: reset)
        }
        return nil
    }

    /// "1 hour 56 minutes" / "6 days 2 hours" / "26 days 17 hours" -> seconds.
    static func parseHumanDuration(_ text: String) -> Int64 {
        let t = text.lowercased().trimmingCharacters(in: .whitespaces)
        if t.contains("now") { return 0 }
        var total: Int64 = 0
        let day = firstNumber(t, unit: "day"); if let v = day { total += Int64(v * 86400) }
        let hour = firstNumber(t, unit: "hour"); if let v = hour { total += Int64(v * 3600) }
        let minute = firstNumber(t, unit: "minute"); if let v = minute { total += Int64(v * 60) }
        let second = firstNumber(t, unit: "second"); if let v = second { total += Int64(v) }
        return total
    }

    private static func firstNumber(_ text: String, unit: String) -> Double? {
        let re = try? NSRegularExpression(pattern: "(\\d+(?:\\.\\d+)?)\\s*\(unit)s?")
        guard let m = re?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: 1), in: text),
              let v = Double(text[r]) else { return nil }
        return v
    }
}
