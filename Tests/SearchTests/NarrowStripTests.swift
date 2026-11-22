import XCTest
@testable import Search

/// Settings › Appearance › Tabs › Narrow to icons: off unless asked for;
/// on, the column is never drawn under the line with titles, and pulled
/// under it is the strip of icons until it is pulled back out. On the
/// model only.
@MainActor
final class NarrowStripTests: XCTestCase {
    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    private let keys = ["sidebar", "sidebar.icons", "sidebar.narrowIcons", "sidebar.narrowed", "sidebar.width"]
    private var saved: [(String, Any?)] = []

    override func setUp() async throws {
        saved = keys.map { ($0, Store.settings.object(forKey: $0)) }
        keys.forEach(Store.settings.removeObject(forKey:))
        Store.settings.set(true, forKey: "sidebar")
    }

    override func tearDown() async throws {
        for (key, value) in saved { Store.settings.set(value, forKey: key) }
    }

    func testOffUnlessAskedFor() {
        let prefs = Preferences()
        XCTAssertFalse(prefs.narrowsToIcons)
        prefs.sideWidth = Metrics.sideMin
        prefs.narrowed = true
        XCTAssertFalse(prefs.narrowStrip)
        XCTAssertFalse(prefs.iconColumn)
        XCTAssertEqual(prefs.columnWidth, Metrics.sideMin)
    }

    func testNeverUnderTheLineWithTitles() {
        let prefs = Preferences()
        prefs.narrowsToIcons = true
        prefs.sideWidth = Metrics.sideMin
        XCTAssertEqual(prefs.columnWidth, Metrics.narrowLine)
        prefs.sideWidth = 300
        XCTAssertEqual(prefs.columnWidth, 300)
    }

    func testNarrowedIsTheStripAndKeepsTheWidthForLater() {
        let prefs = Preferences()
        prefs.narrowsToIcons = true
        prefs.sideWidth = 260
        prefs.narrowed = true
        XCTAssertTrue(prefs.narrowStrip)
        XCTAssertTrue(prefs.iconColumn)
        XCTAssertEqual(prefs.columnWidth, Metrics.iconColumn)
        XCTAssertTrue(Preferences().narrowStrip, "still a strip after a relaunch")
        prefs.narrowed = false
        XCTAssertEqual(prefs.columnWidth, 260)
    }

    func testTheEdgeHeldNarrowsAtTheLineAndBack() {
        // Off: clamped as it always was, never the strip.
        XCTAssertEqual(SideBar.held(100, narrows: false).width, Metrics.sideMin)
        XCTAssertFalse(SideBar.held(100, narrows: false).narrow)
        // On: under the line is the strip, at it and past it titles.
        XCTAssertTrue(SideBar.held(Metrics.narrowLine - 1, narrows: true).narrow)
        XCTAssertNil(SideBar.held(Metrics.narrowLine - 1, narrows: true).width)
        XCTAssertEqual(SideBar.held(Metrics.narrowLine, narrows: true).width, Metrics.narrowLine)
        XCTAssertEqual(SideBar.held(1000, narrows: true).width, Metrics.sideMax)
        // Taken from the strip, a short pull brings titles back.
        let fromStrip = Metrics.narrowLine - SideBar.stripPull
        XCTAssertTrue(SideBar.held(fromStrip + SideBar.stripPull - 1, narrows: true).narrow)
        XCTAssertFalse(SideBar.held(fromStrip + SideBar.stripPull, narrows: true).narrow)
    }

    func testIconsOnlyIsNotTheStrip() {
        let prefs = Preferences()
        prefs.narrowsToIcons = true
        prefs.narrowed = true
        prefs.sideIcons = true
        XCTAssertFalse(prefs.narrowStrip, "icons only keeps back, forward and reload")
        XCTAssertTrue(prefs.iconColumn)
        prefs.sideIcons = false
        prefs.sidebar = false
        XCTAssertFalse(prefs.narrowStrip)
        XCTAssertFalse(prefs.iconColumn)
    }
}
