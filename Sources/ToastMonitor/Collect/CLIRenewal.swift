import Foundation

/// How a background run of a CLI to renew its login ended.
enum CLIRenewalOutcome: Equatable {
    /// The CLI finished. Callers still re-read the login to see if it renewed.
    case completed
    /// Nothing ran: another attempt started moments ago.
    case throttled
    case failed(String)
}

/// Stops separate triggers (the panel opening, the retry) from stacking up
/// CLI launches. Shorter than the retry interval so the retry always gets in.
final class CLIRenewalGate: @unchecked Sendable {
    static let minInterval: TimeInterval = 45

    private let lock = NSLock()
    private var lastInvoke: TimeInterval = 0

    func begin(now: TimeInterval = Date().timeIntervalSince1970) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard now - lastInvoke >= Self.minInterval else { return false }
        lastInvoke = now
        return true
    }
}

/// Retries a failed login renewal once a minute until it works, whether or
/// not anyone is looking at the numbers. Nothing runs once the login is good.
@MainActor
final class CLIRenewalRetry {
    static let defaultInterval: TimeInterval = 60
    /// A renewal can fail for a moment after waking or upgrading the CLI, so
    /// the row only asks for attention after this many failures in a row.
    static let failuresBeforeReporting = 5

    private let interval: TimeInterval
    private(set) var failures = 0
    private var pending: DispatchWorkItem?

    init(interval: TimeInterval = defaultInterval) {
        self.interval = interval
    }

    var shouldReport: Bool { failures >= Self.failuresBeforeReporting }

    /// A refusal can be the server's mistake. The CLI won't replace a token
    /// that hasn't expired, so ask the server again now and then.
    var shouldRetestRejectedToken: Bool {
        failures > 0 && failures % Self.failuresBeforeReporting == 0
    }

    func schedule(counting: Bool, retry: @escaping @MainActor @Sendable () -> Void) {
        if counting { failures += 1 }
        pending?.cancel()
        let work = DispatchWorkItem { MainActor.assumeIsolated { retry() } }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: work)
    }

    func reset() {
        failures = 0
        pending?.cancel()
        pending = nil
    }
}
