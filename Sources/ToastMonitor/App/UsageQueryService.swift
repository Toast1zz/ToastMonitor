import Foundation

/// Off-main-thread aggregation facade.
/// UI state loads one Snapshot per refresh; no view touches the DB directly
/// for aggregates, and no long query ever runs on the main thread.
final class UsageQueryService: @unchecked Sendable {
    static let shared = UsageQueryService()

    private let database: Database
    private let queue: DispatchQueue

    struct CostQuality: Sendable {
        var estimated: Double
        var actual: Double
        var deepseekActual: Double = 0
    }

    /// Fields needed by the status bar and popover. Dashboard-only model and
    /// calendar data is intentionally absent so a lightweight refresh never
    /// performs the annual aggregation queries.
    struct LightSnapshot: Sendable {
        var today: Database.ToolTotals
        var week: Database.ToolTotals
        var month: Database.ToolTotals
        var all: Database.ToolTotals
        var todayTokens: Int64
        var weekTokens: Int64
        var monthTokens: Int64
        var allTokens: Int64
        var byToolToday: [Database.ToolTotals]
        var byToolWeek: [Database.ToolTotals]
        var byToolMonth: [Database.ToolTotals]
        var byToolAll: [Database.ToolTotals]
        var costToday: CostQuality
        var costWeek: CostQuality
        var costMonth: CostQuality
        var costAll: CostQuality
        var apiValueToday: Double
        var apiValueWeek: Double
        var apiValueMonth: Double
        var apiValueAll: Double
        var subscriptions: [Database.Subscription]
        var lastScan: Int64
        var fetchedAt: Int64
    }

    /// Complete dashboard snapshot. `light` is computed once and reused,
    /// avoiding a second round of status/popover aggregate work.
    struct Snapshot: Sendable {
        var light: LightSnapshot
        var modelAggs: [Database.ModelAgg]
        var modelAggsToday: [Database.ModelAgg]
        var modelAggsMonth: [Database.ModelAgg]
        var modelAggsAll: [Database.ModelAgg]
        var heatmap: [Int64: Int64]
        var heatmapCost: [Int64: Double]
    }

    /// Snapshot cache keyed by dataVersionKey: while the DB is unchanged,
    /// polling and didCollect refreshes reuse it instead of re-aggregating.
    private var cachedLight: (key: String, snapshot: LightSnapshot)?
    private var cachedSnapshot: (key: String, snapshot: Snapshot)?
    /// Daily aggregate / heatmap cache, same keying, so the popover's
    /// minute ticker does not rerun the 371-day GROUP BY.
    private var cachedDailyAggs: (key: String, aggs: [Database.DayAgg])?
    /// Estimated Claude tokens used outside this Mac. Recomputed only when a
    /// new quota sample lands or every 5 minutes — not on every new turn,
    /// since it scans all local Claude turns since the first sample.
    private var cachedElsewhere: (key: String, estimate: ClaudeNonLocalEstimator.TokenEstimate?)?
    private var lightComputations = 0
    private var fullComputations = 0
    private var dailyComputations = 0

    private let currentDate: @Sendable () -> Date

    init(database: Database = .shared,
         queue: DispatchQueue = DispatchQueue(label: "toastmonitor.queries", qos: .userInitiated),
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.database = database
        self.queue = queue
        self.currentDate = now
    }

    struct CacheDiagnostics: Equatable {
        let lightComputations: Int
        let fullComputations: Int
        let dailyComputations: Int
    }

    func cacheDiagnostics() -> CacheDiagnostics {
        queue.sync {
            CacheDiagnostics(lightComputations: lightComputations,
                             fullComputations: fullComputations,
                             dailyComputations: dailyComputations)
        }
    }

    /// Drop usage aggregates after a setting that changes their meaning commits.
    /// Queue ordering ensures an already-running query cannot repopulate stale
    /// snapshots after this invalidation. Completion runs on the main actor.
    func invalidateBillingModeCaches(completion: @escaping @MainActor @Sendable () -> Void) {
        queue.async {
            self.cachedLight = nil
            self.cachedSnapshot = nil
            self.cachedDailyAggs = nil
            DispatchQueue.main.async { completion() }
        }
    }
    func loadSnapshot(configuration: UsagePeriodConfiguration = UsagePeriodConfiguration(),
                      completion: @escaping @MainActor @Sendable (Snapshot) -> Void) {
        queue.async {
            let now = self.currentDate()
            let key = self.cacheKey(configuration: configuration, now: now)
            if let c = self.cachedSnapshot, c.key == key {
                DispatchQueue.main.async { completion(c.snapshot) }
                return
            }
            let snap = self.compute(configuration: configuration, now: now)
            self.cachedSnapshot = (key, snap)
            self.cachedLight = (key, snap.light)
            DispatchQueue.main.async { completion(snap) }
        }
    }
    func loadLightSnapshot(configuration: UsagePeriodConfiguration = UsagePeriodConfiguration(),
                           completion: @escaping @MainActor @Sendable (LightSnapshot) -> Void) {
        queue.async {
            let now = self.currentDate()
            let key = self.cacheKey(configuration: configuration, now: now)
            if DebugLog.enabled {
                NSLog("[ToastMonitor][query] light key=%@ cached=%@", key, self.cachedLight?.key ?? "-")
            }
            if let c = self.cachedLight, c.key == key {
                DispatchQueue.main.async { completion(c.snapshot) }
                return
            }
            let snap = self.computeLight(configuration: configuration, now: now)
            self.cachedLight = (key, snap)
            DispatchQueue.main.async { completion(snap) }
        }
    }

    func loadDailyAggs(days: Int, completion: @escaping @MainActor @Sendable ([Database.DayAgg]) -> Void) {
        queue.async {
            let key = "\(self.database.dataVersionKey())|days=\(days)"
            if let c = self.cachedDailyAggs, c.key == key {
                DispatchQueue.main.async { completion(c.aggs) }
                return
            }
            let aggs = self.database.dailyAggregates(days: days)
            self.dailyComputations += 1
            self.cachedDailyAggs = (key, aggs)
            DispatchQueue.main.async { completion(aggs) }
        }
    }

    /// One year of day (yyyymmdd) -> primary tokens for the popover. The
    /// dashboard gets its heatmap from AppState's complete snapshot; the
    /// popover only refreshes the light snapshot, so it queries this itself.
    func loadHeatmap(days: Int = 371, completion: @escaping @MainActor @Sendable ([Int64: Int64]) -> Void) {
        loadDailyAggs(days: days) { aggs in
            completion(Self.buildHeatmap(aggs: aggs))
        }
    }

    func loadTurns(sessionTool: String, sessionID: String,
                   completion: @escaping @MainActor @Sendable ([(ts: Int64, model: String?, input: Int64, output: Int64, cacheRead: Int64, cacheWrite: Int64, cost: Double)]) -> Void) {
        queue.async {
            let turns = self.database.turns(sessionTool: sessionTool, sessionID: sessionID)
            DispatchQueue.main.async { completion(turns) }
        }
    }

    func loadSessions(tool: ToolKind?, limit: Int = 500,
                      completion: @escaping @MainActor @Sendable ([Database.SessionRow], Int) -> Void) {
        queue.async {
            let sessions = self.database.sessions(tool: tool, limit: limit)
            let total = self.database.sessionCount(tool: tool)
            DispatchQueue.main.async { completion(sessions, total) }
        }
    }

    func loadPerfPoints(days: Int, completion: @escaping @MainActor @Sendable ([PerfPoint]) -> Void) {
        queue.async {
            let points = self.database.perfPoints(days: days)
            DispatchQueue.main.async { completion(points) }
        }
    }

    func loadDailyAggsByModel(days: Int, completion: @escaping @MainActor @Sendable ([(day: Int64, model: String, input: Int64, output: Int64, cacheRead: Int64, cost: Double, count: Int64, totalTokens: Int64)]) -> Void) {
        queue.async {
            let aggs = self.database.dailyAggregatesByModel(days: days)
            DispatchQueue.main.async { completion(aggs) }
        }
    }
    private func cacheKey(configuration: UsagePeriodConfiguration, now: Date) -> String {
        let settled = elsewhereSettledKey(now: Int64(now.timeIntervalSince1970))
        return "\(database.dataVersionKey())|\(settled)|\(configuration.cacheKey(now: now))"
    }

    /// The newest quota interval joins the estimate once its ingest margin
    /// passes. No DB write marks that moment, so it has to be in the keys.
    private func elsewhereSettledKey(now: Int64) -> String {
        database.claudeQuotaSampleLatestTs() <= now - ClaudeNonLocalEstimator.ingestMarginSeconds
            ? "settled" : "pending"
    }

    private func computeLight(configuration: UsagePeriodConfiguration,
                              now: Date) -> LightSnapshot {
        lightComputations += 1
        let nowTs = Int64(now.timeIntervalSince1970)
        let todayRange = configuration.range(for: .today, now: now)
        let weekRange = configuration.range(for: .week, now: now)
        let monthRange = configuration.range(for: .month, now: now)
        let allRange = configuration.range(for: .all, now: now)

        func costQuality(from: Int64, to: Int64) -> CostQuality {
            let b = database.costBreakdown(from: from, to: to)
            return CostQuality(estimated: b.estimated, actual: b.actual, deepseekActual: b.deepseekActual)
        }

        // The grouped rows already contain every total; deriving the four
        // period totals avoids four additional aggregate scans.
        let localToday = database.totalsByTool(from: todayRange.start, to: todayRange.end)
        let localWeek = database.totalsByTool(from: weekRange.start, to: weekRange.end)
        let localMonth = database.totalsByTool(from: monthRange.start, to: monthRange.end)
        let localAll = database.totalsByTool(from: allRange.start, to: allRange.end)
        // Claude usage that left no local transcript (Cowork, claude.ai,
        // other machines), estimated from the shared quota, joins the token
        // totals and the per-source rows as its own labelled row. The
        // aggregates below (calls, input/output split, cost) stay local-only.
        let elsewhere = claudeElsewhereEstimate(now: nowTs)
        func withElsewhere(_ rows: [Database.ToolTotals], _ range: UsagePeriodRange) -> [Database.ToolTotals] {
            guard let tokens = elsewhere?.tokens(from: range.start, to: range.end), tokens > 0 else { return rows }
            return rows + [Database.ToolTotals(tool: ClaudeNonLocalEstimator.estimateToolLabel,
                                               input: tokens, output: 0, cacheRead: 0,
                                               cacheWrite: 0, cost: 0, count: 0)]
        }
        let byToolToday = withElsewhere(localToday, todayRange)
        let byToolWeek = withElsewhere(localWeek, weekRange)
        let byToolMonth = withElsewhere(localMonth, monthRange)
        let byToolAll = withElsewhere(localAll, allRange)
        return LightSnapshot(
            today: Self.aggregate(localToday),
            week: Self.aggregate(localWeek),
            month: Self.aggregate(localMonth),
            all: Self.aggregate(localAll),
            todayTokens: Self.totalTokens(byToolToday),
            weekTokens: Self.totalTokens(byToolWeek),
            monthTokens: Self.totalTokens(byToolMonth),
            allTokens: Self.totalTokens(byToolAll),
            byToolToday: byToolToday,
            byToolWeek: byToolWeek,
            byToolMonth: byToolMonth,
            byToolAll: byToolAll,
            costToday: costQuality(from: todayRange.start, to: todayRange.end),
            costWeek: costQuality(from: weekRange.start, to: weekRange.end),
            costMonth: costQuality(from: monthRange.start, to: monthRange.end),
            costAll: costQuality(from: allRange.start, to: allRange.end),
            apiValueToday: database.apiValue(from: todayRange.start, to: todayRange.end),
            apiValueWeek: database.apiValue(from: weekRange.start, to: weekRange.end),
            apiValueMonth: database.apiValue(from: monthRange.start, to: monthRange.end),
            apiValueAll: database.apiValue(from: allRange.start, to: allRange.end),
            subscriptions: database.subscriptions(),
            lastScan: database.lastScanTime(),
            fetchedAt: nowTs)
    }

    private func compute(configuration: UsagePeriodConfiguration, now: Date) -> Snapshot {
        fullComputations += 1
        let light = computeLight(configuration: configuration, now: now)
        let todayRange = configuration.range(for: .today, now: now)
        let weekRange = configuration.range(for: .week, now: now)
        let monthRange = configuration.range(for: .month, now: now)
        let allRange = configuration.range(for: .all, now: now)
        let annualAggs = database.dailyAggregates(days: 371)
        return Snapshot(
            light: light,
            modelAggs: database.modelAggregates(from: weekRange.start, to: weekRange.end),
            modelAggsToday: database.modelAggregates(from: todayRange.start, to: todayRange.end),
            modelAggsMonth: database.modelAggregates(from: monthRange.start, to: monthRange.end),
            modelAggsAll: database.modelAggregates(from: allRange.start, to: allRange.end),
            // The overview renders 53 weeks (up to 371 calendar days).
            heatmap: Self.buildHeatmap(aggs: annualAggs),
            heatmapCost: Self.buildCostHeatmap(aggs: annualAggs))
    }

    /// Caller runs on `queue`.
    private func claudeElsewhereEstimate(now: Int64) -> ClaudeNonLocalEstimator.TokenEstimate? {
        let key = "\(database.claudeQuotaSampleMarker())|\(elsewhereSettledKey(now: now))|\(now / 300)"
        if let cached = cachedElsewhere, cached.key == key { return cached.estimate }
        let samples = database.claudeQuotaSamples(since: now - Database.claudeQuotaSampleRetention)
        let estimate = ClaudeNonLocalEstimator.tokenEstimate(
            samples: samples,
            localIntervalTotals: database.claudeLocalIntervalTotals(samples: samples),
            now: now)
        cachedElsewhere = (key, estimate)
        return estimate
    }

    private static func aggregate(_ rows: [Database.ToolTotals]) -> Database.ToolTotals {
        rows.reduce(Database.ToolTotals(tool: "all", input: 0, output: 0,
                                        cacheRead: 0, cacheWrite: 0, cost: 0, count: 0)) {
            Database.ToolTotals(tool: "all", input: $0.input + $1.input,
                                output: $0.output + $1.output,
                                cacheRead: $0.cacheRead + $1.cacheRead,
                                cacheWrite: $0.cacheWrite + $1.cacheWrite,
                                cost: $0.cost + $1.cost,
                                count: $0.count + $1.count)
        }
    }

    /// Primary token measure: input + output + cache reads (Codex input
    /// already includes cache reads; see ToolKind.totalTokens).
    private static func totalTokens(_ rows: [Database.ToolTotals]) -> Int64 {
        rows.reduce(Int64(0)) { $0 + (ToolKind(rawValue: $1.tool)?.totalTokens($1) ?? ($1.input + $1.output)) }
    }

    /// day(yyyymmdd) -> primary tokens (see totalTokens), for the last 371 days.
    private static func buildHeatmap(aggs: [Database.DayAgg]) -> [Int64: Int64] {
        var out: [Int64: Int64] = [:]
        for a in aggs {
            out[a.day, default: 0] += ToolKind(rawValue: a.tool)?.totalTokens(input: a.input, output: a.output, cacheRead: a.cacheRead)
                ?? (a.input + a.output)
        }
        return out
    }

    /// day(yyyymmdd) -> cost, for the last 371 days (estimate semantics).
    private static func buildCostHeatmap(aggs: [Database.DayAgg]) -> [Int64: Double] {
        var out: [Int64: Double] = [:]
        for a in aggs {
            out[a.day, default: 0] += a.cost
        }
        return out
    }
}
