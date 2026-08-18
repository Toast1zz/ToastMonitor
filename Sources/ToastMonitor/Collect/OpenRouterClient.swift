import Foundation

/// OpenRouter quota panel.
///
/// Data model:
///  - one or more API keys (settings "or_keys", JSON array) — each key's
///    /api/v1/key is queried and daily/weekly/monthly summed across keys
///  - /api/v1/credits (account-level, available to keys with account access)
///    — total usage across ALL keys + prepaid balance
///  - /api/v1/keys is queried only with a key whose /api/v1/key response
///    explicitly reports `is_management_key`; key order never determines
///    management privilege.
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

    /// `/api/v1/credits` is an account endpoint and can be available to a
    /// regular key even when `/api/v1/key` reports `is_management_key=false`.
    /// Prefer a key with a valid key response, then fall back to the first
    /// configured key so the credits request can establish the real privilege.
    static func accountCreditsKey(keys: [String],
                                  results: [String: [String: Any]]) -> String? {
        if let managementKey = results.first(where: { _, json in
            (json["data"] as? [String: Any])?["is_management_key"] as? Bool == true
        })?.key {
            return managementKey
        }
        return keys.first(where: { key in
            (results[key]?["data"] as? [String: Any]) != nil
        }) ?? keys.first
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
    /// A refresh requested while the keychain load was in flight. The load
    /// completion re-runs refresh() so the request is not silently dropped
    /// for up to the keychain-agent wait (60s timer interval).
    private var pendingKeyRefresh = false
    private var legacyCleanupDone = false
    /// `nil` means the login Keychain has not been read yet. Once loaded,
    /// foreground refreshes reuse this in-memory copy and never call Security
    /// framework from the UI thread.
    private var cachedKeys: [String]?
    /// Rate limiting / backoff (S2): after a failed / 429 / 5xx refresh the
    /// next attempt backs off 60s → 2m → 5m → 15m; success resets. Prevents
    /// hammering OpenRouter with a fixed 60s cadence during degradation.
    private var backoffBase: TimeInterval = 0
    private var nextAllowedRefresh: TimeInterval = 0
    /// Merges concurrent refresh() calls so a timer tick + foreground + a
    /// manual setKey cannot fire overlapping request batches.
    private var refreshInFlight = false

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
                clearLegacyOpenRouterValuesOnce()
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
                clearLegacyOpenRouterValuesOnce()
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

    private func saveToKeychain(_ keys: [String], allowPrompt: Bool = false) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: keys) else { return false }
        return KeychainStore.set(String(data: data, encoding: .utf8) ?? "",
                                 account: "or-keys", allowPrompt: allowPrompt)
    }

    @discardableResult
    private func saveKeys(_ keys: [String], allowPrompt: Bool = false) -> Bool {
        let arr = normalizedKeys(keys)
        guard !arr.isEmpty else { return false }
        if saveToKeychain(arr, allowPrompt: allowPrompt) {
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

    private func clearLegacyOpenRouterValuesOnce() {
        guard !legacyCleanupDone else { return }
        legacyCleanupDone = true
        Database.shared.setSetting("or_keys", nil)
        Database.shared.setSetting("openrouter_key", nil)
        KeychainStore.delete(account: "openrouter-key")
    }
    /// Replace all keys (provisioning path).
    @discardableResult
    func setKey(_ key: String?) -> Bool {
        if let key,
           let normalized = normalizedKeys([key]).first,
           saveKeys([normalized], allowPrompt: true) {
            cachedKeys = [normalized]
            hasKey = true
        } else if key != nil {
            state.error = KeychainStore.lastWasInteractionNotAllowed
                ? "钥匙串被锁定/需要解锁，API key 未保存"
                : "Keychain write failed — API key not saved"
            return false
        } else {
            KeychainStore.delete(account: "or-keys", allowPrompt: true)
            KeychainStore.delete(account: "openrouter-key", allowPrompt: true)
            Database.shared.setSetting("or_keys", nil)
            Database.shared.setSetting("openrouter_key", nil)
            Database.shared.setSetting("or_cred_storage", nil)
            cachedKeys = []
            hasKey = false
            var cleared = State()
            cleared.error = "API key not configured"
            state = cleared
        }
        refresh()
        return true
    }

    /// Append a key for multi-key usage aggregation.
    @discardableResult
    func addKey(_ key: String) -> Bool {
        guard let normalized = normalizedKeys([key]).first else { return false }
        var keys = cachedKeys ?? storedKeys()
        guard keys.count < Self.maxKeyCount else {
            state.error = "API key count limit reached"
            return false
        }
        keys.append(normalized)
        guard saveKeys(keys, allowPrompt: true) else {
            state.error = KeychainStore.lastWasInteractionNotAllowed
                ? "钥匙串被锁定/需要解锁，API key 未保存"
                : "Keychain write failed — API key not saved"
            return false
        }
        cachedKeys = normalizedKeys(keys)
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
        guard !keyLoadInFlight else {
            // A setKey/addKey/foreground refresh arrived while the keychain
            // read is pending; remember it so the load completion re-runs us
            // with fresh keys instead of dropping the request.
            pendingKeyRefresh = true
            return
        }
        // Backoff gate: after a failure the next batch waits before retrying
        // (S2). Manual refreshes (Settings / toolbar) bypass the gate but
        // still respect the merged-in-flight guard below.
        if refreshInFlight { return }
        let now = ProcessInfo.processInfo.systemUptime
        if now < nextAllowedRefresh {
            // A deferred retry is already scheduled or the gate is active.
            // Leave the timer to fire the next attempt.
            return
        }
        refreshInFlight = true
        if let cachedKeys {
            refresh(with: cachedKeys)
            return
        }
        keyLoadInFlight = true
        // Standard SecItemCopyMatching is thread-safe. It can still wait for
        // securityd / login-keychain decryption, so it must not run on the
        // main actor where it would freeze the toolbar selection animation.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let keys = self?.storedKeys() ?? []
            DispatchQueue.main.async {
                guard let self else { return }
                self.keyLoadInFlight = false
                self.cachedKeys = keys
                self.refresh(with: keys)
                // Deliver a refresh that was requested while the load was
                // still running (CLIENT-3). keyLoadInFlight is already clear,
                // so this proceeds immediately.
                if self.pendingKeyRefresh {
                    self.pendingKeyRefresh = false
                    self.refresh()
                }
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
            // A locked login keychain reads as "no keys" (errSecItemNotFound
            // vs errSecInteractionNotAllowed); say so instead of reporting
            // unconfigured. checked right after storedKeys() so the status is
            // from the load just completed.
            cleared.error = KeychainStore.lastWasInteractionNotAllowed
                ? "钥匙串被锁定/需要解锁"
                : "API key not configured"
            state = cleared
            return
        }
        state.isLoading = true
        state.error = nil
        // 刷新期间保留上一次的数值：UI 继续显示旧快照（余额/额度/用量），
        // 新数据到达后由本代响应的完成回调整块替换，Popover 不闪
        // Loading/Idle。失败响应仍设置 error，由 UI 优先显示。

        let group = DispatchGroup()
        var results: [String: [String: Any]] = [:]
        var failures: [String] = []

        // Concurrency cap (S2): URLSession would otherwise queue all keys and
        // time out the tail; a semaphore bounds simultaneous requests so a
        // 64-key config never fires 66 requests at once.
        let semaphore = DispatchSemaphore(value: 6)
        for key in keys {
            group.enter()
            semaphore.wait()
            fetch("/api/v1/key", key: key) { json, err in
                if let json { results[key] = json }
                if let err { failures.append(err) }
                semaphore.signal()
                group.leave()
            }
        }

        // Resolve privilege from the response belonging to that exact key.
        // `/api/v1/credits` is account-level and may work with a regular key;
        // only `/api/v1/keys` requires the explicit management-key bit.
        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            guard self.refreshGeneration == generation else { return }
            let managementKey = results.first { _, json in
                (json["data"] as? [String: Any])?["is_management_key"] as? Bool == true
            }?.key
            self.state.isManagementKey = managementKey != nil
            let creditsKey = Self.accountCreditsKey(keys: keys, results: results)
            let accountGroup = DispatchGroup()

            if let creditsKey {
                accountGroup.enter()
                self.fetch("/api/v1/credits", key: creditsKey) { json, err in
                    guard self.refreshGeneration == generation else { accountGroup.leave(); return }
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
                        failures.append("Account credits response missing data")
                    }
                    accountGroup.leave()
                }
            }

            if let managementKey {
                accountGroup.enter()
                self.fetch("/api/v1/keys", key: managementKey) { json, err in
                    guard self.refreshGeneration == generation else { accountGroup.leave(); return }
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
                        failures.append("Management key response missing data")
                    }
                    accountGroup.leave()
                }
            }

            // Finish only after the optional account and management calls have
            // completed. 401/403 from either optional endpoint is informational.
            accountGroup.notify(queue: .main) { [weak self] in
                guard let self else { return }
                guard self.refreshGeneration == generation else { return }
                self.finishRefresh(results: results, failures: failures)
            }
        }
    }

    /// Aggregates the /api/v1/key results into state (admin fields were
    /// already populated by the credits/keys calls, if any).
    private func finishRefresh(results: [String: [String: Any]], failures: [String]) {
        refreshInFlight = false
        // Backoff (S2): total failure or explicit 429/5xx backs off the next
        // batch; partial success resets so transient single-key errors don't
        // stall the account view.
        let rateLimited = failures.contains { $0.contains("429") || $0.contains("HTTP 5") }
        if results.isEmpty || rateLimited {
            applyBackoff()
        } else {
            backoffBase = 0
        }
        state.isLoading = false
        if results.isEmpty {
            state.error = failures.first ?? "Query failed"
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
            f.append("\(invalidKeyResponses) key response(s) missing usage data")
            state.error = f.isEmpty ? nil : "Partial fetch failed: \(f.prefix(2).joined(separator: ", "))"
        } else {
            state.error = failures.isEmpty ? nil : "Partial fetch failed: \(failures.prefix(2).joined(separator: ", "))"
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

    /// Exponential backoff: 60s → 2m → 5m → 15m, capped. The next refresh()
    /// is skipped until the window elapses; the 60s timer picks up after.
    private func applyBackoff() {
        let now = ProcessInfo.processInfo.systemUptime
        backoffBase = min(max(backoffBase, 60), 15 * 60)
        nextAllowedRefresh = now + backoffBase
        backoffBase *= 2
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
        // DB write off the main actor: the shared lock may be held by the
        // collector or the hourly prune (M4).
        DispatchQueue.global(qos: .utility).async {
            Database.shared.insertORSnapshot(snap)
        }
    }

    private func fetch(_ path: String, key: String,
                       completion: @escaping ([String: Any]?, String?) -> Void) {
        guard let url = URL(string: "https://openrouter.ai\(path)") else {
            completion(nil, "Invalid URL")
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        redirectBlocker.boundedDataTask(in: session, request: req,
                                        maxBytes: 10_000_000) { data, resp, err in
            if let err {
                DispatchQueue.main.async { completion(nil, err.localizedDescription) }
                return
            }
            guard let http = resp as? HTTPURLResponse else {
                DispatchQueue.main.async { completion(nil, "No HTTP response") }
                return
            }
            if (300..<400).contains(http.statusCode) {
                DispatchQueue.main.async { completion(nil, "Redirect rejected (HTTP \(http.statusCode))") }
                return
            }
            if http.statusCode == 401 {
                DispatchQueue.main.async { completion(nil, "Invalid or unauthorized key (401)") }
                return
            }
            if http.statusCode == 403 {
                DispatchQueue.main.async { completion(nil, "Insufficient permission (403) — this key cannot query") }
                return
            }
            if http.statusCode == 429 {
                DispatchQueue.main.async { completion(nil, "Too many requests (429)") }
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                DispatchQueue.main.async { completion(nil, "HTTP \(http.statusCode)") }
                return
            }
            // Reject oversized responses from the header before buffering.
            if http.expectedContentLength > 10_000_000 {
                DispatchQueue.main.async { completion(nil, "Response too large (>10MB)") }
                return
            }
            if let mime = http.mimeType,
               !mime.contains("json") && !mime.contains("text") {
                DispatchQueue.main.async { completion(nil, "Non-JSON response (\(mime))") }
                return
            }
            guard let data, data.count < 10_000_000,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                DispatchQueue.main.async { completion(nil, "Failed to parse response or too large") }
                return
            }
            DispatchQueue.main.async { completion(obj, nil) }
        }.resume()
    }
}
