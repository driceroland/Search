import AppKit
import XCTest
@testable import Search

/// A split pinned as a split: Pin on one page pins every page, kept
/// together in pins.json and in the row, put down whole by ⌘W, and let go
/// of by Unpin.
@MainActor
final class PinSplitTests: XCTestCase {
    private var browsers: [Browser] = []
    /// The tabs each test made, in order: one session serves every suite
    /// in the process, so a window may open with tabs left from another.
    private var made: [Tab] = []
    private var restorePreferences: (() -> Void)?

    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    /// This run's world is its own (by pid): gone with it.
    override class func tearDown() {
        if let world = Store.world, world.hasPrefix("pin-split-") {
            try? FileManager.default.removeItem(at: Store.folder)
            UserDefaults.standard.removePersistentDomain(forName: "com.officecommun.search.test.\(world)")
        }
        super.tearDown()
    }

    override func tearDown() async throws {
        // Pins are kept for the space in every window (Pins.swift): put
        // down, or the next test's window would hold them too.
        for browser in browsers {
            for tab in browser.tabs where tab.pin != nil { browser.unpin(tab) }
            browser.closeAll()
        }
        restorePreferences?()
        browsers.removeAll()
        made.removeAll()
        try await Task.sleep(for: .milliseconds(250))
        try await super.tearDown()
    }

    func testAPairIsPinnedTogetherAndStaysTogether() {
        let browser = makeBrowser()
        let tabs = made
        browser.pair(tabs[1], with: tabs[0], onLeft: false)
        XCTAssertNotNil(browser.pinnableSplit(tabs[0]))

        browser.pin(tabs[0])
        XCTAssertNotNil(tabs[0].pin)
        XCTAssertNotNil(tabs[1].pin)
        XCTAssertTrue(tabs[0].listed && tabs[1].listed, "pinned as rows, whatever was asked")
        let pair = browser.pinnedPair(of: tabs[0])
        XCTAssertEqual(pair?.tabs, [tabs[0].id, tabs[1].id])
        XCTAssertEqual(browser.pinnedPair(of: tabs[1])?.id, pair?.id)
        XCTAssertNil(browser.pinnableSplit(tabs[0]), "already pinned")

        let defs = Pins.defs(browser.spaceID)
        XCTAssertEqual(defs.count, 2)
        XCTAssertEqual(Set(defs.map(\.pair)), [pair?.id], "both pins name the same pair")

        // ⌘W puts the pair down whole, still a pair.
        browser.select(tabs[2])
        browser.close(tabs[1])
        XCTAssertEqual(browser.pinnedPair(of: tabs[0])?.id, pair?.id)
        XCTAssertTrue(browser.tabs.contains { $0.id == tabs[1].id })

        // Unpinned, both pages come out and stay in a Split View among the
        // tabs (the pair acts as one group).
        browser.unpin(tabs[0])
        XCTAssertNil(tabs[0].pin)
        XCTAssertNil(tabs[1].pin)
        XCTAssertEqual(browser.split(for: tabs[0])?.tabs, [tabs[0].id, tabs[1].id])
        XCTAssertEqual(Pins.defs(browser.spaceID), [])
    }

    func testTwoPinsPairedTogetherMergeIntoAPinnedSplit() {
        let browser = makeBrowser()
        let tabs = made
        let before = browser.tabs.count
        browser.pin(tabs[0])
        browser.pin(tabs[1])
        XCTAssertNil(browser.pinnedPair(of: tabs[0]), "two pins, not a pair yet")

        // "Open 2 Tabs in Split View" with the two pins picked: the pair
        // merges rather than copying the pins into new tabs beside the pair.
        // One of them has the keys first, so ⌘-click on the other doesn't
        // also pick the tab in front (see extendTabSelection).
        browser.select(tabs[0])
        browser.clearTabSelection()
        browser.extendTabSelection(to: tabs[1], modifiers: .command)
        XCTAssertEqual(browser.selectedTabIDs, Set([tabs[0].id, tabs[1].id]), "only the two pins")
        browser.pairPickedTabs()
        let pair = browser.pinnedPair(of: tabs[0])
        XCTAssertNotNil(pair)
        XCTAssertEqual(pair?.tabs.count, 2, "no copy tab beside the pins")
        XCTAssertTrue(tabs[0].listed && tabs[1].listed, "always rows")
        XCTAssertEqual(browser.tabs.count, before, "no tab added or lost")
    }

    func testPuttingAwayTheOtherPaneOfAnActivePinnedSplitLeavesIt() {
        let browser = makeBrowser()
        let tabs = made
        browser.pair(tabs[1], with: tabs[0], onLeft: false)
        browser.pin(tabs[0])
        browser.select(tabs[2])
        browser.select(tabs[1])
        XCTAssertEqual(browser.activeID, tabs[1].id)

        browser.closeTab(tabs[0])

        XCTAssertEqual(browser.activeID, tabs[2].id)
        XCTAssertTrue(tabs[0].asleep && tabs[1].asleep)
        XCTAssertNotNil(browser.pinnedPair(of: tabs[0]))
    }

    func testAPinnedPairStaysRowsMovesWholeAndComesOutWhole() {
        let browser = makeBrowser()
        let tabs = made
        browser.pair(tabs[1], with: tabs[0], onLeft: false)
        browser.pin(tabs[0])
        browser.pin(tabs[2], listed: true)
        XCTAssertEqual(browser.tabs.prefix(3).map(\.title), ["one", "two", "three"])

        browser.setListed(tabs[0], false)
        XCTAssertTrue(tabs[0].listed, "no Show as Square for a pinned split")
        XCTAssertFalse(browser.takesFolder(tabs[0]), "nor a folder")

        // Carried by one page, the pair goes as one, below the other pin.
        browser.moveDisplayedTab(tabs[0], to: 1)
        XCTAssertEqual(browser.tabs.prefix(3).map(\.title), ["three", "one", "two"])
        XCTAssertEqual(browser.pinnedPair(of: tabs[1])?.tabs, [tabs[0].id, tabs[1].id])

        // Out among the tabs: both pages, still a split.
        XCTAssertTrue(browser.unpinDropped(tabs[1], at: 0))
        XCTAssertNil(tabs[0].pin)
        XCTAssertNil(tabs[1].pin)
        XCTAssertEqual(browser.split(for: tabs[0])?.tabs, [tabs[0].id, tabs[1].id])
        XCTAssertNotNil(tabs[2].pin)
    }

    func testUnpinOnPinnedPairUnpinsBothAndKeepsTheSplit() {
        let browser = makeBrowser()
        let tabs = made
        browser.pair(tabs[1], with: tabs[0], onLeft: false)
        browser.pin(tabs[0])
        XCTAssertNotNil(browser.pinnedPair(of: tabs[0]))

        browser.unpin(tabs[0])
        XCTAssertNil(tabs[0].pin)
        XCTAssertNil(tabs[1].pin, "the other comes out too")
        XCTAssertEqual(browser.split(for: tabs[0])?.tabs, [tabs[0].id, tabs[1].id],
                       "still a Split View among the tabs")
    }

    func testAnotherWindowShowsThePinnedPairAsAPair() {
        let browser = makeBrowser()
        let tabs = made
        browser.pair(tabs[1], with: tabs[0], onLeft: false)
        browser.pin(tabs[0])
        let ids = Set(Pins.defs(browser.spaceID).map(\.id))

        let other = Browser(record: WindowRecord())
        browsers.append(other)
        let pinned = other.splits.filter { pair in
            Set(pair.tabs.compactMap { id in other.tabs.first { $0.id == id }?.pinID }) == ids
        }
        XCTAssertEqual(pinned.count, 1)
    }

    func testATabOutsideASplitIsNotOffered() {
        let browser = makeBrowser()
        XCTAssertNil(browser.pinnableSplit(made[0]))
    }

    private func makeBrowser() -> Browser {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        // Not closeAll() first: a window closed that way writes nothing,
        // pins.json included.
        let browser = Browser(record: WindowRecord())
        browsers.append(browser)
        let prefs = browser.prefs
        let saved = (prefs.usesTabGroups, prefs.splitView, prefs.listsPins, prefs.sharesPins)
        restorePreferences = {
            (prefs.usesTabGroups, prefs.splitView, prefs.listsPins, prefs.sharesPins) = saved
        }
        prefs.usesTabGroups = false
        prefs.splitView = true
        prefs.listsPins = false
        prefs.sharesPins = false
        for word in ["one", "two", "three", "four"] {
            if browser.tabs.last?.isBlank != true { browser.newTab() }
            browser.tabs.last?.restore(url: URL(string: "https://\(word).example/")!, title: word)
            if let last = browser.tabs.last { made.append(last) }
        }
        return browser
    }
}
