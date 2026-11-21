import AppKit
import WebKit
import XCTest
@testable import Search

/// Settings › Tabs › Swipe back closes a tab a link opened: which tabs a
/// swipe back from the first page closes, and where it lands.
@MainActor
final class SwipeBackClosesTests: XCTestCase {
    private var browser: Browser!
    private var oldSplitView = false
    private var oldCloseGoesBack = false
    private var oldSwipeBackCloses = false

    override class func setUp() {
        setenv("SEARCH_PROBE", "swipe-back-closes-\(getpid())", 1)
        super.setUp()
    }

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        browser = Browser(record: WindowRecord())
        oldSplitView = browser.prefs.splitView
        oldCloseGoesBack = browser.prefs.closeGoesBack
        oldSwipeBackCloses = browser.prefs.swipeBackCloses
        browser.prefs.splitView = false
        browser.prefs.closeGoesBack = false
        browser.prefs.swipeBackCloses = true
        browser.closeAll()
    }

    override func tearDown() {
        browser?.closeAll()
        browser?.prefs.splitView = oldSplitView
        browser?.prefs.closeGoesBack = oldCloseGoesBack
        browser?.prefs.swipeBackCloses = oldSwipeBackCloses
        browser = nil
        super.tearDown()
    }

    private func tab(_ name: String, from opener: Tab? = nil) -> Tab {
        let tab = Tab(configuration: Web.configuration(space: browser.spaceID))
        tab.opener = opener?.id
        tab.restore(url: URL(string: "about:blank#\(name)")!, title: name)
        return tab
    }

    func testLinkTabIsArmed() {
        let a = tab("A")
        let link = tab("L", from: a)
        browser.prepare(link)
        XCTAssertNotNil(link.leave)
    }

    func testTabNoLinkOpenedIsNotArmed() {
        let a = tab("A")
        browser.prepare(a)
        XCTAssertNil(a.leave)
    }

    func testSwitchOffLeavesItAlone() {
        browser.prefs.swipeBackCloses = false
        let a = tab("A")
        let link = tab("L", from: a)
        browser.prepare(link)
        XCTAssertNil(link.leave)
    }

    func testSizedPopupIsNotArmed() {
        let a = tab("A")
        let link = tab("L", from: a)
        link.popup = true
        browser.prepare(link)
        XCTAssertNil(link.leave)
    }

    /// A, B and L, a tab a link on B opened, in the row, viewed B, then A,
    /// then L. With Closing a tab goes back off, ⌘W on L lands beside it, on
    /// B; the swipe goes back to A, the tab you were on.
    func testLeavingClosesAndGoesBackToLastViewed() {
        let (a, b) = (tab("A"), tab("B"))
        let link = tab("L", from: b)
        browser.showRow([a, b, link], active: link.id)
        browser.select(b)
        browser.select(a)
        browser.select(link)
        browser.prepare(link)
        link.leave?()
        XCTAssertFalse(browser.tabs.contains { $0 === link })
        XCTAssertEqual(browser.activeID, a.id)
    }

    func testPinningDisarms() {
        let a = tab("A")
        let link = tab("L", from: a)
        browser.showRow([a, link], active: link.id)
        browser.prepare(link)
        XCTAssertNotNil(link.leave)
        browser.pin(link)
        XCTAssertNil(link.leave)
    }

    func testFlippingTheSwitchReachesOpenTabs() {
        let a = tab("A")
        let link = tab("L", from: a)
        browser.showRow([a, link], active: link.id)
        browser.prepare(link)
        XCTAssertNotNil(link.leave)
        browser.prefs.swipeBackCloses = false
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertNil(link.leave)
        browser.prefs.swipeBackCloses = true
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertNotNil(link.leave)
    }
}
