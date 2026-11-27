import AppKit
import XCTest
@testable import Search

@available(macOS 14, *)
@MainActor
final class PinCommandClickTests: XCTestCase {
    private var browser: Browser!
    private let home = URL(string: "https://example.com/")!
    private let article = URL(string: "https://example.com/article")!

    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    override func setUp() {
        _ = NSApplication.shared
        browser = Browser(record: WindowRecord())
        browser.prefs.pinCommandOpensTab = true
        for tab in browser.tabs where tab.pin != nil { browser.unpin(tab) }
        browser.closeAll()
    }

    override func tearDown() {
        browser.prefs.pinCommandOpensTab = false
        for tab in browser.tabs where tab.pin != nil { browser.unpin(tab) }
        browser.closeAll()
        browser = nil
    }

    private func pin(home: URL, current: URL? = nil, listed: Bool = false) -> Tab {
        if browser.tabs.count == 1, browser.tabs[0].isBlank {
            let tab = browser.tabs[0]
            tab.setAddressOptimistically(current ?? home)
            tab.pin = "E"
            tab.pinID = UUID()
            tab.home = home
            tab.listed = listed
            return tab
        }
        let tab = Tab(configuration: Web.configuration(space: browser.spaceID))
        tab.setAddressOptimistically(current ?? home)
        tab.pin = "E"
        tab.pinID = UUID()
        tab.home = home
        tab.listed = listed
        browser.prepare(tab)
        browser.insert(tab, at: browser.pinnedCount)
        return tab
    }

    func testCommandClickWanderedPinMovesToLooseAndResetsPin() {
        let tab = pin(home: home, current: article)
        browser.select(tab)
        XCTAssertEqual(browser.pinnedCount, 1)
        XCTAssertEqual(browser.tabs.count, 1)
        XCTAssertEqual(browser.activeID, tab.id)

        browser.commandClickPin(tab)

        // Pinned count is still 1; tabs count is now 2 (1 pin + 1 unpinned tab).
        XCTAssertEqual(browser.pinnedCount, 1)
        XCTAssertEqual(browser.tabs.count, 2)

        // The first tab is the fresh pin at home.
        let freshPin = browser.tabs[0]
        XCTAssertFalse(freshPin === tab)
        XCTAssertEqual(freshPin.pin, "E")
        XCTAssertEqual(freshPin.home, home)
        XCTAssertEqual(freshPin.address, home)
        XCTAssertEqual(browser.activeID, freshPin.id)

        // The second tab is the previous tab, now unpinned, holding the wandered page.
        let looseTab = browser.tabs[1]
        XCTAssertTrue(looseTab === tab)
        XCTAssertNil(looseTab.pin)
        XCTAssertFalse(looseTab.listed)
        XCTAssertNil(looseTab.home)
        XCTAssertEqual(looseTab.address, article)
    }

    func testCommandClickUnwanderedPinOpensNewLooseTab() {
        let tab = pin(home: home, current: home)
        browser.select(tab)
        XCTAssertEqual(browser.pinnedCount, 1)
        XCTAssertEqual(browser.tabs.count, 1)

        browser.commandClickPin(tab)

        // Pinned count is still 1; tabs count is 2 (the pin + new loose tab).
        XCTAssertEqual(browser.pinnedCount, 1)
        XCTAssertEqual(browser.tabs.count, 2)

        // The pin remains in place.
        XCTAssertTrue(browser.tabs[0] === tab)
        XCTAssertEqual(browser.tabs[0].pin, "E")

        // A new tab opened at home.
        let newTab = browser.tabs[1]
        XCTAssertFalse(newTab === tab)
        XCTAssertNil(newTab.pin)
        XCTAssertEqual(newTab.address, home)
    }

    func testCommandClickWanderedPinFromAnotherTabKeepsCurrentActiveTab() {
        let tab = pin(home: home, current: article)
        let other = Tab(configuration: Web.configuration(space: browser.spaceID))
        other.setAddressOptimistically(URL(string: "https://other.example/")!)
        browser.prepare(other)
        browser.insert(other, at: browser.tabs.count)
        browser.select(other)

        XCTAssertEqual(browser.activeID, other.id)

        browser.commandClickPin(tab)

        // Active tab stays the other tab.
        XCTAssertEqual(browser.activeID, other.id)
        XCTAssertEqual(browser.pinnedCount, 1)
        XCTAssertEqual(browser.tabs.count, 3)

        // The pin was reset at home.
        let freshPin = browser.tabs[0]
        XCTAssertFalse(freshPin === tab)
        XCTAssertEqual(freshPin.pin, "E")
        XCTAssertEqual(freshPin.home, home)

        // The wandered tab moved to loose tabs.
        let movedTab = browser.tabs[1]
        XCTAssertTrue(movedTab === tab)
        XCTAssertNil(movedTab.pin)
        XCTAssertEqual(movedTab.address, article)
    }

    func testCommandClickWanderedPinCarriesPinFolderAndClearsOnMovedTab() {
        let tab = pin(home: home, current: article, listed: true)
        let folderID = UUID()
        tab.pinFolder = folderID
        tab.name = "Custom Name"
        browser.select(tab)

        browser.commandClickPin(tab)

        XCTAssertEqual(browser.pinnedCount, 1)
        XCTAssertEqual(browser.tabs.count, 2)

        // The fresh pin gets the pinFolder and keeps the pin's custom name.
        let freshPin = browser.tabs[0]
        XCTAssertEqual(freshPin.pinFolder, folderID)
        XCTAssertEqual(freshPin.name, "Custom Name")

        // The moved loose tab clears pinFolder and custom name.
        let looseTab = browser.tabs[1]
        XCTAssertNil(looseTab.pinFolder)
        XCTAssertNil(looseTab.name)
    }

    func testExtendTabSelectionRespectsPinCommandOpensTabSetting() {
        let tab = pin(home: home, current: article)
        let other = Tab(configuration: Web.configuration(space: browser.spaceID))
        other.setAddressOptimistically(URL(string: "https://other.example/")!)
        browser.prepare(other)
        browser.insert(other, at: browser.tabs.count)
        browser.select(other)

        // Off by default: ⌘-click adds pin to tab selection instead of opening.
        browser.prefs.pinCommandOpensTab = false
        browser.extendTabSelection(to: tab, modifiers: [.command])

        XCTAssertEqual(browser.tabs.count, 2)
        XCTAssertEqual(browser.pinnedCount, 1)
        XCTAssertTrue(browser.selectedTabIDs.contains(tab.id))
        XCTAssertTrue(browser.selectedTabIDs.contains(other.id))

        // Turned on: ⌘-click moves wandered pin to loose tabs and resets pin at home.
        browser.clearTabSelection()
        browser.prefs.pinCommandOpensTab = true
        browser.extendTabSelection(to: tab, modifiers: [.command])

        XCTAssertEqual(browser.tabs.count, 3)
        XCTAssertEqual(browser.pinnedCount, 1)
        XCTAssertEqual(browser.tabs[0].address, home)
    }
}
