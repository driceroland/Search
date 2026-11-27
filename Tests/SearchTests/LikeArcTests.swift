import AppKit
import XCTest
@testable import Search

/// Set Up Like Arc (idea 964): the Arc habits added since 1.0.7 come on
/// with it, a choice already made is left alone, and Undo puts every key
/// back, whichever of its three places (Settings, the welcome, after Arc's
/// spaces came) it was pressed in.
@available(macOS 14, *)
@MainActor
final class LikeArcTests: XCTestCase {
    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    override func setUp() { _ = NSApplication.shared }

    /// Nothing like Arc, with choices of its own that Undo must give back.
    private func unlike(_ prefs: Preferences) {
        prefs.sidePosition = .right
        prefs.sideIcons = false
        prefs.sidebar = false
        prefs.usesSpaces = false
        prefs.listsPins = false
        prefs.pinsGoHome = false
        prefs.pinsPeek = true
        prefs.floatingNewTab = false
        prefs.tabLife = .never
        prefs.floatsOnLeave = false
        prefs.floatsAway = false
        prefs.swipeBackCloses = false
        prefs.peekClick = .optionCommand
        prefs.peeksLinks = false
        XCTAssertFalse(prefs.looksLikeArc)
    }

    private func assertArc(_ prefs: Preferences, _ line: UInt = #line) {
        XCTAssertTrue(prefs.looksLikeArc, line: line)
        XCTAssertEqual(prefs.tabsLayout, .left, line: line)
        XCTAssertTrue(prefs.usesSpaces && prefs.listsPins && prefs.pinsGoHome && prefs.pinsPeek && prefs.floatingNewTab, line: line)
        XCTAssertEqual(prefs.tabLife, .halfDay, "Arc's 12 hours", line: line)
        XCTAssertEqual(prefs.floatOwn, .tabs, "out when you leave its tab", line: line)
        XCTAssertTrue(prefs.swipeBackCloses, line: line)
        XCTAssertEqual(prefs.peekChoice, .shift, "Arc's Shift-click", line: line)
    }

    private func assertUnlike(_ prefs: Preferences, _ line: UInt = #line) {
        XCTAssertFalse(prefs.looksLikeArc, line: line)
        XCTAssertEqual(prefs.tabsLayout, .top, line: line)
        XCTAssertEqual(prefs.sidePosition, .right, "the side kept under the top layout", line: line)
        XCTAssertFalse(prefs.usesSpaces || prefs.listsPins || prefs.pinsGoHome || prefs.floatingNewTab, line: line)
        XCTAssertTrue(prefs.pinsPeek, line: line)
        XCTAssertEqual(prefs.tabLife, .never, line: line)
        XCTAssertFalse(prefs.floatsOnLeave || prefs.floatsAway, line: line)
        XCTAssertFalse(prefs.swipeBackCloses, line: line)
        XCTAssertFalse(prefs.peeksLinks, line: line)
        XCTAssertEqual(prefs.peekClick, .optionCommand, "the click chosen before", line: line)
    }

    func testSetUpNamesEveryChangeAndUndoPutsItBack() {
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        let prefs = browser.prefs
        unlike(prefs)
        let changed = LikeArc.shared.setUp(prefs)
        assertArc(prefs)
        XCTAssertEqual(changed, ["tabs on the left", "Spaces", "pinned rows", "pins keep their site", "the floating new tab",
                                 "tabs close after 12 hours", "the video floats on its own",
                                 "swipe back closes a link's tab", "Shift-click peeks at a link"])
        XCTAssertTrue(LikeArc.shared.undoable(prefs))
        LikeArc.shared.undo(prefs)
        assertUnlike(prefs)
        XCTAssertFalse(LikeArc.shared.undoable(prefs))
    }

    func testChoicesAlreadyMadeAreLeftAlone() {
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        let prefs = browser.prefs
        unlike(prefs)
        prefs.tabLife = .week
        prefs.floatOwn = .tabsOrApps
        prefs.peekChoice = .optionShift
        let changed = LikeArc.shared.setUp(prefs)
        XCTAssertTrue(prefs.looksLikeArc)
        XCTAssertEqual(prefs.tabLife, .week)
        XCTAssertEqual(prefs.floatOwn, .tabsOrApps)
        XCTAssertEqual(prefs.peekChoice, .optionShift)
        XCTAssertFalse(changed.contains("tabs close after 12 hours") || changed.contains("Shift-click peeks at a link"))
        LikeArc.shared.undo(prefs)
        unlike(prefs)
    }

    func testFindASettingFindsItByArcsWords() {
        for words in ["arc", "auto archive", "peek"] {
            XCTAssertTrue(SettingsIndex.find(words).contains { $0.id == "arc.setup" }, words)
        }
    }
}
