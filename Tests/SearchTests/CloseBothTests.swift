import AppKit
import XCTest
@testable import Search

/// Close Both Pages is remembered as one, as Close Tabs Below is: one ⇧⌘T
/// brings both pages back as the pair they were. Closed one by one, ⇧⌘T
/// brought back one page alone, and a second the other, apart.
@MainActor
final class CloseBothTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "close-both-\(getpid())", 1)
        super.setUp()
    }

    func testOneReopenBringsThePairBack() throws {
        try withBrowser { browser, tabs in
            browser.pair(tabs[2], with: tabs[1], onLeft: false)
            browser.closeSplit()
            XCTAssertEqual(browser.tabs.map(\.id), [tabs[0].id, tabs[3].id])
            XCTAssertEqual(browser.recentlyClosed.count, 1, "one entry")
            XCTAssertEqual(browser.reopenTitle, "Reopen 2 Closed Tabs")

            browser.reopen()
            XCTAssertEqual(browser.tabs.compactMap(\.address), tabs.compactMap(\.address), "back where they were")
            let pair = try XCTUnwrap(browser.split(for: browser.tabs[1]), "a pair again")
            XCTAssertEqual(pair.tabs, [browser.tabs[1].id, browser.tabs[2].id], "in the same order")
            XCTAssertEqual(browser.activeSplit?.id, pair.id, "on screen")
            XCTAssertTrue(browser.ghosts.isEmpty, "nothing left to bring back")
        }
    }

    func testThePageThatHadTheKeysHasThemAgain() throws {
        try withBrowser { browser, tabs in
            browser.pair(tabs[2], with: tabs[1], onLeft: false)
            browser.focusPane(tabs[1])
            browser.closeSplit()
            browser.reopen()
            XCTAssertEqual(browser.active?.address, tabs[1].address)
        }
    }

    func testClosingOnePageStillComesBackBesideTheOther() throws {
        try withBrowser { browser, tabs in
            browser.pair(tabs[2], with: tabs[1], onLeft: false)
            browser.closeTab(tabs[2])
            XCTAssertNil(browser.split(for: tabs[1]))
            browser.reopen()
            let pair = try XCTUnwrap(browser.split(for: tabs[1]), "beside it again, as before")
            XCTAssertEqual(pair.tabs.first, tabs[1].id)
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
        prefs.splitView = true
        for number in 1...4 {
            if number > 1 { browser.newTab() }
            browser.tabs.last?.restore(url: URL(string: "about:blank#\(number)")!, title: "Tab \(number)")
        }
        try body(browser, browser.tabs)
    }
}
