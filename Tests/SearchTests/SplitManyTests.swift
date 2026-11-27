import AppKit
import XCTest
@testable import Search

/// Split View with three and four pages: a split is an ordered list of two
/// to four, a page added beside another joins its split, a page closed
/// leaves the rest, one left alone is a tab again, and a file written with
/// two still reads as it always did.
@available(macOS 14, *)
@MainActor
final class SplitManyTests: XCTestCase {
    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    // MARK: - the model

    func testInsertMakesEvenAndStopsAtFour() {
        let ids = (0..<5).map { _ in UUID() }
        var split = TabSplit(tabs: [ids[0], ids[1]], sizes: [0.3, 0.7])
        XCTAssertTrue(split.insert(ids[2], beside: ids[0]))
        XCTAssertEqual(split.tabs, [ids[0], ids[2], ids[1]], "after the page it went beside")
        XCTAssertEqual(split.sizes, TabSplit.even(3), "each page coming in makes them even")
        XCTAssertTrue(split.insert(ids[3], beside: ids[0], before: true))
        XCTAssertEqual(split.tabs, [ids[3], ids[0], ids[2], ids[1]])
        XCTAssertTrue(split.isFull)
        XCTAssertFalse(split.insert(ids[4]), "no fifth")
        XCTAssertFalse(split.insert(ids[0]), "no page twice")
        XCTAssertEqual(split.tabs.count, TabSplit.most)
    }

    func testRemoveKeepsOrderAndSharesThenCollapses() {
        let ids = (0..<3).map { _ in UUID() }
        var split = TabSplit(tabs: ids, sizes: [0.5, 0.3, 0.2], focused: ids[1])
        XCTAssertTrue(split.remove(ids[1]), "two left is still a split")
        XCTAssertEqual(split.tabs, [ids[0], ids[2]])
        XCTAssertEqual(split.sizes[0], 0.5 / 0.7, accuracy: 0.0001, "its share goes to the others in proportion")
        XCTAssertEqual(split.sizes.reduce(0, +), 1, accuracy: 0.0001)
        XCTAssertNil(split.focused, "the page that had the keys has gone")
        XCTAssertFalse(split.remove(ids[0]), "one alone is no split")
        XCTAssertEqual(split.tabs, [ids[2]])
    }

    func testPartnerIsTheNeighbour() {
        let ids = (0..<3).map { _ in UUID() }
        let split = TabSplit(tabs: ids)
        XCTAssertEqual(split.partner(of: ids[0]), ids[1])
        XCTAssertEqual(split.partner(of: ids[1]), ids[2], "the one to its right")
        XCTAssertEqual(split.partner(of: ids[2]), ids[1], "the last, the one to its left")
        let two = TabSplit(tabs: [ids[0], ids[1]])
        XCTAssertEqual(two.partner(of: ids[0]), ids[1], "of two, the other, as ever")
        XCTAssertEqual(two.partner(of: ids[1]), ids[0])
    }

    func testClampKeepsEveryPageVisible() {
        let shares = TabSplit.clamp([0.9, 0.05, 0.05])
        XCTAssertEqual(shares.reduce(0, +), 1, accuracy: 0.0001)
        XCTAssertTrue(shares.allSatisfy { $0 >= TabSplit.least(3) - 0.0001 }, "\(shares)")
        let two = TabSplit.clamp([0.95, 0.05])
        XCTAssertEqual(two[0], 0.8, accuracy: 0.0001, "two as it always was")
        XCTAssertEqual(two[1], 0.2, accuracy: 0.0001)
    }

    // MARK: - the file

    func testAnOldTwoPageRecordStillReads() throws {
        // The first shape Split View was written in on main.
        let first = try JSONDecoder().decode(Session.Split.self, from: Data(#"{"left":0,"right":1,"fraction":0.3}"#.utf8))
        XCTAssertEqual(first.tabs, [0, 1])
        XCTAssertEqual(first.sizes, [0.3, 0.7])
        XCTAssertEqual(first.axis, .horizontal)
        // The shape 1.0.x writes for a pair.
        let pair = try JSONDecoder().decode(Session.Split.self, from: Data(#"{"tabs":[2,3],"axis":"horizontal","sizes":[0.4,0.6],"focused":3}"#.utf8))
        XCTAssertEqual(pair.tabs, [2, 3])
        XCTAssertEqual(pair.sizes, [0.4, 0.6])
        XCTAssertEqual(pair.focused, 3)
        // A whole row, as a fresh start reads it.
        let shape = try JSONDecoder().decode(Session.Shape.self, from: Data("""
        {"tabs":[{"url":"https://a.test/","title":"A","name":"a"},{"url":"https://b.test/","title":"B","name":"b"}],
         "active":0,"splits":[{"tabs":[0,1],"axis":"horizontal","sizes":[0.4,0.6]}]}
        """.utf8))
        XCTAssertEqual(shape.splits.count, 1)
        XCTAssertEqual(Session.fresh(shape).splits.first?.tabs, [0, 1], "kept whole")
    }

    func testThreePagesRoundTrip() throws {
        let written = Session.Split(tabs: [1, 2, 3], axis: .horizontal, sizes: [0.5, 0.25, 0.25], focused: 2)
        let read = try JSONDecoder().decode(Session.Split.self, from: JSONEncoder().encode(written))
        XCTAssertEqual(read.tabs, [1, 2, 3])
        XCTAssertEqual(read.sizes, [0.5, 0.25, 0.25])
        XCTAssertEqual(read.focused, 2)
    }

    // MARK: - in a window

    func testAPageAddedBesideASplitJoinsIt() throws {
        try withBrowser { browser, t in
            browser.pair(t[2], with: t[1], onLeft: false)
            browser.pair(t[3], with: t[2], onLeft: false)
            let split = try XCTUnwrap(browser.split(for: t[1]))
            XCTAssertEqual(split.tabs, [t[1].id, t[2].id, t[3].id], "three in a row")
            XCTAssertEqual(split.sizes, TabSplit.even(3), "even")
            XCTAssertEqual(browser.splits.count, 1, "one split, not a second pair")
            XCTAssertTrue(Browser.holds(split, in: browser.tabs), "side by side in the row")
            XCTAssertEqual(browser.displayedTabs.map(\.id), [t[0].id, t[1].id, t[4].id], "one place in the row")
            XCTAssertEqual(browser.visibleTabIDs, Set([t[1].id, t[2].id, t[3].id]), "all three on screen")
            XCTAssertEqual(browser.activeID, t[3].id, "the page added has the keys")
        }
    }

    func testAPageCarriedOntoAPageOfASplitLandsBesideIt() throws {
        try withBrowser { browser, t in
            browser.pair(t[2], with: t[1], onLeft: false)
            browser.pair(t[4], with: t[1], onLeft: true)
            XCTAssertEqual(browser.split(for: t[1])?.tabs, [t[4].id, t[1].id, t[2].id], "on its left")
            XCTAssertEqual(browser.tabs.map(\.id), [t[0].id, t[4].id, t[1].id, t[2].id, t[3].id], "in the row too")
        }
    }

    func testFourIsTheMost() throws {
        try withBrowser { browser, t in
            browser.pair(t[1], with: t[0], onLeft: false)
            browser.pair(t[2], with: t[1], onLeft: false)
            browser.pair(t[3], with: t[2], onLeft: false)
            XCTAssertEqual(browser.split(for: t[0])?.tabs.count, 4)
            XCTAssertFalse(browser.canJoin(t[4], beside: t[3]), "full")
            XCTAssertFalse(browser.canAddPane)
            browser.pair(t[4], with: t[3], onLeft: false)
            browser.openInSplit(t[4])
            XCTAssertNil(browser.split(for: t[4]), "nothing joins a full split")
            XCTAssertEqual(browser.split(for: t[0])?.tabs, [t[0].id, t[1].id, t[2].id, t[3].id], "and it is left as it was")
        }
    }

    func testClosingOnePageLeavesTheRestThenOneIsATab() throws {
        try withBrowser { browser, t in
            browser.pair(t[2], with: t[1], onLeft: false)
            browser.pair(t[3], with: t[2], onLeft: false)
            browser.focusPane(t[2])
            browser.closeTab(t[2])
            let split = try XCTUnwrap(browser.split(for: t[1]), "two left stay a split")
            XCTAssertEqual(split.tabs, [t[1].id, t[3].id])
            XCTAssertEqual(browser.activeID, t[3].id, "the page beside it has the keys")
            browser.closeTab(t[3])
            XCTAssertNil(browser.split(for: t[1]), "a split of one is a tab")
            XCTAssertTrue(browser.splits.isEmpty)
            XCTAssertEqual(browser.activeID, t[1].id)
        }
    }

    func testReopenPutsAClosedPageBackInItsPlace() throws {
        try withBrowser { browser, t in
            browser.pair(t[2], with: t[1], onLeft: false)
            browser.pair(t[3], with: t[2], onLeft: false)
            browser.closeTab(t[2])
            browser.reopen()
            let split = try XCTUnwrap(browser.split(for: t[1]))
            XCTAssertEqual(split.tabs.count, 3, "back in the split")
            XCTAssertEqual(split.tabs.first, t[1].id)
            XCTAssertEqual(split.tabs.last, t[3].id, "between the two it was between")
            XCTAssertEqual(browser.tabs.first { $0.id == split.tabs[1] }?.address, t[2].address)
        }
    }

    func testCloseAllComesBackAsOne() throws {
        try withBrowser { browser, t in
            browser.pair(t[2], with: t[1], onLeft: false)
            browser.pair(t[3], with: t[2], onLeft: false)
            browser.closeSplit()
            XCTAssertEqual(browser.tabs.map(\.id), [t[0].id, t[4].id])
            XCTAssertEqual(browser.recentlyClosed.count, 1, "one entry")
            browser.reopen()
            let split = try XCTUnwrap(browser.splits.first, "a split again")
            XCTAssertEqual(split.tabs.compactMap { id in browser.tabs.first { $0.id == id }?.address },
                           [t[1], t[2], t[3]].compactMap(\.address), "the three, in their order")
        }
    }

    func testAddPageToSplitView() throws {
        try withBrowser { browser, t in
            browser.pair(t[2], with: t[1], onLeft: false)
            browser.focusPane(t[1])
            XCTAssertTrue(browser.canAddPane)
            browser.addPaneToSplit()
            let split = try XCTUnwrap(browser.split(for: t[1]))
            XCTAssertEqual(split.tabs.count, 3)
            XCTAssertEqual(split.tabs[0], t[1].id)
            XCTAssertEqual(split.tabs[2], t[2].id, "the new page beside the one with the keys")
            XCTAssertEqual(browser.active?.isBlank, true, "an empty page, with the keys")
            XCTAssertEqual(browser.activeID, split.tabs[1])
        }
    }

    func testFocusMovesOnePageAtATime() throws {
        try withBrowser { browser, t in
            browser.pair(t[2], with: t[1], onLeft: false)
            browser.pair(t[3], with: t[2], onLeft: false)
            browser.focusPane(t[1])
            browser.focusPane(onLeft: false)
            XCTAssertEqual(browser.activeID, t[2].id)
            browser.focusPane(onLeft: false)
            XCTAssertEqual(browser.activeID, t[3].id)
            browser.focusPane(onLeft: false)
            XCTAssertEqual(browser.activeID, t[3].id, "none past the end")
            browser.focusOtherPane()
            XCTAssertEqual(browser.activeID, t[1].id, "round to the first")
        }
    }

    func testLeaveAndSeparate() throws {
        try withBrowser { browser, t in
            browser.pair(t[2], with: t[1], onLeft: false)
            browser.pair(t[3], with: t[2], onLeft: false)
            browser.leaveSplit(t[1])
            XCTAssertEqual(browser.split(for: t[2])?.tabs, [t[2].id, t[3].id], "the others together")
            XCTAssertEqual(browser.displayedTabs.map(\.id), [t[0].id, t[1].id, t[2].id, t[4].id])
            browser.pair(t[1], with: t[2], onLeft: true)
            browser.detachSplit(t[2])
            XCTAssertTrue(browser.splits.isEmpty, "Separate takes all of it apart")
            XCTAssertEqual(browser.tabs.count, 5, "every page stays")
        }
    }

    func testEvenAndSizes() throws {
        try withBrowser { browser, t in
            browser.pair(t[2], with: t[1], onLeft: false)
            browser.pair(t[3], with: t[2], onLeft: false)
            let id = try XCTUnwrap(browser.activeSplit?.id)
            browser.setSplitSizes(id, [0.5, 0.3, 0.2])
            XCTAssertEqual(browser.activeSplit?.sizes ?? [], [0.5, 0.3, 0.2])
            browser.setSplitSizes(id, [0.5, 0.5])
            XCTAssertEqual(browser.activeSplit?.sizes ?? [], [0.5, 0.3, 0.2], "the wrong count is ignored")
            browser.evenSplit()
            XCTAssertEqual(browser.activeSplit?.sizes ?? [], TabSplit.even(3))
        }
    }

    func testFourPickedGoSideBySide() throws {
        try withBrowser { browser, t in
            browser.select(t[0])
            for tab in t[1...3] { browser.extendTabSelection(to: tab, modifiers: .command) }
            XCTAssertEqual(browser.pickedSplit?.count, 4)
            XCTAssertNil(browser.pickedPair, "more than a pair")
            browser.pairPickedTabs()
            XCTAssertEqual(browser.split(for: t[0])?.tabs, t[0...3].map(\.id))
        }
    }

    func testTheRowWritesEveryPageOfTheSplit() throws {
        try withBrowser { browser, t in
            browser.pair(t[2], with: t[1], onLeft: false)
            browser.pair(t[3], with: t[2], onLeft: false)
            let row = try XCTUnwrap(browser.allRows()[browser.spaceID.uuidString])
            XCTAssertEqual(row.splits.count, 1)
            XCTAssertEqual(row.splits.first?.tabs, [1, 2, 3])
            XCTAssertEqual(row.splits.first?.sizes.count, 3)
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
        for number in 1...5 {
            if number > 1 { browser.newTab() }
            browser.tabs.last?.restore(url: URL(string: "http://127.0.0.1:9/\(number)")!, title: "Tab \(number)")
        }
        try body(browser, browser.tabs)
    }
}
