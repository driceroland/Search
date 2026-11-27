import AppKit
import WebKit
import XCTest
@testable import Search

/// What a window listens to in its tabs goes with each tab: the window's own
/// set stays the size it was, however many tabs open and close over a run
/// (each closed tab used to leave five sinks in it), and a tab prepared again
/// is listened to once.
@MainActor
final class TabListeningTests: XCTestCase {
    private var browser: Browser!

    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        browser = Browser(record: WindowRecord())
        browser.closeAll()
    }

    override func tearDown() {
        browser?.closeAll()
        browser = nil
        super.tearDown()
    }

    private func tab(_ name: String) -> Tab {
        let tab = Tab(configuration: Web.configuration(space: browser.spaceID))
        tab.restore(url: URL(string: "about:blank#\(name)")!, title: name)
        return tab
    }

    func testClosedTabsLeaveNothingInTheWindow() {
        let before = browser.listeningCount
        for i in 0..<40 {
            let page = tab("page\(i)")
            browser.insert(page, at: browser.tabs.count)
            browser.prepare(page)
            browser.close(page)
        }
        XCTAssertEqual(browser.listeningCount, before)
    }

    func testATabIsListenedToOnceHoweverOftenItIsPrepared() {
        let page = tab("again")
        browser.insert(page, at: browser.tabs.count)
        browser.prepare(page)
        let once = page.subscriptions.count
        XCTAssertGreaterThan(once, 0)
        browser.prepare(page)
        browser.prepare(page)
        XCTAssertEqual(page.subscriptions.count, once)
    }
}
