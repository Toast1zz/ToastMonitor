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
enum PerfCollector {
    static let interval: CFAbsoluteTime = 60
    private static var lastRun: CFAbsoluteTime = 0

    /// Called from the collector queue on every tick.
    static func maybeRun(claudeFiles: [String], database: Database = .shared) {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastRun >= interval else { return }
        lastRun = now
        if !ToolKind.claude.sourceIsRemote {
            // The first run backfills every transcript; spread that over
            // several runs so one tick never holds the collector for long.
            var budget: Int64 = 128 * 1024 * 1024
            for file in claudeFiles where budget > 0 {
                budget -= scanClaude(file: file, database: database)
            }
        }
        if !ToolKind.opencode.sourceIsRemote {
            scanOpenCode(database: database)
        }
        let hourAgoMs = Int64(Date().timeIntervalSince1970 * 1000) - 3_600_000
        database.pruneIncompletePerfSamples(before: hourAgoMs)
    }

    // MARK: - Claude Code

    /// Returns the number of bytes read.
    @discardableResult
    static func scanClaude(file: String, database: Database) -> Int64 {
        guard let st = FileScanner.fileStat(file) else { return 0 }
        let prev = database.perfCursor(file)
        if let prev, prev.size == st.size, prev.identity == st.identity { return 0 }
        // Upserts are idempotent, so anything but plain growth replays the file.
        let offset = prev.map { $0.identity == st.identity && $0.size < st.size ? $0.size : 0 } ?? 0
        var samples: [String: PerfSample] = [:]
        let end = FileScanner.forEachNewJSONLine(path: file, fromOffset: offset) { item in
            guard let sample = claudeSample(item.obj) else { return }
            samples[sample.key, default: sample].merge(sample)
        }
        _ = database.inTransaction {
            database.upsertPerfSamples(Array(samples.values))
                && database.setPerfCursor(file, size: end, identity: st.identity)
        }
        return end - offset
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
                                outputTokens: (usage?["output_tokens"] as? NSNumber)?.int64Value ?? 0)
        if (obj["apiBlockIndex"] as? NSNumber)?.intValue == 0,
           let thinking = (obj["thinkingDurationMs"] as? NSNumber)?.int64Value, thinking > 0 {
            sample.firstTokenMs = ts - thinking
        }
        return sample
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func parseMillis(_ s: String) -> Int64? {
        guard let date = isoFractional.date(from: s) else { return nil }
        return Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    // MARK: - OpenCode

    /// One row per finished single-step assistant message updated since the
    /// last run. Multi-step messages are skipped: their parts interleave tool
    /// execution with generation.
    static func scanOpenCode(database: Database, path: String = OpenCodeParser.dbPath) {
        guard FileManager.default.fileExists(atPath: path) else { return }
        let watermark = database.perfCursor(path)?.size ?? 0
        var src: OpaquePointer?
        guard sqlite3_open_v2(path, &src, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(src)
            return
        }
        defer { sqlite3_close(src) }
        let sql = """
        WITH m AS (
          SELECT id, time_updated, data FROM message
          WHERE time_updated > ? AND json_extract(data, '$.role') = 'assistant'
            AND json_extract(data, '$.time.completed') IS NOT NULL
        ), p AS (
          SELECT p.message_id, json_extract(p.data, '$.type') AS type,
                 json_extract(p.data, '$.time.start') AS start,
                 json_extract(p.data, '$.time.end') AS stop,
                 json_extract(p.data, '$.state.time.start') AS tool_start
          FROM part p JOIN m ON m.id = p.message_id
        )
        SELECT m.id, m.time_updated, json_extract(m.data, '$.modelID'),
               json_extract(m.data, '$.time.created'), json_extract(m.data, '$.time.completed'),
               COALESCE(json_extract(m.data, '$.tokens.output'), 0)
                 + COALESCE(json_extract(m.data, '$.tokens.reasoning'), 0),
               (SELECT COUNT(*) FROM p WHERE p.message_id = m.id AND type = 'step-start'),
               (SELECT MIN(start) FROM p WHERE p.message_id = m.id AND type IN ('reasoning', 'text')),
               (SELECT MAX(stop) FROM p WHERE p.message_id = m.id AND type IN ('reasoning', 'text')),
               (SELECT MAX(tool_start) FROM p WHERE p.message_id = m.id AND type = 'tool')
        FROM m;
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
        while sqlite3_step(stmt) == SQLITE_ROW {
            high = max(high, sqlite3_column_int64(stmt, 1))
            guard int(6) == 1, let first = int(7) else { continue }
            // A tool call's execution starts once its arguments finished
            // streaming; `completed` would include the tool's run time.
            let last = int(9).map { max($0, int(8) ?? $0) } ?? int(4)
            let model = sqlite3_column_type(stmt, 2) == SQLITE_NULL
                ? nil : String(cString: sqlite3_column_text(stmt, 2))
            samples.append(PerfSample(tool: .opencode,
                                      key: String(cString: sqlite3_column_text(stmt, 0)),
                                      model: model, requestMs: int(3), firstTokenMs: first,
                                      lastMs: last, outputTokens: int(5) ?? 0))
        }
        guard high > watermark else { return }
        _ = database.inTransaction {
            database.upsertPerfSamples(samples)
                && database.setPerfCursor(path, size: high, identity: 0)
        }
    }
}
