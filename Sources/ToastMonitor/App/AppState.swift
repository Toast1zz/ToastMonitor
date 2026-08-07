import SwiftUI

/// Main-thread UI state. All aggregates arrive as a background-computed
/// Snapshot from UsageQueryService — refresh() never queries the DB directly.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var today: Database.ToolTotals = .init(tool: "all", input: 0, output: 0, cacheRead: 0, cacheWrite: 0, cost: 0, count: 0)
    @Published var week: Database.ToolTotals = .init(tool: "all", input: 0, output: 0, cacheRead: 0, cacheWrite: 0, cost: 0, count: 0)
    @Published var month: Database.ToolTotals = .init(tool: "all", input: 0, output: 0, cacheRead: 0, cacheWrite: 0, cost: 0, count: 0)
    /// 主 token 口径（输入 + 输出 + 缓存命中；codex 的 input 已含缓存）。
    @Published var todayTokens: Int64 = 0
    @Published var weekTokens: Int64 = 0
    @Published var monthTokens: Int64 = 0
    @Published var byToolToday: [Database.ToolTotals] = []
    @Published var byToolWeek: [Database.ToolTotals] = []
    @Published var byToolMonth: [Database.ToolTotals] = []
    @Published var apiValueToday: Double = 0
    @Published var apiValueWeek: Double = 0
    @Published var apiValueMonth: Double = 0
    @Published var costToday = UsageQueryService.CostQuality(estimated: 0, actual: 0, knownCount: 0, totalCount: 0)
    @Published var costWeek = UsageQueryService.CostQuality(estimated: 0, actual: 0, knownCount: 0, totalCount: 0)
    @Published var costMonth = UsageQueryService.CostQuality(estimated: 0, actual: 0, knownCount: 0, totalCount: 0)
    @Published var isRefreshing: Bool = false
    @Published var modelAggs: [Database.ModelAgg] = []
    @Published var modelAggsToday: [Database.ModelAgg] = []
    @Published var modelAggsMonth: [Database.ModelAgg] = []
    @Published var dailyAggs: [Database.DayAgg] = []
    @Published var heatmap: [Int64: Int64] = [:]
    @Published var heatmapCost: [Int64: Double] = [:]
    @Published var sessions: [Database.SessionRow] = []
    @Published var subscriptions: [Database.Subscription] = []
    @Published var lastScan: Int64 = 0
    @Published var hasLocalData: Bool = true
    @Published var snapshotFetchedAt: Int64 = 0

    private var refreshTimer: Timer?
    private var refreshInFlight = false

    private init() {
        NotificationCenter.default.addObserver(forName: CollectorEngine.didCollect, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
        NotificationCenter.default.addObserver(forName: Database.subscriptionsDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    func start() {
        refresh()
        let t = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        refreshTimer = t
    }

    /// Coalesced: at most one background snapshot in flight.
    func refresh() {
        guard !refreshInFlight else { return }
        refreshInFlight = true
        isRefreshing = true
        UsageQueryService.shared.loadSnapshot { [weak self] snap in
            guard let self else { return }
            self.today = snap.today
            self.week = snap.week
            self.month = snap.month
            self.todayTokens = snap.todayTokens
            self.weekTokens = snap.weekTokens
            self.monthTokens = snap.monthTokens
            self.byToolToday = snap.byToolToday
            self.byToolWeek = snap.byToolWeek
            self.byToolMonth = snap.byToolMonth
            self.costToday = snap.costToday
            self.costWeek = snap.costWeek
            self.costMonth = snap.costMonth
            self.apiValueToday = snap.apiValueToday
            self.apiValueWeek = snap.apiValueWeek
            self.apiValueMonth = snap.apiValueMonth
            self.modelAggs = snap.modelAggs
            self.modelAggsToday = snap.modelAggsToday
            self.modelAggsMonth = snap.modelAggsMonth
            self.dailyAggs = snap.dailyAggs
            self.heatmap = snap.heatmap
            self.heatmapCost = snap.heatmapCost
            self.sessions = snap.sessions
            self.subscriptions = snap.subscriptions
            self.lastScan = snap.lastScan
            self.hasLocalData = snap.hasLocalData
            self.snapshotFetchedAt = snap.fetchedAt
            self.refreshInFlight = false
            self.isRefreshing = false
        }
    }
}
