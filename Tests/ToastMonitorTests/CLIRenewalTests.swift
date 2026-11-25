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

    @MainActor
    func testRetrySlowsDownOnlyAfterAnHourOfFailures() {
        let retry = CLIRenewalRetry()
        defer { retry.reset() }
        for _ in 1..<CLIRenewalRetry.failuresBeforeSlowing {
            retry.schedule(counting: true) {}
            XCTAssertEqual(retry.nextDelay, CLIRenewalRetry.defaultInterval)
        }
        retry.schedule(counting: true) {}
        XCTAssertEqual(retry.nextDelay, CLIRenewalRetry.slowInterval)
        retry.reset()
        XCTAssertEqual(retry.nextDelay, CLIRenewalRetry.defaultInterval)
    }

    @MainActor
    func testUnreadableLoginKeepsTheRetryGoing() {
        let retry = CLIRenewalRetry(interval: 0.01)
        let fired = expectation(description: "retried")
        XCTAssertTrue(retry.loginUnreadable(renewing: true, outcome: nil) { fired.fulfill() })
        wait(for: [fired], timeout: 2)
        XCTAssertEqual(retry.failures, 1)
    }

    @MainActor
    func testUnreadableLoginAfterAFirstAttemptStartsTheRetry() {
        let retry = CLIRenewalRetry(interval: 0.01)
        let fired = expectation(description: "retried")
        XCTAssertTrue(retry.loginUnreadable(renewing: false, outcome: .completed) { fired.fulfill() })
        wait(for: [fired], timeout: 2)
    }

    @MainActor
    func testUnreadableLoginIsReportedAfterRepeatedFailures() {
        let retry = CLIRenewalRetry(interval: 60)
        defer { retry.reset() }
        for _ in 1..<CLIRenewalRetry.failuresBeforeReporting {
            XCTAssertTrue(retry.loginUnreadable(renewing: true, outcome: .completed) {})
        }
        XCTAssertFalse(retry.loginUnreadable(renewing: true, outcome: .completed) {})
    }

    @MainActor
    func testMissingLoginOutsideARenewalStartsNoRetry() {
        let retry = CLIRenewalRetry(interval: 0.01)
        let fired = expectation(description: "retried")
        fired.isInverted = true
        XCTAssertFalse(retry.loginUnreadable(renewing: false, outcome: nil) { fired.fulfill() })
        wait(for: [fired], timeout: 0.1)
        XCTAssertEqual(retry.failures, 0)
    }

    func testProbeStopsWhenTheCLIExitsEarly() throws {
        let dir = NSTemporaryDirectory() + "claude-exit-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let script = "\(dir)/claude"
        FileManager.default.createFile(atPath: script, contents: Data("#!/bin/sh\nexit 3\n".utf8),
                                       attributes: [.posixPermissions: 0o755])

        let started = Date()
        XCTAssertEqual(ClaudeCLIRefresher.probe(binary: script, attempt: 0, renewed: nil),
                       .failed("exited with status 3"))
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testProbeOutputSurvivesACutMultibyteCharacter() {
        let line = Array("Logged in ─".utf8)
        XCTAssertTrue(ClaudeCLIRefresher.compact(Array(line.dropLast())).contains("loggedin"))
        XCTAssertTrue(ClaudeCLIRefresher.compact(Array("─ Logged in".utf8).dropFirst().map { $0 }).contains("loggedin"))
    }

    func testUnansweredKeychainReadRestsInsteadOfStoppingForGood() {
        defer { ClaudeQuotaClient.clearSecurityToolBlock() }
        ClaudeQuotaClient.markSecurityToolBlocked(now: 1000)
        XCTAssertTrue(ClaudeQuotaClient.securityToolBlocked(now: 1000 + ClaudeQuotaClient.securityToolRest - 1))
        XCTAssertFalse(ClaudeQuotaClient.securityToolBlocked(now: 1000 + ClaudeQuotaClient.securityToolRest))
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

    @MainActor
    func testClaudeBackgroundRenewalPersistsAcrossPopoverClose() {
        let client = ClaudeQuotaClient(forTestingWithConfiguration: .ephemeral)
        defer { client.setEnabled(false) }

        client.simulateRenewalFailureForTesting(outcome: .failed("probe failed"))
        XCTAssertTrue(client.hasPendingRenewalRetryForTesting)
        XCTAssertEqual(client.renewalFailuresForTesting, 1)
        XCTAssertNil(client.state.error)

        client.setForegroundForTesting(true)
        client.setForegroundForTesting(false)
        XCTAssertTrue(client.hasPendingRenewalRetryForTesting)
        XCTAssertEqual(client.renewalFailuresForTesting, 1)
    }

    @MainActor
    func testClaudeForcedRefreshClearsSecurityToolBlock() {
        final class StubOKProtocol: URLProtocol {
            override class func canInit(with request: URLRequest) -> Bool { true }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
            override func startLoading() {
                let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                               httpVersion: nil, headerFields: nil)!
                let body = Data("{\"five_hour\":{\"utilization\":10},\"seven_day\":{\"utilization\":20}}".utf8)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: body)
                client?.urlProtocolDidFinishLoading(self)
            }
            override func stopLoading() {}
        }

        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubOKProtocol.self]
        let future = Int64(Date().timeIntervalSince1970) + 3600
        let client = ClaudeQuotaClient(
            forTestingWithConfiguration: cfg,
            credentialLoader: { .init(accessToken: "test-tok", expiresAt: future, subscriptionType: "max") }
        )
        defer {
            client.setEnabled(false)
            ClaudeQuotaClient.clearSecurityToolBlock()
        }

        ClaudeQuotaClient.markSecurityToolBlocked(now: Date().timeIntervalSince1970)
        XCTAssertTrue(ClaudeQuotaClient.securityToolBlocked())

        client.refresh(force: true, renewing: false)
        XCTAssertFalse(ClaudeQuotaClient.securityToolBlocked())
    }

    func testProbeWaitsForRenewedCallbackAfterStatusReady() throws {
        let dir = NSTemporaryDirectory() + "claude-status-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let script = "\(dir)/claude"
        let body = """
        #!/bin/sh
        while IFS= read -r line; do
          case "$line" in
            */status*) echo "Logged in" ;;
            */exit*) exit 0 ;;
          esac
        done
        """
        FileManager.default.createFile(atPath: script, contents: Data(body.utf8),
                                       attributes: [.posixPermissions: 0o755])

        let lock = NSLock()
        var checks = 0
        let outcome = ClaudeCLIRefresher.probe(binary: script, attempt: 0) {
            lock.lock()
            defer { lock.unlock() }
            checks += 1
            return checks >= 3
        }
        XCTAssertEqual(outcome, .completed)
    }
}
