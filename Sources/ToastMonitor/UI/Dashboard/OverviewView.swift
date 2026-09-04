import SwiftUI

/// Overview is the one-page dashboard: a hero figure with a capacity ring,
/// the year heatmap, attribution, and recent sessions. No nested card stack —
/// the hero sits directly on the canvas, panels hold the rest.
struct OverviewView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var health = SourceHealthHub.shared
    @ObservedObject private var orClient = OpenRouterClient.shared
    @ObservedObject private var periodSettings = UsagePeriodSettings.shared
    @State private var period: Period = .today

    /// Page-wide period: hero totals and the distribution section follow it.
    /// The heatmap (one year) and the gauge (today vs daily average) are
    /// deliberately independent — they answer different questions.
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

    private let cellGutter: CGFloat = 3

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                intro
                // Hero totals and the distribution share one panel: the
                // period figure reads as the header of the breakdown below.
                TMPanel {
                    VStack(alignment: .leading, spacing: 0) {
                        heroSection
                        Rectangle()
                            .fill(TMDesign.divider)
                            .frame(height: 1)
                            .padding(.vertical, 14)
                        rankings
                    }
                }
                TMPanel {
                    heatmapSection
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
        }
    }

    private var intro: some View {
        HStack(alignment: .center, spacing: 12) {
            SectionTitle("Overview")
            Spacer()
            periodControl
        }
        .padding(.top, 18)
        .padding(.bottom, 12)
    }

    /// The period is a filter on this page, not a second navigation layer.
    /// A native pop-up keeps the active range visible while letting AppKit
    /// own the menu, checkmark, material and interaction.
    private var periodControl: some View {
        Picker("Date Range", selection: $period) {
            ForEach(Period.allCases) { p in
                Text(periodSettings.configuration.label(for: p.slot)).tag(p)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
        .accessibilityLabel("Date range")
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

    // MARK: - Hero: today's usage + capacity ring

    private var heroSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                SectionTitle(periodTitle)
                Spacer()
                statusLine
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(Format.compact(periodTokens))
                    .font(TMType.bold(TMType.hero))
                    .tmMonospacedDigit()
                    .lineLimit(1)
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.35), value: periodTokens)
                Text("tokens")
                    .font(TMType.regular(TMType.caption))
                    .foregroundStyle(TMDesign.quiet)
            }
            HStack(spacing: 0) {
                TMMiniMetric(label: "Calls", value: Format.count(periodCalls), font: TMType.regular(16))
                TMMiniMetric(label: actualSpendLabel, value: Format.money(actualSpend), font: TMType.regular(16))
                    .help(actualSpendHelp)
                TMMiniMetric(label: "API-equivalent Value", value: Format.money(apiValue), font: TMType.regular(16))
                    .help("What these model calls would cost at official API list prices. This is not a billed amount.")
            }
        }
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

    private var heatmapSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            TMSectionHeader("Activity")
            HeatmapGrid(
                weeks: heatmapWeeks,
                heatmap: app.heatmap,
                heatmapCost: app.heatmapCost,
                maxTokens: heatmapMaxTokens,
                cellGutter: cellGutter
            )
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

    // MARK: - Attribution (same trailing-7d window on both columns)

    private var rankings: some View {
        VStack(alignment: .leading, spacing: 16) {
            TMSectionHeader("Sources")
            HStack(alignment: .top, spacing: 32) {
                rankingColumn(title: "Models", rows: modelRows(period))
                rankingColumn(title: "Tools", rows: toolRows(period))
            }
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

    private func rankingColumn(title: String, rows: [(String, Int64, Double, Color)]) -> some View {
        let total = rows.reduce(Int64(0)) { $0 + $1.1 }
        return VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(TMType.medium(13))
            if rows.isEmpty {
                Text("No data")
                    .font(TMType.regular(TMType.caption))
                    .foregroundStyle(TMDesign.quiet)
            } else {
                ForEach(Array(rows.prefix(6).enumerated()), id: \.offset) { _, row in
                    let ratio = total > 0 ? Double(row.1) / Double(total) : 0
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 8) {
                            Circle().fill(row.3).frame(width: 7, height: 7)
                            Text(row.0)
                                .font(TMType.regular(TMType.body))
                                .lineLimit(1)
                            Spacer()
                            Text(Format.compact(row.1))
                                .font(TMType.regular(TMType.caption))
                                .tmMonospacedDigit()
                        }
                        TMProgressBar(value: ratio, tint: row.3, height: 4)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The year heatmap owns its hover state: hovering re-evaluates only this
/// grid, never the whole overview body. `maxTokens` is computed once per
/// OverviewView body evaluation (not per cell) and passed down as a constant.
private struct HeatmapGrid: View {
    let weeks: [[Int64?]]
    let heatmap: [Int64: Int64]
    let heatmapCost: [Int64: Double]
    let maxTokens: Int64
    let cellGutter: CGFloat

    private let calendar = Calendar.current
    @State private var hoveredDay: (key: Int64, tokens: Int64, cost: Double)?

    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(minimum: 8), spacing: cellGutter),
              count: weeks.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                if let h = hoveredDay {
                    Text("\(Format.shortDayKey(h.key)) · \(Format.compact(h.tokens)) tokens"
                         + (h.cost > 0 ? " · \(Format.money(h.cost))" : ""))
                        .font(TMType.monoRegular(9))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .frame(height: 14)
            VStack(alignment: .leading, spacing: 4) {
                GeometryReader { proxy in
                    let cell = fittedCellSize(for: proxy.size.width)
                    ZStack(alignment: .topLeading) {
                        ForEach(monthLabels, id: \.index) { m in
                            Text(m.label)
                                .font(TMType.monoRegular(9))
                                .foregroundStyle(TMDesign.quiet)
                                .fixedSize()
                                .offset(x: CGFloat(m.index) * (cell + cellGutter))
                        }
                    }
                }
                .frame(height: 12)

                LazyVGrid(columns: gridColumns, alignment: .leading,
                          spacing: cellGutter) {
                    // Row-major ordering makes LazyVGrid render the same
                    // Monday-to-Sunday rows as the former stack of columns.
                    ForEach(0..<7, id: \.self) { dayIndex in
                        ForEach(weeks.indices, id: \.self) { weekIndex in
                            heatCell(weeks[weekIndex][dayIndex])
                        }
                    }
                }
                .overlay {
                    GeometryReader { proxy in
                        Color.clear
                            .contentShape(Rectangle())
                            .onContinuousHover { phase in
                                updateHover(phase, size: proxy.size)
                            }
                    }
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            heatLegend
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Activity heatmap")
        .accessibilityValue(Text(accessibilitySummary))
        .accessibilityHint("Use Tab or VoiceOver to browse each day's usage")
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
        return MonthAxis.ticks(days: weekKeys).map { (weekIndices[$0.index], $0.label) }
    }

    private var heatLegend: some View {
        HStack(spacing: 4) {
            Text("Less")
                .font(TMType.regular(TMType.micro))
                .foregroundStyle(TMDesign.faint)
            ForEach(0..<5, id: \.self) { level in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(level == 0
                          ? Color.primary.opacity(0.07)
                          : TMDesign.accent.opacity(0.18 + Double(level) / 4 * 0.72))
                    .frame(width: 11, height: 11)
                    .accessibilityHidden(true)
            }
            Text("More")
                .font(TMType.regular(TMType.micro))
                .foregroundStyle(TMDesign.faint)
            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Legend")
        .accessibilityValue("Less to more")
    }

    private func fittedCellSize(for width: CGFloat) -> CGFloat {
        guard !weeks.isEmpty else { return 8 }
        let gaps = CGFloat(max(0, weeks.count - 1)) * cellGutter
        return max(8, (width - gaps) / CGFloat(weeks.count))
    }

    private func updateHover(_ phase: HoverPhase, size: CGSize) {
        switch phase {
        case .active(let point):
            let cell = fittedCellSize(for: size.width)
            let stride = cell + cellGutter
            guard stride > 0 else { hoveredDay = nil; return }
            let week = Int(point.x / stride)
            let day = Int(point.y / stride)
            guard weeks.indices.contains(week), (0..<7).contains(day),
                  point.x - CGFloat(week) * stride <= cell,
                  point.y - CGFloat(day) * stride <= cell,
                  let key = weeks[week][day], key > 0 else {
                hoveredDay = nil
                return
            }
            hoveredDay = (key, heatmap[key] ?? 0, heatmapCost[key] ?? 0)
        case .ended:
            hoveredDay = nil
        }
    }

    @ViewBuilder
    private func heatCell(_ day: Int64?) -> some View {
        // 0 是未来日哨兵（buildHeatmapWeeks：date > now 时写入）。未来格
        // 用更淡底色，与“有效日 0 token”的 0.07 区分开。
        if let day, day > 0 {
            let tokenCount = heatmap[day] ?? 0
            let value = Double(tokenCount)
            let maxValue = Double(maxTokens)
            let intensity = value > 0 && maxValue > 0 ? max(0.18, min(1, value / maxValue)) : 0
            let label = Format.shortDayKey(day)
            let cost = heatmapCost[day] ?? 0
            let valueText = "\(Format.full(tokenCount)) tokens" + (cost > 0 ? ", \(Format.money(cost))" : "")

            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                // 线性渐变不变；下限 0.4 保证有数据的日子（含当天）
                // 明显可见，大日子保留原有梯度。
                .fill(value > 0 ? TMDesign.accent.opacity(max(0.4, 0.18 + intensity * 0.72)) : Color.primary.opacity(0.07))
                .aspectRatio(1, contentMode: .fit)
                .contentShape(Rectangle())
            .accessibilityLabel(Text(label))
            .accessibilityValue(Text(valueText))
        } else {
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .fill(Color.primary.opacity(day == 0 ? 0.03 : 0.07))
                .aspectRatio(1, contentMode: .fit)
                .accessibilityHidden(true)
        }
    }

}
