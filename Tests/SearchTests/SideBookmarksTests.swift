import XCTest
@testable import Search

/// Settings › Appearance › Tabs › Show the bookmarks bar in the sidebar:
/// off unless asked for, only with the bar shown and the tabs down a side,
/// and the height the column adds up for it before it is drawn. On the
/// model only.
@MainActor
final class SideBookmarksTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "side-bookmarks-\(getpid())", 1)
        super.setUp()
    }

    private let keys = ["sidebar", "bookmarks.bar", "bookmarks.side"]
    private var saved: [(String, Any?)] = []

    override func setUp() async throws {
        saved = keys.map { ($0, Store.settings.object(forKey: $0)) }
        keys.forEach(Store.settings.removeObject(forKey:))
    }

    override func tearDown() async throws {
        for (key, value) in saved { Store.settings.set(value, forKey: key) }
    }

    func testOffUnlessAskedForAndOnlyDownASide() {
        Store.settings.set(true, forKey: "sidebar")
        let prefs = Preferences()
        prefs.bookmarksBar = true
        XCTAssertFalse(prefs.bookmarksInSidebar)
        XCTAssertFalse(prefs.sideBookmarks)
        prefs.bookmarksInSidebar = true
        XCTAssertTrue(prefs.sideBookmarks)
        XCTAssertTrue(Preferences().bookmarksInSidebar, "kept")
        prefs.sidebar = false
        XCTAssertFalse(prefs.sideBookmarks, "with the tabs across the top the bar stays above the page")
    }

    func testOnlyWithTheBarShown() {
        Store.settings.set(true, forKey: "sidebar")
        let prefs = Preferences()
        prefs.bookmarksInSidebar = true
        XCTAssertFalse(prefs.sideBookmarks, "the bar hidden is hidden in the column too")
        let item = try! XCTUnwrap(SettingsIndex.item("bookmarks.side"))
        XCTAssertFalse(SettingsIndex.applies(item, prefs), "out of its section, dimmed in search, under a hidden bar")
        prefs.bookmarksBar = true
        XCTAssertTrue(prefs.sideBookmarks)
        XCTAssertTrue(SettingsIndex.applies(item, prefs))
    }

    func testTheBarAboveThePageKeepsItsOwnSwitch() {
        Store.settings.set(true, forKey: "sidebar")
        let prefs = Preferences()
        prefs.bookmarksBar = true
        prefs.bookmarksInSidebar = true
        prefs.bookmarksInSidebar = false
        XCTAssertTrue(prefs.bookmarksBar, "turned off, the bar above the page comes back as it was")
    }

    func testHeightAddsUpRowsGapsAndTheLine() {
        XCTAssertEqual(SideBookmarks.height(0, row: 28), 0)
        XCTAssertEqual(SideBookmarks.height(1, row: 28), 28 + 13)
        XCTAssertEqual(SideBookmarks.height(4, row: 28), 4 * 28 + 3 * 2 + 13)
        XCTAssertEqual(SideBookmarks.height(2, row: Metrics.iconTile), 2 * 32 + 2 + 13)
    }
}
