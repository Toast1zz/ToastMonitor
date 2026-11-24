import SwiftUI

/// Why a popover row could not refresh, and what to do about it. Rows show
/// only a "?" button; the explanation opens in a popover on click.
struct RowProblem: Equatable {
    let title: String
    let detail: String
    /// The fix lives in Settings › Accounts; the popover offers to open it.
    var opensSettings = false
    /// Account key inside Settings › Accounts to expand when opening Settings.
    var accountKey: String? = nil

    /// Maps a client's error text to a plain explanation. `service` is the
    /// row's name as the user sees it.
    static func from(service: String, error: String, accountKey: String? = nil) -> RowProblem {
        let text = error.lowercased()
        if isConnectionProblem(text) {
            return RowProblem(
                title: "\(service) can’t connect",
                detail: "This Mac appears to be offline or the service can’t be reached. "
                    + "The numbers shown are from the last successful update, and ToastMonitor "
                    + "tries again on its own.",
                accountKey: accountKey)
        }
        if text.contains("keychain") {
            return RowProblem(
                title: "\(service) login can’t be read",
                detail: "Keychain did not let ToastMonitor read the saved login. Unlock the "
                    + "login keychain or allow access when macOS asks, then refresh.",
                accountKey: accountKey)
        }
        if service.hasPrefix("Claude") {
            if text.contains("expired") {
                return RowProblem(
                    title: "Claude login expired",
                    detail: "Open Terminal and run claude. It signs in again as it starts, and "
                        + "ToastMonitor picks up the new login on its next refresh.",
                    accountKey: accountKey)
            }
            if text.contains("not found") {
                return RowProblem(
                    title: "Claude login not found",
                    detail: "Open Terminal and run claude /login, then refresh ToastMonitor.",
                    accountKey: accountKey)
            }
        }
        if text.contains("grok login expired") {
            return RowProblem(
                title: "Grok login expired",
                detail: "Open Terminal and run grok. It renews the login as it starts, or asks "
                    + "you to sign in again if it can’t.",
                accountKey: accountKey)
        }
        if text.contains("expired") || text.contains("401") || text.contains("403")
            || text.contains("rejected") || text.contains("unauthorized")
            || text.contains("redirect") || text.contains("302") {
            return RowProblem(
                title: "\(service) sign-in needs attention",
                detail: "The saved login or key was refused or expired. Sign in again or replace the credentials "
                    + "in Settings › Accounts.",
                opensSettings: true,
                accountKey: accountKey)
        }
        return RowProblem(
            title: "\(service) couldn’t refresh",
            detail: error.trimmingCharacters(in: .whitespacesAndNewlines)
                + "\n\nToastMonitor tries again on its own.",
            accountKey: accountKey)
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
                        SettingsWindowController.shared.show(pane: .accounts, expandAccount: problem.accountKey)
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
