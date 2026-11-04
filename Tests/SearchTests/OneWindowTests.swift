import XCTest
@testable import Search

/// Profiles in one window (OneWindow.swift): what windows.json keeps of a
/// merged window, and the switch in Settings.
@MainActor
final class OneWindowTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "one-window-\(getpid())", 1)
        super.setUp()
    }

    func testRecordKeepsTheMergedWindow() throws {
        var record = WindowRecord(space: Space.firstID)
        record.merge = UUID()
        record.tucked = true
        let back = try JSONDecoder().decode(WindowRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(back.merge, record.merge)
        XCTAssertEqual(back.tucked, true)
    }

    func testOlderRecordIsAWindowOfItsOwn() throws {
        let old = #"{"id":"\#(UUID().uuidString)","space":"\#(Space.firstID.uuidString)"}"#
        let back = try JSONDecoder().decode(WindowRecord.self, from: Data(old.utf8))
        XCTAssertNil(back.merge)
        XCTAssertNil(back.tucked)
    }

    func testOffByDefaultAndFindable() {
        let saved = Store.settings.object(forKey: "profiles.oneWindow")
        defer { Store.settings.set(saved, forKey: "profiles.oneWindow") }
        Store.settings.removeObject(forKey: "profiles.oneWindow")
        XCTAssertFalse(Preferences().profilesInOneWindow)
        for words in ["profiles in one window", "one window", "single window"] {
            XCTAssertTrue(SettingsIndex.find(words).contains { $0.id == "profiles.oneWindow" }, words)
        }
        XCTAssertEqual(SettingsIndex.item("profiles.oneWindow")?.parent, "profiles")
    }
}
