import XCTest
@testable import Search

/// Settings › Spaces & Pins › Three pins to a row: off unless asked for,
/// where the squares' rows are what they were; on, a row takes three at
/// most, so four pins are two rows of two. On the model and the rows'
/// arithmetic only.
@MainActor
final class PinsAcrossTests: XCTestCase {
    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    private let key = "pins.threeAcross"
    private var saved: Any?

    override func setUp() async throws {
        saved = Store.settings.object(forKey: key)
        Store.settings.removeObject(forKey: key)
    }

    override func tearDown() async throws {
        Store.settings.set(saved, forKey: key)
    }

    func testOffUnlessAskedFor() {
        let prefs = Preferences()
        XCTAssertFalse(prefs.pinsThreeAcross)
        XCTAssertEqual(prefs.pinsAcross, 4)
        XCTAssertNil(Store.settings.object(forKey: key), "nothing written just for reading it")
    }

    func testOffTheRowsAreAsTheyWere() {
        let most = Preferences().pinsAcross
        XCTAssertEqual(SideBar.pinRows(0, most: most), [])
        XCTAssertEqual(SideBar.pinRows(3, most: most), [3])
        XCTAssertEqual(SideBar.pinRows(4, most: most), [4])
        XCTAssertEqual(SideBar.pinRows(5, most: most), [3, 2])
        XCTAssertEqual(SideBar.pinRows(7, most: most), [4, 3])
        XCTAssertEqual(SideBar.pinRows(8, most: most), [4, 4])
        XCTAssertEqual(SideBar.pinRows(10, most: most), [4, 3, 3])
    }

    func testOnARowTakesThreeAtMost() {
        let prefs = Preferences()
        prefs.pinsThreeAcross = true
        XCTAssertEqual(prefs.pinsAcross, 3)
        let most = prefs.pinsAcross
        // Up to three are the one row they always were.
        XCTAssertEqual(SideBar.pinRows(1, most: most), [1])
        XCTAssertEqual(SideBar.pinRows(3, most: most), [3])
        XCTAssertEqual(SideBar.pinRows(4, most: most), [2, 2])
        XCTAssertEqual(SideBar.pinRows(5, most: most), [3, 2])
        XCTAssertEqual(SideBar.pinRows(6, most: most), [3, 3])
        XCTAssertEqual(SideBar.pinRows(7, most: most), [3, 2, 2])
        XCTAssertEqual(SideBar.pinRows(8, most: most), [3, 3, 2])
        XCTAssertEqual(SideBar.pinRows(12, most: most), [3, 3, 3, 3])
        for count in 1...24 {
            let rows = SideBar.pinRows(count, most: most)
            XCTAssertEqual(rows.reduce(0, +), count, "\(count)")
            XCTAssertLessThanOrEqual(rows.max() ?? 0, 3, "\(count)")
        }
    }

    func testTheSwitchIsKept() {
        let prefs = Preferences()
        prefs.pinsThreeAcross = true
        XCTAssertEqual(Store.settings.object(forKey: key) as? Bool, true)
        XCTAssertEqual(Preferences().pinsAcross, 3, "read back at the next launch")
        prefs.pinsThreeAcross = false
        XCTAssertEqual(Preferences().pinsAcross, 4)
    }

    func testItsRowInSettings() throws {
        let item = try XCTUnwrap(SettingsIndex.item("pins.threeAcross"))
        XCTAssertEqual(item.group, "pins")
        let prefs = Preferences()
        let side = prefs.sidebar
        defer { prefs.sidebar = side }
        prefs.sidebar = true
        XCTAssertTrue(SettingsIndex.applies(item, prefs))
        // Across the top every pin sits in the one row of tabs.
        prefs.sidebar = false
        XCTAssertFalse(SettingsIndex.applies(item, prefs))
    }
}
