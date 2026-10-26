import Foundation

/// Renews the Grok CLI login by running the real `grok` CLI instead of
/// ToastMonitor calling xAI's OIDC token endpoint itself.
///
/// `grok login` stores a short-lived access token (about six hours) next to
/// a long-lived refresh token in ~/.grok/auth.json. Every `grok` start
/// renews an expired access token from the refresh token before doing
/// anything else, under its own auth.json.lock. `grok models` is the
/// cheapest such start: it fetches the model catalog and exits, with no
/// chat turn, no TUI and no PTY. ToastMonitor then re-reads auth.json.
enum GrokCLIRefresher {
    private static let timeout: TimeInterval = 20
    /// A refresh token that is really dead fails every time; don't spawn the
    /// CLI on every poll while the user still has to sign in again.
    private static let minReinvokeInterval: TimeInterval = 10 * 60

    private static var lastInvoke: TimeInterval = 0
    private static let lock = NSLock()

    /// Blocks for up to `timeout`; never call it on the main actor. True
    /// when `grok models` exited cleanly, which it does only with a usable
    /// (possibly just renewed) login.
    @discardableResult
    nonisolated static func refresh(binary: String? = nil) -> Bool {
        lock.lock()
        let now = Date().timeIntervalSince1970
        guard now - lastInvoke >= minReinvokeInterval else { lock.unlock(); return false }
        lastInvoke = now
        lock.unlock()

        guard let binary = binary ?? ClaudeCLIRefresher.locateBinary(named: "grok") else { return false }
        // Same Gatekeeper reason as ClaudeCLIRefresher: an unapproved
        // Homebrew cask would raise a dialog on every attempt.
        guard !ClaudeCLIRefresher.isQuarantined(binary) else { return false }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["models"]
        // Never inside one of the user's projects: no project config, no trust prompt.
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            return false
        }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
            }
            return false
        }
        return process.terminationStatus == 0
    }
}
