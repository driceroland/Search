import AppKit
import XCTest
@testable import Search

/// A tab in a group: its cross (and middle click, and the row's menu) closes
/// it in one click, as a loose tab's does (idea 1412). ⌘W's path (closeTab) is
/// untouched: close_in_group.py.
@MainActor
final class GroupCrossClosesTests: XCTestCase {
    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    private func withGroup(_ body: (Browser, Tab, Tab) -> Void) {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let browser = Browser(record: WindowRecord())
        let saved = browser.prefs.usesTabGroups
        defer { browser.closeAll(); browser.prefs.usesTabGroups = saved }
        browser.prefs.usesTabGroups = true
        for number in 1...3 {
            if number > 1 { browser.newTab() }
            browser.tabs.last?.restore(url: URL(string: "https://example.com/\(number)")!, title: "Tab \(number)")
        }
        let group = TabGroup(id: UUID(), name: "Work", collapsed: false)
        browser.tabGroups = [group]
        let (a, b) = (browser.tabs[0], browser.tabs[1])
        a.groupID = group.id
        b.groupID = group.id
        browser.select(browser.tabs[2])
        body(browser, a, b)
    }

    func testTheCrossClosesAGroupedTabAtOnce() {
        withGroup { browser, a, _ in
            XCTAssertNotNil(browser.group(of: a))
            browser.close(a)   // what the row's cross, middle click and menu run
            XCTAssertFalse(browser.tabs.contains { $0.id == a.id }, "gone, not left as a row")
        }
    }
}
