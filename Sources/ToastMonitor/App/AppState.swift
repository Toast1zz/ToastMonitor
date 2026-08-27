import SwiftUI

/// Deterministic state machine for AppState snapshot requests. Keeping time
/// and generation policy here makes watchdog overlap semantics testable
/// without timers, queues, or a live SwiftUI application.
struct RefreshCoordinator {
    struct Request: Equatable {
        let generation: UInt64
        let restartedByWatchdog: Bool
    }

    struct Rerun: Equatable {
        let manual: Bool
        let requested: Bool
    }

    private(set) var isInFlight = false
    private(set) var startedAt: CFAbsoluteTime = 0
    private(set) var generation: UInt64 = 0
    private var pendingManual = false
    private var pendingRefresh = false

    mutating func request(manual: Bool, now: CFAbsoluteTime,
                          watchdogSeconds: CFAbsoluteTime) -> Request? {
        var restartedByWatchdog = false
        if isInFlight {
            if now - startedAt > watchdogSeconds {
                isInFlight = false
                restartedByWatchdog = true
            } else {
                if manual { pendingManual = true }
                pendingRefresh = true
                return nil
            }
        }
        isInFlight = true
        startedAt = now
        generation &+= 1
        return Request(generation: generation,
                       restartedByWatchdog: restartedByWatchdog)
    }

    mutating func finish(generation candidate: UInt64) -> Rerun? {
        guard candidate == generation else { return nil }
        isInFlight = false
        let rerun = Rerun(manual: pendingManual, requested: pendingRefresh)
        pendingManual = false
        pendingRefresh = false
        return rerun
    }
}

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
            let quality = UsageQueryService.CostQuality(estimated: 0, actual: 0)
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
    private var refreshCoordinator = RefreshCoordinator()
    /// 快照加载开始时间；超过看门狗阈值视为卡死，允许下一次刷新重试。
    /// 若不重置，一次永不完成的加载会让 refreshInFlight 永久为 true，
    /// didCollect 与定时器刷新全部被合并锁挡掉——popover 冻结在旧快照，
    /// 而 quota 客户端独立轮询照常更新，形成"额度在动、来源不动"。
    private static let refreshWatchdogSeconds: CFAbsoluteTime = 10
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
        NotificationCenter.default.addObserver(forName: TMNotifications.usagePeriodSettingsChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    func start() {
        refresh()
        updateForeground()
    }

    /// Foreground = popover expanded or dashboard window visible. While the
    /// user is looking, keep the existing 5s snapshot cadence and refresh
    /// immediately on activation. When everything is hidden, retain a slower
    /// cadence as a fallback; the collector's didCollect notification still
    /// refreshes immediately when new data lands.
    private func updateForeground() {
        let fg = popoverVisible || dashboardVisible
        // At launch both flags are false. The missing timer is the signal that
        // the initial background cadence still needs to be installed.
        guard fg != foreground || refreshTimer == nil else { return }
        foreground = fg
        if let t = refreshTimer {
            t.invalidate()
            refreshTimer = nil
        }
        // 5s 保险轮询：实时性由 didCollect 的变更驱动保证（新数据到达
        // 立即刷新）；后台 30s 轮询兜底 missed notifications/cache races。
        let interval = TMRefreshPolicy.snapshotInterval(foreground: fg)
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        refreshTimer = t
        if fg {
            refresh() // activation moment: show the latest numbers instantly
        }
    }

    /// Coalesced: at most one background snapshot in flight.
    /// `manual` marks user-initiated refreshes (toolbar button) so the
    /// spinner shows only for those.
    func refresh(manual: Bool = false) {
        guard let request = refreshCoordinator.request(
            manual: manual,
            now: CFAbsoluteTimeGetCurrent(),
            watchdogSeconds: Self.refreshWatchdogSeconds
        ) else { return }
        let generation = request.generation
        if request.restartedByWatchdog, DebugLog.enabled {
            NSLog("[ToastMonitor][refresh] watchdog reset inFlight")
        }
        if manual { manualRefreshing = true }
        if DebugLog.enabled {
            NSLog("[ToastMonitor][refresh] enter fg=%d popover=%d dashboard=%d",
                  foreground ? 1 : 0, popoverVisible ? 1 : 0, dashboardVisible ? 1 : 0)
        }

        let publish: (UsageQueryService.LightSnapshot, UsageQueryService.Snapshot?) -> Void = {
            [weak self] light, complete in
            guard let self, self.refreshCoordinator.generation == generation else { return }
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

        let configuration = UsagePeriodSettings.shared.configuration
        if dashboardVisible {
            UsageQueryService.shared.loadSnapshot(configuration: configuration) { [weak self] snap in
                guard let self else { return }
                publish(snap.light, snap)
                self.finishRefresh(generation: generation)
            }
        } else {
            UsageQueryService.shared.loadLightSnapshot(configuration: configuration) { [weak self] light in
                guard let self else { return }
                publish(light, nil)
                self.finishRefresh(generation: generation)
            }
        }
    }

    private func finishRefresh(generation: UInt64) {
        guard let rerun = refreshCoordinator.finish(generation: generation) else { return }
        manualRefreshing = false
        if rerun.manual || rerun.requested {
            refresh(manual: rerun.manual)
        }
    }
}
