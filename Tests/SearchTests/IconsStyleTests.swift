import AppKit
import XCTest
@testable import Search

/// One icons-only switch, two looks (Prefs.swift, IconsStyle): upstream's
/// still 52pt column by default, the dynamic 42pt rail when asked for.
@MainActor
final class IconsStyleTests: XCTestCase {
    private var browsers: [Browser] = []

    override class func setUp() {
        setenv("SEARCH_PROBE", "bld-ai-iconsstyle-\(getpid())", 1)
        super.setUp()
    }

    override class func tearDown() {
        if let world = Store.world, world.hasPrefix("bld-ai-iconsstyle-") {
            try? FileManager.default.removeItem(at: Store.folder)
            UserDefaults.standard.removePersistentDomain(forName: "com.officecommun.search.test.\(world)")
        }
        super.tearDown()
    }

    override func tearDown() async throws {
        for browser in browsers { browser.closeAll() }
        browsers.removeAll()
        try await super.tearDown()
    }

    private func makeBrowser() -> Browser {
        let browser = Browser(record: WindowRecord())
        browsers.append(browser)
        return browser
    }

    func testIconsOnlyKeepsUpstreamsStillColumn() {
        let browser = makeBrowser()
        let prefs = browser.prefs
        prefs.iconsStyle = .column
        prefs.sideWidth = 300
        prefs.tabsLayout = .icons

        XCTAssertEqual(prefs.iconsStyle, .column)
        XCTAssertTrue(prefs.iconColumn)
        XCTAssertFalse(prefs.iconDynamic, "icons only is not the dynamic rail by itself")
        XCTAssertEqual(prefs.columnWidth, Metrics.iconColumn, "52 points, as upstream has it")
        XCTAssertEqual(prefs.sideRow, Metrics.iconTile, "32-point tiles")
        XCTAssertEqual(prefs.sideWidth, 300, "the titled width is kept, not used")
    }

    func testDynamicRailIsTheSameSwitchWithItsOwnWidth() {
        let browser = makeBrowser()
        let prefs = browser.prefs
        prefs.sideWidth = 300
        prefs.tabsLayout = .icons
        prefs.iconsStyle = .dynamic

        XCTAssertTrue(prefs.iconColumn, "one entry point: the same icons-only switch")
        XCTAssertTrue(prefs.iconDynamic)
        XCTAssertEqual(prefs.columnWidth, Metrics.iconSide, "the rail's 42 points")
        XCTAssertEqual(prefs.sideWidth, 300, "the titled width is still kept")
        XCTAssertEqual(Store.settings.string(forKey: "sidebar.icons.style"), "dynamic", "persisted at its own key")
    }

    func testTheLookDoesNothingWhileTheColumnShowsTitles() {
        let browser = makeBrowser()
        let prefs = browser.prefs
        prefs.sideWidth = 250
        prefs.tabsLayout = .left
        prefs.iconsStyle = .dynamic

        XCTAssertFalse(prefs.iconColumn)
        XCTAssertFalse(prefs.iconDynamic, "the rail is icons only, not a look for the titled column")
        XCTAssertEqual(prefs.columnWidth, 250)
    }

    func testTheStandardColumnIsTheDefaultAndAnUnknownStoredStyleFallsBackToIt() {
        // Preferences.init reads `flatMap(IconsStyle.init) ?? .column`.
        XCTAssertEqual(IconsStyle.allCases.first, .column, "the standard column is the default")
        XCTAssertNil(IconsStyle(rawValue: "future-style"))
        XCTAssertEqual(IconsStyle.allCases.map(\.title), ["Standard column", "Dynamic rail"])
    }

    func testTheEdgeSnapsInToTheRailAndOutToTheTitledWidth() {
        let browser = makeBrowser()
        let prefs = browser.prefs
        prefs.tabsLayout = .left
        prefs.sideWidth = 300

        SidebarResize.apply(proposed: 100, to: prefs)
        XCTAssertTrue(prefs.iconDynamic, "dragging in snaps to the dynamic rail")
        XCTAssertEqual(prefs.columnWidth, Metrics.iconSide)
        XCTAssertEqual(prefs.sideWidth, 300, "the wide width is remembered")

        SidebarResize.apply(proposed: 102, to: prefs)
        XCTAssertFalse(prefs.iconColumn, "dragging out brings the titles back")
        XCTAssertEqual(prefs.sideWidth, SidebarResize.expandedMin)
    }
}
