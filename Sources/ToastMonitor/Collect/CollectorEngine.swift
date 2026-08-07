import Foundation

/// Orchestrates collection. Poll-only design (no FSEvents): a 5s timer with
/// cheap per-file stat checks means scans are sub-millisecond when idle, and
/// we avoid the FSEvents feedback loop (our own SQLite -shm side effects
/// landing inside watched directories re-triggering scans).
final class CollectorEngine {
    static let shared = CollectorEngine()

    static let didCollect = Notification.Name("ToastMonitorDidCollect")

    private let queue = DispatchQueue(label: "toastmonitor.collector", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var pending = false
    private var started = false

    /// Coalescing: at most one scan per 2s.
    private var lastScanStart: CFAbsoluteTime = 0
    /// Foreground (popover/dashboard visible) scans every 1s; background is
    /// fully stopped — no source refreshes while nothing is on screen.
    private var foreground = false
    private var popoverVisible = false
    private var dashboardVisible = false

    private init() {
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

    /// OR semantics: either surface being visible keeps the collector
    /// foregrounded; one closing must not stop collection while the other
    /// is still on screen.
    private func updateForeground() {
        let fg = popoverVisible || dashboardVisible
        queue.async { [self] in
            guard fg != foreground else { return }
            foreground = fg
            installTimer() // rebuild with the new interval
            if fg { runScan() } // activation moment: scan immediately
        }
    }

    func start() {
        queue.async { [self] in
            guard !started else { return }
            started = true
            Database.shared.open()
            runScan() // initial full backfill
            installTimer()
        }
    }

    private func installTimer() {
        timer?.cancel()
        timer = nil
        guard foreground else { return } // background: no polling at all
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in self?.runScan() }
        t.resume()
        timer = t
    }

    /// Coalesced trigger (still used for manual refresh button).
    func scheduleScan() {
        queue.async { [self] in
            guard !pending else { return }
            let now = CFAbsoluteTimeGetCurrent()
            guard now - lastScanStart > 2 else { return }
            pending = true
            queue.asyncAfter(deadline: .now() + 0.5) { [self] in
                pending = false
                runScan()
            }
        }
    }

    func runScan() {
        let t0 = CFAbsoluteTimeGetCurrent()
        lastScanStart = t0

        var turns: [TurnRecord] = []
        var sessions: [SessionInfo] = []

        // Each source scans AND commits its turns/sessions/cursor/baselines in
        // one transaction. Parsers are deliberately executed inside the
        // transaction because their scan_state/session_totals writes join the
        // current SQLite transaction. A failed write rolls everything back.
        func ingest(_ source: String, scan: () -> (turns: [TurnRecord], sessions: [SessionInfo])) {
            let t0 = CFAbsoluteTimeGetCurrent()
            var out: (turns: [TurnRecord], sessions: [SessionInfo]) = ([], [])
            let ok = Database.shared.inTransaction {
                out = scan()
                let tOK = Database.shared.insertTurns(out.turns)
                let sOK = Database.shared.upsertSessions(out.sessions)
                return tOK && sOK
            }
            let duration = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            if !ok {
                NSLog("[ToastMonitor] %@ ingestion failed; cursor/baseline rolled back", source)
                Task { @MainActor in
                    SourceHealthHub.shared.record(tool: source, rows: out.turns.count,
                                                  failed: max(out.turns.count, 1), durationMs: duration,
                                                  error: "写入失败，游标/累计基线已回滚")
                }
                return
            }
            guard !out.turns.isEmpty || !out.sessions.isEmpty else {
                Task { @MainActor in
                    SourceHealthHub.shared.recordIdle(tool: source, durationMs: duration)
                }
                return
            }
            turns.append(contentsOf: out.turns)
            sessions.append(contentsOf: out.sessions)
            Task { @MainActor in
                SourceHealthHub.shared.record(tool: source, rows: out.turns.count, failed: ok ? 0 : out.turns.count,
                                              durationMs: duration, error: ok ? nil : "写入失败，游标未前进")
            }
        }

        // 1) Claude Code
        let claudeFiles = FileScanner.listFiles(ClaudeCodeParser.root, maxDepth: 2)
        ingest("claude") { ClaudeCodeParser.scan(knownPaths: claudeFiles) }

        // 2) Codex
        ingest("codex") { CodexParser.scan() }

        // 3) OpenCode
        ingest("opencode") { OpenCodeParser.scan() }

        // 4) Hermes (no-op on machines without a local install)
        ingest("hermes") { HermesParser.scan() }

        // 5) OMP (Oh My Pi, local transcripts only)
        let ompFiles = FileScanner.listFiles(OmpParser.root, maxDepth: 3)
        ingest("omp") { OmpParser.scan(knownPaths: ompFiles) }

        // 6) Hermes remote (VPS usage feed, rate-limited to 60s)
        HermesRemoteClient.shared.maybePoll()

        Database.shared.backfillCosts()
        // Heartbeat: scan_state.last_scan only advances when a file changed;
        // an idle collector would otherwise freeze "数据已更新" at the last
        // change. This stamp reflects the actual scan time.
        Database.shared.setSetting("last_scan_heartbeat", "\(Int64(Date().timeIntervalSince1970))")

        let elapsed = CFAbsoluteTimeGetCurrent() - t0
        if turns.count > 0 || sessions.count > 0 || elapsed > 0.05 {
            NSLog("[ToastMonitor] scan: %d turns, %d sessions, %.1fms", turns.count, sessions.count, elapsed * 1000)
        }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.didCollect, object: nil)
        }
    }
}
