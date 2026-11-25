import Foundation

/// OpenCode Go subscription quota.
/// There is no public quota API — the workspace dashboard page
/// (https://opencode.ai/workspace/<id>/go) embeds SolidJS SSR hydration
/// data with rollingUsage / weeklyUsage / monthlyUsage (usagePercent +
/// resetInSec). We fetch it with the session cookie and parse both the
/// SSR format and the newer data-slot HTML format.
@MainActor
final class OpenCodeGoClient: ObservableObject {
    static let shared = OpenCodeGoClient()
    nonisolated static let maxWorkspaceIDLength = 128
    nonisolated static let maxCookieLength = 16_384
    nonisolated static let maxHTMLLength = 10_000_000
    nonisolated static let maxHTMLItemLength = 100_000

    /// Plan caps in USD (from opencode.ai/docs/go).
    nonisolated static let rollingLimitUSD: Double = 12
    nonisolated static let weeklyLimitUSD: Double = 30
    nonisolated static let monthlyLimitUSD: Double = 60
    /// Default subscription price ($10 buys $60 of usage); editable in Settings.
    nonisolated static let monthlyPriceUSD: Double = 10

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

    private let database: Database
    private let session: URLSession
    /// Retained: URLSession holds its delegate weakly.
    private let redirectBlocker = NoRedirectDelegate()
    private var started = false
    private var inFlight = false
    private var refreshGeneration: UInt64 = 0
    private var backoff = RefreshBackoff()
    private let poller = ForegroundPoller()
    private var credentialsLoaded = false
    private var cachedCredentials: (workspaceId: String, cookie: String)?
    /// Set when a keychain read/write failed with errSecInteractionNotAllowed
    /// (login keychain locked), so refresh() can say so instead of "Not
    /// configured". Reset by a successful provision/clear.
    private var keychainLocked = false

    init(configuration: URLSessionConfiguration? = nil, database: Database = .shared) {
        self.database = database
        let cfg = configuration ?? URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 40
        cfg.httpCookieStorage = nil
        cfg.httpShouldSetCookies = false
        // Credential-bearing request (auth cookie) — never follow redirects.
        session = URLSession(configuration: cfg, delegate: redirectBlocker, delegateQueue: nil)
        // Credential lookup may wait for the login/keychain agent. It is
        // loaded asynchronously after the UI has started.
        configured = false
    }

    private nonisolated static let settingsQueue = DispatchQueue(label: "toastmonitor.opencodego.settings", qos: .utility)

    private func writeSettingAsync(_ key: String, _ value: String?) {
        let database = self.database
        Self.settingsQueue.async {
            _ = database.setSetting(key, value)
        }
    }

    func flushSettings() { Self.settingsQueue.sync {} }

    nonisolated static func normalizedWorkspaceID(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        guard !value.isEmpty,
              value.count <= maxWorkspaceIDLength,
              value.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return value
    }

    nonisolated static func normalizedCookie(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("cookie:") {
            value = String(value.dropFirst("cookie:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if value.hasPrefix("auth=") {
            value = String(value.dropFirst("auth=".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !value.isEmpty,
              value.count <= maxCookieLength,
              value.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        return value
    }

    /// Credentials live in the Keychain; legacy SQLite values are
    /// migrated on first read, then erased. Fail closed: when the Keychain
    /// is unavailable the app reports unconfigured instead of serving
    /// plaintext SQLite values to live API calls.
    nonisolated private static func loadCredentials(database: Database) -> (value: (workspaceId: String, cookie: String)?, locked: Bool) {
        let (wsRead, wsStatus) = KeychainStore.getWithStatus(account: "go-workspace-id")
        let (ckRead, ckStatus) = KeychainStore.getWithStatus(account: "go-auth-cookie")
        var ws = wsRead
        var ck = ckRead
        var readLocked = KeychainStore.authorizationFailures.contains(wsStatus)
            || KeychainStore.authorizationFailures.contains(ckStatus)
        if ws != nil && ck != nil {
            database.setSetting("go_workspace_id", nil)
            database.setSetting("go_auth_cookie", nil)
        }
        if ws == nil || ck == nil {
            let legacyWS = database.setting("go_workspace_id")
            let legacyCK = database.setting("go_auth_cookie")
            if let legacyWS, let legacyCK,
               let normalizedWS = Self.normalizedWorkspaceID(legacyWS),
               let normalizedCK = Self.normalizedCookie(legacyCK) {
                let wsWrite = KeychainStore.setWithStatus(normalizedWS, account: "go-workspace-id")
                let ckWrite = wsWrite.ok
                    ? KeychainStore.setWithStatus(normalizedCK, account: "go-auth-cookie")
                    : (ok: false, status: wsWrite.status)
                if wsWrite.ok && ckWrite.ok {
                    database.setSetting("go_workspace_id", nil)
                    database.setSetting("go_auth_cookie", nil)
                    database.setSetting("go_cred_storage", "keychain")
                    ws = normalizedWS
                    ck = normalizedCK
                    readLocked = false
                } else {
                    database.setSetting("go_cred_storage", "keychain-unavailable")
                    let writeLocked = KeychainStore.authorizationFailures.contains(wsWrite.status)
                        || KeychainStore.authorizationFailures.contains(ckWrite.status)
                    return (nil, readLocked || writeLocked)
                }
            } else if legacyWS != nil || legacyCK != nil {
                // Keychain unavailable or invalid legacy data: treat as
                // unconfigured. Plaintext stays as a recovery copy but is
                // never used for requests.
                database.setSetting("go_cred_storage", "keychain-unavailable")
                return (nil, readLocked)
            }
        }
        guard let ws = ws.flatMap(Self.normalizedWorkspaceID),
              let ck = ck.flatMap(Self.normalizedCookie) else {
            // Nothing usable: genuinely unconfigured, or the keychain is
            // locked (reads then return nil indistinguishably). Remember the
            // lock so the error message is actionable.
            return (nil, readLocked)
        }
        return ((ws, ck), false)
    }

    nonisolated private static func writeProvisionToKeychain(workspaceID: String, authCookie: String) -> (ok: Bool, locked: Bool) {
        let (oldWorkspace, oldWSStatus) = KeychainStore.getWithStatus(account: "go-workspace-id")
        let (oldCookie, oldCKStatus) = KeychainStore.getWithStatus(account: "go-auth-cookie")
        let wsWrite = KeychainStore.setWithStatus(workspaceID, account: "go-workspace-id", allowPrompt: true)
        let ckWrite = wsWrite.ok
            ? KeychainStore.setWithStatus(authCookie, account: "go-auth-cookie", allowPrompt: true)
            : (ok: false, status: errSecSuccess)
        if wsWrite.ok && ckWrite.ok {
            return (true, false)
        }
        let locked = KeychainStore.authorizationFailures.contains(wsWrite.status)
            || (!wsWrite.ok ? false : KeychainStore.authorizationFailures.contains(ckWrite.status))
        if let oldWorkspace {
            _ = KeychainStore.setWithStatus(oldWorkspace, account: "go-workspace-id")
        } else if wsWrite.ok && oldWSStatus == errSecItemNotFound {
            _ = KeychainStore.delete(account: "go-workspace-id")
        }
        if let oldCookie {
            _ = KeychainStore.setWithStatus(oldCookie, account: "go-auth-cookie")
        } else if ckWrite.ok && oldCKStatus == errSecItemNotFound {
            _ = KeychainStore.delete(account: "go-auth-cookie")
        }
        return (false, locked)
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
        invalidateInFlight()
        let outcome = Self.writeProvisionToKeychain(workspaceID: workspaceID, authCookie: authCookie)
        return applyProvisionOutcome(outcome, workspaceID: workspaceID, authCookie: authCookie)
    }

    @discardableResult
    func provisionAsync(workspaceId: String, cookie: String) async -> Bool {
        guard let workspaceID = Self.normalizedWorkspaceID(workspaceId),
              let authCookie = Self.normalizedCookie(cookie) else {
            configured = false
            state.error = "Invalid workspaceId or cookie"
            return false
        }
        invalidateInFlight()
        let outcome = await Task.detached(priority: .userInitiated) {
            Self.writeProvisionToKeychain(workspaceID: workspaceID, authCookie: authCookie)
        }.value
        return applyProvisionOutcome(outcome, workspaceID: workspaceID, authCookie: authCookie)
    }

    private func applyProvisionOutcome(_ outcome: (ok: Bool, locked: Bool),
                                       workspaceID: String, authCookie: String) -> Bool {
        guard outcome.ok else {
            configured = false
            keychainLocked = outcome.locked
            state.error = outcome.locked
                ? "Keychain locked or access denied; cookie was not saved"
                : "Keychain write failed — cookie not saved"
            return false
        }
        writeSettingAsync("go_workspace_id", nil)
        writeSettingAsync("go_auth_cookie", nil)
        writeSettingAsync("go_cred_storage", "keychain")
        keychainLocked = false
        cachedCredentials = (workspaceID, authCookie)
        credentialsLoaded = true
        configured = true
        state.error = nil
        return true
    }

    nonisolated private static func deleteKeychainCredentials() -> Bool {
        let deletedWorkspace = KeychainStore.delete(account: "go-workspace-id", allowPrompt: true)
        let deletedCookie = KeychainStore.delete(account: "go-auth-cookie", allowPrompt: true)
        return deletedWorkspace && deletedCookie
    }

    @discardableResult
    func clear() -> Bool {
        invalidateInFlight()
        guard Self.deleteKeychainCredentials() else {
            state.error = "Keychain delete failed — credentials still stored"
            return false
        }
        applyClearSuccess()
        return true
    }

    @discardableResult
    func clearAsync() async -> Bool {
        invalidateInFlight()
        let ok = await Task.detached(priority: .userInitiated) {
            Self.deleteKeychainCredentials()
        }.value
        guard ok else {
            state.error = "Keychain delete failed — credentials still stored"
            return false
        }
        applyClearSuccess()
        return true
    }

    private func applyClearSuccess() {
        writeSettingAsync("go_workspace_id", nil)
        writeSettingAsync("go_auth_cookie", nil)
        writeSettingAsync("go_cred_storage", nil)
        cachedCredentials = nil
        credentialsLoaded = true
        configured = false
        keychainLocked = false
        var cleared = State()
        cleared.error = "Not configured"
        state = cleared
    }

    private func invalidateInFlight() {
        refreshGeneration &+= 1
        inFlight = false
        state.isLoading = false
        backoff.succeeded()
    }

    func start() {
        guard !started else { return }
        started = true
        refresh()
        poller.start(onWake: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.backoff.allowNow()
                self.refresh(force: self.state.error != nil)
            }
        }) { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func refresh(force: Bool = false) {
        guard !inFlight else { return }
        if force {
            backoff.allowNow()
            if keychainLocked { credentialsLoaded = false }
        }
        // Backoff gate: skip attempts inside the backoff window.
        if backoff.isWaiting { return }
        inFlight = true
        if credentialsLoaded {
            guard let cachedCredentials else {
                inFlight = false
                configured = false
                var cleared = State()
                cleared.error = keychainLocked ? "Keychain locked or access denied" : "Not configured"
                state = cleared
                return
            }
            refresh(with: cachedCredentials)
            return
        }
        let generation = refreshGeneration
        let database = self.database
        // The login Keychain may synchronously wait on securityd. Resolve the
        // pair once on a utility queue, then keep it in memory for every timer
        // and foreground refresh during this process lifetime.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let loaded = Self.loadCredentials(database: database)
            Task { @MainActor [weak self] in
                guard let self, self.refreshGeneration == generation else { return }
                let creds = loaded.value
                self.keychainLocked = loaded.locked
                self.cachedCredentials = creds
                guard let creds else {
                    // Never freeze credentialsLoaded = true while Keychain is locked;
                    // unlocking later must automatically re-read.
                    self.credentialsLoaded = !loaded.locked
                    self.inFlight = false
                    self.configured = false
                    var cleared = State()
                    cleared.error = self.keychainLocked ? "Keychain locked or access denied" : "Not configured"
                    self.state = cleared
                    return
                }
                self.credentialsLoaded = true
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
        // Keep the previous values while refreshing; new data replaces the
        // snapshot whole, so the popover row never flashes Loading. A failed
        // response still sets `error`, which the UI shows first.

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
                if let err {
                    self.state.error = err.localizedDescription
                    self.backoff.failed()
                    return
                }
                guard let data else {
                    self.state.error = "Empty response"
                    self.backoff.failed()
                    return
                }
                guard data.count <= Self.maxHTMLLength else {
                    self.state.error = "Response too large (>10MB)"
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
                // Reject oversized responses from the header before buffering.
                if http.expectedContentLength > 10_000_000 {
                    self.state.error = "Response too large (>10MB)"
                    self.backoff.failed()
                    return
                }
                guard http.statusCode == 200 else {
                    self.state.error = (http.statusCode == 401 || http.statusCode == 403)
                        ? "Cookie expired, reconfigure needed (HTTP \(http.statusCode))"
                        : "HTTP \(http.statusCode)"
                    self.backoff.failed()
                    return
                }
                if let mime = http.mimeType,
                   !mime.contains("html") && !mime.contains("json") && !mime.contains("text") {
                    self.state.error = "Non-web response (\(mime))"
                    self.backoff.failed()
                    return
                }
                guard let html = String(data: data, encoding: .utf8) else {
                    self.state.error = "Failed to parse response"
                    self.backoff.failed()
                    return
                }
                let parsed = Self.parse(html)
                guard let parsed, parsed.0 != nil || parsed.1 != nil || parsed.2 != nil else {
                    self.state.error = "No usage data found (page structure may have changed)"
                    self.backoff.failed()
                    return
                }
                self.state.rollingPct = parsed.0?.pct
                self.state.rollingReset = parsed.0?.reset
                self.state.weeklyPct = parsed.1?.pct
                self.state.weeklyReset = parsed.1?.reset
                self.state.monthlyPct = parsed.2?.pct
                self.state.monthlyReset = parsed.2?.reset
                self.state.lastOK = Int64(Date().timeIntervalSince1970)
                // Only a successful fetch advances the sync clock;
                // otherwise the UI could show "just synced" over an error.
                self.state.lastSync = Int64(Date().timeIntervalSince1970)
                self.state.error = nil
                self.backoff.succeeded()
                self.persist()
            }
        }.resume()
    }


    private func persist() {
        let s = state
        let snap = Database.OGSnapshot(
            ts: Int64(Date().timeIntervalSince1970),
            rollingPct: s.rollingPct, rollingReset: s.rollingReset,
            weeklyPct: s.weeklyPct, weeklyReset: s.weeklyReset,
            monthlyPct: s.monthlyPct, monthlyReset: s.monthlyReset)
        // DB write off the main actor.
        DispatchQueue.global(qos: .utility).async { [database] in
            database.insertOGSnapshot(snap)
        }
    }

    nonisolated private static func hasDisallowedControl(_ value: String) -> Bool {
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
    nonisolated static func parse(_ html: String) -> (WindowUsage?, WindowUsage?, WindowUsage?)? {
        guard html.count <= maxHTMLLength, !hasDisallowedControl(html) else { return nil }
        let rolling = parseWindow(html, key: "rollingUsage")
        let weekly = parseWindow(html, key: "weeklyUsage")
        let monthly = parseWindow(html, key: "monthlyUsage")
        if rolling == nil && weekly == nil && monthly == nil { return nil }
        return (rolling, weekly, monthly)
    }

    nonisolated private static let numberPattern = "(-?\\d+(?:\\.\\d+)?)"
    nonisolated private static func boundedPercent(_ raw: Double) -> Double? {
        guard raw.isFinite, raw >= 0, raw <= 100 else { return nil }
        return raw
    }
    nonisolated private static func boundedReset(_ raw: Double) -> Int64? {
        guard raw.isFinite, raw >= 0, raw <= 366 * 86400 else { return nil }
        return Int64(raw)
    }

    /// SolidJS SSR hydration: `rollingUsage:$R[12]={usagePercent:3,resetInSec:8655}`
    /// (field order varies — try both).
    nonisolated private static func parseWindow(_ html: String, key: String) -> WindowUsage? {
        let pctFirst = try? NSRegularExpression(
            pattern: "\(key):\\$R\\[\\d+\\]=\\{[^}]*usagePercent:\(numberPattern)[^}]*resetInSec:\(numberPattern)[^}]*\\}")
        let resetFirst = try? NSRegularExpression(
            pattern: "\(key):\\$R\\[\\d+\\]=\\{[^}]*resetInSec:\(numberPattern)[^}]*usagePercent:\(numberPattern)[^}]*\\}")

        if let m = pctFirst?.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
           let r1 = Range(m.range(at: 1), in: html),
           let r2 = Range(m.range(at: 2), in: html),
           let pct = Double(html[r1]),
           let reset = Double(html[r2]),
           let boundedPct = boundedPercent(pct),
           let boundedReset = boundedReset(reset) {
            return WindowUsage(pct: boundedPct, reset: boundedReset)
        }
        if let m = resetFirst?.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
           let r1 = Range(m.range(at: 1), in: html),
           let r2 = Range(m.range(at: 2), in: html),
           let reset = Double(html[r1]),
           let pct = Double(html[r2]),
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

    nonisolated private static func parseDataSlot(_ html: String, label: String) -> WindowUsage? {
        let items = html.components(separatedBy: "data-slot=\"usage-item\"")
        for item in items.dropFirst().prefix(256) {
            guard item.count <= maxHTMLItemLength else { continue }
            // Locate this item's own label first, then search value/reset
            // only in the region AFTER it. Searching the whole item can pair
            // a sibling label's value (e.g. an embedded "monthly usage" block
            // inside a "weekly usage" item) with the wrong reset.
            guard let labelRange = item.range(of: "data-slot=\"usage-label\">\(label)",
                                              options: [.caseInsensitive]) else { continue }
            let afterLabel = NSRange(labelRange.upperBound..., in: item)
            let valueRe = try? NSRegularExpression(pattern: "data-slot=\"usage-value\">[^0-9]*(\\d+(?:\\.\\d+)?)")
            let resetRe = try? NSRegularExpression(pattern: "data-slot=\"(reset-time|reset-now)\">([\\s\\S]*?)<\\/span>")
            guard let vm = valueRe?.firstMatch(in: item, range: afterLabel),
                  let valueRange = Range(vm.range(at: 1), in: item),
                  let pct = Double(item[valueRange]),
                  let pct = boundedPercent(pct) else { continue }
            guard let rm = resetRe?.firstMatch(in: item, range: afterLabel),
                  let resetRange = Range(rm.range(at: 2), in: item) else { continue }
            var resetText = item[resetRange]
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
    nonisolated static func parseHumanDuration(_ text: String) -> Int64 {
        guard text.count <= 256, !hasDisallowedControl(text) else { return -1 }
        let t = text.lowercased().trimmingCharacters(in: .whitespaces)
        if t.range(of: #"\bnow\b"#, options: .regularExpression) != nil { return 0 }
        var total = 0.0
        var matched = false
        if let v = firstNumber(t, unit: "day") { total += v * 86400; matched = true }
        if let v = firstNumber(t, unit: "hour") { total += v * 3600; matched = true }
        if let v = firstNumber(t, unit: "minute") { total += v * 60; matched = true }
        if let v = firstNumber(t, unit: "second") { total += v; matched = true }
        guard matched, total.isFinite, total >= 0, total <= 366 * 86400 else { return -1 }
        return Int64(total)
    }

    nonisolated private static func firstNumber(_ text: String, unit: String) -> Double? {
        let re = try? NSRegularExpression(pattern: "(\\d+(?:\\.\\d+)?)\\s*\(unit)s?")
        guard let m = re?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: 1), in: text),
              let v = Double(text[r]) else { return nil }
        return v
    }
}
