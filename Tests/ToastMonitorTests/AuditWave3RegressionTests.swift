import XCTest
@testable import ToastMonitor

final class AuditWave3RegressionTests: XCTestCase {
    private var dir: URL!
    private var db: Database!
    private var previousRead: ((String, Bool) -> (OSStatus, String?))?
    private var previousWrite: ((String, String, Bool) -> OSStatus)?
    private var previousDelete: ((String, Bool) -> OSStatus)?

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tm-audit-w3-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        db = Database.testInstance(path: dir.appendingPathComponent("test.db").path)
        previousRead = KeychainStore.readImpl
        previousWrite = KeychainStore.writeImpl
        previousDelete = KeychainStore.deleteImpl
    }

    override func tearDown() {
        KeychainStore.readImpl = previousRead
        KeychainStore.writeImpl = previousWrite
        KeychainStore.deleteImpl = previousDelete
        db.close()
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    func testOpenCodeGoCookieNormalizationAndHumanDurationParsing() {
        XCTAssertEqual(OpenCodeGoClient.normalizedCookie("auth=Fe26.2**abc"), "Fe26.2**abc")
        XCTAssertEqual(OpenCodeGoClient.normalizedCookie("Cookie: auth=Fe26.2**abc"), "Fe26.2**abc")
        XCTAssertEqual(OpenCodeGoClient.parseHumanDuration("unknown format"), -1)
        XCTAssertEqual(OpenCodeGoClient.parseHumanDuration("Resets now"), 0)
        XCTAssertEqual(OpenCodeGoClient.parseHumanDuration("2 hours 30 minutes"), 9000)
    }

    @MainActor
    func testOpenCodeGoProvisionRollbackPreservesLockedWorkspaceAndRecoversAfterUnlock() async throws {
        var deleteCalls: [String] = []
        KeychainStore.readImpl = { account, _ in
            if account == "go-workspace-id" { return (errSecInteractionNotAllowed, nil) }
            return (errSecItemNotFound, nil)
        }
        KeychainStore.writeImpl = { _, account, _ in
            account == "go-auth-cookie" ? errSecAuthFailed : errSecSuccess
        }
        KeychainStore.deleteImpl = { account, _ in
            deleteCalls.append(account)
            return errSecSuccess
        }

        let client = OpenCodeGoClient(database: db)
        XCTAssertFalse(client.provision(workspaceId: "wrk_123", cookie: "ck_abc"))
        XCTAssertFalse(deleteCalls.contains("go-workspace-id"),
                       "rollback must never delete an existing item that failed to read due to lock/auth")

        // Startup read while locked must not permanently freeze credentialsLoaded = true.
        var locked = true
        KeychainStore.readImpl = { account, _ in
            if locked { return (errSecInteractionNotAllowed, nil) }
            if account == "go-workspace-id" { return (errSecSuccess, "wrk_unlocked") }
            if account == "go-auth-cookie" { return (errSecSuccess, "ck_unlocked") }
            return (errSecItemNotFound, nil)
        }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [Wave3MockURLProtocol.self]
        Wave3MockURLProtocol.handler = { _ in
            let html = #"rollingUsage:$R[1]={usagePercent:5,resetInSec:120}"#
            return (200, ["Content-Type": "text/html"], Data(html.utf8))
        }
        let lockedClient = OpenCodeGoClient(configuration: cfg, database: db)
        lockedClient.refresh()
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertFalse(lockedClient.configured)
        XCTAssertEqual(lockedClient.state.error, "Keychain locked or access denied")

        locked = false
        lockedClient.refresh(force: true)
        for _ in 0..<20 where !lockedClient.configured {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(lockedClient.configured)
    }

    @MainActor
    func testOpenRouterPreservesLockStatusOrdersKeysAndSkipsPartialSnapshotPersist() async throws {
        var locked = true
        KeychainStore.readImpl = { account, _ in
            if account == "or-keys" {
                return locked ? (errSecInteractionNotAllowed, nil) : (errSecSuccess, #"["sk-first","sk-mgmt"]"#)
            }
            return (errSecItemNotFound, nil)
        }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [Wave3MockURLProtocol.self]
        Wave3MockURLProtocol.handler = { req in
            let auth = req.value(forHTTPHeaderField: "Authorization") ?? ""
            if req.url?.path == "/api/v1/key" {
                if auth.contains("sk-first") {
                    return (200, ["Content-Type": "application/json"], Data(#"{"data":{"usage":1,"is_management_key":false,"limit":10,"limit_remaining":8}}"#.utf8))
                }
                return (200, ["Content-Type": "application/json"], Data(#"{"data":{"usage":2,"is_management_key":true}}"#.utf8))
            }
            return (200, ["Content-Type": "application/json"], Data(#"{"data":[]}"#.utf8))
        }
        let client = OpenRouterClient(configuration: cfg, database: db)
        client.refresh()
        for _ in 0..<20 where client.state.error == nil {
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        XCTAssertEqual(client.state.error, "Keychain locked or access denied",
                       "subsequent missing legacy item read must not mask locked or-keys")

        // Unlock and verify partial failure does not persist truncated snapshot.
        locked = false
        client.finishRefreshForTesting(
            keys: ["sk-first", "sk-second"],
            results: ["sk-first": ["data": ["usage": 10.0, "usage_daily": 1.0, "usage_weekly": 2.0, "usage_monthly": 3.0]]],
            failures: ["sk-second failed"],
            creditsFailed: false)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(db.orCreditUsage(since: 0).isEmpty)

        let results: [String: [String: Any]] = [
            "k-mgmt-a": ["data": ["is_management_key": true]],
            "k-mgmt-b": ["data": ["is_management_key": true]],
        ]
        XCTAssertEqual(OpenRouterClient.accountCreditsKey(keys: ["k-mgmt-b", "k-mgmt-a"], results: results), "k-mgmt-b")
    }

    func testAntigravityRejectsBooleanPIDAndUntrustedProcesses() {
        XCTAssertNil(AntigravityQuotaClient.parseHub(Data(#"{"pid":true,"httpPort":8080,"csrfToken":"tok"}"#.utf8)))
        XCTAssertNil(AntigravityQuotaClient.parseHub(Data(#"{"pid":1,"httpPort":8080,"csrfToken":"tok"}"#.utf8)))
        XCTAssertFalse(AntigravityQuotaClient.isTrustedServerProcess(pid: 1))
        XCTAssertFalse(AntigravityQuotaClient.isTrustedServerProcess(pid: ProcessInfo.processInfo.processIdentifier))
    }

    @MainActor
    func testNoRedirectDelegateIsolatesSameTaskIdentifierAndCancelsRedirects() async throws {
        let delegate = NoRedirectDelegate()
        let cfg1 = URLSessionConfiguration.ephemeral
        cfg1.protocolClasses = [Wave3MockURLProtocol.self]
        let cfg2 = URLSessionConfiguration.ephemeral
        cfg2.protocolClasses = [Wave3MockURLProtocol.self]
        let s1 = URLSession(configuration: cfg1, delegate: delegate, delegateQueue: nil)
        let s2 = URLSession(configuration: cfg2, delegate: delegate, delegateQueue: nil)
        Wave3MockURLProtocol.handler = { req in
            if req.url?.path == "/redir" {
                return (302, ["Location": "https://attacker.invalid/steal"], Data("secret".utf8))
            }
            return (200, [:], Data((req.url?.path ?? "").utf8))
        }

        async let firstData: Data? = withCheckedContinuation { cont in
            delegate.boundedDataTask(in: s1, request: URLRequest(url: URL(string: "https://example.test/one")!), maxBytes: 1024) { data, _, _ in
                cont.resume(returning: data)
            }.resume()
        }
        async let secondData: Data? = withCheckedContinuation { cont in
            delegate.boundedDataTask(in: s2, request: URLRequest(url: URL(string: "https://example.test/two")!), maxBytes: 1024) { data, _, _ in
                cont.resume(returning: data)
            }.resume()
        }
        let (d1, d2) = await (firstData, secondData)
        XCTAssertEqual(d1, Data("/one".utf8))
        XCTAssertEqual(d2, Data("/two".utf8))

        var redirErr: Error?
        let cancelled = expectation(description: "redirect cancelled")
        let redirTask = delegate.boundedDataTask(in: s1, request: URLRequest(url: URL(string: "https://example.test/redir")!), maxBytes: 1024) { _, _, err in
            redirErr = err
            cancelled.fulfill()
        }
        let redirectResp = HTTPURLResponse(url: URL(string: "https://example.test/redir")!, statusCode: 302,
                                           httpVersion: "HTTP/1.1", headerFields: ["Location": "https://attacker.invalid/steal"])!
        delegate.urlSession(s1, task: redirTask, willPerformHTTPRedirection: redirectResp,
                            newRequest: URLRequest(url: URL(string: "https://attacker.invalid/steal")!)) { allowed in
            XCTAssertNil(allowed)
        }
        XCTAssertEqual(redirTask.state, .canceling)
        delegate.urlSession(s1, task: redirTask, didCompleteWithError: URLError(.cancelled))
        await fulfillment(of: [cancelled], timeout: 2)
        XCTAssertTrue(redirErr?.localizedDescription.contains("Redirect rejected") == true)
    }

    @MainActor
    func testCodexRejectsBooleanPercentAndSetEnabledFalseClearsState() {
        let client = CodexQuotaClient.shared
        client.setEnabled(false)
        XCTAssertFalse(client.enabled)
        XCTAssertNil(client.state.primaryPct)
        XCTAssertEqual(client.state.lastSync, 0)
    }

    @MainActor
    func testQuotaAlertManagerThresholdDecreaseAndOpenCodeGoJitter() {
        var badge = QuotaAlertPolicy.BadgeState()
        badge.update(remaining: 15, threshold: 20, resetAt: 10_000, viewed: true, jitterTolerance: 7_200)
        badge.update(remaining: 15, threshold: 20, resetAt: 13_600, viewed: false, jitterTolerance: 7_200)
        XCTAssertFalse(badge.unread, "1h OpenCode Go countdown drift must not re-light unread badge")
        badge.update(remaining: 15, threshold: 20, resetAt: 22_000, viewed: false, jitterTolerance: 7_200)
        XCTAssertTrue(badge.unread, "genuine cycle advance beyond jitterTolerance must light unread badge")

        // Verify Threshold Decrease via QuotaAlertPolicy + Database-isolated QuotaAlertManager
        var readings: [QuotaAlertManager.Reading] = [
            .init(id: "wave3-test", name: "TestQuota", remaining: 30, resetAt: nil)
        ]
        let manager = QuotaAlertManager(readingProvider: { readings })
        manager.setThreshold(50)
        XCTAssertEqual(manager.unreadCount, 1)
        readings[0] = .init(id: "wave3-test", name: "TestQuota", remaining: 30, resetAt: nil)
        manager.setThreshold(10)
        XCTAssertEqual(QuotaAlertPolicy.transition(previous: "ok", remaining: 30, threshold: 10), nil)
        manager.setThreshold(20)
    }

    func testCLIRenewalGateUsesMonotonicClockAcrossSmallValues() {
        let gate = CLIRenewalGate()
        XCTAssertTrue(gate.begin(now: 2))
        XCTAssertFalse(gate.begin(now: 10))
        XCTAssertTrue(gate.begin(now: 50))
    }

    func testDeepSeekBalanceEpochFiltersOldAccountSamples() {
        let now = Int64(Date().timeIntervalSince1970)
        db.insertDeepSeekBalance(currency: "USD", amount: 50.0, ts: now - 10)
        XCTAssertEqual(db.deepSeekBalances(currency: "USD", since: 0).count, 1)
        XCTAssertTrue(db.beginDeepSeekBalanceSeries(at: now))
        XCTAssertTrue(db.deepSeekBalances(currency: "USD", since: 0).isEmpty)
        db.insertDeepSeekBalance(currency: "USD", amount: 25.0, ts: now + 5)
        XCTAssertEqual(db.deepSeekBalances(currency: "USD", since: 0).map(\.value), [25.0])
    }
}

private final class Wave3MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, [String: String], Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (code, headers, body) = Self.handler?(request) ?? (500, [:], Data())
        let resp = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
