import AppKit
import XCTest
@testable import Search

@MainActor
final class SpaceCardTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "space-card-\(getpid())", 1)
        super.setUp()
    }

    /// ⌃1–⌃9 or the dot menu, with the card for a new space up: the card goes,
    /// and what it was asked to do with the space it would have made goes too.
    func testGoingToAnotherSpacePutsTheNewSpaceCardAway() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let browser = Browser(record: WindowRecord())
        let oldUsesSpaces = browser.prefs.usesSpaces
        let oldSpaces = browser.spaces
        defer {
            browser.closeAll()
            browser.prefs.usesSpaces = oldUsesSpaces
            browser.spaces = oldSpaces
        }
        browser.prefs.usesSpaces = true
        let first = browser.spaceID
        let second = UUID()
        browser.spaces = [Space(id: first, name: "First", colour: 0),
                          Space(id: second, name: "Second", colour: 1)]
        browser.closeAll()
        browser.showRow([], active: nil, blank: true)

        var stale: Space?
        browser.afterSpaceCreated = { stale = $0 }
        browser.makingSpace = true
        browser.switchSpace(to: second)
        XCTAssertEqual(browser.spaceID, second)
        XCTAssertFalse(browser.makingSpace)
        XCTAssertNil(browser.afterSpaceCreated)

        // A later Create makes the space and goes there, as a fresh one does.
        browser.addSpace(named: "Third")
        let third = browser.spaces.last!
        XCTAssertEqual(third.name, "Third")
        XCTAssertEqual(browser.spaceID, third.id)
        XCTAssertNil(stale)

        // The space the card was made from, chosen again, puts the card away too.
        browser.makingSpace = true
        browser.switchSpace(to: third.id)
        XCTAssertEqual(browser.spaceID, third.id)
        XCTAssertFalse(browser.makingSpace)
    }
}
