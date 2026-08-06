import Foundation

/// Off-main-thread aggregation facade (spec §9 / §11).
/// UI state loads one Snapshot per refresh; no view touches the DB directly
/// for aggregates, and no long query ever runs on the main thread.
final class UsageQueryService {
    static let shared = UsageQueryService()

    private let queue = DispatchQueue(label: "toastmonitor.queries", qos: .userInitiated)

    struct CostQuality {
        var estimated: Double
        var actual: Double
        var knownCount: Int
        var totalCount: Int
        var coverage: Double { totalCount > 0 ? Double(knownCount) / Double(totalCount) : 0 }
    }

    struct Snapshot {
        var today: Database.ToolTotals
        var week: Database.ToolTotals
        var month: Database.ToolTotals
        /// 主 token 口径（输入 + 输出；缓存命中为独立明细）。
        var todayTokens: Int64
        var weekTokens: Int64
        var monthTokens: Int64
        var byToolToday: [Database.ToolTotals]
        var byToolWeek: [Database.ToolTotals]
        var byToolMonth: [Database.ToolTotals]
        var costToday: CostQuality
        var costWeek: CostQuality
        var costMonth: CostQuality
        var modelAggs: [Database.ModelAgg]
        var dailyAggs: [Database.DayAgg]
        var heatmap: [Int64: Int64]
        var heatmapCost: [Int64: Double]
        var sessions: [Database.SessionRow]
        var subscriptions: [Database.Subscription]
        var lastScan: Int64
        var hasLocalData: Bool
        var fetchedAt: Int64
    }

    private init() {}

    func loadSnapshot(completion: @escaping (Snapshot) -> Void) {
        queue.async {
            let snap = self.compute()
            DispatchQueue.main.async { completion(snap) }
        }
    }

    func loadDailyAggs(days: Int, completion: @escaping ([Database.DayAgg]) -> Void) {
        queue.async {
            let aggs = Database.shared.dailyAggregates(days: days)
            DispatchQueue.main.async { completion(aggs) }
        }
    }

    func loadTurns(sessionTool: String, sessionID: String,
                   completion: @escaping ([(ts: Int64, model: String?, input: Int64, output: Int64, cacheRead: Int64, cacheWrite: Int64, cost: Double)]) -> Void) {
        queue.async {
            let turns = Database.shared.turns(sessionTool: sessionTool, sessionID: sessionID)
            DispatchQueue.main.async { completion(turns) }
        }
    }

    func loadORSnapshots(limit: Int = 500, completion: @escaping ([Database.ORSnapshot]) -> Void) {
        queue.async {
            let snapshots = Database.shared.orSnapshots(limit: limit)
            DispatchQueue.main.async { completion(snapshots) }
        }
    }

    func loadOGSnapshots(limit: Int = 200, completion: @escaping ([Database.OGSnapshot]) -> Void) {
        queue.async {
            let snapshots = Database.shared.ogSnapshots(limit: limit)
            DispatchQueue.main.async { completion(snapshots) }
        }
    }

    func loadDailyAggsByModel(days: Int, completion: @escaping ([(day: Int64, model: String, input: Int64, output: Int64, cacheRead: Int64, cost: Double)]) -> Void) {
        queue.async {
            let aggs = Database.shared.dailyAggregatesByModel(days: days)
            DispatchQueue.main.async { completion(aggs) }
        }
    }

    private func compute() -> Snapshot {
        let cal = Calendar.current
        let now = Date()
        let nowTs = Int64(now.timeIntervalSince1970)
        let todayStart = Int64(cal.startOfDay(for: now).timeIntervalSince1970)
        let weekStart = Int64(cal.date(byAdding: .day, value: -6, to: cal.startOfDay(for: now))!.timeIntervalSince1970)
        let monthStart = nowTs - 30 * 86400 // 近 30 天（用户 2026-08-05：不要自然月）

        func costQuality(from: Int64, to: Int64) -> CostQuality {
            let b = Database.shared.costBreakdown(from: from, to: to)
            return CostQuality(estimated: b.estimated, actual: b.actual, knownCount: b.knownCount, totalCount: b.totalCount)
        }

        let today = Database.shared.totals(from: todayStart, to: nowTs)
        let byToolToday = Database.shared.totalsByTool(from: todayStart, to: nowTs)
        let byToolWeek = Database.shared.totalsByTool(from: weekStart, to: nowTs)
        let byToolMonth = Database.shared.totalsByTool(from: monthStart, to: nowTs)
        let dailyAggs = Database.shared.dailyAggregates(days: 35)
        let annualAggs = Database.shared.dailyAggregates(days: 371)
        return Snapshot(
            today: today,
            week: Database.shared.totals(from: weekStart, to: nowTs),
            month: Database.shared.totals(from: monthStart, to: nowTs),
            todayTokens: Self.totalTokens(byToolToday),
            weekTokens: Self.totalTokens(byToolWeek),
            monthTokens: Self.totalTokens(byToolMonth),
            byToolToday: byToolToday,
            byToolWeek: byToolWeek,
            byToolMonth: byToolMonth,
            costToday: costQuality(from: todayStart, to: nowTs),
            costWeek: costQuality(from: weekStart, to: nowTs),
            costMonth: costQuality(from: monthStart, to: nowTs),
            modelAggs: Database.shared.modelAggregates(from: weekStart, to: nowTs),
            dailyAggs: dailyAggs,
            // The overview renders 53 weeks (up to 371 calendar days).
            heatmap: Self.buildHeatmap(aggs: annualAggs),
            heatmapCost: Self.buildCostHeatmap(aggs: annualAggs),
            sessions: Database.shared.sessions(limit: 200),
            subscriptions: Database.shared.subscriptions(),
            lastScan: Database.shared.lastScanTime(),
            hasLocalData: Database.shared.turnCount() > 0,
            fetchedAt: Int64(Date().timeIntervalSince1970))
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
