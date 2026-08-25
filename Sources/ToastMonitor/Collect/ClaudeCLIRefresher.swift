import Foundation
import Darwin

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
    /// Don't spawn a probe more often than this even if a caller keeps
    /// asking — e.g. the token stays expired because the user is genuinely
    /// logged out, not just idle. A whole `claude` session is heavier than
    /// a network request; this keeps a stuck state from repeatedly spawning
    /// one on every refresh cycle.
    private static let minReinvokeInterval: TimeInterval = 10 * 60

    private static var lastInvoke: TimeInterval = 0
    private static let lock = NSLock()

    /// Finds a `claude` executable without shelling out when possible.
    /// Returns nil if none is found — callers should fall back to the
    /// existing "token expired, run claude to refresh" messaging rather
    /// than attempting a probe with no binary.
    /// `fixedCandidates` covers the two common non-Homebrew-variable install
    /// roots; overridable so tests can run hermetically instead of picking
    /// up whatever happens to be installed on the machine running them.
    nonisolated static func locateBinary(env: [String: String] = ProcessInfo.processInfo.environment,
                                         home: String = NSHomeDirectory(),
                                         fixedCandidates: [String] = ["/opt/homebrew/bin/claude", "/usr/local/bin/claude"]) -> String? {
        let candidates = ["\(home)/.local/bin/claude"] + fixedCandidates
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        guard let pathVar = env["PATH"] else { return nil }
        for dir in pathVar.split(separator: ":") {
            let candidate = "\(dir)/claude"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// Runs the probe synchronously — this blocks for up to ~25s and must
    /// never be called on the main actor. Returns true only once `/status`
    /// visibly rendered account info, which is the signal Claude Code's own
    /// login check (and refresh, if the token had expired) completed.
    @discardableResult
    nonisolated static func refresh(binary: String? = nil) -> Bool {
        lock.lock()
        let now = Date().timeIntervalSince1970
        guard now - lastInvoke >= minReinvokeInterval else { lock.unlock(); return false }
        lastInvoke = now
        lock.unlock()

        guard let binary = binary ?? locateBinary() else { return false }

        var masterFD: Int32 = 0
        var slaveFD: Int32 = 0
        guard openpty(&masterFD, &slaveFD, nil, nil, nil) == 0 else { return false }

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
        // Every tool disabled: even if something unexpected reached the
        // model, it could not read, write, or run anything.
        process.arguments = ["--allowed-tools", ""]
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
            return false
        }
        close(slaveFD) // the child holds its own copy; the parent's is done

        let flags = fcntl(masterFD, F_GETFL, 0)
        _ = fcntl(masterFD, F_SETFL, flags | O_NONBLOCK)

        var buffer = [UInt8]()
        let deadline = Date().addingTimeInterval(probeTimeout)
        let commandSendTime = Date().addingTimeInterval(5) // let the UI settle first
        var sentCommand = false
        var lastEnterSent = Date.distantPast
        var succeeded = false

        while Date() < deadline {
            var pfd = pollfd(fd: masterFD, events: Int16(POLLIN), revents: 0)
            if poll(&pfd, 1, 80) > 0, Int32(pfd.revents) & POLLIN != 0 {
                var chunk = [UInt8](repeating: 0, count: 8192)
                let n = read(masterFD, &chunk, chunk.count)
                if n > 0 { buffer.append(contentsOf: chunk[0..<n]) }
            }
            let tail = buffer.suffix(20_000)
            let scan = compact(Array(tail))
            let now = Date()

            if now.timeIntervalSince(lastEnterSent) > 0.8,
               dismissPromptTokens.contains(where: scan.contains) {
                writeToFD(masterFD, "\r")
                lastEnterSent = now
            }
            if !sentCommand, now >= commandSendTime {
                writeToFD(masterFD, "/status\r")
                sentCommand = true
            }
            if sentCommand, now.timeIntervalSince(lastEnterSent) > 0.8 {
                // Some terminals need a nudge for the input to submit.
                writeToFD(masterFD, "\r")
                lastEnterSent = now
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
        return succeeded
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
