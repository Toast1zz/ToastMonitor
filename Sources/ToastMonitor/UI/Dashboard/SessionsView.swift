import SwiftUI

/// 会话: list + per-session turn detail.
struct SessionsView: View {
    @EnvironmentObject var app: AppState
    @State private var selected: Database.SessionRow?
    @State private var toolFilter: ToolKind?
    @State private var search = ""

    var body: some View {
        HStack(spacing: 0) {
            // List
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Picker("", selection: $toolFilter) {
                        Text("全部工具").tag(ToolKind?.none)
                        ForEach(ToolKind.allCases.filter { $0 != .openrouter }) { k in
                            Text(k.displayName).tag(ToolKind?.some(k))
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 130)
                    TextField("搜索", text: $search)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                }
                .padding(10)

                List(filtered, selection: $selected) { s in
                    SessionListRow(session: s)
                        .tag(s)
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
            .frame(minWidth: 300, idealWidth: 350, maxWidth: 390)

            Divider()

            // Detail
            if let selected {
                SessionDetailView(session: selected)
            } else {
                VStack {
                    Spacer()
                    Image(systemName: "sidebar.right")
                        .font(.system(size: 30))
                        .foregroundStyle(.tertiary)
                    Text("选择一个会话查看详情")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
        .background(TMDesign.canvas)
        .onReceive(NotificationCenter.default.publisher(for: CollectorEngine.didCollect)) { _ in
            app.refresh()
        }
    }

    private var filtered: [Database.SessionRow] {
        var list = app.sessions
        if let toolFilter { list = list.filter { $0.tool == toolFilter.rawValue } }
        if !search.isEmpty {
            let q = search.lowercased()
            list = list.filter {
                ($0.title?.lowercased().contains(q) ?? false) ||
                ($0.project?.lowercased().contains(q) ?? false) ||
                ($0.model?.lowercased().contains(q) ?? false) ||
                $0.sessionID.lowercased().contains(q)
            }
        }
        return list
    }
}

struct SessionListRow: View {
    let session: Database.SessionRow

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle()
                    .fill(ToolKind(rawValue: session.tool)?.color ?? .gray)
                    .frame(width: 7, height: 7)
                Text(session.title ?? session.sessionID)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Spacer()
                Text(Format.moneyShort(session.cost))
                    .font(.system(size: 10, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Text(session.project ?? "—")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let model = session.model {
                    Text(model)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer()
                Text(session.updated > 0 ? Format.dateTime(session.updated) : "时间未知")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
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
                            .font(.system(size: 11))
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
                    if session.created > 0 {
                        Text("\(Format.dateTime(session.created)) → \(Format.dateTime(session.updated))")
                    } else {
                        Text("时间未知")
                    }
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(TMDesign.surface)
            Divider()

            if turns.isEmpty {
                Spacer()
                Text("该会话暂无 token 明细（可能只有用户消息或已被清理）")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                List {
                    ForEach(Array(turns.enumerated()), id: \.offset) { _, t in
                        HStack(spacing: 10) {
                            Text(Format.dateTime(t.ts))
                                .font(.system(size: 10.5, design: .monospaced))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 88, alignment: .leading)
                            Text(t.model ?? "—")
                                .font(.system(size: 10.5, design: .monospaced))
                                .lineLimit(1)
                                .frame(width: 150, alignment: .leading)
                            Spacer()
                            Text("\(Format.compact(t.input)) in")
                            Text("\(Format.compact(t.output)) out")
                            Text("缓存 \(Format.compact(t.cacheRead))")
                                .foregroundStyle(.secondary)
                            Text(Format.moneyShort(t.cost))
                                .font(.system(size: 10.5, design: .monospaced))
                                .monospacedDigit()
                                .frame(width: 44, alignment: .trailing)
                        }
                        .font(.system(size: 11))
                    }
                }
                .listStyle(.inset)
            }
        }
        // .task(id:) — 切换会话必须按 session ID 重新加载，不得残留旧 turns
        .task(id: session.id) {
            UsageQueryService.shared.loadTurns(sessionTool: session.tool, sessionID: session.sessionID) { loaded in
                turns = loaded
            }
        }
    }
}
