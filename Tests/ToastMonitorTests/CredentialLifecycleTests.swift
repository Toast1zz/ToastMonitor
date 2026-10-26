import XCTest
import Security
@testable import ToastMonitor

final class CredentialResponseProtocol: URLProtocol {
    static var handler: ((CredentialResponseProtocol) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        DispatchQueue.main.async { Self.handler?(self) }
    }
    override func stopLoading() {}

    func respond(_ body: String, status: Int = 200) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

@MainActor
final class CredentialLifecycleTests: XCTestCase {
    private func fixture() -> (Database, URLSessionConfiguration) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tm-credentials-\(UUID().uuidString)")
        let database = Database.testInstance(path: directory.appendingPathComponent("test.db").path)
        KeychainStore.readImpl = { _, _ in (errSecItemNotFound, nil) }
        KeychainStore.writeImpl = { _, _, _ in errSecSuccess }
        KeychainStore.deleteImpl = { _, _ in errSecSuccess }
        addTeardownBlock {
            CredentialResponseProtocol.handler = nil
            KeychainStore.readImpl = nil
            KeychainStore.writeImpl = nil
            KeychainStore.deleteImpl = nil
            database.close()
            try? FileManager.default.removeItem(at: directory)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CredentialResponseProtocol.self]
        return (database, configuration)
    }

    private func wait(_ condition: @escaping () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Condition timed out")
        throw URLError(.timedOut)
    }

    func testOpenRouterEmptyCacheCanRefreshAfterSavingKey() async throws {
        let (database, configuration) = fixture()
        var requests = 0
        CredentialResponseProtocol.handler = { request in
            requests += 1
            request.respond(#"{"data":{"usage":12}}"#)
        }
        let client = OpenRouterClient(configuration: configuration, database: database)
        client.refresh()
        try await wait { client.state.error != nil }
        XCTAssertTrue(client.setKey("sk-test-new"))
        try await wait { requests > 0 }
        try await wait { !client.state.isLoading }
    }

    func testOpenRouterReplacingKeyDiscardsOldResponse() async throws {
        let (database, configuration) = fixture()
        var pending: [CredentialResponseProtocol] = []
        CredentialResponseProtocol.handler = { request in
            if request.request.url?.path == "/api/v1/key" { pending.append(request) }
            else { request.respond(#"{"data":{"total_credits":100,"total_usage":0}}"#) }
        }
        let client = OpenRouterClient(configuration: configuration, database: database)
        XCTAssertTrue(client.setKey("sk-test-A"))
        try await wait { pending.count == 1 }
        XCTAssertTrue(client.setKey("sk-test-B"))
        pending[0].respond(#"{"data":{"usage":999}}"#)
        try await wait { pending.count == 2 }
        pending[1].respond(#"{"data":{"usage":22}}"#)
        try await wait { !client.state.isLoading }
        XCTAssertEqual(client.state.usage, 22)
        XCTAssertEqual(pending[1].request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test-B")
    }

    func testOpenRouterClearingKeyDiscardsOldResponse() async throws {
        let (database, configuration) = fixture()
        var pending: CredentialResponseProtocol?
        CredentialResponseProtocol.handler = { request in
            if request.request.url?.path == "/api/v1/key" { pending = request }
            else { request.respond(#"{"data":{}}"#) }
        }
        let client = OpenRouterClient(configuration: configuration, database: database)
        XCTAssertTrue(client.setKey("sk-test-A"))
        try await wait { pending != nil }
        XCTAssertTrue(client.setKey(nil))
        pending?.respond(#"{"data":{"usage":999}}"#)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(client.hasKey)
        XCTAssertEqual(client.state.usage, 0)
        XCTAssertEqual(client.state.error, "API key not configured")
    }

    func testOpenRouterDeleteFailureKeepsConfiguredKeyAndError() {
        let (database, configuration) = fixture()
        CredentialResponseProtocol.handler = { $0.respond(#"{"data":{"usage":0}}"#) }
        let client = OpenRouterClient(configuration: configuration, database: database)
        XCTAssertTrue(client.setKey("sk-test-A"))
        KeychainStore.deleteImpl = { _, _ in errSecAuthFailed }
        XCTAssertFalse(client.setKey(nil))
        XCTAssertTrue(client.hasKey)
        XCTAssertEqual(client.state.error, "Keychain delete failed — API key still stored")
    }
    func testKeychainDeletionTreatsMissingItemsAsSuccess() {
        _ = fixture()
        KeychainStore.deleteImpl = { _, _ in errSecItemNotFound }
        XCTAssertTrue(KeychainStore.delete(account: "test-only"))
        KeychainStore.deleteImpl = { _, _ in errSecAuthFailed }
        XCTAssertFalse(KeychainStore.delete(account: "test-only"))
    }

    func testOpenRouterLateKeyLoadCannotReplaceNewCredentials() async throws {
        let (database, configuration) = fixture()
        let started = expectation(description: "Keychain read started")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        KeychainStore.readImpl = { account, _ in
            if account == "or-keys" {
                started.fulfill()
                _ = release.wait(timeout: .now() + 5)
                return (errSecSuccess, "[\"sk-test-old\"]")
            }
            return (errSecItemNotFound, nil)
        }
        var keys: [String] = []
        CredentialResponseProtocol.handler = { request in
            if request.request.url?.path == "/api/v1/key" {
                keys.append(request.request.value(forHTTPHeaderField: "Authorization") ?? "")
                request.respond(#"{"data":{"usage":22}}"#)
            } else { request.respond(#"{"data":{}}"#) }
        }
        let client = OpenRouterClient(configuration: configuration, database: database)
        client.refresh()
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(client.setKey("sk-test-new"))
        try await wait { client.state.usage == 22 }
        release.signal()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(keys, ["Bearer sk-test-new"])
        XCTAssertEqual(client.state.usage, 22)
    }

    func testGoClearDiscardsPendingResponse() async throws {
        let (database, configuration) = fixture()
        var pending: CredentialResponseProtocol?
        CredentialResponseProtocol.handler = { pending = $0 }
        let client = OpenCodeGoClient(configuration: configuration, database: database)
        XCTAssertTrue(client.provision(workspaceId: "test-workspace", cookie: "test-cookie"))
        client.refresh()
        try await wait { pending != nil }
        client.clear()
        pending?.respond("failure", status: 500)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(client.configured)
        XCTAssertEqual(client.state.error, "Not configured")
        XCTAssertFalse(client.state.isLoading)
    }

    func testGoDeleteFailureKeepsConfiguredCredentials() {
        let (database, configuration) = fixture()
        let client = OpenCodeGoClient(configuration: configuration, database: database)
        XCTAssertTrue(client.provision(workspaceId: "test-workspace", cookie: "test-cookie"))
        KeychainStore.deleteImpl = { _, _ in errSecAuthFailed }
        client.clear()
        XCTAssertTrue(client.configured)
        XCTAssertTrue(client.state.error?.contains("Keychain delete failed") == true)
    }

    func testGoLateCredentialReadCannotReplaceProvisionedCredentials() async throws {
        let (database, configuration) = fixture()
        let started = expectation(description: "Go credential read started")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        KeychainStore.readImpl = { account, _ in
            if account == "go-workspace-id" {
                if !Thread.isMainThread {
                    started.fulfill()
                    _ = release.wait(timeout: .now() + 5)
                }
                return (errSecSuccess, "old-workspace")
            }
            return (errSecSuccess, "old-cookie")
        }
        var paths: [String] = []
        CredentialResponseProtocol.handler = { request in
            paths.append(request.request.url!.path)
            request.respond("failure", status: 500)
        }
        let client = OpenCodeGoClient(configuration: configuration, database: database)
        client.refresh()
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(client.provision(workspaceId: "new-workspace", cookie: "new-cookie"))
        client.refresh()
        release.signal()
        try await wait { !paths.isEmpty }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(paths, ["/workspace/new-workspace/go"])
    }

    func testCommandCodeClearDiscardsPendingResponse() async throws {
        let (_, configuration) = fixture()
        KeychainStore.readImpl = { _, _ in (errSecSuccess, "test-cookie") }
        var pending: [CredentialResponseProtocol] = []
        CredentialResponseProtocol.handler = { pending.append($0) }
        let client = CommandCodeQuotaClient(configuration: configuration)
        XCTAssertTrue(client.provision(cookie: "test-cookie"))
        try await wait { pending.count == 2 }
        client.clear()
        for request in pending { request.respond("failure", status: 500) }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(client.state.configured)
        XCTAssertEqual(client.state.error, "Not configured")
        XCTAssertFalse(client.state.isLoading)
    }

    func testCommandCodeDeleteFailureKeepsConfiguredCookie() {
        let (_, configuration) = fixture()
        CredentialResponseProtocol.handler = { $0.respond("failure", status: 500) }
        let client = CommandCodeQuotaClient(configuration: configuration)
        XCTAssertTrue(client.provision(cookie: "test-cookie"))
        KeychainStore.deleteImpl = { _, _ in errSecAuthFailed }
        client.clear()
        XCTAssertTrue(client.state.configured)
        XCTAssertTrue(client.state.error?.contains("Keychain delete failed") == true)
    }

    func testCommandCodeLateCookieReadCannotReplaceProvisionedCookie() async throws {
        let (_, configuration) = fixture()
        let started = expectation(description: "Command Code cookie read started")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let lock = NSLock()
        var storedCookie = "old-cookie"
        var firstRead = true
        KeychainStore.readImpl = { _, _ in
            let snapshot = lock.withLock { () -> (String, Bool) in
                let snapshot = (storedCookie, firstRead)
                firstRead = false
                return snapshot
            }
            if snapshot.1 {
                started.fulfill()
                _ = release.wait(timeout: .now() + 5)
            }
            return (errSecSuccess, snapshot.0)
        }
        KeychainStore.writeImpl = { value, _, _ in
            lock.withLock { storedCookie = value }
            return errSecSuccess
        }
        var cookies: [String] = []
        CredentialResponseProtocol.handler = { request in
            cookies.append(request.request.value(forHTTPHeaderField: "Cookie") ?? "")
            request.respond("failure", status: 500)
        }
        let client = CommandCodeQuotaClient(configuration: configuration)
        client.refresh()
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(client.provision(cookie: "new-cookie"))
        release.signal()
        try await wait { cookies.count == 2 }
        XCTAssertEqual(Set(cookies), ["__Secure-commandcode_prod_.session_token=new-cookie"])
    }

    func testCommandCodeRefreshReadsUpdatedStoredCookie() async throws {
        let (_, configuration) = fixture()
        let lock = NSLock()
        var stored = "cookie=A"
        KeychainStore.readImpl = { _, _ in
            lock.lock(); defer { lock.unlock() }
            return (errSecSuccess, stored)
        }
        var cookies: [String] = []
        CredentialResponseProtocol.handler = { request in
            cookies.append(request.request.value(forHTTPHeaderField: "Cookie") ?? "")
            request.respond(request.request.url!.path.hasSuffix("credits")
                ? #"{"credits":{"monthlyCredits":10}}"# : #"{"success":true,"data":null}"#)
        }
        let client = CommandCodeQuotaClient(configuration: configuration)
        XCTAssertTrue(client.provision(cookie: "cookie=A"))
        try await wait { cookies.count == 2 && !client.state.isLoading }
        lock.withLock { stored = "cookie=B" }
        client.refresh()
        try await wait { cookies.count == 4 && !client.state.isLoading }
        XCTAssertEqual(Array(cookies.suffix(2)), ["cookie=B", "cookie=B"])
    }

}
