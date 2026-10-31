import Charts
import SwiftUI

/// Performance: per-model output speed and time to first token, as the daily
/// median of every measured call, one line per model.
struct PerformanceView: View {
    enum Metric: String, CaseIterable, Identifiable {
        case speed = "Speed"
        case firstToken = "First Token"
        var id: String { rawValue }
    }

    typealias Range = UsageAnalysisView.Range

    @State private var metric: Metric = .speed
    @State private var range: Range = .d30
    @State private var data: PerfData?
    @State private var isLoading = true
    @State private var loadID = UUID()
    @State private var hoveredDay: Int64?
    /// Nil keeps the default ranking by calls.
    @State private var sort: TableSort?

    enum SortColumn {
        case speed, firstToken, calls

        /// Best first: fastest speed, shortest wait, most calls.
        var startsAscending: Bool { self == .firstToken }
    }

    struct TableSort: Equatable {
        var column: SortColumn
        var ascending: Bool
    }

    /// Lines beyond this many models turn the chart into noise; the table
    /// still lists every model.
    private static let chartModelLimit = 6
    /// A median of fewer samples than this is shown as "—".
    private static let minSamples = 20

    private static func median(_ samples: [Double]?) -> Double? {
        guard let samples, samples.count >= minSamples else { return nil }
        return PerfStats.median(samples)
    }

    private struct ModelRow {
        let model: String
        let color: Color
        let tokensPerSecond: Double?
        let ttftMs: Double?
        let calls: Int
    }

    private struct ChartPoint: Identifiable {
        let day: Int64
        let date: Date
        let model: String
        let value: Double
        var id: String { "\(day)|\(model)" }
    }

    private struct PerfData {
        let range: Range
        let rows: [ModelRow]
        let speedPoints: [ChartPoint]
        let ttftPoints: [ChartPoint]
        let chartModels: [String]
        let chartColors: [Color]
        let calls: Int
        let xDomain: ClosedRange<Date>
    }

    var body: some View {
        DashPage {
            controlBar
            if let data, !data.rows.isEmpty {
                summary(data)
                DashCard(metric == .speed ? "Output Speed" : "Time to First Token",
                         trailing: { legend(data) }) {
                    chart(data)
                }
                DashCard("Details") { table(data.rows) }
                    .dashFixedHeight()
            } else if isLoading {
                ProgressView("Loading performance…")
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("No measured calls in this range")
                    .font(TMType.regular(TMType.body))
                    .foregroundStyle(TMDesign.quiet)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { load() }
        .onChange(of: range) { _ in load() }
    }

    private var controlBar: some View {
        HStack(alignment: .center, spacing: 12) {
            DashSegmented(selection: $metric, options: Metric.allCases,
                          title: { $0.rawValue }, accessibilityName: "Metric")
            Spacer(minLength: 8)
            if isLoading, data != nil {
                ProgressView().controlSize(.small)
                    .accessibilityLabel("Updating performance")
            }
            DashSegmented(selection: $range, options: Range.allCases,
                          title: { $0.rawValue }, accessibilityName: "Range")
        }
    }

    private func summary(_ data: PerfData) -> some View {
        DashMetricRow {
            // One model each: a median across models mostly reports whichever
            // model happens to leave the most samples.
            let speed = data.rows.first { $0.tokensPerSecond != nil }
            let first = data.rows.first { $0.ttftMs != nil }
            DashMetric(label: speed.map { "Speed · \($0.model)" } ?? "Speed",
                       value: Self.speedText(speed?.tokensPerSecond))
            DashMetric(label: first.map { "First Token · \($0.model)" } ?? "First Token",
                       value: Self.ttftText(first?.ttftMs))
            DashMetric(label: "Measured Calls", value: Format.count(Int64(data.calls)))
        }
    }

    private func load() {
        let requestID = UUID()
        loadID = requestID
        isLoading = true
        let range = self.range
        UsageQueryService.shared.loadPerfPoints(days: range.days) { points in
            guard loadID == requestID else { return }
            isLoading = false
            hoveredDay = nil
            data = Self.build(points, range: range)
        }
    }

    private static func build(_ rawPoints: [PerfPoint], range: Range) -> PerfData {
        // Group by the name the reader sees, so one model logged under
        // several ids is one line and one table row.
        let points = rawPoints.map {
            PerfPoint(day: $0.day, tool: $0.tool, model: ModelName.display($0.model),
                      ttftMs: $0.ttftMs, tokensPerSecond: $0.tokensPerSecond)
        }
        var callsByModel: [String: Int] = [:]
        var speedByModel: [String: [Double]] = [:]
        var ttftByModel: [String: [Double]] = [:]
        var speedByDay: [Int64: [String: [Double]]] = [:]
        var ttftByDay: [Int64: [String: [Double]]] = [:]
        for p in points {
            callsByModel[p.model, default: 0] += 1
            if let v = p.tokensPerSecond {
                speedByModel[p.model, default: []].append(v)
                speedByDay[p.day, default: [:]][p.model, default: []].append(v)
            }
            if let v = p.ttftMs {
                ttftByModel[p.model, default: []].append(v)
                ttftByDay[p.day, default: [:]][p.model, default: []].append(v)
            }
        }
        let ranked = callsByModel.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map(\.key)
        let palette = TMDesign.modelPalette
        let colors = Dictionary(uniqueKeysWithValues: ranked.enumerated().map { ($1, palette[$0 % palette.count]) })
        let chartModels = Array(ranked.prefix(chartModelLimit))
        let chartSet = Set(chartModels)

        func series(_ byDay: [Int64: [String: [Double]]]) -> [ChartPoint] {
            byDay.keys.sorted().flatMap { day -> [ChartPoint] in
                guard let date = date(fromDayKey: day) else { return [] }
                return chartModels.compactMap { model in
                    guard chartSet.contains(model),
                          let value = byDay[day]?[model].flatMap(PerfStats.median) else { return nil }
                    return ChartPoint(day: day, date: date, model: model, value: value)
                }
            }
        }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let first = calendar.date(byAdding: .day, value: -(range.days - 1), to: today) ?? today
        let end = calendar.date(byAdding: .day, value: 1, to: today) ?? today

        return PerfData(
            range: range,
            rows: ranked.map { model in
                ModelRow(model: model, color: colors[model] ?? palette[0],
                         tokensPerSecond: median(speedByModel[model]),
                         ttftMs: median(ttftByModel[model]),
                         calls: callsByModel[model] ?? 0)
            },
            speedPoints: series(speedByDay),
            ttftPoints: series(ttftByDay),
            chartModels: chartModels,
            chartColors: chartModels.map { colors[$0] ?? palette[0] },
            calls: points.count,
            xDomain: first...end)
    }

    private static func date(fromDayKey key: Int64) -> Date? {
        var c = DateComponents()
        c.year = Int(key) / 10_000
        c.month = (Int(key) / 100) % 100
        c.day = Int(key % 100)
        c.hour = 12
        return Calendar.current.date(from: c)
    }

    private static func speedText(_ v: Double?) -> String {
        guard let v else { return "—" }
        return "\(Int(v.rounded())) tok/s"
    }

    private static func ttftText(_ ms: Double?) -> String {
        guard let ms else { return "—" }
        return ms < 1000 ? "\(Int(ms.rounded())) ms" : String(format: "%.1f s", ms / 1000)
    }

    private func valueText(_ v: Double) -> String {
        metric == .speed ? Self.speedText(v) : Self.ttftText(v)
    }

    private static let axisDate = Date.FormatStyle()
        .month(.abbreviated).day().locale(Locale(identifier: "en_US"))

    // MARK: - Chart

    private func chart(_ data: PerfData) -> some View {
        let points = metric == .speed ? data.speedPoints : data.ttftPoints
        let byDay = Dictionary(grouping: points, by: \.day)
        let step = data.range.days <= 7 ? 1 : (data.range.days <= 30 ? 5 : 14)
        let metricName = metric.rawValue
        return Group {
            if points.isEmpty {
                Text(metric == .speed ? "No speed measured in this range"
                                      : "No first-token time measured in this range")
                    .font(TMType.regular(TMType.body))
                    .foregroundStyle(TMDesign.quiet)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Chart {
                    ForEach(points) { p in
                        LineMark(x: .value("Day", p.date, unit: .day),
                                 y: .value(metricName, p.value))
                            .foregroundStyle(by: .value("Model", p.model))
                            .interpolationMethod(.monotone)
                        PointMark(x: .value("Day", p.date, unit: .day),
                                  y: .value(metricName, p.value))
                            .foregroundStyle(by: .value("Model", p.model))
                            .symbolSize(hoveredDay == p.day ? 40 : 16)
                    }
                    if let day = hoveredDay, let date = Self.date(fromDayKey: day) {
                        RuleMark(x: .value("Day", date, unit: .day))
                            .foregroundStyle(Color.primary.opacity(0.14))
                    }
                }
                .chartForegroundStyleScale(domain: data.chartModels, range: data.chartColors)
                .chartLegend(.hidden)
                .chartXScale(domain: data.xDomain)
                .chartXAxis {
                    // Points sit at midday, so ticks do too.
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
                                Text(valueText(v))
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
                        let dayWidth = plot.width / CGFloat(max(data.range.days, 1))
                        ZStack(alignment: .topLeading) {
                            Color.clear
                                .contentShape(Rectangle())
                                .onContinuousHover { phase in
                                    switch phase {
                                    case .active(let location):
                                        let index = Int(floor((location.x - plot.origin.x) / dayWidth))
                                        let next = Calendar.current
                                            .date(byAdding: .day, value: index, to: data.xDomain.lowerBound)
                                            .map(Self.dayKey(for:))
                                            .flatMap { byDay[$0] != nil ? $0 : nil }
                                        if hoveredDay != next { hoveredDay = next }
                                    case .ended:
                                        hoveredDay = nil
                                    }
                                }
                            if let day = hoveredDay, let dayPoints = byDay[day],
                               let date = Self.date(fromDayKey: day) {
                                let index = Calendar.current.dateComponents(
                                    [.day], from: data.xDomain.lowerBound, to: date).day ?? 0
                                let centerX = plot.origin.x + (CGFloat(index) + 0.5) * dayWidth
                                let onRight = centerX < geo.size.width / 2
                                callout(day: day, points: dayPoints)
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
                .frame(minHeight: 150, maxHeight: .infinity)
                .accessibilityLabel(metric == .speed ? "Output speed per day by model"
                                                     : "Time to first token per day by model")
            }
        }
    }

    private static func tickDates(in domain: ClosedRange<Date>, every step: Int) -> [Date] {
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: domain.lowerBound, to: domain.upperBound).day ?? 0
        return stride(from: 0, to: days, by: step).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: domain.lowerBound)
                .flatMap { calendar.date(byAdding: .hour, value: 12, to: $0) }
        }
    }

    private static func dayKey(for date: Date) -> Int64 {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return Int64((c.year ?? 0) * 10_000 + (c.month ?? 0) * 100 + (c.day ?? 0))
    }

    private func callout(day: Int64, points: [ChartPoint]) -> some View {
        let colors = Dictionary(uniqueKeysWithValues: (data?.rows ?? []).map { ($0.model, $0.color) })
        // Faster is better for speed, sooner is better for first token.
        let sorted = points.sorted { metric == .speed ? $0.value > $1.value : $0.value < $1.value }
        return VStack(alignment: .leading, spacing: 6) {
            Text(Format.shortDayKey(day))
                .font(TMType.regular(TMType.caption))
                .foregroundStyle(TMDesign.quiet)
            ForEach(sorted) { p in
                HStack(spacing: 6) {
                    Circle().fill(colors[p.model] ?? TMDesign.accent).frame(width: 7, height: 7)
                    Text(p.model)
                        .font(TMType.regular(TMType.caption))
                        .lineLimit(1)
                    Spacer(minLength: 12)
                    Text(valueText(p.value))
                        .font(TMType.regular(TMType.caption))
                        .tmMonospacedDigit()
                        .foregroundStyle(TMDesign.quiet)
                }
            }
        }
        .padding(10)
        .frame(width: 230)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
    }

    private func legend(_ data: PerfData) -> some View {
        HStack(spacing: 14) {
            ForEach(Array(zip(data.chartModels, data.chartColors)), id: \.0) { model, color in
                HStack(spacing: 5) {
                    Circle().fill(color).frame(width: 8, height: 8)
                    Text(model)
                        .font(TMType.regular(TMType.caption))
                        .foregroundStyle(TMDesign.quiet)
                        .lineLimit(1)
                }
            }
        }
    }

    // MARK: - Table

    private static let headerHeight: CGFloat = 26
    private static let rowHeight: CGFloat = 38

    /// Rows in the chosen order. Models without a figure for the sorted
    /// column go last either way; ties keep the call ranking.
    private static func sorted(_ rows: [ModelRow], by sort: TableSort?) -> [ModelRow] {
        guard let sort else { return rows }
        func value(_ r: ModelRow) -> Double? {
            switch sort.column {
            case .speed: return r.tokensPerSecond
            case .firstToken: return r.ttftMs
            case .calls: return Double(r.calls)
            }
        }
        return rows.enumerated().sorted { a, b in
            switch (value(a.element), value(b.element)) {
            case let (x?, y?) where x != y: return sort.ascending ? x < y : x > y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.offset < b.offset
            }
        }.map(\.element)
    }

    private func sortHeader(_ title: String, _ column: SortColumn) -> some View {
        let active = sort?.column == column
        let ascending = sort?.ascending ?? false
        return Button {
            sort = active
                ? TableSort(column: column, ascending: !ascending)
                : TableSort(column: column, ascending: column.startsAscending)
        } label: {
            HStack(spacing: 3) {
                Text(title)
                // Always laid out so switching columns never shifts the header.
                Image(systemName: active && ascending ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .opacity(active ? 1 : 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(active ? (ascending ? "Ascending" : "Descending") : "")
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private func table(_ rows: [ModelRow]) -> some View {
        ScrollView(.vertical) {
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 0) {
                GridRow {
                    // Back to the default ranking.
                    Button { sort = nil } label: {
                        Text("Model").contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    sortHeader("Speed", .speed).gridColumnAlignment(.trailing)
                    sortHeader("First Token", .firstToken).gridColumnAlignment(.trailing)
                    sortHeader("Calls", .calls).gridColumnAlignment(.trailing)
                }
                .font(TMType.medium(TMType.caption))
                .foregroundStyle(TMDesign.quiet)
                .frame(height: Self.headerHeight, alignment: .top)

                ForEach(Self.sorted(rows, by: sort), id: \.model) { r in
                    Divider().gridCellUnsizedAxes(.horizontal)
                    GridRow {
                        HStack(spacing: 8) {
                            Circle().fill(r.color).frame(width: 8, height: 8)
                            Text(r.model)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Text(Self.speedText(r.tokensPerSecond))
                            .font(TMType.medium(TMType.body))
                        Text(Self.ttftText(r.ttftMs))
                            .foregroundStyle(TMDesign.quiet)
                        Text(Format.count(Int64(r.calls)))
                            .foregroundStyle(TMDesign.quiet)
                    }
                    .font(TMType.regular(TMType.body))
                    .tmMonospacedDigit()
                    .frame(height: Self.rowHeight - 1)
                }
            }
            // The scroller runs in the card's margin, clear of the figures.
            .padding(.trailing, DashLayout.cardPadding)
            .overlayScrollers()
        }
        .padding(.trailing, -DashLayout.cardPadding)
        .frame(height: Self.headerHeight + CGFloat(min(rows.count, 4)) * Self.rowHeight)
    }
}
