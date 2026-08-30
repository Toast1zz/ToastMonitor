import AppKit
import SwiftUI

/// 用量分析 (spec §3.2): 集中控制条（日期范围 / 按工具·按模型 / 图型）+
/// token 堆叠图 + 成本图（按天聚合，禁止跨工具连线）+ 聚合表。
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
    @State private var hoveredDayIdx: Int?
    @State private var hoveredCostIdx: Int?
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

    private struct DaySegments {
        let date: Int64
        let segments: [(name: String, value: Int64, color: Color)]
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
        let segments: [DaySegments]
        let costByDay: [Int64: Double]
        let aggregates: [AggregateRow]
        let dayCount: Int
        let totalTokens: Int64
        let totalCost: Double
        let totalCalls: Int64
        /// 纯派生图表输入，build 时一并算出，hover/渲染时不再重算：
        /// token 图日峰值与月份刻度、成本图的天键序列/峰值/月份刻度。
        let maxDayTokens: Int64
        let tokenTicks: [(index: Int, label: String)]
        let costDays: [Int64]
        let maxDayCost: Double
        let costTicks: [(index: Int, label: String)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            pageHeader
            hairline
            if analysis == nil {
                Spacer()
                Text("No data in this range")
                    .font(TMType.regular(TMType.body))
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        summaryStrip
                        TMPanel {
                            if metric == .tokens {
                                tokensChart
                            } else {
                                costChart
                            }
                        }
                        TMPanel {
                            aggTable
                        }
                    }
                    .padding(.top, 14)
                    .padding(.bottom, 32)
                }
            }
        }
        .padding(.horizontal, 24)
        .onAppear { load() }
        .onChange(of: range) { _ in load() }
        .onChange(of: grouping) { _ in load() }
    }

    private var pageHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            SectionTitle("Analysis")
            Spacer(minLength: 8)
            controls
            Divider()
                .frame(height: 18)
            Button(action: exportCSV) {
                Image(systemName: "square.and.arrow.up")
            }
            .buttonStyle(.borderless)
            .disabled(analysis == nil)
            .help("Export current analysis as CSV")
            .accessibilityLabel("Export current analysis as CSV")
        }
        .padding(.top, 18)
        .padding(.bottom, 12)
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
        try? (lines.joined(separator: "\n") + "\n")
            .write(to: url, atomically: true, encoding: .utf8)
    }

    private static func csvField(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else { return value }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    /// 设计系统 hairline（TMDesign.divider, primary 0.13），页头与表内统一。
    private var hairline: some View {
        Rectangle().fill(TMDesign.divider).frame(height: 1)
    }

    private var summaryStrip: some View {
        let d = analysis
        let days = d?.dayCount ?? 0
        let total = d?.totalTokens ?? 0
        let cost = d?.totalCost ?? 0
        let calls = d?.totalCalls ?? 0
        let daily = days > 0 ? total / Int64(days) : 0
        return HStack(spacing: 0) {
            TMMiniMetric(label: "Tokens", value: Format.compact(total), font: TMType.semibold(16), spacing: 3, minimumScaleFactor: 0.75)
            Divider().frame(height: 34)
            TMMiniMetric(label: "Estimated Cost", value: Format.moneyShort(cost), font: TMType.semibold(16), spacing: 3, minimumScaleFactor: 0.75)
            Divider().frame(height: 34)
            TMMiniMetric(label: "Daily Avg Tokens", value: Format.compact(daily), font: TMType.semibold(16), spacing: 3, minimumScaleFactor: 0.75)
            Divider().frame(height: 34)
            TMMiniMetric(label: "Calls", value: Format.count(calls), font: TMType.semibold(16), spacing: 3, minimumScaleFactor: 0.75)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        // 与 Overview hero 部分重叠的指标：保留（这里是所选区间口径），
        // 面板降为中性 surface，不再抢 hero 的 accent 视觉。
        .tmPanelSurface(padding: 0)
    }

    private func load() {
        let requestID = UUID()
        loadID = requestID
        let grouping = self.grouping
        let range = self.range
        if grouping == .byTool {
            UsageQueryService.shared.loadDailyAggs(days: range.days) { aggs in
                guard loadID == requestID else { return }
                self.analysis = Self.build(aggs: aggs, modelAggs: [],
                                           grouping: grouping, range: range,
                                           modelColors: self.modelColors)
                self.hoveredDayIdx = nil
                self.hoveredCostIdx = nil
            }
        } else {
            UsageQueryService.shared.loadDailyAggsByModel(days: range.days) { aggs in
                guard loadID == requestID else { return }
                let colors = Self.assignModelColors(aggs)
                self.modelColors = colors
                self.analysis = Self.build(aggs: [], modelAggs: aggs,
                                           grouping: grouping, range: range,
                                           modelColors: colors)
                self.hoveredDayIdx = nil
                self.hoveredCostIdx = nil
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

    /// 单遍聚合：day × name token 和（替代原来的 O(days × names) filter）、
    /// 按名称聚合、按天成本，一次算出图表与表格的全部输入。
    private static func build(aggs: [Database.DayAgg],
                              modelAggs: [(day: Int64, model: String, input: Int64, output: Int64, cacheRead: Int64, cost: Double, count: Int64)],
                              grouping: Grouping,
                              range: Range,
                              modelColors: [String: Color]) -> AnalysisData {
        let rows: [Row] = grouping == .byTool
            ? aggs.map { Row(day: $0.day, key: $0.tool, input: $0.input, output: $0.output, cacheRead: $0.cacheRead, cost: $0.cost, count: $0.count) }
            : modelAggs.map { Row(day: $0.day, key: $0.model, input: $0.input, output: $0.output, cacheRead: $0.cacheRead, cost: $0.cost, count: $0.count) }

        var dayTokens: [Int64: [String: Int64]] = [:]
        var costByDay: [Int64: Double] = [:]
        var tokensByName: [String: Int64] = [:]
        var callsByName: [String: Int64] = [:]
        var costByName: [String: Double] = [:]
        for r in rows {
            let v = tokenValue(r, grouping: grouping)
            var perDay = dayTokens[r.day, default: [:]]
            perDay[r.key, default: 0] += v
            dayTokens[r.day] = perDay
            tokensByName[r.key, default: 0] += v
            callsByName[r.key, default: 0] += max(r.count, 0)
            costByName[r.key, default: 0] += max(r.cost, 0)
            if r.cost > 0 { costByDay[r.day, default: 0] += r.cost }
        }

        let orderedNames = tokensByName.sorted { $0.value > $1.value }.map(\.key)
        let dayOrder = Set(rows.map(\.day)).sorted()
        let totalTokens = tokensByName.values.reduce(0, +)

        let segments: [DaySegments] = dayOrder.map { d in
            let perName = dayTokens[d] ?? [:]
            var segs: [(name: String, value: Int64, color: Color)] = []
            for name in orderedNames {
                let v = perName[name] ?? 0
                if v > 0 {
                    segs.append((name, v, color(for: name, grouping: grouping, modelColors: modelColors)))
                }
            }
            return DaySegments(date: d, segments: segs)
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

        // 图表纯派生输入（与 tokensChart/costChart 原 body 内公式一致）。
        let maxDayTokens = segments.map { day in
            day.segments.reduce(Int64(0)) { $0 + $1.value }
        }.max() ?? 1
        let tokenTicks = MonthAxis.ticks(days: dayOrder)
        let costDays = costByDay.keys.sorted()
        let maxDayCost = max(costDays.map { costByDay[$0] ?? 0 }.max() ?? 0, 0.001)
        let costTicks = MonthAxis.ticks(days: costDays)

        return AnalysisData(grouping: grouping,
                            range: range,
                            segments: segments,
                            costByDay: costByDay,
                            aggregates: aggregates,
                            dayCount: dayOrder.count,
                            totalTokens: totalTokens,
                            totalCost: costByName.values.reduce(0, +),
                            totalCalls: callsByName.values.reduce(0, +),
                            maxDayTokens: maxDayTokens,
                            tokenTicks: tokenTicks,
                            costDays: costDays,
                            maxDayCost: maxDayCost,
                            costTicks: costTicks)
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

    private var controls: some View {
        HStack(spacing: 12) {
            Picker("Metric", selection: $metric) {
                ForEach(Metric.allCases) { metric in Text(metric.rawValue).tag(metric) }
            }
            .pickerStyle(.menu)
            .fixedSize()

            Picker("Range", selection: $range) {
                ForEach(Range.allCases) { r in Text(r.rawValue).tag(r) }
            }
            .pickerStyle(.menu)
            .fixedSize()

            Picker("Grouping", selection: $grouping) {
                ForEach(Grouping.allCases) { g in Text(g.rawValue).tag(g) }
            }
            .pickerStyle(.menu)
            .fixedSize()
        }
        .controlSize(.small)
    }

    // MARK: - Token 堆叠图（按天，按工具/模型分色叠加）

    private var tokensChart: some View {
        let days = analysis?.segments ?? []
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                SectionTitle("Tokens (\(displayGrouping.rawValue))")
                Spacer()
                if !days.isEmpty {
                    legend
                }
            }
            if days.isEmpty {
                Text("No data")
                    .font(TMType.regular(TMType.body))
                    .foregroundStyle(.secondary)
            } else {
                let maxV = analysis?.maxDayTokens ?? 1
                let axisH: CGFloat = 18
                if let idx = hoveredDayIdx, idx < days.count {
                    tokenHoverLine(days[idx])
                } else {
                    Color.clear.frame(height: 18)
                }
                GeometryReader { geo in
                    let yAxisW: CGFloat = 48
                    let width = max(geo.size.width - yAxisW, 10)
                    let barW = max(2, width / CGFloat(days.count) - 2)
                    ZStack(alignment: .topLeading) {
                        Canvas { ctx, size in
                            let chartH = size.height - axisH
                            for step in 0...3 {
                                let y = chartH * CGFloat(step) / 3
                                var grid = Path()
                                grid.move(to: CGPoint(x: yAxisW, y: y))
                                grid.addLine(to: CGPoint(x: size.width, y: y))
                                ctx.stroke(grid, with: .color(Color.primary.opacity(step == 0 ? 0.10 : 0.055)), lineWidth: 1)
                                let v = Double(maxV) * Double(3 - step) / 3
                                let labelY = step == 0 ? CGFloat(1) : (step == 3 ? y - 1 : y)
                                let anchor: UnitPoint = step == 0 ? .topLeading : (step == 3 ? .bottomLeading : .leading)
                                ctx.draw(Text(Format.compact(Int64(v))).font(TMType.regular(TMType.micro).monospacedDigit()).foregroundColor(.secondary),
                                         at: CGPoint(x: 2, y: labelY), anchor: anchor)
                            }
                            for (di, day) in days.enumerated() {
                                var y = chartH
                                for seg in day.segments {
                                    let h = max(0.5, chartH * CGFloat(seg.value) / CGFloat(maxV))
                                    let rect = CGRect(x: yAxisW + CGFloat(di) * (barW + 2), y: y - h, width: barW, height: h)
                                    ctx.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(seg.color.opacity(0.85)))
                                    y -= h
                                }
                            }
                            for (idx, label) in analysis?.tokenTicks ?? [] {
                                let x = yAxisW + CGFloat(idx) * (barW + 2) + barW / 2
                                ctx.draw(Text(label).font(TMType.regular(TMType.micro).monospacedDigit()).foregroundColor(.secondary),
                                         at: CGPoint(x: x, y: chartH + 7))
                            }
                        }
                        // 悬停热区与柱体同一坐标系：柱体从 x = yAxisW 开始，
                        // 热区同样左移 yAxisW，宽度与柱体一一对应。
                        HStack(spacing: 2) {
                            ForEach(days.indices, id: \.self) { di in
                                let day = days[di]
                                let total = day.segments.reduce(Int64(0)) { $0 + $1.value }
                                Button {
                                    hoveredDayIdx = di
                                } label: {
                                    Color.clear
                                        .frame(width: barW)
                                        .frame(maxHeight: .infinity)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(Text(Format.dayKeyString(day.date)))
                                .accessibilityValue(Text(tokenAccessibilityValue(day, total: total)))
                                .accessibilityHint("Press Space to view this day's usage by source")
                                .onHover { hovering in
                                    if hovering { hoveredDayIdx = di }
                                    else if hoveredDayIdx == di { hoveredDayIdx = nil }
                                }
                            }
                        }
                        .frame(width: width, alignment: .leading)
                        .padding(.leading, yAxisW)
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Tokens chart")
                    .accessibilityValue(Text(tokenChartAccessibilitySummary(days)))
                    .accessibilityHint("Use Tab or VoiceOver to browse daily data")
                }
                .frame(height: 180)
            }
        }
    }

    private func tokenHoverLine(_ day: DaySegments) -> some View {
        let total = day.segments.reduce(Int64(0)) { $0 + $1.value }
        let parts = day.segments.map { "\($0.name) \(Format.compact($0.value))" }
        return Text("\(Format.shortDayKey(day.date)) · \(Format.compact(total)) tokens"
                    + (parts.isEmpty ? "" : " · " + parts.joined(separator: " · ")))
            .font(TMType.monoRegular(TMType.caption))
            .tmMonospacedDigit()
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 18)
    }
    private func tokenAccessibilityValue(_ day: DaySegments, total: Int64) -> String {
        let parts = day.segments.map { "\($0.name) \(Format.full($0.value)) tokens" }
        return "\(Format.full(total)) tokens" + (parts.isEmpty ? "" : ", " + parts.joined(separator: ", "))
    }

    private func tokenChartAccessibilitySummary(_ days: [DaySegments]) -> String {
        let total = days.reduce(Int64(0)) { partial, day in
            partial + day.segments.reduce(Int64(0)) { $0 + $1.value }
        }
        return "\(days.count) days, \(Format.full(total)) tokens total"
    }

    // MARK: - 成本图（按天单 series，不允许跨工具连线）

    private var costChart: some View {
        let days = analysis?.costByDay ?? [:]
        return VStack(alignment: .leading, spacing: 6) {
            SectionTitle("Estimated Cost (Per Day)")
            if days.values.allSatisfy({ $0 <= 0 }) {
                Text("No estimated cost data in this range")
                    .font(TMType.regular(TMType.body))
                    .foregroundStyle(.secondary)
            } else {
                let keys = analysis?.costDays ?? []
                let maxV = analysis?.maxDayCost ?? 0.001
                let axisH: CGFloat = 18
                if let idx = hoveredCostIdx, idx < keys.count {
                    let k = keys[idx]
                    Text("\(Format.shortDayKey(k)) · \(Format.money(days[k] ?? 0))")
                        .font(TMType.monoRegular(TMType.caption))
                        .tmMonospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: 18)
                } else {
                    Color.clear.frame(height: 18)
                }
                GeometryReader { geo in
                    let yAxisW: CGFloat = 48
                    let width = max(geo.size.width - yAxisW, 10)
                    Canvas { ctx, size in
                        let chartH = size.height - axisH
                        for step in 0...3 {
                            let y = chartH * CGFloat(step) / 3
                            var grid = Path()
                            grid.move(to: CGPoint(x: yAxisW, y: y))
                            grid.addLine(to: CGPoint(x: size.width, y: y))
                            ctx.stroke(grid, with: .color(Color.primary.opacity(step == 0 ? 0.10 : 0.055)), lineWidth: 1)
                            let v = maxV * Double(3 - step) / 3
                            let labelY = step == 0 ? CGFloat(1) : (step == 3 ? y - 1 : y)
                            let anchor: UnitPoint = step == 0 ? .topLeading : (step == 3 ? .bottomLeading : .leading)
                            ctx.draw(Text(Format.moneyShort(v)).font(TMType.regular(TMType.micro).monospacedDigit()).foregroundColor(.secondary),
                                     at: CGPoint(x: 2, y: labelY), anchor: anchor)
                        }
                        if keys.count == 1 {
                            // 单天数据：画圆点而不是空白。
                            let k = keys[0]
                            let x = yAxisW + (size.width - yAxisW) / 2
                            let y = max(6, chartH - chartH * CGFloat(days[k] ?? 0) / CGFloat(maxV))
                            ctx.fill(Path(ellipseIn: CGRect(x: x - 3.5, y: y - 3.5, width: 7, height: 7)),
                                     with: .color(TMDesign.accent))
                        } else {
                            var path = Path()
                            for (i, k) in keys.enumerated() {
                                let x = yAxisW + CGFloat(i) / CGFloat(keys.count - 1) * (size.width - yAxisW)
                                let y = chartH - chartH * CGFloat(days[k] ?? 0) / CGFloat(maxV)
                                if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                                else { path.addLine(to: CGPoint(x: x, y: y)) }
                            }
                            ctx.stroke(path, with: .color(TMDesign.accent), lineWidth: 1.8)
                            var area = path
                            area.addLine(to: CGPoint(x: size.width, y: chartH))
                            area.addLine(to: CGPoint(x: yAxisW, y: chartH))
                            area.closeSubpath()
                            ctx.fill(area, with: .color(TMDesign.accent.opacity(0.12)))
                        }
                        for (idx, label) in analysis?.costTicks ?? [] {
                            let x = keys.count > 1
                                ? yAxisW + CGFloat(idx) / CGFloat(keys.count - 1) * (size.width - yAxisW)
                                : yAxisW + (size.width - yAxisW) / 2
                            ctx.draw(Text(label).font(TMType.regular(TMType.micro).monospacedDigit()).foregroundColor(.secondary),
                                     at: CGPoint(x: x, y: chartH + 7))
                        }
                    }
                    // 悬停分区与数据点对齐：数据点在 (count-1) 段上排布，
                    // 热区按相邻点中点划分（每点一个居中分区），且不含 y 轴。
                    HStack(spacing: 0) {
                        ForEach(keys.indices, id: \.self) { i in
                            let day = keys[i]
                            Button {
                                hoveredCostIdx = i
                            } label: {
                                Color.clear
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text(Format.dayKeyString(day)))
                            .accessibilityValue(Text("\(Format.money(days[day] ?? 0))"))
                            .accessibilityHint("Press Space to view this day's estimated cost")
                            .onHover { hovering in
                                if hovering { hoveredCostIdx = i }
                                else if hoveredCostIdx == i { hoveredCostIdx = nil }
                            }
                            .frame(width: width * costZoneFraction(i, count: keys.count))
                        }
                    }
                    .frame(width: width, alignment: .leading)
                    .padding(.leading, yAxisW)
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Estimated cost chart")
                .accessibilityValue(Text(costChartAccessibilitySummary(keys, values: days)))
                .accessibilityHint("Use Tab or VoiceOver to browse daily data")
                .frame(height: 146)
            }
        }
    }

    /// Hover 分区宽度比例：边界取相邻数据点（(count-1) 段）的中点，
    /// 每个点一个以自身为中心的分区，完整覆盖图表宽度。
    private func costZoneFraction(_ i: Int, count: Int) -> CGFloat {
        guard count > 1 else { return 1 }
        if i == 0 || i == count - 1 { return 0.5 / CGFloat(count - 1) }
        return 1 / CGFloat(count - 1)
    }

    private func costChartAccessibilitySummary(_ keys: [Int64], values: [Int64: Double]) -> String {
        let total = keys.reduce(0.0) { $0 + (values[$1] ?? 0) }
        return "\(keys.count) days, \(Format.money(total)) total"
    }

    // MARK: - 聚合表

    private var aggTable: some View {
        let rows = analysis?.aggregates ?? []
        return VStack(alignment: .leading, spacing: 8) {
            SectionTitle("Details (\(analysis?.range.rawValue ?? range.rawValue))")
            if rows.isEmpty {
                Text("No data")
                    .font(TMType.regular(TMType.body))
                    .foregroundStyle(.secondary)
            } else {
                // Grid 自适应列宽：数值列按内容取宽，名称列吃掉剩余空间。
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 0) {
                    GridRow {
                        Text(displayGrouping == .byTool ? "Tool" : "Model")
                            .gridColumnAlignment(.leading)
                        Text("Cost")
                            .gridColumnAlignment(.trailing)
                        Text("Tokens")
                            .gridColumnAlignment(.trailing)
                        Text("Calls")
                            .gridColumnAlignment(.trailing)
                        Text("Share")
                            .gridColumnAlignment(.trailing)
                        Color.clear
                            .frame(width: 100, height: 1)
                            .gridColumnAlignment(.leading)
                    }
                    .font(TMType.medium(TMType.micro))
                    .foregroundStyle(TMDesign.quiet)
                    .padding(.bottom, 6)

                    ForEach(rows, id: \.name) { r in
                        Group {
                            GridRow {
                                HStack(spacing: 7) {
                                    Circle().fill(r.color).frame(width: 7, height: 7)
                                    Text(displayName(for: r.name))
                                        .font(TMType.medium(TMType.body))
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                Text(r.cost > 0 ? Format.moneyShort(r.cost) : "—")
                                    .font(TMType.regular(TMType.caption))
                                    .tmMonospacedDigit()
                                    .foregroundStyle(.secondary)
                                Text(Format.compact(r.tokens))
                                    .font(TMType.regular(TMType.caption))
                                    .tmMonospacedDigit()
                                Text(Format.count(r.calls))
                                    .font(TMType.regular(TMType.caption))
                                    .tmMonospacedDigit()
                                    .foregroundStyle(.secondary)
                                Text("\(Int(r.ratio * 100))%")
                                    .font(TMType.regular(TMType.caption))
                                    .tmMonospacedDigit()
                                    .foregroundStyle(.secondary)
                                TMProgressBar(value: r.ratio, tint: r.color, height: 5)
                                    .frame(width: 100)
                            }
                            .padding(.vertical, 7)

                            GridRow {
                                Rectangle()
                                    .fill(TMDesign.divider)
                                    .frame(height: 1)
                                    .gridCellColumns(6)
                                    .gridCellUnsizedAxes(.horizontal)
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: - 数据组装

    private var legend: some View {
        // Sorted by usage (aggregates are descending), top 6.
        let top = analysis?.aggregates.prefix(6) ?? []
        return HStack(spacing: 12) {
            ForEach(top, id: \.name) { r in
                HStack(spacing: 5) {
                    Circle().fill(r.color).frame(width: 7, height: 7)
                    Text(displayName(for: r.name))
                        .font(TMType.regular(TMType.caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }
}
