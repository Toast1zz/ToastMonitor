import Foundation

/// Off-main-thread aggregation facade (spec §9 / §11).
/// UI state loads one Snapshot per refresh; no view touches the DB directly
/// for aggregates, and no long query ever runs on the main thread.
final class UsageQueryService: @unchecked Sendable {
    static let shared = UsageQueryService()

    private let queue = DispatchQueue(label: "toastmonitor.queries", qos: .userInitiated)

    struct CostQuality: Sendable {
        var estimated: Double
        var actual: Double
        var knownCount: Int
        var totalCount: Int
        var coverage: Double { totalCount > 0 ? Double(knownCount) / Double(totalCount) : 0 }
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

    private init() {}

    func loadSnapshot(completion: @escaping @MainActor @Sendable (Snapshot) -> Void) {
        queue.async {
            let key = Database.shared.dataVersionKey()
            if let c = self.cachedSnapshot, c.key == key {
                DispatchQueue.main.async { completion(c.snapshot) }
                return
            }
            let snap = self.compute()
            self.cachedSnapshot = (key, snap)
            self.cachedLight = (key, snap.light)
            DispatchQueue.main.async { completion(snap) }
        }
    }
    func loadLightSnapshot(completion: @escaping @MainActor @Sendable (LightSnapshot) -> Void) {
        queue.async {
            let key = Database.shared.dataVersionKey()
            if DebugLog.enabled {
                NSLog("[ToastMonitor][query] light key=%@ cached=%@", key, self.cachedLight?.key ?? "-")
            }
            if let c = self.cachedLight, c.key == key {
                DispatchQueue.main.async { completion(c.snapshot) }
                return
            }
            let snap = self.computeLight()
            self.cachedLight = (key, snap)
            DispatchQueue.main.async { completion(snap) }
        }
    }

    func loadDailyAggs(days: Int, completion: @escaping @MainActor @Sendable ([Database.DayAgg]) -> Void) {
        queue.async {
            let aggs = Database.shared.dailyAggregates(days: days)
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
            let turns = Database.shared.turns(sessionTool: sessionTool, sessionID: sessionID)
            DispatchQueue.main.async { completion(turns) }
        }
    }

    func loadORSnapshots(limit: Int = 500, completion: @escaping @MainActor @Sendable ([Database.ORSnapshot]) -> Void) {
        queue.async {
            let snapshots = Database.shared.orSnapshots(limit: limit)
            DispatchQueue.main.async { completion(snapshots) }
        }
    }

    func loadDailyAggsByModel(days: Int, completion: @escaping @MainActor @Sendable ([(day: Int64, model: String, input: Int64, output: Int64, cacheRead: Int64, cost: Double, count: Int64)]) -> Void) {
        queue.async {
            let aggs = Database.shared.dailyAggregatesByModel(days: days)
            DispatchQueue.main.async { completion(aggs) }
        }
    }
    /// Loads one quota point per local calendar day, retaining the complete
    /// persisted history rather than a polling-frequency-dependent row limit.
    func loadOGSnapshotsByDay(completion: @escaping @MainActor @Sendable ([Database.OGSnapshot]) -> Void) {
        queue.async {
            let snapshots = Database.shared.ogSnapshotsByDay()
            DispatchQueue.main.async { completion(snapshots) }
        }
    }

    func loadORSnapshotsByDay(completion: @escaping @MainActor @Sendable ([Database.ORSnapshot]) -> Void) {
        queue.async {
            let snapshots = Database.shared.orSnapshotsByDay()
            DispatchQueue.main.async { completion(snapshots) }
        }
    }

    private func computeLight() -> LightSnapshot {
        let cal = Calendar.current
        let now = Date()
        let nowTs = Int64(now.timeIntervalSince1970)
        let todayStart = Int64(cal.startOfDay(for: now).timeIntervalSince1970)
        let weekStart = Int64(cal.date(byAdding: .day, value: -6, to: cal.startOfDay(for: now))!.timeIntervalSince1970)
        let monthStart = nowTs - 30 * 86400 // 近 30 天（不要自然月）

        func costQuality(from: Int64, to: Int64) -> CostQuality {
            let b = Database.shared.costBreakdown(from: from, to: to)
            return CostQuality(estimated: b.estimated, actual: b.actual,
                               knownCount: b.knownCount, totalCount: b.totalCount)
        }

        // The grouped rows already contain every total; deriving the four
        // period totals avoids four additional aggregate scans.
        let byToolToday = Database.shared.totalsByTool(from: todayStart, to: nowTs)
        let byToolWeek = Database.shared.totalsByTool(from: weekStart, to: nowTs)
        let byToolMonth = Database.shared.totalsByTool(from: monthStart, to: nowTs)
        let byToolAll = Database.shared.totalsByTool(from: 0, to: nowTs)
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
            costToday: costQuality(from: todayStart, to: nowTs),
            costWeek: costQuality(from: weekStart, to: nowTs),
            costMonth: costQuality(from: monthStart, to: nowTs),
            costAll: costQuality(from: 0, to: nowTs),
            apiValueToday: Database.shared.apiValue(from: todayStart, to: nowTs),
            apiValueWeek: Database.shared.apiValue(from: weekStart, to: nowTs),
            apiValueMonth: Database.shared.apiValue(from: monthStart, to: nowTs),
            apiValueAll: Database.shared.apiValue(from: 0, to: nowTs),
            subscriptions: Database.shared.subscriptions(),
            lastScan: Database.shared.lastScanTime(),
            fetchedAt: nowTs)
    }

    private func compute() -> Snapshot {
        let light = computeLight()
        let nowTs = light.fetchedAt
        let cal = Calendar.current
        let now = Date(timeIntervalSince1970: TimeInterval(nowTs))
        let todayStart = Int64(cal.startOfDay(for: now).timeIntervalSince1970)
        let weekStart = Int64(cal.date(byAdding: .day, value: -6, to: cal.startOfDay(for: now))!.timeIntervalSince1970)
        let monthStart = nowTs - 30 * 86400
        let annualAggs = Database.shared.dailyAggregates(days: 371)
        return Snapshot(
            light: light,
            modelAggs: Database.shared.modelAggregates(from: weekStart, to: nowTs),
            modelAggsToday: Database.shared.modelAggregates(from: todayStart, to: nowTs),
            modelAggsMonth: Database.shared.modelAggregates(from: monthStart, to: nowTs),
            modelAggsAll: Database.shared.modelAggregates(from: 0, to: nowTs),
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
