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
    private static let gate = CLIRenewalGate()

    /// Blocks for up to `timeout`; never call it on the main actor. Completes
    /// when `grok models` exits cleanly, which it does only with a usable
    /// (possibly just renewed) login.
    nonisolated static func refresh() -> CLIRenewalOutcome {
        guard gate.begin() else { return .throttled }
        let outcome = run(binary: nil)
        if case .failed(let reason) = outcome {
            NSLog("[ToastMonitor][renewal] grok failed: %@", reason)
        }
        return outcome
    }

    nonisolated static func run(binary: String?) -> CLIRenewalOutcome {
        guard let binary = binary ?? ClaudeCLIRefresher.locateBinary(named: "grok") else {
            return .failed("binary not found")
        }
        // Same Gatekeeper reason as ClaudeCLIRefresher: a quarantined build
        // that is not notarized would raise a dialog on every attempt.
        guard !ClaudeCLIRefresher.launchBlocked(binary) else { return .failed("blocked by Gatekeeper") }

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
            return .failed("launch: \(error.localizedDescription)")
        }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
            }
            return .failed("timed out after \(Int(timeout))s")
        }
        return process.terminationStatus == 0 ? .completed : .failed("exit \(process.terminationStatus)")
    }
}
