import XCTest
import SwiftUI
@testable import ToastMonitor

final class DeepSeekBrowserSessionTests: XCTestCase {
    @MainActor func testGoogleAuthenticationIsRoutedToRealBrowser() {
        for newWindow in [true, false] {
            XCTAssertEqual(DeepSeekLoginWebView.route(URL(string: "https://accounts.google.com/o/oauth2/v2/auth?state=example"),
                                                     newWindow: newWindow), .browser)
        }
    }

    @MainActor func testSecondaryDeepSeekWindowDoesNotGetSilentlyDropped() {
        XCTAssertEqual(DeepSeekLoginWebView.route(URL(string: "https://platform.deepseek.com/oauth/google"), newWindow: true), .browser)
        XCTAssertEqual(DeepSeekLoginWebView.route(URL(string: "about:blank"), newWindow: true), .browser)
        XCTAssertEqual(DeepSeekLoginWebView.route(URL(string: "https://platform.deepseek.com/sign_in"), newWindow: false), .allow)
    }

    @MainActor func testBrowserRoutingDoesNotRelaxCredentialOriginBoundary() {
        for string in ["http://accounts.google.com", "https://accounts.google.com.evil.example",
                       "https://platform.deepseek.com.evil.example", "https://user:secret@accounts.google.com",
                       "https://accounts.google.com:8443", "file:///tmp/token", "javascript:alert(1)"] {
            XCTAssertEqual(DeepSeekLoginWebView.route(URL(string: string), newWindow: true), .block)
        }
        XCTAssertFalse(DeepSeekLoginWebView.isPlatformOrigin(URL(string: "https://accounts.google.com")))
    }

    func testScriptsOnlyReadActiveDeepSeekTabAndNeverEnumerateProfiles() {
        for browser in DeepSeekBrowserSession.Browser.allCases {
            let script = DeepSeekBrowserSession.script(for: browser)
            XCTAssertTrue(script.contains("front window"))
            XCTAssertTrue(script.contains("set targetURL to URL of targetTab"))
            XCTAssertTrue(script.contains("location.origin!=='https://platform.deepseek.com'"))
            XCTAssertTrue(script.contains("localStorage.getItem('userToken')"))
            XCTAssertFalse(script.contains("every tab"))
            XCTAssertFalse(script.contains("document.cookie"))
            XCTAssertFalse(script.contains("accounts.google.com"))
            XCTAssertFalse(script.contains("do shell script"))
        }
    }

    func testBrowserStatusMarkersNeverBecomeCredentials() {
        let cases: [(String, DeepSeekBrowserSession.Failure)] = [
            ("__TM_NO_TAB__", .noTab), ("__TM_WRONG_TAB__", .wrongTab),
            ("__TM_NO_SESSION__", .noSession), ("__TM_AUTOMATION_DENIED__", .automationDenied),
            ("__TM_JS_DISABLED__", .javascriptDisabled(.chrome)), ("__TM_FAILED__", .failed),
            ("__TM_INVALID__", .failed), ("", .failed)
        ]
        for (value, expected) in cases {
            XCTAssertThrowsError(try DeepSeekBrowserSession.parse(Data(value.utf8), browser: .chrome)) {
                XCTAssertEqual($0 as? DeepSeekBrowserSession.Failure, expected)
            }
        }
    }

    func testImportedSessionIsValidatedWithoutExposingItInErrors() throws {
        let token = String(repeating: "synthetic-session-", count: 4)
        let raw = Data("{\"value\":\"\(token)\"}\n".utf8)
        let credential = try DeepSeekBrowserSession.parse(raw, browser: .safari)
        XCTAssertEqual(credential.kind, .platform)
        XCTAssertEqual(credential.secret, token)
        let invalid = "private value with spaces and injection"
        XCTAssertThrowsError(try DeepSeekBrowserSession.parse(Data(invalid.utf8), browser: .chrome)) {
            XCTAssertFalse($0.localizedDescription.contains(invalid))
        }
        XCTAssertThrowsError(try DeepSeekBrowserSession.parse(Data(repeating: 65, count: 65_537), browser: .chrome))
    }

    func testRunnerReturnsInertOutputWithoutAnyBrowserAccess() throws {
        let data = try DeepSeekBrowserSession.runScript("return \"__TM_NO_SESSION__\"", timeout: 3)
        XCTAssertEqual(String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), "__TM_NO_SESSION__")
    }

    func testRunnerTimesOutAndStopsItsOwnProcess() {
        let start = Date()
        XCTAssertThrowsError(try DeepSeekBrowserSession.runScript("delay 10", timeout: 0.15)) {
            XCTAssertEqual($0 as? DeepSeekBrowserSession.Failure, .timeout)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    @MainActor func testCompileBrowserScriptsWithoutExecutingOrReadingAnySession() throws {
        guard ProcessInfo.processInfo.environment["TM_DEEPSEEK_BROWSER_COMPILE"] == "1" else {
            throw XCTSkip("Opt in to local AppleScript compilation; scripts are never executed")
        }
        for browser in DeepSeekBrowserSession.Browser.allCases {
            guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.bundleID) != nil else { continue }
            let script = try XCTUnwrap(NSAppleScript(source: DeepSeekBrowserSession.script(for: browser)))
            var error: NSDictionary?
            XCTAssertTrue(script.compileAndReturnError(&error), "Could not compile fixed script for \(browser.rawValue)")
            XCTAssertNil(error)
        }
    }

    @MainActor func testBrowserConnectionViewRendersWithoutLaunchingBrowser() async throws {
        guard let directory = ProcessInfo.processInfo.environment["TM_DEEPSEEK_UI_OUTPUT"] else {
            throw XCTSkip("Opt-in rendered QA")
        }
        _ = NSApplication.shared
        let hosting = NSHostingView(rootView: DeepSeekConnectionView().background(Color(nsColor: .windowBackgroundColor)))
        hosting.appearance = NSAppearance(named: .aqua)
        hosting.frame = NSRect(x: 0, y: 0, width: 700, height: 610)
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 250_000_000)
        let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: folder.appendingPathComponent("deepseek-browser-login.png"), options: .atomic)
    }
}
