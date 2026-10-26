import AppKit
import WebKit
import XCTest
@testable import Search

/// Which tab is on screen after the one on screen closes, with and without
/// Settings › Tabs › Closing a tab goes back to the one before.
@MainActor
final class TabCloseTests: XCTestCase {
    private var browser: Browser!
    private var oldSplitView = false
    private var oldCloseGoesBack = false

    override class func setUp() {
        setenv("SEARCH_PROBE", "tab-close-\(getpid())", 1)
        super.setUp()
    }

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        browser = Browser(record: WindowRecord())
        oldSplitView = browser.prefs.splitView
        oldCloseGoesBack = browser.prefs.closeGoesBack
        browser.prefs.splitView = false
        browser.prefs.closeGoesBack = true
        browser.closeAll()
    }

    override func tearDown() {
        browser?.closeAll()
        browser?.prefs.splitView = oldSplitView
        browser?.prefs.closeGoesBack = oldCloseGoesBack
        browser = nil
        super.tearDown()
    }

    private func tab(_ name: String) -> Tab {
        let tab = Tab(configuration: Web.configuration(space: browser.spaceID))
        tab.restore(url: URL(string: "about:blank#\(name)")!, title: name)
        return tab
    }

    /// A, B and C in the row, viewed B, then A, then C: C's neighbour is B,
    /// the tab viewed before it is A.
    private func viewedBAC() -> (a: Tab, b: Tab, c: Tab) {
        let (a, b, c) = (tab("A"), tab("B"), tab("C"))
        browser.showRow([a, b, c], active: c.id)
        browser.select(b)
        browser.select(a)
        browser.select(c)
        return (a, b, c)
    }

    func testOffClosingCurrentSelectsNeighbour() {
        browser.prefs.closeGoesBack = false
        let (_, b, c) = viewedBAC()
        browser.close(c)
        XCTAssertEqual(browser.activeID, b.id)
    }

    func testClosingCurrentGoesBackToLastViewed() {
        let (a, _, c) = viewedBAC()
        browser.close(c)
        XCTAssertEqual(browser.activeID, a.id)
    }

    func testSuccessiveClosesKeepGoingBack() {
        let (a, b, c) = viewedBAC()
        browser.close(c)
        XCTAssertEqual(browser.activeID, a.id)
        browser.close(a)
        XCTAssertEqual(browser.activeID, b.id)
    }

    func testTabClosedBehindIsNotGoneBackTo() {
        let (a, b, c) = viewedBAC()
        browser.close(a)
        XCTAssertEqual(browser.activeID, c.id)
        browser.close(c)
        XCTAssertEqual(browser.activeID, b.id)
    }

    func testOrderInTheRowDoesNotMatter() {
        let (a, b, c) = viewedBAC()
        browser.move(c, to: 1)
        XCTAssertEqual(browser.tabs.map(\.id), [a.id, c.id, b.id])
        browser.close(c)
        XCTAssertEqual(browser.activeID, a.id)
    }

    func testSplitPartnerStaysFirst() {
        browser.prefs.splitView = true
        let (a, b, c) = (tab("A"), tab("B"), tab("C"))
        browser.showRow([a, b, c], active: c.id)
        browser.pair(b, with: a, onLeft: false)
        browser.select(c)
        browser.select(b)
        browser.close(b)
        XCTAssertEqual(browser.activeID, a.id)
        XCTAssertNil(browser.activeSplit)
    }

    func testSleepingTabGoneBackToWakes() {
        let (a, _, c) = viewedBAC()
        a.rest()
        XCTAssertTrue(a.asleep)
        browser.close(c)
        XCTAssertEqual(browser.activeID, a.id)
        XCTAssertFalse(a.asleep)
        XCTAssertNotNil(a.built)
    }

    func testNoHistoryKeepsNeighbour() {
        let (_, b, c) = viewedBAC()
        browser.select(b)
        browser.tabSwitcher.reset()
        browser.close(b)
        XCTAssertEqual(browser.activeID, c.id)
    }

    func testStaysInItsSpace() {
        let oldUsesSpaces = browser.prefs.usesSpaces
        let oldSpaces = browser.spaces
        defer {
            browser.prefs.usesSpaces = oldUsesSpaces
            browser.spaces = oldSpaces
        }
        browser.prefs.usesSpaces = true
        let firstID = browser.spaceID
        let secondID = UUID()
        browser.spaces = [Space(id: firstID, name: "First", colour: 0), Space(id: secondID, name: "Second", colour: 1)]

        let (a, _, c) = viewedBAC()
        browser.switchSpace(to: secondID)
        let (d, e) = (tab("D"), tab("E"))
        browser.showRow([d, e], active: d.id)
        browser.select(e)
        browser.select(d)

        browser.switchSpace(to: firstID)
        browser.close(c)
        XCTAssertEqual(browser.activeID, a.id)
        XCTAssertEqual(browser.spaceID, firstID)
    }

    func testTabMovedToAnotherWindowIsNotGoneBackTo() {
        let other = Browser(record: WindowRecord(space: browser.spaceID))
        defer { other.closeAll() }
        let (a, b, c) = viewedBAC()
        browser.moveToWindow(a, other)
        browser.close(c)
        XCTAssertEqual(browser.activeID, b.id)
        XCTAssertTrue(other.tabs.contains { $0.id == a.id })
    }
}
