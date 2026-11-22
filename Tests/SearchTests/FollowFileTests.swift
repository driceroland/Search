import XCTest
@testable import Search

/// Settings read again while Search runs (Preferences.reread): only the look
/// and layout of the tabs, the sidebar and the window, read the way launch
/// reads them; a protection written from outside waits for the next launch,
/// a line this build can't read is left alone, and a line taken out stays out.
@MainActor
final class FollowFileTests: XCTestCase {
    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    /// The list agreed on #736. A setting added here is a choice to read
    /// for the reviewer, so the test names every one.
    func testOnlyTheLookAndLayoutAreReadAgain() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Search/Prefs.swift")
        let source = try String(contentsOf: file, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "func reread()"))
        let end = try XCTUnwrap(source.range(of: "func take<", range: start.upperBound..<source.endIndex))
        let read = Set(source[start.upperBound..<end.lowerBound].components(separatedBy: "take(\\.").dropFirst()
            .map { String($0.prefix { $0.isLetter || $0.isNumber }) })
        XCTAssertEqual(read, [
            "look", "navigationLeft", "sidebar", "sidePosition", "sideHides", "roomyTabs", "sideIcons", "sideWidth",
            "sidePanelWidth", "cards", "glyph", "tabsGive", "showsTabShortcuts", "bookmarksBar", "alwaysShowsDownloads",
            "foldsToIcons", "instantMotion", "compactStrip",
            // Look and layout settings added since, each read again as it was
            // added: the column's slide, buttons at the top, the card in full
            // screen, the address bar and its width, the glass window and the
            // Liquid Glass tab, the bounce, and ⌘1–⌘9 for spaces.
            "slidesColumn", "doorsUp", "cardsInFullScreen", "addressLine", "addressWidth", "glass", "glassGrain",
            "glassClear", "glassStyle", "liquidTabs", "bounces", "spacesOnCommand",
            // Themes: the empty tab's background is part of the look.
            "homeTheme", "homeThemeImage", "homeTuning", "homeShuffle",
            // The column narrowed to icons, and the sidebar button beside the
            // window's buttons (#1360, #1351).
            "narrowed", "narrowsToIcons", "foldButton",
            // The bookmarks bar at the top of the sidebar (#1390).
            "bookmarksInSidebar",
            // A click on the tab you're on edits its address only (idea 951).
            "tabClickAddressOnly",
        ])
    }

    func testAProtectionWrittenFromOutsideWaitsForLaunch() {
        let prefs = Preferences()
        let keys = ["shield", "tabs.address", "sidebar.roomy"]
        defer { keys.forEach(Store.settings.removeObject) }
        Store.settings.set(false, forKey: "shield")
        Store.settings.set(false, forKey: "tabs.address")
        Store.settings.set(true, forKey: "sidebar.roomy")
        prefs.reread()
        XCTAssertTrue(prefs.shielded)
        XCTAssertTrue(prefs.showsAddress)
        XCTAssertTrue(prefs.roomyTabs)
    }

    func testAFileNothingChangedInSetsNothing() {
        let prefs = Preferences()
        var sets = 0
        let watching = prefs.objectWillChange.sink { sets += 1 }
        defer { watching.cancel(); Store.settings.removeObject(forKey: "sidebar.position") }
        prefs.reread()
        XCTAssertEqual(sets, 0)
        Store.settings.set("right", forKey: "sidebar.position")
        prefs.reread()
        XCTAssertEqual(prefs.sidePosition, .right)
        XCTAssertEqual(sets, 1)
    }

    func testALineThisBuildCantReadIsLeftAlone() {
        let prefs = Preferences()
        defer { ["sidebar.position", "look"].forEach(Store.settings.removeObject) }
        Store.settings.set("right", forKey: "sidebar.position")
        Store.settings.set("dark", forKey: "look")
        prefs.reread()
        // A place a newer build offers, and a typo.
        Store.settings.set("middle", forKey: "sidebar.position")
        Store.settings.set("Dark", forKey: "look")
        prefs.reread()
        XCTAssertEqual(prefs.sidePosition, .right)
        XCTAssertEqual(prefs.look, .dark)
        XCTAssertEqual(Store.settings.string(forKey: "sidebar.position"), "middle")
        XCTAssertEqual(Store.settings.string(forKey: "look"), "Dark")
    }

    func testALineTakenOutPutsTheDefaultBackAndStaysOut() {
        let prefs = Preferences()
        let keys = ["layout.cards", "look"]
        defer { keys.forEach(Store.settings.removeObject) }
        prefs.cards = false
        prefs.look = .dark
        keys.forEach(Store.settings.removeObject)
        prefs.reread()
        XCTAssertTrue(prefs.cards)
        XCTAssertEqual(prefs.look, .system)
        XCTAssertEqual(keys.filter { Store.settings.object(forKey: $0) != nil }, [])
    }
}
