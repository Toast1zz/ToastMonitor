import SwiftUI
import Combine
import AppKit
import Charts

/// yyyymmdd → Date（本地日历）。
private func dayFromKey(_ key: Int64) -> Date {
    var c = DateComponents()
    c.year = Int(key / 10_000)
    c.month = Int(key / 100) % 100
    c.day = Int(key % 100)
    return Calendar.current.date(from: c) ?? .distantPast
}

/// "Aug 5" 式短日期（hover 提示用）。固定英文 locale：系统为中文时
/// DateFormatter 会输出 "8月5日"，Popover 全英文必须强制 en_US。
private let shortDayFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "MMM d"
    return f
}()



/// Compact, single-purpose menu bar home. It answers three questions quickly:
/// how much was used, where it came from, and whether a limit needs attention.
struct PopoverHomeView: View {
    static let testPeriodNotification = Notification.Name("tmTestPopoverPeriod")

    /// UI-1 决策：面板隐藏时跳过分钟 tick（不推进 now、不重载热力图）。
    static func minuteTickAllowed(panelVisible: Bool) -> Bool {
        panelVisible
    }

    /// UI-1 决策：可见性通知 → (新可见状态, 是否需要本次重载热力图)。
    /// 仅在 隐藏→显示 转换时重载；其余转换（含保持显示）不重载。
    static func visibilityTransition(visible: Bool, wasVisible: Bool) -> (visible: Bool, reload: Bool) {
        (visible, visible && !wasVisible)
    }

    enum Period: String, CaseIterable, Identifiable {
        case today = "Today"
        case week = "7 Days"
        case month = "30 Days"
        case all = "All Time"
        var id: String { rawValue }

        var slot: UsagePeriodSlot {
            switch self {
            case .today: return .today
            case .week: return .week
            case .month: return .month
            case .all: return .all
            }
        }
    }

    @ObservedObject private var app = AppState.shared
    @ObservedObject private var orClient = OpenRouterClient.shared
    @ObservedObject private var goClient = OpenCodeGoClient.shared
    @ObservedObject private var codexQuota = CodexQuotaClient.shared
    @ObservedObject private var ccQuota = CommandCodeQuotaClient.shared
    @ObservedObject private var claudeQuota = ClaudeQuotaClient.shared
    @ObservedObject private var periodSettings = UsagePeriodSettings.shared
    @State private var period: Period = {
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "--period"), flag + 1 < args.count else {
            return .today
        }
        switch args[flag + 1] {
        case "week": return .week
        case "month": return .month
        case "all": return .all
        default: return .today
        }
    }()
    /// Drives countdown refresh (resets etc.) once a minute.
    @State private var now = Date()
    /// Full-number mode (1,234,567 instead of 1.2M) — switch to watch the
    /// counter tick up during streaming.
    @AppStorage("popoverFullTokens") private var fullTokens = false
    /// 年度每日用量（Popover 自持：AppState 只在 dashboard 可见时填 heatmap）。
    @State private var heatmapData: [Int64: Int64] = [:]
    @State private var detectedTools: [ToolKind] = []
    /// 面板是否可见。PopoverHomeView 常驻（面板不销毁视图），隐藏时分钟
    /// tick 与热力图重载都必须停，否则每 60s 跑一次 371 天聚合（UI-1）。
    @State private var panelVisible = false
    private let minuteTicker = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    private var totals: Database.ToolTotals {
        switch period {
        case .today: app.today
        case .week: app.week
        case .month: app.month
        case .all: app.all
        }
    }

    private var tokens: Int64 {
        switch period {
        case .today: app.todayTokens
        case .week: app.weekTokens
        case .month: app.monthTokens
        case .all: app.allTokens
        }
    }

    private var cost: UsageQueryService.CostQuality {
        switch period {
        case .today: app.costToday
        case .week: app.costWeek
        case .month: app.costMonth
        case .all: app.costAll
        }
    }

    private var byTool: [Database.ToolTotals] {
        switch period {
        case .today: app.byToolToday
        case .week: app.byToolWeek
        case .month: app.byToolMonth
        case .all: app.byToolAll
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Keep the period selector outside the scroll view. Long 7-day
            // and 30-day pages may need to scroll after the panel reaches the
            // screen-height limit, but the selector must always remain visible.
            periodControl
                .padding(.horizontal, 20)
                .padding(.top, 6)
                .padding(.bottom, 10)
                .fixedSize(horizontal: false, vertical: true)
                .reportPopoverHeight(.pinned, page: .home)

            ScrollView(.vertical, showsIndicators: false) {
                // 板块节奏统一：每块之间一条等宽分割线（撑满内容区），
                // 线上下各 10pt 间距，所有板块间距一致。
                VStack(alignment: .leading, spacing: 0) {
                    hero
                        .padding(.bottom, 10)
                    sourceBar
                    Divider().opacity(0.4)
                        .padding(.vertical, 10)
                    quotaSection
                    Divider().opacity(0.4)
                        .padding(.vertical, 10)
                    activityBlock
                    Divider().opacity(0.4)
                        .padding(.vertical, 10)
                    trendBlock
                }
                .padding(.horizontal, 20)
                .fixedSize(horizontal: false, vertical: true)
                .reportPopoverHeight(.body, page: .home)
            }
            .id(period)
            .frame(minHeight: 0, maxHeight: .infinity)
            .layoutPriority(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            loadQuotaRowHidden()
            loadDetectedTools()
            reloadHeatmap()
        }
        .onReceive(minuteTicker) { tick in
            // UI-1: 面板隐藏时跳过整轮 tick——不推进 now、不重载热力图。
            // 显示时再由可见性通知补一次加载，所以数据不会等下一个 60s。
            guard Self.minuteTickAllowed(panelVisible: panelVisible) else { return }
            now = tick
            reloadHeatmap()
        }
        .onReceive(NotificationCenter.default.publisher(for: TMNotifications.popoverVisibility)) { note in
            // UI-1: 面板常驻，可见性由通知驱动。仅在 隐藏→显示 转换时
            // 立即重载热力图（初始 onAppear 已负责首次加载）。
            let visible = (note.object as? Bool) ?? false
            let transition = Self.visibilityTransition(visible: visible, wasVisible: panelVisible)
            panelVisible = transition.visible
            if transition.reload {
                now = Date()
                reloadHeatmap()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Self.testPeriodNotification)) { note in
            guard let raw = note.object as? String else { return }
            switch raw {
            case "week": period = .week
            case "month": period = .month
            default: period = .today
            }
        }
    }

    /// Hero: the decision number is TOKENS. Below it, Spent and Value
    /// (official-rate revaluation) each get their own row.
    private var hero: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(fullTokens ? Format.full(tokens) : Format.compact(tokens))
                    .font(TMType.bold(34))
                    .tmMonospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .contentTransition(.numericText())
                    // Both the token count and the display format drive the
                    // transition, so toggling 缩写/完整 animates the same way
                    // as a live token update.
                    .animation(.easeOut(duration: 0.35), value: HeroValue(tokens: tokens, full: fullTokens))
                    .accessibilityLabel("\(periodSettings.configuration.label(for: period.slot)) token usage")
                    .accessibilityValue(Text("\(Format.full(tokens)) tokens"))
                Text("tokens")
                    .font(TMType.regular(13))
                    .foregroundStyle(.tertiary)
                Button {
                    fullTokens.toggle()
                } label: {
                    Image(systemName: fullTokens ? "number.circle.fill" : "number.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(TMDesign.faint)
                }
                .buttonStyle(.borderless)
                .help(fullTokens ? "Showing full number; click for compact (1.2M)" : "Showing compact number; click for full")
                .accessibilityLabel("Toggle number format")
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("Spent")
                        .font(TMType.monoRegular(12))
                        .foregroundStyle(.secondary)
                    Text(actualShown > 0 ? Format.money(actualShown) : "—")
                        .font(TMType.monoRegular(12))
                        .foregroundStyle(.secondary)
                }
                .help(spentHelp)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Spent")
                .accessibilityValue(Text(actualShown > 0 ? Format.money(actualShown) : "—"))
                HStack(spacing: 6) {
                    Text("Value")
                        .font(TMType.monoRegular(12))
                        .foregroundStyle(.secondary)
                    Text(estimatedShown > 0 ? Format.money(estimatedShown) : "—")
                        .font(TMType.monoRegular(12))
                        .foregroundStyle(.secondary)
                }
                .help("What these model calls would cost at official API list prices. This is not a billed amount.")
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Value")
                .accessibilityValue(Text(estimatedShown > 0 ? Format.money(estimatedShown) : "—"))
            }
        }
    }

    private var spentHelp: String {
        let base = "Billed turn costs, OpenRouter usage, and subscription amortization."
        return period == .all
            ? base + " OpenRouter only exposes its recent monthly window, not full account history."
            : base
    }

    @ViewBuilder
    private var periodControl: some View {
        let labels = Period.allCases.map { periodSettings.configuration.label(for: $0.slot) }
        if #available(macOS 26.0, *) {
            NativePeriodSelector(selection: $period, labels: labels)
                // PopoverRootView intentionally makes ordinary controls
                // small. This top-level range selector is the exception: the
                // native macOS 26/27 metric is a 36 pt extra-large capsule.
                .environment(\.controlSize, .extraLarge)
                .accessibilityLabel("Period")
        } else {
            NativePeriodSelector(selection: $period, labels: labels)
                .environment(\.controlSize, .large)
                .accessibilityLabel("Period")
        }
    }

    /// 实际支出 = turns 实际 + OpenRouter 今日实际 + 全部订阅摊销。
    private var actualShown: Double {
        cost.actual + periodOrUsage + subsAmortized
    }

    /// API 价值 = 全部工具（含 hermes）turns 按模型官方单价重估。
    private var estimatedShown: Double {
        switch period {
        case .today: return app.apiValueToday
        case .week: return app.apiValueWeek
        case .month: return app.apiValueMonth
        case .all: return app.apiValueAll
        }
    }

    private var periodOrUsage: Double {
        switch period {
        case .today: orClient.state.usageDaily
        case .week: orClient.state.usageWeekly
        case .month: orClient.state.usageMonthly
        // OpenRouter 只提供月窗口；全部时按最近月近似。
        case .all: orClient.state.usageMonthly
        }
    }

    private var subsAmortized: Double {
        let days: Int
        switch period {
        case .today: days = 1
        case .week: days = 7
        case .month: days = 30
        // 全部：10 年窗口覆盖全部订阅期（含已结束的），全额计入。
        case .all: days = 3650
        }
        return SubscriptionMath.amortized(days: days, subscriptions: app.subscriptions)
    }

    /// 来源分段条 + 每来源一行（行尾直接显示占比，无隐式交互）。
    private var sourceBar: some View {
        let rows = sortedRows
        let total = rows.reduce(Int64(0)) {
            $0 + (ToolKind(rawValue: $1.tool)?.totalTokens($1) ?? ($1.input + $1.output))
        }
        return VStack(alignment: .leading, spacing: 8) {
            if rows.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Get Started")
                        .font(TMType.semibold(TMType.body))
                    Text(detectedTools.isEmpty
                         ? "No supported local tools detected"
                         : "Detected: \(detectedTools.map(\.displayName).joined(separator: ", "))")
                        .font(TMType.regular(TMType.caption))
                        .foregroundStyle(TMDesign.quiet)
                        .lineLimit(2)
                    Button("Configure Sources") {
                        WindowManager.shared.show(tab: .settings)
                        NotificationCenter.default.post(name: PanelController.hideNotification,
                                                        object: nil)
                    }
                    .controlSize(.small)
                }
            } else {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        // 轨道：系统低层级填充（不发光）
                        Capsule().fill(Color.primary.opacity(0.06))
                        HStack(spacing: 0) {
                            ForEach(rows, id: \.tool) { row in
                                let value = ToolKind(rawValue: row.tool)?.totalTokens(row) ?? (row.input + row.output)
                                let ratio = total > 0 ? CGFloat(value) / CGFloat(total) : 0
                                Rectangle()
                                    .fill(ToolKind(rawValue: row.tool)?.color ?? TMDesign.accent)
                                    .frame(width: geo.size.width * ratio)
                            }
                        }
                        .clipShape(Capsule())
                    }
                }
                .frame(height: 6)
                .accessibilityHidden(true)

                ForEach(rows, id: \.tool) { row in
                    HStack(spacing: 7) {
                        Circle()
                            .fill(ToolKind(rawValue: row.tool)?.color ?? TMDesign.accent)
                            .frame(width: 7, height: 7)
                        Text(ToolKind(rawValue: row.tool)?.displayName ?? row.tool)
                            .font(TMType.medium(TMType.body))
                            .italic()
                            .foregroundStyle(.primary)
                        Text("(\(percentText(row, total: total)))")
                            .font(TMType.monoRegular(TMType.caption))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(Format.compact(ToolKind(rawValue: row.tool)?.totalTokens(row) ?? (row.input + row.output)))
                            .font(TMType.monoRegular(TMType.body))
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(ToolKind(rawValue: row.tool)?.displayName ?? row.tool)
                    .accessibilityValue(Text("\(Format.full(ToolKind(rawValue: row.tool)?.totalTokens(row) ?? (row.input + row.output))) tokens, \(percentText(row, total: total)) of total"))
                }
            }
        }
    }

    private func loadDetectedTools() {
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            var tools: [ToolKind] = []
            if fm.fileExists(atPath: ClaudeCodeParser.root)
                || fm.fileExists(atPath: ClaudeCodeParser.coworkLocalAgentRoot) { tools.append(.claude) }
            if fm.fileExists(atPath: CodexParser.sessionsRoot) { tools.append(.codex) }
            if fm.fileExists(atPath: OpenCodeParser.dbPath) { tools.append(.opencode) }
            if fm.fileExists(atPath: HermesParser.dbPath) { tools.append(.hermes) }
            if fm.fileExists(atPath: OmpParser.root) { tools.append(.omp) }
            if fm.fileExists(atPath: DSHParser.projCachePath)
                || !DSHParser.listSessionFiles().isEmpty { tools.append(.dsh) }
            DispatchQueue.main.async { detectedTools = tools }
        }
    }

    private func percentText(_ row: Database.ToolTotals, total: Int64) -> String {
        let value = ToolKind(rawValue: row.tool)?.totalTokens(row) ?? (row.input + row.output)
        let ratio = total > 0 ? Double(value) / Double(total) : 0
        return String(format: "%.1f%%", ratio * 100)
    }

    private var sortedRows: [Database.ToolTotals] {
        byTool.sorted {
            (ToolKind(rawValue: $0.tool)?.totalTokens($0) ?? ($0.input + $0.output)) >
                (ToolKind(rawValue: $1.tool)?.totalTokens($1) ?? ($1.input + $1.output))
        }
    }

    // MARK: - 额度状态（实时账户快照，与所选周期无关）

    /// Quota/balance is a live account snapshot — it only changes as time
    /// passes, never with the selected period. Showing it inside the period
    /// switcher implied it varied per dimension, so it now lives in its own
    /// fixed section below the period content, labelled as such.
    private var quotaSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle("Quota")
            if !(quotaRowHidden["claude"] ?? false) { claudeStatusRow }
            if !(quotaRowHidden["go"] ?? false) { goStatusRow }
            if !(quotaRowHidden["codex"] ?? false) { codexStatusRow }
            if !(quotaRowHidden["cc"] ?? false) { commandCodeStatusRow }
            if !(quotaRowHidden["router"] ?? false) { routerStatusRow }
        }
    }

    /// Per-row visibility (key = "go" / "codex" / "router"), mirrored from
    /// the `hide_quota_row_<key>` setting. Mutations update this state
    /// immediately so the row disappears on click; persistence is instant too.
    @State private var quotaRowHidden: [String: Bool] = [:]

    private static func quotaRowHiddenKey(_ key: String) -> String {
        "hide_quota_row_\(key)"
    }

    private func loadQuotaRowHidden() {
        for key in ["claude", "go", "codex", "cc", "router"] {
            quotaRowHidden[key] = Database.shared.setting(Self.quotaRowHiddenKey(key)) == "1"
        }
    }

    private func hideQuotaRow(_ key: String) {
        quotaRowHidden[key] = true
        _ = Database.shared.setSetting(Self.quotaRowHiddenKey(key), "1")
    }

    // MARK: - 活动与趋势（历史维度，与周期选择无关）

    /// 近半年活动热力图板块（参考图布局：网格 + 右上角 active days）。
    private var activityBlock: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                SectionTitle("Activity")
                Spacer()
                Text("\(activeDays) active days")
                    .font(TMType.monoRegular(TMType.caption))
                    .foregroundStyle(.secondary)
            }
            PopoverHeatmap(weeks: activityWeeks,
                           heatmap: heatmapData,
                           maxTokens: heatmapData.values.max() ?? 0)
        }
    }

    /// 最近 60 天每日用量曲线板块（参考图布局：折线 + 右上角 peak）。
    /// 悬停状态由 TrendChartView 独占（UI-2），标题行只显示 Peak。
    private var trendBlock: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                SectionTitle("Trend")
                Spacer()
                Text("Peak \(Format.compact(trendPeak))")
                    .font(TMType.monoRegular(TMType.caption))
                    .foregroundStyle(.secondary)
            }
            TrendChartView(series: trendSeries)
        }
        // Keep the x-axis labels inside the measured scroll document. A
        // visual `offset` is not included in SwiftUI's layout size, which let
        // the fixed footer clip the bottom of the dates.
        .padding(.bottom, 6)
    }

    /// UserDefaults 持久化的上次热力图数据：冷启动先显示旧曲线，
    /// 异步刷新后再更新，避免 Activity/Trend 区块空白等待。
    private static let heatmapCacheKey = "popoverHeatmapCache"

    private func cachedHeatmap() -> [Int64: Int64]? {
        guard let data = UserDefaults.standard.data(forKey: Self.heatmapCacheKey),
              let dict = try? JSONDecoder().decode([String: Int64].self, from: data) else { return nil }
        var out: [Int64: Int64] = [:]
        for (k, v) in dict {
            if let key = Int64(k) { out[key] = v }
        }
        return out.isEmpty ? nil : out
    }

    private func saveHeatmapCache(_ map: [Int64: Int64]) {
        let dict = Dictionary(uniqueKeysWithValues: map.map { (String($0.key), $0.value) })
        if let data = try? JSONEncoder().encode(dict) {
            UserDefaults.standard.set(data, forKey: Self.heatmapCacheKey)
        }
    }

    private func reloadHeatmap() {
        // 打开时立即用缓存数据渲染，再异步刷新。
        if heatmapData.isEmpty, let cached = cachedHeatmap() {
            heatmapData = cached
        }
        UsageQueryService.shared.loadHeatmap { map in
            guard map != self.heatmapData else { return }
            self.heatmapData = map
            self.saveHeatmapCache(map)
        }
    }

    private var activeDays: Int {
        heatmapData.values.filter { $0 > 0 }.count
    }

    /// 最近 60 天（含今天）按日排序的用量序列。
    private var trendSeries: [(key: Int64, tokens: Int64)] {
        heatmapData.sorted { $0.key < $1.key }
            .suffix(60)
            .map { ($0.key, $0.value) }
    }

    private var trendPeak: Int64 {
        trendSeries.map(\.tokens).max() ?? 0
    }

    /// 近 26 周（6 个月）网格：key 与 heatmapData 的 yyyymmdd（本地日）对齐。
    private var activityWeeks: [[Int64?]] {
        Self.buildHeatmapWeeks(now: Date(), configuration: periodSettings.configuration)
    }

    private static func buildHeatmapWeeks(now: Date,
                                          configuration: UsagePeriodConfiguration) -> [[Int64?]] {
        var weeks: [[Int64?]] = []
        let calendar = configuration.configuredCalendar()
        let weekStart = configuration.startOfConfiguredWeek(now, calendar: calendar)
        for week in 0..<26 {
            var column: [Int64?] = []
            for day in 0..<7 {
                guard let date = calendar.date(byAdding: .day, value: week * 7 + day - 25 * 7, to: weekStart) else {
                    column.append(nil)
                    continue
                }
                if date > now {
                    column.append(nil)
                } else {
                    let components = calendar.dateComponents([.year, .month, .day], from: date)
                    let key = (components.year ?? 0) * 10_000 + (components.month ?? 0) * 100 + (components.day ?? 0)
                    column.append(Int64(key))
                }
            }
            weeks.append(column)
        }
        return weeks
    }

    private func resetText(_ at: Int64?) -> String? {
        guard let at, at > Int64(now.timeIntervalSince1970) else { return nil }
        return "resets in \(Format.remaining(at - Int64(now.timeIntervalSince1970)))"
    }

    private var goStatusRow: some View {
        let state = goClient.state
        let remaining = state.monthlyPct.map { 100 - $0 }
        let stale = state.lastSync > 0
            && now.timeIntervalSince1970 - TimeInterval(state.lastSync) > 120
        var status = goClient.configured ? "Loading" : "Not configured"
        var resetSuffix: String?
        // Same "prefer the cached number" reasoning as Claude's row: a
        // stale percentage is still more useful than the word "Stale", so
        // the last known value stays on screen with a small freshness badge
        // instead of being replaced.
        var staleBadge: String?
        if !goClient.configured {
            // A locked/re-authorized Keychain reads back exactly like
            // "never configured" from credentials() — surface which one it
            // actually is instead of always saying "Not configured", or a
            // real credentials loss looks identical to a rebuild-triggered
            // Keychain re-auth prompt that never happened.
            status = (state.error?.localizedCaseInsensitiveContains("keychain") == true) ? "Keychain locked" : "Not configured"
        } else if let remaining {
            status = "\(Int(remaining))% monthly left"
            resetSuffix = resetText(state.monthlyReset.map { state.lastSync + $0 })
            if stale {
                let age = now.timeIntervalSince1970 - TimeInterval(state.lastSync)
                staleBadge = "\(Format.remaining(Int64(age))) ago"
            }
        } else if state.error != nil {
            status = "Error"
        }
        // Go also reports a weekly window alongside the monthly one; shown
        // as a quiet subtitle only once real data has loaded, same pattern
        // as Claude's 5h line — a plan with unlimited/no weekly cap simply
        // never sets weeklyPct, so this stays hidden rather than showing 0%.
        let weeklySubtitle = state.weeklyPct.map { "\(Int(100 - $0))% weekly left" }
        return statusRow(name: "OpenCode Go", status: status,
                         statusColor: .primary,
                         critical: remaining.map { $0 < 20 } ?? false,
                         resetSuffix: resetSuffix,
                         subtitle: weeklySubtitle,
                         staleBadge: staleBadge,
                         hideKey: "go")
    }

    /// Claude subscription quota, from the same OAuth usage endpoint Claude
    /// Code's own status line reads. Claude bills against two independent
    /// windows at once (a 5h rolling one and a weekly one). The weekly one
    /// is the number that matters day to day, so it takes the value column
    /// — same two-line shape (status + reset) as every other Quota row, so
    /// rows stay the same height. The 5h window goes under the name instead,
    /// as a quiet subtitle; it still turns the row critical (★) on its own
    /// if it's the one running low, even though it isn't the headline number.
    ///
    /// Claude's cadence (5min foreground-only, plus real backoff after a
    /// 429) means it sits without a fresh answer far more often than the
    /// other quota rows. A cached number that's a few minutes old is still
    /// useful; the word "Stale" on its own is not — so, matching how
    /// Command Code GOAT already handles this, the last known percentage
    /// stays on screen instead of being replaced by a status word, and a
    /// bare "Error" only appears once there's truly nothing cached to fall
    /// back on. The reset countdown on the second line is unaffected by any
    /// of this — it comes straight from the server and stays accurate
    /// whether or not the percentage above it is fresh, so it's shown as-is
    /// either way. Staleness gets its own small pill next to the percentage
    /// instead — a single signal, not a second one stacked on top via a
    /// dimmed color as well.
    private var claudeStatusRow: some View {
        let state = claudeQuota.state
        let weekly = state.sevenDay
        let remaining = weekly.map { 100 - $0.usedPercent }
        let stale = state.lastSync > 0
            && now.timeIntervalSince1970 - TimeInterval(state.lastSync) > 120
        var status = state.configured ? "Loading" : "Not configured"
        var resetSuffix: String?
        var staleBadge: String?
        if !claudeQuota.enabled {
            // Opt-in, off by default (see ClaudeQuotaClient) — distinct from
            // "Not configured" so it reads as a choice, not a missing login.
            status = "Off — enable in Dashboard"
        } else if let remaining, let weekly {
            status = "\(remaining)% weekly left"
            resetSuffix = resetText(weekly.resetAt)
            if stale {
                let age = now.timeIntervalSince1970 - TimeInterval(state.lastSync)
                staleBadge = "\(Format.remaining(Int64(age))) ago"
            }
        } else if state.error != nil {
            status = "Error"
        }
        // The star has to sit on whichever number is actually low — the
        // weekly line if that's the tight one, the 5h/Opus subtitle if
        // that's the one about to run out, never just the primary line by
        // default regardless of which window earned it.
        return statusRow(name: claudeRowName, status: status,
                         statusColor: .primary,
                         critical: claudeQuota.enabled && (remaining.map { $0 < 20 } ?? false),
                         resetSuffix: resetSuffix,
                         subtitle: claudeQuota.enabled ? claudeSubtitle(state) : nil,
                         subtitleCritical: claudeQuota.enabled && state.hasCriticalSecondaryWindow,
                         staleBadge: staleBadge,
                         hideKey: "claude")
    }

    /// The 5h window (and, rarely, a weekly-Opus one) rendered as a compact
    /// caption under the name — "84% 5h left", joined with " · " if both are
    /// present. Shown whenever cached data exists, even mid-error or while
    /// stale — same "prefer the cached number" reasoning as the row above.
    private func claudeSubtitle(_ state: ClaudeQuotaClient.State) -> String? {
        let windows = [state.fiveHour, state.sevenDayOpus].compactMap { $0 }
        guard !windows.isEmpty else { return nil }
        return windows.map { "\(100 - $0.usedPercent)% \($0.label) left" }.joined(separator: " · ")
    }

    /// "Claude Max" / "Claude Pro" when the plan is known, plain "Claude"
    /// otherwise — the credentials blob does not always carry a plan.
    private var claudeRowName: String {
        let plan = claudeQuota.state.planType?.lowercased() ?? ""
        let suffix = claudeQuota.state.error == nil ? "" : " ⚠"
        if plan.contains("max") { return "Claude Max" + suffix }
        if plan.contains("pro") { return "Claude Pro" + suffix }
        return "Claude" + suffix
    }

    /// Window label derives from limit_window_seconds: 604800 = weekly (Plus today).
    private var windowLabel: String {
        guard let s = codexQuota.state.windowSeconds else { return "limit" }
        if s >= 7 * 86400 { return "weekly" }
        if s >= 86400 { return "every \(s / 86400) days" }
        if s >= 3600 { return "every \(s / 3600) hours" }
        return "limit"
    }

    private var codexStatusRow: some View {
        let state = codexQuota.state
        let remaining = state.primaryPct.map { 100 - Double($0) }
        // The plan picker stores "openai" for the ChatGPT/Codex subscription;
        // "codex" alone never matched anything a user could actually save.
        let sub = app.subscriptions.first { $0.plan == "openai" || $0.plan == "codex" }
        let stale = state.lastSync > 0
            && now.timeIntervalSince1970 - TimeInterval(state.lastSync) > 120
        // 刷新期间保留上次结果：只有从未同步过才显示 Loading。
        var status = sub == nil ? "Not configured"
                    : (state.lastSync <= 0 ? "Loading" : "Idle")
        var resetSuffix: String?
        var staleBadge: String?
        if let remaining {
            status = "\(Int(remaining))% of \(windowLabel) left"
            resetSuffix = resetText(state.resetAt)
            if stale {
                let age = now.timeIntervalSince1970 - TimeInterval(state.lastSync)
                staleBadge = "\(Format.remaining(Int64(age))) ago"
            }
        } else if state.error != nil {
            status = "Error"
        } else if let sub {
            status = "Subscribed · \(Format.money(sub.price))/mo"
        }
        return statusRow(name: "Codex Plus", status: status,
                         statusColor: .primary,
                         critical: remaining.map { $0 < 20 } ?? false,
                         resetSuffix: resetSuffix,
                         staleBadge: staleBadge,
                         hideKey: "codex")
    }

    /// Command Code GOAT quota (experimental private billing API).
    /// Shows the last good snapshot while a refresh is in flight — never a
    /// Stale interstitial — and replaces it when fresh data lands.
    private var commandCodeStatusRow: some View {
        let state = ccQuota.state
        let name = "Command Code GOAT" + (state.error == nil ? "" : " ⚠")
        let stale = state.lastSync > 0
            && now.timeIntervalSince1970 - TimeInterval(state.lastSync) > 120
        var status = state.configured ? "Loading" : "Not configured"
        var resetSuffix: String?
        var staleBadge: String?
        if let percent = state.monthlyUsedPercent {
            // Known plan: remaining = 100 − used. Cached value is shown
            // while refreshing; it updates in place when new data lands.
            status = "\(Int((100 - percent).rounded()))% monthly left"
            if let end = state.billingPeriodEnd {
                let remaining = end.timeIntervalSince1970 - now.timeIntervalSince1970
                if remaining > 0 {
                    resetSuffix = "resets in \(Format.remaining(Int64(remaining)))"
                }
            }
            if stale {
                let age = now.timeIntervalSince1970 - TimeInterval(state.lastSync)
                staleBadge = "\(Format.remaining(Int64(age))) ago"
            }
        } else if state.error != nil {
            status = "Error"
        } else if let remaining = state.monthlyCreditsRemaining {
            // Unknown plan or no allowance: show remaining only, no percent.
            status = "$\(Format.money(remaining)) left"
        } else if state.configured && state.lastSync <= 0 {
            status = "Loading"
        }
        return statusRow(name: name, status: status,
                         statusColor: .primary,
                         // Star = running low: remaining below 20% (used > 80%).
                         critical: state.monthlyUsedPercent.map { $0 > 80 } ?? false,
                         resetSuffix: resetSuffix,
                         staleBadge: staleBadge,
                         hideKey: "cc")
    }

    private var routerStatusRow: some View {
        let state = orClient.state
        let stale = state.lastOK > 0
            && now.timeIntervalSince1970 - TimeInterval(state.lastOK) > 120
        var status: String
        var staleBadge: String?
        if !orClient.hasKey {
            status = "Not configured"
        } else if let balance = state.accountBalance {
            status = "Balance \(Format.money(balance))"
            if stale {
                let age = now.timeIntervalSince1970 - TimeInterval(state.lastOK)
                staleBadge = "\(Format.remaining(Int64(age))) ago"
            }
        } else if state.error != nil {
            status = "Error"
        } else if state.isLoading && state.lastOK <= 0 {
            status = "Loading"
        } else {
            status = "Idle"
        }
        return statusRow(name: "OpenRouter", status: status,
                         statusColor: orClient.hasKey ? .primary : TMDesign.quiet,
                         staleBadge: staleBadge,
                         hideKey: "router")
    }

    private func statusRow(name: String, status: String, statusColor: Color,
                           critical: Bool = false, resetSuffix: String? = nil,
                           subtitle: String? = nil, subtitleCritical: Bool = false,
                           staleBadge: String? = nil,
                           hideKey: String? = nil) -> some View {
        StatusRow(name: name, status: status, statusColor: statusColor,
                  critical: critical, resetSuffix: resetSuffix, subtitle: subtitle,
                  subtitleCritical: subtitleCritical, staleBadge: staleBadge,
                  hideAction: hideKey.map { key in { self.hideQuotaRow(key) } })
    }

}

/// 趋势折线图独占悬停状态（UI-2，同 PopoverHeatmap 模式）：悬停只重渲
/// 本子视图，不重渲整页。悬停信息行放在图上方、固定行高，无悬停时空占位。
private struct TrendChartView: View {
    /// 最近 60 天（含今天）按日排序的用量序列。
    let series: [(key: Int64, tokens: Int64)]

    @State private var hoveredTrend: (key: Int64, tokens: Int64)?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if let h = hoveredTrend {
                    Text("\(shortDayFormatter.string(from: dayFromKey(h.key))) · \(Format.compact(h.tokens))")
                        .font(TMType.monoRegular(TMType.caption))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .frame(height: 16)
            // Charts 平滑折线（catmullRom）。冷启动延迟由热力图缓存解决：
            // 打开时先用上次持久化的数据立即渲染，再异步刷新新曲线。
            Chart(series, id: \.key) { d in
                LineMark(
                    x: .value("Day", dayFromKey(d.key)),
                    y: .value("Tokens", d.tokens)
                )
                .foregroundStyle(TMDesign.accent)
                .interpolationMethod(.catmullRom)
            }
            .chartXAxis {
                // 3 个日期标签，颜色与 Activity 月份标签一致（TMDesign.quiet）。
                AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                    AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
                    AxisValueLabel(format: .dateTime.month(.defaultDigits).day())
                        .font(.system(size: 9))
                        .foregroundStyle(TMDesign.quiet)
                }
            }
            .chartYAxis(.hidden)
            .frame(height: 76)
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle().fill(Color.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                guard let date = proxy.value(atX: location.x, as: Date.self) else { return }
                                let day = Calendar.current.startOfDay(for: date)
                                if let hit = series.first(where: {
                                    Calendar.current.isDate(dayFromKey($0.key), inSameDayAs: day)
                                }) {
                                    hoveredTrend = hit
                                } else {
                                    hoveredTrend = nil
                                }
                            case .ended:
                                hoveredTrend = nil
                            }
                        }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Daily usage trend")
            .accessibilityChildren {
                ForEach(series, id: \.key) { day in
                    Text(shortDayFormatter.string(from: dayFromKey(day.key)))
                        .accessibilityValue("\(Format.full(day.tokens)) tokens")
                }
            }
        }
    }
}

/// The period choices replace the visible dashboard content, so on macOS 27
/// this is a tabs control rather than an inspector-style value picker. The
/// tabs role is also what supplies the native draggable Liquid Glass selection
/// island shown by system apps. The control draws all chrome itself; there is
/// no material or glass wrapper.
private struct NativePeriodSelector: NSViewRepresentable {
    @Binding var selection: PopoverHomeView.Period
    var labels: [String]

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection)
    }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(
            labels: labels,
            trackingMode: .selectOne,
            target: context.coordinator,
            action: #selector(Coordinator.selectionChanged(_:))
        )
        control.segmentDistribution = .fillEqually
        control.selectedSegment = selectedIndex
        if #available(macOS 26.0, *) {
            // The current macOS value-selection control uses the system's
            // extra-large 36 pt metric. `.large` is the 28 pt compact form
            // and is why the popover still looked like the previous design.
            control.controlSize = .extraLarge
            control.borderShape = .capsule
        } else {
            control.controlSize = .large
        }
        if #available(macOS 27.0, *) {
            control.role = .tabs
        }
        control.setAccessibilityLabel("Period")
        control.setAccessibilityHelp("Changes the usage time range")
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.selection = $selection
        for (index, label) in labels.enumerated() where index < control.segmentCount {
            if control.label(forSegment: index) != label {
                control.setLabel(label, forSegment: index)
            }
        }
        // SwiftUI can propagate the root `.small` environment into the
        // represented NSControl after makeNSView. Reassert the platform's
        // native metric on updates so its intrinsic height remains 36 pt.
        if #available(macOS 26.0, *) {
            if control.controlSize != .extraLarge {
                control.controlSize = .extraLarge
                control.invalidateIntrinsicContentSize()
            }
        } else if control.controlSize != .large {
            control.controlSize = .large
            control.invalidateIntrinsicContentSize()
        }
        if control.selectedSegment != selectedIndex {
            control.selectedSegment = selectedIndex
        }
    }

    private var selectedIndex: Int {
        PopoverHomeView.Period.allCases.firstIndex(of: selection) ?? 0
    }

    @MainActor
    final class Coordinator: NSObject {
        var selection: Binding<PopoverHomeView.Period>

        init(selection: Binding<PopoverHomeView.Period>) {
            self.selection = selection
        }

        @objc func selectionChanged(_ sender: NSSegmentedControl) {
            let periods = PopoverHomeView.Period.allCases
            guard periods.indices.contains(sender.selectedSegment) else { return }
            selection.wrappedValue = periods[sender.selectedSegment]
        }
    }
}


/// Drives the hero number transition: any change to the token count OR the
/// 缩写/完整 format toggle re-runs the same numericText animation.
private struct HeroValue: Equatable {
    let tokens: Int64
    let full: Bool
}

/// 额度状态行：名称 primary，状态按健康状态着色。纯信息行，不引导跳转。
/// 状态主文本是 SF Pro Regular + 等宽数字；可选的 "resets in …" 后缀单独用
/// SF Mono Regular，不让整行变成等宽。提供 hideAction 时行尾会出现一个
/// 眼睛按钮（hover 显示），点击将该配额行隐藏。
private struct StatusRow: View {
    let name: String
    let status: String
    let statusColor: Color
    var critical = false
    /// Now sits under the name rather than under the value, so the name
    /// column and the value column both read top-to-bottom as "headline,
    /// then detail" — name/when on the left, percent/percent on the right.
    var resetSuffix: String?
    /// A quiet second value under the primary one — for a source that bills
    /// against more than one window at once (Claude's 5h + weekly), this
    /// carries the window not already shown as the primary value.
    var subtitle: String?
    /// Puts the ★ on the subtitle line instead of the status line — for a
    /// source with more than one window, the one running low isn't always
    /// the one shown as the primary value, and the star has to follow
    /// whichever number actually earned it.
    var subtitleCritical = false
    /// A small pill next to the status text (e.g. "6m ago") flagging that
    /// the number is cached rather than fresh. Deliberately a capsule, not
    /// plain text appended to the status string — plain text read as part
    /// of the sentence and was easy to miss at a glance; a distinct chip
    /// reads as metadata immediately.
    var staleBadge: String?
    var hideAction: (() -> Void)?

    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            // 固定两行高度：空字符串 Text 固有高度会塌缩为 0，所以用
            // 显式 frame 占位——Loading → 数据切换时行高恒定，面板不跳。
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(TMType.medium(TMType.body))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .frame(height: TMLayout.quotaPrimaryLineHeight, alignment: .leading)
                Text(resetSuffix ?? "")
                    .font(TMType.monoRegular(TMType.micro))
                    .foregroundStyle(TMDesign.quiet)
                    .lineLimit(1)
                    .frame(height: TMLayout.quotaSecondaryLineHeight, alignment: .leading)
                    .opacity(resetSuffix == nil ? 0 : 1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 5) {
                    // Badge first, status text last: the HStack is
                    // trailing-aligned, so the status text's right edge —
                    // where every other row's number also lands — never
                    // moves whether or not the badge is present.
                    if let staleBadge {
                        Text(staleBadge)
                            .font(TMType.monoRegular(TMType.micro))
                            .foregroundStyle(TMDesign.quiet)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(TMDesign.quiet.opacity(0.14), in: Capsule(style: .continuous))
                    }
                    if critical {
                        TMStatusCapsule(text: status, compact: true)
                            .lineLimit(1)
                    } else {
                        Text(status)
                            .font(TMType.monoRegular(TMType.body))
                            .foregroundStyle(statusColor)
                            .lineLimit(1)
                    }
                }
                .frame(height: TMLayout.quotaPrimaryLineHeight, alignment: .trailing)
                Text((subtitleCritical ? "★ " : "") + (subtitle ?? ""))
                    .font(TMType.monoRegular(TMType.micro))
                    .foregroundStyle(TMDesign.quiet)
                    .lineLimit(1)
                    .frame(height: TMLayout.quotaSecondaryLineHeight, alignment: .trailing)
                    .opacity(subtitle == nil ? 0 : 1)
            }
            .layoutPriority(1)

            if let hideAction, hovering {
                Button(action: hideAction) {
                    Image(systemName: "eye.slash")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Hide this quota row")
                .padding(.leading, 2)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(name)
        .accessibilityValue(Text([status, resetSuffix].compactMap { $0 }.joined(separator: " · ")))
    }
}

/// 紧凑近半年活动热力图（Popover 版）：26 周 × 7 天方格，月份标签悬浮在
/// 网格上方。无悬停交互——活跃度一眼扫读即可。
private struct PopoverHeatmap: View {
    let weeks: [[Int64?]]
    let heatmap: [Int64: Int64]
    let maxTokens: Int64

    /// 网格与月份标签的垂直间距。
    private let labelGap: CGFloat = 14
    private let cellGutter: CGFloat = 3

    /// Grid cells divide the shared popover content width evenly.
    private var gridHeight: CGFloat {
        let contentWidth = TMLayout.popoverContentWidth
        let cell = max((contentWidth - CGFloat(weeks.count - 1) * cellGutter) / CGFloat(weeks.count), 2)
        return labelGap + 7 * cell + 6 * cellGutter
    }

    /// 26 周均分 6 个标签：无论各月实际周数，标签间距恒定，
    /// 名字取该周所在月份。
    private var monthLabels: [(index: Int, label: String)] {
        let count = 6
        let step = Double(weeks.count) / Double(count)
        var out: [(Int, String)] = []
        for i in 0..<count {
            let wi = min(Int(Double(i) * step), max(weeks.count - 1, 0))
            guard let first = weeks[wi].compactMap({ $0 }).first else { continue }
            let month = (Int(first) / 100) % 100
            out.append((wi, MonthAxis.names[month - 1]))
        }
        return out
    }

    @State private var hoveredDay: (key: Int64, tokens: Int64)?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // 悬停信息行：无悬停时空占位，保持高度稳定。
            HStack {
                if let h = hoveredDay {
                    Text("\(shortDayFormatter.string(from: dayFromKey(h.key))) · \(Format.compact(h.tokens)) tokens")
                        .font(TMType.monoRegular(9))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .frame(height: 11)
            GeometryReader { geo in
                let cell = max((geo.size.width - CGFloat(weeks.count - 1) * cellGutter) / CGFloat(weeks.count), 2)
                ZStack(alignment: .topLeading) {
                    HStack(alignment: .top, spacing: cellGutter) {
                        ForEach(weeks.indices, id: \.self) { wi in
                            VStack(spacing: cellGutter) {
                                ForEach(0..<7, id: \.self) { di in
                                    heatCell(weeks[wi][di], size: cell)
                                }
                            }
                        }
                    }
                    .padding(.top, labelGap)
                    ForEach(monthLabels, id: \.index) { m in
                        Text(m.label)
                            .font(TMType.monoRegular(9))
                            .foregroundStyle(TMDesign.quiet)
                            .fixedSize()
                            .offset(x: CGFloat(m.index) * (cell + cellGutter), y: 0)
                    }
                }
            }
            .frame(height: gridHeight)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Activity heatmap, six months")
    }

    private func heatCell(_ key: Int64?, size: CGFloat) -> some View {
        let v = key.flatMap { heatmap[$0] } ?? 0
        let ratio = maxTokens > 0 ? Double(v) / Double(maxTokens) : 0
        // 线性渐变不变；下限 0.4 保证任何有数据的日子（包括当天——其
        // 比例常被峰值日压到 0.01 以下）都明显可见，而大日子保持原有
        // 梯度。精确数值由悬停提供。
        let opacity = max(0.4, 0.25 + 0.75 * ratio)
        return RoundedRectangle(cornerRadius: 1, style: .continuous)
            .fill(v > 0
                  ? TMDesign.accent.opacity(opacity)
                  : Color.primary.opacity(0.06))
            .frame(width: size, height: size)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering, let key {
                    hoveredDay = (key, v)
                } else if hoveredDay?.key == key {
                    hoveredDay = nil
                }
            }
            .accessibilityElement()
            .accessibilityLabel(key.map { shortDayFormatter.string(from: dayFromKey($0)) } ?? "")
            .accessibilityValue("\(Format.full(v)) tokens")
            .accessibilityHidden(key == nil)
    }
}
