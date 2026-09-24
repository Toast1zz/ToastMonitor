import SwiftUI

/// Settings › Sources › Collectors: one summary row, collapsed by default.
/// Testing, rescanning or the disclosure triangle expands a table with one
/// row per collector plus the remote feed.
struct CollectorStatusSection: View {
    @ObservedObject private var health = SourceHealthHub.shared
    @ObservedObject private var remote = HermesRemoteClient.shared
    /// Effective source per tool, owned by the Sources pane.
    let remoteSources: [ToolKind: Bool]

    @State private var expanded = false
    @State private var testing = false
    @State private var testResult: (text: String, ok: Bool)?
    /// Bumped per test start; a stale 10s timeout checks it before firing.
    @State private var testGeneration = 0

    private struct Row: Identifiable {
        let id: String
        let name: String
        let symbol: String
        let color: Color
        let mode: String
        let status: Status
        let lastScan: Int64
        let imported: String
        let failed: String
        let duration: String
        let error: String?
    }

    enum Status: String {
        case synced = "Synced", stale = "Stale", error = "Error", idle = "Idle"

        var symbol: String {
            switch self {
            case .synced: return "checkmark.circle.fill"
            case .stale: return "clock.badge.exclamationmark"
            case .error: return "xmark.circle.fill"
            case .idle: return "circle.dashed"
            }
        }

        var color: Color {
            switch self {
            case .synced, .idle: return .secondary
            case .stale: return TMDesign.warning
            case .error: return TMDesign.danger
            }
        }
    }

    var body: some View {
        Section("Collectors") {
            DisclosureGroup(isExpanded: $expanded) {
                if let testResult {
                    Text(testResult.text)
                        .foregroundStyle(testResult.ok ? Color.secondary : TMDesign.danger)
                        .textSelection(.enabled)
                }
                table
                ForEach(rows.filter { $0.error != nil }) { row in
                    LabeledContent(row.name) {
                        Text(row.error ?? "")
                            .foregroundStyle(TMDesign.danger)
                            .textSelection(.enabled)
                    }
                }
            } label: {
                LabeledContent {
                    HStack {
                        Button {
                            test()
                        } label: {
                            if testing {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("Test Connection")
                            }
                        }
                        .disabled(testing)
                        Button("Rescan Now") { rescan() }
                    }
                } label: {
                    Text(summary)
                        .foregroundStyle(summaryColor)
                }
            }
        }
    }

    // MARK: - Table

    private var table: some View {
        let rows = rows
        return Table(rows) {
            TableColumn("Source") { row in
                HStack(spacing: 6) {
                    Image(systemName: row.symbol)
                        .foregroundStyle(row.color)
                        .frame(width: 16)
                    Text(row.name)
                }
                .help("\(row.name) · \(row.mode)")
            }
            .width(min: 96, ideal: 128)
            TableColumn("Status") { row in
                Label(row.status.rawValue, systemImage: row.status.symbol)
                    .foregroundStyle(row.status.color)
                    .help(row.error ?? row.status.rawValue)
            }
            .width(min: 56, ideal: 64)
            TableColumn("Last Scan") { row in
                Text(row.lastScan > 0 ? Format.dateTime(row.lastScan) : "—")
            }
            .width(min: 72, ideal: 78)
            TableColumn("Imported") { row in
                Text(row.imported).frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 44, ideal: 56)
            TableColumn("Failed") { row in
                Text(row.failed).frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 36, ideal: 42)
            TableColumn("Time") { row in
                Text(row.duration).frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 40, ideal: 48)
        }
        .tableStyle(.bordered(alternatesRowBackgrounds: true))
        .tmMonospacedDigit()
        .frame(height: CGFloat(rows.count) * 24 + 30)
        .accessibilityLabel("Collector status")
    }

    private var rows: [Row] {
        let tools = ToolKind.allCases.filter { $0 != .openrouter }
        var out = tools.map { tool -> Row in
            let h = health.sources.first { $0.tool == tool.rawValue }
            let status: Status
            if h?.error != nil {
                status = .error
            } else if h?.isStale == true {
                status = .stale
            } else if (h?.lastScan ?? 0) > 0 {
                status = .synced
            } else {
                status = .idle
            }
            return Row(id: tool.rawValue, name: tool.displayName, symbol: tool.symbol, color: tool.color,
                       mode: (remoteSources[tool] ?? false) ? "Remote" : "Local",
                       status: status, lastScan: h?.lastScan ?? 0,
                       imported: h.map { "\($0.lastRows)" } ?? "—",
                       failed: h.map { "\($0.failedRows)" } ?? "—",
                       duration: h.map { String(format: "%.0f ms", $0.durationMs) } ?? "—",
                       error: h?.error)
        }
        let st = remote.status
        let remoteStatus: Status
        if st.error != nil {
            remoteStatus = .error
        } else if st.lastSync > 0,
                  Date().timeIntervalSince1970 - TimeInterval(st.lastSync) > SourceHealth.staleThreshold {
            remoteStatus = .stale
        } else {
            remoteStatus = st.lastSync > 0 ? .synced : .idle
        }
        out.append(Row(id: "remote-feed", name: "Remote Feed", symbol: "externaldrive.badge.icloud",
                       color: TMDesign.accent, mode: "Remote", status: remoteStatus,
                       lastScan: st.lastSync, imported: "\(st.lastRows)", failed: "—",
                       duration: "—", error: st.error))
        return out
    }

    private var summary: String {
        let rows = rows
        let errors = rows.filter { $0.status == .error }
        let stale = rows.filter { $0.status == .stale }
        if errors.count == 1 { return "\(errors[0].name) failed" }
        if errors.count > 1 { return "\(errors.count) sources failed" }
        if stale.count == 1 { return "\(stale[0].name) is stale" }
        if stale.count > 1 { return "\(stale.count) sources are stale" }
        let last = rows.map(\.lastScan).max() ?? 0
        return last > 0 ? "Up to date · \(Format.dateTime(last))" : "Not scanned yet"
    }

    private var summaryColor: Color {
        let rows = rows
        if rows.contains(where: { $0.status == .error }) { return TMDesign.danger }
        if rows.contains(where: { $0.status == .stale }) { return TMDesign.warning }
        return .secondary
    }

    // MARK: - Actions

    private func test() {
        expanded = true
        testing = true
        testResult = nil
        testGeneration += 1
        let gen = testGeneration
        CollectorEngine.shared.scheduleScan(force: true) { receipt in
            // The completion is the source of truth: a late success must be
            // able to replace the 10s timeout message.
            guard gen == testGeneration else { return }
            // Read the remote status in the poll's own completion; the local
            // scan usually finishes first and would report a stale value.
            HermesRemoteClient.shared.poll {
                guard gen == testGeneration else { return }
                testing = false
                let remoteErr = HermesRemoteClient.shared.status.error
                if receipt.failedSources.isEmpty && remoteErr == nil {
                    testResult = ("Scan complete · \(receipt.turns) new", true)
                } else {
                    var parts = receipt.failedSources
                    if let remoteErr { parts.append("Remote Feed: \(remoteErr)") }
                    testResult = ("Failed: \(parts.joined(separator: ", "))", false)
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            guard gen == testGeneration, testing else { return }
            testing = false
            testResult = ("Scan not finished in 10 s", false)
        }
    }

    private func rescan() {
        expanded = true
        CollectorEngine.shared.scheduleScan()
        OpenRouterClient.shared.refresh()
        OpenCodeGoClient.shared.refresh()
    }
}
