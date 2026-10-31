import SwiftUI

/// Sessions: everything the collectors saw, newest first, grouped by day.
struct SessionsView: View {
    @State private var rows: [Database.SessionRow] = []
    @State private var selectedTool = "all"
    @State private var selectedSession: Database.SessionRow?
    @State private var loading = false
    @State private var loadGeneration = 0
    @State private var total = 0
    @State private var limit = Self.pageSize

    private static let pageSize = 500

    var body: some View {
        DashPage {
            HStack(spacing: 12) {
                toolFilter
                Spacer(minLength: 8)
                if loading {
                    ProgressView().controlSize(.small)
                } else if !rows.isEmpty {
                    Text(rows.count < total
                         ? "Latest \(rows.count) of \(total) sessions"
                         : "\(rows.count) session\(rows.count == 1 ? "" : "s")")
                        .font(TMType.regular(TMType.caption))
                        .tmMonospacedDigit()
                        .foregroundStyle(TMDesign.quiet)
                }
                Button(action: load) { Image(systemName: "arrow.clockwise") }
                    .tmGlassButton(circle: true, extraLarge: true)
                    .disabled(loading)
                    .help("Refresh sessions")
                    .accessibilityLabel("Refresh sessions")
            }

            // One card fills the page; the list scrolls inside it, with each
            // day's heading pinned while its sessions pass underneath.
            DashCard(inset: 0) {
                if loading && rows.isEmpty {
                    ProgressView("Loading sessions…")
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if rows.isEmpty {
                    Text("No sessions found")
                        .font(TMType.regular(TMType.body))
                        .foregroundStyle(TMDesign.quiet)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: 2, pinnedViews: [.sectionHeaders]) {
                            ForEach(SessionDayGroup.groups(rows)) { group in
                                Section {
                                    ForEach(group.rows) { row in
                                        SessionRowView(row: row) { selectedSession = row }
                                    }
                                } header: {
                                    Text(group.title)
                                        .font(TMType.semibold(TMType.body))
                                        .padding(.horizontal, 10)
                                        .padding(.top, 10)
                                        .padding(.bottom, 6)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(TMDesign.surface)
                                }
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.bottom, 10)
                        if rows.count < total {
                            Button("Show \(min(Self.pageSize, total - rows.count)) More") {
                                limit += Self.pageSize
                                load()
                            }
                            .disabled(loading)
                            .tmGlassButton(circle: false)
                            .padding(.bottom, 14)
                        }
                    }
                }
            }
        }
        .onAppear(perform: load)
        .onChange(of: selectedTool) { _ in
            rows = []
            limit = Self.pageSize
            load()
        }
        .sheet(item: $selectedSession) { SessionDetailView(session: $0) }
    }

    /// A pull-down button rather than a pop-up: the pop-up's bezel is the
    /// pre-Liquid Glass one, while a menu behind a glass capsule button
    /// matches the segmented controls and the other buttons on the page.
    private var toolFilter: some View {
        Menu {
            Picker("Tool", selection: $selectedTool) {
                Text("All Tools").tag("all")
                ForEach(ToolKind.allCases.filter { $0 != .openrouter }) { tool in
                    Text(tool.displayName).tag(tool.rawValue)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 6) {
                Text(ToolKind(rawValue: selectedTool)?.displayName ?? "All Tools")
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(TMDesign.quiet)
            }
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize()
        .tmGlassButton(circle: false, extraLarge: true)
        .accessibilityLabel("Tool filter")
    }

    private func load() {
        let generation = loadGeneration &+ 1
        loadGeneration = generation
        loading = true
        let tool = selectedTool == "all" ? nil : ToolKind(rawValue: selectedTool)
        UsageQueryService.shared.loadSessions(tool: tool, limit: limit) { sessions, count in
            guard generation == loadGeneration else { return }
            rows = sessions
            total = count
            loading = false
        }
    }
}

/// What a session is called on screen. Sources often store the prompt, which
/// can open with a generated file list or carry raw Markdown links.
enum SessionTitle {
    static func clean(_ raw: String?) -> String? {
        guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        if text.hasPrefix("# Files mentioned") {
            // The user's words follow this heading; without it there are none.
            guard let heading = text.range(of: #"(?m)^## My request[^\n]*\n"#, options: .regularExpression) else { return nil }
            text = String(text[heading.upperBound...])
        }
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first = lines.first(where: { !$0.isEmpty }) else { return nil }
        return first.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "\\", with: "")
    }

    /// Title, else project; never a session id.
    static func display(title: String?, project: String?) -> String {
        if let cleaned = clean(title), !cleaned.isEmpty { return cleaned }
        if let project, !project.isEmpty { return project }
        return "Untitled session"
    }
}

/// Sessions of one calendar day, headed "Today" / "Yesterday" / "Fri, Sep 26".
struct SessionDayGroup: Identifiable {
    let title: String
    let rows: [Database.SessionRow]
    var id: String { title }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "EEE, MMM d"
        return f
    }()

    /// Rows arrive newest first, so consecutive rows of one day form a group.
    static func groups(_ rows: [Database.SessionRow]) -> [SessionDayGroup] {
        let calendar = Calendar.current
        var out: [SessionDayGroup] = []
        var currentDay: Date?
        var current: [Database.SessionRow] = []
        func flush() {
            guard let day = currentDay, !current.isEmpty else { return }
            let title: String
            if calendar.isDateInToday(day) { title = "Today" }
            else if calendar.isDateInYesterday(day) { title = "Yesterday" }
            else { title = dayFormatter.string(from: day) }
            out.append(SessionDayGroup(title: title, rows: current))
        }
        for row in rows {
            let day = calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(row.updated)))
            if day != currentDay {
                flush()
                currentDay = day
                current = []
            }
            current.append(row)
        }
        flush()
        return out
    }
}

/// One session: tool glyph, title with its context, and the figures.
struct SessionRowView: View {
    let row: Database.SessionRow
    let action: () -> Void
    @State private var hovering = false

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()

    private var tool: ToolKind? { ToolKind(rawValue: row.tool) }

    private var title: String {
        SessionTitle.display(title: row.title, project: row.project)
    }

    /// Context under the title. When the project already serves as the title
    /// it is not repeated.
    private var context: String {
        let titled = SessionTitle.clean(row.title) != nil
        var parts: [String] = []
        if titled, let p = row.project, !p.isEmpty { parts.append(p) }
        if let m = row.model, !m.isEmpty { parts.append(ModelName.display(m)) }
        if parts.isEmpty { parts.append(tool?.displayName ?? row.tool) }
        return parts.joined(separator: " · ")
    }

    private var tokens: Int64 {
        tool?.totalTokens(input: row.input, output: row.output, cacheRead: row.cacheRead)
            ?? row.input + row.output + row.cacheRead
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                DashGlyph(symbol: tool?.symbol ?? "terminal",
                          color: tool?.color ?? TMDesign.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(TMType.medium(TMType.body))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(context)
                        .font(TMType.regular(TMType.caption))
                        .foregroundStyle(TMDesign.quiet)
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(Format.compact(tokens) + " tokens")
                        .font(TMType.medium(TMType.body))
                        .tmMonospacedDigit()
                    Text("\(Format.count(row.count)) calls" + (row.cost > 0 ? " · \(Format.moneyShort(row.cost))" : ""))
                        .font(TMType.regular(TMType.caption))
                        .tmMonospacedDigit()
                        .foregroundStyle(TMDesign.quiet)
                }
                Text(Self.timeFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(row.updated))))
                    .font(TMType.regular(TMType.caption))
                    .tmMonospacedDigit()
                    .foregroundStyle(TMDesign.quiet)
                    .frame(width: 40, alignment: .trailing)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(hovering ? 0.06 : 0),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
    }
}

struct SessionDetailView: View {
    let session: Database.SessionRow
    @Environment(\.dismiss) private var dismiss
    @State private var turns: [(ts: Int64, model: String?, input: Int64, output: Int64,
                                cacheRead: Int64, cacheWrite: Int64, cost: Double)] = []
    @State private var loaded = false

    private var tool: ToolKind? { ToolKind(rawValue: session.tool) }

    private var totalTokens: Int64 {
        tool?.totalTokens(input: session.input, output: session.output, cacheRead: session.cacheRead)
            ?? session.input + session.output + session.cacheRead
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 12) {
                DashGlyph(symbol: tool?.symbol ?? "terminal",
                          color: tool?.color ?? TMDesign.accent, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(SessionTitle.display(title: session.title, project: session.project))
                        .font(TMType.semibold(TMType.section))
                        .lineLimit(2)
                    Text([tool?.displayName ?? session.tool, session.project]
                        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(TMType.regular(TMType.caption))
                        .foregroundStyle(TMDesign.quiet)
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .tmGlassButton(circle: false)
            }

            DashMetricRow {
                DashMetric(label: "Tokens", value: Format.compact(totalTokens))
                DashMetric(label: "Calls", value: Format.count(session.count))
                DashMetric(label: "Cost", value: Format.moneyShort(session.cost))
            }

            DashCard("Turns", inset: 10, trailing: {
                if loaded, Int64(turns.count) < session.count {
                    Text("Latest \(turns.count) of \(Format.count(session.count))")
                        .font(TMType.regular(TMType.caption))
                        .tmMonospacedDigit()
                        .foregroundStyle(TMDesign.quiet)
                }
            }) {
                if !loaded {
                    ProgressView().controlSize(.small)
                        .frame(maxWidth: .infinity, minHeight: 80)
                } else if turns.isEmpty {
                    Text("No turn details")
                        .font(TMType.regular(TMType.body))
                        .foregroundStyle(TMDesign.quiet)
                        .frame(maxWidth: .infinity, minHeight: 80)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(turns.enumerated()), id: \.offset) { index, turn in
                                if index > 0 { Divider().padding(.horizontal, 10) }
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(turn.model.map(ModelName.display) ?? "Unknown model")
                                            .font(TMType.regular(TMType.body))
                                        Text(Format.dateTime(turn.ts))
                                            .font(TMType.regular(TMType.caption))
                                            .tmMonospacedDigit()
                                            .foregroundStyle(TMDesign.quiet)
                                    }
                                    Spacer(minLength: 12)
                                    Text(Format.compact(tool?.totalTokens(input: turn.input, output: turn.output, cacheRead: turn.cacheRead)
                                                        ?? turn.input + turn.output + turn.cacheRead))
                                        .font(TMType.medium(TMType.body))
                                        .tmMonospacedDigit()
                                    Text(Format.moneyShort(turn.cost))
                                        .font(TMType.regular(TMType.body))
                                        .tmMonospacedDigit()
                                        .foregroundStyle(TMDesign.quiet)
                                        .frame(width: 64, alignment: .trailing)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                            }
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(minWidth: 680, minHeight: 460)
        .background(TMDesign.canvas)
        .onAppear {
            UsageQueryService.shared.loadTurns(sessionTool: session.tool,
                                               sessionID: session.sessionID) {
                turns = $0
                loaded = true
            }
        }
    }
}
