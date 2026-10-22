import SwiftUI

/// Why a popover row could not refresh, and what to do about it. Rows show
/// only a "?" button; the explanation opens in a popover on click.
struct RowProblem: Equatable {
    let title: String
    let detail: String
    /// The fix lives in Settings › Accounts; the popover offers to open it.
    var opensSettings = false

    /// Maps a client's error text to a plain explanation. `service` is the
    /// row's name as the user sees it.
    static func from(service: String, error: String) -> RowProblem {
        let text = error.lowercased()
        if isConnectionProblem(text) {
            return RowProblem(
                title: "\(service) can’t connect",
                detail: "This Mac appears to be offline or the service can’t be reached. "
                    + "The numbers shown are from the last successful update, and ToastMonitor "
                    + "tries again on its own.")
        }
        if text.contains("keychain") {
            return RowProblem(
                title: "\(service) login can’t be read",
                detail: "Keychain did not let ToastMonitor read the saved login. Unlock the "
                    + "login keychain or allow access when macOS asks, then refresh.")
        }
        if service.hasPrefix("Claude") {
            if text.contains("expired") {
                return RowProblem(
                    title: "Claude login expired",
                    detail: "Open Terminal and run claude. It signs in again as it starts, and "
                        + "ToastMonitor picks up the new login on its next refresh.")
            }
            if text.contains("not found") {
                return RowProblem(
                    title: "Claude login not found",
                    detail: "Open Terminal and run claude /login, then refresh ToastMonitor.")
            }
        }
        if text.contains("expired") || text.contains("401") || text.contains("403")
            || text.contains("rejected") || text.contains("unauthorized") {
            return RowProblem(
                title: "\(service) sign-in needs attention",
                detail: "The saved login or key was refused. Sign in again or replace the key "
                    + "in Settings › Accounts.",
                opensSettings: true)
        }
        return RowProblem(
            title: "\(service) couldn’t refresh",
            detail: error.trimmingCharacters(in: .whitespacesAndNewlines)
                + "\n\nToastMonitor tries again on its own.")
    }

    private static func isConnectionProblem(_ text: String) -> Bool {
        ["offline", "not connected", "network connection was lost", "timed out",
         "could not connect", "cannot find host", "could not be found", "dns"]
            .contains { text.contains($0) }
    }
}

/// The quiet "?" beside a row's name. Clicking it opens the explanation in
/// a popover anchored to the button, inside the panel.
struct RowProblemButton: View {
    let problem: RowProblem
    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 12))
                .foregroundStyle(TMDesign.quiet)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(problem.title)
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text(problem.title)
                    .font(.headline)
                Text(problem.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if problem.opensSettings {
                    Button("Open Settings…") {
                        showing = false
                        SettingsWindowController.shared.show(pane: .accounts)
                        NotificationCenter.default.post(name: PanelController.hideNotification, object: nil)
                    }
                    .padding(.top, 2)
                }
            }
            .padding(14)
            .frame(width: 260, alignment: .leading)
        }
    }
}
