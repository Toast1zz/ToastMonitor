import AppKit
import Foundation
import Darwin

/// Explicit, one-shot import from the selected browser's active Platform tab.
/// No profile files, other tabs, Google cookies, or passwords are inspected.
enum DeepSeekBrowserSession {
    enum Browser: String, CaseIterable, Identifiable, Sendable {
        case chrome = "Google Chrome"
        case safari = "Safari"
        var id: String { rawValue }
        var bundleID: String { self == .chrome ? "com.google.Chrome" : "com.apple.Safari" }
    }

    enum Failure: Error, Equatable, LocalizedError {
        case notInstalled, noTab, wrongTab, noSession, automationDenied, javascriptDisabled(Browser), timeout, failed
        var errorDescription: String? {
            switch self {
            case .notInstalled: return "Selected browser is not installed"
            case .noTab: return "Open DeepSeek in the selected browser first"
            case .wrongTab: return "Select the signed-in DeepSeek Platform tab in your browser, then retry"
            case .noSession: return "Finish signing in to DeepSeek Platform in your browser, then retry"
            case .automationDenied: return "Allow ToastMonitor under System Settings > Privacy & Security > Automation"
            case .javascriptDisabled(let browser):
                return browser == .chrome
                    ? "In Chrome, enable View > Developer > Allow JavaScript from Apple Events, then retry"
                    : "In Safari, enable Develop > Allow JavaScript from Apple Events, then retry"
            case .timeout: return "Browser connection timed out. Check for a macOS permission dialog and retry."
            case .failed: return "Browser connection failed. Check browser automation permissions or use Platform Session."
            }
        }
    }

    @MainActor static func open(_ browser: Browser) async throws {
        guard let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.bundleID) else {
            throw Failure.notInstalled
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let _: NSRunningApplication = try await withCheckedThrowingContinuation { continuation in
            NSWorkspace.shared.open([URL(string: DeepSeekBilling.platformOrigin)!],
                                    withApplicationAt: application, configuration: configuration) { app, error in
                if let app, error == nil { continuation.resume(returning: app) }
                else { continuation.resume(throwing: Failure.failed) }
            }
        }
    }

    // The origin is checked in the same JavaScript evaluation as the read,
    // so a tab navigation between the AppleScript URL check and execution
    // cannot import a session from a different website.
    static let tokenJavaScript = "(function(){if(location.origin!=='https://platform.deepseek.com')return '__TM_WRONG_TAB__';var t=localStorage.getItem('userToken');if(!t)return '__TM_NO_SESSION__';return t.length<=16384?t:'__TM_INVALID__';})()"

    static func script(for browser: Browser) -> String {
        let readTab = browser == .chrome ? "active tab of front window" : "current tab of front window"
        let readToken = browser == .chrome
            ? "execute targetTab javascript \"\(tokenJavaScript)\""
            : "do JavaScript \"\(tokenJavaScript)\" in targetTab"
        return """
        try
            if application id "\(browser.bundleID)" is not running then return "__TM_NO_TAB__"
            tell application id "\(browser.bundleID)"
                if (count of windows) is 0 then return "__TM_NO_TAB__"
                set targetTab to \(readTab)
                set targetURL to URL of targetTab
                if targetURL is not "https://platform.deepseek.com" and targetURL does not start with "https://platform.deepseek.com/" then return "__TM_WRONG_TAB__"
                return \(readToken)
            end tell
        on error errorMessage number errorNumber
            if errorNumber is -1743 then return "__TM_AUTOMATION_DENIED__"
            if errorMessage contains "JavaScript" or errorMessage contains "javascript" then return "__TM_JS_DISABLED__"
            return "__TM_FAILED__"
        end try
        """
    }

    static func parse(_ data: Data, browser: Browser) throws -> DeepSeekBilling.Credential {
        guard data.count <= 65_536, let raw = String(data: data, encoding: .utf8) else { throw Failure.failed }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "__TM_NO_TAB__": throw Failure.noTab
        case "__TM_WRONG_TAB__": throw Failure.wrongTab
        case "__TM_NO_SESSION__": throw Failure.noSession
        case "__TM_AUTOMATION_DENIED__": throw Failure.automationDenied
        case "__TM_JS_DISABLED__": throw Failure.javascriptDisabled(browser)
        case "__TM_INVALID__", "__TM_FAILED__": throw Failure.failed
        default:
            guard let credential = try? DeepSeekBilling.Credential.make(raw, kind: .platform) else { throw Failure.failed }
            return credential
        }
    }

    static func read(_ browser: Browser) async throws -> DeepSeekBilling.Credential {
        let worker = Task.detached(priority: .userInitiated) { try readSynchronously(browser) }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: { worker.cancel() }
    }

    private static func readSynchronously(_ browser: Browser) throws -> DeepSeekBilling.Credential {
        try parse(runScript(script(for: browser)), browser: browser)
    }

    /// Internal runner exposed to tests with inert scripts, so pipe handling
    /// and timeout cancellation can be verified without browser access.
    static func runScript(_ source: String, timeout: TimeInterval = 20) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        process.standardInput = FileHandle.nullDevice
        // Script errors can include remote page content. Never surface or log
        // stderr; only the fixed status markers above cross the UI boundary.
        process.standardError = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        try Task.checkCancellation()
        do { try process.run() } catch { throw Failure.failed }
        try? output.fileHandleForWriting.close()
        let fd = output.fileHandleForReading.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
        defer {
            if process.isRunning {
                process.terminate()
                for _ in 0..<10 where process.isRunning { Thread.sleep(forTimeInterval: 0.02) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            process.waitUntilExit()
            try? output.fileHandleForReading.close()
        }
        let deadline = Date().addingTimeInterval(timeout)
        var data = Data()
        var complete = false
        while Date() < deadline {
            try Task.checkCancellation()
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP), revents: 0)
            let ready = poll(&descriptor, 1, 80)
            if ready > 0 {
                var bytes = [UInt8](repeating: 0, count: 4096)
                let count = Darwin.read(fd, &bytes, bytes.count)
                if count > 0 {
                    guard data.count + count <= 65_536 else { throw Failure.failed }
                    data.append(contentsOf: bytes.prefix(count))
                    continue
                }
                if count == 0 { complete = true; break }
            }
            if !process.isRunning { complete = true; break }
        }
        guard complete else { throw Failure.timeout }
        // A script compilation/TCC failure produces no trusted result marker.
        guard !data.isEmpty else { throw Failure.failed }
        return data
    }
}
