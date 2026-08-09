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
}
