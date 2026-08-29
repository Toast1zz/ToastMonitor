import XCTest
@testable import ToastMonitor

final class ClaudeQuotaTests: XCTestCase {

    private func json(_ text: String) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
    }

    func testParsesClaudeCodeCredentialBlob() {
        let data = Data("""
        {"claudeAiOauth":{"accessToken":"sk-ant-oat01-token","refreshToken":"sk-ant-ort01-x",
        "expiresAt":1900000000000,"subscriptionType":"max"}}
        """.utf8)
        let creds = ClaudeQuotaClient.parseCredentials(data)
        XCTAssertEqual(creds?.accessToken, "sk-ant-oat01-token")
        // expiresAt is milliseconds in the blob and seconds in our state.
        XCTAssertEqual(creds?.expiresAt, 1_900_000_000)
        XCTAssertEqual(creds?.subscriptionType, "max")
    }

    func testRejectsCredentialBlobWithoutToken() {
        XCTAssertNil(ClaudeQuotaClient.parseCredentials(Data("{\"claudeAiOauth\":{}}".utf8)))
        XCTAssertNil(ClaudeQuotaClient.parseCredentials(Data("not json".utf8)))
    }

    func testParsesWindowsAndISOResets() {
        let soon = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
        let usage = ClaudeQuotaClient.parseUsage(json("""
        {"five_hour":{"utilization":23,"resets_at":"\(soon)"},
         "seven_day":{"utilization":61,"resets_at":"\(soon)"},
         "seven_day_opus":{"utilization":4,"resets_at":"\(soon)"}}
        """))
        XCTAssertEqual(usage.fiveHour?.usedPercent, 23)
        XCTAssertEqual(usage.sevenDay?.usedPercent, 61)
        XCTAssertEqual(usage.sevenDayOpus?.usedPercent, 4)
        XCTAssertEqual(usage.fiveHour?.label, "5h")
        XCTAssertEqual(usage.sevenDay?.label, "weekly")
        XCTAssertNotNil(usage.fiveHour?.resetAt)
    }

    func testAcceptsAlternateSpellingsAndNesting() {
        let usage = ClaudeQuotaClient.parseUsage(json("""
        {"rate_limits":{"fiveHour":{"used_percent":10},"sevenDay":{"percent_used":20}}}
        """))
        XCTAssertEqual(usage.fiveHour?.usedPercent, 10)
        XCTAssertEqual(usage.sevenDay?.usedPercent, 20)
    }

    func testUnknownShapeYieldsNoWindows() {
        let usage = ClaudeQuotaClient.parseUsage(json("""
        {"something_else":{"utilization":50}}
        """))
        XCTAssertNil(usage.fiveHour)
        XCTAssertNil(usage.sevenDay)
        XCTAssertNil(usage.sevenDayOpus)
    }

    func testOutOfRangePercentIsRejectedNotClamped() {
        let usage = ClaudeQuotaClient.parseUsage(json("""
        {"five_hour":{"utilization":140},"seven_day":{"utilization":-1}}
        """))
        XCTAssertNil(usage.fiveHour)
        XCTAssertNil(usage.sevenDay)
    }

    func testHasCriticalSecondaryWindowFlagsALowFiveHourWindow() {
        var state = ClaudeQuotaClient.State()
        state.fiveHour = .init(label: "5h", usedPercent: 88, resetAt: nil)
        state.sevenDay = .init(label: "weekly", usedPercent: 12, resetAt: nil)
        XCTAssertTrue(state.hasCriticalSecondaryWindow)
    }

    func testHasCriticalSecondaryWindowIsFalseWhenBothWindowsAreHealthy() {
        var state = ClaudeQuotaClient.State()
        state.fiveHour = .init(label: "5h", usedPercent: 12, resetAt: nil)
        state.sevenDay = .init(label: "weekly", usedPercent: 40, resetAt: nil)
        XCTAssertFalse(state.hasCriticalSecondaryWindow)
    }

    func testHasCriticalSecondaryWindowIsFalseWithoutAnyWindow() {
        XCTAssertFalse(ClaudeQuotaClient.State().hasCriticalSecondaryWindow)
    }

    /// Field names as returned by the live endpoint on 2026-08-25 (verified
    /// against a real account) — top-level windows, no wrapper object,
    /// microsecond-precision ISO-8601 resets, unused windows sent as null.
    func testParsesRealUsageEndpointShape() {
        let usage = ClaudeQuotaClient.parseUsage(json("""
        {"five_hour":{"utilization":13.0,"resets_at":"2026-08-25T10:19:59.736833+00:00"},
         "seven_day":{"utilization":3.0,"resets_at":"2026-08-29T14:59:59.736856+00:00"},
         "seven_day_opus":null}
        """))
        XCTAssertEqual(usage.fiveHour?.usedPercent, 13)
        XCTAssertEqual(usage.sevenDay?.usedPercent, 3)
        XCTAssertNil(usage.sevenDayOpus)
        XCTAssertNotNil(usage.fiveHour?.resetAt)
    }

    // MARK: - Backoff / Retry-After

    func testParseRetryAfterAcceptsSeconds() {
        XCTAssertEqual(ClaudeQuotaClient.parseRetryAfter("30"), 30)
    }

    func testParseRetryAfterAcceptsHTTPDate() {
        let future = Date().addingTimeInterval(120)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let header = formatter.string(from: future)
        let parsed = ClaudeQuotaClient.parseRetryAfter(header)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed!, 120, accuracy: 2)
    }

    func testParseRetryAfterRejectsGarbage() {
        XCTAssertNil(ClaudeQuotaClient.parseRetryAfter("not-a-value"))
        XCTAssertNil(ClaudeQuotaClient.parseRetryAfter(nil))
        XCTAssertNil(ClaudeQuotaClient.parseRetryAfter(""))
    }

    /// Anthropic has been observed sending "0" (no real guidance). That must
    /// not become an immediate retry — computeBackoffDelay should fall
    /// through to the exponential schedule exactly as if no header were sent.
    func testZeroRetryAfterFallsThroughToExponentialBackoff() {
        let withZeroHeader = ClaudeQuotaClient.computeBackoffDelay(attempt: 1, retryAfterHeader: "0")
        let withNoHeader = ClaudeQuotaClient.computeBackoffDelay(attempt: 1, retryAfterHeader: nil)
        // Both land in the same exponential range (2.5s...5s for attempt 1);
        // a real Retry-After: 0 would instead produce ~0s, which this rules out.
        XCTAssertGreaterThan(withZeroHeader, 1)
        XCTAssertGreaterThan(withNoHeader, 1)
    }

    func testPositiveRetryAfterDrivesDelayWithSmallJitter() {
        let delay = ClaudeQuotaClient.computeBackoffDelay(attempt: 1, retryAfterHeader: "60")
        // 60s plus at most a 10%-capped-at-5s jitter.
        XCTAssertGreaterThanOrEqual(delay, 60)
        XCTAssertLessThanOrEqual(delay, 65)
    }

    func testExponentialBackoffGrowsWithAttemptAndCapsAtFiveMinutes() {
        let early = ClaudeQuotaClient.computeBackoffDelay(attempt: 1, retryAfterHeader: nil)
        let late = ClaudeQuotaClient.computeBackoffDelay(attempt: 20, retryAfterHeader: nil)
        XCTAssertLessThan(early, late)
        XCTAssertLessThanOrEqual(late, 300)
    }

    func testExponentialBackoffNeverExceedsCapEvenAtAttemptOne() {
        for _ in 0..<50 {
            let delay = ClaudeQuotaClient.computeBackoffDelay(attempt: 1, retryAfterHeader: nil)
            XCTAssertGreaterThanOrEqual(delay, 0)
            XCTAssertLessThanOrEqual(delay, 300)
        }
    }

    // MARK: - Credential read (never interactive)

    /// The guard that replaced kSecUseAuthenticationUIFail is process-wide,
    /// so the thing that matters is that it always hands the switch back —
    /// otherwise the `--provision-*` CLI paths, which are supposed to be able
    /// to prompt, would go silently deaf after the first background refresh.
    func testWithoutUserInteractionRestoresTheProcessWideSwitch() {
        var before: DarwinBoolean = false
        XCTAssertEqual(SecKeychainGetUserInteractionAllowed(&before), errSecSuccess)

        let observed: DarwinBoolean = KeychainStore.withoutUserInteraction {
            var inside: DarwinBoolean = true
            XCTAssertEqual(SecKeychainGetUserInteractionAllowed(&inside), errSecSuccess)
            return inside
        }
        XCTAssertFalse(observed.boolValue, "interaction must be off inside the body")

        var after: DarwinBoolean = false
        XCTAssertEqual(SecKeychainGetUserInteractionAllowed(&after), errSecSuccess)
        XCTAssertEqual(after.boolValue, before.boolValue, "previous value must be restored")
    }

    func testWithoutUserInteractionNestsWithoutDeadlockingOrLeakingTheSwitch() {
        var before: DarwinBoolean = false
        XCTAssertEqual(SecKeychainGetUserInteractionAllowed(&before), errSecSuccess)
        // Nested use must not leave the switch off after the outer call.
        KeychainStore.withoutUserInteraction {
            KeychainStore.withoutUserInteraction { }
        }
        var after: DarwinBoolean = true
        XCTAssertEqual(SecKeychainGetUserInteractionAllowed(&after), errSecSuccess)
        XCTAssertEqual(after.boolValue, before.boolValue)
    }

    // MARK: - runCapturing (the /usr/bin/security fallback's plumbing)

    func testRunCapturingReturnsStdout() {
        let result = ClaudeQuotaClient.runCapturing(path: "/bin/echo", arguments: ["hello"],
                                                    timeout: 5, maxBytes: 1024)
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.data.map { String(decoding: $0, as: UTF8.self) }, "hello\n")
    }

    /// A `security` child that outlives the timeout is one parked on a
    /// password sheet. It must be killed, and killed promptly — the whole
    /// point is that the sheet never becomes typeable.
    func testRunCapturingKillsAChildThatOutlivesTheTimeout() {
        let started = Date()
        let result = ClaudeQuotaClient.runCapturing(path: "/bin/sleep", arguments: ["30"],
                                                    timeout: 0.5, maxBytes: 1024)
        XCTAssertTrue(result.timedOut)
        XCTAssertNil(result.data)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "must not wait out the child")
    }

    func testRunCapturingRefusesOversizedOutputRatherThanTruncating() {
        let result = ClaudeQuotaClient.runCapturing(path: "/bin/echo",
                                                    arguments: [String(repeating: "x", count: 200)],
                                                    timeout: 5, maxBytes: 16)
        XCTAssertFalse(result.timedOut)
        XCTAssertNil(result.data)
    }

    func testRunCapturingReportsFailureForNonZeroExitAndMissingBinary() {
        XCTAssertNil(ClaudeQuotaClient.runCapturing(path: "/usr/bin/false", arguments: [],
                                                    timeout: 5, maxBytes: 1024).data)
        XCTAssertNil(ClaudeQuotaClient.runCapturing(path: "/nope/not-a-binary", arguments: [],
                                                    timeout: 5, maxBytes: 1024).data)
    }

    /// The blob `security -w` prints carries a trailing newline that SecItem
    /// never returns; the parser has to cope with both spellings.
    func testParsesCredentialBlobWithTrailingNewline() {
        let blob = "{\"claudeAiOauth\":{\"accessToken\":\"sk-ant-oat01-x\",\"expiresAt\":1900000000000}}\n"
        XCTAssertEqual(ClaudeQuotaClient.parseCredentials(Data(blob.utf8))?.accessToken,
                       "sk-ant-oat01-x")
    }
}
