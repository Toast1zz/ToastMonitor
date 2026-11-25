import XCTest
import AppKit
@testable import ToastMonitor

@MainActor
final class SettingsWindowTests: XCTestCase {
    /// Opening Settings measures every pane before the window appears; that
    /// pass must not decide which pane opens (it ended on Updates).
    func testFirstOpenRestoresTheLastViewedPane() {
        let controller = SettingsWindowController.shared
        let suiteName = "tm-settings-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        controller.defaults = defaults
        controller.activatesAppOnShow = false
        defer {
            NSApp.windows.first { $0.toolbar?.identifier == "ToastMonitor.Settings" }?.close()
            controller.defaults = .standard
            controller.activatesAppOnShow = true
            defaults.removePersistentDomain(forName: suiteName)
        }

        defaults.set(SettingsPane.sources.rawValue, forKey: "settingsLastPane")
        controller.show()
        let window = NSApp.windows.first { $0.toolbar?.identifier == "ToastMonitor.Settings" }
        XCTAssertEqual(window?.title, SettingsPane.sources.title)
        XCTAssertEqual(defaults.string(forKey: "settingsLastPane"), SettingsPane.sources.rawValue)
        XCTAssertEqual(window?.contentView?.subviews.isEmpty, false)
        window?.close()

        controller.show()
        let reopenedWindow = NSApp.windows.first { $0.toolbar?.identifier == "ToastMonitor.Settings" }
        XCTAssertTrue(reopenedWindow?.isVisible == true)
        XCTAssertEqual(reopenedWindow?.title, SettingsPane.sources.title)
        XCTAssertEqual(reopenedWindow?.contentView?.subviews.isEmpty, false)
        reopenedWindow?.close()
    }
}
