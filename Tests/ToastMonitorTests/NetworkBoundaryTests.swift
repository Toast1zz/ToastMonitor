import XCTest
@testable import ToastMonitor

final class NetworkBoundaryTests: XCTestCase {
    func testHermesFeedAllowlistRejectsPublicHTTPAndCredentialURLs() {
        XCTAssertTrue(HermesRemoteClient.isAllowedFeedURL(URL(string: "https://feed.example.test/usage.json")!))
        XCTAssertTrue(HermesRemoteClient.isAllowedFeedURL(URL(string: "http://100.116.140.74/usage.json")!))
        XCTAssertTrue(HermesRemoteClient.isAllowedFeedURL(URL(string: "http://127.0.0.1:8080/usage.json")!))
        XCTAssertFalse(HermesRemoteClient.isAllowedFeedURL(URL(string: "http://8.8.8.8/usage.json")!))
        XCTAssertFalse(HermesRemoteClient.isAllowedFeedURL(URL(string: "https://user:secret@feed.example.test/usage.json")!))
        XCTAssertFalse(HermesRemoteClient.isAllowedFeedURL(URL(string: "file:///tmp/usage.json")!))
    }

    func testCredentialFieldCapsRemainFinite() {
        XCTAssertGreaterThan(OpenRouterClient.maxAPIKeyLength, 0)
        XCTAssertLessThanOrEqual(OpenRouterClient.maxAPIKeyLength, 4_096)
        XCTAssertGreaterThan(OpenCodeGoClient.maxWorkspaceIDLength, 0)
        XCTAssertGreaterThan(OpenCodeGoClient.maxCookieLength, OpenCodeGoClient.maxWorkspaceIDLength)
    }

    func testAccountCreditsFallsBackToRegularKey() {
        let regular: [String: [String: Any]] = [
            "regular": ["data": ["is_management_key": false]]
        ]
        XCTAssertEqual(
            OpenRouterClient.accountCreditsKey(keys: ["regular"], results: regular),
            "regular")

        let mixed: [String: [String: Any]] = [
            "regular": ["data": ["is_management_key": false]],
            "management": ["data": ["is_management_key": true]]
        ]
        XCTAssertEqual(
            OpenRouterClient.accountCreditsKey(keys: ["regular", "management"], results: mixed),
            "management")
    }

    func testBoundedDelegateRejectsChunkedBodyOverCap() {
        ChunkedPayloadURLProtocol.payload = Data(repeating: 0x61, count: 16)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChunkedPayloadURLProtocol.self]
        let blocker = NoRedirectDelegate()
        let session = URLSession(configuration: configuration,
                                 delegate: blocker, delegateQueue: nil)
        let finished = expectation(description: "bounded response completion")
        let task = blocker.boundedDataTask(
            in: session,
            request: URLRequest(url: URL(string: "https://chunked.test/feed")!),
            maxBytes: 8) { data, _, error in
                XCTAssertNil(data)
                let nsError = error as NSError?
                XCTAssertEqual(nsError?.domain, "ToastMonitor.Network")
                XCTAssertEqual(nsError?.code, 1)
                finished.fulfill()
            }
        task.resume()
        wait(for: [finished], timeout: 2)
        session.invalidateAndCancel()
    }

    // CLIENT-4: a redirect rejected by the delegate must surface as a
    // descriptive "Redirect rejected" error, not a generic -999 cancellation.
    // Driven directly through the delegate (URLProtocol-simulated redirects
    // never complete the task once the redirect is rejected, so the mapping
    // is exercised via the delegate methods themselves).
    func testBoundedDelegateMapsRedirectRejectionToDescriptiveError() {
        let blocker = NoRedirectDelegate()
        let session = URLSession(configuration: .ephemeral, delegate: blocker, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let finished = expectation(description: "redirect rejection completion")
        let task = blocker.boundedDataTask(
            in: session,
            request: URLRequest(url: URL(string: "https://redirect.test/usage")!),
            maxBytes: 1_024) { data, _, error in
                XCTAssertNil(data)
                let nsError = error as NSError?
                XCTAssertEqual(nsError?.domain, "ToastMonitor.Network")
                XCTAssertEqual(nsError?.code, 2)
                XCTAssertEqual(nsError?.localizedDescription,
                               "Redirect rejected (HTTP redirect cancelled)")
                finished.fulfill()
            }
        let httpResponse = HTTPURLResponse(
            url: URL(string: "https://redirect.test/usage")!, statusCode: 302,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": "https://redirected.test/usage.json"])!
        // Exercise the two delegate callbacks URLSession would issue when the
        // redirect is rejected (willPerformHTTPRedirection then a -999
        // cancellation); the task is never resumed.
        blocker.urlSession(session, task: task,
                           willPerformHTTPRedirection: httpResponse,
                           newRequest: URLRequest(url: URL(string: "https://redirected.test/usage.json")!)) { _ in }
        blocker.urlSession(session, task: task, didCompleteWithError: URLError(.cancelled))
        wait(for: [finished], timeout: 2)
    }

    // CLIENT-2: poll() must be callable from the main thread and invoke its
    // completion on the main thread after finishing (all finish paths).
    func testHermesPollCompletionRunsOnMain() {
        let done = expectation(description: "poll completion")
        HermesRemoteClient.shared.poll {
            XCTAssertTrue(Thread.isMainThread,
                          "poll completion must run on the main thread")
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }

    // CLIENT-6a: SolidJS SSR hydration format.
    func testOpenCodeGoParsesSSRHydrationFormat() {
        let html = "<script>self.__ssr={rollingUsage:$R[12]={usagePercent:3,resetInSec:8655},weeklyUsage:$R[13]={usagePercent:10,resetInSec:604799}}</script>"
        let parsed = OpenCodeGoClient.parse(html)
        XCTAssertEqual(parsed?.0?.pct, 3)
        XCTAssertEqual(parsed?.0?.reset, 8_655)
        XCTAssertEqual(parsed?.1?.pct, 10)
        XCTAssertEqual(parsed?.1?.reset, 604_799)
    }

    // CLIENT-6b: data-slot HTML format with a monthly usage item.
    func testOpenCodeGoDataSlotMonthlyFormat() {
        let html = """
        <div data-slot="usage-item">
          <span data-slot="usage-label">monthly usage</span>
          <span data-slot="usage-value">42% used</span>
          <span data-slot="reset-time">Resets in 5 days 3 hours</span>
        </div>
        """
        let parsed = OpenCodeGoClient.parse(html)
        XCTAssertEqual(parsed?.2?.pct, 42)
        XCTAssertEqual(parsed?.2?.reset, Int64(5 * 86_400 + 3 * 3_600))
    }

    // CLIENT-6c: when one usage-item embeds a sibling label block, each label
    // must pair with the value/reset that FOLLOWS it — never the sibling's.
    func testOpenCodeGoDataSlotPairsExactLabelValue() {
        let html = """
        <div data-slot="usage-item">
          <span data-slot="usage-label">weekly usage</span>
          <span data-slot="usage-value">10% used</span>
          <span data-slot="reset-time">Resets in 1 day 2 hours</span>
          <div>
            <span data-slot="usage-label">monthly usage</span>
            <span data-slot="usage-value">42% used</span>
            <span data-slot="reset-time">Resets in 5 days 3 hours</span>
          </div>
        </div>
        """
        let parsed = OpenCodeGoClient.parse(html)
        XCTAssertEqual(parsed?.1?.pct, 10)
        XCTAssertEqual(parsed?.1?.reset, Int64(86_400 + 2 * 3_600))
        // Old code searched the whole item and paired monthly with the
        // weekly item's 10% / 1d2h; the label-anchored search must find 42%.
        XCTAssertEqual(parsed?.2?.pct, 42)
        XCTAssertEqual(parsed?.2?.reset, Int64(5 * 86_400 + 3 * 3_600))
    }

    // CLIENT-5: the remote watermark is diagnostic-only and persists just the
    // timestamp — never "ts:eventID" (the eventID's colons were unparseable).
    func testRemoteWatermarkPersistsTimestampOnly() {
        let tmpPath = NSTemporaryDirectory() + "tm-test-\(UUID().uuidString).db"
        let db = Database.testInstance(path: tmpPath)
        defer {
            db.close()
            let fm = FileManager.default
            try? fm.removeItem(atPath: tmpPath)
            try? fm.removeItem(atPath: tmpPath + "-wal")
            try? fm.removeItem(atPath: tmpPath + "-shm")
        }
        let now = Int64(Date().timeIntervalSince1970)
        XCTAssertTrue(db.setSetting("src_claude", "remote"))
        let row: [String: Any] = [
            "tool": "claude",
            "session_id": "wm-session",
            "model": "claude-3-5-sonnet",
            "last_seen": NSNumber(value: now),
            "first_seen": NSNumber(value: now),
            "input_tokens": NSNumber(value: 10),
            "output_tokens": NSNumber(value: 5),
            "event_id": "wm-event"
        ]
        HermesRemoteClient.shared.importFeed(["rows": [row]], database: db)

        let watermark = db.setting("remote_watermark_claude")
        XCTAssertNotNil(watermark)
        XCTAssertFalse(watermark!.contains(":"),
                       "watermark must not embed a colon-bearing eventID")
        XCTAssertEqual(Int64(watermark!), now,
                       "watermark is just the clamped timestamp")
    }

    // CLIENT-8: the per-poll precomputed remote-source set must skip rows for
    // tools configured local, even when the feed offers them.
    func testRemoteImportSkipsLocallyConfiguredTools() {
        let tmpPath = NSTemporaryDirectory() + "tm-test-\(UUID().uuidString).db"
        let db = Database.testInstance(path: tmpPath)
        defer {
            db.close()
            let fm = FileManager.default
            try? fm.removeItem(atPath: tmpPath)
            try? fm.removeItem(atPath: tmpPath + "-wal")
            try? fm.removeItem(atPath: tmpPath + "-shm")
        }
        let now = Int64(Date().timeIntervalSince1970)
        XCTAssertTrue(db.setSetting("src_claude", "remote"))
        // codex stays at its default "local".
        let rows: [[String: Any]] = [
            ["tool": "claude", "session_id": "s-remote", "model": "claude-3-5-sonnet",
             "last_seen": NSNumber(value: now), "first_seen": NSNumber(value: now),
             "input_tokens": NSNumber(value: 10), "output_tokens": NSNumber(value: 5),
             "event_id": "claude-event"],
            ["tool": "codex", "session_id": "s-local", "model": "gpt-5.6-sol",
             "last_seen": NSNumber(value: now), "first_seen": NSNumber(value: now),
             "input_tokens": NSNumber(value: 20), "output_tokens": NSNumber(value: 7),
             "event_id": "codex-event"]
        ]
        HermesRemoteClient.shared.importFeed(["rows": rows], database: db)

        XCTAssertEqual(db.turns(sessionTool: "claude", sessionID: "s-remote").count, 1)
        XCTAssertEqual(db.turns(sessionTool: "codex", sessionID: "s-local").count, 0,
                       "locally-configured tools must not import remote rows")
        XCTAssertNil(db.setting("remote_watermark_codex"),
                     "no watermark is written for a skipped tool")
    }
}

private final class ChunkedPayloadURLProtocol: URLProtocol {
    static var payload = Data()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let midpoint = Self.payload.count / 2
        client?.urlProtocol(self, didLoad: Self.payload.prefix(midpoint))
        client?.urlProtocol(self, didLoad: Self.payload.suffix(Self.payload.count - midpoint))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
