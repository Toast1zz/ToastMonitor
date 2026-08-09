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
