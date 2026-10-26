import Foundation
import SQLite3

/// OpenCode parser (modern format): ~/.local/share/opencode/opencode.db
/// `session` table carries cumulative totals: cost, tokens_input/output/reasoning/cache_read/cache_write.
/// We compute per-scan deltas against session_totals to build turn records.
enum OpenCodeParser {

    static let watermarkKey = "opencode_row_watermark"

    static var dbPath: String {
        // getenv sees setenv (tests). OPENCODE_HOME wins even when the file
        // does not exist yet, so a scan can wait for the database to appear.
        if let raw = getenv("OPENCODE_HOME"), let home = String(validatingUTF8: raw), !home.isEmpty {
            return (home as NSString).appendingPathComponent("opencode.db")
        }
        let fm = FileManager.default
        let userHome = fm.homeDirectoryForCurrentUser
        var candidates: [String] = []
        if let raw = getenv("XDG_DATA_HOME"), let xdg = String(validatingUTF8: raw), !xdg.isEmpty {
            candidates.append((xdg as NSString).appendingPathComponent("opencode/opencode.db"))
        }
        candidates.append(userHome.appendingPathComponent("Library/Application Support/opencode/opencode.db").path)
        candidates.append(userHome.appendingPathComponent(".local/share/opencode/opencode.db").path)
        return candidates.first { fm.fileExists(atPath: $0) } ?? candidates[candidates.count - 1]
    }

    struct Row {
        let id: String
        let title: String
        let directory: String
        let model: String?
        let provider: String?
        let cost: Double
        let hasActualCost: Bool
        let input: Int64
        let output: Int64
        let reasoning: Int64
        let cacheRead: Int64
        let cacheWrite: Int64
        let timeCreated: Int64
        let timeUpdated: Int64
    }

    /// Rows at or after `watermark` (raw `time_updated`). A prepare failure is
    /// reported and does not advance the watermark.
    private static func forEachRow(since watermark: Int64, database: any ParserStateStore,
                                   _ body: (Row) -> Void) -> (count: Int, maxUpdated: Int64, failed: Bool) {
        guard FileManager.default.fileExists(atPath: dbPath) else { return (0, watermark, false) }
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            database.noteScanProblem("OpenCode database could not be opened")
            return (0, watermark, true)
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        let sql = """
        SELECT id, COALESCE(title,''), COALESCE(directory,''), model, cost,
               tokens_input, tokens_output, tokens_reasoning, tokens_cache_read, tokens_cache_write,
               time_created, time_updated FROM session WHERE time_updated >= ?;
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            database.noteScanProblem("OpenCode database could not be read")
            return (0, watermark, true)
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, watermark)
        var count = 0
        var maxUpdated = watermark
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let id = SQLiteText.column(stmt, 0), !id.isEmpty else { continue }
            let model = SQLiteText.column(stmt, 3)
            let updated = sqlite3_column_int64(stmt, 11)
            if updated > maxUpdated { maxUpdated = updated }
            body(Row(id: id, title: SQLiteText.column(stmt, 1) ?? "",
                     directory: SQLiteText.column(stmt, 2) ?? "",
                     model: normalizeModel(model),
                     provider: normalizeProvider(model),
                     cost: sqlite3_column_double(stmt, 4),
                     hasActualCost: sqlite3_column_type(stmt, 4) != SQLITE_NULL,
                     input: FileScanner.tokenCount(sqlite3_column_int64(stmt, 5)),
                     output: FileScanner.tokenCount(sqlite3_column_int64(stmt, 6)),
                     reasoning: FileScanner.tokenCount(sqlite3_column_int64(stmt, 7)),
                     cacheRead: FileScanner.tokenCount(sqlite3_column_int64(stmt, 8)),
                     cacheWrite: FileScanner.tokenCount(sqlite3_column_int64(stmt, 9)),
                     timeCreated: sqlite3_column_int64(stmt, 10),
                     timeUpdated: updated))
            count += 1
        }
        return (count, maxUpdated, false)
    }

    /// The `model` column is sometimes a JSON object
    /// ({"id":"...","providerID":"..."}) instead of a bare id. Extract the id
    /// so the UI never shows raw JSON in session/model rows.
    static func normalizeModel(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        if raw.hasPrefix("{"), let data = raw.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let id = obj["id"] as? String, !id.isEmpty {
            return id
        }
        return raw
    }

    static func normalizeProvider(_ raw: String?) -> String? {
        guard let raw, raw.hasPrefix("{"), let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return (obj["providerID"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    static func scan(database: any ParserStateStore = Database.shared) -> (turns: [TurnRecord], sessions: [SessionInfo]) {
        guard !ToolKind.opencode.sourceIsRemote else { return ([], []) }
        var turns: [TurnRecord] = []
        var sessions: [SessionInfo] = []
        let prevTotals = database.sessionTotals()
        // opencode stores ms timestamps; normalize to seconds.
        func sec(_ v: Int64) -> Int64 { v > 1_000_000_000_000 ? v / 1000 : v }
        func quality(_ row: Row) -> String {
            let tokens = row.input + row.output + row.reasoning + row.cacheRead + row.cacheWrite
            if row.cost == 0 && tokens > 0 { return "unknown" }
            return row.hasActualCost ? "actual" : "unknown"
        }
        let watermark = Int64(database.setting(watermarkKey) ?? "") ?? 0

        let read = forEachRow(since: watermark, database: database) { row in
            let key = "opencode|\(row.id)"
            let project = row.directory.isEmpty ? nil : (row.directory as NSString).lastPathComponent
            sessions.append(SessionInfo(tool: .opencode, sessionID: row.id, title: row.title.isEmpty ? nil : row.title,
                                        project: project, model: row.model, created: sec(row.timeCreated), updated: sec(row.timeUpdated)))

            let totalInput = row.input
            let legacyCombinedInput = prevTotals[key].map {
                FileScanner.tokenCount($0.reasoning) == 0 && row.reasoning > 0
                    && FileScanner.tokenCount($0.input) == row.input + row.reasoning
            } ?? false
            if let prev = prevTotals[key] {
                let dInput = (legacyCombinedInput ? row.input + row.reasoning : totalInput) - FileScanner.tokenCount(prev.input)
                let dOutput = row.output - FileScanner.tokenCount(prev.output)
                let dReasoning = legacyCombinedInput ? 0 : row.reasoning - FileScanner.tokenCount(prev.reasoning)
                let dCacheRead = row.cacheRead - FileScanner.tokenCount(prev.cacheRead)
                let dCacheWrite = row.cacheWrite - FileScanner.tokenCount(prev.cacheWrite)
                let dCost = row.cost - prev.cost
                let turn = TurnRecord(tool: .opencode, sessionID: row.id, project: project,
                                      model: row.model, ts: sec(row.timeUpdated),
                                      inputTokens: max(dInput, 0), outputTokens: max(dOutput, 0),
                                      reasoningTokens: max(dReasoning, 0),
                                      cacheRead: max(dCacheRead, 0), cacheWrite: max(dCacheWrite, 0),
                                      cost: max(dCost, 0), provider: row.provider,
                                      eventID: "opencode:\(row.id):\(row.timeUpdated):\(totalInput):\(row.output):\(row.reasoning):\(row.cacheRead):\(row.cacheWrite)",
                                      costQuality: quality(row))
                if turn.inputTokens + turn.outputTokens + turn.reasoningTokens + turn.cacheRead + turn.cacheWrite > 0 {
                    turns.append(turn)
                }
            } else if totalInput > 0 || row.output > 0 || row.reasoning > 0 || row.cacheRead > 0 || row.cacheWrite > 0 {
                // First sighting: record the full totals as one turn (backfill).
                // ts uses the REAL last-update time so history lands on its
                // true day instead of today.
                turns.append(TurnRecord(tool: .opencode, sessionID: row.id, project: project,
                                        model: row.model, ts: sec(row.timeUpdated),
                                        inputTokens: totalInput, outputTokens: row.output,
                                        reasoningTokens: row.reasoning,
                                        cacheRead: row.cacheRead, cacheWrite: row.cacheWrite, cost: row.cost,
                                        provider: row.provider,
                                        eventID: "opencode:\(row.id):\(row.timeUpdated):\(totalInput):\(row.output):\(row.reasoning):\(row.cacheRead):\(row.cacheWrite)",
                                        costQuality: quality(row)))
            }
            // Cost-only changes without token growth are intentionally not imported.
            // Keep high-water counters across rollbacks. On the legacy transition,
            // adopt the split input/reasoning baseline once so future input growth
            // is not consumed by the old combined value.
            let prev = prevTotals[key]
            database.setSessionTotals(key, tool: "opencode",
                                     input: legacyCombinedInput ? row.input : max(prev?.input ?? 0, totalInput),
                                     output: max(prev?.output ?? 0, row.output),
                                     reasoning: legacyCombinedInput ? row.reasoning : max(prev?.reasoning ?? 0, row.reasoning),
                                     cacheRead: max(prev?.cacheRead ?? 0, row.cacheRead),
                                     cacheWrite: max(prev?.cacheWrite ?? 0, row.cacheWrite),
                                     cost: max(prev?.cost ?? 0, row.cost),
                                     updated: sec(row.timeUpdated))
        }
        if read.failed { return ([], []) }
        guard read.count > 0 else { return ([], []) }
        if read.maxUpdated > watermark {
            database.setSetting(watermarkKey, "\(read.maxUpdated)")
        }
        return (turns, sessions)
    }
}
