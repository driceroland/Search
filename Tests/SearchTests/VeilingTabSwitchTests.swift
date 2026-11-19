import AppKit
import XCTest
@testable import Search

@MainActor
final class VeilingTabSwitchTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "veiling-tab-switch-\(getpid())", 1)
        super.setUp()
    }

    func testGoingToAnotherTabPutsThePickerAway() {
        withBrowser { browser, tabs in
            browser.select(tabs[0])
            browser.toggleHiding()
            XCTAssertTrue(browser.veiling)

            browser.select(tabs[1])
            XCTAssertFalse(browser.veiling)

            browser.toggleHiding()
            XCTAssertTrue(browser.veiling)
        }
    }

    func testOnlyThePickingTabEndsThePicking() {
        withBrowser { browser, tabs in
            browser.select(tabs[0])
            browser.toggleHiding()
            browser.select(tabs[1])
            browser.toggleHiding()

            tabs[0].pickingEnded()
            XCTAssertTrue(browser.veiling)

            tabs[1].pickingEnded()
            XCTAssertFalse(browser.veiling)
        }
    }

    private func withBrowser(_ body: (Browser, [Tab]) throws -> Void) rethrows {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let browser = Browser(record: WindowRecord())
        let prefs = browser.prefs
        let saved = (prefs.usesTabGroups, prefs.splitView)
        defer {
            browser.closeAll()
            prefs.usesTabGroups = saved.0
            prefs.splitView = saved.1
        }
        prefs.usesTabGroups = false
        prefs.splitView = false
        for number in 1...2 {
            if number > 1 { browser.newTab() }
            browser.tabs.last?.restore(url: URL(string: "about:blank#\(number)")!, title: "Tab \(number)")
        }
        try body(browser, browser.tabs)
    }
}
