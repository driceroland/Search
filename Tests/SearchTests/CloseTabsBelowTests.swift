import AppKit
import XCTest
@testable import Search

@MainActor
final class CloseTabsBelowTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "close-tabs-below-\(getpid())", 1)
        super.setUp()
    }

    func testClosesOnlyTabsBelowBackgroundTabAndRemembersThem() {
        withBrowser { browser, tabs in
            browser.select(tabs[3])
            browser.closeTabsBelow(tabs[1])
            XCTAssertEqual(browser.tabs.map(\.id), tabs.prefix(2).map(\.id))
            XCTAssertEqual(browser.activeID, tabs[1].id)
            XCTAssertEqual(Set(browser.ghosts.map(\.title)), Set(["Tab 3", "Tab 4"]))
            XCTAssertEqual(browser.recentlyClosed.count, 1)
            XCTAssertEqual(browser.reopenTitle, "Reopen 2 Closed Tabs")

            browser.reopen()
            XCTAssertEqual(browser.tabs.compactMap(\.address), tabs.compactMap(\.address))
            XCTAssertEqual(browser.active?.address, tabs[3].address)
            XCTAssertTrue(browser.ghosts.isEmpty)
        }
    }

    func testPreservesFocusAboveAndDoesNothingAtEndOrForMissingTab() {
        withBrowser { browser, tabs in
            browser.select(tabs[0])
            XCTAssertTrue(browser.tabsBelow(tabs[3]).isEmpty)
            browser.closeTabsBelow(tabs[3])
            XCTAssertEqual(browser.tabs.count, 4)
            XCTAssertTrue(browser.recentlyClosed.isEmpty)
            browser.closeTabsBelow(tabs[1])
            XCTAssertEqual(browser.activeID, tabs[0].id)
            XCTAssertTrue(browser.tabsBelow(tabs[2]).isEmpty)
            browser.closeTabsBelow(tabs[2])
            XCTAssertEqual(browser.tabs.map(\.id), tabs.prefix(2).map(\.id))
            browser.reopen()
            XCTAssertEqual(browser.tabs.compactMap(\.address), tabs.compactMap(\.address))
            XCTAssertEqual(browser.activeID, tabs[0].id)
        }
    }

    func testPinsStayWhenClosingBelowFirstTab() {
        withBrowser { browser, tabs in
            browser.pin(tabs[0])
            browser.pin(tabs[1])
            defer {
                browser.unpin(tabs[0])
                browser.unpin(tabs[1])
            }
            browser.closeTabsBelow(tabs[0])
            XCTAssertEqual(browser.tabs.map(\.id), tabs.prefix(2).map(\.id))
            XCTAssertNotNil(tabs[1].pin)
        }
    }

    func testKeepsBothPagesWhenInvokedFromEitherSplitHalf() {
        for half in 0...1 {
            withBrowser { browser, tabs in
                browser.prefs.splitView = true
                browser.pair(tabs[1], with: tabs[0], onLeft: false)
                browser.closeTabsBelow(tabs[half])
                XCTAssertEqual(browser.tabs.map(\.id), tabs.prefix(2).map(\.id))
                XCTAssertNotNil(browser.split(for: tabs[0]))
            }
        }
    }

    func testClosesFoldedGroupsBelowInTheirDisplayOrder() {
        withBrowser { browser, tabs in
            browser.prefs.usesTabGroups = true
            let below = browser.addTabGroup(containing: tabs[0])
            browser.move(tabs[1], toGroup: below)
            let above = browser.addTabGroup(containing: tabs[2])
            browser.moveTabGroup(above, to: 0)
            browser.select(tabs[3])
            browser.toggleTabGroup(below)
            XCTAssertFalse(browser.shownTabs.contains { $0.id == tabs[0].id })
            browser.closeTabsBelow(tabs[2])
            XCTAssertEqual(browser.tabs.map(\.id), [tabs[2].id])
            XCTAssertEqual(browser.tabGroups.map(\.id), [above])

            browser.reopen()
            XCTAssertEqual(browser.tabGroups.map(\.id), [above, below])
            XCTAssertEqual(browser.tabs(in: below).compactMap(\.address), tabs.prefix(2).compactMap(\.address))
            XCTAssertEqual(browser.tabs.compactMap(\.address), [tabs[2], tabs[0], tabs[1], tabs[3]].compactMap(\.address))
        }
    }

    func testRecentlyClosedRestoresWholeBatchWithoutReopeningOtherActions() throws {
        try withBrowser(count: 6) { browser, tabs in
            browser.close(tabs[5])
            browser.closeTabsBelow(tabs[1])
            browser.close(tabs[0])

            XCTAssertEqual(browser.recentlyClosed.count, 3)
            XCTAssertEqual(browser.recentlyClosed.map { browser.closedTitle(for: $0) },
                           ["Tab 1", "3 Closed Tabs", "Tab 6"])
            let entry = try XCTUnwrap(browser.recentlyClosed.first { $0.batch != nil })
            browser.reopen(entry)
            XCTAssertEqual(browser.tabs.compactMap(\.address), tabs[1...4].compactMap(\.address))
            XCTAssertEqual(browser.active?.address, tabs[4].address)
            XCTAssertEqual(Set(browser.ghosts.map(\.title)), Set(["Tab 1", "Tab 6"]))
        }
    }

    func testBatchLargerThanHistoryLimitReopensEveryTab() {
        withBrowser(count: 16) { browser, tabs in
            browser.select(tabs[0])
            browser.closeTabsBelow(tabs[0])
            XCTAssertEqual(browser.ghosts.count, 15)
            XCTAssertEqual(browser.recentlyClosed.count, 1)
            XCTAssertEqual(browser.reopenTitle, "Reopen 15 Closed Tabs")
            browser.reopen()
            XCTAssertEqual(browser.tabs.compactMap(\.address), tabs.compactMap(\.address))
            XCTAssertEqual(browser.activeID, tabs[0].id)
        }
    }

    func testReopeningRestoresSplitBelowClickedTab() throws {
        try withBrowser { browser, tabs in
            browser.prefs.splitView = true
            browser.pair(tabs[3], with: tabs[2], onLeft: false)
            browser.select(tabs[0])
            browser.closeTabsBelow(tabs[1])
            browser.reopen()
            XCTAssertEqual(browser.tabs.compactMap(\.address), tabs.compactMap(\.address))
            let pair = try XCTUnwrap(browser.split(for: browser.tabs[2]))
            XCTAssertEqual(pair.tabs, Array(browser.tabs.suffix(2)).map(\.id))
            XCTAssertEqual(browser.activeID, tabs[0].id)
        }
    }

    func testReopeningRestoresMultipleGroupsAndPartiallyClosedGroup() {
        withBrowser(count: 6) { browser, tabs in
            browser.prefs.usesTabGroups = true
            let first = browser.addTabGroup(containing: tabs[0])
            browser.move(tabs[1], toGroup: first)
            let second = browser.addTabGroup(containing: tabs[2])
            browser.move(tabs[3], toGroup: second)
            let third = browser.addTabGroup(containing: tabs[4])
            browser.renameTabGroup(second, to: "Research")
            browser.select(tabs[0])
            browser.closeTabsBelow(tabs[0])
            XCTAssertEqual(browser.reopenTitle, "Reopen 5 Closed Tabs")
            browser.reopen()
            XCTAssertEqual(browser.tabs.compactMap(\.address), tabs.compactMap(\.address))
            XCTAssertEqual(browser.tabGroups.map(\.id), [first, second, third])
            XCTAssertEqual(browser.tabGroups[1].name, "Research")
            XCTAssertEqual(browser.tabs.map(\.groupID), [first, first, second, second, third, nil])
        }
    }

    func testClearAndCloseGroupKeepTheirBatchLabelsAndHistoryActions() throws {
        try withBrowser { browser, tabs in
            browser.prefs.usesTabGroups = true
            let group = browser.addTabGroup(containing: tabs[0])
            browser.move(tabs[1], toGroup: group)
            browser.select(tabs[0])
            browser.clearTabs()
            XCTAssertEqual(browser.reopenTitle, "Reopen 2 Cleared Tabs")
            browser.closeTabGroup(group)
            XCTAssertEqual(browser.reopenTitle, "Reopen Closed Group")
            XCTAssertEqual(browser.recentlyClosed.map { browser.closedTitle(for: $0) },
                           ["Closed Group", "2 Cleared Tabs"])
            browser.reopen(try XCTUnwrap(browser.recentlyClosed.first))
            XCTAssertEqual(browser.tabs.filter { !$0.isBlank }.compactMap(\.address), tabs.prefix(2).compactMap(\.address))
            XCTAssertEqual(browser.recentlyClosed.count, 1)
            browser.reopen()
            XCTAssertEqual(browser.tabs.filter { !$0.isBlank }.compactMap(\.address), tabs.compactMap(\.address))
            XCTAssertEqual(browser.tabs(in: group).count, 2)
            XCTAssertTrue(browser.ghosts.isEmpty)
        }
    }

    private func withBrowser(count: Int = 4, _ body: (Browser, [Tab]) throws -> Void) rethrows {
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
        for number in 1...count {
            if number > 1 { browser.newTab() }
            browser.tabs.last?.restore(url: URL(string: "about:blank#\(number)")!, title: "Tab \(number)")
        }
        try body(browser, browser.tabs)
    }
}
