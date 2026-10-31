import Foundation
import Darwin
import Security

/// Delegates Claude Code's OAuth token refresh to the real `claude` CLI
/// instead of ToastMonitor implementing an OAuth refresh flow of its own.
///
/// Anthropic's OAuth token endpoint is reserved for Claude Code itself; a
/// third party reimplementing the refresh call (client_id, grant_type,
/// rewriting the credentials file) is a bigger step into "impersonating the
/// official client" than a read-only usage check already is. Community
/// tools facing the same problem (e.g. github.com/Javis603/token-monitor)
/// instead spawn a real `claude` session and let its own startup sequence
/// validate/refresh the token as a side effect — Claude Code always checks
/// its login and (if expired) refreshes it the moment a session starts, to
/// show you your rate-limit status, before you've typed anything. This
/// mirrors that: open a PTY, launch `claude` with every tool disabled, send
/// `/status` (a read-only account query, not a prompt to the model), wait
/// for it to answer, then exit. No chat turn is ever sent, so this is the
/// same zero-cost thing that happens every time you open `claude` yourself
/// — just triggered on ToastMonitor's behalf instead of waiting for you to
/// happen to use the CLI.
enum ClaudeCLIRefresher {
    /// Phrases Claude Code shows on first run in a new/untrusted directory.
    /// Matched only to decide when it's safe to send a bare Enter — never
    /// used to trigger any other input.
    static let dismissPromptTokens = [
        "trustthisfolder", "safetycheck", "presstocontinue", "readytocode",
    ]
    /// Phrases that show up once `/status` has actually rendered account
    /// info — the signal that the login check (and any refresh) completed.
    static let statusReadyTokens = [
        "loggedin", "subscription", "organization",
    ]

    private static let probeTimeout: TimeInterval = 25
    private static let gate = CLIRenewalGate()

    private static var attempt = 0
    private static let lock = NSLock()

    /// `--tools ""` disables the tool list. The probe still uses the user's
    /// Claude login; CLAUDE_CONFIG_DIR is left unset on purpose. A failed
    /// login retries every minute, and a normal start launches every
    /// configured MCP server, so most retries skip them.
    nonisolated static func arguments(attempt: Int) -> [String] {
        attempt % 5 == 0 ? ["--tools", ""] : ["--tools", "", "--strict-mcp-config"]
    }

    /// Finds a `claude` executable without shelling out when possible.
    /// Returns nil if none is found — callers should fall back to the
    /// existing "token expired, run claude to refresh" messaging rather
    /// than attempting a probe with no binary.
    /// `fixedCandidates` covers the two common non-Homebrew-variable install
    /// roots; overridable so tests can run hermetically instead of picking
    /// up whatever happens to be installed on the machine running them.
    nonisolated static func locateBinary(named name: String = "claude",
                                         env: [String: String] = ProcessInfo.processInfo.environment,
                                         home: String = NSHomeDirectory(),
                                         fixedCandidates: [String]? = nil) -> String? {
        let fixed = fixedCandidates ?? ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)"]
        // ~/.grok/bin is where Grok's own installer puts it; an app opened
        // from Finder doesn't get the PATH line that installer adds.
        let candidates = ["\(home)/.local/bin/\(name)", "\(home)/.\(name)/bin/\(name)"] + fixed
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        guard let pathVar = env["PATH"] else { return nil }
        for dir in pathVar.split(separator: ":") {
            let candidate = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// True when the file a path resolves to carries a quarantine flag the
    /// user has not approved yet.
    nonisolated static func isQuarantined(_ path: String) -> Bool {
        let target = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let name = "com.apple.quarantine"
        let size = getxattr(target, name, nil, 0, 0, 0)
        guard size > 0 else { return false }
        var buffer = [UInt8](repeating: 0, count: size)
        guard getxattr(target, name, &buffer, size, 0, 0) == size else { return false }
        return quarantineBlocksLaunch(String(decoding: buffer, as: UTF8.self))
    }

    /// True when launching the file from this app would raise a Gatekeeper
    /// dialog: quarantined and not notarized. Homebrew re-quarantines a cask
    /// on every upgrade and a Terminal run never clears the flag, so blocking
    /// notarized builds too stopped renewals for good after each upgrade.
    nonisolated static func launchBlocked(_ path: String) -> Bool {
        isQuarantined(path) && !isNotarized(path)
    }

    /// Checks the notarization ticket (stapled, or online); may block briefly.
    nonisolated static func isNotarized(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath() as CFURL
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(url, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString("notarized" as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures),
                                          requirement) == errSecSuccess
    }

    /// The xattr reads "flags;timestamp;agent;uuid" with hex flags; 0x40
    /// marks a file the user already approved to open.
    nonisolated static func quarantineBlocksLaunch(_ value: String) -> Bool {
        guard let field = value.split(separator: ";", omittingEmptySubsequences: false).first,
              let flags = UInt32(field, radix: 16) else { return true }
        return flags & 0x40 == 0
    }

    /// Runs the probe synchronously — this blocks for up to ~25s and must
    /// never be called on the main actor. Ends as soon as `renewed` reports
    /// the new login, or once `/status` visibly rendered account info, which
    /// is the signal Claude Code's own login check completed.
    nonisolated static func refresh(binary: String? = nil,
                                    renewed: (@Sendable () -> Bool)? = nil) -> CLIRenewalOutcome {
        guard gate.begin() else { return .throttled }
        lock.lock()
        let currentAttempt = attempt
        attempt += 1
        lock.unlock()
        let outcome = probe(binary: binary, attempt: currentAttempt, renewed: renewed)
        if case .failed(let reason) = outcome {
            NSLog("[ToastMonitor][renewal] claude attempt %d failed: %@", currentAttempt, reason)
        }
        return outcome
    }

    /// The next renewal, hours away, starts over with the full launch.
    nonisolated static func renewalSucceeded() {
        lock.lock()
        let attempts = attempt
        attempt = 0
        lock.unlock()
        if attempts > 1 {
            NSLog("[ToastMonitor][renewal] claude renewed on attempt %d", attempts - 1)
        }
    }

    private nonisolated static func probe(binary: String?, attempt: Int,
                                          renewed: (@Sendable () -> Bool)?) -> CLIRenewalOutcome {
        guard let binary = binary ?? locateBinary() else { return .failed("binary not found") }
        // A quarantined build that is not notarized makes Gatekeeper put up
        // a "cannot verify" dialog on every attempt, while a Terminal run is
        // exempt — so leave that one to the user there.
        guard !launchBlocked(binary) else { return .failed("blocked by Gatekeeper") }

        var masterFD: Int32 = 0
        var slaveFD: Int32 = 0
        guard openpty(&masterFD, &slaveFD, nil, nil, nil) == 0 else { return .failed("no PTY") }

        // A dedicated scratch directory: this must never run inside one of
        // the user's real projects (wrong trust prompts, wrong CLAUDE.md,
        // wrong git context). The marker file suppresses the one-time
        // deep-link registration prompt so it can't block the PTY probe.
        let probeDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("toastmonitor-claude-probe", isDirectory: true)
        let claudeDir = probeDir.appendingPathComponent(".claude", isDirectory: true)
        try? FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        let settingsPath = claudeDir.appendingPathComponent("settings.local.json")
        if !FileManager.default.fileExists(atPath: settingsPath.path) {
            try? Data("{\"disableDeepLinkRegistration\":\"disable\"}\n".utf8).write(to: settingsPath)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments(attempt: attempt)
        process.currentDirectoryURL = probeDir
        let slaveHandle = FileHandle(fileDescriptor: slaveFD, closeOnDealloc: false)
        process.standardInput = slaveHandle
        process.standardOutput = slaveHandle
        process.standardError = slaveHandle

        do {
            try process.run()
        } catch {
            close(masterFD)
            close(slaveFD)
            return .failed("launch: \(error.localizedDescription)")
        }
        close(slaveFD) // the child holds its own copy; the parent's is done

        let flags = fcntl(masterFD, F_GETFL, 0)
        _ = fcntl(masterFD, F_SETFL, flags | O_NONBLOCK)

        var buffer = [UInt8]()
        let deadline = Date().addingTimeInterval(probeTimeout)
        let commandSendTime = Date().addingTimeInterval(5) // let the UI settle first
        var sentCommand = false
        var nudgedAfterStatus = false
        var scanFrom = 0
        var succeeded = false
        var nextRenewedCheck = Date().addingTimeInterval(1)

        while Date() < deadline {
            if let renewed, Date() >= nextRenewedCheck {
                if renewed() {
                    succeeded = true
                    break
                }
                nextRenewedCheck = Date().addingTimeInterval(1)
            }
            var pfd = pollfd(fd: masterFD, events: Int16(POLLIN), revents: 0)
            if poll(&pfd, 1, 80) > 0, Int32(pfd.revents) & POLLIN != 0 {
                var chunk = [UInt8](repeating: 0, count: 8192)
                let n = read(masterFD, &chunk, chunk.count)
                if n > 0 { buffer.append(contentsOf: chunk[0..<n]) }
            }
            let fresh = buffer.dropFirst(min(scanFrom, buffer.count))
            let scan = compact(Array(fresh.suffix(20_000)))
            let now = Date()

            if dismissPromptTokens.contains(where: scan.contains) {
                writeToFD(masterFD, "\r")
                scanFrom = buffer.count
            }
            if !sentCommand, now >= commandSendTime {
                writeToFD(masterFD, "/status\r")
                sentCommand = true
                scanFrom = buffer.count
            }
            if sentCommand, !nudgedAfterStatus, now >= commandSendTime.addingTimeInterval(0.8) {
                writeToFD(masterFD, "\r")
                nudgedAfterStatus = true
            }
            if sentCommand, statusReadyTokens.contains(where: scan.contains) {
                succeeded = true
                Thread.sleep(forTimeInterval: 1.5) // let the credential write flush
                break
            }
        }

        writeToFD(masterFD, "/exit\r")
        Thread.sleep(forTimeInterval: 0.3)
        if process.isRunning {
            process.terminate()
            for _ in 0..<20 where process.isRunning { Thread.sleep(forTimeInterval: 0.1) }
        }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        close(masterFD)
        return succeeded ? .completed : .failed("no account info within \(Int(probeTimeout))s")
    }

    private static func writeToFD(_ fd: Int32, _ text: String) {
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
    }

    /// Strips ANSI escapes and collapses everything to lowercase
    /// letters/digits, matching the "does this recognisable phrase appear
    /// anywhere in the recent output" check the probe relies on — exact
    /// spacing/formatting in Claude Code's TUI output isn't something to
    /// depend on.
    private static func compact(_ bytes: [UInt8]) -> String {
        guard let text = String(bytes: bytes, encoding: .utf8) else { return "" }
        var out = ""
        out.reserveCapacity(text.count)
        var iterator = text.unicodeScalars.makeIterator()
        while let scalar = iterator.next() {
            if scalar == "\u{1B}" {
                // Skip a CSI/OSC-ish escape sequence: ESC then non-letters
                // then a letter terminator, best-effort (this only feeds a
                // "does a keyword appear" scan, not anything that must be
                // byte-exact).
                while let next = iterator.next(), !CharacterSet.letters.contains(next) {}
                continue
            }
            if scalar.properties.isAlphabetic || scalar.properties.numericType != nil || scalar == "%" {
                out.unicodeScalars.append(scalar)
            }
        }
        return out.lowercased()
    }
}
