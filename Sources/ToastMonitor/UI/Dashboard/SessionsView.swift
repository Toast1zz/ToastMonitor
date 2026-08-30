import SwiftUI

struct SessionsView: View {
    @State private var rows: [Database.SessionRow] = []
    @State private var selectedTool = "all"
    @State private var selectedSession: Database.SessionRow?
    @State private var loading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                SectionTitle("Sessions")
                Spacer()
                Picker("Tool", selection: $selectedTool) {
                    Text("All Tools").tag("all")
                    ForEach(ToolKind.allCases.filter { $0 != .openrouter }) { tool in
                        Text(tool.displayName).tag(tool.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                Button(action: load) { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .disabled(loading)
                    .help("Refresh sessions")
            }
            .padding(.top, 18)
            .padding(.bottom, 12)
            Rectangle().fill(TMDesign.divider).frame(height: 1)

            if rows.isEmpty, !loading {
                Spacer()
                Text("No sessions found")
                    .foregroundStyle(TMDesign.quiet)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { row in
                            Button { selectedSession = row } label: { sessionRow(row) }
                                .buttonStyle(.plain)
                            Divider().opacity(0.45)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .padding(.horizontal, 24)
        .onAppear(perform: load)
        .onChange(of: selectedTool) { _ in load() }
        .sheet(item: $selectedSession) { SessionDetailView(session: $0) }
    }

    private func sessionRow(_ row: Database.SessionRow) -> some View {
        HStack(spacing: 12) {
            Image(systemName: ToolKind(rawValue: row.tool)?.symbol ?? "terminal")
                .foregroundStyle(ToolKind(rawValue: row.tool)?.color ?? TMDesign.accent)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.title?.isEmpty == false ? row.title! : row.sessionID)
                    .font(TMType.medium(TMType.body))
                    .lineLimit(1)
                Text([row.project, row.model].compactMap { $0 }.joined(separator: " · "))
                    .font(TMType.regular(TMType.micro))
                    .foregroundStyle(TMDesign.quiet)
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(Format.compact(sessionTokens(row)) + " tokens")
                    .font(TMType.monoRegular(TMType.caption))
                Text("\(Format.count(row.count)) calls · \(Format.moneyShort(row.cost)) · \(Format.dateTime(row.updated))")
                    .font(TMType.regular(TMType.micro))
                    .foregroundStyle(TMDesign.quiet)
            }
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func sessionTokens(_ row: Database.SessionRow) -> Int64 {
        ToolKind(rawValue: row.tool)?.totalTokens(input: row.input, output: row.output,
                                                  cacheRead: row.cacheRead)
            ?? row.input + row.output + row.cacheRead
    }

    private func load() {
        loading = true
        let tool = selectedTool == "all" ? nil : ToolKind(rawValue: selectedTool)
        UsageQueryService.shared.loadSessions(tool: tool) {
            rows = $0
            loading = false
        }
    }
}

private struct SessionDetailView: View {
    let session: Database.SessionRow
    @Environment(\.dismiss) private var dismiss
    @State private var turns: [(ts: Int64, model: String?, input: Int64, output: Int64,
                                cacheRead: Int64, cacheWrite: Int64, cost: Double)] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title?.isEmpty == false ? session.title! : session.sessionID)
                        .font(TMType.semibold(TMType.section))
                    Text(ToolKind(rawValue: session.tool)?.displayName ?? session.tool)
                        .font(TMType.regular(TMType.caption))
                        .foregroundStyle(TMDesign.quiet)
                }
                Spacer()
                Button("Done") { dismiss() }
            }
            Divider()
            if turns.isEmpty {
                Text("No turn details").foregroundStyle(TMDesign.quiet)
                Spacer()
            } else {
                List(Array(turns.enumerated()), id: \.offset) { _, turn in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(turn.model ?? "Unknown model")
                            Text(Format.dateTime(turn.ts))
                                .font(TMType.regular(TMType.micro))
                                .foregroundStyle(TMDesign.quiet)
                        }
                        Spacer()
                        Text("\(Format.compact(turn.input + turn.output + turn.cacheRead)) · \(Format.moneyShort(turn.cost))")
                            .font(TMType.monoRegular(TMType.caption))
                    }
                }
            }
        }
        .padding(20)
        .frame(minWidth: 680, minHeight: 420)
        .onAppear {
            UsageQueryService.shared.loadTurns(sessionTool: session.tool,
                                               sessionID: session.sessionID) { turns = $0 }
        }
    }
}
