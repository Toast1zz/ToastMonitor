import Foundation
import Combine
import CryptoKit

/// Remote usage collector: pulls the usage feed exported by the VPS
/// (cron tm-export.py → http://100.116.140.74/tm/usage.json over Tailscale)
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
        Database.shared.setting("remote_feed_url") ?? "http://100.116.140.74/tm/usage.json"
    }

    @discardableResult
    func provision(url: String?) -> Bool {
        guard let raw = url?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return Database.shared.setSetting("remote_feed_url", nil)
        }
        guard let parsed = URL(string: raw), Self.isAllowedFeedURL(parsed) else { return false }
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

    // MARK: - Feed security (P0-6)

    /// HTTPS always allowed; plain HTTP only for private/Tailscale ranges
    /// (the VPS feed runs on 100.116.140.74 over Tailscale).
    static func isAllowedFeedURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        if scheme == "https" { return true }
        guard scheme == "http", let host = url.host else { return false }
        // Tailscale CGNAT range 100.64.0.0/10, private ranges, localhost.
        if let ip = IPv4Address(host) {
            if ip.isTailscale || ip.isPrivate || ip.isLoopback { return true }
            return false
        }
        return host == "localhost"
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

        guard let url = URL(string: feedURL), Self.isAllowedFeedURL(url) else {
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
                guard let data else {
                    self.publishStatus { $0.error = "空响应" }
                    return
                }
                guard data.count < 10_000_000 else {
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
        guard let rows = result["rows"] as? [[String: Any]] else {
            publishStatus { $0.error = "feed 格式异常" }
            return
        }
        if let schema = result["schema"] as? Int, schema > 1 {
            publishStatus { $0.error = "feed schema v\(schema) 不受支持" }
            return
        }

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
        var pendingOpenCodeTotals: [(key: String, input: Int64, output: Int64, cacheRead: Int64, cacheWrite: Int64, cost: Double, updated: Int64)] = []
        var pendingWatermarks: [ToolKind: Cursor] = [:]
        var seenRemoteTools: Set<String> = []
        var unknownTools = 0
        var malformedRows = 0
        let totals = Database.shared.sessionTotals() // once per poll
        // Running baselines within this poll: two rows sharing a delta key
        // must compute against the previous row's write, not the stale
        // committed value, or the cumulative delta is inserted twice.
        var runningHermes: [String: [Int64]] = [:]
        var runningOpenCode: [String: (tool: String, input: Int64, output: Int64, cacheRead: Int64, cacheWrite: Int64, cost: Double)] = [:]
        let nowTs = Int64(Date().timeIntervalSince1970)
        // Feed rows outside this window are rejected (a future-dated row
        // would poison the monotonic watermark and blind per-turn tools).
        let tsLower = nowTs - 10 * 366 * 86400
        let tsUpper = nowTs + 24 * 3600

        for row in rows {
            guard let sessionID = row["session_id"] as? String, !sessionID.isEmpty else {
                malformedRows += 1
                continue
            }
            // Unknown tools are rejected, never silently treated as hermes (P0-6).
            guard let tool = ToolKind(rawValue: row["tool"] as? String ?? "") else {
                unknownTools += 1
                continue
            }
            guard tool.sourceIsRemote else { continue }
            seenRemoteTools.insert(tool.rawValue)

            let lastSeen = Int64((row["last_seen"] as? NSNumber)?.doubleValue ?? 0)
            // Normalize units once (feed sometimes carries milliseconds),
            // then validate the range in SECONDS against now ± skew.
            let lastSeenS = lastSeen > 1_000_000_000_000 ? lastSeen / 1000 : lastSeen
            guard lastSeenS >= tsLower && lastSeenS <= tsUpper else {
                malformedRows += 1
                continue
            }
            let firstSeen = Int64((row["first_seen"] as? NSNumber)?.doubleValue ?? Double(lastSeen))
            let model = row["model"] as? String
            // All values are clamped to >= 0: negative feed rows would skew
            // SUM-based aggregates and cost breakdowns.
            let input = max((row["input_tokens"] as? NSNumber)?.int64Value ?? 0, 0)
            let output = max((row["output_tokens"] as? NSNumber)?.int64Value ?? 0, 0)
            let reasoning = max((row["reasoning_tokens"] as? NSNumber)?.int64Value ?? 0, 0)
            let cacheRead = max((row["cache_read_tokens"] as? NSNumber)?.int64Value ?? 0, 0)
            let cacheWrite = max((row["cache_write_tokens"] as? NSNumber)?.int64Value ?? 0, 0)
            let cost = max((row["cost_usd"] as? NSNumber)?.doubleValue ?? 0, 0)
            let title = row["title"] as? String
            let project = row["project"] as? String

            var dInput = input
            var dOutput = output
            var dCacheRead = cacheRead
            var dCacheWrite = cacheWrite
            var dCost = cost
            var costQuality = "estimated"
            var rawEventID = row["event_id"] as? String ?? ""
            // Cap upstream event ids: a bloated id would explode the unique
            // index and the watermark setting on every poll.
            if rawEventID.count > 512 {
                rawEventID = String(rawEventID.prefix(512))
            }
            let eventID = rawEventID.isEmpty
                ? Self.fallbackEventID(row: row, tool: tool, sessionID: sessionID,
                                       lastSeen: lastSeenS, firstSeen: firstSeen)
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
                // Use the NORMALIZED second timestamp for the cursor so a
                // feed mixing ms and s units cannot advance past future
                // second-unit rows.
                guard lastSeenS > previousCursor.ts
                        || (lastSeenS == previousCursor.ts && eventID > previousCursor.eventID) else { continue }
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
                let totalIn = input + reasoning
                let prev = runningHermes[key]
                    ?? (Database.shared.setting(key) ?? "").split(separator: ",").map { Int64($0) ?? 0 }
                isFirstRow = prev.count != 5
                if prev.count == 5 {
                    dInput = max(totalIn - prev[0], 0)
                    dOutput = max(output - prev[1], 0)
                    dCacheRead = max(cacheRead - prev[2], 0)
                    dCacheWrite = max(cacheWrite - prev[3], 0)
                }
                runningHermes[key] = [totalIn, output, cacheRead, cacheWrite, 0]
                pendingHermesBaselines.append((key, "\(totalIn),\(output),\(cacheRead),\(cacheWrite),0"))
                dCost = 0
                costQuality = "unknown"
            case .opencode:
                let totalsKey = "opencode|\(sessionID)"
                let prev = runningOpenCode[totalsKey] ?? totals[totalsKey]
                isFirstRow = prev == nil
                if let prev {
                    dInput = max(input + reasoning - prev.input, 0)
                    dOutput = max(output - prev.output, 0)
                    dCacheRead = max(cacheRead - prev.cacheRead, 0)
                    dCacheWrite = max(cacheWrite - prev.cacheWrite, 0)
                    dCost = max(cost - prev.cost, 0)
                }
                runningOpenCode[totalsKey] = ("opencode", input + reasoning, output, cacheRead, cacheWrite, cost)
                pendingOpenCodeTotals.append((totalsKey, input + reasoning, output, cacheRead,
                                              cacheWrite, cost, lastSeenS))
                costQuality = "actual"
            default:
                break // per-turn events: insert as-is
            }

            if dInput > 0 || dOutput > 0 || dCacheRead > 0 || dCacheWrite > 0 {
                // First-seen rows are cumulative baselines: attribute them to
                // the session's start date, not "now" (spec: 历史累计不得归入今天).
                let firstSeenS = firstSeen > 1_000_000_000_000 ? firstSeen / 1000 : firstSeen
                let ts = (isFirstRow && firstSeenS > 0) ? firstSeenS : lastSeenS
                turns.append(TurnRecord(tool: tool, sessionID: sessionID, project: project,
                                        model: model, ts: ts,
                                        inputTokens: dInput, outputTokens: dOutput,
                                        cacheRead: dCacheRead, cacheWrite: dCacheWrite, cost: dCost,
                                        eventID: eventID, costQuality: costQuality))
            }
            sessions["\(tool.rawValue)|\(sessionID)"] = SessionInfo(tool: tool, sessionID: sessionID, title: title,
                                                                    project: project, model: model,
                                                                    created: firstSeen > 1_000_000_000_000 ? firstSeen / 1000 : firstSeen,
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
        if let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) {
            let digest = SHA256.hash(data: data)
                .map { String(format: "%02x", $0) }
                .joined()
            return "remote:\(tool.rawValue):\(sessionID):\(digest)"
        }
        return "remote:\(tool.rawValue):\(sessionID):\(firstSeen):\(lastSeen)"
    }
}
