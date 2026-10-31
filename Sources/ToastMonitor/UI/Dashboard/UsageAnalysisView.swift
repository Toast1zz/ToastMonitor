import AppKit
import Charts
import SwiftUI

/// Analysis: one control bar (metric, range, grouping), summary figures, a
/// per-day stacked bar chart and the aggregate table. Charts are Swift Charts,
/// so axes, grid lines, VoiceOver and Audio Graphs are the system's.
struct UsageAnalysisView: View {
    var readinessChanged: ((Bool) -> Void)? = nil
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

    // MARK: - Derived data (rebuilt only when data arrives)

    /// Normalized row: (day, groupKey, input, output, cacheRead, cost, calls)
    private struct Row {
        let day: Int64
        let key: String
        let input: Int64
        let output: Int64
        let cacheRead: Int64
        let cost: Double
        let count: Int64
        let totalTokens: Int64?
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

    /// Every derived chart/table input, built in one pass over the raw rows
    /// when data arrives; old values keep rendering while range/grouping change.
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
        /// What the CSV export writes: raw ids, not merged display names.
        let csvRows: [AnalysisCSVRow]
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
        for row in analysis.csvRows {
            let textFields = [analysis.range.rawValue, analysis.grouping.rawValue, row.name]
                .map { Self.csvField($0) }
            let numberFields = [String(row.tokens), String(row.calls),
                                String(format: "%.6f", row.cost), String(format: "%.6f", row.ratio)]
                .map { Self.csvField($0, text: false) }
            lines.append((textFields + numberFields).joined(separator: ","))
        }
        do {
            try (lines.joined(separator: "\n") + "\n")
                .write(to: url, atomically: true, encoding: .utf8)
        } catch {
            exportError = error.localizedDescription
        }
    }

    static func csvField(_ value: String, text: Bool = true) -> String {
        var escaped = value
        if text {
            let leading = value.prefix(while: { $0.isWhitespace })
            let first = value.dropFirst(leading.count).first
            let formula = first.map { "=+-@".contains($0) } ?? false
            let control = leading.unicodeScalars.contains { $0.value == 9 || $0.value == 13 }
            if formula || control { escaped = "'" + value }
        }
        guard escaped.contains(",") || escaped.contains("\"") || escaped.contains("\n") || escaped.contains("\r") else { return escaped }
        return "\"\(escaped.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private func summary(_ data: AnalysisData) -> some View {
        let daily = data.dayCount > 0 ? data.totalTokens / Int64(data.dayCount) : 0
        return DashMetricRow {
            DashMetric(label: "Tokens · recorded only", value: Format.compact(data.totalTokens))
            DashMetric(label: "Estimated Cost", value: Format.moneyShort(data.totalCost))
            DashMetric(label: "Daily Avg Tokens", value: Format.compact(daily))
            DashMetric(label: "Calls", value: Format.count(data.totalCalls))
        }
    }

    private func load() {
        let requestID = UUID()
        loadID = requestID
        isLoading = true
        readinessChanged?(false)
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
                readinessChanged?(true)
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
                readinessChanged?(true)
            }
        }
    }

    /// Rank models by total tokens (descending) and hand each the next
    /// palette color — the top model gets the first color, no collisions.
    private static func assignModelColors(_ aggs: [(day: Int64, model: String, input: Int64, output: Int64, cacheRead: Int64, cost: Double, count: Int64, totalTokens: Int64)]) -> [String: Color] {
        let totals: [String: Int64] = aggs.reduce(into: [:]) { acc, row in
            acc[ModelName.display(row.model), default: 0] += row.totalTokens
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

    /// One pass: per-day × name token sums, per-name totals and per-day cost —
    /// every chart and table input.
    private static func build(aggs: [Database.DayAgg],
                              modelAggs: [(day: Int64, model: String, input: Int64, output: Int64, cacheRead: Int64, cost: Double, count: Int64, totalTokens: Int64)],
                              grouping: Grouping,
                              range: Range,
                              modelColors: [String: Color]) -> AnalysisData {
        let rows: [Row] = grouping == .byTool
            ? aggs.map { Row(day: $0.day, key: $0.tool, input: $0.input, output: $0.output, cacheRead: $0.cacheRead, cost: $0.cost, count: $0.count, totalTokens: nil) }
            : modelAggs.map { Row(day: $0.day, key: ModelName.display($0.model), input: $0.input, output: $0.output, cacheRead: $0.cacheRead, cost: $0.cost, count: $0.count, totalTokens: $0.totalTokens) }

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
        // Models past the legend share one gray: more colors than the legend
        // can name leave segments nobody can identify. The table lists them all.
        let chartedNames = grouping == .byModel ? Array(orderedNames.prefix(legendLimit)) : orderedNames
        let charted = Set(chartedNames)
        func chartName(_ name: String) -> String { charted.contains(name) ? name : otherLabel }
        let dayOrder = Set(rows.map(\.day)).sorted()
        let totalTokens = tokensByName.values.reduce(0, +)

        func label(_ name: String) -> String {
            grouping == .byTool ? (ToolKind(rawValue: name)?.displayName ?? name) : name
        }

        var tokenPoints: [ChartPoint] = []
        var costPoints: [ChartPoint] = []
        for d in dayOrder {
            guard let date = date(fromDayKey: d) else { continue }
            var tokens: [String: Double] = [:]
            var cost: [String: Double] = [:]
            for name in orderedNames {
                tokens[chartName(name), default: 0] += Double(dayTokens[d]?[name] ?? 0)
                cost[chartName(name), default: 0] += dayCost[d]?[name] ?? 0
            }
            for name in chartedNames + [otherLabel] {
                let c = name == otherLabel ? otherColor : color(for: name, grouping: grouping, modelColors: modelColors)
                if let v = tokens[name], v > 0 {
                    tokenPoints.append(ChartPoint(dayKey: d, date: date, label: label(name),
                                                  color: c, value: v))
                }
                if let v = cost[name], v > 0 {
                    costPoints.append(ChartPoint(dayKey: d, date: date, label: label(name),
                                                 color: c, value: v))
                }
            }
        }

        // CSV keeps the raw ids, one row per id, so an export can be matched
        // back to the logs and the price table.
        let csvRows: [AnalysisCSVRow]
        if grouping == .byTool {
            csvRows = orderedNames.compactMap { name in
                let tokens = tokensByName[name] ?? 0
                guard tokens > 0 else { return nil }
                return AnalysisCSVRow(name: name, tokens: tokens, calls: callsByName[name] ?? 0,
                                      cost: costByName[name] ?? 0,
                                      ratio: totalTokens > 0 ? Double(tokens) / Double(totalTokens) : 0)
            }
        } else {
            csvRows = AnalysisCSVRow.perModelID(modelAggs)
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
        let hasOther = chartedNames.count < orderedNames.count
        let chartedAggregates = aggregates.filter { charted.contains($0.name) }

        return AnalysisData(grouping: grouping,
                            range: range,
                            tokenPoints: tokenPoints,
                            costPoints: costPoints,
                            tokenByDay: Dictionary(grouping: tokenPoints, by: \.dayKey),
                            costByDay: Dictionary(grouping: costPoints, by: \.dayKey),
                            labels: chartedAggregates.map { label($0.name) } + (hasOther ? [otherLabel] : []),
                            colors: chartedAggregates.map(\.color) + (hasOther ? [otherColor] : []),
                            aggregates: aggregates,
                            csvRows: csvRows,
                            dayCount: dayOrder.count,
                            totalTokens: totalTokens,
                            totalCost: costByName.values.reduce(0, +),
                            totalCalls: callsByName.values.reduce(0, +),
                            xDomain: first...end)
    }

    private static let legendLimit = 5
    private static let otherLabel = "Other"
    private static let otherColor = Color.primary.opacity(0.25)

    private static func tokenValue(_ row: Row, grouping: Grouping) -> Int64 {
        if grouping == .byTool {
            return ToolKind(rawValue: row.key)?.totalTokens(input: row.input,
                                                            output: row.output,
                                                            cacheRead: row.cacheRead)
                ?? row.input + row.output
        }
        return row.totalTokens ?? 0
    }

    private static func color(for name: String, grouping: Grouping, modelColors: [String: Color]) -> Color {
        if grouping == .byTool {
            return TMDesign.sourceColor(name)
        }
        // Model colors are pre-assigned by usage rank (assignModelColors), so a
        // model has one color everywhere; a newly seen model gets the first.
        return modelColors[name] ?? TMDesign.modelPalette[0]
    }

    /// Grouping of the data on screen (follows the old grouping until new data lands).
    private var displayGrouping: Grouping {
        analysis?.grouping ?? grouping
    }

    private func displayName(for name: String) -> String {
        displayGrouping == .byTool
            ? (ToolKind(rawValue: name)?.displayName ?? name)
            : name
    }

    // MARK: - Chart (stacked per day; tokens and cost share one chart)

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

    // MARK: - Aggregate table

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
        // The chart's own scale, so every color on it is named here.
        let labels = analysis?.labels ?? []
        let colors = analysis?.colors ?? []
        return HStack(spacing: 14) {
            ForEach(Array(zip(labels, colors).enumerated()), id: \.offset) { _, item in
                HStack(spacing: 5) {
                    Circle().fill(item.1).frame(width: 8, height: 8)
                    Text(item.0)
                        .font(TMType.regular(TMType.caption))
                        .foregroundStyle(TMDesign.quiet)
                        .lineLimit(1)
                }
            }
        }
    }
}

/// One CSV line of the Analysis export.
struct AnalysisCSVRow: Equatable {
    let name: String
    let tokens: Int64
    let calls: Int64
    let cost: Double
    let ratio: Double

    /// One row per raw model id (never merged by display name), most-used
    /// first, so an export can be matched back to the logs and price table.
    static func perModelID(
        _ aggs: [(day: Int64, model: String, input: Int64, output: Int64, cacheRead: Int64, cost: Double, count: Int64, totalTokens: Int64)]
    ) -> [AnalysisCSVRow] {
        var tokens: [String: Int64] = [:], calls: [String: Int64] = [:], cost: [String: Double] = [:]
        for m in aggs {
            tokens[m.model, default: 0] += m.totalTokens
            calls[m.model, default: 0] += max(m.count, 0)
            cost[m.model, default: 0] += max(m.cost, 0)
        }
        let total = tokens.values.reduce(0, +)
        return tokens.filter { $0.value > 0 }
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map { id, t in
                AnalysisCSVRow(name: id, tokens: t, calls: calls[id] ?? 0, cost: cost[id] ?? 0,
                               ratio: total > 0 ? Double(t) / Double(total) : 0)
            }
    }
}
