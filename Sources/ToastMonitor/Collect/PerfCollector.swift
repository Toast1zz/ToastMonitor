import Foundation
import SQLite3

/// Collects per-call timing (time to first token, output speed) on its own
/// cursors, at most once a minute. Only sources that record when streaming
/// actually started are used; whole-call durations would mix in queueing and
/// prompt processing.
///
/// - Claude Code writes one transcript line per finished content block. A
///   leading thinking block carries `thinkingDurationMs`, so its line time
///   minus that duration is when the first token arrived. The `api-request`
///   line (newer CLI versions) gives the send time. Calls that open with text
///   or a tool call have no first-token time and are not measured.
/// - OpenCode stores start/end times on each streamed part.
/// - Codex (newer CLI versions) stamps each reasoning and message item with
///   its streaming start/end; a `token_usage_record` closes each response.
/// - DeepSeek Harness logs each step's start and every streamed chunk.
/// - Oh My Pi records each assistant message's send time, time to first
///   token and duration.
///
/// - Antigravity stores each call's time to first token and streaming
///   duration next to its token counts.
///
/// Hermes logs only whole-call latency, so it is not measured.
enum PerfCollector {
    static let interval: CFAbsoluteTime = 60
    static let didUpdate = Notification.Name("ToastMonitorPerfDidUpdate")
    private static var lastRun: CFAbsoluteTime = 0

    private static func sameCursor(_ lhs: (size: Int64, identity: Int64)?,
                                   _ rhs: (size: Int64, identity: Int64)?) -> Bool {
        lhs?.size == rhs?.size && lhs?.identity == rhs?.identity
    }

    /// Called from the collector queue on every tick.
    static func maybeRun(claudeFiles: [String], codexFiles: [String], ompFiles: [String],
                         database: Database = .shared) {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastRun >= interval else { return }
        lastRun = now
        let beforeVersion = database.dataVersionKey()
        // The first run backfills every transcript; spread that over
        // several runs so one tick never holds the collector for long.
        var budget: Int64 = 128 * 1024 * 1024
        func scan(_ tool: ToolKind, _ files: [String], _ scanner: (String) -> Int64) {
            guard !tool.sourceIsRemote else { return }
            for file in files where budget > 0 { budget -= scanner(file) }
        }
        scan(.claude, claudeFiles) { scanClaude(file: $0, database: database) }
        scan(.codex, codexFiles) { scanCodex(file: $0, database: database) }
        scan(.omp, ompFiles) { scanOmp(file: $0, database: database) }
        scan(.dsh, DSHParser.listSessionFiles()) { scanDSH(file: $0, database: database) }
        if !ToolKind.opencode.sourceIsRemote {
            scanOpenCode(database: database)
        }
        for path in AntigravityParser.conversationPaths() {
            scanAntigravity(path: path, database: database)
        }
        let hourAgoMs = Int64(Date().timeIntervalSince1970 * 1000) - 3_600_000
        database.pruneIncompletePerfSamples(before: hourAgoMs)
        if database.dataVersionKey() != beforeVersion {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: didUpdate, object: nil)
            }
        }
    }

    // MARK: - Claude Code

    /// Returns the number of bytes read.
    @discardableResult
    static func scanClaude(file: String, database: Database) -> Int64 {
        guard let st = FileScanner.fileStat(file) else { return 0 }
        let prev = database.perfCursor(file)
        if let prev, prev.size == st.size, prev.identity == st.identity { return 0 }
        // Upserts are idempotent, so anything but plain growth replays the file.
        let offset = prev.flatMap {
            $0.identity == st.identity && $0.size < st.size
                && FileScanner.isLineBoundary(path: file, offset: $0.size) ? $0.size : nil
        } ?? 0
        var samples: [String: PerfSample] = [:]
        let end = FileScanner.forEachNewJSONLine(path: file, fromOffset: offset, maxOffset: st.size) { item in
            guard let sample = claudeSample(item.obj) else { return }
            samples[sample.key, default: sample].merge(sample)
        }
        _ = database.inTransaction {
            guard sameCursor(database.perfCursor(file), prev) else { return false }
            return database.upsertPerfSamples(Array(samples.values))
                && database.setPerfCursor(file, size: end, identity: st.identity)
        }
        return max(end - offset, 0)
    }

    static func claudeSample(_ obj: [String: Any]) -> PerfSample? {
        guard let type = obj["type"] as? String,
              let ts = (obj["timestamp"] as? String).flatMap(parseMillis)
        else { return nil }
        if type == "api-request" {
            guard let id = obj["id"] as? String, !id.isEmpty else { return nil }
            return PerfSample(tool: .claude, key: id, requestMs: ts)
        }
        guard type == "assistant", let message = obj["message"] as? [String: Any] else { return nil }
        // requestRef matches the api-request line; older lines only have requestId.
        guard let key = (obj["requestRef"] as? String) ?? (obj["requestId"] as? String)
                ?? (message["id"] as? String), !key.isEmpty
        else { return nil }
        let usage = message["usage"] as? [String: Any]
        var sample = PerfSample(tool: .claude, key: key,
                                model: message["model"] as? String,
                                lastMs: ts,
                                outputTokens: FileScanner.tokenCount(usage?["output_tokens"]))
        if (obj["apiBlockIndex"] as? NSNumber)?.intValue == 0,
           let thinking = (obj["thinkingDurationMs"] as? NSNumber)?.int64Value, thinking > 0 {
            let (first, overflow) = ts.subtractingReportingOverflow(thinking)
            if !overflow { sample.firstTokenMs = first }
        }
        return sample
    }

    private final class ISOFormatterCache: @unchecked Sendable {
        private let lock = NSLock()
        private let isoFractional: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f
        }()
        private let isoBasic: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime]
            return f
        }()

        func parse(_ s: String) -> Date? {
            lock.lock(); defer { lock.unlock() }
            return isoFractional.date(from: s) ?? isoBasic.date(from: s)
        }
    }

    private static let isoCache = ISOFormatterCache()

    static func parseMillis(_ s: String) -> Int64? {
        guard let date = isoCache.parse(s) else { return nil }
        return Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    // MARK: - Codex

    /// A response's samples are only complete once its usage record arrives,
    /// so while a turn is open the cursor stays at the line that last reset
    /// the state and the next run reads the response again from there.
    @discardableResult
    static func scanCodex(file: String, database: Database,
                          nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) -> Int64 {
        guard let st = FileScanner.fileStat(file) else { return 0 }
        let prev = database.perfCursor(file)
        if let prev, prev.size == st.size, prev.identity == st.identity { return 0 }
        let offset = prev.flatMap {
            $0.identity == st.identity && $0.size < st.size
                && FileScanner.isLineBoundary(path: file, offset: $0.size) ? $0.size : nil
        } ?? 0
        // A resumed read can start after the turn's model line; the usage
        // parser's context holds the file's latest model.
        var state = CodexResponseState()
        if offset > 0, let ctx = database.scanState(file).context?.data(using: .utf8),
           let model = ((try? JSONSerialization.jsonObject(with: ctx)) as? [String: Any])?["model"] as? String,
           !model.isEmpty {
            state.model = model
        }
        var samples: [PerfSample] = []
        let end = FileScanner.forEachNewJSONLine(path: file, fromOffset: offset, maxOffset: st.size) { item in
            if let sample = state.consume(item.obj, offset: item.offset) { samples.append(sample) }
        }
        // A turn whose last line is an hour old ended without a closing event.
        let open = state.turnOpen && nowMs - state.lastLineMs < 3_600_000
        let cursor = open ? max(state.mark ?? offset, offset) : end
        _ = database.inTransaction {
            guard sameCursor(database.perfCursor(file), prev) else { return false }
            return database.upsertPerfSamples(samples)
                && database.setPerfCursor(file, size: cursor, identity: st.identity)
        }
        return max(end - offset, 0)
    }

    /// Folds rollout lines into one sample per model response.
    struct CodexResponseState {
        var model: String?
        var turnOpen = false
        var lastLineMs: Int64 = 0
        /// Offset of the latest line a re-read can rebuild this state from.
        var mark: Int64?
        private var requestMs: Int64?
        private var firstMs: Int64?
        private var lastMs: Int64?

        private mutating func startResponse(requestMs: Int64?, offset: Int64) {
            self.requestMs = requestMs
            firstMs = nil
            lastMs = nil
            mark = offset
        }

        mutating func consume(_ obj: [String: Any], offset: Int64) -> PerfSample? {
            guard let type = obj["type"] as? String,
                  let ts = (obj["timestamp"] as? String).flatMap(PerfCollector.parseMillis),
                  let payload = obj["payload"] as? [String: Any]
            else { return nil }
            lastLineMs = max(lastLineMs, ts)
            let kind = payload["type"] as? String
            switch type {
            case "turn_context":
                if let m = payload["model"] as? String, !m.isEmpty { model = m }
            case "response_item":
                guard let kind else { break }
                // A tool call is logged once its arguments finished streaming;
                // its output is what the next request is sent with.
                if kind.hasSuffix("_call") {
                    lastMs = max(lastMs ?? ts, ts)
                } else if kind.hasSuffix("_call_output") {
                    requestMs = max(requestMs ?? ts, ts)
                }
            case "token_usage_record":
                defer { startResponse(requestMs: ts, offset: offset) }
                guard let first = firstMs, let id = payload["response_id"] as? String, !id.isEmpty,
                      let usage = payload["usage"] as? [String: Any]
                else { return nil }
                return PerfSample(tool: .codex, key: id, model: model, requestMs: requestMs,
                                  firstTokenMs: first, lastMs: lastMs,
                                  outputTokens: FileScanner.tokenCount(usage["output_tokens"]))
            case "event_msg":
                switch kind {
                case "thread_settings_applied":
                    if let m = (payload["thread_settings"] as? [String: Any])?["model"] as? String,
                       !m.isEmpty { model = m }
                case "task_started":
                    turnOpen = true
                    mark = offset
                case "task_complete", "turn_aborted":
                    turnOpen = false
                case "item_completed":
                    guard let item = payload["item"] as? [String: Any],
                          let start = (payload["started_at_ms"] as? NSNumber)?.int64Value,
                          let done = (payload["completed_at_ms"] as? NSNumber)?.int64Value
                    else { break }
                    switch item["type"] as? String {
                    case "UserMessage", "ContextCompaction":
                        startResponse(requestMs: done, offset: offset)
                    case "Reasoning", "AgentMessage":
                        firstMs = min(firstMs ?? start, start)
                        lastMs = max(lastMs ?? done, done)
                    default:
                        break
                    }
                default:
                    break
                }
            default:
                break
            }
            return nil
        }
    }

    // MARK: - DeepSeek Harness

    /// One sample per step, keyed by session/turn/step so a migrated copy
    /// of the same history lands on the same rows. Partial steps merge in
    /// the database across reads.
    @discardableResult
    static func scanDSH(file: String, database: Database,
                        decompress: ((Data) -> Data?)? = nil) -> Int64 {
        if decompress == nil, file.hasSuffix(".zstd"), Zstd.executablePath() == nil { return 0 }
        let decompressFn: (Data) -> Data? = decompress ?? { Zstd.decompress($0) }
        guard let st = FileScanner.fileStat(file) else { return 0 }
        let prev = database.perfCursor(file)
        if let prev, prev.size == st.size, prev.identity == st.identity { return 0 }
        let offset = prev.flatMap {
            $0.identity == st.identity && $0.size < st.size
                && (file.hasSuffix(".zstd") || FileScanner.isLineBoundary(path: file, offset: $0.size)) ? $0.size : nil
        } ?? 0
        let sessionID = ((file as NSString).deletingLastPathComponent as NSString).lastPathComponent
        var samples: [String: PerfSample] = [:]
        let pass = DSHParser.forEachObject(path: file, fromOffset: offset, maxOffset: st.size, decompress: decompressFn) { item in
            guard let sample = dshSample(item.obj, sessionID: sessionID) else { return }
            samples[sample.key, default: sample].merge(sample)
        }
        _ = database.inTransaction {
            guard sameCursor(database.perfCursor(file), prev) else { return false }
            return database.upsertPerfSamples(Array(samples.values))
                && database.setPerfCursor(file, size: pass.newOffset, identity: st.identity)
        }
        return max(pass.newOffset - offset, 0)
    }

    static func dshSample(_ obj: [String: Any], sessionID: String) -> PerfSample? {
        guard let type = obj["type"] as? String, let d = obj["data"] as? [String: Any],
              let turn = d["turn"] as? Int, let step = d["step"] as? Int
        else { return nil }
        let time = (obj["time"] as? NSNumber)?.int64Value
        var sample = PerfSample(tool: .dsh, key: "\(sessionID):\(turn):\(step)")
        switch type {
        case "step/start":
            sample.requestMs = time
        case "assistant/chunk":
            // Older logs: one line per streamed chunk.
            guard let chunk = d["chunk"] as? [String: Any], let time else { return nil }
            switch chunk["type"] as? String {
            case "usage":
                sample.outputTokens = FileScanner.tokenCount((chunk["usage"] as? [String: Any])?["outputTokens"])
            case "finish":
                let rs = chunk["replayState"] as? [String: Any]
                sample.model = (rs?["response"] as? [String: Any])?["model"] as? String
                    ?? rs?["model"] as? String
            default:
                sample.firstTokenMs = time
                sample.lastMs = time
            }
        case "assistant/message":
            // Versioned logs fold the chunks into the message's `stream`.
            let msg = d["message"] as? [String: Any]
            let source = msg?["source"] as? [String: Any]
            sample.model = msg?["model"] as? String ?? source?["model"] as? String
            let usage = (d["usage"] ?? msg?["usage"]) as? [String: Any]
            sample.outputTokens = FileScanner.tokenCount(usage?["outputTokens"])
            for entry in d["stream"] as? [[String: Any]] ?? [] {
                let span: (Int64, Int64)
                if let t0 = (entry["time0"] as? NSNumber)?.int64Value {
                    var dt: Int64 = 0
                    for v in entry["dt"] as? [NSNumber] ?? [] {
                        let (sum, ov) = dt.addingReportingOverflow(v.int64Value)
                        if ov { dt = Int64.max; break }
                        dt = sum
                    }
                    let (endTs, ov) = t0.addingReportingOverflow(dt)
                    guard !ov else { continue }
                    span = (t0, endTs)
                } else if let t = (entry["time"] as? NSNumber)?.int64Value,
                          let kind = (entry["chunk"] as? [String: Any])?["type"] as? String,
                          kind != "usage", kind != "finish" {
                    span = (t, t)
                } else {
                    continue
                }
                sample.firstTokenMs = min(sample.firstTokenMs ?? span.0, span.0)
                sample.lastMs = max(sample.lastMs ?? span.1, span.1)
            }
        default:
            return nil
        }
        return sample
    }

    // MARK: - Oh My Pi

    @discardableResult
    static func scanOmp(file: String, database: Database) -> Int64 {
        guard let st = FileScanner.fileStat(file) else { return 0 }
        let prev = database.perfCursor(file)
        if let prev, prev.size == st.size, prev.identity == st.identity { return 0 }
        let offset = prev.flatMap {
            $0.identity == st.identity && $0.size < st.size
                && FileScanner.isLineBoundary(path: file, offset: $0.size) ? $0.size : nil
        } ?? 0
        var samples: [PerfSample] = []
        let end = FileScanner.forEachNewJSONLine(path: file, fromOffset: offset, maxOffset: st.size) { item in
            if let sample = ompSample(item.obj) { samples.append(sample) }
        }
        _ = database.inTransaction {
            guard sameCursor(database.perfCursor(file), prev) else { return false }
            return database.upsertPerfSamples(samples)
                && database.setPerfCursor(file, size: end, identity: st.identity)
        }
        return max(end - offset, 0)
    }

    static func ompSample(_ obj: [String: Any]) -> PerfSample? {
        guard obj["type"] as? String == "message",
              let message = obj["message"] as? [String: Any],
              message["role"] as? String == "assistant",
              let sent = (message["timestamp"] as? NSNumber)?.int64Value,
              let ttft = (message["ttft"] as? NSNumber)?.doubleValue,
              let duration = (message["duration"] as? NSNumber)?.doubleValue,
              ttft.isFinite, duration.isFinite,
              ttft >= 0, duration >= 0,
              ttft < 86_400_000, duration < 86_400_000,
              let key = (message["responseId"] as? String) ?? (obj["id"] as? String), !key.isEmpty
        else { return nil }
        let (firstTokenMs, firstOverflow) = sent.addingReportingOverflow(Int64(ttft.rounded()))
        let (lastMs, lastOverflow) = sent.addingReportingOverflow(Int64(duration.rounded()))
        guard !firstOverflow, !lastOverflow else { return nil }
        let usage = message["usage"] as? [String: Any]
        return PerfSample(tool: .omp, key: key, model: message["model"] as? String,
                          requestMs: sent, firstTokenMs: firstTokenMs,
                          lastMs: lastMs,
                          outputTokens: FileScanner.tokenCount(usage?["output"]))
    }

    // MARK: - Antigravity

    private final class SignatureCache: @unchecked Sendable {
        private let lock = NSLock()
        private var map: [String: String] = [:]

        func get(_ path: String) -> String? {
            lock.lock(); defer { lock.unlock() }
            return map[path]
        }

        func set(_ path: String, _ value: String) {
            lock.lock(); defer { lock.unlock() }
            map[path] = value
        }

        func reset() {
            lock.lock(); defer { lock.unlock() }
            map.removeAll()
        }
    }

    /// Signature of each conversation file / OpenCode DB at its last read, so unchanged
    /// files are not opened every minute.
    private static let antigravitySignatures = SignatureCache()
    private static let openCodeSignatures = SignatureCache()

    static func resetCaches() {
        antigravitySignatures.reset()
        openCodeSignatures.reset()
    }

    /// The cursor holds the next unread `gen_metadata` index.
    static func scanAntigravity(path: String, database: Database) {
        let wal = FileScanner.fileStat(path + "-wal")
        guard let st = FileScanner.fileStat(path) else { return }
        let prevCursor = database.perfCursor(path)
        let next = prevCursor?.size ?? 0
        let signature = "\(ObjectIdentifier(database))|\(st.size):\(st.mtime):\(st.identity)|\(wal?.size ?? -1):\(wal?.mtime ?? -1)|c=\(next)"
        guard antigravitySignatures.get(path) != signature else { return }
        guard let rows = AntigravityParser.readGenerations(path: path, after: next - 1) else { return }
        let cascade = AntigravityParser.cascadeID(path)
        let samples = rows.compactMap { row -> PerfSample? in
            let (sentMs, ov) = row.sentAt.multipliedReportingOverflow(by: 1000)
            guard !ov else { return nil }
            return antigravitySample(row.gen, key: "\(cascade):\(row.idx)", sentMs: sentMs)
        }
        let read = AntigravityParser.readThrough(rows, previous: next - 1) {
            $0.timeToFirstTokenMs != nil && $0.usage != nil && $0.streamingMs != nil
        }
        let saved = database.inTransaction {
            guard sameCursor(database.perfCursor(path), prevCursor) else { return false }
            return database.upsertPerfSamples(samples)
                && (read + 1 == next || database.setPerfCursor(path, size: read + 1, identity: 0))
        }
        if saved {
            let finalNext = database.perfCursor(path)?.size ?? next
            let finalSig = "\(ObjectIdentifier(database))|\(st.size):\(st.mtime):\(st.identity)|\(wal?.size ?? -1):\(wal?.mtime ?? -1)|c=\(finalNext)"
            antigravitySignatures.set(path, finalSig)
        }
    }

    /// The step time only dates the call; both figures come from the
    /// recorded durations.
    static func antigravitySample(_ gen: AntigravityParser.Generation, key: String,
                                  sentMs: Int64) -> PerfSample? {
        guard let ttft = gen.timeToFirstTokenMs, let usage = gen.usage else { return nil }
        let (first, firstOverflow) = sentMs.addingReportingOverflow(ttft)
        guard !firstOverflow else { return nil }
        let last: Int64?
        if let streaming = gen.streamingMs {
            let (sum, lastOverflow) = first.addingReportingOverflow(streaming)
            last = lastOverflow ? nil : sum
        } else {
            last = nil
        }
        return PerfSample(tool: .antigravity, key: key, model: gen.model,
                          requestMs: sentMs, firstTokenMs: first,
                          lastMs: last,
                          outputTokens: usage.output)
    }

    // MARK: - OpenCode

    /// One row per finished single-step assistant message updated since the
    /// last run. Multi-step messages are skipped: their parts interleave tool
    /// execution with generation.
    static func scanOpenCode(database: Database, path: String = OpenCodeParser.dbPath) {
        guard let st = FileScanner.fileStat(path) else { return }
        let wal = FileScanner.fileStat(path + "-wal")
        let prevCursor = database.perfCursor(path)
        let watermark = prevCursor?.size ?? -1
        let sig = "\(ObjectIdentifier(database))|\(st.size):\(st.mtime):\(st.identity)|\(wal?.size ?? -1):\(wal?.mtime ?? -1)|c=\(watermark)"
        guard openCodeSignatures.get(path) != sig else { return }
        guard let src = SQLiteReadOnly.open(path) else { return }
        defer { sqlite3_close(src) }
        let sql = """
        WITH m AS (
          SELECT id, time_updated, data FROM message
          WHERE time_updated > ? AND json_extract(data, '$.role') = 'assistant'
            AND json_extract(data, '$.time.completed') IS NOT NULL
        )
        SELECT m.id, m.time_updated, json_extract(m.data, '$.modelID'),
               json_extract(m.data, '$.time.created'), json_extract(m.data, '$.time.completed'),
               COALESCE(json_extract(m.data, '$.tokens.output'), 0)
                 + COALESCE(json_extract(m.data, '$.tokens.reasoning'), 0),
               SUM(CASE WHEN json_extract(p.data, '$.type') = 'step-start' THEN 1 ELSE 0 END),
               MIN(CASE WHEN json_extract(p.data, '$.type') IN ('reasoning', 'text')
                        THEN json_extract(p.data, '$.time.start') END),
               MAX(CASE WHEN json_extract(p.data, '$.type') IN ('reasoning', 'text')
                        THEN json_extract(p.data, '$.time.end') END),
               MAX(CASE WHEN json_extract(p.data, '$.type') = 'tool'
                        THEN json_extract(p.data, '$.state.time.start') END)
        FROM m LEFT JOIN part p ON p.message_id = m.id
        GROUP BY m.id
        ORDER BY m.time_updated ASC;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(src, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, watermark)
        func int(_ i: Int32) -> Int64? {
            sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, i)
        }
        var samples: [PerfSample] = []
        var high = watermark
        var stepRC = sqlite3_step(stmt)
        while stepRC == SQLITE_ROW {
            high = max(high, sqlite3_column_int64(stmt, 1))
            if int(6) == 1, let first = int(7), let key = SQLiteText.column(stmt, 0) {
                // A tool call's execution starts once its arguments finished
                // streaming; `completed` would include the tool's run time.
                let last = int(9).map { max($0, int(8) ?? $0) } ?? int(4)
                let model = SQLiteText.column(stmt, 2)
                let rawOut = int(5) ?? 0
                let clampedOut = min(max(rawOut, 0), TurnRecord.maxTokens)
                samples.append(PerfSample(tool: .opencode,
                                          key: key,
                                          model: model, requestMs: int(3), firstTokenMs: first,
                                          lastMs: last, outputTokens: clampedOut))
            }
            stepRC = sqlite3_step(stmt)
        }
        guard stepRC == SQLITE_DONE else { return }
        guard high > watermark || !samples.isEmpty else {
            openCodeSignatures.set(path, sig)
            return
        }
        let saved = database.inTransaction {
            guard sameCursor(database.perfCursor(path), prevCursor) else { return false }
            return database.upsertPerfSamples(samples)
                && database.setPerfCursor(path, size: max(high, 0), identity: 0)
        }
        if saved {
            let finalCursor = max(high, 0)
            let finalSig = "\(ObjectIdentifier(database))|\(st.size):\(st.mtime):\(st.identity)|\(wal?.size ?? -1):\(wal?.mtime ?? -1)|c=\(finalCursor)"
            openCodeSignatures.set(path, finalSig)
        }
    }
}
