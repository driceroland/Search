import JavaScriptCore
import XCTest
@testable import Search

/// Rendering's emulations done in the page: the media query rewrite, which
/// options go to the page rather than to WebKit, and the script as sent.
@MainActor
final class DeveloperRenderingPageTests: XCTestCase {
    private func rewrite(_ text: String, _ overrides: [String: String]) throws -> String {
        let context = try XCTUnwrap(JSContext())
        let function = context.evaluateScript("(" + DeveloperRenderingPage.mediaRewriter + "\n)")
        XCTAssertNil(context.exception, "\(context.exception?.toString() ?? "")")
        let result = function?.call(withArguments: [text, overrides])
        XCTAssertNil(context.exception, "\(context.exception?.toString() ?? "")")
        return try XCTUnwrap(result?.toString())
    }

    private let always = "(min-width: 0px)"
    private let never = "(not (min-width: 0px))"

    func testForcedColorsTestsBecomeConstants() throws {
        XCTAssertEqual(try rewrite("(forced-colors: active)", ["forced-colors": "active"]), always)
        XCTAssertEqual(try rewrite("(forced-colors: none)", ["forced-colors": "active"]), never)
        XCTAssertEqual(try rewrite("(forced-colors)", ["forced-colors": "active"]), always)
        XCTAssertEqual(try rewrite("(forced-colors)", ["forced-colors": "none"]), never)
        XCTAssertEqual(try rewrite("screen and ( Forced-Colors:ACTIVE )", ["forced-colors": "active"]),
                       "screen and " + always)
    }

    func testOtherFeaturesAndTextAreKept() throws {
        XCTAssertEqual(try rewrite("screen and (max-width: 600px), print", ["forced-colors": "active"]),
                       "screen and (max-width: 600px), print")
        XCTAssertEqual(try rewrite("(prefers-contrast: less) and (min-width: 40em)", ["prefers-contrast": "less"]),
                       always + " and (min-width: 40em)")
        XCTAssertEqual(try rewrite("not all and (prefers-reduced-data: reduce)", [:]),
                       "not all and (prefers-reduced-data: reduce)")
    }

    func testBooleanTestsMatchAnythingButNoPreference() throws {
        XCTAssertEqual(try rewrite("(prefers-contrast)", ["prefers-contrast": "custom"]), always)
        XCTAssertEqual(try rewrite("(prefers-contrast)", ["prefers-contrast": "no-preference"]), never)
        XCTAssertEqual(try rewrite("(prefers-contrast: more)", ["prefers-contrast": "less"]), never)
        XCTAssertEqual(try rewrite("(prefers-reduced-transparency)", ["prefers-reduced-transparency": "reduce"]), always)
        XCTAssertEqual(try rewrite("(prefers-reduced-data: reduce)", ["prefers-reduced-data": "reduce"]), always)
    }

    func testColorGamutIsARange() throws {
        let p3 = ["color-gamut": "p3"]
        XCTAssertEqual(try rewrite("(color-gamut: srgb)", p3), always)
        XCTAssertEqual(try rewrite("(color-gamut: p3)", p3), always)
        XCTAssertEqual(try rewrite("(color-gamut: rec2020)", p3), never)
        XCTAssertEqual(try rewrite("(color-gamut: rec2020)", ["color-gamut": "rec2020"]), always)
        XCTAssertEqual(try rewrite("(color-gamut: wide)", p3), never)
        XCTAssertEqual(try rewrite("(color-gamut)", ["color-gamut": "srgb"]), always)
    }

    func testOptionsSplitBetweenWebKitAndThePage() {
        var options = DeveloperRendering.Options()
        XCTAssertTrue(options.pageState(nativeContrast: true).isEmpty)

        options.frameStats = true
        options.focusedPage = true
        options.forcedColors = "active"
        options.colorGamut = "srgb"
        options.contrast = "more"
        let native = options.pageState(nativeContrast: true)
        XCTAssertTrue(native.frameStats)
        XCTAssertFalse(native.layoutShifts)
        XCTAssertTrue(native.focused)
        // WebKit emulates `more` itself where it can.
        XCTAssertEqual(native.media, ["forced-colors": "active", "color-gamut": "srgb"])
        XCTAssertEqual(options.pageState(nativeContrast: false).media["prefers-contrast"], "more")

        options.contrast = "less"
        XCTAssertEqual(options.pageState(nativeContrast: true).media["prefers-contrast"], "less")
    }

    func testStateIsSentAsSortedJSON() {
        let state = DeveloperRenderingPage.State(frameStats: true, layoutShifts: false, focused: false,
                                                 media: ["prefers-reduced-data": "reduce"])
        XCTAssertEqual(state.json,
                       #"{"focused":false,"frameStats":true,"layoutShifts":false,"media":{"prefers-reduced-data":"reduce"}}"#)
        XCTAssertFalse(state.isEmpty)
        XCTAssertTrue(DeveloperRenderingPage.State().isEmpty)
    }

    /// The script, with the rewriter, estimator and state around it, compiles as sent.
    func testComposedScriptCompiles() {
        let source = DeveloperRenderingPage.source(DeveloperRenderingPage.State(frameStats: true))
        XCTAssertTrue(source.contains(DeveloperRenderingPage.mediaRewriter))
        XCTAssertTrue(source.contains(DeveloperLayoutShiftEstimator.source))
        let context = JSContext()!
        context.setObject(source, forKeyedSubscript: "source" as NSString)
        _ = context.evaluateScript("new Function(source)")
        XCTAssertNil(context.exception, "\(context.exception?.toString() ?? "")")
    }
}
