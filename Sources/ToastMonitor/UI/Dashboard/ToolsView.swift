import SwiftUI

/// 工具: per-tool cards with today / 7d / month totals.
struct ToolsView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
                ForEach(ToolKind.allCases.filter { $0 != .openrouter }) { kind in
                    toolCard(kind, (today: value(kind, app.byToolToday),
                                    week: value(kind, app.byToolWeek),
                                    month: value(kind, app.byToolMonth)))
                }
            }
            .padding(18)
        }
    }

    private func value(_ kind: ToolKind, _ rows: [Database.ToolTotals]) -> Database.ToolTotals {
        rows.first { $0.tool == kind.rawValue }
            ?? Database.ToolTotals(tool: kind.rawValue, input: 0, output: 0,
                                   cacheRead: 0, cacheWrite: 0, cost: 0, count: 0)
    }

    private func toolCard(_ kind: ToolKind, _ t: (today: Database.ToolTotals, week: Database.ToolTotals, month: Database.ToolTotals)) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: kind.symbol)
                    .font(.system(size: 14))
                    .foregroundStyle(kind.color)
                Text(kind.displayName)
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("\(t.month.count) 次/月")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            row("今日", t.today)
            row("近 7 天", t.week)
            row("本月", t.month)
            Divider().opacity(0.4)
            HStack {
                Text("缓存读取")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(Format.compact(t.month.cacheRead))
                    .font(.system(size: 11, design: .monospaced))
                    .monospacedDigit()
                Text("· 写入 \(Format.compact(t.month.cacheWrite))")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.04)))
    }

    private func row(_ label: String, _ t: Database.ToolTotals) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .leading)
            Text(Format.compact(ToolKind(rawValue: t.tool)?.totalTokens(t) ?? (t.input + t.output)))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .monospacedDigit()
            Text("tokens")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Spacer()
            Text(Format.moneyShort(t.cost))
                .font(.system(size: 11, design: .monospaced))
                .monospacedDigit()
        }
    }
}
