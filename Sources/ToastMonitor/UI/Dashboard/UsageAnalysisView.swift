import AppKit
import Charts
import SwiftUI

/// 用量分析 (spec §3.2): 集中控制条（日期范围 / 按工具·按模型 / 图型）+
/// token 堆叠图 + 成本图（按天聚合，禁止跨工具连线）+ 聚合表。
/// Analysis: one control bar (metric, range, grouping), summary figures, a
/// per-day stacked bar chart and the aggregate table. Charts are Swift Charts,
/// so axes, grid lines, VoiceOver and Audio Graphs are the system's.
struct UsageAnalysisView: View {
    enum Range: String, CaseIterable, Identifiable {
        case d7 = "7 Days"
        case d30 = "30 Days"
        case d90 = "90 Days"
        var id: String { rawValue }
        var days: Int {
            switch self {
            case .d7: 7
            case .d30: 30
            case .d90: 90
            }
        }
    }

    enum Grouping: String, CaseIterable, Identifiable {
        case byTool = "By Tool"
        case byModel = "By Model"
        var id: String { rawValue }
    }

    enum Metric: String, CaseIterable, Identifiable {
        case tokens = "Tokens"
        case cost = "Cost"
        var id: String { rawValue }
    }

    @State private var range: Range = .d30
    @State private var grouping: Grouping = .byTool
    @State private var metric: Metric = .tokens
    /// Derived chart/table inputs, rebuilt once per data arrival — never per
    /// body evaluation. nil until the first load completes.
    @State private var analysis: AnalysisData?
    @State private var loadID = UUID()
    @State private var exportError: String?
    @State private var isLoading = true
    @State private var hoveredDay: Int64?
    /// Model -> color, assigned by usage rank so distinct models always get
    /// distinct palette entries (hash-based mapping collided).
    @State private var modelColors: [String: Color] = [:]

    // MARK: - Derived data（单次求值，仅数据到达时重建）

    /// 归一化行：(day, groupKey, input, output, cacheRead, cost, calls)
    private struct Row {
        let day: Int64
        let key: String
        let input: Int64
        let output: Int64
        let cacheRead: Int64
        let cost: Double
        let count: Int64
    }

    /// One bar segment: a day's value for one tool/model.
    private struct ChartPoint: Identifiable {
        let dayKey: Int64
        let date: Date
        let label: String
        let color: Color
        let value: Double
        var id: String { "\(dayKey)|\(label)" }
    }

    private struct AggregateRow {
        let name: String
        let tokens: Int64
        let calls: Int64
        let cost: Double
        let ratio: Double
        let color: Color
    }

    /// 图表/表格的全部派生输入，在原始行上单遍聚合得到。只有新数据到达时
    /// 才重建；切换 range/grouping 时旧值继续渲染，避免整页 loading 闪屏。
    private struct AnalysisData {
        let grouping: Grouping
        let range: Range
        let tokenPoints: [ChartPoint]
        let costPoints: [ChartPoint]
        let tokenByDay: [Int64: [ChartPoint]]
        let costByDay: [Int64: [ChartPoint]]
        /// Display labels and colors, most-used first: the chart's color scale.
        let labels: [String]
        let colors: [Color]
        let aggregates: [AggregateRow]
        let dayCount: Int
        let totalTokens: Int64
        let totalCost: Double
        let totalCalls: Int64
        /// The full requested window, so days without usage still occupy
        /// their place on the time axis.
        let xDomain: ClosedRange<Date>
    }

    var body: some View {
        DashPage {
            controlBar
            if let data = analysis {
                summary(data)
                DashCard(metric == .tokens ? "Tokens per Day" : "Estimated Cost per Day",
                         trailing: { legend }) {
                    chart(data)
                }
                DashCard("Details") { aggTable }
                    .dashFixedHeight()
            } else if isLoading {
                ProgressView("Loading analysis…")
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("No data in this range")
                    .font(TMType.regular(TMType.body))
                    .foregroundStyle(TMDesign.quiet)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { load() }
        .onChange(of: range) { _ in load() }
        .onChange(of: grouping) { _ in load() }
        .alert("Export failed", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } })) {
                Button("OK", role: .cancel) { exportError = nil }
            } message: {
                Text(exportError ?? "The CSV could not be written.")
            }
    }

    /// Three peer choices, each a segmented control whose segments name
    /// themselves; nothing needs a caption.
    private var controlBar: some View {
        HStack(alignment: .center, spacing: 12) {
            DashSegmented(selection: $metric, options: Metric.allCases,
                          title: { $0.rawValue }, accessibilityName: "Metric")
            Spacer(minLength: 8)
            if isLoading, analysis != nil {
                ProgressView().controlSize(.small)
                    .accessibilityLabel("Updating analysis")
            }
            DashSegmented(selection: $range, options: Range.allCases,
                          title: { $0.rawValue }, accessibilityName: "Range")
            DashSegmented(selection: $grouping, options: Grouping.allCases,
                          title: { $0.rawValue }, accessibilityName: "Grouping")
            Button(action: exportCSV) {
                Image(systemName: "square.and.arrow.up")
            }
            .tmGlassButton(circle: true, extraLarge: true)
            .disabled(analysis == nil || isLoading)
            .help("Export current analysis as CSV")
            .accessibilityLabel("Export current analysis as CSV")
        }
    }

    private func exportCSV() {
        guard let analysis else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "ToastMonitor-\(analysis.range.rawValue.replacingOccurrences(of: " ", with: "-"))-\(analysis.grouping.rawValue.replacingOccurrences(of: " ", with: "-" )).csv"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var lines = ["range,grouping,name,tokens,calls,estimated_cost,share"]
        for row in analysis.aggregates {
            lines.append([
                analysis.range.rawValue,
                analysis.grouping.rawValue,
                row.name,
                String(row.tokens),
                String(row.calls),
                String(format: "%.6f", row.cost),
                String(format: "%.6f", row.ratio),
            ].map(Self.csvField).joined(separator: ","))
        }
        do {
            try (lines.joined(separator: "\n") + "\n")
                .write(to: url, atomically: true, encoding: .utf8)
        } catch {
            exportError = error.localizedDescription
        }
    }

    private static func csvField(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else { return value }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private func summary(_ data: AnalysisData) -> some View {
        let daily = data.dayCount > 0 ? data.totalTokens / Int64(data.dayCount) : 0
        return DashMetricRow {
            DashMetric(label: "Tokens", value: Format.compact(data.totalTokens))
            DashMetric(label: "Estimated Cost", value: Format.moneyShort(data.totalCost))
            DashMetric(label: "Daily Avg Tokens", value: Format.compact(daily))
            DashMetric(label: "Calls", value: Format.count(data.totalCalls))
        }
    }

    private func load() {
        let requestID = UUID()
        loadID = requestID
        isLoading = true
        let grouping = self.grouping
        let range = self.range
        if grouping == .byTool {
            UsageQueryService.shared.loadDailyAggs(days: range.days) { aggs in
                guard loadID == requestID else { return }
                isLoading = false
                self.analysis = Self.build(aggs: aggs, modelAggs: [],
                                           grouping: grouping, range: range,
                                           modelColors: self.modelColors)
                self.hoveredDay = nil
            }
        } else {
            UsageQueryService.shared.loadDailyAggsByModel(days: range.days) { aggs in
                guard loadID == requestID else { return }
                isLoading = false
                let colors = Self.assignModelColors(aggs)
                self.modelColors = colors
                self.analysis = Self.build(aggs: [], modelAggs: aggs,
                                           grouping: grouping, range: range,
                                           modelColors: colors)
                self.hoveredDay = nil
            }
        }
    }

    /// Rank models by total tokens (descending) and hand each the next
    /// palette color — the top model gets the first color, no collisions.
    private static func assignModelColors(_ aggs: [(day: Int64, model: String, input: Int64, output: Int64, cacheRead: Int64, cost: Double, count: Int64)]) -> [String: Color] {
        let totals: [String: Int64] = aggs.reduce(into: [:]) { acc, row in
            acc[row.model, default: 0] += row.input + row.output + row.cacheRead
        }
        let ranked = totals.sorted { $0.value > $1.value }.map(\.key)
        var map: [String: Color] = [:]
        for (i, name) in ranked.enumerated() {
            map[name] = TMDesign.modelPalette[i % TMDesign.modelPalette.count]
        }
        return map
    }

    /// The interface is English; axis dates follow it, not the system locale.
    private static let axisDate = Date.FormatStyle()
        .month(.abbreviated).day().locale(Locale(identifier: "en_US"))

    /// Midday of every `step`-th day of the window, counted from the first
    /// day: a label centered under the very last bar has no room to its
    /// right and the system truncates it to an ellipsis.
    private static func tickDates(in domain: ClosedRange<Date>, every step: Int) -> [Date] {
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: domain.lowerBound, to: domain.upperBound).day ?? 0
        return stride(from: 0, to: days, by: step).compactMap { offset in
            calendar.date(byAdding: .hour, value: 12,
                          to: calendar.date(byAdding: .day, value: offset, to: domain.lowerBound) ?? domain.lowerBound)
        }
    }

    private static func date(fromDayKey key: Int64) -> Date? {
        var c = DateComponents()
        c.year = Int(key) / 10_000
        c.month = (Int(key) / 100) % 100
        c.day = Int(key % 100)
        return Calendar.current.date(from: c)
    }

    /// The day at `index` slices from the start of the window, if in range.
    private static func dayKey(forIndex index: Int, in data: AnalysisData) -> Int64? {
        guard index >= 0, index < data.range.days,
              let date = Calendar.current.date(byAdding: .day, value: index, to: data.xDomain.lowerBound)
        else { return nil }
        return dayKey(for: date)
    }

    private static func dayKey(for date: Date) -> Int64 {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return Int64((c.year ?? 0) * 10_000 + (c.month ?? 0) * 100 + (c.day ?? 0))
    }

    /// 单遍聚合：day × name token 和、按名称聚合、按天成本，一次算出
    /// 图表与表格的全部输入。
    private static func build(aggs: [Database.DayAgg],
                              modelAggs: [(day: Int64, model: String, input: Int64, output: Int64, cacheRead: Int64, cost: Double, count: Int64)],
                              grouping: Grouping,
                              range: Range,
                              modelColors: [String: Color]) -> AnalysisData {
        let rows: [Row] = grouping == .byTool
            ? aggs.map { Row(day: $0.day, key: $0.tool, input: $0.input, output: $0.output, cacheRead: $0.cacheRead, cost: $0.cost, count: $0.count) }
            : modelAggs.map { Row(day: $0.day, key: $0.model, input: $0.input, output: $0.output, cacheRead: $0.cacheRead, cost: $0.cost, count: $0.count) }

        var dayTokens: [Int64: [String: Int64]] = [:]
        var dayCost: [Int64: [String: Double]] = [:]
        var tokensByName: [String: Int64] = [:]
        var callsByName: [String: Int64] = [:]
        var costByName: [String: Double] = [:]
        for r in rows {
            let v = tokenValue(r, grouping: grouping)
            dayTokens[r.day, default: [:]][r.key, default: 0] += v
            tokensByName[r.key, default: 0] += v
            callsByName[r.key, default: 0] += max(r.count, 0)
            costByName[r.key, default: 0] += max(r.cost, 0)
            if r.cost > 0 { dayCost[r.day, default: [:]][r.key, default: 0] += r.cost }
        }

        let orderedNames = tokensByName.sorted { $0.value > $1.value }.map(\.key)
        let dayOrder = Set(rows.map(\.day)).sorted()
        let totalTokens = tokensByName.values.reduce(0, +)

        func label(_ name: String) -> String {
            grouping == .byTool ? (ToolKind(rawValue: name)?.displayName ?? name) : name
        }

        var tokenPoints: [ChartPoint] = []
        var costPoints: [ChartPoint] = []
        for d in dayOrder {
            guard let date = date(fromDayKey: d) else { continue }
            for name in orderedNames {
                let c = color(for: name, grouping: grouping, modelColors: modelColors)
                if let v = dayTokens[d]?[name], v > 0 {
                    tokenPoints.append(ChartPoint(dayKey: d, date: date, label: label(name),
                                                  color: c, value: Double(v)))
                }
                if let v = dayCost[d]?[name], v > 0 {
                    costPoints.append(ChartPoint(dayKey: d, date: date, label: label(name),
                                                 color: c, value: v))
                }
            }
        }

        let aggregates: [AggregateRow] = orderedNames.compactMap { name in
            let tokens = tokensByName[name] ?? 0
            guard tokens > 0 else { return nil }
            return AggregateRow(name: name,
                                tokens: tokens,
                                calls: callsByName[name] ?? 0,
                                cost: costByName[name] ?? 0,
                                ratio: totalTokens > 0 ? Double(tokens) / Double(totalTokens) : 0,
                                color: color(for: name, grouping: grouping, modelColors: modelColors))
        }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let first = calendar.date(byAdding: .day, value: -(range.days - 1), to: today) ?? today
        let end = calendar.date(byAdding: .day, value: 1, to: today) ?? today

        return AnalysisData(grouping: grouping,
                            range: range,
                            tokenPoints: tokenPoints,
                            costPoints: costPoints,
                            tokenByDay: Dictionary(grouping: tokenPoints, by: \.dayKey),
                            costByDay: Dictionary(grouping: costPoints, by: \.dayKey),
                            labels: aggregates.map { label($0.name) },
                            colors: aggregates.map(\.color),
                            aggregates: aggregates,
                            dayCount: dayOrder.count,
                            totalTokens: totalTokens,
                            totalCost: costByName.values.reduce(0, +),
                            totalCalls: callsByName.values.reduce(0, +),
                            xDomain: first...end)
    }

    private static func tokenValue(_ row: Row, grouping: Grouping) -> Int64 {
        if grouping == .byTool {
            return ToolKind(rawValue: row.key)?.totalTokens(input: row.input,
                                                            output: row.output,
                                                            cacheRead: row.cacheRead)
                ?? row.input + row.output
        }
        return row.input + row.output + row.cacheRead
    }

    private static func color(for name: String, grouping: Grouping, modelColors: [String: Color]) -> Color {
        if grouping == .byTool {
            return ToolKind(rawValue: name)?.color ?? TMDesign.accent
        }
        // 模型色：按用量排名预分配（assignModelColors），同一模型在
        // 图表/图例/表格里永远同色；新出现的模型兜底第一个色。
        return modelColors[name] ?? TMDesign.modelPalette[0]
    }

    /// 当前展示数据的分组（切换期间旧数据渲染时跟随旧分组，保持标签一致）。
    private var displayGrouping: Grouping {
        analysis?.grouping ?? grouping
    }

    private func displayName(for name: String) -> String {
        displayGrouping == .byTool
            ? (ToolKind(rawValue: name)?.displayName ?? name)
            : name
    }

    // MARK: - Chart（按天堆叠；token 与成本共用一张图）

    private func chart(_ data: AnalysisData) -> some View {
        let points = metric == .tokens ? data.tokenPoints : data.costPoints
        let byDay = metric == .tokens ? data.tokenByDay : data.costByDay
        let step = data.range.days <= 7 ? 1 : (data.range.days <= 30 ? 5 : 14)
        let metricName = metric.rawValue
        let groupName = displayGrouping == .byTool ? "Tool" : "Model"
        return Group {
            if points.isEmpty {
                Text(metric == .tokens ? "No data in this range" : "No estimated cost in this range")
                    .font(TMType.regular(TMType.body))
                    .foregroundStyle(TMDesign.quiet)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Chart {
                    ForEach(points) { p in
                        BarMark(x: .value("Day", p.date, unit: .day),
                                y: .value(metricName, p.value),
                                width: .ratio(0.74))
                            .foregroundStyle(by: .value(groupName, p.label))
                    }
                    if let key = hoveredDay, let date = Self.date(fromDayKey: key), byDay[key] != nil {
                        RuleMark(x: .value("Day", date, unit: .day))
                            .foregroundStyle(Color.primary.opacity(0.14))
                    }
                }
                .chartForegroundStyleScale(domain: data.labels, range: data.colors)
                .chartLegend(.hidden)
                .chartXScale(domain: data.xDomain)
                .chartXAxis {
                    // One label per `step` days, at the center of that day's bar.
                    AxisMarks(values: Self.tickDates(in: data.xDomain, every: step)) { _ in
                        AxisValueLabel(format: Self.axisDate)
                            .font(TMType.regular(TMType.caption))
                            .foregroundStyle(TMDesign.quiet)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                            .foregroundStyle(Color.primary.opacity(0.14))
                        AxisValueLabel {
                            if let v = value.as(Double.self) {
                                Text(metric == .tokens ? Format.compact(Int64(v)) : Format.moneyShort(v))
                                    .font(TMType.regular(TMType.caption))
                                    .tmMonospacedDigit()
                                    .foregroundStyle(TMDesign.quiet)
                            }
                        }
                    }
                }
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        let plot = geo[proxy.plotAreaFrame]
                        // Each day owns an equal slice of the plot area, so the
                        // pointer maps to a day without asking the axis.
                        let dayWidth = plot.width / CGFloat(max(data.range.days, 1))
                        ZStack(alignment: .topLeading) {
                            Color.clear
                                .contentShape(Rectangle())
                                .onContinuousHover { phase in
                                    switch phase {
                                    case .active(let location):
                                        let index = Int(floor((location.x - plot.origin.x) / dayWidth))
                                        let next = Self.dayKey(forIndex: index, in: data)
                                            .flatMap { byDay[$0] != nil ? $0 : nil }
                                        if hoveredDay != next { hoveredDay = next }
                                    case .ended:
                                        hoveredDay = nil
                                    }
                                }
                            if let key = hoveredDay, let segments = byDay[key],
                               let date = Self.date(fromDayKey: key) {
                                let index = Calendar.current.dateComponents(
                                    [.day], from: data.xDomain.lowerBound, to: date).day ?? 0
                                let centerX = plot.origin.x + (CGFloat(index) + 0.5) * dayWidth
                                // The callout sits beside the bar, on whichever
                                // side has room, so it never covers the bar.
                                let onRight = centerX < geo.size.width / 2
                                dayCallout(key: key, segments: segments)
                                    .fixedSize()
                                    .frame(width: geo.size.width, height: geo.size.height,
                                           alignment: onRight ? .topLeading : .topTrailing)
                                    .padding(onRight ? .leading : .trailing,
                                             onRight ? centerX + dayWidth
                                                     : geo.size.width - centerX + dayWidth)
                                    .padding(.top, 4)
                                    .allowsHitTesting(false)
                            }
                        }
                    }
                }
                // The chart takes whatever height the window leaves.
                .frame(minHeight: 150, maxHeight: .infinity)
                .accessibilityLabel(metric == .tokens ? "Tokens per day" : "Estimated cost per day")
            }
        }
    }

    /// The hovered day, Health-style: a callout above the bar with the day's
    /// total and its split.
    private func dayCallout(key: Int64, segments: [ChartPoint]) -> some View {
        let total = segments.reduce(0) { $0 + $1.value }
        func text(_ v: Double) -> String {
            metric == .tokens ? Format.compact(Int64(v)) : Format.money(v)
        }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(Format.shortDayKey(key))
                    .font(TMType.regular(TMType.caption))
                    .foregroundStyle(TMDesign.quiet)
                Spacer(minLength: 0)
                Text(text(total))
                    .font(TMType.semibold(TMType.body))
                    .tmMonospacedDigit()
            }
            ForEach(segments.sorted { $0.value > $1.value }) { seg in
                HStack(spacing: 6) {
                    Circle().fill(seg.color).frame(width: 7, height: 7)
                    Text(seg.label)
                        .font(TMType.regular(TMType.caption))
                        .lineLimit(1)
                    Spacer(minLength: 12)
                    Text(text(seg.value))
                        .font(TMType.regular(TMType.caption))
                        .tmMonospacedDigit()
                        .foregroundStyle(TMDesign.quiet)
                }
            }
        }
        .padding(10)
        .frame(width: 210)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
    }

    // MARK: - 聚合表

    private var aggTable: some View {
        let rows = analysis?.aggregates ?? []
        return Group {
            if rows.isEmpty {
                Text("No data")
                    .font(TMType.regular(TMType.body))
                    .foregroundStyle(TMDesign.quiet)
            } else {
                // Up to four rows at full height; more scroll inside the card
                // so the chart keeps its share of the page.
                ScrollView(.vertical) { detailsGrid(rows) }
                    .frame(height: Self.detailsHeaderHeight
                           + CGFloat(min(rows.count, 4)) * Self.detailsRowHeight)
            }
        }
    }

    private static let detailsHeaderHeight: CGFloat = 26
    private static let detailsRowHeight: CGFloat = 38

    private func detailsGrid(_ rows: [AggregateRow]) -> some View {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 0) {
                    GridRow {
                        Text(displayGrouping == .byTool ? "Tool" : "Model")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("Tokens").gridColumnAlignment(.trailing)
                        Text("Calls").gridColumnAlignment(.trailing)
                        Text("Cost").gridColumnAlignment(.trailing)
                        Text("Share")
                            .frame(width: 150, alignment: .leading)
                    }
                    .font(TMType.medium(TMType.caption))
                    .foregroundStyle(TMDesign.quiet)
                    .frame(height: Self.detailsHeaderHeight, alignment: .top)

                    ForEach(rows, id: \.name) { r in
                        Divider().gridCellUnsizedAxes(.horizontal)
                        GridRow {
                            HStack(spacing: 8) {
                                Circle().fill(r.color).frame(width: 8, height: 8)
                                Text(displayName(for: r.name))
                                    .font(TMType.regular(TMType.body))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Text(Format.compact(r.tokens))
                                .font(TMType.medium(TMType.body))
                            Text(Format.count(r.calls))
                                .foregroundStyle(TMDesign.quiet)
                            Text(r.cost > 0 ? Format.moneyShort(r.cost) : "—")
                                .foregroundStyle(TMDesign.quiet)
                            HStack(spacing: 8) {
                                DashUsageBar(usedPercent: r.ratio * 100, tint: r.color, height: 5)
                                    .frame(width: 84)
                                Text(String(format: "%.1f%%", r.ratio * 100))
                                    .foregroundStyle(TMDesign.quiet)
                                    .frame(width: 46, alignment: .trailing)
                            }
                            .frame(width: 150, alignment: .leading)
                        }
                        .font(TMType.regular(TMType.body))
                        .tmMonospacedDigit()
                        .frame(height: Self.detailsRowHeight - 1)
                    }
                }
                .padding(.trailing, 4)
    }

    // MARK: - Legend

    private var legend: some View {
        // Sorted by usage (aggregates are descending), top 6.
        let top = analysis?.aggregates.prefix(6) ?? []
        return HStack(spacing: 14) {
            ForEach(top, id: \.name) { r in
                HStack(spacing: 5) {
                    Circle().fill(r.color).frame(width: 8, height: 8)
                    Text(displayName(for: r.name))
                        .font(TMType.regular(TMType.caption))
                        .foregroundStyle(TMDesign.quiet)
                        .lineLimit(1)
                }
            }
        }
    }
}
