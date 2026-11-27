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

    private let keys = ["sidebar", "bookmarks.bar", "bookmarks.side", "bookmarks.iconsOnly"]
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
        XCTAssertEqual(SideBookmarks.height(2, row: 28, lined: false), 2 * 28 + 2, "with the keep line straight after, no line of its own (idea 1255)")
    }

    /// Show Icons Only follows the bar into the column (idea 1326): the
    /// bookmarks between two folders sit side by side as tiles, as many as
    /// fit across, in the bar's order; folders keep a row and their names.
    /// No setting of its own, and the height the column adds up is the
    /// lines drawn.
    func testIconsOnlyTilesTheBookmarksInTheColumn() throws {
        func mark(_ n: Int) -> Bookmark { Bookmark(title: "Site \(n)", url: "https://s\(n).example/", children: nil) }
        let folder = Bookmark(title: "Work", url: nil, children: [mark(99)])
        let roots = (0..<5).map(mark) + [folder] + [mark(5), mark(6)]
        // 4 tiles of 28 with gaps of 2 across 120 points: (120 + 2) / 30.
        let lines = SideBookmarks.lines(roots, tiles: true, room: 120, row: 28)
        XCTAssertEqual(lines.map { $0.map(\.title) }, [
            ["Site 0", "Site 1", "Site 2", "Site 3"], ["Site 4"], ["Work"], ["Site 5", "Site 6"],
        ])
        XCTAssertEqual(lines.flatMap { $0 }.map(\.id), roots.map(\.id), "every bookmark, in the bar's order")
        XCTAssertEqual(SideBookmarks.lines(roots, tiles: false, room: 120, row: 28).count, roots.count, "off: a row each")
        XCTAssertEqual(SideBookmarks.lines([mark(0), mark(1)], tiles: true, room: 0, row: 28).count, 2, "never fewer than one across")

        Store.settings.set(true, forKey: "sidebar")
        let prefs = Preferences()
        prefs.bookmarksBar = true
        prefs.bookmarksInSidebar = true
        prefs.bookmarksIconsOnly = false
        XCTAssertFalse(SideBookmarks.tiles(prefs, compact: false), "off unless asked for")
        prefs.bookmarksIconsOnly = true
        XCTAssertTrue(SideBookmarks.tiles(prefs, compact: false), "the bar's own switch, in the column too")
        XCTAssertFalse(SideBookmarks.tiles(prefs, compact: true), "the column icons only: every bookmark a tile already")
        let item = try XCTUnwrap(SettingsIndex.item("bookmarks.iconsOnly"))
        XCTAssertTrue(SettingsIndex.applies(item, prefs), "the switch applies with the bookmarks in the sidebar")
        XCTAssertTrue(WhatsNew.toggles.contains { $0.title == "Icons only on the bookmarks bar" && $0.shown(prefs) })
    }
}
