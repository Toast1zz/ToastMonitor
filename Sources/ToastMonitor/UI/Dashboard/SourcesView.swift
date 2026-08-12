import SwiftUI

/// 数据来源 (spec §3.2): 每个采集器一张状态卡 — 模式/最后扫描/条数/失败/耗时/错误，
/// 测试连接 + 立即重扫入口。来源切换立即保存并反馈。
struct SourcesView: View {
    @ObservedObject private var health = SourceHealthHub.shared
    @ObservedObject private var remote = HermesRemoteClient.shared
    @State private var testing = false
    @State private var testResult: String?
    /// True when the last test ended in a completed scan (colors the result).
    @State private var testOK = false
    /// Bumped per test start; stale 10s timeouts check it before firing.
    @State private var testGeneration = 0

    private let tools: [ToolKind] = ToolKind.allCases.filter { $0 != .openrouter }
    var embedded = false

    var body: some View {
        Group {
            if embedded {
                content
            } else {
                ScrollView { content }
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionTitle("Collector Status")
                    Spacer()
                    Button {
                        testing = true
                        testOK = false
                        testResult = nil
                        testGeneration += 1
                        let gen = testGeneration
                        CollectorEngine.shared.scheduleScan(force: true) { receipt in
                            // 完成回调是唯一真相源：只按代际过滤（迟到成功必须
                            // 能覆盖 10s 超时文案，不能被 testing 状态丢弃）。
                            guard gen == testGeneration else { return }
                            testing = false
                            let remoteErr = HermesRemoteClient.shared.status.error
                            let localFailed = receipt.failedSources
                            if localFailed.isEmpty && remoteErr == nil {
                                testOK = true
                                testResult = "Scan complete (\(receipt.turns) new)"
                            } else {
                                testOK = false
                                var parts = localFailed
                                if let remoteErr { parts.append("Remote Feed: \(remoteErr)") }
                                testResult = "Error: \(parts.joined(separator: ", "))"
                            }
                        }
                        HermesRemoteClient.shared.poll()
                        // 超时只兜底"仍在等待"；迟到的完成回调会覆盖此文案。
                        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                            guard gen == testGeneration, testing else { return }
                            testing = false
                            testOK = false
                            testResult = "Scan not finished in 10s"
                        }
                    } label: {
                        if testing {
                            ProgressView().controlSize(.mini)
                        } else {
                            Label("Test connection", systemImage: "bolt")
                        }
                    }
                    .disabled(testing)
                    .accessibilityLabel("Test connection")
                    .accessibilityValue(testing ? "Running" : "Ready")
                    .accessibilityHint("Runs an immediate scan and checks all sources")
                    Button {
                        CollectorEngine.shared.scheduleScan()
                        OpenRouterClient.shared.refresh()
                        OpenCodeGoClient.shared.refresh()
                    } label: {
                        Label("Rescan now", systemImage: "arrow.clockwise")
                    }
                    .accessibilityLabel("Rescan now")
                    .accessibilityHint("Re-scans all local sources and refreshes remote quotas")
                }
                .controlSize(.small)
                if let tr = testResult {
                    Text(tr)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Connection test result")
                        .accessibilityValue(Text(tr))
                        .font(TMType.regular(11))
                        .foregroundStyle(testOK ? TMDesign.accent : TMDesign.danger)
                }
            }
            .padding(.bottom, 10)

            Divider()

            ForEach(Array(tools.enumerated()), id: \.element) { _, tool in
                sourceRow(tool)
                Divider()
            }
            remoteRow
        }
        .tmPanelSurface()
        .padding(.horizontal, embedded ? 0 : 24)
        .padding(.vertical, embedded ? 0 : 18)
    }

    private func sourceRow(_ tool: ToolKind) -> some View {
        let h = health.sources.first { $0.tool == tool.rawValue }
        let isRemote = tool.sourceIsRemote
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: tool.symbol)
                    .font(TMType.medium(TMType.body))
                    .foregroundStyle(tool.color)
                    .frame(width: 20)
                Text(tool.displayName)
                    .font(TMType.semibold(TMType.body))
                Spacer()
                Text(isRemote ? "Remote" : "Local")
                    .font(TMType.regular(TMType.micro))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
                if h?.error != nil {
                    TMStatusPill(text: "Error", color: TMDesign.danger, symbol: "xmark.circle.fill")
                } else if h?.isStale == true {
                    TMStatusPill(text: "Stale", color: TMDesign.accent, symbol: "clock.badge.exclamationmark")
                } else if (h?.lastScan ?? 0) > 0 {
                    TMStatusPill(text: "Synced", color: TMDesign.quiet, symbol: "checkmark.circle.fill")
                } else {
                    TMStatusPill(text: "Idle", color: TMDesign.quiet, symbol: "circle.dashed")
                }
            }
            HStack(spacing: 16) {
                infoItem("Last scan", h.map { Format.dateTime($0.lastScan) } ?? "—")
                infoItem("Imported", h.map { "\($0.lastRows) rows" } ?? "—")
                infoItem("Failed", h.map { "\($0.failedRows) rows" } ?? "—")
                infoItem("Duration", h.map { String(format: "%.0fms", $0.durationMs) } ?? "—")
            }
            if let err = h?.error {
                Text(err)
                    .font(TMType.regular(TMType.caption))
                    .foregroundStyle(TMDesign.danger.opacity(0.85))
                    .lineLimit(2)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(tool.displayName) source")
        .accessibilityValue(Text(sourceAccessibilityValue(h)))
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sourceAccessibilityValue(_ health: SourceHealth?) -> String {
        guard let health else { return "Idle" }
        let status: String
        if health.error != nil {
            status = "Error"
        } else if health.isStale {
            status = "Stale"
        } else if health.lastScan > 0 {
            status = "Synced"
        } else {
            status = "Idle"
        }
        let scannedAt = health.lastScan > 0 ? Format.dateTime(health.lastScan) : "—"
        return "\(status), last scan \(scannedAt), imported \(health.lastRows) rows, failed \(health.failedRows) rows"
    }

    private var remoteRow: some View {
        let st = remote.status
        let stale = st.lastSync > 0
            && Date().timeIntervalSince1970 - TimeInterval(st.lastSync) > SourceHealth.staleThreshold
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "externaldrive.badge.icloud")
                    .font(TMType.medium(TMType.body))
                    .foregroundStyle(TMDesign.accent)
                    .frame(width: 20)
                Text("Remote Feed")
                    .font(TMType.semibold(TMType.body))
                Spacer()
                if st.error != nil {
                    TMStatusPill(text: "Error", color: TMDesign.danger, symbol: "xmark.circle.fill")
                } else if stale {
                    TMStatusPill(text: "Stale", color: TMDesign.accent, symbol: "clock.badge.exclamationmark")
                } else if st.lastSync > 0 {
                    TMStatusPill(text: "Synced", color: TMDesign.quiet, symbol: "checkmark.circle.fill")
                } else {
                    TMStatusPill(text: "Idle", color: TMDesign.quiet, symbol: "circle.dashed")
                }
            }
            HStack(spacing: 16) {
                infoItem("Last sync", st.lastSync > 0 ? Format.dateTime(st.lastSync) : "—")
                infoItem("Imported", "\(st.lastRows) rows")
                infoItem("Delay", st.lastSync > 0 ? Format.remaining(Int64(Date().timeIntervalSince1970) - st.lastSync) : "—")
            }
            if let err = st.error {
                Text(err)
                    .font(TMType.regular(TMType.caption))
                    .foregroundStyle(TMDesign.danger.opacity(0.85))
                    .lineLimit(2)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Remote Feed")
        .accessibilityValue(Text(remoteAccessibilityValue(st, stale: stale)))
        .padding(.top, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func remoteAccessibilityValue(_ status: HermesRemoteClient.SyncStatus, stale: Bool) -> String {
        let state: String
        if status.error != nil {
            state = "Error"
        } else if stale {
            state = "Stale"
        } else if status.lastSync > 0 {
            state = "Synced"
        } else {
            state = "Idle"
        }
        return "\(state), last sync \(status.lastSync > 0 ? Format.dateTime(status.lastSync) : "—"), imported \(status.lastRows) rows"
    }

    private func infoItem(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(TMType.regular(TMType.caption))
                .foregroundStyle(TMDesign.quiet)
            Text(value)
                .font(TMType.regular(TMType.caption))
                .tmMonospacedDigit()
        }
    }

}
