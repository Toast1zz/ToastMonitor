import AppKit
import Charts
import SwiftUI

/// Performance: per-model output speed and time to first token, as the daily
/// median of every measured call, one line per model.
struct PerformanceView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dashboardActiveTab) private var activeTab

    enum Metric: String, CaseIterable, Identifiable {
        case speed = "Speed"
        case firstToken = "First Token"
        var id: String { rawValue }
    }

    typealias Range = UsageAnalysisView.Range

    @State private var metric: Metric = .speed
    @State private var range: Range = .d30
    @State private var data: PerfData?
    @State private var renderState = ChartRenderState.empty
    @State private var isLoading = true
    @State private var loadID = UUID()
    @State private var needsReload = false
    @State private var hoveredDay: Int64?
    @State private var hoveredModel: String?
    @State private var pinnedModel: String?
    @State private var exportError: String?
    /// Nil keeps the default ranking by calls.
    @State private var sort: TableSort?
    /// Providers left out of the view, one per line. Hidden rather than
    /// shown, so a provider used for the first time appears on its own.
    @AppStorage("performance.hiddenProviders") private var hiddenProvidersRaw = ""

    enum SortColumn {
        case speed, firstToken, ttftP90, calls

        /// Best first: fastest speed, shortest wait, most calls.
        var startsAscending: Bool { self == .firstToken || self == .ttftP90 }
    }

    struct TableSort: Equatable {
        var column: SortColumn
        var ascending: Bool
    }

    struct ModelRow: Equatable, Sendable {
        let model: String
        let provider: String
        /// Fixed by call rank, so a line keeps its color while others come and go.
        let color: Color
        let tokensPerSecond: Double?
        let ttftMs: Double?
        let ttftP90Ms: Double?
        let calls: Int
    }

    struct ChartPoint: Identifiable, Sendable {
        let day: Int64
        let date: Date
        let model: String
        let value: Double
        var id: String { "\(day)|\(model)" }
    }

    struct PerfData: Sendable {
        let range: Range
        let rows: [ModelRow]
        let speedPoints: [ChartPoint]
        let ttftPoints: [ChartPoint]
        /// Providers in this range: most calls first, "Other" last.
        let providers: [String]
        let calls: Int
        let xDomain: ClosedRange<Date>
    }

    private struct ChartRenderState {
        let shownRows: [ModelRow]
        let models: [String]
        let colors: [Color]
        let colorsByModel: [String: Color]
        let points: [ChartPoint]
        let byDay: [Int64: [ChartPoint]]
        let visibleCalls: Int

        static let empty = ChartRenderState(
            shownRows: [], models: [], colors: [], colorsByModel: [:],
            points: [], byDay: [:], visibleCalls: 0
        )
    }

    private var activeHighlightModel: String? {
        hoveredModel ?? pinnedModel
    }

    var body: some View {
        DashPage {
            controlBar
            if let data, !data.rows.isEmpty {
                summary(renderState)
                DashCard(metric == .speed ? "Output Speed" : "Time to First Token",
                         trailing: { providerPills(data) }) {
                    VStack(alignment: .leading, spacing: 12) {
                        chart(data, state: renderState)
                        if !renderState.shownRows.isEmpty {
                            legend(renderState.shownRows)
                        }
                    }
                }
                if !renderState.shownRows.isEmpty {
                    DashCard("Details") { table(renderState.shownRows) }
                        .dashFixedHeight()
                }
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
        .onAppear { load(showSpinner: data == nil) }
        .onChange(of: range) { _ in load(showSpinner: true) }
        .onChange(of: app.lastScan) { _ in handleExternalUpdate() }
        .onReceive(NotificationCenter.default.publisher(for: PerfCollector.didUpdate)) { _ in
            handleExternalUpdate()
        }
        .onChange(of: activeTab) { _ in
            if isTabActive, needsReload {
                load(showSpinner: data == nil)
            }
        }
        .onChange(of: metric) { _ in rebuildRenderState() }
        .onChange(of: hiddenProvidersRaw) { _ in rebuildRenderState() }
        .alert("Export failed", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } })) {
                Button("OK", role: .cancel) { exportError = nil }
            } message: {
                Text(exportError ?? "The CSV could not be written.")
            }
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
            Button(action: exportCSV) {
                Image(systemName: "square.and.arrow.up")
            }
            .tmGlassButton(circle: true, extraLarge: true)
            .disabled(renderState.shownRows.isEmpty || isLoading)
            .help("Export current performance summary as CSV")
            .accessibilityLabel("Export current performance summary as CSV")
        }
    }

    private func summary(_ state: ChartRenderState) -> some View {
        DashMetricRow {
            let speed = state.shownRows.first { $0.tokensPerSecond != nil }
            let first = state.shownRows.first { $0.ttftMs != nil }
            DashMetric(label: speed.map { "Speed · \($0.model)" } ?? "Speed",
                       value: Self.speedText(speed?.tokensPerSecond))
            DashMetric(label: first.map { "First Token · \($0.model)" } ?? "First Token",
                       value: Self.ttftText(first?.ttftMs))
            DashMetric(label: "Measured Calls", value: Format.count(Int64(state.visibleCalls)))
        }
    }

    private var isTabActive: Bool {
        activeTab == nil || activeTab == .performance
    }

    private func handleExternalUpdate() {
        guard isTabActive else {
            needsReload = true
            return
        }
        load(showSpinner: data == nil)
    }

    private func load(showSpinner: Bool) {
        let requestID = UUID()
        loadID = requestID
        needsReload = false
        if showSpinner { isLoading = true }
        let range = self.range
        UsageQueryService.shared.loadPerfPoints(days: range.days) { points in
            guard loadID == requestID else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                let built = Self.build(points, range: range)
                DispatchQueue.main.async {
                    guard loadID == requestID else { return }
                    isLoading = false
                    if showSpinner { hoveredDay = nil }
                    data = built
                    rebuildRenderState()
                }
            }
        }
    }

    private func rebuildRenderState() {
        guard let data else {
            renderState = .empty
            return
        }
        let hidden = hiddenProviders
        let shownRows = data.rows.filter { !hidden.contains($0.provider) }
        let models = shownRows.map(\.model)
        let shownSet = Set(models)
        let points = (metric == .speed ? data.speedPoints : data.ttftPoints)
            .filter { shownSet.contains($0.model) }
        let byDay = Dictionary(grouping: points, by: \.day)
        let colorsByModel = Dictionary(uniqueKeysWithValues: shownRows.map { ($0.model, $0.color) })
        let visibleCalls = shownRows.reduce(0) { $0 + $1.calls }
        if let pinned = pinnedModel, !shownSet.contains(pinned) {
            pinnedModel = nil
        }
        if let hovered = hoveredModel, !shownSet.contains(hovered) {
            hoveredModel = nil
        }
        if let day = hoveredDay, byDay[day]?.isEmpty ?? true {
            hoveredDay = nil
        }
        renderState = ChartRenderState(
            shownRows: shownRows,
            models: models,
            colors: shownRows.map(\.color),
            colorsByModel: colorsByModel,
            points: points,
            byDay: byDay,
            visibleCalls: visibleCalls
        )
    }

    nonisolated static func build(_ rawPoints: [PerfPoint], range: Range, now: Date = Date()) -> PerfData {
        // Group by the name the reader sees, so one model logged under
        // several ids is one line and one table row.
        var providerByModel: [String: String] = [:]
        let points = rawPoints.map { raw -> PerfPoint in
            let provider = ModelProvider.name(for: raw.model)
            let model = ModelName.display(raw.model)
            if providerByModel[model] == nil { providerByModel[model] = provider }
            return PerfPoint(day: raw.day, tool: raw.tool, model: model,
                             ttftMs: raw.ttftMs, tokensPerSecond: raw.tokensPerSecond)
        }
        var callsByProvider: [String: Int] = [:]
        for p in points {
            let provider = providerByModel[p.model] ?? ModelProvider.other
            callsByProvider[provider, default: 0] += 1
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
        let colors = TMDesign.modelColors(for: ranked)

        let providers = callsByProvider.sorted { a, b in
            if (a.key == ModelProvider.other) != (b.key == ModelProvider.other) { return b.key == ModelProvider.other }
            return a.value == b.value ? a.key < b.key : a.value > b.value
        }.map(\.key)

        func series(_ byDay: [Int64: [String: [Double]]]) -> [ChartPoint] {
            byDay.keys.sorted().flatMap { day -> [ChartPoint] in
                guard let date = date(fromDayKey: day), let models = byDay[day] else { return [] }
                return models.compactMap { model, values in
                    PerfStats.median(values).map { ChartPoint(day: day, date: date, model: model, value: $0) }
                }
            }
        }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let first = calendar.date(byAdding: .day, value: -(range.days - 1), to: today) ?? today
        let end = calendar.date(byAdding: .day, value: 1, to: today) ?? today

        return PerfData(
            range: range,
            rows: ranked.map { model in
                ModelRow(model: model, provider: providerByModel[model] ?? ModelProvider.other,
                         color: colors[model] ?? TMDesign.accent,
                         tokensPerSecond: PerfStats.median(speedByModel[model] ?? []),
                         ttftMs: PerfStats.median(ttftByModel[model] ?? []),
                         ttftP90Ms: PerfStats.percentile(ttftByModel[model] ?? [], p: 0.90),
                         calls: callsByModel[model] ?? 0)
            },
            speedPoints: series(speedByDay),
            ttftPoints: series(ttftByDay),
            providers: providers,
            calls: points.count,
            xDomain: first...end)
    }

    nonisolated static func date(fromDayKey key: Int64) -> Date? {
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

    private func chart(_ data: PerfData, state: ChartRenderState) -> some View {
        let step = data.range.days <= 7 ? 1 : (data.range.days <= 30 ? 5 : 14)
        let metricName = metric.rawValue
        let highlight = activeHighlightModel
        return Group {
            if state.shownRows.isEmpty {
                Text("No providers selected")
                    .font(TMType.regular(TMType.body))
                    .foregroundStyle(TMDesign.quiet)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if state.points.isEmpty {
                Text(metric == .speed ? "No speed measured in this range"
                                      : "No first-token time measured in this range")
                    .font(TMType.regular(TMType.body))
                    .foregroundStyle(TMDesign.quiet)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Chart {
                    ForEach(state.points) { p in
                        let dimmed = highlight != nil && highlight != p.model
                        let emphasized = highlight == p.model
                        LineMark(x: .value("Day", p.date, unit: .day),
                                 y: .value(metricName, p.value))
                            .foregroundStyle(by: .value("Model", p.model))
                            .lineStyle(StrokeStyle(lineWidth: emphasized ? 2.5 : 1.75))
                            .opacity(dimmed ? 0.18 : 1)
                            .interpolationMethod(.linear)
                        PointMark(x: .value("Day", p.date, unit: .day),
                                  y: .value(metricName, p.value))
                            .foregroundStyle(by: .value("Model", p.model))
                            .symbolSize(hoveredDay == p.day ? (emphasized ? 56 : 40) : (emphasized ? 28 : 16))
                            .opacity(dimmed ? 0.18 : 1)
                    }
                    if let day = hoveredDay, let date = Self.date(fromDayKey: day) {
                        RuleMark(x: .value("Day", date, unit: .day))
                            .foregroundStyle(Color.primary.opacity(0.16))
                    }
                }
                .chartForegroundStyleScale(domain: state.models, range: state.colors)
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
                        ZStack(alignment: .topLeading) {
                            Color.clear
                                .contentShape(Rectangle())
                                .onContinuousHover { phase in
                                    switch phase {
                                    case .active(let location):
                                        guard plot.contains(location),
                                              let date = proxy.value(atX: location.x - plot.origin.x, as: Date.self)
                                        else {
                                            hoveredDay = nil
                                            return
                                        }
                                        let key = Self.dayKey(for: date)
                                        let next = state.byDay[key] != nil ? key : nil
                                        if hoveredDay != next { hoveredDay = next }
                                    case .ended:
                                        hoveredDay = nil
                                    }
                                }
                            if let day = hoveredDay, let dayPoints = state.byDay[day],
                               let date = Self.date(fromDayKey: day),
                               let xInPlot = proxy.position(forX: date) {
                                let centerX = plot.origin.x + xInPlot
                                let calloutWidth: CGFloat = 230
                                let gap: CGFloat = 12
                                let onRight = centerX + gap + calloutWidth <= geo.size.width
                                let xPos = onRight
                                    ? min(centerX + gap, max(0, geo.size.width - calloutWidth))
                                    : max(0, centerX - gap - calloutWidth)
                                callout(day: day, points: dayPoints, colors: state.colorsByModel)
                                    .frame(width: calloutWidth)
                                    .offset(x: xPos, y: plot.origin.y + 4)
                                    .allowsHitTesting(false)
                            }
                        }
                    }
                }
                .frame(minHeight: 140, maxHeight: .infinity)
                .accessibilityLabel(metric == .speed ? "Output speed per day by model"
                                                     : "Time to first token per day by model")
            }
        }
    }

    static func tickDates(in domain: ClosedRange<Date>, every step: Int) -> [Date] {
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: domain.lowerBound, to: domain.upperBound).day ?? 0
        return stride(from: 0, to: days, by: step).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: domain.lowerBound)
                .flatMap { calendar.date(byAdding: .hour, value: 12, to: $0) }
        }
    }

    static func dayKey(for date: Date) -> Int64 {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return Int64((c.year ?? 0) * 10_000 + (c.month ?? 0) * 100 + (c.day ?? 0))
    }

    private func callout(day: Int64, points: [ChartPoint], colors: [String: Color]) -> some View {
        // Faster is better for speed, sooner is better for first token.
        let sorted = points.sorted { metric == .speed ? $0.value > $1.value : $0.value < $1.value }
        let limit = 6
        let visible = Array(sorted.prefix(limit))
        let remaining = sorted.count - visible.count
        return VStack(alignment: .leading, spacing: 6) {
            Text(Format.shortDayKey(day))
                .font(TMType.medium(TMType.caption))
                .foregroundStyle(TMDesign.quiet)
            ForEach(visible) { p in
                HStack(spacing: 6) {
                    Circle().fill(colors[p.model] ?? TMDesign.accent).frame(width: 7, height: 7)
                    Text(p.model)
                        .font(TMType.regular(TMType.caption))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(valueText(p.value))
                        .font(TMType.regular(TMType.caption))
                        .tmMonospacedDigit()
                        .foregroundStyle(TMDesign.quiet)
                }
            }
            if remaining > 0 {
                Text("+\(remaining) more")
                    .font(TMType.regular(TMType.caption))
                    .foregroundStyle(TMDesign.quiet)
            }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
    }

    // MARK: - Providers & Legend

    private var hiddenProviders: Set<String> {
        Set(hiddenProvidersRaw.split(separator: "\n").map(String.init))
    }

    private func setHiddenProviders(_ hidden: Set<String>) {
        hiddenProvidersRaw = hidden.sorted().joined(separator: "\n")
        hoveredDay = nil
    }

    private func toggleProvider(_ provider: String, allProviders: [String]) {
        let optionDown = NSEvent.modifierFlags.contains(.option)
        var hidden = hiddenProviders
        if optionDown {
            let others = Set(allProviders.filter { $0 != provider })
            if hidden == others {
                hidden.removeAll()
            } else {
                hidden = others
            }
        } else {
            if hidden.contains(provider) { hidden.remove(provider) } else { hidden.insert(provider) }
        }
        setHiddenProviders(hidden)
    }

    private func providerPills(_ data: PerfData) -> some View {
        let row = providerPillsRow(data)
        return ViewThatFits(in: .horizontal) {
            row
            ScrollView(.horizontal, showsIndicators: false) {
                row
            }
            .layoutPriority(-1)
        }
    }

    private func providerPillsRow(_ data: PerfData) -> some View {
        let hidden = hiddenProviders
        let hasHidden = data.providers.contains { hidden.contains($0) }
        return HStack(spacing: 6) {
            if hasHidden {
                Button {
                    setHiddenProviders([])
                } label: {
                    Text("All")
                        .font(TMType.medium(TMType.caption))
                        .foregroundStyle(TMDesign.accent)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(TMDesign.accent.opacity(0.10), in: Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .help("Show all providers")
            }
            ForEach(data.providers, id: \.self) { provider in
                let on = !hidden.contains(provider)
                Button {
                    toggleProvider(provider, allProviders: data.providers)
                } label: {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(on ? TMDesign.accent : TMDesign.quiet.opacity(0.45))
                            .frame(width: 5, height: 5)
                        Text(provider)
                            .font(TMType.medium(TMType.caption))
                            .foregroundStyle(on ? Color.primary : TMDesign.quiet.opacity(0.65))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        on ? Color.primary.opacity(0.07) : Color.primary.opacity(0.02),
                        in: Capsule(style: .continuous)
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(Color.primary.opacity(on ? 0.14 : 0.08), lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
                .help("Click to toggle · Option-click to isolate")
                .accessibilityValue(on ? "Shown" : "Hidden")
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func legend(_ rows: [ModelRow]) -> some View {
        let highlight = activeHighlightModel
        return FlowLayout(horizontalSpacing: 14, verticalSpacing: 6) {
            ForEach(rows, id: \.model) { row in
                let isSelected = pinnedModel == row.model
                let dimmed = highlight != nil && highlight != row.model
                Button {
                    pinnedModel = (pinnedModel == row.model) ? nil : row.model
                } label: {
                    HStack(spacing: 5) {
                        Circle().fill(row.color).frame(width: 8, height: 8)
                        Text(row.model)
                            .font(isSelected ? TMType.medium(TMType.caption) : TMType.regular(TMType.caption))
                            .foregroundStyle(isSelected ? Color.primary : TMDesign.quiet)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        isSelected ? Color.primary.opacity(0.07) : Color.clear,
                        in: Capsule(style: .continuous)
                    )
                    .opacity(dimmed ? 0.45 : 1)
                }
                .buttonStyle(.plain)
                .onHover { inside in
                    if inside {
                        hoveredModel = row.model
                    } else if hoveredModel == row.model {
                        hoveredModel = nil
                    }
                }
            }
        }
    }

    // MARK: - Table

    private static let headerHeight: CGFloat = 26
    private static let rowHeight: CGFloat = 36

    /// Rows in the chosen order. Models without a figure for the sorted
    /// column go last either way; ties keep the call ranking.
    static func sorted(_ rows: [ModelRow], by sort: TableSort?) -> [ModelRow] {
        guard let sort else { return rows }
        func value(_ r: ModelRow) -> Double? {
            switch sort.column {
            case .speed: return r.tokensPerSecond
            case .firstToken: return r.ttftMs
            case .ttftP90: return r.ttftP90Ms
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
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 0) {
                GridRow {
                    // Back to the default ranking.
                    Button { sort = nil } label: {
                        Text("Model").contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Reset to default ranking by calls")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text("Provider")
                        .frame(minWidth: 70, alignment: .leading)
                    sortHeader("Speed", .speed).gridColumnAlignment(.trailing)
                    sortHeader("First Token", .firstToken).gridColumnAlignment(.trailing)
                    sortHeader("TTFT P90", .ttftP90).gridColumnAlignment(.trailing)
                    sortHeader("Calls", .calls).gridColumnAlignment(.trailing)
                }
                .font(TMType.medium(TMType.caption))
                .foregroundStyle(TMDesign.quiet)
                .frame(height: Self.headerHeight, alignment: .top)

                ForEach(Self.sorted(rows, by: sort), id: \.model) { r in
                    let isHighlighted = activeHighlightModel == r.model
                    Divider().gridCellUnsizedAxes(.horizontal)
                    GridRow {
                        HStack(spacing: 8) {
                            Circle().fill(r.color).frame(width: 8, height: 8)
                            Text(r.model)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Text(r.provider)
                            .font(TMType.regular(TMType.caption))
                            .foregroundStyle(TMDesign.quiet)
                            .lineLimit(1)
                        Text(Self.speedText(r.tokensPerSecond))
                            .font(TMType.medium(TMType.body))
                        Text(Self.ttftText(r.ttftMs))
                            .foregroundStyle(TMDesign.quiet)
                        Text(Self.ttftText(r.ttftP90Ms))
                            .foregroundStyle(TMDesign.quiet)
                        Text(Format.count(Int64(r.calls)))
                            .foregroundStyle(TMDesign.quiet)
                    }
                    .font(TMType.regular(TMType.body))
                    .tmMonospacedDigit()
                    .frame(height: Self.rowHeight - 1)
                    .contentShape(Rectangle())
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(isHighlighted ? Color.primary.opacity(0.05) : Color.clear)
                            .padding(.horizontal, -6)
                    )
                    .onTapGesture {
                        pinnedModel = (pinnedModel == r.model) ? nil : r.model
                    }
                    .onHover { inside in
                        if inside {
                            hoveredModel = r.model
                        } else if hoveredModel == r.model {
                            hoveredModel = nil
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(r.model)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAddTraits(pinnedModel == r.model ? .isSelected : [])
                }
            }
            // The scroller runs in the card's margin, clear of the figures.
            .padding(.trailing, DashLayout.cardPadding)
            .overlayScrollers()
        }
        .padding(.trailing, -DashLayout.cardPadding)
        .frame(height: Self.headerHeight + CGFloat(min(rows.count, 5)) * Self.rowHeight)
    }

    // MARK: - Export

    private func exportCSV() {
        guard let data else { return }
        let rows = Self.sorted(renderState.shownRows, by: sort)
        guard !rows.isEmpty else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "ToastMonitor-Performance-\(data.range.rawValue.replacingOccurrences(of: " ", with: "-")).csv"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var lines = ["range,model,provider,calls,speed_median_tok_s,ttft_median_ms,ttft_p90_ms"]
        for row in rows {
            let speed = row.tokensPerSecond.map { String(format: "%.2f", $0) } ?? ""
            let ttft = row.ttftMs.map { String(format: "%.1f", $0) } ?? ""
            let p90 = row.ttftP90Ms.map { String(format: "%.1f", $0) } ?? ""
            lines.append([
                UsageAnalysisView.csvField(data.range.rawValue),
                UsageAnalysisView.csvField(row.model),
                UsageAnalysisView.csvField(row.provider),
                "\(row.calls)",
                speed,
                ttft,
                p90,
            ].joined(separator: ","))
        }
        do {
            try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        } catch {
            exportError = error.localizedDescription
        }
    }
}
