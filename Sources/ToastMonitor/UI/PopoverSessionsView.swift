import SwiftUI

/// Popover 会话页：最近会话（工具/模型、时间、tokens、成本）。
struct PopoverSessionsView: View {
    @ObservedObject private var app = AppState.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("最近会话")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .kerning(0.6)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 4)
                if app.sessions.isEmpty {
                    Text("暂无会话")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                } else {
                    ForEach(Array(app.sessions.prefix(15)), id: \.id) { s in
                        row(s)
                        Divider()
                    }
                    Text("完整列表见完整面板")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 16)
                        .padding(.top, 6)
                }
                Spacer(minLength: 8)
            }
        }
    }

    private func row(_ s: Database.SessionRow) -> some View {
        let kind = ToolKind(rawValue: s.tool)
        let createdText = s.created > 0 ? Format.dateTime(s.created) : "时间未知"
        return HStack(spacing: 8) {
            Image(systemName: kind?.symbol ?? "square.grid.2x2")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(kind?.color ?? .gray)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(s.title ?? s.sessionID)
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
                Text([s.model ?? "模型未知", createdText].joined(separator: " · "))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(Format.compact(ToolKind(rawValue: s.tool)?.totalTokens(input: s.input, output: s.output, cacheRead: s.cacheRead)
                                   ?? (s.input + s.output)))
                    .font(.system(size: 10.5, design: .monospaced))
                    .monospacedDigit()
                if s.cost > 0 {
                    Text(Format.money(s.cost))
                        .font(.system(size: 9.5, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
    }
}
