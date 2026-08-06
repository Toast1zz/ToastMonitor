import SwiftUI

/// Popover 工具页：本周期工具排行，行结构 = 名称/来源/tokens/占比/金额。
struct PopoverToolsView: View {
    @ObservedObject private var app = AppState.shared
    @ObservedObject private var health = SourceHealthHub.shared
    @State private var period: PopoverHomeView.Period = .today

    private var byTool: [Database.ToolTotals] {
        switch period {
        case .today: app.byToolToday
        case .week: app.byToolWeek
        case .month: app.byToolMonth
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Picker("周期", selection: $period) {
                    ForEach(PopoverHomeView.Period.allCases) { p in
                        Text(p.rawValue).tag(p)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 12)

                let rows = byTool.sorted { (ToolKind(rawValue: $0.tool)?.totalTokens($0) ?? ($0.input + $0.output)) > (ToolKind(rawValue: $1.tool)?.totalTokens($1) ?? ($1.input + $1.output)) }
                let total = rows.reduce(Int64(0)) { $0 + (ToolKind(rawValue: $1.tool)?.totalTokens($1) ?? ($1.input + $1.output)) }
                let multi = rows.count > 1
                if rows.isEmpty {
                    Text("本周期暂无数据")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                } else {
                    ForEach(rows, id: \.tool) { t in
                        row(t, total: total, multi: multi)
                        if t.tool != rows.last?.tool { Divider() }
                    }
                }
                Spacer(minLength: 8)
            }
        }
    }

    private func row(_ t: Database.ToolTotals, total: Int64, multi: Bool) -> some View {
        let kind = ToolKind(rawValue: t.tool)
        let value = kind?.totalTokens(t) ?? (t.input + t.output)
        let ratio = total > 0 ? Double(value) / Double(total) : 0
        let h = health.sources.first { $0.tool == t.tool }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: kind?.symbol ?? "square.grid.2x2")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(kind?.color ?? .gray)
                    .frame(width: 16)
                Text(kind?.displayName ?? t.tool)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 74, alignment: .leading)
                if let h {
                    Text(h.mode == "remote" ? "远程" : "本机")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if t.cost > 0 {
                    Text(Format.money(t.cost))
                        .font(.system(size: 10, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Text(Format.compact(value))
                    .font(.system(size: 11, design: .monospaced))
                    .monospacedDigit()
                    .frame(width: 52, alignment: .trailing)
                Text("\(Int(ratio * 100))%")
                    .font(.system(size: 10, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
            }
            if multi {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.06))
                        Capsule().fill(kind?.color ?? .gray)
                            .frame(width: max(3, geo.size.width * ratio))
                    }
                }
                .frame(height: 4)
                .padding(.leading, 24)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }
}
