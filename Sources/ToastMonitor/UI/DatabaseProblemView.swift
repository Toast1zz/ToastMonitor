import AppKit
import SwiftUI

/// Shown instead of an empty dashboard when the store cannot be used, so a
/// damaged database never looks like a first launch.
struct DatabaseProblemView: View {
    let problem: Database.OpenProblem
    @ObservedObject private var app = AppState.shared
    @State private var latestBackup: URL?
    @State private var failed = false

    private var title: String {
        switch problem {
        case .damaged: return "ToastMonitor can't read its database"
        case .readOnly: return "ToastMonitor can't write to its database"
        }
    }

    private var detail: String {
        switch problem {
        case .damaged(let message), .readOnly(let message): return message
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: "exclamationmark.triangle.fill")
                .font(TMType.semibold(TMType.body))
                .foregroundStyle(TMDesign.danger)
            Text(failed ? "Recovery failed; the database was left as it was." : detail)
                .font(TMType.regular(TMType.caption))
                .foregroundStyle(TMDesign.quiet)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            HStack(spacing: 8) {
                if latestBackup != nil {
                    Button("Restore Latest Backup…") { confirmRecovery(from: latestBackup) }
                }
                Button("Start Fresh…") { confirmRecovery(from: nil) }
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: Database.shared.dbPath)])
                }
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .onAppear {
            DispatchQueue.global(qos: .utility).async {
                let newest = DataMaintenance.availableBackups().first
                DispatchQueue.main.async { latestBackup = newest }
            }
        }
    }

    private func confirmRecovery(from backup: URL?) {
        let alert = NSAlert()
        if let backup {
            let date = (try? backup.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate.map { Format.dateTime(Int64($0.timeIntervalSince1970)) } ?? ""
            alert.messageText = "Restore the backup from \(date)?"
            alert.informativeText = "Usage since then is read again from logs still on this Mac. The current file is kept beside the new one."
            alert.addButton(withTitle: "Restore Backup")
        } else {
            alert.messageText = "Start with an empty database?"
            alert.informativeText = "History is read again from logs still on this Mac; subscriptions and settings start empty. The current file is kept beside the new one."
            alert.addButton(withTitle: "Start Fresh")
        }
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = DataMaintenance.recover(from: backup)
            DispatchQueue.main.async {
                failed = !ok
                app.databaseWasReplaced()
            }
        }
    }
}
