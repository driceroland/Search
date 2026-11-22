import Foundation
import XCTest
@testable import Search

/// Settings › Tabs › Archive tabs you leave alone: off unless turned on,
/// twelve hours when first turned on, and the time chosen last kept while off.
@MainActor
final class ArchiveSwitchTests: XCTestCase {
    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    override func tearDown() {
        Store.settings.removeObject(forKey: "tabs.close.after")
        Store.settings.removeObject(forKey: "tabs.close.after.chosen")
        super.tearDown()
    }

    func testOffUntilTurnedOnThenTwelveHours() {
        Store.settings.removeObject(forKey: "tabs.close.after")
        Store.settings.removeObject(forKey: "tabs.close.after.chosen")
        let prefs = Preferences()
        XCTAssertFalse(prefs.archivesTabs)
        XCTAssertEqual(prefs.tabLife, .never)
        prefs.archivesTabs = true
        XCTAssertEqual(prefs.tabLife, .halfDay)
    }

    func testTheTimeChosenComesBackWithTheSwitch() {
        let prefs = Preferences()
        XCTAssertTrue(SettingsIndex.apply("tabs.close.after", 168, to: prefs))
        XCTAssertEqual(prefs.tabLife, .week)
        XCTAssertTrue(SettingsIndex.apply("tabs.close.after", false, to: prefs))
        XCTAssertEqual(prefs.tabLife, .never)
        XCTAssertTrue(SettingsIndex.apply("tabs.close.after", true, to: prefs))
        XCTAssertEqual(prefs.tabLife, .week)
        XCTAssertFalse(SettingsIndex.apply("tabs.close.after", 5, to: prefs))
    }
}
