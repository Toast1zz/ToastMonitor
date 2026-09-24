import Foundation
import SQLite3

/// Hermes parser: $HERMES_HOME/state.db (or ~/.hermes/state.db).
/// Schema varies by version — we introspect columns and adapt.
/// The user's Mac typically has no local Hermes install; this parser no-ops gracefully.
enum HermesParser {

    static var home: String {
        if let h = ProcessInfo.processInfo.environment["HERMES_HOME"], !h.isEmpty { return h }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes").path
    }

    /// The default profile's store.
    static var dbPath: String { (home as NSString).appendingPathComponent("state.db") }

    /// Every profile's store: the default one, then `profiles/<name>/state.db`
    /// (each named profile keeps its own sessions and usage).
    static var dbPaths: [String] {
        let fm = FileManager.default
        let profiles = (home as NSString).appendingPathComponent("profiles")
        let named = ((try? fm.contentsOfDirectory(atPath: profiles)) ?? [])
            .filter { !$0.hasPrefix(".") }
            .sorted()
            .map { ((profiles as NSString).appendingPathComponent($0) as NSString)
                .appendingPathComponent("state.db") }
        return ([dbPath] + named).filter { fm.fileExists(atPath: $0) }
    }

    struct SessionRow {
        let id: String
        let title: String?
        let createdAt: Int64
        let updatedAt: Int64
        let input: Int64
        let output: Int64
    }

    static func scan(database: any ParserStateStore = Database.shared) -> (turns: [TurnRecord], sessions: [SessionInfo]) {
        guard !ToolKind.hermes.sourceIsRemote else { return ([], []) } // source = VPS feed
        var turns: [TurnRecord] = []
        var sessions: [SessionInfo] = []
        for path in dbPaths {
            let out = scan(path: path, database: database)
            turns += out.turns
            sessions += out.sessions
        }
        return (turns, sessions)
    }

    private static func scan(path: String, database: any ParserStateStore) -> (turns: [TurnRecord], sessions: [SessionInfo]) {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return ([], [])
        }
        defer { sqlite3_close(db) }

        // Introspect tables.
        var hasMessages = false
        var hasSessions = false
        var hasUsage = false
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type='table';", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let name = String(cString: sqlite3_column_text(stmt, 0))
                if name == "messages" { hasMessages = true }
                if name == "sessions" { hasSessions = true }
                if name == "session_model_usage" { hasUsage = true }
            }
        }
        sqlite3_finalize(stmt)
        guard hasMessages || hasSessions || hasUsage else { return ([], []) }

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

        // Current Hermes keeps cumulative usage per (session, model, billing
        // route); per-message token columns only exist in old versions.
        if hasUsage {
            turns += scanUsage(db: db, database: database)
            return (turns, sessions)
        }

        // Per-message token usage when columns exist (legacy schema).
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
                                         reasoning: 0,
                                         cacheRead: 0, cacheWrite: 0, cost: 0, updated: agg.lastTs)
            }
        }
        return (turns, sessions)
    }

    /// Deltas from `session_model_usage`, the same cumulative rows the VPS
    /// feed exports. Baselines are shared with the remote importer, so
    /// switching the Hermes source never recounts a session.
    private static func scanUsage(db: OpaquePointer?, database: any ParserStateStore) -> [TurnRecord] {
        let cols = Set(columns(of: "session_model_usage", db: db))
        let required = ["session_id", "input_tokens", "output_tokens", "last_seen"]
        guard required.allSatisfy(cols.contains) else { return [] }
        func col(_ name: String, _ fallback: String) -> String { cols.contains(name) ? name : fallback }
        let sql = """
        SELECT session_id, \(col("model", "NULL")), \(col("billing_provider", "NULL")),
               \(col("billing_base_url", "NULL")), input_tokens, output_tokens,
               \(col("reasoning_tokens", "0")), \(col("cache_read_tokens", "0")),
               \(col("cache_write_tokens", "0")), \(col("first_seen", "last_seen")), last_seen
        FROM session_model_usage;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        func text(_ i: Int32) -> String? {
            sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, i))
        }
        func seconds(_ i: Int32) -> Int64 {
            let v = sqlite3_column_double(stmt, i)
            guard v.isFinite, v > 0 else { return 0 }
            return Int64(v > 1_000_000_000_000 ? v / 1000 : v)
        }
        let totals = database.sessionTotals()
        var turns: [TurnRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let sid = text(0), !sid.isEmpty else { continue }
            let model = text(1)
            let provider = text(2)
            let current = HermesUsageBaseline.Counters(
                input: max(sqlite3_column_int64(stmt, 4), 0),
                output: max(sqlite3_column_int64(stmt, 5), 0),
                reasoning: max(sqlite3_column_int64(stmt, 6), 0),
                cacheRead: max(sqlite3_column_int64(stmt, 7), 0),
                cacheWrite: max(sqlite3_column_int64(stmt, 8), 0))
            let lastSeen = seconds(10)
            let firstSeen = min(seconds(9), lastSeen)
            let key = HermesUsageBaseline.key(session: sid, model: model, provider: provider,
                                              baseURL: text(3))
            let localKey = HermesUsageBaseline.localTotalsKey(key)
            let prev = totals[localKey].map { [$0.input, $0.output, $0.reasoning, $0.cacheRead, $0.cacheWrite, 0] }
                ?? HermesUsageBaseline.parse(database.setting(key))
            let step = HermesUsageBaseline.advance(current: current, prev: prev)
            let d = step.delta
            if d.input > 0 || d.output > 0 || d.reasoning > 0 || d.cacheRead > 0 || d.cacheWrite > 0 {
                // A first sighting is the session's whole history: date it
                // to the session start, not to now.
                let ts = step.isFirst && firstSeen > 0 ? firstSeen : lastSeen
                turns.append(TurnRecord(tool: .hermes, sessionID: sid, project: nil, model: model,
                                        ts: ts > 0 ? ts : Int64(Date().timeIntervalSince1970),
                                        inputTokens: d.input, outputTokens: d.output,
                                        reasoningTokens: d.reasoning,
                                        cacheRead: d.cacheRead, cacheWrite: d.cacheWrite, cost: 0,
                                        provider: provider,
                                        eventID: "hermes-local:\(key):\(current.input):\(current.output):\(current.cacheRead)",
                                        costQuality: "unknown"))
            }
            let b = step.base
            database.setSessionTotals(localKey, tool: "hermes", input: b.input, output: b.output,
                                      reasoning: b.reasoning, cacheRead: b.cacheRead,
                                      cacheWrite: b.cacheWrite, cost: 0, updated: lastSeen)
        }
        return turns
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

/// Hermes reports usage as cumulative counters per (session, model, billing
/// route). Both the local parser and the remote feed turn them into deltas
/// against a stored high-water baseline under the same key, and each reads
/// the other's baseline, so a session is counted once whichever source is on.
enum HermesUsageBaseline {
    struct Counters: Equatable {
        var input: Int64
        var output: Int64
        var reasoning: Int64
        var cacheRead: Int64
        var cacheWrite: Int64
    }

    /// Remote baselines live in settings under this key. base_url is
    /// normalized because Hermes flips its trailing slash on route changes.
    static func key(session: String, model: String?, provider: String?, baseURL: String?) -> String {
        let url = (baseURL ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return "hm_d|\(session)|\(model ?? "")|\(provider ?? "")|\(url)"
    }

    /// Local baselines live in session_totals (tool "hermes").
    static func localTotalsKey(_ key: String) -> String { "hermes|usage|\(key)" }

    static func parse(_ stored: String?) -> [Int64] {
        (stored ?? "").split(separator: ",").map { Int64($0) ?? 0 }
    }

    static func encode(_ base: Counters) -> String {
        [base.input, base.output, base.reasoning, base.cacheRead, base.cacheWrite, 0]
            .map(String.init).joined(separator: ",")
    }

    /// `prev` is a stored baseline: 6 values, or the legacy 5 whose input
    /// included reasoning; anything else means the key was never seen.
    static func advance(current c: Counters, prev: [Int64]) -> (delta: Counters, base: Counters, isFirst: Bool) {
        switch prev.count {
        case 6:
            let delta = Counters(input: max(c.input - prev[0], 0), output: max(c.output - prev[1], 0),
                                 reasoning: max(c.reasoning - prev[2], 0),
                                 cacheRead: max(c.cacheRead - prev[3], 0),
                                 cacheWrite: max(c.cacheWrite - prev[4], 0))
            let base = Counters(input: max(c.input, prev[0]), output: max(c.output, prev[1]),
                                reasoning: max(c.reasoning, prev[2]),
                                cacheRead: max(c.cacheRead, prev[3]),
                                cacheWrite: max(c.cacheWrite, prev[4]))
            return (delta, base, false)
        case 5:
            // Claim the legacy baseline without replaying historical
            // reasoning as a new delta.
            let delta = Counters(input: max(c.input + c.reasoning - prev[0], 0),
                                 output: max(c.output - prev[1], 0), reasoning: 0,
                                 cacheRead: max(c.cacheRead - prev[2], 0),
                                 cacheWrite: max(c.cacheWrite - prev[3], 0))
            return (delta, c, false)
        default:
            return (c, c, true)
        }
    }
}
