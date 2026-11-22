import AppKit
import XCTest
@testable import Search

/// Pin Tab and Pin Tab as Row on keys of your own: each pins the tab on
/// screen, and on a pinned tab unpins it. With the rows off, the row's
/// pins a square.
@MainActor
final class PinKeyTests: XCTestCase {
    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    func testPinTabPinsASquareAndUnpins() throws {
        try withBrowser(rows: true) { browser, tab in
            press("tabs.pin", browser)
            XCTAssertNotNil(tab.pin)
            XCTAssertFalse(tab.listed, "a square")
            press("tabs.pin", browser)
            XCTAssertNil(tab.pin, "the same key unpins it")
        }
    }

    func testPinTabAsRowPinsARowAndUnpins() throws {
        try withBrowser(rows: true) { browser, tab in
            press("tabs.pinRow", browser)
            XCTAssertNotNil(tab.pin)
            XCTAssertTrue(tab.listed, "a row")
            press("tabs.pinRow", browser)
            XCTAssertNil(tab.pin, "the same key unpins it")
        }
    }

    func testWithRowsOffTheRowsKeyPinsASquare() throws {
        try withBrowser(rows: false) { browser, tab in
            press("tabs.pinRow", browser)
            XCTAssertNotNil(tab.pin)
            XCTAssertFalse(tab.listed, "a square, as every pin is with the rows off")
        }
    }

    /// As a key of your own runs it, through its command.
    private func press(_ id: String, _ browser: Browser) {
        guard let command = Command.named(id) else { return XCTFail("no \(id) command") }
        command.run(browser)
    }

    private func withBrowser(rows: Bool, _ body: (Browser, Tab) throws -> Void) throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let browser = Browser(record: WindowRecord())
        let prefs = browser.prefs
        let saved = (prefs.sidebar, prefs.usesTabGroups, prefs.listsPins)
        defer {
            for tab in browser.tabs where tab.pin != nil { browser.unpin(tab) }
            browser.closeAll()
            (prefs.sidebar, prefs.usesTabGroups, prefs.listsPins) = saved
        }
        prefs.sidebar = true
        prefs.usesTabGroups = false
        prefs.listsPins = rows
        browser.newTab()
        let tab = try XCTUnwrap(browser.tabs.last)
        tab.restore(url: URL(string: "about:blank#pin")!, title: "Pin")
        browser.select(tab)
        try body(browser, tab)
    }
}
