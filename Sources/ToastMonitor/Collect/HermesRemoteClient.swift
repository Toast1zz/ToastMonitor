import AppKit
import Foundation
import Combine
import CryptoKit
import Darwin

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
/// Event IDs provide idempotency; timestamp watermarks are retained only for
/// diagnostics and never exclude a valid per-turn event.
final class HermesRemoteClient: ObservableObject {
    nonisolated(unsafe) static let shared = HermesRemoteClient()
    static let maxFeedURLLength = 2_048
    static let maxFeedBytes = 10_000_000
    static let maxFeedRows = 50_000
    static let maxFieldLength = 512
    static let maxProviderLength = 256

    struct SyncStatus: Equatable {
        var lastSync: Int64 = 0
        var lastRows: Int = 0
        var error: String?
    }

    @Published private(set) var status = SyncStatus()

    private let queue = DispatchQueue(label: "toastmonitor.remote", qos: .utility)
    private let session: URLSession
    /// Retained: URLSession keeps its delegate weakly.
    private let redirectBlocker = NoRedirectDelegate()
    private var lastPoll: Int64 = 0
    private var timer: Timer?
    private var inFlight = false
    private var started = false

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        session = URLSession(configuration: configuration,
                             delegate: redirectBlocker, delegateQueue: nil)
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
            poll()
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
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.queue.async { [weak self] in
                self?.lastPoll = 0
                self?.maybePoll()
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
        // Empty value clears the remote feed (back to local sources); not an error.
        let trimmed = url?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            return Database.shared.setSetting("remote_feed_url", nil)
        }
        guard trimmed.count <= Self.maxFeedURLLength,
              trimmed.rangeOfCharacter(from: .controlCharacters) == nil,
              let parsed = URL(string: trimmed),
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

    func reloadConfiguration() {
        guard started else { return }
        if !remoteSourcesEnabled {
            clearRemoteHealth()
        }
        lastPoll = 0
        updateForeground()
        if remoteSourcesEnabled {
            poll()
        }
    }

    private func startTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.poll()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Called from the collector loop; rate-limited internally (60s).
    func maybePoll() {
        guard remoteSourcesEnabled else {
            clearRemoteHealth()
            return
        }
        // Foreground uses the existing 15s timer. Background scans also call
        // this method, but the serial-queue rate limit below reduces them to
        // at most one feed request per 60s.
        // Keep the rate-limit check on the serial queue: lastPoll is only
        // mutated inside pollEnqueued, which always runs there.
        queue.async { [weak self] in
            guard let self else { return }
            let now = Int64(Date().timeIntervalSince1970)
            guard now - self.lastPoll > 60 else { return }
            self.pollEnqueued(completion: nil)
        }
    }

    static func isAllowedFeedURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              url.user == nil,
              url.password == nil else { return false }
        if scheme == "https" { return true }
        guard scheme == "http", let host = url.host else { return false }
        // HTTP is limited to the Tailscale CGNAT range 100.64.0.0/10 and loopback.
        if let ip = IPv4Address(host) {
            if ip.isTailscale || ip.isLoopback { return true }
            return false
        }
        return host.lowercased() == "localhost"
    }

    private static func validField(_ value: Any?, maxLength: Int,
                                   allowEmpty: Bool = true) -> Bool {
        guard let value, !(value is NSNull) else { return true }
        guard let string = value as? String,
              (allowEmpty || !string.isEmpty),
              string.count <= maxLength,
              string.rangeOfCharacter(from: .controlCharacters) == nil else { return false }
        return true
    }

    private struct IPv4Address {
        let a: UInt8, b: UInt8, c: UInt8, d: UInt8
        init?(_ s: String) {
            let parts = s.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 4 else { return nil }
            var bytes: [UInt8] = []
            bytes.reserveCapacity(4)
            for part in parts {
                guard !part.isEmpty, part.count <= 3,
                      part.allSatisfy({ $0.isASCII && $0.isNumber }),
                      part == "0" || part.first != "0",
                      let byte = UInt8(part) else { return nil }
                bytes.append(byte)
            }
            var addr = in_addr()
            guard inet_pton(AF_INET, s, &addr) == 1 else { return nil }
            (a, b, c, d) = (bytes[0], bytes[1], bytes[2], bytes[3])
        }
        var isTailscale: Bool { a == 100 && b >= 64 && b <= 127 }
        var isLoopback: Bool { a == 127 }
    }

    // MARK: - Poll

    /// Enqueues one poll on the serial queue. Safe to call from any thread,
    /// including the main thread (Settings' "Test Connection").
    /// `completion` is invoked on the main actor once this poll finishes —
    /// success or failure, including the skip paths where no network request
    /// is made.
    func poll(completion: (@MainActor @Sendable () -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            self.pollEnqueued(completion: completion)
        }
    }

    /// The poll body. Runs on the serial queue only (see `poll`).
    private func pollEnqueued(completion: (@MainActor @Sendable () -> Void)?) {
        func finish() {
            guard let completion else { return }
            Task { @MainActor in completion() }
        }
        guard remoteSourcesEnabled else {
            clearRemoteHealth()
            finish()
            return
        }
        guard !inFlight else { finish(); return }
        inFlight = true
        lastPoll = Int64(Date().timeIntervalSince1970)

        guard feedURL.count <= Self.maxFeedURLLength,
              feedURL.rangeOfCharacter(from: .controlCharacters) == nil,
              let url = URL(string: feedURL),
              Self.isAllowedFeedURL(url) else {
            inFlight = false
            publishStatus { $0.error = "Feed URL invalid or unsafe (HTTPS or private range only)" }
            finish()
            return
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        redirectBlocker.boundedDataTask(in: session, request: req,
                                        maxBytes: Self.maxFeedBytes) { [weak self] data, resp, err in
            guard let self else { return }
            // The session completion arrives on a URLSession delegate queue;
            // hop back onto the serial queue for all state mutation. This is
            // not a nested queue.async inside pollEnqueued's own closure (it
            // runs later, off the queue), so there is no deadlock.
            self.queue.async {
                defer { self.inFlight = false }
                defer { finish() }
                if let err {
                    self.publishStatus { $0.error = err.localizedDescription }
                    return
                }
                guard let http = resp as? HTTPURLResponse else {
                    self.publishStatus { $0.error = "No HTTP response" }
                    return
                }
                // Redirects are cancelled by the delegate; retain this
                // final-URL check for custom URL loading implementations.
                if !Self.isAllowedFeedURL(http.url ?? url) {
                    self.publishStatus { $0.error = "Redirect to a disallowed address rejected" }
                    return
                }
                // Reject oversized responses from the Content-Length header
                // before the body finishes buffering.
                if http.expectedContentLength > Int64(Self.maxFeedBytes) {
                    self.publishStatus { $0.error = "Response too large (>10MB)" }
                    return
                }
                guard http.statusCode == 200 else {
                    self.publishStatus { $0.error = "HTTP \(http.statusCode)" }
                    return
                }
                guard let data, data.count <= Self.maxFeedBytes else {
                    self.publishStatus { $0.error = "Response too large (>10MB)" }
                    return
                }
                if let mime = http.mimeType, !mime.contains("json") {
                    self.publishStatus { $0.error = "Non-JSON response (\(mime))" }
                    return
                }
                guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    self.publishStatus { $0.error = "Failed to parse response" }
                    return
                }
                self.importFeed(obj)
            }
        }.resume()
    }

    /// With remote ingestion off, stale feed state must not linger in the UI.
    private func clearRemoteHealth() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.status != SyncStatus() { self.status = SyncStatus() }
            SourceHealthHub.shared.purgeRemote()
        }
    }

    private func publishStatus(reportErrorToHealth: Bool = true,
                               _ update: @escaping (inout SyncStatus) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            update(&self.status)
            if let error = self.status.error {
                NSLog("[ToastMonitor] remote feed error: %@", error)
                if reportErrorToHealth {
                    SourceHealthHub.shared.record(tool: "remote-feed", rows: 0, failed: 1,
                                                  durationMs: 0, error: error)
                }
            }
        }
    }
    func importFeed(_ result: [String: Any], database: Database = .shared) {
        guard let rows = result["rows"] as? [[String: Any]],
              rows.count <= Self.maxFeedRows else {
            publishStatus { $0.error = "Feed format invalid or too many rows" }
            return
        }
        if let schema = result["schema"] as? Int, schema > 1 {
            publishStatus { $0.error = "Unsupported feed schema v\(schema)" }
            return
        }
        let sourceDigest = SHA256.hash(data: Data(feedURL.utf8))
            .prefix(8).map { String(format: "%02x", $0) }.joined()
        let sourceInstance = "remote:\(sourceDigest)"

        // Retain a monotonic watermark for diagnostics and migration
        // visibility, but never use it to decide whether a per-turn event is
        // eligible: event_id is the durable deduplication boundary.
        struct Cursor {
            var ts: Int64
            var eventID: String
        }
        struct HermesSubCounters {
            var input: Int64
            var output: Int64
            var reasoning: Int64
            var cacheRead: Int64
            var cacheWrite: Int64
        }
        struct HermesRoute {
            let sessionID: String
            let model: String?
            let billingProvider: String?
            var project: String?
            var subRows: [String: HermesSubCounters]
            var firstSeen: Int64
            var lastSeen: Int64
        }

        let staged = StagedParserStateStore(database: database, sourcePaths: [])
        var turns: [TurnRecord] = []
        var sessions: [String: SessionInfo] = [:]
        var hermesRoutes: [String: HermesRoute] = [:]
        var pendingWatermarks: [ToolKind: Cursor] = [:]
        var seenRemoteTools: Set<String> = []
        var unknownTools = 0
        var malformedRows = 0
        let totals = staged.sessionTotals() // once per poll
        // Resolve the remote-source set once per poll instead of
        // hitting the settings table for every row.
        let toolRemoteSources = Set(ToolKind.allCases.filter {
            (staged.setting($0.sourceKey) ?? $0.defaultSource) == "remote"
        })
        var runningOpenCode: [String: (tool: String, input: Int64, output: Int64, reasoning: Int64, cacheRead: Int64, cacheWrite: Int64, cost: Double)] = [:]
        let nowTs = Int64(Date().timeIntervalSince1970)
        // Feed rows outside this window are rejected (a future-dated row
        // would poison the monotonic watermark and blind per-turn tools).
        let tsLower = nowTs - 10 * 366 * 86400
        let tsUpper = nowTs + 24 * 3600

        func updateWatermark(_ tool: ToolKind, lastSeen: Int64, eventID: String) {
            let candidate = Cursor(ts: min(lastSeen, nowTs), eventID: eventID)
            if let previous = pendingWatermarks[tool] {
                if candidate.ts > previous.ts || (candidate.ts == previous.ts && candidate.eventID > previous.eventID) {
                    pendingWatermarks[tool] = candidate
                }
            } else {
                pendingWatermarks[tool] = candidate
            }
        }

        for row in rows {
            // Unknown tools are rejected, never silently treated as Hermes.
            guard let tool = ToolKind(rawValue: row["tool"] as? String ?? "") else {
                unknownTools += 1
                continue
            }
            guard toolRemoteSources.contains(tool) else { continue }
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
                  Self.validField(row["billing_mode"], maxLength: Self.maxFieldLength),
                  Self.validField(row["task"], maxLength: Self.maxFieldLength),
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
            let rawModel = row["model"] as? String
            let model = tool == .opencode ? OpenCodeParser.normalizeModel(rawModel) : rawModel
            // All token values are non-negative and capped before arithmetic;
            // malformed numbers become zero instead of overflowing Int64 sums.
            func count(_ key: String) -> Int64 {
                guard let n = row[key] as? NSNumber else { return 0 }
                let d = n.doubleValue
                guard d.isFinite else { return 0 }
                return Int64(min(max(d, 0), Double(TurnRecord.maxTokens)))
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
            let hasReportedCost = (row["cost_usd"] as? NSNumber).map {
                CFGetTypeID($0) != CFBooleanGetTypeID() && $0.doubleValue.isFinite && $0.doubleValue >= 0
            } ?? false

            let rawEventID = row["event_id"] as? String ?? ""
            let fallbackID = rawEventID.isEmpty
                ? Self.fallbackEventID(row: row, tool: tool, sessionID: sessionID,
                                       lastSeen: lastSeenS, firstSeen: firstSeenS)
                : rawEventID

            let safeSessionUpdated = max(lastSeenS, firstSeenS)
            let sessionKey = "\(tool.rawValue)|\(sessionID)"
            if let existing = sessions[sessionKey] {
                let mergedCreated = existing.created > 0 && firstSeenS > 0 ? min(existing.created, firstSeenS) : max(existing.created, firstSeenS)
                sessions[sessionKey] = SessionInfo(tool: tool, sessionID: sessionID,
                                                   title: existing.title ?? title,
                                                   project: existing.project ?? project,
                                                   model: existing.model ?? model,
                                                   created: mergedCreated,
                                                   updated: max(existing.updated, safeSessionUpdated))
            } else {
                sessions[sessionKey] = SessionInfo(tool: tool, sessionID: sessionID, title: title,
                                                   project: project, model: model,
                                                   created: firstSeenS,
                                                   updated: safeSessionUpdated)
            }

            switch tool {
            case .hermes:
                // Mirror Hermes `session_model_usage` key semantics: duplicate or
                // sequential snapshots for the same `(billing_mode, task)` take
                // `max`, whereas distinct tasks within one billing route sum.
                let billingProvider = row["billing_provider"] as? String
                let key = HermesUsageBaseline.key(session: sessionID, model: model,
                                                  provider: billingProvider,
                                                  baseURL: row["billing_base_url"] as? String)
                let subKey = "\((row["billing_mode"] as? String) ?? "")\u{0}\((row["task"] as? String) ?? "")"
                let subSample = HermesSubCounters(input: input, output: output, reasoning: reasoning,
                                                  cacheRead: cacheRead, cacheWrite: cacheWrite)
                if var route = hermesRoutes[key] {
                    if let existingSub = route.subRows[subKey] {
                        route.subRows[subKey] = HermesSubCounters(
                            input: max(existingSub.input, subSample.input),
                            output: max(existingSub.output, subSample.output),
                            reasoning: max(existingSub.reasoning, subSample.reasoning),
                            cacheRead: max(existingSub.cacheRead, subSample.cacheRead),
                            cacheWrite: max(existingSub.cacheWrite, subSample.cacheWrite))
                    } else {
                        route.subRows[subKey] = subSample
                    }
                    if firstSeenS > 0 && (route.firstSeen == 0 || firstSeenS < route.firstSeen) {
                        route.firstSeen = firstSeenS
                    }
                    route.lastSeen = max(route.lastSeen, lastSeenS)
                    if route.project == nil { route.project = project }
                    hermesRoutes[key] = route
                } else {
                    hermesRoutes[key] = HermesRoute(
                        sessionID: sessionID, model: model,
                        billingProvider: billingProvider ?? (row["provider"] as? String),
                        project: project,
                        subRows: [subKey: subSample],
                        firstSeen: firstSeenS, lastSeen: lastSeenS)
                }
                updateWatermark(.hermes, lastSeen: lastSeenS, eventID: fallbackID)
            case .opencode:
                let totalsKey = "opencode|\(sessionID)"
                let prev = runningOpenCode[totalsKey] ?? totals[totalsKey]
                let isFirstRow = prev == nil
                var dInput = input
                var dOutput = output
                var dReasoning = reasoning
                var dCacheRead = cacheRead
                var dCacheWrite = cacheWrite
                var dCost = cost
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
                staged.setSessionTotals(totalsKey, tool: "opencode",
                                        input: safeInput, output: safeOutput,
                                        reasoning: safeReasoning,
                                        cacheRead: safeRead, cacheWrite: safeWrite,
                                        cost: safeCost, updated: lastSeenS)
                // Always derive cumulative delta event_id from post-step counters
                // rather than reusing a static row["event_id"], which would drop
                // subsequent deltas via ON CONFLICT DO NOTHING.
                let deltaEventID = "opencode-remote:\(sessionID):\(lastSeenS):\(safeInput):\(safeOutput):\(safeReasoning):\(safeRead):\(safeWrite)"
                let dTokens = dInput + dOutput + dReasoning + dCacheRead + dCacheWrite
                if dTokens > 0 {
                    let ts = (isFirstRow && firstSeenS > 0) ? firstSeenS : lastSeenS
                    let provider = (row["billing_provider"] as? String)
                        ?? (row["provider"] as? String)
                        ?? OpenCodeParser.normalizeProvider(rawModel)
                    let quality = (dCost == 0 || !hasReportedCost) ? "unknown" : "actual"
                    turns.append(TurnRecord(tool: .opencode, sessionID: sessionID, project: project,
                                            model: model, ts: ts,
                                            inputTokens: dInput, outputTokens: dOutput,
                                            reasoningTokens: dReasoning,
                                            cacheRead: dCacheRead, cacheWrite: dCacheWrite, cost: dCost,
                                            provider: provider, sourceInstance: sourceInstance,
                                            eventID: deltaEventID, costQuality: quality))
                }
                updateWatermark(.opencode, lastSeen: lastSeenS, eventID: deltaEventID)
            default:
                let dTokens = input + output + reasoning + cacheRead + cacheWrite
                if dTokens > 0 {
                    let provider = (row["billing_provider"] as? String) ?? (row["provider"] as? String)
                    let finalCost: Double
                    let quality: String
                    if hasReportedCost {
                        finalCost = cost
                        quality = "estimated"
                    } else if let est = Pricing.estimate(model: model, input: input, output: output,
                                                         cacheRead: cacheRead, cacheWrite: cacheWrite,
                                                         inputIncludesCache: tool == .codex) {
                        finalCost = est
                        quality = "estimated"
                    } else {
                        finalCost = 0
                        quality = "unknown"
                    }
                    turns.append(TurnRecord(tool: tool, sessionID: sessionID, project: project,
                                            model: model, ts: lastSeenS,
                                            inputTokens: input, outputTokens: output,
                                            reasoningTokens: reasoning,
                                            cacheRead: cacheRead, cacheWrite: cacheWrite, cost: finalCost,
                                            provider: provider, sourceInstance: sourceInstance,
                                            eventID: fallbackID, costQuality: quality))
                }
                updateWatermark(tool, lastSeen: lastSeenS, eventID: fallbackID)
            }
        }

        for key in hermesRoutes.keys.sorted() {
            guard let route = hermesRoutes[key] else { continue }
            var totalInput: Int64 = 0
            var totalOutput: Int64 = 0
            var totalReasoning: Int64 = 0
            var totalCacheRead: Int64 = 0
            var totalCacheWrite: Int64 = 0
            for sub in route.subRows.values {
                totalInput = min(totalInput + sub.input, TurnRecord.maxTokens)
                totalOutput = min(totalOutput + sub.output, TurnRecord.maxTokens)
                totalReasoning = min(totalReasoning + sub.reasoning, TurnRecord.maxTokens)
                totalCacheRead = min(totalCacheRead + sub.cacheRead, TurnRecord.maxTokens)
                totalCacheWrite = min(totalCacheWrite + sub.cacheWrite, TurnRecord.maxTokens)
            }
            let current = HermesUsageBaseline.Counters(input: totalInput, output: totalOutput,
                                                       reasoning: totalReasoning,
                                                       cacheRead: totalCacheRead,
                                                       cacheWrite: totalCacheWrite)
            let localKey = HermesUsageBaseline.localTotalsKey(key)
            let local: [Int64] = totals[localKey].map {
                [$0.input, $0.output, $0.reasoning, $0.cacheRead, $0.cacheWrite, 0]
            } ?? []
            let prev = HermesUsageBaseline.merge(current: current, baselines: [
                local,
                HermesUsageBaseline.parse(staged.setting(key))
            ])
            let step = HermesUsageBaseline.advance(current: current, prev: prev)
            let b = step.base
            let encoded = HermesUsageBaseline.encode(b)
            if staged.setting(key) != encoded {
                staged.setSetting(key, encoded)
            }
            let stored = totals[localKey]
            if stored?.input != b.input || stored?.output != b.output || stored?.reasoning != b.reasoning
                || stored?.cacheRead != b.cacheRead || stored?.cacheWrite != b.cacheWrite {
                staged.setSessionTotals(localKey, tool: "hermes",
                                        input: b.input, output: b.output,
                                        reasoning: b.reasoning, cacheRead: b.cacheRead,
                                        cacheWrite: b.cacheWrite, cost: 0, updated: nowTs)
            }
            let d = step.delta
            if d.input > 0 || d.output > 0 || d.reasoning > 0 || d.cacheRead > 0 || d.cacheWrite > 0 {
                let ts = (step.isFirst && route.firstSeen > 0) ? route.firstSeen : route.lastSeen
                let eventID = "hermes-remote:\(key):\(b.input):\(b.output):\(b.reasoning):\(b.cacheRead):\(b.cacheWrite)"
                turns.append(TurnRecord(tool: .hermes, sessionID: route.sessionID, project: route.project,
                                        model: route.model, ts: ts,
                                        inputTokens: d.input, outputTokens: d.output,
                                        reasoningTokens: d.reasoning,
                                        cacheRead: d.cacheRead, cacheWrite: d.cacheWrite, cost: 0,
                                        provider: route.billingProvider, sourceInstance: sourceInstance,
                                        eventID: eventID, costQuality: "unknown"))
            }
        }

        for (tool, value) in pendingWatermarks {
            staged.setSetting("remote_watermark_\(tool.rawValue)", "\(value.ts)")
        }

        // Atomic commit: validate baselines + turns + sessions + cumulative baselines + watermarks.
        var insertedTurnCount = 0
        var importedByTool: [String: Int] = [:]
        let ok = database.inTransaction {
            guard staged.validateForCommit() else { return false }
            let insertResult = database.insertTurnsCounting(turns)
            guard insertResult.ok else { return false }
            insertedTurnCount = insertResult.changed
            importedByTool = insertResult.changedByTool
            guard database.upsertSessions(Array(sessions.values)), staged.apply() else { return false }
            return true
        }
        guard ok else {
            publishStatus { $0.error = "Import transaction failed, watermark not advanced" }
            return
        }
        let ignoredRows = unknownTools + malformedRows
        let errorText = ignoredRows > 0 ? "\(ignoredRows) invalid/unknown rows ignored" : nil
        let syncTime = Int64(Date().timeIntervalSince1970)
        if insertedTurnCount > 0 {
            database.setSetting("last_scan_heartbeat", "\(syncTime)")
            database.backfillCosts()
        }
        publishStatus(reportErrorToHealth: false) {
            $0.lastSync = syncTime
            $0.lastRows = insertedTurnCount
            $0.error = errorText
        }
        Task { @MainActor in
            for tool in seenRemoteTools {
                let imported = importedByTool[tool] ?? 0
                if imported > 0 {
                    SourceHealthHub.shared.record(tool: tool, rows: imported, failed: 0,
                                                  durationMs: 0, error: nil)
                } else {
                    SourceHealthHub.shared.recordIdle(tool: tool, durationMs: 0)
                }
            }
            // Always record the remote-feed outcome so recovery clears prior errors.
            SourceHealthHub.shared.record(tool: "remote-feed", rows: insertedTurnCount,
                                          failed: ignoredRows, durationMs: 0,
                                          error: errorText)
            if insertedTurnCount > 0 {
                NotificationCenter.default.post(name: CollectorEngine.didCollect, object: nil)
            }
        }
        if insertedTurnCount > 0 || ignoredRows > 0 {
            NSLog("[ToastMonitor] remote feed: %d rows received, %d turns imported, %d invalid",
                  rows.count, insertedTurnCount, ignoredRows)
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
