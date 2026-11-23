import XCTest
@testable import Search

final class DeveloperColorContrastFixTests: XCTestCase {
    private let white = DeveloperCSSColor.white
    private let black = DeveloperCSSColor.black

    func testThresholdsForNormalAndLargeText() {
        XCTAssertEqual(DeveloperContrastFix.thresholds(large: false).aa, 4.5)
        XCTAssertEqual(DeveloperContrastFix.thresholds(large: false).aaa, 7)
        XCTAssertEqual(DeveloperContrastFix.thresholds(large: true).aa, 3)
        XCTAssertEqual(DeveloperContrastFix.thresholds(large: true).aaa, 4.5)
        XCTAssertEqual(DeveloperContrastFix.label(4.5), "4.5")
        XCTAssertEqual(DeveloperContrastFix.label(7), "7")
    }

    func testAPassingColorIsItsOwnSuggestion() {
        XCTAssertEqual(DeveloperContrastFix.suggestion(for: black, on: white, ratio: 7), black)
        let lines = DeveloperContrastFix.lines(foreground: black, background: white, large: false)
        XCTAssertEqual(lines.map(\.passes), [true, true])
        XCTAssertEqual(lines.map(\.fix), [nil, nil])
    }

    func testLightGrayOnWhiteIsDarkenedJustEnough() throws {
        let gray = DeveloperCSSColor(red: 170, green: 170, blue: 170)
        XCTAssertLessThan(DeveloperCSSColor.contrast(gray, white), 4.5)
        let aa = try XCTUnwrap(DeveloperContrastFix.suggestion(for: gray, on: white, ratio: 4.5))
        let aaa = try XCTUnwrap(DeveloperContrastFix.suggestion(for: gray, on: white, ratio: 7))
        XCTAssertGreaterThanOrEqual(DeveloperCSSColor.contrast(aa, white), 4.5)
        XCTAssertGreaterThanOrEqual(DeveloperCSSColor.contrast(aaa, white), 7)
        // Still gray, darker, and the nearest: one step lighter fails.
        XCTAssertEqual(aa.red, aa.green)
        XCTAssertEqual(aa.green, aa.blue)
        XCTAssertLessThan(aa.red, gray.red)
        XCTAssertLessThan(aaa.red, aa.red)
        let lighter = DeveloperCSSColor(red: aa.red + 1, green: aa.green + 1, blue: aa.blue + 1)
        XCTAssertLessThan(DeveloperCSSColor.contrast(lighter, white), 4.5)
        // #767676 is the familiar lightest gray that passes AA on white.
        XCTAssertEqual(aa.hex, "#767676")
    }

    func testDarkTextOnABlackBackgroundIsLightened() throws {
        let navy = DeveloperCSSColor(red: 20, green: 30, blue: 90)
        let fix = try XCTUnwrap(DeveloperContrastFix.suggestion(for: navy, on: black, ratio: 4.5))
        XCTAssertGreaterThanOrEqual(DeveloperCSSColor.contrast(fix, black), 4.5)
        XCTAssertGreaterThan(fix.luminance, navy.luminance)
        // Same hue, within rounding.
        let (hue, _, _) = DeveloperContrastFix.hsl(navy)
        let (fixedHue, _, _) = DeveloperContrastFix.hsl(fix)
        XCTAssertEqual(fixedHue, hue, accuracy: 2)
    }

    func testTheNearerSideIsChosen() throws {
        // Mid gray on mid gray: darker and lighter both work; lighter is
        // nearer for a light foreground.
        let back = DeveloperCSSColor(red: 100, green: 100, blue: 100)
        let fore = DeveloperCSSColor(red: 140, green: 140, blue: 140)
        let fix = try XCTUnwrap(DeveloperContrastFix.suggestion(for: fore, on: back, ratio: 3))
        XCTAssertGreaterThan(fix.red, fore.red)
        XCTAssertGreaterThanOrEqual(DeveloperCSSColor.contrast(fix, back), 3)
    }

    func testNoSuggestionWhenNeitherSideReaches() {
        // On mid gray nothing gets to 7:1 either way.
        let back = DeveloperCSSColor(red: 119, green: 119, blue: 119)
        let fore = DeveloperCSSColor(red: 130, green: 130, blue: 130)
        XCTAssertNil(DeveloperContrastFix.suggestion(for: fore, on: back, ratio: 7))
    }

    func testLargeTextLinesUseTheLowerThresholds() throws {
        let gray = DeveloperCSSColor(red: 140, green: 140, blue: 140)
        let lines = DeveloperContrastFix.lines(foreground: gray, background: white, large: true)
        XCTAssertEqual(lines.map(\.level), ["AA", "AAA"])
        XCTAssertEqual(lines.map(\.threshold), [3, 4.5])
        XCTAssertTrue(lines[0].passes)
        XCTAssertFalse(lines[1].passes)
        let fix = try XCTUnwrap(lines[1].fix)
        XCTAssertGreaterThanOrEqual(DeveloperCSSColor.contrast(fix, white), 4.5)
    }

    func testAlphaIsKept() throws {
        // Drawn over white it is a light blue: the fix is a darker one,
        // still translucent.
        let faint = DeveloperCSSColor(red: 120, green: 120, blue: 255, alpha: 0.8)
        XCTAssertLessThan(DeveloperCSSColor.contrast(faint, white), 4.5)
        let fix = try XCTUnwrap(DeveloperContrastFix.suggestion(for: faint, on: white, ratio: 4.5))
        XCTAssertEqual(fix.alpha, 0.8)
        XCTAssertGreaterThanOrEqual(DeveloperCSSColor.contrast(fix, white), 4.5)
    }

    func testHSLRoundTrips() {
        let color = DeveloperCSSColor(red: 200, green: 80, blue: 40)
        let (h, s, l) = DeveloperContrastFix.hsl(color)
        let back = DeveloperContrastFix.rgb(hue: h, saturation: s, lightness: l)
        XCTAssertEqual(back.red, 200, accuracy: 0.001)
        XCTAssertEqual(back.green, 80, accuracy: 0.001)
        XCTAssertEqual(back.blue, 40, accuracy: 0.001)
    }
}
