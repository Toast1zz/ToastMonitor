import Foundation
import Combine
import CryptoKit

/// Remote usage collector: pulls the usage feed exported by the VPS
/// (cron exporter over a user-configured HTTPS or private-network feed)
/// and imports turns for every tool whose source is set to "remote".
///
/// Row semantics per tool (produced by tm-export.py):
///  - hermes:   aggregate per (session, model) — delta-tracked locally
///  - opencode: cumulative per session — delta via session_totals
///  - claude:   per-turn events (real ts) — direct insert
///  - codex:    per-turn events (real ts) — direct insert
///
/// Incremental via a per-tool watermark (max ts already imported).
final class HermesRemoteClient: ObservableObject {
    static let shared = HermesRemoteClient()
    static let replayLookback: Int64 = 300
    static let maxFeedURLLength = 2_048
    static let maxFeedRows = 50_000
    static let maxFieldLength = 512
    static let maxProviderLength = 256
    static func isWithinReplayWindow(timestamp: Int64, cursorTimestamp: Int64) -> Bool {
        timestamp >= max(cursorTimestamp - replayLookback, 0)
    }

    struct SyncStatus {
        var lastSync: Int64 = 0
        var lastRows: Int = 0
        var error: String?
    }

    @Published private(set) var status = SyncStatus()

    private let queue = DispatchQueue(label: "toastmonitor.remote", qos: .utility)
    private var lastPoll: Int64 = 0
    private var timer: Timer?
    private var inFlight = false
    private var started = false

    private init() {
        observeForeground()
    }

    private var popoverVisible = false
    private var dashboardVisible = false
    private var foreground = false

    private func updateForeground() {
        let fg = popoverVisible || dashboardVisible
        guard fg != foreground else { return }
        foreground = fg
        if fg {
            startTimer()
            queue.async { [weak self] in self?.poll() }
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

    /// Remote ingestion is opt-in. A local Mac installation therefore stays
    /// fully usable without a Tailscale/VPS connection.
    private var remoteSourcesEnabled: Bool {
        ToolKind.allCases.contains { $0 != .openrouter && $0.sourceIsRemote }
    }

    var feedURL: String {
        Database.shared.setting("remote_feed_url") ?? ""
    }

    @discardableResult
    func provision(url: String?) -> Bool {
        guard let raw = url?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              raw.count <= Self.maxFeedURLLength,
              raw.rangeOfCharacter(from: .controlCharacters) == nil,
              let parsed = URL(string: raw),
              parsed.user == nil,
              parsed.password == nil,
              Self.isAllowedFeedURL(parsed) else { return false }
        return Database.shared.setSetting("remote_feed_url", parsed.absoluteString)
    }

    func start() {
        guard !started else { return }
        started = true
        updateForeground()
    }

    private func startTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Called from the collector loop; rate-limited internally (60s).
    func maybePoll() {
        guard remoteSourcesEnabled else { return }
        queue.async { [weak self] in
            guard let self else { return }
            let now = Int64(Date().timeIntervalSince1970)
            guard now - self.lastPoll > 13 else { return }
            self.poll()
        }
    }

    static func isAllowedFeedURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              url.user == nil,
              url.password == nil else { return false }
        if scheme == "https" { return true }
        guard scheme == "http", let host = url.host else { return false }
        // Tailscale CGNAT range 100.64.0.0/10, private ranges, localhost.
        if let ip = IPv4Address(host) {
            if ip.isTailscale || ip.isPrivate || ip.isLoopback { return true }
            return false
        }
        return host == "localhost"
    }

    private static func validField(_ value: Any?, maxLength: Int,
                                   allowEmpty: Bool = true) -> Bool {
        guard let value else { return true }
        guard let string = value as? String,
              (allowEmpty || !string.isEmpty),
              string.count <= maxLength,
              string.rangeOfCharacter(from: .controlCharacters) == nil else { return false }
        return true
    }

    private struct IPv4Address {
        let a: UInt8, b: UInt8, c: UInt8, d: UInt8
        init?(_ s: String) {
            let parts = s.split(separator: ".").compactMap { UInt8($0) }
            guard parts.count == 4 else { return nil }
            (a, b, c, d) = (parts[0], parts[1], parts[2], parts[3])
        }
        var isTailscale: Bool { a == 100 && b >= 64 && b <= 127 }
        var isPrivate: Bool {
            a == 10 || (a == 172 && b >= 16 && b <= 31) || (a == 192 && b == 168)
        }
        var isLoopback: Bool { a == 127 }
    }

    // MARK: - Poll

    func poll() {
        guard remoteSourcesEnabled else { return }
        guard !inFlight else { return }
        inFlight = true
        lastPoll = Int64(Date().timeIntervalSince1970)

        guard feedURL.count <= Self.maxFeedURLLength,
              feedURL.rangeOfCharacter(from: .controlCharacters) == nil,
              let url = URL(string: feedURL),
              Self.isAllowedFeedURL(url) else {
            inFlight = false
            publishStatus { $0.error = "feed URL 无效或不安全（仅允许 HTTPS 或私有网段）" }
            return
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
            guard let self else { return }
            self.queue.async {
                defer { self.inFlight = false }
                if let err {
                    self.publishStatus { $0.error = err.localizedDescription }
                    return
                }
                guard let http = resp as? HTTPURLResponse else {
                    self.publishStatus { $0.error = "无 HTTP 响应" }
                    return
                }
                // URLSession follows redirects; the allowlist checked above
                // covers only the initial URL, so re-check the final one.
                if !Self.isAllowedFeedURL(http.url ?? url) {
                    self.publishStatus { $0.error = "重定向到不允许的地址，已拒绝" }
                    return
                }
                // Reject oversized responses from the Content-Length header
                // before the body finishes buffering.
                if http.expectedContentLength > 10_000_000 {
                    self.publishStatus { $0.error = "响应过大 (>10MB)" }
                    return
                }
                guard http.statusCode == 200 else {
                    self.publishStatus { $0.error = "HTTP \(http.statusCode)" }
                    return
                }
                guard let data, data.count <= 10_000_000 else {
                    self.publishStatus { $0.error = "响应过大 (>10MB)" }
                    return
                }
                if let mime = http.mimeType, !mime.contains("json") {
                    self.publishStatus { $0.error = "非 JSON 响应 (\(mime))" }
                    return
                }
                guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    self.publishStatus { $0.error = "响应解析失败" }
                    return
                }
                self.importFeed(obj)
            }
        }.resume()
    }

    private func publishStatus(_ update: @escaping (inout SyncStatus) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            update(&self.status)
        }
    }

    private func importFeed(_ result: [String: Any]) {
        guard let rows = result["rows"] as? [[String: Any]],
              rows.count <= Self.maxFeedRows else {
            publishStatus { $0.error = "feed 格式异常或行数过多" }
            return
        }
        if let schema = result["schema"] as? Int, schema > 1 {
            publishStatus { $0.error = "feed schema v\(schema) 不受支持" }
            return
        }
        let sourceDigest = SHA256.hash(data: Data(feedURL.utf8))
            .prefix(8).map { String(format: "%02x", $0) }.joined()
        let sourceInstance = "remote:\(sourceDigest)"

        // Per-tool cursors (timestamp + stable tie-breaker): switching a
        // source to remote never reuses another tool's cursor, and two rows
        // with the same second are both importable.
        struct Cursor {
            var ts: Int64
            var eventID: String
        }
        func cursor(_ tool: ToolKind) -> Cursor {
            let raw = Database.shared.setting("remote_watermark_\(tool.rawValue)") ?? "0"
            guard let separator = raw.firstIndex(of: ":"),
                  let ts = Int64(raw[..<separator]) else {
                return Cursor(ts: Int64(raw) ?? 0, eventID: "")
            }
            return Cursor(ts: ts, eventID: String(raw[raw.index(after: separator)...]))
        }

        var turns: [TurnRecord] = []
        var sessions: [String: SessionInfo] = [:]
        var pendingHermesBaselines: [(key: String, value: String)] = []
        var pendingOpenCodeTotals: [(key: String, input: Int64, output: Int64, reasoning: Int64, cacheRead: Int64, cacheWrite: Int64, cost: Double, updated: Int64)] = []
        var pendingWatermarks: [ToolKind: Cursor] = [:]
        var seenRemoteTools: Set<String> = []
        var unknownTools = 0
        var malformedRows = 0
        let totals = Database.shared.sessionTotals() // once per poll
        // Running baselines within this poll: two rows sharing a delta key
        // must compute against the previous row's write, not the stale
        // committed value, or the cumulative delta is inserted twice.
        var runningHermes: [String: [Int64]] = [:]
        var runningOpenCode: [String: (tool: String, input: Int64, output: Int64, reasoning: Int64, cacheRead: Int64, cacheWrite: Int64, cost: Double)] = [:]
        let nowTs = Int64(Date().timeIntervalSince1970)
        // Feed rows outside this window are rejected (a future-dated row
        // would poison the monotonic watermark and blind per-turn tools).
        let tsLower = nowTs - 10 * 366 * 86400
        let tsUpper = nowTs + 24 * 3600

        for row in rows {
            // Unknown tools are rejected, never silently treated as Hermes.
            guard let tool = ToolKind(rawValue: row["tool"] as? String ?? "") else {
                unknownTools += 1
                continue
            }
            guard tool.sourceIsRemote else { continue }
            seenRemoteTools.insert(tool.rawValue)
            guard let rawSession = row["session_id"] as? String,
                  !rawSession.isEmpty, rawSession.count <= Self.maxFieldLength,
                  rawSession.rangeOfCharacter(from: .controlCharacters) == nil else {
                malformedRows += 1
                continue
            }
            guard Self.validField(row["model"], maxLength: Self.maxFieldLength),
                  Self.validField(row["title"], maxLength: Self.maxFieldLength),
                  Self.validField(row["project"], maxLength: Self.maxFieldLength),
                  Self.validField(row["billing_provider"], maxLength: Self.maxProviderLength),
                  Self.validField(row["provider"], maxLength: Self.maxProviderLength),
                  Self.validField(row["billing_base_url"], maxLength: Self.maxFieldLength),
                  Self.validField(row["event_id"], maxLength: Self.maxFieldLength) else {
                malformedRows += 1
                continue
            }
            let sessionID = rawSession
            guard let rawLast = (row["last_seen"] as? NSNumber)?.doubleValue,
                  rawLast.isFinite, rawLast >= 0, rawLast <= 4_000_000_000_000 else {
                malformedRows += 1
                continue
            }
            let lastSeenS = Int64(rawLast > 1_000_000_000_000 ? rawLast / 1000 : rawLast)
            guard lastSeenS >= tsLower && lastSeenS <= tsUpper else {
                malformedRows += 1
                continue
            }
            let rawFirst = (row["first_seen"] as? NSNumber)?.doubleValue ?? Double(lastSeenS)
            guard rawFirst.isFinite, rawFirst >= 0, rawFirst <= 4_000_000_000_000 else {
                malformedRows += 1
                continue
            }
            let normalizedFirst = Int64(rawFirst > 1_000_000_000_000 ? rawFirst / 1000 : rawFirst)
            let firstSeenS = min(max(normalizedFirst, tsLower), min(lastSeenS, nowTs))
            let model = row["model"] as? String
            // All token values are non-negative and capped before arithmetic;
            // malformed numbers become zero instead of overflowing Int64 sums.
            func count(_ key: String) -> Int64 {
                guard let n = row[key] as? NSNumber else { return 0 }
                let d = n.doubleValue
                guard d.isFinite else { return 0 }
                return Int64(min(max(d, 0), 9_000_000_000_000_000))
            }
            let input = count("input_tokens")
            let output = count("output_tokens")
            let reasoning = count("reasoning_tokens")
            let cacheRead = count("cache_read_tokens")
            let cacheWrite = count("cache_write_tokens")
            let rawCost = (row["cost_usd"] as? NSNumber)?.doubleValue ?? 0
            let cost = rawCost.isFinite ? min(max(rawCost, 0), 1_000_000_000) : 0
            let title = row["title"] as? String
            let project = row["project"] as? String

            var dInput = input
            var dReasoning = reasoning
            var dOutput = output
            var dCacheRead = cacheRead
            var dCacheWrite = cacheWrite
            var dCost = cost
            var costQuality = "estimated"
            let rawEventID = row["event_id"] as? String ?? ""
            let eventID = rawEventID.isEmpty
                ? Self.fallbackEventID(row: row, tool: tool, sessionID: sessionID,
                                       lastSeen: lastSeenS, firstSeen: firstSeenS)
                : rawEventID
            let previousCursor = cursor(tool)
            // Watermark guard applies only to per-turn tools. Hermes/OpenCode
            // rows are cumulative baselines: their deltas are idempotent via
            // session_totals/baseline settings, and a ts+content-hash cursor
            // would permanently skip never-imported keys (e.g. a fresh
            // (session, model, provider) route-change row with lastSeen at or
            // below the watermark).
            switch tool {
            case .hermes, .opencode:
                break
            default:
                // Replay a bounded tail on every poll. Event ids make this
                // idempotent, while the overlap admits rows that arrived a few
                // minutes late behind the producer's current watermark.
                guard Self.isWithinReplayWindow(timestamp: lastSeenS,
                                                cursorTimestamp: previousCursor.ts) else { continue }
            }
            var isFirstRow = false // 首行 = 该 session 的累计基线 → 归 firstSeen 日期

            switch tool {
            case .hermes:
                // Hermes traffic bills through the underlying plans
                // (opencode-go 套餐 / OpenRouter 余额 / Codex 订阅) — tokens
                // only, never cost here.
                // Delta key is per (session, model, billing route): one
                // cumulative row per (provider, base_url) combo — sharing a
                // key lets later small rows clobber the baseline. base_url is
                // normalized (trailing slash) because Hermes flips the slash
                // on route changes, which would otherwise open a fresh row
                // carrying the FULL cumulative value (double counting).
                let provider = row["billing_provider"] as? String ?? ""
                let baseURL = ((row["billing_base_url"] as? String) ?? "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                let key = "hm_d|\(sessionID)|\(model ?? "")|\(provider)|\(baseURL)"
                let prev = runningHermes[key]
                    ?? (Database.shared.setting(key) ?? "").split(separator: ",").map { Int64($0) ?? 0 }
                isFirstRow = prev.count != 5 && prev.count != 6
                if prev.count == 6 {
                    dInput = max(input - prev[0], 0)
                    dOutput = max(output - prev[1], 0)
                    dReasoning = max(reasoning - prev[2], 0)
                    dCacheRead = max(cacheRead - prev[3], 0)
                    dCacheWrite = max(cacheWrite - prev[4], 0)
                } else if prev.count == 5 {
                    // Legacy baseline stored input+reasoning together. Claim it
                    // without replaying historical reasoning as a new delta.
                    dInput = max(input + reasoning - prev[0], 0)
                    dOutput = max(output - prev[1], 0)
                    dReasoning = 0
                    dCacheRead = max(cacheRead - prev[2], 0)
                    dCacheWrite = max(cacheWrite - prev[3], 0)
                }
                let safeBase: [Int64]
                if prev.count == 6 {
                    safeBase = [max(input, prev[0]), max(output, prev[1]),
                                max(reasoning, prev[2]), max(cacheRead, prev[3]),
                                max(cacheWrite, prev[4]), 0]
                } else {
                    safeBase = [input, output, reasoning, cacheRead, cacheWrite, 0]
                }
                runningHermes[key] = safeBase
                pendingHermesBaselines.append((key, safeBase.map(String.init).joined(separator: ",")))
                dCost = 0
                costQuality = "unknown"
            case .opencode:
                let totalsKey = "opencode|\(sessionID)"
                let prev = runningOpenCode[totalsKey] ?? totals[totalsKey]
                isFirstRow = prev == nil
                var legacyCombinedInput = false
                if let prev {
                    legacyCombinedInput = prev.reasoning == 0
                        && reasoning > 0 && prev.input == input + reasoning
                    dInput = max((legacyCombinedInput ? input + reasoning : input) - prev.input, 0)
                    dOutput = max(output - prev.output, 0)
                    dReasoning = legacyCombinedInput ? 0 : max(reasoning - prev.reasoning, 0)
                    dCacheRead = max(cacheRead - prev.cacheRead, 0)
                    dCacheWrite = max(cacheWrite - prev.cacheWrite, 0)
                    dCost = max(cost - prev.cost, 0)
                }
                let safeInput = legacyCombinedInput ? input : (prev.map { max(input, $0.input) } ?? input)
                let safeOutput = prev.map { max(output, $0.output) } ?? output
                let safeReasoning = legacyCombinedInput ? reasoning : (prev.map { max(reasoning, $0.reasoning) } ?? reasoning)
                let safeRead = prev.map { max(cacheRead, $0.cacheRead) } ?? cacheRead
                let safeWrite = prev.map { max(cacheWrite, $0.cacheWrite) } ?? cacheWrite
                let safeCost = prev.map { max(cost, $0.cost) } ?? cost
                runningOpenCode[totalsKey] = ("opencode", safeInput, safeOutput, safeReasoning,
                                              safeRead, safeWrite, safeCost)
                pendingOpenCodeTotals.append((totalsKey, safeInput, safeOutput, safeReasoning,
                                              safeRead, safeWrite, safeCost, lastSeenS))
                costQuality = "actual"
            default:
                break // per-turn events: insert as-is
            }

            if dInput > 0 || dOutput > 0 || dReasoning > 0 || dCacheRead > 0 || dCacheWrite > 0 {
                // First-seen rows are cumulative baselines: attribute them to
                // the session's start date, not "now" (spec: 历史累计不得归入今天).
                let ts = (isFirstRow && firstSeenS > 0) ? firstSeenS : lastSeenS
                let provider = (row["billing_provider"] as? String)
                    ?? (row["provider"] as? String)
                turns.append(TurnRecord(tool: tool, sessionID: sessionID, project: project,
                                        model: model, ts: ts,
                                        inputTokens: dInput, outputTokens: dOutput,
                                        reasoningTokens: dReasoning,
                                        cacheRead: dCacheRead, cacheWrite: dCacheWrite, cost: dCost,
                                        provider: provider, sourceInstance: sourceInstance,
                                        eventID: eventID, costQuality: costQuality))
            }
            sessions["\(tool.rawValue)|\(sessionID)"] = SessionInfo(tool: tool, sessionID: sessionID, title: title,
                                                                    project: project, model: model,
                                                                    created: firstSeenS,
                                                                    updated: lastSeenS)
            // Clamp the cursor to now: a future-dated row (within the +24h
            // acceptance window) must not advance the watermark past the
            // present, or it would blind per-turn import until the feed
            // catches up.
            let candidate = Cursor(ts: min(lastSeenS, nowTs), eventID: eventID)
            if let previous = pendingWatermarks[tool] {
                if candidate.ts > previous.ts || (candidate.ts == previous.ts && candidate.eventID > previous.eventID) {
                    pendingWatermarks[tool] = candidate
                }
            } else {
                pendingWatermarks[tool] = candidate
            }
        }

        // Atomic commit: turns + sessions + cumulative baselines + watermarks
        // are one unit. A failed write must leave the feed replayable.
        let ok = Database.shared.inTransaction {
            var writesOK = Database.shared.insertTurns(turns)
            writesOK = Database.shared.upsertSessions(Array(sessions.values)) && writesOK
            for p in pendingHermesBaselines {
                writesOK = Database.shared.setSetting(p.key, p.value) && writesOK
            }
            for p in pendingOpenCodeTotals {
                writesOK = Database.shared.setSessionTotals(p.key, tool: "opencode",
                                                            input: p.input, output: p.output,
                                                            reasoning: p.reasoning,
                                                            cacheRead: p.cacheRead, cacheWrite: p.cacheWrite,
                                                            cost: p.cost, updated: p.updated) && writesOK
            }
            for (tool, value) in pendingWatermarks {
                writesOK = Database.shared.setSetting("remote_watermark_\(tool.rawValue)", "\(value.ts):\(value.eventID)") && writesOK
            }
            return writesOK
        }
        guard ok else {
            publishStatus { $0.error = "导入事务失败，水位线未前进" }
            return
        }
        let ignoredRows = unknownTools + malformedRows
        let errorText = ignoredRows > 0 ? "\(ignoredRows) 行无效/未知记录已忽略" : nil
        let syncTime = Int64(Date().timeIntervalSince1970)
        publishStatus {
            $0.lastSync = syncTime
            $0.lastRows = turns.count
            $0.error = errorText
        }
        Task { @MainActor in
            for tool in seenRemoteTools {
                let imported = turns.reduce(0) { $0 + ($1.tool.rawValue == tool ? 1 : 0) }
                SourceHealthHub.shared.record(tool: tool, rows: imported, failed: 0,
                                              durationMs: 0, error: nil)
            }
            if let errorText {
                SourceHealthHub.shared.record(tool: "remote-feed", rows: turns.count,
                                              failed: ignoredRows, durationMs: 0, error: errorText)
            }
            // Remote import completes after the collector's local scan
            // notification. Publish the same refresh signal so the menu bar
            // and dashboard do not wait for the next 15-second snapshot tick.
            NotificationCenter.default.post(name: CollectorEngine.didCollect, object: nil)
        }
        if turns.count > 0 {
            NSLog("[ToastMonitor] remote feed: %d turns imported", turns.count)
        }
    }

    /// Feed rows without an upstream event_id still need a stable identity.
    /// Hashing the canonical JSON preserves distinct same-second rows while
    /// keeping the SQLite event_id compact and free of raw prompt content.
    private static func fallbackEventID(row: [String: Any], tool: ToolKind,
                                        sessionID: String, lastSeen: Int64,
                                        firstSeen: Int64) -> String {
        let digest: String
        if let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) {
            digest = SHA256.hash(data: data)
                .map { String(format: "%02x", $0) }
                .joined()
        } else {
            digest = "\(firstSeen):\(lastSeen)"
        }
        let full = "remote:\(tool.rawValue):\(sessionID):\(digest)"
        guard full.count <= Self.maxFieldLength else {
            let sessionDigest = SHA256.hash(data: Data(sessionID.utf8))
                .map { String(format: "%02x", $0) }
                .joined()
            return "remote:\(tool.rawValue):\(sessionDigest):\(digest)"
        }
        return full
    }
}
