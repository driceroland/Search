import AppKit
import XCTest
@testable import Search

/// A space's colour washes the chrome behind the tabs; a space without one
/// leaves it exactly as it was.
@MainActor
final class SpaceWashTests: XCTestCase {
    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    func testNoColourNoWash() {
        XCTAssertNil(Tints.wash(nil, dark: false))
        XCTAssertNil(Tints.wash(0, dark: false))
        XCTAssertNil(Tints.wash(0, dark: true))
        // From a newer Search with more colours, or a broken list.
        XCTAssertNil(Tints.wash(Tints.colours.count, dark: false))
        XCTAssertNil(Tints.wash(-1, dark: true))
    }

    func testEveryColourWashesFaintlyAndDarkTakesMore() {
        for colour in 1..<Tints.colours.count {
            let light = Tints.wash(colour, dark: false)
            let dark = Tints.wash(colour, dark: true)
            XCTAssertEqual(light, Tints.washLight, Tints.colourNames[colour])
            XCTAssertEqual(dark, Tints.washDark, Tints.colourNames[colour])
        }
        XCTAssertGreaterThan(Tints.washDark, Tints.washLight)
        // A wash, not a fill: a tab's grey and a title's ink keep their contrast.
        XCTAssertLessThanOrEqual(Tints.washDark, 0.15)
        XCTAssertGreaterThan(Tints.washLight, 0)
    }

}
