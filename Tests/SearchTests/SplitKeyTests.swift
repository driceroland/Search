import AppKit
import XCTest
@testable import Search

/// ⌥⌘N splits the page on screen, and on a pair puts it apart: the key that
/// made the split takes it away, as ⌘T, ⌘L and ⌘K each put away what they
/// raised (#912). On a pair it used to go to the right-hand page.
@MainActor
final class SplitKeyTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "split-key-\(getpid())", 1)
        super.setUp()
    }

    func testOnOnePageAnEmptyPageComesBeside() throws {
        try withBrowser { browser, tabs in
            browser.select(tabs[1])
            press(browser)
            let pair = try XCTUnwrap(browser.activeSplit, "a pair")
            XCTAssertEqual(pair.left, tabs[1].id)
            XCTAssertTrue(browser.active?.isBlank == true, "the empty page beside it has the keys")
        }
    }

    func testOnAPairItComesApartAndBothStay() throws {
        try withBrowser { browser, tabs in
            browser.pair(tabs[2], with: tabs[1], onLeft: false)
            browser.focusPane(tabs[1])
            press(browser)
            XCTAssertTrue(browser.splits.isEmpty, "apart")
            XCTAssertEqual(browser.tabs.map(\.id), tabs.map(\.id), "both pages stay, in place")
            XCTAssertEqual(browser.activeID, tabs[1].id, "the page that had the keys is on screen")
        }
    }

    func testPressedTwiceIsWhereItStarted() throws {
        try withBrowser { browser, tabs in
            browser.select(tabs[0])
            press(browser)
            XCTAssertNotNil(browser.activeSplit)
            browser.focusPane(tabs[0])
            press(browser)
            XCTAssertNil(browser.activeSplit, "the second press takes the split away")
            XCTAssertEqual(browser.activeID, tabs[0].id)
        }
    }

    func testTwoPickedTabsStillPairOnAPair() throws {
        try withBrowser { browser, tabs in
            browser.pair(tabs[1], with: tabs[0], onLeft: false)
            browser.select(tabs[2])
            browser.extendTabSelection(to: tabs[2], modifiers: .command)
            browser.extendTabSelection(to: tabs[3], modifiers: .command)
            XCTAssertNotNil(browser.pickedPair)
            press(browser)
            let pair = try XCTUnwrap(browser.split(for: tabs[3]), "the picked two side by side")
            XCTAssertEqual(Set(pair.tabs), [tabs[2].id, tabs[3].id])
            XCTAssertNotNil(browser.split(for: tabs[0]), "the other pair is left as it was")
        }
    }

    /// As the key runs it, through its command.
    private func press(_ browser: Browser) {
        guard let command = Command.all.first(where: { $0.id == "tabs.split" }) else {
            return XCTFail("no tabs.split command")
        }
        command.run(browser)
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
        prefs.splitView = true
        for number in 1...4 {
            if number > 1 { browser.newTab() }
            browser.tabs.last?.restore(url: URL(string: "about:blank#\(number)")!, title: "Tab \(number)")
        }
        try body(browser, browser.tabs)
    }
}
