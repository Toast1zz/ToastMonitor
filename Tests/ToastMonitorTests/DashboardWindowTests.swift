import XCTest
import AppKit
@testable import ToastMonitor

@MainActor
final class DashboardWindowTests: XCTestCase {
    func testToggleDismissalRestoresSelectedTabAndPostsOneVisibilityChange() {
        let manager = WindowManager.shared
        var visibilityChanges: [Bool] = []
        let observer = NotificationCenter.default.addObserver(
            forName: WindowManager.visibilityNotification,
            object: nil,
            queue: nil
        ) { notification in
            if let visible = notification.object as? Bool {
                visibilityChanges.append(visible)
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        manager.show(tab: .analysis)
        let firstWindow = NSApp.windows.first {
            $0.toolbar?.identifier == "ToastMonitor.DashboardToolbar"
        }
        XCTAssertTrue(firstWindow?.isVisible == true)
        XCTAssertEqual(selectedTab(in: firstWindow), .analysis)

        manager.toggle()
        XCTAssertFalse(firstWindow?.isVisible ?? true)
        XCTAssertEqual(visibilityChanges.filter { !$0 }.count, 1)

        manager.toggle()
        let reopenedWindow = NSApp.windows.first {
            $0.toolbar?.identifier == "ToastMonitor.DashboardToolbar"
        }
        XCTAssertTrue(reopenedWindow?.isVisible == true)
        XCTAssertEqual(selectedTab(in: reopenedWindow), .analysis)
        manager.toggle()
    }

    private func selectedTab(in window: NSWindow?) -> DashboardView.Tab? {
        guard let toolbar = window?.toolbar,
              let tabs = toolbar.items.first(where: {
                  $0.itemIdentifier.rawValue == "ToastMonitor.DashboardTabs"
              }) else { return nil }
        let index: Int
        if let group = tabs as? NSToolbarItemGroup {
            index = group.selectedIndex
        } else if let control = tabs.view as? NSSegmentedControl {
            index = control.selectedSegment
        } else {
            return nil
        }
        guard DashboardView.Tab.allCases.indices.contains(index) else { return nil }
        return DashboardView.Tab.allCases[index]
    }
}
