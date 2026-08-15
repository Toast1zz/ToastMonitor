import Foundation
import SQLite3

/// Hermes parser: $HERMES_HOME/state.db (or ~/.hermes/state.db).
/// Schema varies by version — we introspect columns and adapt.
/// The user's Mac typically has no local Hermes install; this parser no-ops gracefully.
enum HermesParser {

    static var dbPath: String {
        if let h = ProcessInfo.processInfo.environment["HERMES_HOME"], !h.isEmpty {
            return (h as NSString).appendingPathComponent("state.db")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".hermes/state.db").path
    }

    struct SessionRow {
        let id: String
        let title: String?
        let createdAt: Int64
        let updatedAt: Int64
        let input: Int64
        let output: Int64
    }

    static func scan(database: Database = .shared) -> (turns: [TurnRecord], sessions: [SessionInfo]) {
        guard !ToolKind.hermes.sourceIsRemote else { return ([], []) } // source = VPS feed
        guard FileManager.default.fileExists(atPath: dbPath) else { return ([], []) }

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return ([], []) }
        defer { sqlite3_close(db) }

        // Introspect tables.
        var hasMessages = false
        var hasSessions = false
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type='table';", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let name = String(cString: sqlite3_column_text(stmt, 0))
                if name == "messages" { hasMessages = true }
                if name == "sessions" { hasSessions = true }
            }
        }
        sqlite3_finalize(stmt)
        guard hasMessages || hasSessions else { return ([], []) }

        // Column introspection for messages.
        var tokenCols: [String: String] = [:] // kind -> column name
        var sessionCol: String? = nil
        var timeCols: [String] = []
        if hasMessages {
            let cols = columns(of: "messages", db: db)
            for c in cols {
                switch c {
                case "token_in", "input_tokens", "tokens_in", "prompt_tokens": tokenCols["input"] = c
                case "token_out", "output_tokens", "tokens_out", "completion_tokens": tokenCols["output"] = c
                case "session_id", "session": sessionCol = c
                case "created_at", "timestamp", "ts": timeCols.append(c)
                default: break
                }
            }
        }

        var sessions: [SessionInfo] = []
        var turns: [TurnRecord] = []
        func sec(_ value: Int64) -> Int64 {
            value > 1_000_000_000_000 ? value / 1000 : value
        }

        // Session metadata.
        if hasSessions {
            let cols = columns(of: "sessions", db: db)
            let idCol = cols.contains("id") ? "id" : (cols.contains("session_id") ? "session_id" : "")
            if !idCol.isEmpty {
                var titleCol = "NULL"
                if cols.contains("title") { titleCol = "title" }
                var createdCol = "0", updatedCol = "0"
                if cols.contains("created_at") { createdCol = "created_at" }
                if cols.contains("updated_at") { updatedCol = "updated_at" }
                let sql = "SELECT \(idCol), \(titleCol), \(createdCol), \(updatedCol) FROM sessions;"
                if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                    while sqlite3_step(stmt) == SQLITE_ROW {
                        let sid = String(cString: sqlite3_column_text(stmt, 0))
                        let title = sqlite3_column_type(stmt, 1) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 1))
                        let created = sec(sqlite3_column_int64(stmt, 2))
                        let updated = sec(sqlite3_column_int64(stmt, 3))
                        sessions.append(SessionInfo(tool: .hermes, sessionID: sid, title: title,
                                                    project: nil, model: nil, created: created, updated: updated))
                    }
                }
                sqlite3_finalize(stmt)
            }
        }

        // Per-message token usage when columns exist.
        if hasMessages, let inCol = tokenCols["input"], let outCol = tokenCols["output"], let sCol = sessionCol {
            guard let timeCol = timeCols.first else {
                // We can still expose session metadata, but cannot place
                // usage on a trustworthy day without a message timestamp.
                return (turns, sessions)
            }
            let sql = "SELECT \(sCol), \(inCol), \(outCol), \(timeCol) FROM messages WHERE (\(inCol) IS NOT NULL AND \(inCol) > 0) OR (\(outCol) IS NOT NULL AND \(outCol) > 0);"
            var perSession: [String: (input: Int64, output: Int64, lastTs: Int64)] = [:]
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let sid = String(cString: sqlite3_column_text(stmt, 0))
                    // Corrupt/partially migrated rows must never create
                    // negative token deltas downstream.
                    let input = max(sqlite3_column_int64(stmt, 1), 0)
                    let output = max(sqlite3_column_int64(stmt, 2), 0)
                    let ts = sqlite3_column_type(stmt, 3) == SQLITE_NULL ? 0 : sec(sqlite3_column_int64(stmt, 3))
                    var agg = perSession[sid] ?? (0, 0, 0)
                    agg.input += input
                    agg.output += output
                    if ts > agg.lastTs { agg.lastTs = ts }
                    perSession[sid] = agg
                }
            }
            sqlite3_finalize(stmt)

            let prevTotals = database.sessionTotals()
            for (sid, agg) in perSession {
                let key = "hermes|\(sid)"
                let prev = prevTotals[key]
                if let prev {
                    let dIn = max(agg.input - prev.input, 0)
                    let dOut = max(agg.output - prev.output, 0)
                    if dIn > 0 || dOut > 0 {
                        turns.append(TurnRecord(tool: .hermes, sessionID: sid, project: nil, model: nil,
                                                ts: agg.lastTs > 0 ? agg.lastTs : Int64(Date().timeIntervalSince1970),
                                                inputTokens: dIn, outputTokens: dOut,
                                                cacheRead: 0, cacheWrite: 0, cost: 0,
                                                eventID: "hermes-local:\(sid):\(agg.lastTs):\(agg.input):\(agg.output)", costQuality: "unknown"))
                    }
                } else if agg.input > 0 || agg.output > 0 {
                    turns.append(TurnRecord(tool: .hermes, sessionID: sid, project: nil, model: nil,
                                            ts: agg.lastTs > 0 ? agg.lastTs : Int64(Date().timeIntervalSince1970),
                                            inputTokens: agg.input, outputTokens: agg.output,
                                            cacheRead: 0, cacheWrite: 0, cost: 0,
                                            eventID: "hermes-local:\(sid):\(agg.lastTs):\(agg.input):\(agg.output)", costQuality: "unknown"))
                }
                // Baseline is the HIGH-WATER MARK per counter: a source
                // rollback must not lower the origin, or the regrowth beyond
                // the old peak would be re-counted.
                database.setSessionTotals(key, tool: "hermes",
                                         input: max(prev?.input ?? 0, agg.input),
                                         output: max(prev?.output ?? 0, agg.output),
                                         cacheRead: 0, cacheWrite: 0, cost: 0, updated: agg.lastTs)
            }
        }
        return (turns, sessions)
    }

    private static func columns(of table: String, db: OpaquePointer?) -> [String] {
        var out: [String] = []
        var stmt: OpaquePointer?
        let sql = "PRAGMA table_info(\(table));"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return out }
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(String(cString: sqlite3_column_text(stmt, 1)))
        }
        sqlite3_finalize(stmt)
        return out
    }
}
