import SwiftUI

/// Main-thread UI state. All aggregates arrive as a background-computed
/// Snapshot from UsageQueryService — refresh() never queries the DB directly.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var today: Database.ToolTotals = .init(tool: "all", input: 0, output: 0, cacheRead: 0, cacheWrite: 0, cost: 0, count: 0)
    @Published var week: Database.ToolTotals = .init(tool: "all", input: 0, output: 0, cacheRead: 0, cacheWrite: 0, cost: 0, count: 0)
    @Published var month: Database.ToolTotals = .init(tool: "all", input: 0, output: 0, cacheRead: 0, cacheWrite: 0, cost: 0, count: 0)
    @Published var all: Database.ToolTotals = .init(tool: "all", input: 0, output: 0, cacheRead: 0, cacheWrite: 0, cost: 0, count: 0)
    /// 主 token 口径（输入 + 输出 + 缓存命中；codex 的 input 已含缓存）。
    @Published var todayTokens: Int64 = 0
    @Published var weekTokens: Int64 = 0
    @Published var monthTokens: Int64 = 0
    @Published var allTokens: Int64 = 0
    @Published var byToolToday: [Database.ToolTotals] = []
    @Published var byToolWeek: [Database.ToolTotals] = []
    @Published var byToolMonth: [Database.ToolTotals] = []
    @Published var byToolAll: [Database.ToolTotals] = []
    @Published var apiValueToday: Double = 0
    @Published var apiValueWeek: Double = 0
    @Published var apiValueMonth: Double = 0
    @Published var apiValueAll: Double = 0
    @Published var costToday = UsageQueryService.CostQuality(estimated: 0, actual: 0, knownCount: 0, totalCount: 0)
    @Published var costWeek = UsageQueryService.CostQuality(estimated: 0, actual: 0, knownCount: 0, totalCount: 0)
    @Published var costMonth = UsageQueryService.CostQuality(estimated: 0, actual: 0, knownCount: 0, totalCount: 0)
    @Published var costAll = UsageQueryService.CostQuality(estimated: 0, actual: 0, knownCount: 0, totalCount: 0)
    @Published var isRefreshing: Bool = false
    /// True only while a USER-initiated refresh is in flight — the toolbar
    /// spinner reacts to this, never to automatic refreshes.
    @Published var manualRefreshing: Bool = false
    @Published var modelAggs: [Database.ModelAgg] = []
    @Published var modelAggsToday: [Database.ModelAgg] = []
    @Published var modelAggsMonth: [Database.ModelAgg] = []
    @Published var modelAggsAll: [Database.ModelAgg] = []
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
    private var popoverVisible = false
    private var dashboardVisible = false
    private var foreground = false

    private init() {
        for name in [TMNotifications.popoverVisibility, TMNotifications.dashboardVisibility] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let self else { return }
                let visible = (note.object as? Bool) ?? false
                if name == PanelController.visibilityNotification {
                    self.popoverVisible = visible
                } else {
                    self.dashboardVisible = visible
                }
                self.updateForeground()
            }
        }
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
        updateForeground()
    }

    /// Foreground = popover expanded or dashboard window visible. While the
    /// user is looking, snapshot every second and refresh immediately on
    /// activation; when everything is hidden the UI stops polling (the
    /// collector's didCollect notification still lands fresh data).
    private func updateForeground() {
        let fg = popoverVisible || dashboardVisible
        guard fg != foreground else { return }
        foreground = fg
        if let t = refreshTimer {
            t.invalidate()
            refreshTimer = nil
        }
        if fg {
            let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refresh()
                }
            }
            RunLoop.main.add(t, forMode: .common)
            refreshTimer = t
            refresh() // activation moment: show the latest numbers instantly
        }
    }

    /// Coalesced: at most one background snapshot in flight.
    /// `manual` marks user-initiated refreshes (toolbar button) so the
    /// spinner shows only for those.
    func refresh(manual: Bool = false) {
        guard !refreshInFlight else { return }
        refreshInFlight = true
        isRefreshing = true
        if manual { manualRefreshing = true }
        UsageQueryService.shared.loadSnapshot { [weak self] snap in
            guard let self else { return }
            self.today = snap.today
            self.week = snap.week
            self.month = snap.month
            self.all = snap.all
            self.todayTokens = snap.todayTokens
            self.weekTokens = snap.weekTokens
            self.monthTokens = snap.monthTokens
            self.allTokens = snap.allTokens
            self.byToolToday = snap.byToolToday
            self.byToolWeek = snap.byToolWeek
            self.byToolMonth = snap.byToolMonth
            self.byToolAll = snap.byToolAll
            self.costToday = snap.costToday
            self.costWeek = snap.costWeek
            self.costMonth = snap.costMonth
            self.costAll = snap.costAll
            self.apiValueToday = snap.apiValueToday
            self.apiValueWeek = snap.apiValueWeek
            self.apiValueMonth = snap.apiValueMonth
            self.apiValueAll = snap.apiValueAll
            self.modelAggs = snap.modelAggs
            self.modelAggsToday = snap.modelAggsToday
            self.modelAggsMonth = snap.modelAggsMonth
            self.modelAggsAll = snap.modelAggsAll
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
            self.manualRefreshing = false
        }
    }
}
