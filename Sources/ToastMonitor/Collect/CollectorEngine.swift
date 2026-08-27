import Foundation

/// Orchestrates collection. A 1s foreground / 5s background poll uses cheap
/// per-file stat checks, keeps the menu-bar token count fresh while the
/// popover is hidden, and avoids FSEvents feedback from SQLite sidecars.
final class CollectorEngine: @unchecked Sendable {
    struct ScanReceipt: Sendable {
        let requestID: UUID?
        let startedAt: Date
        let finishedAt: Date
        let turns: Int
        let sessions: Int
        let failedSources: [String]

        var changed: Bool { turns > 0 || sessions > 0 }
    }

    static let shared = CollectorEngine()
    static let didCollect = Notification.Name("ToastMonitorDidCollect")

    /// Parses a source without a database transaction, then validates and
    /// commits its rows plus cursor/baseline mutations in one short write.
    /// Internal so integration tests can hold `scan` open and prove ordinary
    /// database reads are not blocked by parser IO.
    static func prepareAndCommit(
        database: Database,
        sourcePaths: [String],
        scan: (any ParserStateStore) -> (turns: [TurnRecord], sessions: [SessionInfo])
    ) -> (committed: Bool, turns: [TurnRecord], sessions: [SessionInfo]) {
        let staged = StagedParserStateStore(database: database, sourcePaths: sourcePaths)
        let out = scan(staged)
        let committed = database.inTransaction {
            staged.validateForCommit()
                && database.insertTurns(out.turns)
                && database.upsertSessions(out.sessions)
                && staged.apply()
        }
        return (committed, out.turns, out.sessions)
    }

    private let queue = DispatchQueue(label: "toastmonitor.collector", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var pending = false
    private var started = false
    private var lastScanStart: CFAbsoluteTime = 0
    private var foreground = false
    private var popoverVisible = false
    private var dashboardVisible = false
    /// Source DBs do not use scan_state cursors; their main/WAL mtimes form
    /// an in-memory preflight watermark so idle scans avoid opening a tx.
    private var sourceSignatures: [String: String] = [:]
    private var fileLists: [String: (loadedAt: CFAbsoluteTime, paths: [String])] = [:]

    private func cachedFileList(_ key: String, maxAge: CFAbsoluteTime = 60,
                                load: () -> [String]) -> [String] {
        let now = CFAbsoluteTimeGetCurrent()
        if let cached = fileLists[key], now - cached.loadedAt < maxAge {
            return cached.paths
        }
        let paths = load()
        fileLists[key] = (now, paths)
        return paths
    }

    private func sourceSignature(_ path: String) -> String? {
        guard let main = FileScanner.fileStat(path) else { return nil }
        let wal = FileScanner.fileStat(path + "-wal")
        return "\(main.size):\(main.mtime):\(main.identity)|\(wal?.size ?? -1):\(wal?.mtime ?? -1)"
    }

    private func sourceChanged(_ path: String) -> Bool {
        guard let current = sourceSignature(path) else { return false }
        return sourceSignatures[path] != current
    }

    private func rememberSource(_ path: String) {
        if let signature = sourceSignature(path) {
            sourceSignatures[path] = signature
        }
    }

    private func fileSourcesChanged(_ paths: [String]) -> Bool {
        paths.contains { path in
            guard let stat = FileScanner.fileStat(path) else { return false }
            let previous = Database.shared.scanState(path)
            return previous.size != stat.size
                || previous.mtime != stat.mtime
                || previous.identity != stat.identity
        }
    }

    private init() {
        for name in [TMNotifications.popoverVisibility, TMNotifications.dashboardVisibility] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] note in
                guard let self else { return }
                let visible = (note.object as? Bool) ?? false
                self.queue.async { [self] in
                    if name == TMNotifications.popoverVisibility {
                        self.popoverVisible = visible
                    } else {
                        self.dashboardVisible = visible
                    }
                    self.updateForeground()
                }
            }
        }
    }

    private func updateForeground() {
        dispatchPrecondition(condition: .onQueue(queue))
        let visible = popoverVisible || dashboardVisible
        guard visible != foreground else { return }
        foreground = visible
        installTimer()
        if visible { runScan() }
    }

    func start() {
        queue.async { [self] in
            guard !started else { return }
            started = true
            Database.shared.open()
            runScan()
            installTimer()
        }
    }

    private func installTimer() {
        dispatchPrecondition(condition: .onQueue(queue))
        timer?.cancel()
        timer = nil
        let interval: DispatchTimeInterval = foreground ? .seconds(1) : .seconds(5)
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + interval, repeating: interval)
        source.setEventHandler { [weak self] in self?.runScan() }
        source.resume()
        timer = source
    }

    /// Returns an identity immediately. Forced requests never disappear into
    /// the timer coalescer; their completion belongs to that exact scan.
    @discardableResult
    func scheduleScan(force: Bool = false,
                      completion: (@MainActor @Sendable (ScanReceipt) -> Void)? = nil) -> UUID {
        let requestID = UUID()
        queue.async { [self] in
            if force {
                pending = false
                runScan(requestID: requestID, completion: completion)
                return
            }
            guard !pending else { return }
            let now = CFAbsoluteTimeGetCurrent()
            guard now - lastScanStart > 2 else { return }
            pending = true
            queue.asyncAfter(deadline: .now() + 0.5) { [self] in
                pending = false
                runScan(requestID: requestID, completion: completion)
            }
        }
        return requestID
    }

    func runScan(requestID: UUID? = nil,
                 completion: (@MainActor @Sendable (ScanReceipt) -> Void)? = nil) {
        dispatchPrecondition(condition: .onQueue(queue))
        let startedAt = Date()
        let t0 = CFAbsoluteTimeGetCurrent()
        lastScanStart = t0

        var turns: [TurnRecord] = []
        var sessions: [SessionInfo] = []
        var failedSources: [String] = []

        func ingest(_ source: String, preflight: () -> Bool,
                    sourcePaths: [String],
                    scan: (any ParserStateStore) -> (turns: [TurnRecord], sessions: [SessionInfo]),
                    signaturePath: String? = nil) {
            let sourceStart = CFAbsoluteTimeGetCurrent()
            guard preflight() else {
                let duration = (CFAbsoluteTimeGetCurrent() - sourceStart) * 1000
                Task { @MainActor in
                    SourceHealthHub.shared.recordIdle(tool: source, durationMs: duration)
                }
                return
            }

            let prepared = Self.prepareAndCommit(database: .shared,
                                                 sourcePaths: sourcePaths,
                                                 scan: scan)
            let out = (turns: prepared.turns, sessions: prepared.sessions)
            let duration = (CFAbsoluteTimeGetCurrent() - sourceStart) * 1000
            if !prepared.committed {
                failedSources.append(source)
                Task { @MainActor in
                    SourceHealthHub.shared.record(tool: source, rows: out.turns.count,
                                                  failed: max(out.turns.count, 1), durationMs: duration,
                                                  error: "Source changed or write failed — retrying")
                }
                return
            }
            if let signaturePath { rememberSource(signaturePath) }
            if out.turns.isEmpty && out.sessions.isEmpty {
                Task { @MainActor in
                    SourceHealthHub.shared.recordIdle(tool: source, durationMs: duration)
                }
                return
            }
            turns.append(contentsOf: out.turns)
            sessions.append(contentsOf: out.sessions)
            Task { @MainActor in
                SourceHealthHub.shared.record(tool: source, rows: out.turns.count,
                                              failed: 0, durationMs: duration, error: nil)
            }
        }

        let claudeFiles = cachedFileList("claude") {
            (FileScanner.listFiles(ClaudeCodeParser.root, maxDepth: 2)
                + ClaudeCodeParser.listCoworkFiles())
                .filter { $0.hasSuffix(".jsonl") }
        }
        ingest("claude", preflight: { self.fileSourcesChanged(claudeFiles) },
               sourcePaths: claudeFiles) { state in
            ClaudeCodeParser.scan(knownPaths: claudeFiles, database: state)
        }

        let codexFiles = cachedFileList("codex") {
            FileScanner.listFiles(CodexParser.sessionsRoot, maxDepth: 4)
                .filter { $0.hasSuffix(".jsonl") }
        }
        ingest("codex", preflight: { self.fileSourcesChanged(codexFiles) },
               sourcePaths: codexFiles) { state in
            CodexParser.scan(database: state)
        }

        ingest("opencode", preflight: { self.sourceChanged(OpenCodeParser.dbPath) },
               sourcePaths: [OpenCodeParser.dbPath, OpenCodeParser.dbPath + "-wal"],
               scan: { OpenCodeParser.scan(database: $0) }, signaturePath: OpenCodeParser.dbPath)

        ingest("hermes", preflight: { self.sourceChanged(HermesParser.dbPath) },
               sourcePaths: [HermesParser.dbPath, HermesParser.dbPath + "-wal"],
               scan: { HermesParser.scan(database: $0) }, signaturePath: HermesParser.dbPath)
        let ompFiles = cachedFileList("omp") {
            FileScanner.listFiles(OmpParser.root, maxDepth: 3)
                .filter { $0.hasSuffix(".jsonl") }
        }
        ingest("omp", preflight: { self.fileSourcesChanged(ompFiles) },
               sourcePaths: ompFiles) { state in
            OmpParser.scan(knownPaths: ompFiles, database: state)
        }

        // DeepSeek Harness: incremental raw event logs when a zstd CLI is
        // available, otherwise the JSON projection cache. The mode is sticky
        // (see DSHParser.resolveMode) so the two accounting paths never mix.
        switch DSHParser.resolveMode() {
        case .log:
            let dshFiles = cachedFileList("dsh") { DSHParser.listSessionFiles() }
            ingest("dsh", preflight: { self.fileSourcesChanged(dshFiles) },
                   sourcePaths: dshFiles) { state in
                DSHParser.scanLogs(knownPaths: dshFiles, database: state)
            }
        case .cache:
            ingest("dsh", preflight: { self.sourceChanged(DSHParser.projCachePath) },
                   sourcePaths: [DSHParser.projCachePath],
                   scan: { DSHParser.scanProjCache(database: $0) },
                   signaturePath: DSHParser.projCachePath)
        }

        HermesRemoteClient.shared.maybePoll()
        // Unconditional (not gated on new turns/sessions): a week with zero
        // new usage still deserves a backup, since settings/subscriptions
        // can change independently of collector activity. Self-throttled
        // internally, so calling this every tick costs one setting read.
        DataMaintenance.maybeCreateRoutineBackupIfDue()
        if !turns.isEmpty || !sessions.isEmpty {
            Database.shared.backfillCosts()
        }

        if !turns.isEmpty || !sessions.isEmpty {
            Database.shared.setSetting("last_scan_heartbeat", "\(Int64(Date().timeIntervalSince1970))")
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - t0
        if !turns.isEmpty || !sessions.isEmpty || elapsed > 0.05 {
            NSLog("[ToastMonitor] scan: %d turns, %d sessions, %.1fms",
                  turns.count, sessions.count, elapsed * 1000)
        }
        let receipt = ScanReceipt(requestID: requestID, startedAt: startedAt,
                                  finishedAt: Date(), turns: turns.count,
                                  sessions: sessions.count, failedSources: failedSources)
        Task { @MainActor in
            NotificationCenter.default.post(name: Self.didCollect, object: receipt)
            completion?(receipt)
        }
    }
}
