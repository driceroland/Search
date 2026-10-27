import AppKit
import Foundation
import XCTest
@testable import Search

/// History › Clear Browsing Data…, which asks for the clearing controls
/// that live inside History (#749).
@available(macOS 15.4, *)
@MainActor
final class ClearBrowsingDataTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "clear-browsing-data-\(getpid())", 1)
        super.setUp()
    }

    private func fresh() -> Browser {
        _ = NSApplication.shared
        return Browser(record: WindowRecord())
    }

    /// Asked for with History closed, which is how it is usually asked for:
    /// the mode alone left nothing on screen, so the menu item and its
    /// shortcut did nothing at all.
    func testBringsHistoryOutOnItsClearingControls() {
        let browser = fresh()
        XCTAssertFalse(browser.recalling)

        browser.clearBrowsingData()

        XCTAssertTrue(browser.recalling)
        XCTAssertEqual(browser.recallMode, .clearing)
    }

    /// Asked for with History already open, where it worked before: the mode
    /// has to be set after the page is out, since a page coming out afresh
    /// puts the mode back to its list.
    func testSwitchesHistoryAlreadyOpenToItsClearingControls() {
        let browser = fresh()
        browser.recalling = true
        XCTAssertEqual(browser.recallMode, .history)

        browser.clearBrowsingData()

        XCTAssertTrue(browser.recalling)
        XCTAssertEqual(browser.recallMode, .clearing)
    }

    /// Never a second History, however often it is asked for, as ⌘Y's own
    /// page is brought forward rather than opened again.
    func testAsksTwiceAndKeepsOneHistory() {
        let browser = fresh()
        browser.clearBrowsingData()
        browser.clearBrowsingData()

        XCTAssertEqual(browser.tabs.filter { $0.page?.kind == .history }.count, 1)
        XCTAssertEqual(browser.recallMode, .clearing)
    }

    /// Show History… is unchanged: it opens on the list, not on clearing.
    func testShowHistoryStillOpensOnItsList() {
        let browser = fresh()
        browser.recalling = true

        XCTAssertTrue(browser.recalling)
        XCTAssertEqual(browser.recallMode, .history)
    }
}
