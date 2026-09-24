import XCTest
import AppKit
@testable import ToastMonitor

@MainActor
final class SettingsWindowTests: XCTestCase {
    /// Opening Settings measures every pane before the window appears; that
    /// pass must not decide which pane opens (it ended on Updates).
    func testFirstOpenRestoresTheLastViewedPane() {
        UserDefaults.standard.set(SettingsPane.sources.rawValue, forKey: "settingsLastPane")
        SettingsWindowController.shared.show()
        let window = NSApp.windows.first { $0.toolbar?.identifier == "ToastMonitor.Settings" }
        XCTAssertEqual(window?.title, SettingsPane.sources.title)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "settingsLastPane"), SettingsPane.sources.rawValue)
        window?.close()
    }
}
