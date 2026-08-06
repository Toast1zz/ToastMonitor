import Foundation

/// OpenRouter quota panel.
///
/// Data model:
///  - one or more API keys (settings "or_keys", JSON array) — each key's
///    /api/v1/key is queried and daily/weekly/monthly summed across keys
///  - /api/v1/credits (account-level, works with a regular key) — total
///    usage across ALL keys + prepaid balance
///  - if the first key is a management key, /api/v1/keys enumerates every
///    key in the account for a per-key breakdown
final class OpenRouterClient: ObservableObject {
    static let shared = OpenRouterClient()

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

    @Published private(set) var state = State()
    @Published private(set) var hasKey = false

    private let session: URLSession
    private var timer: Timer?
    private var refreshGeneration: UInt64 = 0
    private var keyLoadInFlight = false

    private init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 30
        session = URLSession(configuration: cfg)
        // Keychain reads can wait for the login/keychain agent. Never perform
        // one while SwiftUI is constructing the menu bar scene.
        hasKey = false
    }

    // MARK: - Keys

    /// Keys live in the Keychain (P0-5); legacy SQLite values are migrated
    /// on first read, then erased.
    func storedKeys() -> [String] {
        if let kc = KeychainStore.get(account: "or-keys"), !kc.isEmpty {
            var keys: [String]?
            var needsUpgrade = false
            if let data = kc.data(using: .utf8),
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
        return keys.compactMap { raw in
            let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, seen.insert(key).inserted else { return nil }
            return key
        }
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
        if let key {
            let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, saveKeys([key]) else {
                state.error = "无法写入 macOS 钥匙串，未保存 API Key"
                return false
            }
            hasKey = true
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
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return false }
        var keys = storedKeys()
        keys.append(key)
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
        refresh()
        let t = Timer(timeInterval: 300, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
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

        // Account-level credits (works with a regular key).
        group.enter()
        fetch("/api/v1/credits", key: keys[0]) { json, err in
            guard self.refreshGeneration == generation else { group.leave(); return }
            if let err { failures.append("账户额度: \(err)") }
            if let json, let data = json["data"] as? [String: Any] {
                let total = (data["total_credits"] as? NSNumber)?.doubleValue
                let used = (data["total_usage"] as? NSNumber)?.doubleValue
                self.state.creditsTotal = total
                self.state.creditsUsage = used
                self.state.accountUsage = used
                // Available balance ≠ purchased credits (P0-7): credits minus
                // cumulative usage across ALL keys.
                if let total, let used {
                    self.state.accountBalance = max(total - used, 0)
                }
            } else if err == nil {
                failures.append("账户额度响应缺少 data")
            }
            group.leave()
        }

        // Management key: enumerate all account keys.
        group.enter()
        fetch("/api/v1/keys", key: keys[0]) { json, err in
            guard self.refreshGeneration == generation else { group.leave(); return }
            if let err, !err.isEmpty { failures.append("管理 key: \(err)") }
            if let json, let data = json["data"] as? [[String: Any]] {
                self.state.isManagementKey = true
                self.state.keys = data.compactMap { k in
                    guard let label = k["label"] as? String else { return nil }
                    return KeyInfo(
                        label: label,
                        usageDaily: (k["usage_daily"] as? NSNumber)?.doubleValue ?? 0,
                        usageWeekly: (k["usage_weekly"] as? NSNumber)?.doubleValue ?? 0,
                        usageMonthly: (k["usage_monthly"] as? NSNumber)?.doubleValue ?? 0)
                }
                self.state.keyCount = self.state.keys.count
            } else {
                if err == nil { failures.append("管理 key 响应缺少 data") }
                self.state.isManagementKey = false
                self.state.keys = []
                self.state.keyCount = keys.count
            }
            group.leave()
        }

        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            guard self.refreshGeneration == generation else { return }
            self.state.isLoading = false
            if results.isEmpty {
                self.state.error = failures.first ?? "查询失败"
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
                usage += (data["usage"] as? NSNumber)?.doubleValue ?? 0
                daily += (data["usage_daily"] as? NSNumber)?.doubleValue ?? 0
                weekly += (data["usage_weekly"] as? NSNumber)?.doubleValue ?? 0
                monthly += (data["usage_monthly"] as? NSNumber)?.doubleValue ?? 0
                if let v = data["limit"] as? NSNumber { limit = v.doubleValue }
                if let v = data["limit_remaining"] as? NSNumber { remaining = v.doubleValue }
                if let r = data["limit_reset"] as? String { reset = r }
                if (data["is_free_tier"] as? NSNumber)?.boolValue == true { freeTier = true }
            }
            if invalidKeyResponses > 0 {
                failures.append("\(invalidKeyResponses) 个 key 响应无用量数据")
            }
            self.state.usage = usage
            self.state.usageDaily = daily
            self.state.usageWeekly = weekly
            self.state.usageMonthly = monthly
            self.state.limit = limit
            self.state.limitRemaining = remaining
            self.state.limitReset = reset
            self.state.isFreeTier = freeTier
            // accountUsage/accountBalance already set by the credits call.
            self.state.lastOK = Int64(Date().timeIntervalSince1970)
            self.state.error = failures.isEmpty ? nil : "部分数据获取失败：\(failures.prefix(2).joined(separator: "；"))"
            self.persist()
        }
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
