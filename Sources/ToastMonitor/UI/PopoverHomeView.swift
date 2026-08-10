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

    enum Period: String, CaseIterable, Identifiable {
        case today = "Today"
        case week = "7 Days"
        case month = "30 Days"
        case all = "All Time"
        var id: String { rawValue }
    }

    @ObservedObject private var app = AppState.shared
    @ObservedObject private var orClient = OpenRouterClient.shared
    @ObservedObject private var goClient = OpenCodeGoClient.shared
    @ObservedObject private var codexQuota = CodexQuotaClient.shared
    @State private var period: Period = .today
    /// Drives countdown refresh (resets etc.) once a minute.
    @State private var now = Date()
    /// Full-number mode (1,234,567 instead of 1.2M) — switch to watch the
    /// counter tick up during streaming.
    @AppStorage("popoverFullTokens") private var fullTokens = false
    /// 年度每日用量（Popover 自持：AppState 只在 dashboard 可见时填 heatmap）。
    @State private var heatmapData: [Int64: Int64] = [:]
    /// Trend 悬停命中的日数据；无悬停时标题行显示 Peak。
    @State private var hoveredTrend: (key: Int64, tokens: Int64)?
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
                .padding(.top, 14)
                .padding(.bottom, 12)
                .fixedSize(horizontal: false, vertical: true)
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .onAppear {
                                // Defer past the first layout pass: the initial
                                // size can be a stale viewport value, which
                                // made the panel height wrong until a period
                                // switch re-measured it.
                                DispatchQueue.main.async {
                                    postPanelHeight(kind: "pinned", height: geo.size.height)
                                }
                            }
                            .onChange(of: geo.size.height) { _, h in
                                postPanelHeight(kind: "pinned", height: h)
                            }
                    }
                )

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
                // A ScrollView normally accepts the viewport's proposed
                // height, which made every period report the same 684pt panel
                // height. Force the document to keep its natural vertical
                // size so 7-day / 30-day pages can actually grow the panel.
                .fixedSize(horizontal: false, vertical: true)
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .onAppear {
                                DispatchQueue.main.async {
                                    postPanelHeight(kind: "body", height: geo.size.height)
                                }
                            }
                            .onChange(of: geo.size.height) { _, h in
                                postPanelHeight(kind: "body", height: h)
                            }
                    }
                )
            }
            .onChange(of: period) { _, _ in
                // Reset the underlying NSClipView after SwiftUI updates the
                // document and PanelController resizes the NSPanel.
                NotificationCenter.default.post(
                    name: PanelController.resetScrollNotification,
                    object: nil
                )
            }
            .frame(minHeight: 0, maxHeight: .infinity)
            .layoutPriority(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { reloadHeatmap() }
        .onReceive(minuteTicker) {
            now = $0
            reloadHeatmap()
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
                    .contentTransition(.numericText(value: Double(tokens)))
                    // Both the token count and the display format drive the
                    // transition, so toggling 缩写/完整 animates the same way
                    // as a live token update.
                    .animation(.easeOut(duration: 0.35), value: HeroValue(tokens: tokens, full: fullTokens))
                    .accessibilityLabel("\(period.rawValue) token usage")
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
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Value")
                .accessibilityValue(Text(estimatedShown > 0 ? Format.money(estimatedShown) : "—"))
            }
        }
    }

    private var periodControl: some View {
        HStack(spacing: 2) {
            ForEach(Period.allCases) { p in
                Button {
                    period = p
                } label: {
                    Text(p.rawValue)
                        .font(TMType.medium(13))
                        .foregroundStyle(period == p ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(period == p ? Color.primary.opacity(0.10) : .clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(p.rawValue)
                .accessibilityValue(period == p ? "Selected" : "Not selected")
                .accessibilityAddTraits(period == p ? .isSelected : [])
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
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
                Text("No source data yet")
                    .font(.caption)
                    .foregroundStyle(TMDesign.quiet)
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
            goStatusRow
            codexStatusRow
            routerStatusRow
        }
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
    private var trendBlock: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                SectionTitle("Trend")
                Spacer()
                if let h = hoveredTrend {
                    Text("\(shortDayFormatter.string(from: dayFromKey(h.key))) · \(Format.compact(h.tokens))")
                        .font(TMType.monoRegular(TMType.caption))
                        .foregroundStyle(.secondary)
                } else {
                    Text("Peak \(Format.compact(trendPeak))")
                        .font(TMType.monoRegular(TMType.caption))
                        .foregroundStyle(.secondary)
                }
            }
            trendChart
        }
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
        Self.buildHeatmapWeeks(now: Date())
    }

    /// 本周第一天的日期归一化到周一（不依赖 firstWeekday 的周日/周一习惯）。
    private static func weekStartMonday(now: Date, calendar: Calendar) -> Date? {
        guard let first = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)) else { return nil }
        let weekday = calendar.component(.weekday, from: first)  // 1 = 周日 … 7 = 周六
        let delta = weekday == 1 ? -6 : 2 - weekday
        return calendar.date(byAdding: .day, value: delta, to: first)
    }

    private static func buildHeatmapWeeks(now: Date) -> [[Int64?]] {
        var weeks: [[Int64?]] = []
        let calendar = Calendar.current
        guard let monday = weekStartMonday(now: now, calendar: calendar) else { return weeks }
        for week in 0..<26 {
            var column: [Int64?] = []
            for day in 0..<7 {
                guard let date = calendar.date(byAdding: .day, value: week * 7 + day - 25 * 7, to: monday) else {
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

    private static func dayDate(_ key: Int64) -> Date {
        var c = DateComponents()
        c.year = Int(key / 10_000)
        c.month = Int(key / 100) % 100
        c.day = Int(key % 100)
        return Calendar.current.date(from: c) ?? .distantPast
    }

    /// Charts 平滑折线（catmullRom）。冷启动延迟由热力图缓存解决：
    /// 打开时先用上次持久化的数据立即渲染，再异步刷新新曲线。
    private var trendChart: some View {
        Chart(trendSeries, id: \.key) { d in
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
                    .offset(y: 5)
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
                            if let hit = trendSeries.first(where: {
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
        var status = "Not configured"
        var resetSuffix: String?
        if goClient.configured {
            if state.error != nil {
                status = "Error"
            } else if stale {
                status = "Stale"
            } else if let remaining {
                status = "\(Int(remaining))% left"
                resetSuffix = resetText(state.monthlyReset.map { state.lastSync + $0 })
            } else if state.isLoading && state.lastSync <= 0 {
                status = "Loading"
            } else {
                // 刷新期间保留上次结果，不闪 Loading。
                status = "Idle"
            }
        }
        return statusRow(name: "OpenCode Go", status: status,
                         statusColor: .primary,
                         critical: remaining.map { $0 < 20 } ?? false,
                         resetSuffix: resetSuffix)
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
        let sub = app.subscriptions.first { $0.plan == "codex" }
        let stale = state.lastSync > 0
            && now.timeIntervalSince1970 - TimeInterval(state.lastSync) > 120
        // 刷新期间保留上次结果：只有从未同步过才显示 Loading。
        var status = sub == nil ? "Not configured"
                    : (state.lastSync <= 0 ? "Loading" : "Idle")
        var resetSuffix: String?
        if state.error != nil {
            status = "Error"
        } else if stale, state.primaryPct != nil {
            status = "Stale"
        } else if let remaining {
            status = "\(Int(remaining))% of \(windowLabel) left"
            resetSuffix = resetText(state.resetAt)
        } else if let sub {
            status = "Subscribed · \(Format.money(sub.price))/mo"
        }
        return statusRow(name: "Codex Plus", status: status,
                         statusColor: .primary,
                         critical: remaining.map { $0 < 20 } ?? false,
                         resetSuffix: resetSuffix)
    }

    private var routerStatusRow: some View {
        let state = orClient.state
        let stale = state.lastOK > 0
            && now.timeIntervalSince1970 - TimeInterval(state.lastOK) > 120
        let status: String
        if !orClient.hasKey {
            status = "Not configured"
        } else if state.error != nil {
            status = "Error"
        } else if stale {
            status = "Stale"
        } else if let balance = state.accountBalance {
            status = "Balance \(Format.money(balance))"
        } else if state.isLoading && state.lastOK <= 0 {
            status = "Loading"
        } else {
            status = "Idle"
        }
        return statusRow(name: "OpenRouter", status: status,
                         statusColor: orClient.hasKey ? .primary : TMDesign.quiet)
    }

    private func statusRow(name: String, status: String, statusColor: Color,
                           critical: Bool = false, resetSuffix: String? = nil) -> some View {
        StatusRow(name: name, status: status, statusColor: statusColor,
                  critical: critical, resetSuffix: resetSuffix)
    }

    /// Post a measured height slice straight to the panel controller.
    /// Notifications bypass SwiftUI's preference chain, which is unreliable
    /// across ScrollView boundaries (the pinned slice was stuck at 0 and the
    /// bottom rows — OpenRouter — got cut off).
    private func postPanelHeight(kind: String, height: CGFloat) {
        NotificationCenter.default.post(
            name: PanelController.contentHeightNotification,
            object: nil,
            userInfo: ["kind": kind, "height": height]
        )
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
/// SF Mono Regular，不让整行变成等宽。
private struct StatusRow: View {
    let name: String
    let status: String
    let statusColor: Color
    var critical = false
    var resetSuffix: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(name)
                .font(TMType.medium(TMType.body))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 8)
            // 固定两行高度：空字符串 Text 固有高度会塌缩为 0，所以用
            // 显式 frame 占位——Loading → 数据切换时行高恒定，面板不跳。
            VStack(alignment: .trailing, spacing: 2) {
                Text((critical ? "★ " : "") + status)
                    .font(TMType.monoRegular(TMType.body))
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
                    .frame(height: 16, alignment: .trailing)
                Text(resetSuffix ?? "")
                    .font(TMType.monoRegular(TMType.micro))
                    .foregroundStyle(statusColor.opacity(0.7))
                    .lineLimit(1)
                    .frame(height: 13, alignment: .trailing)
                    .opacity(resetSuffix == nil ? 0 : 1)
            }
            .layoutPriority(1)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(name)
        .accessibilityValue(Text([status, resetSuffix].compactMap { $0 }.joined(separator: " · ")))
    }
}

/// 板块标题（Quota / Activity / Trend）：全大写 + 小号 + 字距 + 灰，
/// 与内容行（13pt medium primary）形成清晰层次；右侧跟随次要信息。
private struct SectionTitle: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title.uppercased())
            .font(TMType.semibold(11))
            .kerning(0.6)
            .foregroundStyle(TMDesign.quiet)
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
    private static let monthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                                     "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// 内容区固定 360pt（面板 400 − 水平 padding 40），cell 按列数均分。
    private var gridHeight: CGFloat {
        let contentWidth: CGFloat = 360
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
            out.append((wi, Self.monthNames[month - 1]))
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Activity heatmap, six months")
    }

    private func heatCell(_ key: Int64?, size: CGFloat) -> some View {
        let v = key.flatMap { heatmap[$0] } ?? 0
        let ratio = maxTokens > 0 ? Double(v) / Double(maxTokens) : 0
        return RoundedRectangle(cornerRadius: 1, style: .continuous)
            .fill(v > 0
                  ? TMDesign.accent.opacity(0.25 + 0.75 * ratio)
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
    }
}
