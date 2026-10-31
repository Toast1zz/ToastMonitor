import XCTest
@testable import ToastMonitor

final class CLIRenewalTests: XCTestCase {
    func testGateAllowsOneRunPerInterval() {
        let gate = CLIRenewalGate()
        XCTAssertTrue(gate.begin(now: 1000))
        XCTAssertFalse(gate.begin(now: 1000 + CLIRenewalGate.minInterval - 1))
        XCTAssertTrue(gate.begin(now: 1000 + CLIRenewalGate.minInterval))
    }

    func testGateLetsTheOneMinuteRetryThrough() {
        XCTAssertLessThan(CLIRenewalGate.minInterval, CLIRenewalRetry.defaultInterval)
    }

    @MainActor
    func testRetryKeepsFiringUntilReset() {
        let retry = CLIRenewalRetry(interval: 0.01)
        let fired = expectation(description: "retried")
        retry.schedule(counting: true) { fired.fulfill() }
        wait(for: [fired], timeout: 2)
        XCTAssertEqual(retry.failures, 1)
    }

    @MainActor
    func testResetCancelsThePendingRetry() {
        let retry = CLIRenewalRetry(interval: 0.01)
        let fired = expectation(description: "retried")
        fired.isInverted = true
        retry.schedule(counting: true) { fired.fulfill() }
        retry.reset()
        wait(for: [fired], timeout: 0.1)
        XCTAssertEqual(retry.failures, 0)
    }

    @MainActor
    func testProblemIsReportedOnlyAfterRepeatedFailures() {
        let retry = CLIRenewalRetry(interval: 60)
        defer { retry.reset() }
        for _ in 1..<CLIRenewalRetry.failuresBeforeReporting {
            retry.schedule(counting: true) {}
            XCTAssertFalse(retry.shouldReport)
        }
        retry.schedule(counting: true) {}
        XCTAssertTrue(retry.shouldReport)
    }

    @MainActor
    func testThrottledRunIsNotAFailure() {
        let retry = CLIRenewalRetry(interval: 60)
        defer { retry.reset() }
        retry.schedule(counting: false) {}
        XCTAssertEqual(retry.failures, 0)
    }

    @MainActor
    func testRejectedTokenIsRetestedPeriodically() {
        let retry = CLIRenewalRetry(interval: 60)
        defer { retry.reset() }
        XCTAssertFalse(retry.shouldRetestRejectedToken)
        for _ in 1..<CLIRenewalRetry.failuresBeforeReporting {
            retry.schedule(counting: true) {}
            XCTAssertFalse(retry.shouldRetestRejectedToken)
        }
        retry.schedule(counting: true) {}
        XCTAssertTrue(retry.shouldRetestRejectedToken)
    }

    func testClaudeRenewsAnExpiredOrRejectedToken() {
        let valid = ClaudeQuotaClient.Credentials(accessToken: "a", expiresAt: 2000, subscriptionType: nil)
        let expired = ClaudeQuotaClient.Credentials(accessToken: "a", expiresAt: 1000, subscriptionType: nil)
        XCTAssertFalse(ClaudeQuotaClient.needsRenewal(valid, rejectedToken: nil, now: 1500))
        XCTAssertTrue(ClaudeQuotaClient.needsRenewal(expired, rejectedToken: nil, now: 1500))
        XCTAssertTrue(ClaudeQuotaClient.needsRenewal(valid, rejectedToken: "a", now: 1500))
        // A new login replaced the token the server refused.
        XCTAssertFalse(ClaudeQuotaClient.needsRenewal(valid, rejectedToken: "old", now: 1500))
    }

    func testGrokRenewsAnExpiredOrRejectedToken() {
        let now = Date(timeIntervalSince1970: 1500)
        let valid = GrokQuotaClient.Credentials(accessToken: "a", expiresAt: Date(timeIntervalSince1970: 2000))
        let expired = GrokQuotaClient.Credentials(accessToken: "a", expiresAt: Date(timeIntervalSince1970: 1000))
        XCTAssertFalse(GrokQuotaClient.needsRenewal(valid, rejectedToken: nil, now: now))
        XCTAssertTrue(GrokQuotaClient.needsRenewal(expired, rejectedToken: nil, now: now))
        XCTAssertTrue(GrokQuotaClient.needsRenewal(valid, rejectedToken: "a", now: now))
        XCTAssertFalse(GrokQuotaClient.needsRenewal(valid, rejectedToken: "old", now: now))
    }

    func testFirstClaudeAttemptUsesTheFullStartThenRetriesStayLight() {
        XCTAssertEqual(ClaudeCLIRefresher.arguments(attempt: 0), ["--tools", ""])
        XCTAssertEqual(ClaudeCLIRefresher.arguments(attempt: 1), ["--tools", "", "--strict-mcp-config"])
        XCTAssertEqual(ClaudeCLIRefresher.arguments(attempt: 4), ["--tools", "", "--strict-mcp-config"])
        XCTAssertEqual(ClaudeCLIRefresher.arguments(attempt: 5), ["--tools", ""])
    }

    func testGrokRenewalReportsTheCLIResult() throws {
        let dir = NSTemporaryDirectory() + "grok-renew-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let ok = "\(dir)/ok", bad = "\(dir)/bad"
        FileManager.default.createFile(atPath: ok, contents: Data("#!/bin/sh\nexit 0\n".utf8),
                                       attributes: [.posixPermissions: 0o755])
        FileManager.default.createFile(atPath: bad, contents: Data("#!/bin/sh\nexit 3\n".utf8),
                                       attributes: [.posixPermissions: 0o755])

        XCTAssertEqual(GrokCLIRefresher.run(binary: ok), .completed)
        XCTAssertEqual(GrokCLIRefresher.run(binary: bad), .failed("exit 3"))
    }
}
