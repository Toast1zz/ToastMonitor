import SwiftUI

/// Overview: the period's headline figures, where the tokens went (tools and
/// models), and a year of activity, all on one screen. The period control at
/// the top drives the figures and both breakdowns; the heatmap always shows
/// the trailing year.
struct OverviewView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var health = SourceHealthHub.shared
    @ObservedObject private var orClient = OpenRouterClient.shared
    @ObservedObject private var periodSettings = UsagePeriodSettings.shared
    @ObservedObject private var deepseek = DeepSeekBillingClient.shared
    @AppStorage(DeepSeekBilling.exchangeRateKey) private var cnyPerUSD = DeepSeekBilling.defaultCNYPerUSD
    @State private var period: Period = .today
    @State private var hoveredDay: HeatmapDay?

    /// Page-wide period: the figures and the breakdowns follow it. The
    /// heatmap (one year) is deliberately independent.
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

    var body: some View {
        DashPage {
            HStack(alignment: .center, spacing: 12) {
                periodControl
                Spacer(minLength: 8)
                statusLine
            }
            DashMetricRow {
                DashMetric(label: "Tokens", value: Format.compact(periodTokens))
                    .tmNumericTextTransition(value: Double(periodTokens))
                    .animation(.easeOut(duration: 0.35), value: periodTokens)
                DashMetric(label: "Calls", value: Format.count(periodCalls))
                DashMetric(label: actualSpendLabel, value: actualSpendText,
                           help: actualSpendHelp)
                DashMetric(label: "API Value", value: Format.money(apiValue),
                           help: "What these model calls would cost at official API list prices. This is not a billed amount.")
            }
            // The breakdowns absorb the window's spare height; a long model
            // list scrolls inside its card.
            HStack(alignment: .top, spacing: DashLayout.gap) {
                DashCard("Tools") { scrolling(ShareList(items: toolItems)) }
                DashCard("Models") { scrolling(ShareList(items: modelItems)) }
            }
            .frame(minHeight: 140, maxHeight: .infinity)
            DashCard("Activity", trailing: { activitySummary }) {
                HeatmapGrid(
                    weeks: heatmapWeeks,
                    heatmap: app.heatmap,
                    heatmapCost: app.heatmapCost,
                    maxTokens: heatmapMaxTokens,
                    weekdayLabels: weekdayLabels,
                    hoveredDay: $hoveredDay
                )
            }
            .dashFixedHeight()
        }
        // Account-wide DeepSeek spend for this page's period. It is fetched
        // beside the popover's own period rather than by re-selecting the
        // shared one; the client only fetches while a surface is visible.
        .task(id: period) {
            while !Task.isCancelled {
                deepseek.loadSpendIfNeeded(for: period.slot, configuration: periodSettings.configuration)
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
    }

    private func scrolling<V: View>(_ content: V) -> some View {
        ScrollView(.vertical) { content }
            .scrollIndicators(.automatic)
    }

    /// Trailing text of the Activity card: the hovered day, else the year's
    /// active-day count. One fixed line so hovering never reflows the card.
    private var activitySummary: some View {
        let text: String
        if let h = hoveredDay {
            text = "\(Format.shortDayKey(h.key)) · \(Format.compact(h.tokens)) tokens"
                + (h.cost > 0 ? " · \(Format.money(h.cost))" : "")
        } else {
            let active = app.heatmap.values.filter { $0 > 0 }.count
            text = active == 0 ? "" : "\(active) active day\(active == 1 ? "" : "s") in the past year"
        }
        return Text(text)
            .font(TMType.regular(TMType.caption))
            .tmMonospacedDigit()
            .foregroundStyle(TMDesign.quiet)
            .lineLimit(1)
    }

    /// The period is a filter on this page, so it is a segmented control:
    /// four peers, one always selected, all visible.
    private var periodControl: some View {
        DashSegmented(selection: $period, options: Period.allCases,
                      title: { periodSettings.configuration.label(for: $0.slot) },
                      accessibilityName: "Date range")
    }

    private var periodTitle: String {
        periodSettings.configuration.title(for: period.slot)
    }

    private var periodTokens: Int64 {
        switch period {
        case .today: return app.todayTokens
        case .week: return app.weekTokens
        case .month: return app.monthTokens
        case .all: return app.allTokens
        }
    }

    private var periodCalls: Int64 {
        switch period {
        case .today: return app.today.count
        case .week: return app.week.count
        case .month: return app.month.count
        case .all: return app.all.count
        }
    }

    private var periodCost: UsageQueryService.CostQuality {
        switch period {
        case .today: return app.costToday
        case .week: return app.costWeek
        case .month: return app.costMonth
        case .all: return app.costAll
        }
    }

    /// 这些 token 按 API 官方单价价值多少钱（全部工具，含 hermes）。
    private var apiValue: Double {
        switch period {
        case .today: return app.apiValueToday
        case .week: return app.apiValueWeek
        case .month: return app.apiValueMonth
        case .all: return app.apiValueAll
        }
    }

    /// 实际花了多少钱 = 账单/直连实际 + OpenRouter 实际 + 订阅按天分摊。
    private var actualSpend: Double {
        let orUsage: Double
        let days: Int
        switch period {
        case .today: orUsage = orClient.state.usageDaily; days = 1
        case .week: orUsage = orClient.state.usageWeekly; days = 7
        case .month: orUsage = orClient.state.usageMonthly; days = 30
        case .all: orUsage = orClient.state.usageMonthly; days = 3650 // OpenRouter 只给月窗口；10 年窗口覆盖全部订阅期
        }
        return periodCost.actual + orUsage
            + SubscriptionMath.amortized(days: days, subscriptions: app.subscriptions)
    }

    /// Same composition as the popover's Spent chip: local billed cost,
    /// OpenRouter and subscription amortization, plus DeepSeek's account-wide
    /// billing where it is available (which replaces the matching local cost).
    private var actualSpendText: String {
        DeepSeekBilling.combinedSpend(
            localUSD: actualSpend,
            coveredLocalUSD: periodCost.deepseekActual,
            spend: deepseek.spend(for: period.slot, configuration: periodSettings.configuration),
            cnyPerUSD: cnyPerUSD)
    }

    private var actualSpendLabel: String {
        if period == .all { return "Actual Spend · OR recent month" }
        return "Actual Spend"
    }

    private var actualSpendHelp: String {
        let base = "Billed turn costs, OpenRouter account usage, and subscription amortization."
        return period == .all
            ? base + " OpenRouter only exposes its recent monthly window, so All Time includes that recent month rather than full history."
            : base
    }


    private var statusLine: some View {
        let broken = health.sources.filter { $0.error != nil }.count
        let stale = health.sources.filter { $0.error == nil && $0.isStale }.count
        let summary = TMHealthStatus(brokenCount: broken, staleCount: stale, lastScan: app.lastScan)
        return TMStatusPill(text: summary.text, color: summary.color, symbol: summary.symbol)
    }

    // MARK: - Heatmap (one year, month axis)

    /// Labels for the weekday rows: every other row, in the configured
    /// week order, so the grid reads without a legend.
    private var weekdayLabels: [String] {
        var calendar = periodSettings.configuration.configuredCalendar()
        // The interface is English; weekday names follow it, not the system.
        calendar.locale = Locale(identifier: "en_US")
        let symbols = calendar.shortWeekdaySymbols
        return (0..<7).map { row in
            row % 2 == 1 ? "" : symbols[(calendar.firstWeekday - 1 + row) % 7]
        }
    }

    /// One O(n) pass per body evaluation, shared by every heatmap cell
    /// (the per-cell `values.max()` was 371 passes per body eval).
    private var heatmapMaxTokens: Int64 {
        app.heatmap.values.max() ?? 0
    }

    /// 53-week geometry is keyed by calendar year and ordinal day. A day-only
    /// key reused the prior year's grid when the app stayed open over New Year.
    /// Timezone identifier joins the key: year/ordinal-day components depend on
    /// the current zone, so a system zone change must rebuild the grid too.
    private static var cachedWeeks: [[Int64?]] = []
    private static var cachedWeeksKey: String = ""

    private var heatmapWeeks: [[Int64?]] {
        let now = Date()
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year], from: now)
        let day = calendar.ordinality(of: .day, in: .year, for: now) ?? -1
        let key = "\(components.year ?? 0)-\(day)-\(TimeZone.current.identifier)-\(periodSettings.weekStart.rawValue)"
        guard Self.cachedWeeksKey != key else { return Self.cachedWeeks }
        Self.cachedWeeks = Self.buildHeatmapWeeks(now: now, configuration: periodSettings.configuration)
        Self.cachedWeeksKey = key
        return Self.cachedWeeks
    }

    private static func buildHeatmapWeeks(now: Date,
                                          configuration: UsagePeriodConfiguration) -> [[Int64?]] {
        var weeks: [[Int64?]] = []
        let calendar = configuration.configuredCalendar()
        let weekStart = configuration.startOfConfiguredWeek(now, calendar: calendar)
        for week in 0..<53 {
            var column: [Int64?] = []
            for day in 0..<7 {
                guard let date = calendar.date(byAdding: .day, value: week * 7 + day - 52 * 7, to: weekStart) else {
                    column.append(nil)
                    continue
                }
                if date > now {
                    // 未来日哨兵 0：与有效日 0 token 区分（渲染用更淡色）。
                    // 真实键恒为正（year*10000 + …），0 不可能冲突。
                    column.append(0)
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

    // MARK: - Attribution

    private var toolItems: [ShareItem] {
        toolRows(period).map { ShareItem(name: $0.0, value: $0.1, color: $0.3) }
    }

    private var modelItems: [ShareItem] {
        // One color per model by rank (same rule as Analysis › By Model);
        // a tool's color would repeat across its models.
        modelRows(period).enumerated().map { index, row in
            ShareItem(name: row.0, value: row.1,
                      color: TMDesign.modelPalette[index % TMDesign.modelPalette.count])
        }
    }

    private func modelRows(_ period: Period) -> [(String, Int64, Double, Color)] {
        let aggs: [Database.ModelAgg]
        switch period {
        case .today: aggs = app.modelAggsToday
        case .week: aggs = app.modelAggs
        case .month: aggs = app.modelAggsMonth
        case .all: aggs = app.modelAggsAll
        }
        // The same model can be used by multiple tools. Aggregate it into one
        // row so the ranking answers "which model" instead of leaking source
        // implementation details as duplicate labels.
        var totals: [String: (tokens: Int64, cost: Double, color: Color)] = [:]
        for row in aggs {
            let value = ToolKind(rawValue: row.tool)?.totalTokens(input: row.input, output: row.output, cacheRead: row.cacheRead) ?? row.input + row.output
            let previous = totals[row.model]
            totals[row.model] = (
                tokens: (previous?.tokens ?? 0) + value,
                cost: (previous?.cost ?? 0) + row.cost,
                color: previous?.color ?? ToolKind(rawValue: row.tool)?.color ?? TMDesign.accent
            )
        }
        return totals.map { ($0.key, $0.value.tokens, $0.value.cost, $0.value.color) }
            .sorted { $0.1 > $1.1 }
    }

    private func toolRows(_ period: Period) -> [(String, Int64, Double, Color)] {
        let rows: [Database.ToolTotals]
        switch period {
        case .today: rows = app.byToolToday
        case .week: rows = app.byToolWeek
        case .month: rows = app.byToolMonth
        case .all: rows = app.byToolAll
        }
        return rows.sorted {
            (ToolKind(rawValue: $0.tool)?.totalTokens($0) ?? $0.input + $0.output) >
                (ToolKind(rawValue: $1.tool)?.totalTokens($1) ?? $1.input + $1.output)
        }.map { row in
            (ToolKind(rawValue: row.tool)?.displayName ?? row.tool,
             ToolKind(rawValue: row.tool)?.totalTokens(row) ?? row.input + row.output,
             row.cost,
             ToolKind(rawValue: row.tool)?.color ?? TMDesign.accent)
        }
    }
}

struct HeatmapDay: Equatable {
    let key: Int64
    let tokens: Int64
    let cost: Double
}

/// One year of daily usage, Monday-first (or Sunday-first) columns of weeks.
/// The cell size is derived from the available width so the grid always fills
/// the card; hover is reported through `hoveredDay` so the card header, not
/// this view, shows the readout and hovering re-evaluates almost nothing.
private struct HeatmapGrid: View {
    let weeks: [[Int64?]]
    let heatmap: [Int64: Int64]
    let heatmapCost: [Int64: Double]
    let maxTokens: Int64
    /// One label per weekday row, empty for rows that stay unlabeled.
    let weekdayLabels: [String]
    @Binding var hoveredDay: HeatmapDay?

    private let gutter: CGFloat = 4
    private let labelWidth: CGFloat = 30
    private let monthAxisHeight: CGFloat = 16

    var body: some View {
        let cell = cellSize(for: width)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: gutter) {
                    Color.clear.frame(height: monthAxisHeight - gutter)
                    ForEach(0..<7, id: \.self) { row in
                        Text(weekdayLabels.indices.contains(row) ? weekdayLabels[row] : "")
                            .font(TMType.regular(TMType.micro))
                            .foregroundStyle(TMDesign.quiet)
                            .frame(width: labelWidth, height: cell, alignment: .leading)
                    }
                }
                VStack(alignment: .leading, spacing: gutter) {
                    ZStack(alignment: .topLeading) {
                        ForEach(monthLabels, id: \.index) { m in
                            Text(m.label)
                                .font(TMType.regular(TMType.micro))
                                .foregroundStyle(TMDesign.quiet)
                                .fixedSize()
                                .offset(x: CGFloat(m.index) * (cell + gutter))
                        }
                    }
                    .frame(height: monthAxisHeight - gutter, alignment: .topLeading)
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(cell), spacing: gutter),
                                             count: weeks.count),
                              alignment: .leading, spacing: gutter) {
                        // Row-major ordering renders weekday rows.
                        ForEach(0..<7, id: \.self) { dayIndex in
                            ForEach(weeks.indices, id: \.self) { weekIndex in
                                heatCell(weeks[weekIndex][dayIndex], size: cell)
                            }
                        }
                    }
                    .overlay {
                        Color.clear
                            .contentShape(Rectangle())
                            .onContinuousHover { phase in
                                updateHover(phase, cell: cell)
                            }
                    }
                }
            }
            .frame(height: monthAxisHeight + 7 * cell + 6 * gutter, alignment: .topLeading)
            heatLegend
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { width = proxy.size.width }
                    .onChange(of: proxy.size.width) { width = $0 }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Activity heatmap")
        .accessibilityValue(Text(accessibilitySummary))
        .accessibilityHint("Use Tab or VoiceOver to browse each day's usage")
    }

    /// Card width, measured after layout; the cell size derives from it.
    @State private var width: CGFloat = 0

    private func cellSize(for width: CGFloat) -> CGFloat {
        guard !weeks.isEmpty else { return 10 }
        let gaps = CGFloat(max(0, weeks.count - 1)) * gutter
        return max(8, floor((width - labelWidth - gaps) / CGFloat(weeks.count)))
    }

    private var accessibilitySummary: String {
        let activeDays = heatmap.values.filter { $0 > 0 }.count
        guard activeDays > 0 else { return "No usage data" }
        let total = heatmap.values.reduce(Int64(0), +)
        return "\(activeDays) day\(activeDays == 1 ? "" : "s") with usage, \(Format.full(total)) tokens total"
    }

    /// First week whose Monday falls in a new month gets that month's label
    /// (shared MonthAxis logic; January carries the 2-digit year so the year
    /// boundary is visible in a 53-week span). Ticks are computed over each
    /// week's first real day key, then remapped back to week indices.
    private var monthLabels: [(index: Int, label: String)] {
        var weekKeys: [Int64] = []
        var weekIndices: [Int] = []
        for (wi, week) in weeks.enumerated() {
            guard let first = week.first(where: { ($0 ?? 0) > 0 }), let key = first else { continue }
            weekKeys.append(key)
            weekIndices.append(wi)
        }
        let ticks = MonthAxis.ticks(days: weekKeys).map { (weekIndices[$0.index], $0.label) }
        // A label needs about three columns; drop one that the next month's
        // label would overprint (the partial first month of the grid).
        return ticks.enumerated().filter { i, tick in
            i + 1 >= ticks.count || ticks[i + 1].0 - tick.0 >= 3
        }.map(\.element)
    }

    private var heatLegend: some View {
        HStack(spacing: 4) {
            Spacer()
            Text("Less")
                .font(TMType.regular(TMType.micro))
                .foregroundStyle(TMDesign.quiet)
            ForEach(0..<5, id: \.self) { level in
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .fill(level == 0
                          ? Color.primary.opacity(0.07)
                          : TMDesign.accent.opacity(0.18 + Double(level) / 4 * 0.72))
                    .frame(width: 12, height: 12)
                    .accessibilityHidden(true)
            }
            Text("More")
                .font(TMType.regular(TMType.micro))
                .foregroundStyle(TMDesign.quiet)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Legend")
        .accessibilityValue("Less to more")
    }

    private func updateHover(_ phase: HoverPhase, cell: CGFloat) {
        switch phase {
        case .active(let point):
            let stride = cell + gutter
            guard stride > 0 else { hoveredDay = nil; return }
            let week = Int(point.x / stride)
            let day = Int(point.y / stride)
            guard weeks.indices.contains(week), (0..<7).contains(day),
                  point.x - CGFloat(week) * stride <= cell,
                  point.y - CGFloat(day) * stride <= cell,
                  let key = weeks[week][day], key > 0 else {
                if hoveredDay != nil { hoveredDay = nil }
                return
            }
            let next = HeatmapDay(key: key, tokens: heatmap[key] ?? 0, cost: heatmapCost[key] ?? 0)
            if hoveredDay != next { hoveredDay = next }
        case .ended:
            hoveredDay = nil
        }
    }

    @ViewBuilder
    private func heatCell(_ day: Int64?, size: CGFloat) -> some View {
        // 0 is the future-day sentinel (buildHeatmapWeeks writes it for
        // date > now); it renders fainter than a real zero-token day.
        if let day, day > 0 {
            let tokenCount = heatmap[day] ?? 0
            let value = Double(tokenCount)
            let maxValue = Double(maxTokens)
            let intensity = value > 0 && maxValue > 0 ? max(0.18, min(1, value / maxValue)) : 0
            let label = Format.shortDayKey(day)
            let cost = heatmapCost[day] ?? 0
            let valueText = "\(Format.full(tokenCount)) tokens" + (cost > 0 ? ", \(Format.money(cost))" : "")

            RoundedRectangle(cornerRadius: 3, style: .continuous)
                // Linear ramp with a 0.4 floor so any populated day (today
                // included) is clearly visible next to the peak day.
                .fill(value > 0 ? TMDesign.accent.opacity(max(0.4, 0.18 + intensity * 0.72)) : Color.primary.opacity(0.07))
                .frame(width: size, height: size)
                .contentShape(Rectangle())
                .accessibilityLabel(Text(label))
                .accessibilityValue(Text(valueText))
        } else {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Color.primary.opacity(day == 0 ? 0.03 : 0.07))
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }
}
