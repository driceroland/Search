import AppKit
import XCTest
@testable import Search

/// The address above the page (Toolbar.swift): only with the address in
/// sight, put there, and the tabs down a side; while it is, the column
/// gives up back, forward, reload and the extensions, so each is drawn once.
@MainActor
final class ToolbarTests: XCTestCase {
    override class func setUp() { TestWorld.enter(); super.setUp() }

    func testOnlyAboveThePageWithTheTabsDownASide() {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        let prefs = browser.prefs
        let saved = (prefs.addressLine, prefs.sidebar, prefs.addressPlace, prefs.hidesExtensionsDoor)
        defer {
            prefs.addressLine = saved.0; prefs.sidebar = saved.1
            prefs.addressPlace = saved.2; prefs.hidesExtensionsDoor = saved.3
        }
        prefs.hidesExtensionsDoor = false
        prefs.addressLine = true
        prefs.sidebar = true
        prefs.addressPlace = .side
        XCTAssertFalse(prefs.toolbar, "In the column: no row above the page")
        XCTAssertEqual(prefs.rowHelmDoors, prefs.helmDoors, "the lights' row keeps its doors")
        XCTAssertTrue(prefs.footPuzzle, "and the foot its puzzle")

        prefs.addressPlace = .page
        XCTAssertTrue(prefs.toolbar, "Above the page with the tabs down a side")
        XCTAssertEqual(prefs.rowHelmDoors, 0, "back, forward and reload go up to the row")
        XCTAssertEqual(Metrics.helm(prefs), 0, "and the lights' row makes no room for them")
        XCTAssertFalse(prefs.footPuzzle, "the puzzle goes up to the row too")

        prefs.sidebar = false
        XCTAssertFalse(prefs.toolbar, "Tabs across the top: the strip has all of it")
        XCTAssertEqual(prefs.rowHelmDoors, prefs.helmDoors)

        prefs.sidebar = true
        prefs.addressLine = false
        XCTAssertFalse(prefs.toolbar, "The address not shown: no row for it")
    }

    func testSidebarByDefaultAndListed() {
        let store = UserDefaults(suiteName: "toolbar-\(UUID().uuidString)")!
        XCTAssertNil(store.string(forKey: "address.place").flatMap(AddressPlace.init))
        XCTAssertEqual(AddressPlace(rawValue: "page"), .page)
        XCTAssertNil(AddressPlace(rawValue: "nonsense"), "an unknown value falls back to the column")
        let item = SettingsIndex.items.first { $0.id == "address.place" }
        XCTAssertNotNil(item)
        XCTAssertEqual(item?.parent, "address.shown")
    }
}
