import Foundation
import SQLite3

/// Thread-safe SQLite store. WAL mode, single writer, batched transactions.
final class Database {
    static let shared = Database()
    static let subscriptionsDidChange = Notification.Name("ToastMonitorSubscriptionsDidChange")

    private var db: OpaquePointer?
    /// Recursive so inTransaction bodies can call locked writers directly.
    private let lock = NSRecursiveLock()
    /// Any failed write inside the current transaction aborts the whole ingest.
    /// Duplicate conflicts are intentionally ignored by the turns UPSERT,
    /// but prepare/step/ALTER/commit errors must never be silently committed.
    private var transactionWriteError = false
    private(set) var dbPath: String = ""

    private init() {}

    /// Opens (creating if needed) the store under Application Support.
    func open() {
        lock.lock(); defer { lock.unlock() }
        guard db == nil else { return }

        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("ToastMonitor", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        openLocked(dir.appendingPathComponent("toastmonitor.db").path)
    }

    /// Opens at an explicit path — tests use a temp file, never the real store.
    func openAt(_ path: String) {
        lock.lock(); defer { lock.unlock() }
        guard db == nil else { return }
        openLocked(path)
    }

    /// Test helper: isolated instance on a throwaway path.
    static func testInstance(path: String) -> Database {
        let d = Database()
        d.openAt(path)
        return d
    }

    private func openLocked(_ path: String) {
        let fm = FileManager.default
        let dir = (path as NSString).deletingLastPathComponent
        // Create with the private mode up front (attributesForDirectory) so
        // there is no window where the dir/file is world-readable.
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        // Usage metadata can reveal project names; keep the store private to
        // the current user even when the directory pre-existed.
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir)
        dbPath = path

        var handle: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            NSLog("[ToastMonitor] DB open failed: %s", sqlite3_errmsg(handle))
            return
        }
        db = handle
        sqlite3_busy_timeout(db, 3000) // WAL writers don't block, but reads
                                       // during a long migration would fail
                                       // fast without this; wait up to 3s.
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dbPath)
        exec("PRAGMA journal_mode=WAL;")
        exec("PRAGMA synchronous=NORMAL;")
        exec("PRAGMA foreign_keys=ON;")
        migrate()
        migrateDropLegacyTurnsUnique()
        // Legacy databases predate the subscriptions.end_date column.
        ensureColumn("end_date", "INTEGER NOT NULL DEFAULT 0", table: "subscriptions")
        // OpenCode upstream stored `model` as a JSON object
        // ({"id":...,"providerID":...}) in some versions; normalize any
        // already-imported rows once (idempotent, no-op afterwards).
        execChecked("""
        UPDATE sessions SET model = json_extract(model, '$.id')
        WHERE model IS NOT NULL AND model LIKE '{%' AND json_valid(model) = 1;
        UPDATE turns SET model = json_extract(model, '$.id')
        WHERE model IS NOT NULL AND model LIKE '{%' AND json_valid(model) = 1;
        """)
    }

    /// P0-3: rebuilds `turns` without the legacy compound UNIQUE constraint
    /// when SQLite's autoindex for it is still present. Data is preserved;
    /// the event_id index becomes the sole dedupe authority.
    private func migrateDropLegacyTurnsUnique() {
        lock.lock(); defer { lock.unlock() }
        guard let db else { return }
        guard sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK else {
            setUserVersion(0)
            return
        }
        // Databases created by versions before event_id/cost_quality existed
        // need the columns added before the table rebuild can copy rows.
        for (name, decl) in [("event_id", "TEXT"),
                             ("cost_quality", "TEXT NOT NULL DEFAULT 'estimated'"),
                             ("cache_read", "INTEGER NOT NULL DEFAULT 0"),
                             ("cache_write", "INTEGER NOT NULL DEFAULT 0")] {
            var colStmt: OpaquePointer?
            let check = "SELECT COUNT(*) FROM pragma_table_info('turns') WHERE name='\(name)';"
            guard sqlite3_prepare_v2(db, check, -1, &colStmt, nil) == SQLITE_OK else {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                setUserVersion(0)
                return
            }
            var exists = false
            if sqlite3_step(colStmt) == SQLITE_ROW { exists = sqlite3_column_int(colStmt, 0) > 0 }
            sqlite3_finalize(colStmt)
            if !exists && !execChecked("ALTER TABLE turns ADD COLUMN \(name) \(decl);") {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                setUserVersion(0)
                return
            }
        }
        var stmt: OpaquePointer?
        var n = 0
        if sqlite3_prepare_v2(db, "SELECT n FROM _tm_detect LIMIT 1;", -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW { n = Int(sqlite3_column_int64(stmt, 0)) }
            sqlite3_finalize(stmt)
        } else {
            // The temporary detector only exists for the connection that ran
            // the migration. Older databases may have been created before it
            // existed, so inspect the durable schema as a fallback.
            if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name='sqlite_autoindex_turns_1';", -1, &stmt, nil) == SQLITE_OK {
                if sqlite3_step(stmt) == SQLITE_ROW { n = Int(sqlite3_column_int64(stmt, 0)) }
                sqlite3_finalize(stmt)
            }
        }

        // Fresh installs (and already-migrated DBs) have the event_id column:
        // just make sure the dedupe index exists.
        if n == 0 {
            // A buggy pre-release may already contain duplicate event IDs.
            // Keep every row and make the later row's identity deterministic
            // before creating the unique index.
            let repairDuplicates = """
            UPDATE turns SET event_id = event_id || ':dedup:' || id
            WHERE event_id IS NOT NULL AND EXISTS (
              SELECT 1 FROM turns t2
              WHERE t2.tool = turns.tool AND t2.event_id = turns.event_id AND t2.id < turns.id
            );
            """
            if !execChecked(repairDuplicates)
                || !execChecked("CREATE UNIQUE INDEX IF NOT EXISTS idx_turns_event ON turns(tool, event_id) WHERE event_id IS NOT NULL;") {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                setUserVersion(0)
            } else if sqlite3_exec(db, "COMMIT;", nil, nil, nil) != SQLITE_OK {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                setUserVersion(0)
            }
            return
        }

        let statements = [
            "ALTER TABLE turns RENAME TO turns_legacy;",
            """
            CREATE TABLE turns (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              tool TEXT NOT NULL,
              session_id TEXT NOT NULL,
              project TEXT,
              model TEXT,
              ts INTEGER NOT NULL,
              input_tokens INTEGER NOT NULL DEFAULT 0,
              output_tokens INTEGER NOT NULL DEFAULT 0,
              cache_read INTEGER NOT NULL DEFAULT 0,
              cache_write INTEGER NOT NULL DEFAULT 0,
              cost REAL NOT NULL DEFAULT 0,
              event_id TEXT,
              cost_quality TEXT NOT NULL DEFAULT 'estimated'
            );
            """,
            """
            INSERT INTO turns (id, tool, session_id, project, model, ts, input_tokens, output_tokens, cache_read, cache_write, cost, event_id, cost_quality)
              SELECT id, tool, session_id, project, model, ts, input_tokens, output_tokens, cache_read, cache_write, cost, event_id, cost_quality FROM turns_legacy;
            """,
            """
            UPDATE turns SET
              event_id = 'derived:' || tool || ':' || session_id || ':' || ts || ':' || input_tokens || ':' || output_tokens || ':' || id,
              cost_quality = CASE WHEN tool='hermes' THEN 'unknown' ELSE COALESCE(NULLIF(cost_quality, ''), 'estimated') END
              WHERE event_id IS NULL;
            """,
            """
            UPDATE turns SET event_id = event_id || ':dedup:' || id
            WHERE event_id IS NOT NULL AND EXISTS (
              SELECT 1 FROM turns t2
              WHERE t2.tool = turns.tool AND t2.event_id = turns.event_id AND t2.id < turns.id
            );
            """,
            "DROP TABLE turns_legacy;",
            "CREATE INDEX IF NOT EXISTS idx_turns_ts ON turns(ts);",
            "CREATE INDEX IF NOT EXISTS idx_turns_tool ON turns(tool, ts);",
            // The legacy rebuild drops the fresh-install idx_turns_session
            // with turns_legacy; recreate it or session lookups go full-scan.
            "CREATE INDEX IF NOT EXISTS idx_turns_session ON turns(tool, session_id);",
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_turns_event ON turns(tool, event_id) WHERE event_id IS NOT NULL;"
        ]
        for sql in statements {
            var err: UnsafeMutablePointer<CChar>?
            if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
                let msg = err.map { String(cString: $0) } ?? "unknown"
                NSLog("[ToastMonitor] turns rebuild step failed: %@ (rolling back)", msg)
                if let err { sqlite3_free(err) }
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                // Keep the database at the pre-migration version so the next
                // launch retries the migration instead of treating a partial
                // schema as current.
                setUserVersion(0)
                return
            }
        }
        if sqlite3_exec(db, "COMMIT;", nil, nil, nil) != SQLITE_OK {
            sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            setUserVersion(0)
            return
        }
        NSLog("[ToastMonitor] turns table rebuilt without legacy UNIQUE")
    }

    private func migrate() {
        // Versioned migrations (spec §7): schema version tracked in
        // PRAGMA user_version; each version runs once, in order.
        let current = userVersion()
        if current < 1 {
            guard let db else { return }
            guard sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK else { return }
            let ok = execChecked("""
            CREATE TABLE IF NOT EXISTS turns (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          tool TEXT NOT NULL,
          session_id TEXT NOT NULL,
          project TEXT,
          model TEXT,
          ts INTEGER NOT NULL,
          input_tokens INTEGER NOT NULL DEFAULT 0,
          output_tokens INTEGER NOT NULL DEFAULT 0,
          cache_read INTEGER NOT NULL DEFAULT 0,
          cache_write INTEGER NOT NULL DEFAULT 0,
          cost REAL NOT NULL DEFAULT 0,
          event_id TEXT,
          cost_quality TEXT NOT NULL DEFAULT 'estimated'
        );
        CREATE INDEX IF NOT EXISTS idx_turns_ts ON turns(ts);
        CREATE INDEX IF NOT EXISTS idx_turns_tool ON turns(tool, ts);
        CREATE INDEX IF NOT EXISTS idx_turns_session ON turns(tool, session_id);

        CREATE TABLE IF NOT EXISTS sessions (
          tool TEXT NOT NULL,
          session_id TEXT NOT NULL,
          title TEXT,
          project TEXT,
          model TEXT,
          created INTEGER NOT NULL DEFAULT 0,
          updated INTEGER NOT NULL DEFAULT 0,
          PRIMARY KEY(tool, session_id)
        );

        CREATE TABLE IF NOT EXISTS scan_state (
          source TEXT PRIMARY KEY,
          size INTEGER NOT NULL DEFAULT 0,
          mtime INTEGER NOT NULL DEFAULT 0,
          identity INTEGER NOT NULL DEFAULT 0,
          last_scan INTEGER NOT NULL DEFAULT 0
        );

        CREATE TABLE IF NOT EXISTS session_totals (
          tool TEXT NOT NULL,
          session_id TEXT NOT NULL,
          input INTEGER NOT NULL DEFAULT 0,
          output INTEGER NOT NULL DEFAULT 0,
          cache_read INTEGER NOT NULL DEFAULT 0,
          cache_write INTEGER NOT NULL DEFAULT 0,
          cost REAL NOT NULL DEFAULT 0,
          updated INTEGER NOT NULL DEFAULT 0,
          PRIMARY KEY(tool, session_id)
        );

        CREATE TABLE IF NOT EXISTS openrouter_snapshots (
          ts INTEGER PRIMARY KEY,
          usage REAL NOT NULL DEFAULT 0,
          usage_daily REAL NOT NULL DEFAULT 0,
          usage_weekly REAL NOT NULL DEFAULT 0,
          usage_monthly REAL NOT NULL DEFAULT 0,
          limit_amount REAL,
          limit_remaining REAL,
          limit_reset TEXT,
          is_free_tier INTEGER NOT NULL DEFAULT 0,
          credits_total REAL,
          credits_usage REAL,
          account_usage REAL,
          account_balance REAL,
          is_management_key INTEGER NOT NULL DEFAULT 0
        );

        CREATE TABLE IF NOT EXISTS opencodego_snapshots (
          ts INTEGER PRIMARY KEY,
          rolling_pct REAL,
          rolling_reset INTEGER,
          weekly_pct REAL,
          weekly_reset INTEGER,
          monthly_pct REAL,
          monthly_reset INTEGER
        );

        CREATE TABLE IF NOT EXISTS subscriptions (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          name TEXT NOT NULL,
          plan TEXT NOT NULL DEFAULT '',
          start_date INTEGER NOT NULL DEFAULT 0,
          end_date INTEGER NOT NULL DEFAULT 0,
          cycle TEXT NOT NULL DEFAULT 'monthly',
          price REAL NOT NULL DEFAULT 0,
          currency TEXT NOT NULL DEFAULT 'USD'
        );

        -- P0-9 migration: rebuild id=0 rows with real auto-increment ids.
        INSERT INTO subscriptions (name, plan, start_date, cycle, price, currency)
        SELECT name, plan, start_date, cycle, price, currency FROM subscriptions WHERE id=0;
        DELETE FROM subscriptions WHERE id=0;

        -- P0-3: the event_id unique index is created AFTER the legacy table
        -- rebuild (see migrateDropLegacyTurnsUnique) — on legacy schemas the
        -- column does not exist yet and index creation would abort the batch.

        -- P0-3 migration: the legacy table-level UNIQUE(tool, session_id, ts,
        -- input, output) must go — it still swallows distinct events that
        -- share the same second and token counts. Rebuild the table without it.
        -- (Detected by the presence of SQLite's autoindex for that constraint.)
        CREATE TEMP TABLE IF NOT EXISTS _tm_detect (n INTEGER);
        DELETE FROM _tm_detect;
        INSERT INTO _tm_detect SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name='sqlite_autoindex_turns_1';
        -- The actual rebuild runs below in Swift (conditional, in a transaction).

        CREATE TABLE IF NOT EXISTS settings (
          k TEXT PRIMARY KEY,
          v TEXT
        );
        """) && setUserVersion(1)
            if ok {
                if sqlite3_exec(db, "COMMIT;", nil, nil, nil) != SQLITE_OK {
                    sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                    setUserVersion(0)
                }
            } else {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                setUserVersion(0)
            }
        }
        // Future versions: if current < 2 { ...; setUserVersion(2) }
    }

    private func userVersion() -> Int32 {
        guard let db else { return 0 }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        var v: Int32 = 0
        if sqlite3_step(stmt) == SQLITE_ROW { v = sqlite3_column_int(stmt, 0) }
        sqlite3_finalize(stmt)
        return v
    }

    @discardableResult
    private func setUserVersion(_ v: Int32) -> Bool {
        guard let db else { return false }
        let sql = "PRAGMA user_version = \(v);"
        return sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    private func exec(_ sql: String) {
        _ = execChecked(sql)
    }

    @discardableResult
    private func execChecked(_ sql: String) -> Bool {
        guard let db else { return false }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            if let err { NSLog("[ToastMonitor] SQL error: %s", err); sqlite3_free(err) }
            return false
        }
        return true
    }

    private func markTransactionWriteFailure() {
        guard let db, sqlite3_get_autocommit(db) == 0 else { return }
        transactionWriteError = true
    }

    // MARK: - Scans

    /// Inserts turn rows. Duplicates are ignored (by event_id when present,
    /// otherwise by the legacy compound key). Transaction-aware: joins an
    /// outer `inTransaction` instead of committing independently (P0-2).
    /// Returns false when the write failed (caller should roll back).
    @discardableResult
    func insertTurns(_ turns: [TurnRecord]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !turns.isEmpty else { return true }
        guard let db else { return false }
        let inTx = sqlite3_get_autocommit(db) == 0
        if !inTx {
            guard sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK else { return false }
        }
        var stmt: OpaquePointer?
        let sql = """
        INSERT INTO turns (tool, session_id, project, model, ts, input_tokens, output_tokens, cache_read, cache_write, cost, event_id, cost_quality)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT DO NOTHING;
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            if !inTx { sqlite3_exec(db, "ROLLBACK;", nil, nil, nil) }
            markTransactionWriteFailure()
            return false
        }
        var ok = true
        for t in turns {
            // Legacy rows without an upstream identity get a deterministic
            // derived one (the old compound key semantics) so replays still
            // dedupe, while upstream event_ids stay authoritative.
            let eid = t.eventID ?? "derived:\(t.tool.rawValue):\(t.sessionID):\(t.ts):\(t.inputTokens):\(t.outputTokens):\(t.cacheRead):\(t.cacheWrite):\(t.model ?? "")"
            sqlite3_bind_text(stmt, 1, (t.tool.rawValue as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, (t.sessionID as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, (t.project as NSString?)?.utf8String ?? nil, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 4, (t.model as NSString?)?.utf8String ?? nil, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 5, t.ts)
            sqlite3_bind_int64(stmt, 6, t.inputTokens)
            sqlite3_bind_int64(stmt, 7, t.outputTokens)
            sqlite3_bind_int64(stmt, 8, t.cacheRead)
            sqlite3_bind_int64(stmt, 9, t.cacheWrite)
            sqlite3_bind_double(stmt, 10, t.cost)
            sqlite3_bind_text(stmt, 11, (eid as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 12, (t.costQuality as NSString).utf8String, -1, SQLITE_TRANSIENT)
            let rc = sqlite3_step(stmt)
            if rc != SQLITE_DONE {
                NSLog("[ToastMonitor] insertTurns failed rc=%d", rc)
                ok = false
                markTransactionWriteFailure()
            }
            sqlite3_reset(stmt)
        }
        sqlite3_finalize(stmt)
        if !inTx {
            if ok {
                if sqlite3_exec(db, "COMMIT;", nil, nil, nil) != SQLITE_OK { ok = false; sqlite3_exec(db, "ROLLBACK;", nil, nil, nil) }
            } else { sqlite3_exec(db, "ROLLBACK;", nil, nil, nil) }
        }
        return ok
    }

    /// Runs a body inside one transaction. When the body returns false the
    /// transaction is rolled back and no cursor/watermark may advance (P0-2).
    /// Nested calls (body invoking inTransaction again) join the outer
    /// transaction instead of starting a second one.
    func inTransaction(_ body: () -> Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let db else { return false }
        let joined = sqlite3_get_autocommit(db) == 0
        if joined {
            // Already inside an outer transaction: participate, don't commit.
            return body()
        }
        guard sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK else { return false }
        transactionWriteError = false
        let ok = body()
        if ok && !transactionWriteError {
            if sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK {
                return true
            }
            NSLog("[ToastMonitor] ingestion COMMIT failed")
            if sqlite3_exec(db, "ROLLBACK;", nil, nil, nil) != SQLITE_OK {
                // Both COMMIT and ROLLBACK failed (persistent I/O error): the
                // connection is stuck in an open transaction. Every later
                // inTransaction would silently JOIN it and lose its writes,
                // so poison the connection instead — subsequent operations
                // fail loudly until the next open().
                NSLog("[ToastMonitor] ROLLBACK failed too; poisoning connection")
                sqlite3_close(db)
                self.db = nil
            }
        } else {
            NSLog("[ToastMonitor] ingestion transaction rolled back")
            sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
        }
        return false
    }

    @discardableResult
    func upsertSessions(_ sessions: [SessionInfo]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !sessions.isEmpty else { return true }
        guard let db else { return false }
        let inTx = sqlite3_get_autocommit(db) == 0
        if !inTx {
            guard sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK else { return false }
        }
        var stmt: OpaquePointer?
        let sql = """
        INSERT INTO sessions (tool, session_id, title, project, model, created, updated)
        VALUES (?,?,?,?,?,?,?)
        ON CONFLICT(tool, session_id) DO UPDATE SET
          title=COALESCE(NULLIF(excluded.title, ''), sessions.title),
          project=COALESCE(NULLIF(excluded.project, ''), sessions.project),
          model=COALESCE(NULLIF(excluded.model, ''), sessions.model),
          created=CASE
            WHEN sessions.created=0 THEN excluded.created
            WHEN excluded.created=0 THEN sessions.created
            ELSE MIN(sessions.created, excluded.created)
          END,
          updated=MAX(sessions.updated, excluded.updated);
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            if !inTx { sqlite3_exec(db, "ROLLBACK;", nil, nil, nil) }
            markTransactionWriteFailure()
            return false
        }
        var ok = true
        for s in sessions {
            sqlite3_bind_text(stmt, 1, (s.tool.rawValue as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, (s.sessionID as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, (s.title as NSString?)?.utf8String ?? nil, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 4, (s.project as NSString?)?.utf8String ?? nil, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 5, (s.model as NSString?)?.utf8String ?? nil, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 6, s.created)
            sqlite3_bind_int64(stmt, 7, s.updated)
            let rc = sqlite3_step(stmt)
            if rc != SQLITE_DONE {
                NSLog("[ToastMonitor] upsertSessions failed rc=%d", rc)
                ok = false
                markTransactionWriteFailure()
            }
            sqlite3_reset(stmt)
        }
        sqlite3_finalize(stmt)
        if !inTx {
            if ok {
                if sqlite3_exec(db, "COMMIT;", nil, nil, nil) != SQLITE_OK { ok = false; sqlite3_exec(db, "ROLLBACK;", nil, nil, nil) }
            } else { sqlite3_exec(db, "ROLLBACK;", nil, nil, nil) }
        }
        return ok
    }

    /// Current cumulative totals per session (for delta-based parsers).
    func sessionTotals() -> [String: (tool: String, input: Int64, output: Int64, cacheRead: Int64, cacheWrite: Int64, cost: Double)] {
        lock.lock(); defer { lock.unlock() }
        guard let db else { return [:] }
        var out: [String: (tool: String, input: Int64, output: Int64, cacheRead: Int64, cacheWrite: Int64, cost: Double)] = [:]
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT tool, session_id, input, output, cache_read, cache_write, cost FROM session_totals;", -1, &stmt, nil) == SQLITE_OK else { return out }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let tool = String(cString: sqlite3_column_text(stmt, 0))
            let sid = String(cString: sqlite3_column_text(stmt, 1))
            let key = "\(tool)|\(sid)"
            out[key] = (tool, sqlite3_column_int64(stmt, 2), sqlite3_column_int64(stmt, 3),
                        sqlite3_column_int64(stmt, 4), sqlite3_column_int64(stmt, 5), sqlite3_column_double(stmt, 6))
        }
        sqlite3_finalize(stmt)
        return out
    }

    @discardableResult
    func setSessionTotals(_ key: String, tool: String, input: Int64, output: Int64, cacheRead: Int64, cacheWrite: Int64, cost: Double, updated: Int64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let db else { return false }
        let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { markTransactionWriteFailure(); return false }
        var stmt: OpaquePointer?
        let sql = """
        INSERT INTO session_totals (tool, session_id, input, output, cache_read, cache_write, cost, updated)
        VALUES (?,?,?,?,?,?,?,?)
        ON CONFLICT(tool, session_id) DO UPDATE SET
          input=excluded.input, output=excluded.output, cache_read=excluded.cache_read,
          cache_write=excluded.cache_write, cost=excluded.cost, updated=excluded.updated;
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { markTransactionWriteFailure(); return false }
        sqlite3_bind_text(stmt, 1, (parts[0] as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, (parts[1] as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 3, input)
        sqlite3_bind_int64(stmt, 4, output)
        sqlite3_bind_int64(stmt, 5, cacheRead)
        sqlite3_bind_int64(stmt, 6, cacheWrite)
        sqlite3_bind_double(stmt, 7, cost)
        sqlite3_bind_int64(stmt, 8, updated)
        let rc = sqlite3_step(stmt)
        sqlite3_finalize(stmt)
        if rc != SQLITE_DONE { markTransactionWriteFailure(); return false }
        return true
    }

    func scanState(_ source: String) -> (size: Int64, mtime: Int64, identity: Int64, context: String?) {
        lock.lock(); defer { lock.unlock() }
        guard let db else { return (0, 0, 0, nil) }
        ensureColumn("context", "TEXT", table: "scan_state")
        ensureColumn("identity", "INTEGER NOT NULL DEFAULT 0", table: "scan_state")
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT size, mtime, identity, context FROM scan_state WHERE source=?;", -1, &stmt, nil) == SQLITE_OK else { return (0, 0, 0, nil) }
        sqlite3_bind_text(stmt, 1, (source as NSString).utf8String, -1, SQLITE_TRANSIENT)
        var out: (Int64, Int64, Int64, String?) = (0, 0, 0, nil)
        if sqlite3_step(stmt) == SQLITE_ROW {
            out = (sqlite3_column_int64(stmt, 0), sqlite3_column_int64(stmt, 1),
                   sqlite3_column_int64(stmt, 2),
                   sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 3)))
        }
        sqlite3_finalize(stmt)
        return out
    }

    @discardableResult
    func setScanState(_ source: String, size: Int64, mtime: Int64, identity: Int64 = 0, context: String? = nil) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let db else { return false }
        ensureColumn("context", "TEXT", table: "scan_state")
        ensureColumn("identity", "INTEGER NOT NULL DEFAULT 0", table: "scan_state")
        var stmt: OpaquePointer?
        let sql = "INSERT INTO scan_state (source, size, mtime, identity, context, last_scan) VALUES (?,?,?,?,?,?) ON CONFLICT(source) DO UPDATE SET size=excluded.size, mtime=excluded.mtime, identity=excluded.identity, context=excluded.context, last_scan=excluded.last_scan;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { markTransactionWriteFailure(); return false }
        sqlite3_bind_text(stmt, 1, (source as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 2, size)
        sqlite3_bind_int64(stmt, 3, mtime)
        sqlite3_bind_int64(stmt, 4, identity)
        sqlite3_bind_text(stmt, 5, (context as NSString?)?.utf8String ?? nil, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 6, Int64(Date().timeIntervalSince1970))
        let rc = sqlite3_step(stmt)
        sqlite3_finalize(stmt)
        if rc != SQLITE_DONE { markTransactionWriteFailure(); return false }
        return true
    }

    /// Re-estimates cost for turns that have a model but zero cost
    /// (e.g. ingested before the model was known). Idempotent.
    func backfillCosts() {
        lock.lock(); defer { lock.unlock() }
        guard let db else { return }
        let now = Int64(Date().timeIntervalSince1970)
        if let last = Int64(setting("backfill_costs_last") ?? "0"), now - last < 60 { return }
        var stmt: OpaquePointer?
        let select = "SELECT id, model, input_tokens, output_tokens, cache_read, cache_write FROM turns WHERE cost=0 AND tool != 'hermes' AND model IS NOT NULL AND model != '';"
        guard sqlite3_prepare_v2(db, select, -1, &stmt, nil) == SQLITE_OK else { return }
        var rows: [(id: Int64, model: String, input: Int64, output: Int64, cr: Int64, cw: Int64)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append((sqlite3_column_int64(stmt, 0),
                         String(cString: sqlite3_column_text(stmt, 1)),
                         sqlite3_column_int64(stmt, 2), sqlite3_column_int64(stmt, 3),
                         sqlite3_column_int64(stmt, 4), sqlite3_column_int64(stmt, 5)))
        }
        sqlite3_finalize(stmt)
        guard !rows.isEmpty else { return }

        let update = "UPDATE turns SET cost=?, cost_quality=CASE WHEN cost_quality='unknown' THEN 'estimated' ELSE cost_quality END WHERE id=?;"
        guard sqlite3_prepare_v2(db, update, -1, &stmt, nil) == SQLITE_OK else { return }
        for r in rows {
            guard let cost = Pricing.estimate(model: r.model, input: r.input, output: r.output,
                                              cacheRead: r.cr, cacheWrite: r.cw) else { continue }
            sqlite3_bind_double(stmt, 1, cost)
            sqlite3_bind_int64(stmt, 2, r.id)
            if sqlite3_step(stmt) != SQLITE_DONE {
                NSLog("[ToastMonitor] cost backfill failed for turn id=%lld", r.id)
                markTransactionWriteFailure()
            }
            sqlite3_reset(stmt)
        }
        sqlite3_finalize(stmt)
        // Stamp the throttle only after the work actually ran, so a failed
        // backfill is retried on the next tick instead of waiting 60s.
        _ = setSetting("backfill_costs_last", "\(now)")
    }

    // MARK: - Settings

    func setting(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let db else { return nil }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT v FROM settings WHERE k=?;", -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(stmt, 1, (key as NSString).utf8String, -1, SQLITE_TRANSIENT)
        var out: String?
        if sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) {
            out = String(cString: c)
        }
        sqlite3_finalize(stmt)
        return out
    }

    @discardableResult
    func setSetting(_ key: String, _ value: String?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let db else { return false }
        var stmt: OpaquePointer?
        if let value {
            let sql = "INSERT INTO settings (k, v) VALUES (?,?) ON CONFLICT(k) DO UPDATE SET v=excluded.v;"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { markTransactionWriteFailure(); return false }
            sqlite3_bind_text(stmt, 1, (key as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, (value as NSString).utf8String, -1, SQLITE_TRANSIENT)
        } else {
            guard sqlite3_prepare_v2(db, "DELETE FROM settings WHERE k=?;", -1, &stmt, nil) == SQLITE_OK else { markTransactionWriteFailure(); return false }
            sqlite3_bind_text(stmt, 1, (key as NSString).utf8String, -1, SQLITE_TRANSIENT)
        }
        let rc = sqlite3_step(stmt)
        sqlite3_finalize(stmt)
        if rc != SQLITE_DONE { markTransactionWriteFailure(); return false }
        return true
    }

    // MARK: - Queries (UI)

    struct ToolTotals {
        var tool: String
        var input: Int64
        var output: Int64
        var cacheRead: Int64
        var cacheWrite: Int64
        var cost: Double
        var count: Int64
    }

    struct DayAgg {
        let day: Int64      // yyyymmdd as int
        let tool: String
        let input: Int64
        let output: Int64
        let cacheRead: Int64
        let cost: Double
    }

    struct ModelAgg: Identifiable {
        let tool: String
        let model: String
        let input: Int64
        let output: Int64
        let cacheRead: Int64
        let cost: Double
        let count: Int64

        var id: String { "\(tool)|\(model)" }
    }

    struct SessionRow: Hashable, Identifiable {
        let tool: String
        let sessionID: String
        let title: String?
        let project: String?
        let model: String?
        let created: Int64
        let updated: Int64
        let input: Int64
        let output: Int64
        let cacheRead: Int64
        let cost: Double
        let count: Int64

        var id: String { "\(tool)|\(sessionID)" }
    }

    struct ORSnapshot: Identifiable {
        let ts: Int64
        let usage: Double
        let usageDaily: Double
        let usageWeekly: Double
        let usageMonthly: Double
        let limit: Double?
        let limitRemaining: Double?
        let limitReset: String?
        let isFreeTier: Bool
        let creditsTotal: Double?
        let creditsUsage: Double?
        let accountUsage: Double?
        let accountBalance: Double?
        let isManagementKey: Bool

        var id: Int64 { ts }
    }

    /// Totals within [from, to] (unix seconds), optionally per tool.
    func totals(from: Int64, to: Int64, tool: ToolKind? = nil) -> ToolTotals {
        lock.lock(); defer { lock.unlock() }
        var out = ToolTotals(tool: tool?.rawValue ?? "all", input: 0, output: 0, cacheRead: 0, cacheWrite: 0, cost: 0, count: 0)
        guard let db else { return out }
        var sql = "SELECT SUM(input_tokens), SUM(output_tokens), SUM(cache_read), SUM(cache_write), SUM(cost), COUNT(*) FROM turns WHERE ts>=? AND ts<=?"
        if tool != nil { sql += " AND tool=?" }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return out }
        sqlite3_bind_int64(stmt, 1, from)
        sqlite3_bind_int64(stmt, 2, to)
        if let tool { sqlite3_bind_text(stmt, 3, (tool.rawValue as NSString).utf8String, -1, SQLITE_TRANSIENT) }
        if sqlite3_step(stmt) == SQLITE_ROW {
            out.input = sqlite3_column_int64(stmt, 0)
            out.output = sqlite3_column_int64(stmt, 1)
            out.cacheRead = sqlite3_column_int64(stmt, 2)
            out.cacheWrite = sqlite3_column_int64(stmt, 3)
            out.cost = sqlite3_column_double(stmt, 4)
            out.count = sqlite3_column_int64(stmt, 5)
        }
        sqlite3_finalize(stmt)
        return out
    }

    func totalsByTool(from: Int64, to: Int64) -> [ToolTotals] {
        lock.lock(); defer { lock.unlock() }
        var out: [ToolTotals] = []
        guard let db else { return out }
        var stmt: OpaquePointer?
        let sql = """
        SELECT tool, SUM(input_tokens), SUM(output_tokens), SUM(cache_read), SUM(cache_write), SUM(cost), COUNT(*)
        FROM turns WHERE ts>=? AND ts<=? GROUP BY tool ORDER BY SUM(cost) DESC;
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return out }
        sqlite3_bind_int64(stmt, 1, from)
        sqlite3_bind_int64(stmt, 2, to)
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(ToolTotals(
                tool: String(cString: sqlite3_column_text(stmt, 0)),
                input: sqlite3_column_int64(stmt, 1),
                output: sqlite3_column_int64(stmt, 2),
                cacheRead: sqlite3_column_int64(stmt, 3),
                cacheWrite: sqlite3_column_int64(stmt, 4),
                cost: sqlite3_column_double(stmt, 5),
                count: sqlite3_column_int64(stmt, 6)))
        }
        sqlite3_finalize(stmt)
        return out
    }

    /// Per-day aggregates: day = local yyyymmdd int.
    func dailyAggregates(days: Int) -> [DayAgg] {
        lock.lock(); defer { lock.unlock() }
        var out: [DayAgg] = []
        guard let db else { return out }
        let from = startOfDay(daysAgo: days - 1)
        var stmt: OpaquePointer?
        let sql = """
        SELECT CAST(strftime('%Y%m%d', ts, 'unixepoch', 'localtime') AS INTEGER) AS day, tool,
               SUM(input_tokens), SUM(output_tokens), SUM(cache_read), SUM(cost)
        FROM turns WHERE ts>=? GROUP BY day, tool;
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return out }
        sqlite3_bind_int64(stmt, 1, from)
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(DayAgg(
                day: sqlite3_column_int64(stmt, 0),
                tool: String(cString: sqlite3_column_text(stmt, 1)),
                input: sqlite3_column_int64(stmt, 2),
                output: sqlite3_column_int64(stmt, 3),
                cacheRead: sqlite3_column_int64(stmt, 4),
                cost: sqlite3_column_double(stmt, 5)))
        }
        sqlite3_finalize(stmt)
        return out
    }

    func modelAggregates(from: Int64, to: Int64) -> [ModelAgg] {
        lock.lock(); defer { lock.unlock() }
        var out: [ModelAgg] = []
        guard let db else { return out }
        var stmt: OpaquePointer?
        let sql = """
        SELECT tool, COALESCE(NULLIF(model,''), '(unknown)'), SUM(input_tokens), SUM(output_tokens), SUM(cache_read), SUM(cost), COUNT(*)
        FROM turns WHERE ts>=? AND ts<=? GROUP BY tool, model ORDER BY SUM(cost) DESC;
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return out }
        sqlite3_bind_int64(stmt, 1, from)
        sqlite3_bind_int64(stmt, 2, to)
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(ModelAgg(
                tool: String(cString: sqlite3_column_text(stmt, 0)),
                model: String(cString: sqlite3_column_text(stmt, 1)),
                input: sqlite3_column_int64(stmt, 2),
                output: sqlite3_column_int64(stmt, 3),
                cacheRead: sqlite3_column_int64(stmt, 4),
                cost: sqlite3_column_double(stmt, 5),
                count: sqlite3_column_int64(stmt, 6)))
        }
        sqlite3_finalize(stmt)
        return out
    }

    func sessions(tool: ToolKind? = nil, limit: Int = 100) -> [SessionRow] {
        lock.lock(); defer { lock.unlock() }
        var out: [SessionRow] = []
        guard let db else { return out }
        var sql = """
        SELECT s.tool, s.session_id, s.title, s.project, s.model, s.created, s.updated,
               COALESCE(SUM(t.input_tokens),0), COALESCE(SUM(t.output_tokens),0), COALESCE(SUM(t.cache_read),0), COALESCE(SUM(t.cost),0), COUNT(t.id)
        FROM sessions s LEFT JOIN turns t ON t.tool=s.tool AND t.session_id=s.session_id
        """
        if tool != nil { sql += " WHERE s.tool=?" }
        sql += " GROUP BY s.tool, s.session_id ORDER BY s.updated DESC LIMIT ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return out }
        var idx: Int32 = 1
        if let tool {
            sqlite3_bind_text(stmt, idx, (tool.rawValue as NSString).utf8String, -1, SQLITE_TRANSIENT)
            idx += 1
        }
        sqlite3_bind_int64(stmt, idx, Int64(limit))
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(SessionRow(
                tool: String(cString: sqlite3_column_text(stmt, 0)),
                sessionID: String(cString: sqlite3_column_text(stmt, 1)),
                title: colStr(stmt, 2),
                project: colStr(stmt, 3),
                model: colStr(stmt, 4),
                created: sqlite3_column_int64(stmt, 5),
                updated: sqlite3_column_int64(stmt, 6),
                input: sqlite3_column_int64(stmt, 7),
                output: sqlite3_column_int64(stmt, 8),
                cacheRead: sqlite3_column_int64(stmt, 9),
                cost: sqlite3_column_double(stmt, 10),
                count: sqlite3_column_int64(stmt, 11)))
        }
        sqlite3_finalize(stmt)
        return out
    }

    func turns(sessionTool: String, sessionID: String, limit: Int = 200) -> [(ts: Int64, model: String?, input: Int64, output: Int64, cacheRead: Int64, cacheWrite: Int64, cost: Double)] {
        lock.lock(); defer { lock.unlock() }
        var out: [(ts: Int64, model: String?, input: Int64, output: Int64, cacheRead: Int64, cacheWrite: Int64, cost: Double)] = []
        guard let db else { return out }
        var stmt: OpaquePointer?
        let sql = """
        SELECT ts, model, input_tokens, output_tokens, cache_read, cache_write, cost
        FROM turns WHERE tool=? AND session_id=? ORDER BY ts DESC LIMIT ?;
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return out }
        sqlite3_bind_text(stmt, 1, (sessionTool as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, (sessionID as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 3, Int64(limit))
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append((sqlite3_column_int64(stmt, 0), colStr(stmt, 1),
                        sqlite3_column_int64(stmt, 2), sqlite3_column_int64(stmt, 3),
                        sqlite3_column_int64(stmt, 4), sqlite3_column_int64(stmt, 5),
                        sqlite3_column_double(stmt, 6)))
        }
        sqlite3_finalize(stmt)
        return out
    }

    func orSnapshots(limit: Int = 500) -> [ORSnapshot] {
        lock.lock(); defer { lock.unlock() }
        var out: [ORSnapshot] = []
        guard let db else { return out }
        var stmt: OpaquePointer?
        let sql = """
        SELECT ts, usage, usage_daily, usage_weekly, usage_monthly, limit_amount, limit_remaining,
               limit_reset, is_free_tier, credits_total, credits_usage, account_usage, account_balance, is_management_key
        FROM openrouter_snapshots ORDER BY ts DESC LIMIT ?;
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return out }
        sqlite3_bind_int64(stmt, 1, Int64(limit))
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(ORSnapshot(
                ts: sqlite3_column_int64(stmt, 0),
                usage: sqlite3_column_double(stmt, 1),
                usageDaily: sqlite3_column_double(stmt, 2),
                usageWeekly: sqlite3_column_double(stmt, 3),
                usageMonthly: sqlite3_column_double(stmt, 4),
                limit: sqlite3_column_type(stmt, 5) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 5),
                limitRemaining: sqlite3_column_type(stmt, 6) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 6),
                limitReset: colStr(stmt, 7),
                isFreeTier: sqlite3_column_int(stmt, 8) != 0,
                creditsTotal: sqlite3_column_type(stmt, 9) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 9),
                creditsUsage: sqlite3_column_type(stmt, 10) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 10),
                accountUsage: sqlite3_column_type(stmt, 11) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 11),
                accountBalance: sqlite3_column_type(stmt, 12) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 12),
                isManagementKey: sqlite3_column_int(stmt, 13) != 0))
        }
        sqlite3_finalize(stmt)
        return out
    }

    @discardableResult
    func insertORSnapshot(_ s: ORSnapshot) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let db else { return false }
        // Migration for older DBs missing the account columns.
        ensureColumn("account_usage", "REAL", table: "openrouter_snapshots")
        ensureColumn("account_balance", "REAL", table: "openrouter_snapshots")
        ensureColumn("is_management_key", "INTEGER NOT NULL DEFAULT 0", table: "openrouter_snapshots")
        var stmt: OpaquePointer?
        let sql = """
        INSERT OR REPLACE INTO openrouter_snapshots
        (ts, usage, usage_daily, usage_weekly, usage_monthly, limit_amount, limit_remaining, limit_reset, is_free_tier, credits_total, credits_usage, account_usage, account_balance, is_management_key)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?);
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { markTransactionWriteFailure(); return false }
        sqlite3_bind_int64(stmt, 1, s.ts)
        sqlite3_bind_double(stmt, 2, s.usage)
        sqlite3_bind_double(stmt, 3, s.usageDaily)
        sqlite3_bind_double(stmt, 4, s.usageWeekly)
        sqlite3_bind_double(stmt, 5, s.usageMonthly)
        if let v = s.limit { sqlite3_bind_double(stmt, 6, v) } else { sqlite3_bind_null(stmt, 6) }
        if let v = s.limitRemaining { sqlite3_bind_double(stmt, 7, v) } else { sqlite3_bind_null(stmt, 7) }
        sqlite3_bind_text(stmt, 8, (s.limitReset as NSString?)?.utf8String ?? nil, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 9, s.isFreeTier ? 1 : 0)
        if let v = s.creditsTotal { sqlite3_bind_double(stmt, 10, v) } else { sqlite3_bind_null(stmt, 10) }
        if let v = s.creditsUsage { sqlite3_bind_double(stmt, 11, v) } else { sqlite3_bind_null(stmt, 11) }
        if let v = s.accountUsage { sqlite3_bind_double(stmt, 12, v) } else { sqlite3_bind_null(stmt, 12) }
        if let v = s.accountBalance { sqlite3_bind_double(stmt, 13, v) } else { sqlite3_bind_null(stmt, 13) }
        sqlite3_bind_int(stmt, 14, s.isManagementKey ? 1 : 0)
        let rc = sqlite3_step(stmt)
        sqlite3_finalize(stmt)
        if rc != SQLITE_DONE { markTransactionWriteFailure(); return false }
        return true
    }

    /// Adds a column if the table lacks it (idempotent migration).
    /// NOTE: caller must already hold the recursive lock.
    private func ensureColumn(_ name: String, _ decl: String, table: String) {
        guard let db else { return }
        var stmt: OpaquePointer?
        let check = "SELECT COUNT(*) FROM pragma_table_info('\(table)') WHERE name='\(name)';"
        guard sqlite3_prepare_v2(db, check, -1, &stmt, nil) == SQLITE_OK else { return }
        var exists = false
        if sqlite3_step(stmt) == SQLITE_ROW { exists = sqlite3_column_int(stmt, 0) > 0 }
        sqlite3_finalize(stmt)
        guard !exists else { return }
        if sqlite3_exec(db, "ALTER TABLE \(table) ADD COLUMN \(name) \(decl);", nil, nil, nil) != SQLITE_OK {
            markTransactionWriteFailure()
        }
    }

    // MARK: - OpenCode Go quota snapshots

    struct OGSnapshot: Identifiable {
        let ts: Int64
        let rollingPct: Double?
        let rollingReset: Int64?
        let weeklyPct: Double?
        let weeklyReset: Int64?
        let monthlyPct: Double?
        let monthlyReset: Int64?

        var id: Int64 { ts }
    }

    @discardableResult
    func insertOGSnapshot(_ s: OGSnapshot) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let db else { return false }
        var stmt: OpaquePointer?
        let sql = """
        INSERT OR REPLACE INTO opencodego_snapshots
        (ts, rolling_pct, rolling_reset, weekly_pct, weekly_reset, monthly_pct, monthly_reset)
        VALUES (?,?,?,?,?,?,?);
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { markTransactionWriteFailure(); return false }
        sqlite3_bind_int64(stmt, 1, s.ts)
        if let v = s.rollingPct { sqlite3_bind_double(stmt, 2, v) } else { sqlite3_bind_null(stmt, 2) }
        if let v = s.rollingReset { sqlite3_bind_int64(stmt, 3, v) } else { sqlite3_bind_null(stmt, 3) }
        if let v = s.weeklyPct { sqlite3_bind_double(stmt, 4, v) } else { sqlite3_bind_null(stmt, 4) }
        if let v = s.weeklyReset { sqlite3_bind_int64(stmt, 5, v) } else { sqlite3_bind_null(stmt, 5) }
        if let v = s.monthlyPct { sqlite3_bind_double(stmt, 6, v) } else { sqlite3_bind_null(stmt, 6) }
        if let v = s.monthlyReset { sqlite3_bind_int64(stmt, 7, v) } else { sqlite3_bind_null(stmt, 7) }
        let rc = sqlite3_step(stmt)
        sqlite3_finalize(stmt)
        if rc != SQLITE_DONE { markTransactionWriteFailure(); return false }
        return true
    }

    func ogSnapshots(limit: Int = 200) -> [OGSnapshot] {
        lock.lock(); defer { lock.unlock() }
        var out: [OGSnapshot] = []
        guard let db else { return out }
        var stmt: OpaquePointer?
        let sql = """
        SELECT ts, rolling_pct, rolling_reset, weekly_pct, weekly_reset, monthly_pct, monthly_reset
        FROM opencodego_snapshots ORDER BY ts DESC LIMIT ?;
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return out }
        sqlite3_bind_int64(stmt, 1, Int64(limit))
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(OGSnapshot(
                ts: sqlite3_column_int64(stmt, 0),
                rollingPct: optDouble(stmt, 1), rollingReset: optInt(stmt, 2),
                weeklyPct: optDouble(stmt, 3), weeklyReset: optInt(stmt, 4),
                monthlyPct: optDouble(stmt, 5), monthlyReset: optInt(stmt, 6)))
        }
        sqlite3_finalize(stmt)
        return out
    }

    private func optDouble(_ stmt: OpaquePointer?, _ idx: Int32) -> Double? {
        sqlite3_column_type(stmt, idx) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, idx)
    }

    private func optInt(_ stmt: OpaquePointer?, _ idx: Int32) -> Int64? {
        sqlite3_column_type(stmt, idx) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, idx)
    }

    // MARK: - Subscriptions (fixed-cost side)

    struct Subscription: Identifiable, Equatable {
        let id: Int64
        var name: String
        var plan: String      // "" | "go" | "openrouter" | "claude"
        var startDate: Int64  // unix seconds
        var endDate: Int64 = 0 // 0 = active; unix seconds when it ended/stops
        var cycle: String     // "monthly" | "yearly"
        var price: Double
        var currency: String
    }

    func subscriptions() -> [Subscription] {
        lock.lock(); defer { lock.unlock() }
        var out: [Subscription] = []
        guard let db else { return out }
        var stmt: OpaquePointer?
        let sql = "SELECT id, name, plan, start_date, end_date, cycle, price, currency FROM subscriptions ORDER BY start_date;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return out }
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(Subscription(
                id: sqlite3_column_int64(stmt, 0),
                name: String(cString: sqlite3_column_text(stmt, 1)),
                plan: String(cString: sqlite3_column_text(stmt, 2)),
                startDate: sqlite3_column_int64(stmt, 3),
                endDate: sqlite3_column_int64(stmt, 4),
                cycle: String(cString: sqlite3_column_text(stmt, 5)),
                price: sqlite3_column_double(stmt, 6),
                currency: String(cString: sqlite3_column_text(stmt, 7))))
        }
        sqlite3_finalize(stmt)
        return out
    }

    @discardableResult
    func upsertSubscription(_ s: Subscription) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let db else { return false }
        // Persistence-layer validation: the UI constrains inputs, but the DB
        // must not accept values that would crash calendar math or produce
        // meaningless records (negative price, absurd magnitude, end < start,
        // unknown cycle).
        guard s.price.isFinite, s.price >= 0, s.price < 1_000_000,
              s.startDate > 0,
              s.endDate == 0 || s.endDate > s.startDate,
              s.cycle == "monthly" || s.cycle == "yearly" || s.cycle == "weekly",
              s.startDate < 4_102_444_800 else { // year 2100
            return false
        }
        var stmt: OpaquePointer?
        if s.id == 0 {
            // New record: let SQLite assign the id (P0-9).
            let sql = "INSERT INTO subscriptions (name, plan, start_date, end_date, cycle, price, currency) VALUES (?,?,?,?,?,?,?);"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { markTransactionWriteFailure(); return false }
            sqlite3_bind_text(stmt, 1, (s.name as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, (s.plan as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 3, s.startDate)
            sqlite3_bind_int64(stmt, 4, s.endDate)
            sqlite3_bind_text(stmt, 5, (s.cycle as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 6, s.price)
            sqlite3_bind_text(stmt, 7, (s.currency as NSString).utf8String, -1, SQLITE_TRANSIENT)
            let rc = sqlite3_step(stmt)
            sqlite3_finalize(stmt)
            guard rc == SQLITE_DONE else { markTransactionWriteFailure(); return false }
            NotificationCenter.default.post(name: Self.subscriptionsDidChange, object: nil)
            return true
        }
        let sql = """
        INSERT INTO subscriptions (id, name, plan, start_date, end_date, cycle, price, currency)
        VALUES (?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET name=excluded.name, plan=excluded.plan,
          start_date=excluded.start_date, end_date=excluded.end_date,
          cycle=excluded.cycle, price=excluded.price, currency=excluded.currency;
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { markTransactionWriteFailure(); return false }
        sqlite3_bind_int64(stmt, 1, s.id)
        sqlite3_bind_text(stmt, 2, (s.name as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, (s.plan as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 4, s.startDate)
        sqlite3_bind_int64(stmt, 5, s.endDate)
        sqlite3_bind_text(stmt, 6, (s.cycle as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 7, s.price)
        sqlite3_bind_text(stmt, 8, (s.currency as NSString).utf8String, -1, SQLITE_TRANSIENT)
        let rc = sqlite3_step(stmt)
        sqlite3_finalize(stmt)
        guard rc == SQLITE_DONE else { markTransactionWriteFailure(); return false }
        NotificationCenter.default.post(name: Self.subscriptionsDidChange, object: nil)
        return true
    }

    @discardableResult
    func deleteSubscription(id: Int64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let db else { return false }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM subscriptions WHERE id=?;", -1, &stmt, nil) == SQLITE_OK else { markTransactionWriteFailure(); return false }
        sqlite3_bind_int64(stmt, 1, id)
        let rc = sqlite3_step(stmt)
        sqlite3_finalize(stmt)
        guard rc == SQLITE_DONE else { markTransactionWriteFailure(); return false }
        NotificationCenter.default.post(name: Self.subscriptionsDidChange, object: nil)
        return true
    }

    /// OpenRouter spend since a timestamp: sum of per-UTC-day maxima from the
    /// snapshot history. For a cycle that starts mid-day, subtract the latest
    /// pre-cycle cumulative value from that first day's maximum so a complete
    /// day's usage is not incorrectly attributed to the cycle.
    func orSpendSince(_ start: Int64) -> Double {
        lock.lock(); defer { lock.unlock() }
        guard let db else { return 0 }
        var stmt: OpaquePointer?
        let startDay = start / 86400
        var baseline: Double = 0
        let baselineSQL = "SELECT usage_daily FROM openrouter_snapshots WHERE ts < ? AND ts / 86400 = ? ORDER BY ts DESC LIMIT 1;"
        if sqlite3_prepare_v2(db, baselineSQL, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int64(stmt, 1, start)
            sqlite3_bind_int64(stmt, 2, startDay)
            if sqlite3_step(stmt) == SQLITE_ROW { baseline = sqlite3_column_double(stmt, 0) }
            sqlite3_finalize(stmt)
        }
        let sql = """
        SELECT ts / 86400 AS utc_day, MAX(usage_daily) FROM openrouter_snapshots
        WHERE ts >= ? GROUP BY utc_day;
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        sqlite3_bind_int64(stmt, 1, start)
        var total: Double = 0
        while sqlite3_step(stmt) == SQLITE_ROW {
            let day = sqlite3_column_int64(stmt, 0)
            let maxDaily = sqlite3_column_double(stmt, 1)
            total += day == startDay ? max(maxDaily - baseline, 0) : maxDaily
        }
        sqlite3_finalize(stmt)
        return total
    }

    /// Daily aggregates grouped by (day, model) for the model grouping view.
    func dailyAggregatesByModel(days: Int) -> [(day: Int64, model: String, input: Int64, output: Int64, cacheRead: Int64, cost: Double)] {
        lock.lock(); defer { lock.unlock() }
        guard let db else { return [] }
        let since = startOfDay(daysAgo: max(days - 1, 0))
        var stmt: OpaquePointer?
        let sql = """
        SELECT CAST(strftime('%Y%m%d', ts, 'unixepoch', 'localtime') AS INTEGER) AS day,
               COALESCE(model, '(未知)') AS model,
               SUM(input_tokens), SUM(output_tokens), SUM(cache_read), SUM(cost)
        FROM turns WHERE ts >= ? GROUP BY day, model ORDER BY day;
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_int64(stmt, 1, since)
        var out: [(Int64, String, Int64, Int64, Int64, Double)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append((sqlite3_column_int64(stmt, 0),
                        String(cString: sqlite3_column_text(stmt, 1)),
                        sqlite3_column_int64(stmt, 2),
                        sqlite3_column_int64(stmt, 3),
                        sqlite3_column_int64(stmt, 4),
                        sqlite3_column_double(stmt, 5)))
        }
        sqlite3_finalize(stmt)
        return out
    }

    /// Cost breakdown by quality (spec §5.2): estimated vs actual variable
    /// spend, plus coverage (known / total billable turns). Hermes is
    /// excluded (its traffic is billed inside OCG/OR/Codex plans).
    func costBreakdown(from: Int64, to: Int64) -> (estimated: Double, actual: Double, knownCount: Int, totalCount: Int) {
        lock.lock(); defer { lock.unlock() }
        guard let db else { return (0, 0, 0, 0) }
        var stmt: OpaquePointer?
        let sql = """
        SELECT
          COALESCE(SUM(CASE WHEN cost_quality='estimated' THEN cost ELSE 0 END), 0),
          COALESCE(SUM(CASE WHEN cost_quality='actual' THEN cost ELSE 0 END), 0),
          SUM(CASE WHEN cost_quality != 'unknown' THEN 1 ELSE 0 END),
          COUNT(*)
        FROM turns WHERE tool != 'hermes' AND ts BETWEEN ? AND ?;
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return (0, 0, 0, 0) }
        sqlite3_bind_int64(stmt, 1, from)
        sqlite3_bind_int64(stmt, 2, to)
        var out = (0.0, 0.0, 0, 0)
        if sqlite3_step(stmt) == SQLITE_ROW {
            out.0 = sqlite3_column_double(stmt, 0)
            out.1 = sqlite3_column_double(stmt, 1)
            out.2 = Int(sqlite3_column_int64(stmt, 2))
            out.3 = Int(sqlite3_column_int64(stmt, 3))
        }
        sqlite3_finalize(stmt)
        return out
    }

    /// API 价值：全部工具（含 hermes）的所有 turns 按模型官方单价重估。
    /// 与实际账单无关——回答「这些 token 按 API 价值多少钱」。
    func apiValue(from: Int64, to: Int64, tool: String? = nil) -> Double {
        lock.lock(); defer { lock.unlock() }
        guard let db else { return 0 }
        var stmt: OpaquePointer?
        let sql: String
        if let tool {
            sql = "SELECT model, input_tokens, output_tokens, cache_read, cache_write FROM turns WHERE ts BETWEEN ? AND ? AND tool = ?;"
        } else {
            sql = "SELECT model, input_tokens, output_tokens, cache_read, cache_write FROM turns WHERE ts BETWEEN ? AND ?;"
        }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        sqlite3_bind_int64(stmt, 1, from)
        sqlite3_bind_int64(stmt, 2, to)
        if let tool {
            sqlite3_bind_text(stmt, 3, (tool as NSString).utf8String, -1, SQLITE_TRANSIENT)
        }
        var total = 0.0
        while sqlite3_step(stmt) == SQLITE_ROW {
            let model = sqlite3_column_type(stmt, 0) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 0))
            guard let cost = Pricing.estimate(model: model,
                                              input: sqlite3_column_int64(stmt, 1),
                                              output: sqlite3_column_int64(stmt, 2),
                                              cacheRead: sqlite3_column_int64(stmt, 3),
                                              cacheWrite: sqlite3_column_int64(stmt, 4)) else { continue }
            total += cost
        }
        sqlite3_finalize(stmt)
        return total
    }

    // MARK: - queries

    func turnCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        guard let db else { return 0 }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM turns;", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        var n = 0
        if sqlite3_step(stmt) == SQLITE_ROW { n = Int(sqlite3_column_int64(stmt, 0)) }
        sqlite3_finalize(stmt)
        return n
    }

    /// Sanitized diagnostics: table counts, model distribution, cost quality,
    /// settings KEY NAMES ONLY (never values — no secrets leave the device).
    func diagnosticsSummary() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        guard let db else { return ["error": "db not open"] }
        var out: [String: Any] = [:]
        func count(_ table: String) -> Int {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM \(table);", -1, &stmt, nil) == SQLITE_OK else { return -1 }
            var n = 0
            if sqlite3_step(stmt) == SQLITE_ROW { n = Int(sqlite3_column_int64(stmt, 0)) }
            sqlite3_finalize(stmt)
            return n
        }
        out["turns"] = count("turns")
        out["sessions"] = count("sessions")
        out["subscriptions"] = count("subscriptions")
        out["or_snapshots"] = count("openrouter_snapshots")
        out["go_snapshots"] = count("opencodego_snapshots")
        out["scan_state_entries"] = count("scan_state")
        out["user_version"] = userVersion()

        var stmt: OpaquePointer?
        var models: [[String: Any]] = []
        if sqlite3_prepare_v2(db, "SELECT COALESCE(model,'(nil)'), COUNT(*) FROM turns GROUP BY model ORDER BY 2 DESC LIMIT 10;", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                models.append(["model": String(cString: sqlite3_column_text(stmt, 0)),
                               "count": Int(sqlite3_column_int64(stmt, 1))])
            }
            sqlite3_finalize(stmt)
        }
        out["top_models"] = models

        var quality: [String: Int] = [:]
        if sqlite3_prepare_v2(db, "SELECT cost_quality, COUNT(*) FROM turns GROUP BY cost_quality;", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                quality[String(cString: sqlite3_column_text(stmt, 0))] = Int(sqlite3_column_int64(stmt, 1))
            }
            sqlite3_finalize(stmt)
        }
        out["cost_quality"] = quality

        var keys: [String] = []
        if sqlite3_prepare_v2(db, "SELECT k FROM settings ORDER BY k;", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                keys.append(String(cString: sqlite3_column_text(stmt, 0)))
            }
            sqlite3_finalize(stmt)
        }
        out["settings_keys"] = keys // names only, never values
        return out
    }

    // MARK: - helpers

    private func colStr(_ stmt: OpaquePointer?, _ idx: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, idx) else { return nil }
        return String(cString: c)
    }

    private func startOfDay(daysAgo: Int) -> Int64 {
        let cal = Calendar.current
        let day = cal.date(byAdding: .day, value: -daysAgo, to: cal.startOfDay(for: Date()))!
        return Int64(day.timeIntervalSince1970)
    }

    func lastScanTime() -> Int64 {
        lock.lock(); defer { lock.unlock() }
        guard let db else { return 0 }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT MAX(last_scan) FROM scan_state;", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        var out: Int64 = 0
        if sqlite3_step(stmt) == SQLITE_ROW { out = sqlite3_column_int64(stmt, 0) }
        sqlite3_finalize(stmt)
        // CollectorEngine stamps a heartbeat on every scan (idle or not);
        // take the newer of the two so the UI reports real freshness.
        let beat = Int64(setting("last_scan_heartbeat") ?? "0") ?? 0
        return max(out, beat)
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
