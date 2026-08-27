import Foundation
import SQLite3

/// OpenCode parser (modern format): ~/.local/share/opencode/opencode.db
/// `session` table carries cumulative totals: cost, tokens_input/output/reasoning/cache_read/cache_write.
/// We compute per-scan deltas against session_totals to build turn records.
enum OpenCodeParser {

    static var dbPath: String {
        // Env override mirrors HermesParser (HERMES_HOME) / DSHParser
        // (DSH_HOME) so tests and alternate installs can redirect the source.
        if let h = ProcessInfo.processInfo.environment["OPENCODE_HOME"], !h.isEmpty {
            return (h as NSString).appendingPathComponent("opencode.db")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/opencode/opencode.db").path
    }

    struct Row {
        let id: String
        let title: String
        let directory: String
        let model: String?
        let provider: String?
        let cost: Double
        let input: Int64
        let output: Int64
        let reasoning: Int64
        let cacheRead: Int64
        let cacheWrite: Int64
        let timeCreated: Int64
        let timeUpdated: Int64
    }

    static func readRows() -> [Row] {
        var out: [Row] = []
        guard FileManager.default.fileExists(atPath: dbPath) else { return [] }
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        let sql = """
        SELECT id, COALESCE(title,''), COALESCE(directory,''), model, cost,
               tokens_input, tokens_output, tokens_reasoning, tokens_cache_read, tokens_cache_write,
               time_created, time_updated FROM session;
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let col = { (i: Int32) -> String in String(cString: sqlite3_column_text(stmt, i)) }
            let model: String? = sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : col(3)
            out.append(Row(id: col(0), title: col(1), directory: col(2), model: normalizeModel(model),
                           provider: normalizeProvider(model),
                           cost: sqlite3_column_double(stmt, 4),
                           input: sqlite3_column_int64(stmt, 5),
                           output: sqlite3_column_int64(stmt, 6),
                           reasoning: sqlite3_column_int64(stmt, 7),
                           cacheRead: sqlite3_column_int64(stmt, 8),
                           cacheWrite: sqlite3_column_int64(stmt, 9),
                           timeCreated: sqlite3_column_int64(stmt, 10),
                           timeUpdated: sqlite3_column_int64(stmt, 11)))
        }
        return out
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
        guard !ToolKind.opencode.sourceIsRemote else { return ([], []) } // source = VPS feed
        var turns: [TurnRecord] = []
        var sessions: [SessionInfo] = []
        let rows = readRows()
        guard !rows.isEmpty else { return ([], []) }

        let prevTotals = database.sessionTotals()
        // opencode stores ms timestamps; normalize to seconds (P1).
        func sec(_ v: Int64) -> Int64 { v > 1_000_000_000_000 ? v / 1000 : v }

        for row in rows {
            let key = "opencode|\(row.id)"
            let project = row.directory.isEmpty ? nil : (row.directory as NSString).lastPathComponent
            sessions.append(SessionInfo(tool: .opencode, sessionID: row.id, title: row.title.isEmpty ? nil : row.title,
                                        project: project, model: row.model, created: sec(row.timeCreated), updated: sec(row.timeUpdated)))

            let totalInput = row.input
            if let prev = prevTotals[key] {
                let legacyCombinedInput = prev.reasoning == 0
                    && row.reasoning > 0 && prev.input == row.input + row.reasoning
                let dInput = (legacyCombinedInput ? row.input + row.reasoning : totalInput) - prev.input
                let dOutput = row.output - prev.output
                let dReasoning = legacyCombinedInput ? 0 : row.reasoning - prev.reasoning
                let dCacheRead = row.cacheRead - prev.cacheRead
                let dCacheWrite = row.cacheWrite - prev.cacheWrite
                let dCost = row.cost - prev.cost
                let turn = TurnRecord(tool: .opencode, sessionID: row.id, project: project,
                                      model: row.model, ts: sec(row.timeUpdated),
                                      inputTokens: max(dInput, 0), outputTokens: max(dOutput, 0),
                                      reasoningTokens: max(dReasoning, 0),
                                      cacheRead: max(dCacheRead, 0), cacheWrite: max(dCacheWrite, 0),
                                      cost: max(dCost, 0), provider: row.provider,
                                      eventID: "opencode:\(row.id):\(row.timeUpdated):\(totalInput):\(row.output):\(row.reasoning):\(row.cacheRead):\(row.cacheWrite)",
                                      costQuality: "actual")
                if turn.inputTokens + turn.outputTokens + turn.reasoningTokens + turn.cacheRead + turn.cacheWrite > 0 {
                    turns.append(turn)
                }
            } else if totalInput > 0 || row.output > 0 || row.reasoning > 0 {
                // First sighting: record the full totals as one turn (backfill).
                // ts uses the REAL last-update time so history lands on its
                // true day instead of today (P1).
                turns.append(TurnRecord(tool: .opencode, sessionID: row.id, project: project,
                                        model: row.model, ts: sec(row.timeUpdated),
                                        inputTokens: totalInput, outputTokens: row.output,
                                        reasoningTokens: row.reasoning,
                                        cacheRead: row.cacheRead, cacheWrite: row.cacheWrite, cost: row.cost,
                                        provider: row.provider,
                                        eventID: "opencode:\(row.id):\(row.timeUpdated):\(totalInput):\(row.output):\(row.reasoning):\(row.cacheRead):\(row.cacheWrite)",
                                        costQuality: "actual"))
            }
            // The baseline is the HIGH-WATER MARK per counter, never the raw
            // current value: a source rollback (totals dropping) must not
            // reset the origin, or the later regrowth would be re-counted
            // from the rolled-back value. max() also absorbs the legacy
            // combined-input transition (prev.input == input + reasoning),
            // where prev.input exceeds the split current values.
            let prev = prevTotals[key]
            database.setSessionTotals(key, tool: "opencode",
                                     input: max(prev?.input ?? 0, totalInput),
                                     output: max(prev?.output ?? 0, row.output),
                                     reasoning: max(prev?.reasoning ?? 0, row.reasoning),
                                     cacheRead: max(prev?.cacheRead ?? 0, row.cacheRead),
                                     cacheWrite: max(prev?.cacheWrite ?? 0, row.cacheWrite),
                                     cost: max(prev?.cost ?? 0, row.cost),
                                     updated: sec(row.timeUpdated))
        }
        return (turns, sessions)
    }
}
