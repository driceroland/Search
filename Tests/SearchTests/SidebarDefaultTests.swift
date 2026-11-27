import XCTest
@testable import Search

/// Tabs down the side for a new Search, and no move for anybody already
/// using one (SidebarDefault in Prefs.swift).
@available(macOS 14, *)
final class SidebarDefaultTests: XCTestCase {
    private var suite = ""
    private var store: UserDefaults!

    override func setUpWithError() throws {
        suite = "SidebarDefaultTests.\(UUID().uuidString)"
        store = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDown() {
        store.removePersistentDomain(forName: suite)
    }

    /// What Preferences.init reads after settling.
    private func launch(testing: Bool = false, ranBefore: Bool = false) -> Bool {
        SidebarDefault.settle(store, testing: testing, ranBefore: ranBefore)
        return store.object(forKey: "sidebar") as? Bool
            ?? store.string(forKey: "manner").map { $0 == "side" }
            ?? SidebarDefault.fresh(testing: testing)
    }

    func testFreshInstallGetsTheColumnAndWritesNoLine() {
        XCTAssertTrue(launch())
        XCTAssertNil(store.object(forKey: "sidebar"))
        XCTAssertTrue(store.bool(forKey: SidebarDefault.settledKey))
    }

    func testFreshInstallKeepsTheColumnAtItsSecondLaunch() {
        XCTAssertTrue(launch())
        // What the first run leaves: the welcome walked through, a session.
        store.set(true, forKey: "welcomed")
        store.set("{{0, 0}, {1200, 800}}", forKey: "NSWindow Frame search")
        XCTAssertTrue(launch(ranBefore: true))
        XCTAssertNil(store.object(forKey: "sidebar"))
    }

    func testExistingInstallWithNoLineKeepsTabsAcrossTheTop() {
        for trace in SidebarDefault.traces {
            store.removePersistentDomain(forName: suite)
            store.set(true, forKey: trace)
            XCTAssertFalse(launch(), trace)
            XCTAssertEqual(store.object(forKey: "sidebar") as? Bool, false, trace)
            // And it stays so at every launch after.
            XCTAssertFalse(launch(), trace)
        }
    }

    func testExistingInstallFoundByItsFilesAlone() {
        XCTAssertFalse(launch(ranBefore: true))
        XCTAssertEqual(store.object(forKey: "sidebar") as? Bool, false)
    }

    func testAChoiceAlreadyMadeIsLeftAlone() {
        store.set(true, forKey: "welcomed")
        store.set(true, forKey: "sidebar")
        XCTAssertTrue(launch(ranBefore: true))
        store.removePersistentDomain(forName: suite)
        store.set(true, forKey: "welcomed")
        store.set(false, forKey: "sidebar")
        XCTAssertFalse(launch(ranBefore: true))
    }

    func testTheOldMannerLineStillDecides() {
        store.set("side", forKey: "manner")
        XCTAssertTrue(launch(ranBefore: true))
        XCTAssertNil(store.object(forKey: "sidebar"))
        store.removePersistentDomain(forName: suite)
        store.set("strip", forKey: "manner")
        XCTAssertFalse(launch(ranBefore: true))
        XCTAssertNil(store.object(forKey: "sidebar"))
    }

    func testTestWorldsKeepTabsAcrossTheTopAndWriteNothing() {
        XCTAssertFalse(launch(testing: true))
        store.set(true, forKey: "welcomed")
        store.removeObject(forKey: SidebarDefault.settledKey)
        XCTAssertFalse(launch(testing: true, ranBefore: true))
        XCTAssertNil(store.object(forKey: "sidebar"))
    }

    func testRanBeforeLooksForTheSessionFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertFalse(SidebarDefault.ranBefore(in: folder))
        try Data("{}".utf8).write(to: folder.appendingPathComponent("session.json"))
        XCTAssertTrue(SidebarDefault.ranBefore(in: folder))
    }
}
