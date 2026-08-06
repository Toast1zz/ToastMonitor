import SwiftUI

/// Reusable session rows. The full-page session browser was folded into the
/// overview: the list lives on the home page, detail opens as a sheet.
struct SessionListRow: View {
    let session: Database.SessionRow

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle()
                    .fill(ToolKind(rawValue: session.tool)?.color ?? .gray)
                    .frame(width: 7, height: 7)
                Text(session.title ?? session.sessionID)
                    .font(.system(size: TMType.body, weight: .medium))
                    .lineLimit(1)
                Spacer()
                Text(session.cost > 0 ? Format.moneyShort(session.cost) : "—")
                    .font(.system(size: TMType.caption, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Text(session.project ?? "—")
                    .font(.system(size: TMType.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let model = session.model {
                    Text(model)
                        .font(.system(size: TMType.caption, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer()
                Text(session.updated > 0 ? Format.dateTime(session.updated) : "时间未知")
                    .font(.system(size: TMType.caption))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 3)
    }
}

struct SessionDetailView: View {
    let session: Database.SessionRow
    @State private var turns: [(ts: Int64, model: String?, input: Int64, output: Int64, cacheRead: Int64, cacheWrite: Int64, cost: Double)] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: ToolKind(rawValue: session.tool)?.symbol ?? "questionmark")
                        .foregroundStyle(ToolKind(rawValue: session.tool)?.color ?? .gray)
                    Text(session.title ?? session.sessionID)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    Spacer()
                    if session.cost > 0 {
                        Text(Format.money(session.cost))
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .monospacedDigit()
                    } else {
                        Text("成本 —")
                            .font(.system(size: TMType.caption))
                            .foregroundStyle(.tertiary)
                    }
                }
                HStack(spacing: 10) {
                    Text("项目: \(session.project ?? "—")")
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let model = session.model {
                        Text("模型: \(model)")
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Text("\(session.count) 次调用")
                    Spacer()
                    Text(session.created > 0 ? "开始 \(Format.dateTime(session.created))" : "开始时间未知")
                }
                .font(.system(size: TMType.caption))
                .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(TMDesign.surface)

            Divider()

            if turns.isEmpty {
                VStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("加载调用明细…")
                        .font(.system(size: TMType.caption))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        HStack(spacing: 10) {
                            Text("时间").frame(width: 110, alignment: .leading)
                            Text("模型").frame(maxWidth: .infinity, alignment: .leading)
                            Text("输入").frame(width: 70, alignment: .trailing)
                            Text("输出").frame(width: 70, alignment: .trailing)
                            Text("缓存").frame(width: 70, alignment: .trailing)
                            Text("成本").frame(width: 70, alignment: .trailing)
                        }
                        .font(.system(size: TMType.micro, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)

                        ForEach(turns, id: \.ts) { t in
                            HStack(spacing: 10) {
                                Text(Format.dateTime(t.ts)).frame(width: 110, alignment: .leading)
                                Text(t.model ?? "—")
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(Format.count(t.input)).frame(width: 70, alignment: .trailing)
                                Text(Format.count(t.output)).frame(width: 70, alignment: .trailing)
                                Text(t.cacheRead > 0 ? Format.count(t.cacheRead) : "—").frame(width: 70, alignment: .trailing)
                                Text(t.cost > 0 ? Format.moneyShort(t.cost) : "—").frame(width: 70, alignment: .trailing)
                            }
                            .font(.system(size: TMType.caption, design: .monospaced))
                            .monospacedDigit()
                            .padding(.horizontal, 12)
                            .padding(.vertical, 3)
                            Divider().padding(.leading, 12)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(minWidth: 620, minHeight: 380)
        .task(id: session.id) {
            turns = Database.shared.turns(sessionTool: session.tool, sessionID: session.sessionID)
        }
    }
}
