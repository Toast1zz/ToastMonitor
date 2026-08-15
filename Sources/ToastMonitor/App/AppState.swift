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
    // UI-10: read-only — every write flows through refresh()'s single
    // `state = next` publish, so the per-property setters were dead code
    // (verified: no caller writes these).
    var today: Database.ToolTotals { state.today }
    var week: Database.ToolTotals { state.week }
    var month: Database.ToolTotals { state.month }
    var all: Database.ToolTotals { state.all }
    var todayTokens: Int64 { state.todayTokens }
    var weekTokens: Int64 { state.weekTokens }
    var monthTokens: Int64 { state.monthTokens }
    var allTokens: Int64 { state.allTokens }
    var byToolToday: [Database.ToolTotals] { state.byToolToday }
    var byToolWeek: [Database.ToolTotals] { state.byToolWeek }
    var byToolMonth: [Database.ToolTotals] { state.byToolMonth }
    var byToolAll: [Database.ToolTotals] { state.byToolAll }
    var apiValueToday: Double { state.apiValueToday }
    var apiValueWeek: Double { state.apiValueWeek }
    var apiValueMonth: Double { state.apiValueMonth }
    var apiValueAll: Double { state.apiValueAll }
    var costToday: UsageQueryService.CostQuality { state.costToday }
    var costWeek: UsageQueryService.CostQuality { state.costWeek }
    var costMonth: UsageQueryService.CostQuality { state.costMonth }
    var costAll: UsageQueryService.CostQuality { state.costAll }
    var modelAggs: [Database.ModelAgg] { state.modelAggs }
    var modelAggsToday: [Database.ModelAgg] { state.modelAggsToday }
    var modelAggsMonth: [Database.ModelAgg] { state.modelAggsMonth }
    var modelAggsAll: [Database.ModelAgg] { state.modelAggsAll }
    var heatmap: [Int64: Int64] { state.heatmap }
    var heatmapCost: [Int64: Double] { state.heatmapCost }
    var subscriptions: [Database.Subscription] { state.subscriptions }
    var lastScan: Int64 { state.lastScan }
    var snapshotFetchedAt: Int64 { state.snapshotFetchedAt }

    private var refreshTimer: Timer?
    private var refreshInFlight = false
    /// A manual refresh arrived while a snapshot was already in flight;
    /// re-run as manual once the in-flight one completes so the toolbar
    /// spinner reflects the user's request.
    private var pendingManual = false
    /// 快照加载开始时间；超过看门狗阈值视为卡死，允许下一次刷新重试。
    /// 若不重置，一次永不完成的加载会让 refreshInFlight 永久为 true，
    /// didCollect 与定时器刷新全部被合并锁挡掉——popover 冻结在旧快照，
    /// 而 quota 客户端独立轮询照常更新，形成"额度在动、来源不动"。
    private var refreshStartedAt: CFAbsoluteTime = 0
    private static let refreshWatchdogSeconds: CFAbsoluteTime = 10
    /// Monotonic request identity. A watchdog retry may overlap the request it
    /// superseded; only the newest generation is allowed to publish or clear
    /// the in-flight state.
    private var refreshGeneration: UInt64 = 0
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
        if refreshInFlight {
            // Watchdog: 卡住超过阈值的在途加载不阻塞后续刷新。旧加载若
            // 最终完成，其 generation guard 会同时拦住 publish 与 finish，
            // 不能覆盖新一轮快照或清掉新一轮的 in-flight 状态。
            if CFAbsoluteTimeGetCurrent() - refreshStartedAt > Self.refreshWatchdogSeconds {
                refreshInFlight = false
                if DebugLog.enabled {
                    NSLog("[ToastMonitor][refresh] watchdog reset inFlight")
                }
            } else {
                if manual { pendingManual = true }
                return
            }
        }
        refreshInFlight = true
        refreshStartedAt = CFAbsoluteTimeGetCurrent()
        refreshGeneration &+= 1
        let generation = refreshGeneration
        if manual { manualRefreshing = true }
        if DebugLog.enabled {
            NSLog("[ToastMonitor][refresh] enter fg=%d popover=%d dashboard=%d",
                  foreground ? 1 : 0, popoverVisible ? 1 : 0, dashboardVisible ? 1 : 0)
        }

        let publish: (UsageQueryService.LightSnapshot, UsageQueryService.Snapshot?) -> Void = {
            [weak self] light, complete in
            guard let self, self.refreshGeneration == generation else { return }
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
            if DebugLog.enabled {
                NSLog("[ToastMonitor][refresh] publish today=%lld (codex %lld) turns=%d",
                      light.todayTokens,
                      (light.byToolToday.first { $0.tool == "codex" }?.input ?? 0)
                        + (light.byToolToday.first { $0.tool == "codex" }?.output ?? 0),
                      light.byToolToday.reduce(0) { $0 + $1.count })
            }
        }

        if dashboardVisible {
            UsageQueryService.shared.loadSnapshot { [weak self] snap in
                guard let self else { return }
                publish(snap.light, snap)
                self.finishRefresh(generation: generation)
            }
        } else {
            UsageQueryService.shared.loadLightSnapshot { [weak self] light in
                guard let self else { return }
                publish(light, nil)
                self.finishRefresh(generation: generation)
            }
        }
    }

    private func finishRefresh(generation: UInt64) {
        guard generation == refreshGeneration else { return }
        refreshInFlight = false
        manualRefreshing = false
        if pendingManual {
            pendingManual = false
            refresh(manual: true)
        }
    }
}
