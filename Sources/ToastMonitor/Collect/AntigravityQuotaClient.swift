import Foundation
import Combine

/// Antigravity (Google AI Pro / Ultra) model quota, read from the language
/// server that Antigravity — standalone or inside Gemini.app — runs on this
/// Mac. The server writes a discovery file to
/// ~/.gemini/antigravity/daemon/hub_<port>.json with its loopback HTTP port
/// and a CSRF token. ToastMonitor POSTs two of its RPCs there:
/// `RetrieveUserQuotaSummary` for the quota and `GetUserStatus` for the plan.
///
/// EXPERIMENTAL: this is the app's own local API, not a documented one.
/// Nothing leaves the Mac, and the token is held in memory only for the
/// request. When Antigravity isn't running there is no server to ask, so the
/// last reading stays on screen with its age.
///
/// The summary lists model groups (today: Gemini, Claude and GPT, Argon), each
/// with a five-hour and/or a weekly bucket. When it is unavailable, the
/// per-model quota in GetUserStatus is the fallback: it shows one bucket per
/// model, and models in one group report the exact same remaining fraction
/// and reset time, so readings are grouped on that pair.
@MainActor
final class AntigravityQuotaClient: ObservableObject {
    static let shared = AntigravityQuotaClient()
    nonisolated static let maxResponseBytes = 10_000_000
    nonisolated static let statusPath = "/exa.language_server_pb.LanguageServerService/GetUserStatus"
    nonisolated static let summaryPath = "/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary"
    nonisolated static let enabledSettingKey = "antigravity_quota_enabled"
    nonisolated static let notRunning = "Antigravity isn't running"

    /// One limit of one model group. `remaining` is 0…100; `name` is the
    /// group ("Gemini", "Argon", "Others"); `window` is "5h" or "Weekly".
    struct ModelQuota: Equatable {
        var name: String
        var families: [String] = []
        let remaining: Double
        let resetAt: Int64?
        var window: String? = nil
        var windowSeconds: Int64? = nil

        var label: String { window.map { "\(name) \($0)" } ?? name }
    }

    struct Snapshot: Equatable {
        var planName: String?
        var models: [ModelQuota] = []
    }

    struct State {
        var configured = false
        var planName: String?
        var models: [ModelQuota] = []
        var lastSync: Int64 = 0
        var error: String?
        var isLoading = false

        /// The tightest pool: lowest remaining, earliest reset on a tie.
        var tightest: ModelQuota? {
            models.min { ($0.remaining, $0.resetAt ?? .max) < ($1.remaining, $1.resetAt ?? .max) }
        }
    }

    struct Hub: Equatable {
        let pid: Int32
        let httpPort: Int
        let csrfToken: String
    }

    @Published private(set) var state = State()
    @Published private(set) var enabled = false

    func showDemo(_ demo: State) {
        isDemo = true
        state = demo
    }
    private var isDemo = false
    private var started = false
    private var loadedPreference = false
    private var inFlight = false
    private var refreshGeneration: UInt64 = 0
    private var backoff = RefreshBackoff()
    private let poller = ForegroundPoller()
    private let session: URLSession
    private let redirectBlocker = NoRedirectDelegate()

    private init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 10
        cfg.timeoutIntervalForResource = 20
        cfg.connectionProxyDictionary = [:] // loopback only; never through a proxy
        session = URLSession(configuration: cfg, delegate: redirectBlocker, delegateQueue: nil)
    }

    /// On by default: the source is a local server and nothing is sent anywhere.
    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        loadedPreference = true
        DispatchQueue.global(qos: .utility).async {
            _ = Database.shared.setSetting(Self.enabledSettingKey, on ? nil : "0")
        }
        started = false
        if on {
            start()
        } else {
            poller.stop()
            refreshGeneration &+= 1
            inFlight = false
        }
    }

    func start() {
        if !loadedPreference {
            enabled = Database.shared.setting(Self.enabledSettingKey) != "0"
            loadedPreference = true
        }
        guard enabled, !started else { return }
        started = true
        refresh()
        poller.start { [weak self] in MainActor.assumeIsolated { self?.refresh() } }
    }

    func refresh() {
        guard enabled, !inFlight, !isDemo else { return }
        if backoff.isWaiting { return }
        inFlight = true
        refreshGeneration &+= 1
        let generation = refreshGeneration
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let hub = Self.findHub()
            Task { @MainActor [weak self] in
                guard let self, self.refreshGeneration == generation else { return }
                guard let hub else {
                    self.inFlight = false
                    self.state.isLoading = false
                    self.state.configured = Self.isInstalled()
                    self.state.error = self.state.configured ? Self.notRunning : nil
                    return
                }
                self.state.configured = true
                self.request(hub: hub, generation: generation)
            }
        }
    }

    // MARK: - Discovery

    nonisolated static func appDataDir(env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let custom = env["GEMINI_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
                .appendingPathComponent("antigravity")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/antigravity")
    }

    /// Antigravity has run on this Mac at least once.
    nonisolated static func isInstalled() -> Bool {
        FileManager.default.fileExists(atPath: appDataDir().path)
    }

    /// The newest discovery file whose server process is still alive. A
    /// crashed server leaves its file behind, so the pid is checked.
    nonisolated static func findHub() -> Hub? {
        let dir = appDataDir().appendingPathComponent("daemon")
        guard let names = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        let candidates = names
            .filter { $0.lastPathComponent.hasPrefix("hub_") && $0.pathExtension == "json" }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a > b
            }
        for url in candidates {
            guard let data = try? Data(contentsOf: url), data.count <= 64_000,
                  let hub = parseHub(data), kill(hub.pid, 0) == 0 || errno == EPERM else { continue }
            return hub
        }
        return nil
    }

    nonisolated static func parseHub(_ data: Data) -> Hub? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = (root["pid"] as? NSNumber)?.int32Value, pid > 0,
              let port = (root["httpPort"] as? NSNumber)?.intValue, (1...65535).contains(port),
              let token = (root["csrfToken"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty, token.count <= 256,
              token.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        return Hub(pid: pid, httpPort: port, csrfToken: token)
    }

    // MARK: - Request

    private func request(hub: Hub, generation: UInt64) {
        state.isLoading = true
        func makeRequest(_ path: String) -> URLRequest? {
            var components = URLComponents()
            components.scheme = "http"
            components.host = "127.0.0.1"
            components.port = hub.httpPort
            components.path = path
            guard let url = components.url else { return nil }
            var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
            req.setValue(hub.csrfToken, forHTTPHeaderField: "X-Codeium-Csrf-Token")
            req.httpBody = Data(#"{"metadata":{"ideName":"antigravity","extensionName":"antigravity","locale":"en"}}"#.utf8)
            return req
        }
        guard let statusRequest = makeRequest(Self.statusPath),
              let summaryRequest = makeRequest(Self.summaryPath) else {
            inFlight = false
            return
        }

        let group = DispatchGroup()
        var statusResult: Result<Data, CommandCodeQuotaClient.HTTPError>?
        var summaryData: Data?
        group.enter()
        let statusTask = redirectBlocker.boundedDataTask(in: session, request: statusRequest,
                                                         maxBytes: Self.maxResponseBytes) { data, resp, err in
            statusResult = CommandCodeQuotaClient.validate(data: data, response: resp, error: err)
            group.leave()
        }
        // The summary is preferred but optional: older servers lack it.
        group.enter()
        let summaryTask = redirectBlocker.boundedDataTask(in: session, request: summaryRequest,
                                                          maxBytes: Self.maxResponseBytes) { data, resp, err in
            if case .success(let data) = CommandCodeQuotaClient.validate(data: data, response: resp, error: err) {
                summaryData = data
            }
            group.leave()
        }
        statusTask.resume()
        summaryTask.resume()

        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            self.inFlight = false
            guard self.refreshGeneration == generation else { return }
            self.state.isLoading = false
            switch statusResult {
            case .success(let data)?:
                guard var snapshot = Self.parseUserStatus(data) else {
                    self.state.error = "Failed to parse Antigravity status"
                    self.backoff.failed()
                    return
                }
                if let buckets = summaryData.flatMap(Self.parseQuotaSummary), !buckets.isEmpty {
                    snapshot.models = buckets
                }
                self.apply(snapshot)
            case .failure(.transport)?:
                // The server exited between discovery and the request.
                self.state.error = Self.notRunning
            case .failure(let error)?:
                self.state.error = Self.message(for: error)
                self.backoff.failed()
            case nil:
                self.state.error = "Antigravity status request failed"
                self.backoff.failed()
            }
        }
    }

    private func apply(_ snapshot: Snapshot) {
        state.planName = snapshot.planName ?? state.planName
        state.models = snapshot.models
        state.lastSync = Int64(Date().timeIntervalSince1970)
        state.error = nil
        backoff.succeeded()
    }

    nonisolated static func message(for error: CommandCodeQuotaClient.HTTPError) -> String {
        switch error {
        case .transport(let message): return message
        case .redirect(let code): return "Redirect rejected (HTTP \(code))"
        case .status(let code): return "Antigravity status HTTP \(code)"
        case .parse: return "Failed to parse Antigravity status"
        case .tooLarge: return "Antigravity status response too large"
        }
    }

    // MARK: - Parsing

    /// `userStatus.cascadeModelConfigData.clientModelConfigs[].quotaInfo`
    /// gives `remainingFraction` (0…1) and `resetTime` per model; proto3 JSON
    /// omits a zero fraction, so a reset time without one means exhausted.
    /// Models without quotaInfo are unmetered and skipped.
    nonisolated static func parseUserStatus(_ data: Data) -> Snapshot? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = root["userStatus"] as? [String: Any] else { return nil }
        var snapshot = Snapshot()
        snapshot.planName = planName(status)
        let configs = (status["cascadeModelConfigData"] as? [String: Any])?["clientModelConfigs"]
            as? [[String: Any]] ?? []
        var order: [String] = []
        var byFamily: [String: ModelQuota] = [:]
        for config in configs {
            guard let label = config["label"] as? String,
                  let quota = config["quotaInfo"] as? [String: Any], !quota.isEmpty else { continue }
            let family = Self.family(of: label)
            guard !family.isEmpty, family.count <= 64,
                  family.rangeOfCharacter(from: .controlCharacters) == nil else { continue }
            let reset = (quota["resetTime"] as? String).flatMap(GrokQuotaClient.isoDate)
            let fraction: Double
            if let n = quota["remainingFraction"] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
               n.doubleValue.isFinite {
                fraction = n.doubleValue
            } else if reset != nil {
                fraction = 0
            } else {
                continue
            }
            let reading = ModelQuota(name: family,
                                     remaining: min(max(fraction * 100, 0), 100),
                                     resetAt: reset.map { Int64($0.timeIntervalSince1970) })
            if let existing = byFamily[family] {
                // Variants share a pool; keep the most conservative reading.
                if reading.remaining < existing.remaining { byFamily[family] = reading }
            } else {
                order.append(family)
                byFamily[family] = reading
            }
        }
        snapshot.models = pools(order.compactMap { byFamily[$0] })
        guard snapshot.planName != nil || !snapshot.models.isEmpty else { return nil }
        return snapshot
    }

    /// `response.groups[].buckets[]`: each bucket has `window` ("5h" or
    /// "weekly"), `remainingFraction` (omitted when zero) and `resetTime`.
    /// A group's models are listed in its description; the group is named
    /// from them like the fallback pools.
    nonisolated static func parseQuotaSummary(_ data: Data) -> [ModelQuota]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let groups = (root["response"] as? [String: Any])?["groups"] as? [[String: Any]] else { return nil }
        var out: [ModelQuota] = []
        for group in groups {
            let display = (group["displayName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            var families = memberFamilies(group["description"] as? String)
            if families.isEmpty, !display.isEmpty { families = [display] }
            guard !families.isEmpty else { continue }
            let name = poolName(families)
            var buckets: [ModelQuota] = []
            for bucket in group["buckets"] as? [[String: Any]] ?? [] {
                let reset = (bucket["resetTime"] as? String).flatMap(GrokQuotaClient.isoDate)
                let fraction: Double
                if let n = bucket["remainingFraction"] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                   n.doubleValue.isFinite {
                    fraction = n.doubleValue
                } else if reset != nil {
                    fraction = 0
                } else {
                    continue
                }
                let (window, seconds): (String?, Int64?) = {
                    switch (bucket["window"] as? String)?.lowercased() {
                    case "5h": return ("5h", 5 * 3600)
                    case "weekly": return ("Weekly", 7 * 86400)
                    default: return (nil, nil)
                    }
                }()
                buckets.append(ModelQuota(name: name, families: families,
                                          remaining: min(max(fraction * 100, 0), 100),
                                          resetAt: reset.map { Int64($0.timeIntervalSince1970) },
                                          window: window, windowSeconds: seconds))
            }
            // Shorter window first, as Claude's 5h then Weekly.
            out += buckets.sorted { ($0.windowSeconds ?? .max) < ($1.windowSeconds ?? .max) }
        }
        return out
    }

    /// "Models within this group: Gemini 4 Neon, Gemini 4 Hydrogen" → the names.
    nonisolated static func memberFamilies(_ description: String?) -> [String] {
        guard let description, let colon = description.range(of: "group:") else { return [] }
        // The list ends at a sentence break; "3.8" has no space after its dot.
        var list = String(description[colon.upperBound...])
        if let end = list.range(of: ". ") { list = String(list[..<end.lowerBound]) }
        if list.hasSuffix(".") { list.removeLast() }
        return list.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count <= 64 && $0.rangeOfCharacter(from: .controlCharacters) == nil }
    }

    /// Families with the same remaining fraction and reset time are one pool,
    /// in first-seen order.
    nonisolated static func pools(_ families: [ModelQuota]) -> [ModelQuota] {
        var order: [String] = []
        var members: [String: [ModelQuota]] = [:]
        for quota in families {
            let key = "\(quota.remaining)|\(quota.resetAt.map(String.init) ?? "-")"
            if members[key] == nil { order.append(key) }
            members[key, default: []].append(quota)
        }
        let pools: [ModelQuota] = order.compactMap { key in
            guard let group = members[key], let first = group.first else { return nil }
            let names = group.map(\.name)
            return ModelQuota(name: poolName(names), families: names,
                              remaining: first.remaining, resetAt: first.resetAt)
        }
        // Two pools must never share a label; fall back to brand names.
        let labels = pools.map(\.name)
        return pools.map { pool in
            guard labels.filter({ $0 == pool.name }).count > 1 else { return pool }
            var renamed = pool
            renamed.name = brands(pool.families).joined(separator: " · ")
            return renamed
        }
    }

    /// Short labels: a lone Gemini model by its codename ("Argon", "Flash"),
    /// several Gemini models as "Gemini", and a pool without Gemini as "Others".
    nonisolated static func poolName(_ families: [String]) -> String {
        let gemini = families.filter { $0.hasPrefix("Gemini") }
        if gemini.isEmpty { return families.isEmpty ? "" : "Others" }
        guard families.count == 1, let only = families.first else { return "Gemini" }
        // "Gemini 4 Argon" → "Argon": drop the brand and its version.
        let words = only.split(separator: " ").dropFirst().drop { $0.first?.isNumber == true }
        return words.isEmpty ? only : words.joined(separator: " ")
    }

    private nonisolated static func brands(_ families: [String]) -> [String] {
        var out: [String] = []
        for family in families {
            let brand = family.split(separator: " ").first.map(String.init) ?? family
            if !out.contains(brand) { out.append(brand) }
        }
        return out
    }

    /// "Claude Opus 5.5 (High)" → "Claude Opus 5.5".
    nonisolated static func family(of label: String) -> String {
        var name = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.hasSuffix(")"), let open = name.lastIndex(of: "(") {
            name = String(name[..<open]).trimmingCharacters(in: .whitespaces)
        }
        return name
    }

    /// `userTier.name` ("Google AI Pro"), else `planInfo.planName`.
    nonisolated static func planName(_ status: [String: Any]) -> String? {
        let tier = (status["userTier"] as? [String: Any])?["name"] as? String
        let plan = ((status["planStatus"] as? [String: Any])?["planInfo"] as? [String: Any])?["planName"] as? String
        for raw in [tier, plan] {
            if let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty,
               value.count <= 64, value.rangeOfCharacter(from: .controlCharacters) == nil {
                return value
            }
        }
        return nil
    }

    /// A subscription recorded with plan "google" names the row over the API tier.
    nonisolated static func plan(subscriptions: [Database.Subscription], apiPlan: String?,
                                 now: Date = Date()) -> String? {
        let nowSeconds = Int64(now.timeIntervalSince1970)
        return subscriptions.first { $0.plan == "google" && ($0.endDate == 0 || $0.endDate > nowSeconds) }?.name
            ?? apiPlan
    }

    /// Window length implied by the time to reset: Antigravity pools refill
    /// every five hours or every week.
    nonisolated static func windowSeconds(resetAt: Int64?, now: Int64) -> Int64? {
        guard let resetAt, resetAt > now else { return nil }
        return resetAt - now <= 5 * 3600 ? 5 * 3600 : 7 * 86400
    }
}
