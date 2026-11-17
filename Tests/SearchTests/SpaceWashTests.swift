import AppKit
import XCTest
@testable import Search

/// A space's colour washes the chrome behind the tabs; a space without one
/// leaves it exactly as it was.
@MainActor
final class SpaceWashTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "space-wash-\(getpid())", 1)
        super.setUp()
    }

    func testNoColourNoWash() {
        XCTAssertNil(Spaces.wash(nil, dark: false))
        XCTAssertNil(Spaces.wash(0, dark: false))
        XCTAssertNil(Spaces.wash(0, dark: true))
        // From a newer Search with more colours, or a broken list.
        XCTAssertNil(Spaces.wash(Spaces.colours.count, dark: false))
        XCTAssertNil(Spaces.wash(-1, dark: true))
    }

    func testEveryColourWashesFaintlyAndDarkTakesMore() {
        for colour in 1..<Spaces.colours.count {
            let light = Spaces.wash(colour, dark: false)
            let dark = Spaces.wash(colour, dark: true)
            XCTAssertEqual(light, Spaces.washLight, Spaces.colourNames[colour])
            XCTAssertEqual(dark, Spaces.washDark, Spaces.colourNames[colour])
        }
        XCTAssertGreaterThan(Spaces.washDark, Spaces.washLight)
        // A wash, not a fill: a tab's grey and a title's ink keep their contrast.
        XCTAssertLessThanOrEqual(Spaces.washDark, 0.15)
        XCTAssertGreaterThan(Spaces.washLight, 0)
    }

    /// The wash is the space on screen's, follows a switch, and is none with
    /// spaces off or while a new space is being made.
    func testWashFollowsTheSpaceShown() {
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
                          Space(id: second, name: "Second", colour: 2)]
        browser.closeAll()
        browser.showRow([], active: nil, blank: true)

        XCTAssertNil(browser.washColour, "no colour, no wash")
        browser.switchSpace(to: second)
        XCTAssertEqual(browser.washColour, 2)

        browser.setSpaceColour(second, to: 4)
        XCTAssertEqual(browser.washColour, 4)
        browser.setSpaceColour(second, to: 0)
        XCTAssertNil(browser.washColour, "back to none, back to today's look")
        browser.setSpaceColour(second, to: 4)

        browser.makingSpace = true
        XCTAssertNil(browser.washColour, "the card for a new space has no colour yet")
        browser.makingSpace = false

        browser.prefs.usesSpaces = false
        XCTAssertNil(browser.washColour, "spaces off, no wash")
        browser.prefs.usesSpaces = true

        browser.switchSpace(to: first)
        XCTAssertNil(browser.washColour)
    }
}
