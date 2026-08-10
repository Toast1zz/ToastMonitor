import SwiftUI

/// Main-thread UI state. All aggregates arrive as a background-computed
/// Snapshot from UsageQueryService — refresh() never queries the DB directly.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    private struct UIState {
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
        var apiValueToday: Double
        var apiValueWeek: Double
        var apiValueMonth: Double
        var apiValueAll: Double
        var costToday: UsageQueryService.CostQuality
        var costWeek: UsageQueryService.CostQuality
        var costMonth: UsageQueryService.CostQuality
        var costAll: UsageQueryService.CostQuality
        var modelAggs: [Database.ModelAgg]
        var modelAggsToday: [Database.ModelAgg]
        var modelAggsMonth: [Database.ModelAgg]
        var modelAggsAll: [Database.ModelAgg]
        var heatmap: [Int64: Int64]
        var heatmapCost: [Int64: Double]
        var subscriptions: [Database.Subscription]
        var lastScan: Int64
        var snapshotFetchedAt: Int64

        init() {
            let zero = Database.ToolTotals(tool: "all", input: 0, output: 0,
                                           cacheRead: 0, cacheWrite: 0, cost: 0, count: 0)
            let quality = UsageQueryService.CostQuality(estimated: 0, actual: 0,
                                                        knownCount: 0, totalCount: 0)
            today = zero; week = zero; month = zero; all = zero
            todayTokens = 0; weekTokens = 0; monthTokens = 0; allTokens = 0
            byToolToday = []; byToolWeek = []; byToolMonth = []; byToolAll = []
            apiValueToday = 0; apiValueWeek = 0; apiValueMonth = 0; apiValueAll = 0
            costToday = quality; costWeek = quality; costMonth = quality; costAll = quality
            modelAggs = []; modelAggsToday = []; modelAggsMonth = []; modelAggsAll = []
            heatmap = [:]; heatmapCost = [:]; subscriptions = []
            lastScan = 0; snapshotFetchedAt = 0
        }
    }
    @Published private var state = UIState()
    /// True only while a USER-initiated refresh is in flight.
    @Published private(set) var manualRefreshing = false

    // Keep the established property names for existing views/callers.
    var today: Database.ToolTotals { get { state.today } set { state.today = newValue } }
    var week: Database.ToolTotals { get { state.week } set { state.week = newValue } }
    var month: Database.ToolTotals { get { state.month } set { state.month = newValue } }
    var all: Database.ToolTotals { get { state.all } set { state.all = newValue } }
    var todayTokens: Int64 { get { state.todayTokens } set { state.todayTokens = newValue } }
    var weekTokens: Int64 { get { state.weekTokens } set { state.weekTokens = newValue } }
    var monthTokens: Int64 { get { state.monthTokens } set { state.monthTokens = newValue } }
    var allTokens: Int64 { get { state.allTokens } set { state.allTokens = newValue } }
    var byToolToday: [Database.ToolTotals] { get { state.byToolToday } set { state.byToolToday = newValue } }
    var byToolWeek: [Database.ToolTotals] { get { state.byToolWeek } set { state.byToolWeek = newValue } }
    var byToolMonth: [Database.ToolTotals] { get { state.byToolMonth } set { state.byToolMonth = newValue } }
    var byToolAll: [Database.ToolTotals] { get { state.byToolAll } set { state.byToolAll = newValue } }
    var apiValueToday: Double { get { state.apiValueToday } set { state.apiValueToday = newValue } }
    var apiValueWeek: Double { get { state.apiValueWeek } set { state.apiValueWeek = newValue } }
    var apiValueMonth: Double { get { state.apiValueMonth } set { state.apiValueMonth = newValue } }
    var apiValueAll: Double { get { state.apiValueAll } set { state.apiValueAll = newValue } }
    var costToday: UsageQueryService.CostQuality { get { state.costToday } set { state.costToday = newValue } }
    var costWeek: UsageQueryService.CostQuality { get { state.costWeek } set { state.costWeek = newValue } }
    var costMonth: UsageQueryService.CostQuality { get { state.costMonth } set { state.costMonth = newValue } }
    var costAll: UsageQueryService.CostQuality { get { state.costAll } set { state.costAll = newValue } }
    var modelAggs: [Database.ModelAgg] { get { state.modelAggs } set { state.modelAggs = newValue } }
    var modelAggsToday: [Database.ModelAgg] { get { state.modelAggsToday } set { state.modelAggsToday = newValue } }
    var modelAggsMonth: [Database.ModelAgg] { get { state.modelAggsMonth } set { state.modelAggsMonth = newValue } }
    var modelAggsAll: [Database.ModelAgg] { get { state.modelAggsAll } set { state.modelAggsAll = newValue } }
    var heatmap: [Int64: Int64] { get { state.heatmap } set { state.heatmap = newValue } }
    var heatmapCost: [Int64: Double] { get { state.heatmapCost } set { state.heatmapCost = newValue } }
    var subscriptions: [Database.Subscription] { get { state.subscriptions } set { state.subscriptions = newValue } }
    var lastScan: Int64 { get { state.lastScan } set { state.lastScan = newValue } }
    var snapshotFetchedAt: Int64 { get { state.snapshotFetchedAt } set { state.snapshotFetchedAt = newValue } }

    private var refreshTimer: Timer?
    private var refreshInFlight = false
    /// A manual refresh arrived while a snapshot was already in flight;
    /// re-run as manual once the in-flight one completes so the toolbar
    /// spinner reflects the user's request.
    private var pendingManual = false
    private var popoverVisible = false
    private var dashboardVisible = false
    private var foreground = false

    private init() {
        for name in [TMNotifications.popoverVisibility, TMNotifications.dashboardVisibility] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let visible = (note.object as? Bool) ?? false
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if name == TMNotifications.popoverVisibility {
                        self.popoverVisible = visible
                    } else {
                        self.dashboardVisible = visible
                    }
                    self.updateForeground()
                }
            }
        }
        NotificationCenter.default.addObserver(forName: CollectorEngine.didCollect, object: nil, queue: .main) { [weak self] note in
            // 变更驱动：只有真的扫到新数据才刷新快照；空转扫描（0 新增）
            // 直接跳过，避免每秒一轮完整聚合。
            if let receipt = note.object as? CollectorEngine.ScanReceipt,
               receipt.turns == 0, receipt.sessions == 0 { return }
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
            // 5s 保险轮询：实时性由 didCollect 的变更驱动保证（新数据到达
            // 立即刷新），此处只兜底错过通知的场景，避免每秒完整聚合。
            let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
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
        guard !refreshInFlight else {
            if manual { pendingManual = true }
            return
        }
        refreshInFlight = true
        if manual { manualRefreshing = true }

        let publish: (UsageQueryService.LightSnapshot, UsageQueryService.Snapshot?) -> Void = {
            [weak self] light, complete in
            guard let self else { return }
            var next = self.state
            next.today = light.today
            next.week = light.week
            next.month = light.month
            next.all = light.all
            next.todayTokens = light.todayTokens
            next.weekTokens = light.weekTokens
            next.monthTokens = light.monthTokens
            next.allTokens = light.allTokens
            next.byToolToday = light.byToolToday
            next.byToolWeek = light.byToolWeek
            next.byToolMonth = light.byToolMonth
            next.byToolAll = light.byToolAll
            next.costToday = light.costToday
            next.costWeek = light.costWeek
            next.costMonth = light.costMonth
            next.costAll = light.costAll
            next.apiValueToday = light.apiValueToday
            next.apiValueWeek = light.apiValueWeek
            next.apiValueMonth = light.apiValueMonth
            next.apiValueAll = light.apiValueAll
            next.subscriptions = light.subscriptions
            next.lastScan = light.lastScan
            next.snapshotFetchedAt = light.fetchedAt
            if let complete {
                next.modelAggs = complete.modelAggs
                next.modelAggsToday = complete.modelAggsToday
                next.modelAggsMonth = complete.modelAggsMonth
                next.modelAggsAll = complete.modelAggsAll
                next.heatmap = complete.heatmap
                next.heatmapCost = complete.heatmapCost
            }
            self.state = next
        }

        if dashboardVisible {
            UsageQueryService.shared.loadSnapshot { [weak self] snap in
                guard let self else { return }
                publish(snap.light, snap)
                self.finishRefresh()
            }
        } else {
            UsageQueryService.shared.loadLightSnapshot { [weak self] light in
                guard let self else { return }
                publish(light, nil)
                self.finishRefresh()
            }
        }
    }

    private func finishRefresh() {
        refreshInFlight = false
        manualRefreshing = false
        if pendingManual {
            pendingManual = false
            refresh(manual: true)
        }
    }
}
