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

    /// A pin's page goes into Split View as it is (#1573): the tab that held
    /// it is the one in the pair, still where it wandered to, and the pin
    /// starts again in its place, asleep at the page it was pinned at, with
    /// its id, letter, folder and name. A pin still asleep since launch
    /// goes the same way.
    func testAPinsOwnPageGoesIntoThePairAndThePinStartsAgainAtHome() {
        let browser = makeBrowser()
        let tabs = made
        browser.pin(tabs[0], listed: true)
        browser.pin(tabs[1], listed: true)
        let home = tabs[1].home
        let letter = tabs[1].pin
        let ids = browser.tabs.prefix(2).map(\.pinID)
        let elsewhere = URL(string: "https://two.example/elsewhere")!
        tabs[1].restore(url: elsewhere, title: "elsewhere")
        let folder = UUID()
        tabs[1].pinFolder = folder
        tabs[1].name = "kept"

        // A tab dropped on the pin's page, on its right.
        browser.pair(tabs[2], with: tabs[1], onLeft: false)

        XCTAssertEqual(browser.split(for: tabs[1])?.tabs, [tabs[1].id, tabs[2].id], "the pin's own tab, not a copy")
        XCTAssertNil(tabs[1].pin)
        XCTAssertNil(tabs[1].pinFolder)
        XCTAssertEqual(tabs[1].address, elsewhere)
        XCTAssertEqual(browser.pinnedCount, 2)
        XCTAssertEqual(browser.tabs.prefix(2).map(\.pinID), ids, "both pins where they were")
        let fresh = browser.tabs[1]
        XCTAssertFalse(fresh === tabs[1])
        XCTAssertEqual(fresh.pin, letter)
        XCTAssertEqual(fresh.home, home)
        XCTAssertEqual(fresh.address, home)
        XCTAssertTrue(fresh.asleep, "nothing loaded for it")
        XCTAssertTrue(fresh.listed)
        XCTAssertEqual(fresh.pinFolder, folder)
        XCTAssertEqual(fresh.name, "kept")
        XCTAssertNil(browser.split(for: fresh))
    }

    /// ⌥⌘N on the pin on screen: its own page and an empty one, the pin
    /// kept among the pins with a fresh tab.
    func testStartingASplitOnAPinKeepsItsPage() {
        let browser = makeBrowser()
        let tabs = made
        browser.pin(tabs[0])
        let id = tabs[0].pinID
        browser.select(tabs[0])
        browser.startSplit()

        XCTAssertEqual(browser.split(for: tabs[0])?.tabs.first, tabs[0].id)
        XCTAssertNil(tabs[0].pin)
        XCTAssertEqual(browser.tabs.first?.pinID, id)
        XCTAssertNotNil(browser.tabs.first?.pin)
        XCTAssertFalse(browser.tabs.first === tabs[0])
    }

    /// A page of a pinned split with a link opened beside it: that page goes
    /// into the new pair, and the pinned split keeps the pin's fresh tab,
    /// still a pinned split of two.
    func testAPinOfAPinnedSplitLeavesItsPageAndThePinnedSplitHolds() {
        let browser = makeBrowser()
        let tabs = made
        browser.pair(tabs[1], with: tabs[0], onLeft: false)
        browser.pin(tabs[0])
        let pinned = browser.pinnedPair(of: tabs[0])
        XCTAssertNotNil(pinned)

        browser.pair(tabs[2], with: tabs[0], onLeft: false)

        let fresh = browser.tabs[0]
        XCTAssertFalse(fresh === tabs[0])
        XCTAssertNil(tabs[0].pin)
        XCTAssertEqual(browser.pinnedPair(of: fresh)?.id, pinned?.id)
        XCTAssertEqual(browser.pinnedPair(of: fresh)?.tabs, [fresh.id, tabs[1].id])
        XCTAssertEqual(browser.split(for: tabs[2])?.tabs, [tabs[0].id, tabs[2].id])
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
