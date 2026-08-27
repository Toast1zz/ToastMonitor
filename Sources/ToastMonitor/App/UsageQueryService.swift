import Foundation

/// Off-main-thread aggregation facade (spec §9 / §11).
/// UI state loads one Snapshot per refresh; no view touches the DB directly
/// for aggregates, and no long query ever runs on the main thread.
final class UsageQueryService: @unchecked Sendable {
    static let shared = UsageQueryService()

    private let database: Database
    private let queue: DispatchQueue

    struct CostQuality: Sendable {
        var estimated: Double
        var actual: Double
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

    /// 快照缓存：以 dataVersionKey 为失效键。DB 未变化时直接返回缓存，
    /// 5s 保险轮询与 didCollect 驱动的刷新都不再触发全量聚合。
    private var cachedLight: (key: String, snapshot: LightSnapshot)?
    private var cachedSnapshot: (key: String, snapshot: Snapshot)?
    /// 日聚合/热力图缓存（M8）：与快照同键策略。popover 可见期间每分钟
    /// 的 minuteTicker 不再反复跑 371 天 strftime+GROUP BY 全量聚合。
    private var cachedDailyAggs: (key: String, aggs: [Database.DayAgg])?
    private var lightComputations = 0
    private var fullComputations = 0
    private var dailyComputations = 0

    init(database: Database = .shared,
         queue: DispatchQueue = DispatchQueue(label: "toastmonitor.queries", qos: .userInitiated)) {
        self.database = database
        self.queue = queue
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

    func loadSnapshot(configuration: UsagePeriodConfiguration = UsagePeriodConfiguration(),
                      completion: @escaping @MainActor @Sendable (Snapshot) -> Void) {
        queue.async {
            let now = Date()
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
            let now = Date()
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

    /// 一年热力图（day yyyymmdd -> primary tokens，口径同主面板），供
    /// Popover 使用——主面板走 AppState 的 complete snapshot，Popover
    /// 前台只刷 light snapshot，heatmap 不会自动填充，需自行查询。
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
                      completion: @escaping @MainActor @Sendable ([Database.SessionRow]) -> Void) {
        queue.async {
            let sessions = self.database.sessions(tool: tool, limit: limit)
            DispatchQueue.main.async { completion(sessions) }
        }
    }

    func loadORSnapshots(limit: Int = 500, completion: @escaping @MainActor @Sendable ([Database.ORSnapshot]) -> Void) {
        queue.async {
            let snapshots = self.database.orSnapshots(limit: limit)
            DispatchQueue.main.async { completion(snapshots) }
        }
    }

    func loadDailyAggsByModel(days: Int, completion: @escaping @MainActor @Sendable ([(day: Int64, model: String, input: Int64, output: Int64, cacheRead: Int64, cost: Double, count: Int64)]) -> Void) {
        queue.async {
            let aggs = self.database.dailyAggregatesByModel(days: days)
            DispatchQueue.main.async { completion(aggs) }
        }
    }
    /// Loads daily quota points plus intra-day balance-change events, retaining
    /// the complete history rather than a polling-frequency-dependent row limit.
    func loadOGSnapshotsByDay(completion: @escaping @MainActor @Sendable ([Database.OGSnapshot]) -> Void) {
        queue.async {
            let snapshots = self.database.ogSnapshotsByDay()
            DispatchQueue.main.async { completion(snapshots) }
        }
    }

    func loadORSnapshotsByDay(completion: @escaping @MainActor @Sendable ([Database.ORSnapshot]) -> Void) {
        queue.async {
            let snapshots = self.database.orSnapshotsByDay()
            DispatchQueue.main.async { completion(snapshots) }
        }
    }

    private func cacheKey(configuration: UsagePeriodConfiguration, now: Date) -> String {
        "\(database.dataVersionKey())|\(configuration.cacheKey(now: now))"
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
            return CostQuality(estimated: b.estimated, actual: b.actual)
        }

        // The grouped rows already contain every total; deriving the four
        // period totals avoids four additional aggregate scans.
        let byToolToday = database.totalsByTool(from: todayRange.start, to: todayRange.end)
        let byToolWeek = database.totalsByTool(from: weekRange.start, to: weekRange.end)
        let byToolMonth = database.totalsByTool(from: monthRange.start, to: monthRange.end)
        let byToolAll = database.totalsByTool(from: allRange.start, to: allRange.end)
        return LightSnapshot(
            today: Self.aggregate(byToolToday),
            week: Self.aggregate(byToolWeek),
            month: Self.aggregate(byToolMonth),
            all: Self.aggregate(byToolAll),
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

    /// 主 token 口径：输入 + 输出 + 缓存命中（cacheRead 计入总量；
    /// codex 除外——其 input 已含缓存，见 ToolKind.totalTokens）。
    private static func totalTokens(_ rows: [Database.ToolTotals]) -> Int64 {
        rows.reduce(Int64(0)) { $0 + (ToolKind(rawValue: $1.tool)?.totalTokens($1) ?? ($1.input + $1.output)) }
    }

    /// day(yyyymmdd) -> primary tokens (totalTokens 口径：含缓存命中，codex 除外), for the last 371 days.
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
