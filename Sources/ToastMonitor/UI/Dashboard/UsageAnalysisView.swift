import SwiftUI

/// 用量分析 (spec §3.2): 集中控制条（日期范围 / 按工具·按模型 / 图型）+
/// token 堆叠图 + 成本图（按天聚合，禁止跨工具连线）+ 聚合表。
struct UsageAnalysisView: View {
    enum Range: String, CaseIterable, Identifiable {
        case d7 = "7 天"
        case d30 = "30 天"
        case d90 = "90 天"
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
        case byTool = "按工具"
        case byModel = "按模型"
        var id: String { rawValue }
    }

    @State private var range: Range = .d30
    @State private var grouping: Grouping = .byTool
    @State private var aggs: [Database.DayAgg] = []
    @State private var modelAggs: [(day: Int64, model: String, input: Int64, output: Int64, cacheRead: Int64, cost: Double)] = []
    @State private var loading = true
    @State private var loadID = UUID()

    /// 归一化行：(day, groupKey, input, output, cacheRead, cost)
    private var rows: [(day: Int64, key: String, input: Int64, output: Int64, cacheRead: Int64, cost: Double)] {
        if grouping == .byTool {
            return aggs.map { ($0.day, $0.tool, $0.input, $0.output, $0.cacheRead, $0.cost) }
        }
        return modelAggs.map { ($0.day, $0.model, $0.input, $0.output, $0.cacheRead, $0.cost) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TMPageHeader(
                title: "用量分析",
                subtitle: "按时间、工具或模型观察消耗趋势，并保留成本口径说明",
                eyebrow: "分析"
            )
            controls
                .padding(.bottom, 12)
            Divider()
            if loading {
                Spacer()
                ProgressView("加载中…")
                Spacer()
            } else if rows.isEmpty {
                Spacer()
                Text("该时间范围内暂无数据")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        TMPanel {
                            tokensChart
                        }
                        TMPanel {
                            costChart
                        }
                        TMPanel {
                            aggTable
                        }
                    }
                    .padding(.top, 4)
                    .padding(.bottom, 32)
                }
            }
        }
        .padding(.horizontal, 24)
        .onAppear { load() }
        .onChange(of: range) { load() }
        .onChange(of: grouping) { load() }
    }

    private func load() {
        loading = true
        let requestID = UUID()
        loadID = requestID
        if grouping == .byTool {
            UsageQueryService.shared.loadDailyAggs(days: range.days) { aggs in
                guard loadID == requestID else { return }
                self.aggs = aggs
                self.modelAggs = []
                self.loading = false
            }
        } else {
            UsageQueryService.shared.loadDailyAggsByModel(days: range.days) { aggs in
                guard loadID == requestID else { return }
                self.modelAggs = aggs
                self.aggs = []
                self.loading = false
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Picker("范围", selection: $range) {
                ForEach(Range.allCases) { r in Text(r.rawValue).tag(r) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 200)

            Picker("分组", selection: $grouping) {
                ForEach(Grouping.allCases) { g in Text(g.rawValue).tag(g) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 180)

            Spacer()
            Text("按天聚合 · \(range.rawValue)")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Token 堆叠图（按天，按工具/模型分色叠加）

    private var tokensChart: some View {
        let days = groupedDays()
        return VStack(alignment: .leading, spacing: 6) {
            Text("Tokens（\(grouping.rawValue)）")
                .font(.system(size: 13, weight: .semibold))
            if days.isEmpty {
                Text("暂无数据")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            } else {
                let maxV = days.flatMap { $0.segments.map(\.value) }.max() ?? 1
                GeometryReader { geo in
                    let width = geo.size.width
                    let barW = max(2, width / CGFloat(days.count) - 2)
                    Canvas { ctx, size in
                        for (di, day) in days.enumerated() {
                            var y = size.height
                            for seg in day.segments {
                                let h = max(0.5, size.height * CGFloat(seg.value) / CGFloat(maxV))
                                let rect = CGRect(x: CGFloat(di) * (barW + 2), y: y - h, width: barW, height: h)
                                ctx.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(seg.color.opacity(0.85)))
                                y -= h
                            }
                        }
                    }
                }
                .frame(height: 160)
                .overlay(alignment: .bottomLeading) {
                    Text("峰值 \(Format.compact(maxV)) / 天")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                        .padding(2)
                }
                legend
            }
        }
    }

    // MARK: - 成本图（按天单 series，不允许跨工具连线）

    private var costChart: some View {
        let days = costByDay()
        return VStack(alignment: .leading, spacing: 6) {
            Text("估算成本（按天聚合）")
                .font(.system(size: 13, weight: .semibold))
            if days.values.allSatisfy({ $0 <= 0 }) {
                Text("该范围内无估算成本数据")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            } else {
                let maxV = max(days.values.max() ?? 0, 0.001)
                GeometryReader { _ in
                    Canvas { ctx, size in
                        let keys = days.keys.sorted()
                        guard keys.count >= 2 else { return }
                        var path = Path()
                        for (i, k) in keys.enumerated() {
                            let x = CGFloat(i) / CGFloat(keys.count - 1) * size.width
                            let y = size.height - size.height * CGFloat(days[k] ?? 0) / CGFloat(maxV)
                            if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                            else { path.addLine(to: CGPoint(x: x, y: y)) }
                        }
                        ctx.stroke(path, with: .color(.orange), lineWidth: 1.6)
                        // 面积
                        var area = path
                        area.addLine(to: CGPoint(x: size.width, y: size.height))
                        area.addLine(to: CGPoint(x: 0, y: size.height))
                        area.closeSubpath()
                        ctx.fill(area, with: .color(.orange.opacity(0.12)))
                    }
                }
                .frame(height: 110)
                .overlay(alignment: .bottomTrailing) {
                    Text("最高 \(Format.money(maxV)) / 天")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                        .padding(2)
                }
            }
        }
    }

    // MARK: - 聚合表

    private var aggTable: some View {
        let rows = aggregateRows()
        return VStack(alignment: .leading, spacing: 6) {
            Text("聚合明细（\(range.rawValue)）")
                .font(.system(size: 13, weight: .semibold))
            if rows.isEmpty {
                Text("暂无数据")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(rows, id: \.name) { r in
                        HStack(spacing: 10) {
                            Circle().fill(r.color).frame(width: 7, height: 7)
                            Text(r.name)
                                .font(.system(size: 11.5, weight: .medium))
                                .frame(width: 150, alignment: .leading)
                                .lineLimit(1)
                            Text("\(Format.count(r.calls)) 次调用")
                                .font(.system(size: 10.5, design: .monospaced))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 80, alignment: .trailing)
                            Spacer()
                            Text(Format.compact(r.tokens))
                                .font(.system(size: 11, design: .monospaced))
                                .monospacedDigit()
                                .frame(width: 56, alignment: .trailing)
                            Text("\(Int(r.ratio * 100))%")
                                .font(.system(size: 10.5, design: .monospaced))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 40, alignment: .trailing)
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color.primary.opacity(0.06))
                                    Capsule().fill(r.color)
                                        .frame(width: max(2, geo.size.width * r.ratio))
                                }
                            }
                            .frame(width: 90)
                        }
                        .padding(.vertical, 5)
                        Divider()
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - 数据组装

    private struct DaySegments {
        let date: Int64
        let segments: [(name: String, value: Int64, color: Color)]
    }

    private func groupedDays() -> [DaySegments] {
        let groups = groupMap()
        let days = rows.map(\.day).sorted()
        return days.map { d in
            var segs: [(String, Int64, Color)] = []
            for (name, list) in groups {
                let v = list.filter { $0.day == d }.reduce(Int64(0)) {
                    if grouping == .byTool {
                        return $0 + (ToolKind(rawValue: $1.key)?.totalTokens(input: $1.input, output: $1.output, cacheRead: $1.cacheRead)
                                   ?? ($1.input + $1.output))
                    }
                    // by-model rows are keyed by model name (no tool);
                    // cacheRead counts toward the total like by-tool (the
                    // codex exception is not expressible at model granularity).
                    return $0 + $1.input + $1.output + $1.cacheRead
                }
                if v > 0 {
                    segs.append((name, v, color(for: name)))
                }
            }
            return DaySegments(date: d, segments: segs)
        }
    }

    private func costByDay() -> [Int64: Double] {
        var out: [Int64: Double] = [:]
        for a in rows where a.cost > 0 {
            out[a.day, default: 0] += a.cost
        }
        return out
    }

    private func aggregateRows() -> [(name: String, tokens: Int64, calls: Int64, cost: Double, ratio: Double, color: Color)] {
        let groups = groupMap()
        let total = groups.values.flatMap { $0 }.reduce(Int64(0)) {
            if grouping == .byTool {
                return $0 + (ToolKind(rawValue: $1.key)?.totalTokens(input: $1.input, output: $1.output, cacheRead: $1.cacheRead)
                           ?? ($1.input + $1.output))
            }
            // by-model: no tool info on model-keyed rows; include cacheRead.
            return $0 + $1.input + $1.output + $1.cacheRead
        }
        var out: [(name: String, tokens: Int64, calls: Int64, cost: Double, ratio: Double, color: Color)] = []
        for (name, list) in groups {
            let tokens = list.reduce(Int64(0)) {
                if grouping == .byTool {
                    return $0 + (ToolKind(rawValue: $1.key)?.totalTokens(input: $1.input, output: $1.output, cacheRead: $1.cacheRead)
                               ?? ($1.input + $1.output))
                }
                // by-model: no tool info on model-keyed rows; include cacheRead.
                return $0 + $1.input + $1.output + $1.cacheRead
            }
            if tokens == 0 { continue }
            let calls = list.count
            let cost = list.reduce(0.0) { $0 + $1.cost }
            out.append((name, tokens, Int64(calls), cost, total > 0 ? Double(tokens) / Double(total) : 0, color(for: name)))
        }
        return out.sorted { $0.tokens > $1.tokens }
    }

    private func groupMap() -> [String: [(day: Int64, key: String, input: Int64, output: Int64, cacheRead: Int64, cost: Double)]] {
        var groups: [String: [(Int64, String, Int64, Int64, Int64, Double)]] = [:]
        for a in rows {
            groups[a.key, default: []].append(a)
        }
        return groups
    }

    private func color(for name: String) -> Color {
        if grouping == .byTool {
            return ToolKind(rawValue: name)?.color ?? .gray
        }
        // 模型色：按名称散列取固定色板
        let palette: [Color] = [.orange, .blue, .green, .purple, .pink, .teal, .indigo, .brown]
        let h = name.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return palette[h % palette.count]
    }

    private var legend: some View {
        let names = Set(groupMap().keys)
        return HStack(spacing: 12) {
            ForEach(Array(names).sorted(), id: \.self) { n in
                HStack(spacing: 4) {
                    Circle().fill(color(for: n)).frame(width: 6, height: 6)
                    Text(n)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
