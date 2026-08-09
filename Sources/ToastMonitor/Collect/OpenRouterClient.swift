import Foundation

/// OpenRouter quota panel.
///
/// Data model:
///  - one or more API keys (settings "or_keys", JSON array) — each key's
///    /api/v1/key is queried and daily/weekly/monthly summed across keys
///  - /api/v1/credits (account-level, management-key only) — total usage
///    across ALL keys + prepaid balance
///  - /api/v1/keys is queried with a key whose /api/v1/key response explicitly
///    reports `is_management_key`; key order never determines privilege.
final class OpenRouterClient: ObservableObject {
    nonisolated(unsafe) static let shared = OpenRouterClient()
    static let maxAPIKeyLength = 512
    static let maxKeyCount = 64
    static let maxKeyPayloadLength = 40_000
    static let maxLabelLength = 256
    struct KeyInfo {
        let label: String
        let usageDaily: Double
        let usageWeekly: Double

        let usageMonthly: Double
    }

    struct State {
        var usage: Double = 0
        var usageDaily: Double = 0
        var usageWeekly: Double = 0
        var usageMonthly: Double = 0
        var limit: Double?
        var limitRemaining: Double?
        var limitReset: String?
        var isFreeTier: Bool = false
        var creditsTotal: Double?
        var creditsUsage: Double?
        var accountUsage: Double?
        var accountBalance: Double?
        var isManagementKey: Bool = false
        var keyCount: Int = 0
        var keys: [KeyInfo] = []
        var lastOK: Int64 = 0
        var error: String?
        var isLoading = false
    }

    private static func finiteAmount(_ value: NSNumber?) -> Double? {
        guard let value else { return nil }
        let d = value.doubleValue
        guard d.isFinite, d >= 0, d <= 1_000_000_000 else { return nil }
        return d
    }
    @Published private(set) var state = State()
    @Published private(set) var hasKey = false

    private let session: URLSession
    /// Retained: URLSession holds its delegate weakly.
    private let redirectBlocker = NoRedirectDelegate()
    private var timer: Timer?
    private var started = false
    private var refreshGeneration: UInt64 = 0
    private var keyLoadInFlight = false

    private var popoverVisible = false
    private var dashboardVisible = false
    private var foreground = false

    /// Background (nothing on screen) stops all polling; foregrounding
    /// rebuilds the timer and refreshes immediately.
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

    private init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 30
        // Credential-bearing requests must never be redirected: a downgrade
        // or cross-host redirect would forward the Bearer token.
        session = URLSession(configuration: cfg, delegate: redirectBlocker, delegateQueue: nil)
        // Keychain reads can wait for the login/keychain agent. Never perform
        // one while SwiftUI is constructing the menu bar scene.
        hasKey = false
        observeForeground()
    }

    // MARK: - Keys

    /// Keys live in the Keychain (P0-5); legacy SQLite values are migrated
    /// on first read, then erased.
    func storedKeys() -> [String] {
        if let kc = KeychainStore.get(account: "or-keys"), !kc.isEmpty {
            var keys: [String]?
            var needsUpgrade = false
            if kc.utf8.count <= Self.maxKeyPayloadLength,
               let data = kc.data(using: .utf8),
               let raw = try? JSONSerialization.jsonObject(with: data) as? [String] {
                keys = raw
            } else {
                // Bare key format (--set-or-key stores the raw string);
                // upgrade it to the array format in place — once.
                keys = [kc]
                needsUpgrade = true
            }
            if let keys {
                let arr = normalizedKeys(keys)
                if needsUpgrade {
                    saveKeys(arr)
                }
                // Remove any pre-Keychain plaintext remnants left by older builds.
                Database.shared.setSetting("or_keys", nil)
                Database.shared.setSetting("openrouter_key", nil)
                KeychainStore.delete(account: "openrouter-key")
                if arr.isEmpty { KeychainStore.delete(account: "or-keys") }
                return arr
            }
        }
        // Legacy migration (SQLite → Keychain, then erase). Fail closed:
        // when the Keychain write fails, return unconfigured instead of
        // serving plaintext values to live API calls. The plaintext stays on
        // disk (0600) as a recovery copy, marked unavailable.
        var migrated: [String] = []
        if let raw = Database.shared.setting("or_keys"),
           raw.utf8.count <= Self.maxKeyPayloadLength,
           let data = raw.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [String] {
            migrated = arr
        }
        var legacy: [String] = migrated
        if let k = KeychainStore.get(account: "openrouter-key"), !k.isEmpty { legacy.append(k) }
        if let k = Database.shared.setting("openrouter_key"), !k.isEmpty { legacy.append(k) }
        if !legacy.isEmpty {
            let arr = normalizedKeys(legacy)
            if saveToKeychain(arr) {
                Database.shared.setSetting("or_keys", nil)
                Database.shared.setSetting("openrouter_key", nil)
                KeychainStore.delete(account: "openrouter-key")
                Database.shared.setSetting("or_cred_storage", "keychain")
                return arr
            }
            Database.shared.setSetting("or_cred_storage", "keychain-unavailable")
            return []
        }
        return []
    }

    private func normalizedKeys(_ keys: [String]) -> [String] {
        var seen = Set<String>()
        let normalized = keys.compactMap { raw -> String? in
            let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty,
                  key.count <= Self.maxAPIKeyLength,
                  key.rangeOfCharacter(from: .controlCharacters) == nil,
                  seen.insert(key).inserted else { return nil }
            return key
        }
        return Array(normalized.prefix(Self.maxKeyCount))
    }

    private func saveToKeychain(_ keys: [String]) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: keys) else { return false }
        return KeychainStore.set(String(data: data, encoding: .utf8) ?? "", account: "or-keys")
    }

    @discardableResult
    private func saveKeys(_ keys: [String]) -> Bool {
        let arr = normalizedKeys(keys)
        guard !arr.isEmpty else { return false }
        if saveToKeychain(arr) {
            Database.shared.setSetting("or_keys", nil)
            Database.shared.setSetting("or_cred_storage", "keychain")
            return true
        }
        // Never create a new plaintext SQLite copy when Keychain is locked or
        // unavailable. The caller keeps the previous value and surfaces an
        // actionable error instead.
        Database.shared.setSetting("or_cred_storage", "keychain-unavailable")
        return false
    }
    /// Replace all keys (provisioning path).
    @discardableResult
    func setKey(_ key: String?) -> Bool {
        if let key,
           let normalized = normalizedKeys([key]).first,
           saveKeys([normalized]) {
            hasKey = true
        } else if key != nil {
            state.error = "无法写入 macOS 钥匙串，未保存 API Key"
            return false
        } else {
            KeychainStore.delete(account: "or-keys")
            KeychainStore.delete(account: "openrouter-key")
            Database.shared.setSetting("or_keys", nil)
            Database.shared.setSetting("openrouter_key", nil)
            Database.shared.setSetting("or_cred_storage", nil)
            hasKey = false
            var cleared = State()
            cleared.error = "未配置 API Key"
            state = cleared
        }
        refresh()
        return true
    }

    /// Append a key for multi-key usage aggregation.
    @discardableResult
    func addKey(_ key: String) -> Bool {
        guard let normalized = normalizedKeys([key]).first else { return false }
        var keys = storedKeys()
        guard keys.count < Self.maxKeyCount else {
            state.error = "API Key 数量已达上限"
            return false
        }
        keys.append(normalized)
        guard saveKeys(keys) else {
            state.error = "无法写入 macOS 钥匙串，未保存 API Key"
            return false
        }
        hasKey = true
        refresh()
        return true
    }

    /// Provisioning path for headless/SSH setups.
    @discardableResult
    func provisionKey(_ key: String) -> Bool {
        return setKey(key)
    }

    // MARK: - Polling

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
        guard !keyLoadInFlight else { return }
        keyLoadInFlight = true
        // Keychain reads MUST run on the main thread: every read unlocks the
        // vault (SecKeychainUnlock needs the main-thread UI session). Reading
        // here on the background queue silently failed, leaving hasKey=false
        // and the OpenRouter row stuck on "尚未配置 API key".
        let keys = storedKeys()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.keyLoadInFlight = false
                self.refresh(with: keys)
            }
        }
    }

    private func refresh(with keys: [String]) {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        hasKey = !keys.isEmpty
        state.keyCount = keys.count
        guard !keys.isEmpty else {
            var cleared = State()
            cleared.error = "未配置 API Key"
            state = cleared
            return
        }
        state.isLoading = true
        state.error = nil
        // A new request must not leave a failed/unauthorized response looking
        // like the current account state. Values are repopulated only from
        // this generation's responses.
        state.usage = 0
        state.usageDaily = 0
        state.usageWeekly = 0
        state.usageMonthly = 0
        state.limit = nil
        state.limitRemaining = nil
        state.limitReset = nil
        state.creditsTotal = nil
        state.creditsUsage = nil
        state.isManagementKey = false
        state.keys = []
        state.accountUsage = nil
        state.accountBalance = nil

        let group = DispatchGroup()
        var results: [String: [String: Any]] = [:]
        var failures: [String] = []

        for key in keys {
            group.enter()
            fetch("/api/v1/key", key: key) { json, err in
                if let json { results[key] = json }
                if let err { failures.append(err) }
                group.leave()
            }
        }

        // Resolve privilege from the response belonging to that exact key.
        // Never assume keys[0] is the management key. The credits and keys
        // endpoints are management-only; regular keys keep balance unknown
        // instead of turning an expected 401/403 into a permanent error.
        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            guard self.refreshGeneration == generation else { return }
            let managementKey = results.first { _, json in
                (json["data"] as? [String: Any])?["is_management_key"] as? Bool == true
            }?.key
            self.state.isManagementKey = managementKey != nil
            let adminGroup = DispatchGroup()

            if let managementKey {
                adminGroup.enter()
                self.fetch("/api/v1/credits", key: managementKey) { json, err in
                    guard self.refreshGeneration == generation else { adminGroup.leave(); return }
                    if let json, let data = json["data"] as? [String: Any] {
                        let total = Self.finiteAmount(data["total_credits"] as? NSNumber)
                        let used = Self.finiteAmount(data["total_usage"] as? NSNumber)
                        self.state.creditsTotal = total
                        self.state.creditsUsage = used
                        self.state.accountUsage = used
                        if let total, let used {
                            self.state.accountBalance = max(total - used, 0)
                        }
                    } else if err == nil {
                        failures.append("账户额度响应缺少 data")
                    }
                    adminGroup.leave()
                }

                adminGroup.enter()
                self.fetch("/api/v1/keys", key: managementKey) { json, err in
                    guard self.refreshGeneration == generation else { adminGroup.leave(); return }
                    if let json, let data = json["data"] as? [[String: Any]] {
                        self.state.keys = data.prefix(Self.maxKeyCount).compactMap { k in
                            guard let rawLabel = k["label"] as? String,
                                  rawLabel.count <= Self.maxLabelLength,
                                  !rawLabel.isEmpty,
                                  rawLabel.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
                            return KeyInfo(
                                label: rawLabel,
                                usageDaily: Self.finiteAmount(k["usage_daily"] as? NSNumber) ?? 0,
                                usageWeekly: Self.finiteAmount(k["usage_weekly"] as? NSNumber) ?? 0,
                                usageMonthly: Self.finiteAmount(k["usage_monthly"] as? NSNumber) ?? 0)
                        }
                        self.state.keyCount = self.state.keys.count
                    } else if err == nil {
                        failures.append("管理 key 响应缺少 data")
                    }
                    adminGroup.leave()
                }
            }

            // Finish only after optional management calls have completed.
            adminGroup.notify(queue: .main) { [weak self] in
                guard let self else { return }
                guard self.refreshGeneration == generation else { return }
                self.finishRefresh(results: results, failures: failures)
            }
        }
    }

    /// Aggregates the /api/v1/key results into state (admin fields were
    /// already populated by the credits/keys calls, if any).
    private func finishRefresh(results: [String: [String: Any]], failures: [String]) {
        state.isLoading = false
        if results.isEmpty {
            state.error = failures.first ?? "查询失败"
            return
        }
        var usage: Double = 0, daily: Double = 0, weekly: Double = 0, monthly: Double = 0
        var limit: Double?, remaining: Double?, reset: String?
        var freeTier = false
        var invalidKeyResponses = 0
        for (_, json) in results {
            guard let data = json["data"] as? [String: Any] else {
                invalidKeyResponses += 1
                continue
            }
            usage += Self.finiteAmount(data["usage"] as? NSNumber) ?? 0
            daily += Self.finiteAmount(data["usage_daily"] as? NSNumber) ?? 0
            weekly += Self.finiteAmount(data["usage_weekly"] as? NSNumber) ?? 0
            monthly += Self.finiteAmount(data["usage_monthly"] as? NSNumber) ?? 0
            if let v = Self.finiteAmount(data["limit"] as? NSNumber) { limit = v }
            if let v = Self.finiteAmount(data["limit_remaining"] as? NSNumber) { remaining = v }
            if let r = data["limit_reset"] as? String,
               r.count <= Self.maxLabelLength,
               r.rangeOfCharacter(from: .controlCharacters) == nil {
                reset = r
            }
            if (data["is_free_tier"] as? NSNumber)?.boolValue == true { freeTier = true }
        }
        if invalidKeyResponses > 0 {
            var f = failures
            f.append("\(invalidKeyResponses) 个 key 响应无用量数据")
            state.error = f.isEmpty ? nil : "部分数据获取失败：\(f.prefix(2).joined(separator: "；"))"
        } else {
            state.error = failures.isEmpty ? nil : "部分数据获取失败：\(failures.prefix(2).joined(separator: "；"))"
        }
        state.usage = usage
        state.usageDaily = daily
        state.usageWeekly = weekly
        state.usageMonthly = monthly
        state.limit = limit
        state.limitRemaining = remaining
        state.limitReset = reset
        state.isFreeTier = freeTier
        // accountUsage/accountBalance already set by the credits call.
        state.lastOK = Int64(Date().timeIntervalSince1970)
        persist()
    }

    private func persist() {
        let s = state
        let snap = Database.ORSnapshot(
            ts: Int64(Date().timeIntervalSince1970),
            usage: s.usage, usageDaily: s.usageDaily, usageWeekly: s.usageWeekly, usageMonthly: s.usageMonthly,
            limit: s.limit, limitRemaining: s.limitRemaining, limitReset: s.limitReset,
            isFreeTier: s.isFreeTier, creditsTotal: s.creditsTotal, creditsUsage: s.creditsUsage,
            accountUsage: s.accountUsage, accountBalance: s.accountBalance,
            isManagementKey: s.isManagementKey)
        Database.shared.insertORSnapshot(snap)
    }

    private func fetch(_ path: String, key: String,
                       completion: @escaping ([String: Any]?, String?) -> Void) {
        guard let url = URL(string: "https://openrouter.ai\(path)") else {
            completion(nil, "URL 无效")
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        session.dataTask(with: req) { data, resp, err in
            if let err {
                DispatchQueue.main.async { completion(nil, err.localizedDescription) }
                return
            }
            guard let http = resp as? HTTPURLResponse else {
                DispatchQueue.main.async { completion(nil, "无 HTTP 响应") }
                return
            }
            if (300..<400).contains(http.statusCode) {
                DispatchQueue.main.async { completion(nil, "拒绝重定向 (HTTP \(http.statusCode))") }
                return
            }
            if http.statusCode == 401 {
                DispatchQueue.main.async { completion(nil, "key 无效或未授权 (401)") }
                return
            }
            if http.statusCode == 403 {
                DispatchQueue.main.async { completion(nil, "权限不足 (403)——该 key 无此查询权限") }
                return
            }
            if http.statusCode == 429 {
                DispatchQueue.main.async { completion(nil, "请求过于频繁 (429)") }
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                DispatchQueue.main.async { completion(nil, "HTTP \(http.statusCode)") }
                return
            }
            // Reject oversized responses from the header before buffering.
            if http.expectedContentLength > 10_000_000 {
                DispatchQueue.main.async { completion(nil, "响应过大 (>10MB)") }
                return
            }
            if let mime = http.mimeType,
               !mime.contains("json") && !mime.contains("text") {
                DispatchQueue.main.async { completion(nil, "非 JSON 响应 (\(mime))") }
                return
            }
            guard let data, data.count < 10_000_000,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                DispatchQueue.main.async { completion(nil, "响应解析失败或过大") }
                return
            }
            DispatchQueue.main.async { completion(obj, nil) }
        }.resume()
    }
}
