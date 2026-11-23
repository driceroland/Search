import XCTest
@testable import Search

/// The CSS overview's pure logic: colour parsing and normalisation, WCAG
/// contrast, the effective background behind text, selector counts,
/// media queries, colour and font tallies and unused declarations.
final class DeveloperCSSOverviewTests: XCTestCase {
    private typealias Overview = DeveloperCSSOverview
    private typealias Element = DeveloperCSSOverview.Element

    // MARK: Colours

    func testComputedColoursParseAndNormaliseToHex() {
        XCTAssertEqual(DeveloperCSSColor.parse("rgb(255, 0, 0)")?.hex, "#ff0000")
        XCTAssertEqual(DeveloperCSSColor.parse("rgba(0, 0, 0, 0.5)")?.hex, "#00000080")
        XCTAssertEqual(DeveloperCSSColor.parse("rgb(10 20 30 / 50%)")?.hex, "#0a141e80")
        XCTAssertEqual(DeveloperCSSColor.parse("RGB(100%, 0%, 50%)")?.hex, "#ff0080")
        XCTAssertEqual(DeveloperCSSColor.parse("#abc")?.hex, "#aabbcc")
        XCTAssertEqual(DeveloperCSSColor.parse("#11223344")?.hex, "#11223344")
        XCTAssertEqual(DeveloperCSSColor.parse("color(srgb 1 0 0.5)")?.hex, "#ff0080")
        XCTAssertEqual(DeveloperCSSColor.parse("color(srgb 0 0 0 / 0.25)")?.alpha ?? 0, 0.25, accuracy: 1e-9)
        XCTAssertEqual(DeveloperCSSColor.parse(" white ")?.hex, "#ffffff")
        XCTAssertEqual(DeveloperCSSColor.parse("transparent")?.isTransparent, true)
        XCTAssertEqual(DeveloperCSSColor.parse("rgb(300, -4, 0)")?.hex, "#ff0000")
    }

    func testWhatIsntAColourDoesntParse() {
        for text in ["", "currentcolor", "none", "oklch(0.5 0.1 200)", "rgb(1, 2)", "#12", "#ggg", "rgb(a, b, c)", "color(display-p3 1 0 0)"] {
            XCTAssertNil(DeveloperCSSColor.parse(text), text)
        }
    }

    func testColourKeysSkipTransparencyAndKeepUnreadableColoursAsText() {
        XCTAssertEqual(Overview.colorKey("rgb(0, 0, 0)")?.key, "#000000")
        XCTAssertNil(Overview.colorKey("rgba(0, 0, 0, 0)"))
        XCTAssertNil(Overview.colorKey("currentcolor"))
        XCTAssertNil(Overview.colorKey("url(#gradient)"))
        let odd = Overview.colorKey("oklch(0.5 0.1 200)")
        XCTAssertEqual(odd?.key, "oklch(0.5 0.1 200)")
        XCTAssertNil(odd?.color)
    }

    func testCompositingATranslucentColourOverAnother() {
        let half = DeveloperCSSColor(red: 0, green: 0, blue: 0, alpha: 0.5)
        XCTAssertEqual(half.over(.white).hex, "#808080")
        XCTAssertEqual(DeveloperCSSColor.white.over(half).hex, "#ffffff")
    }

    func testContrastRatiosFollowWCAG() {
        XCTAssertEqual(DeveloperCSSColor.contrast(.black, .white), 21, accuracy: 1e-9)
        XCTAssertEqual(DeveloperCSSColor.contrast(.white, .black), 21, accuracy: 1e-9)
        XCTAssertEqual(DeveloperCSSColor.contrast(.white, .white), 1, accuracy: 1e-9)
        let gray = DeveloperCSSColor.parse("#777777")!
        let ratio = DeveloperCSSColor.contrast(gray, .white)
        XCTAssertGreaterThan(ratio, 4.47)
        XCTAssertLessThan(ratio, 4.49)
        // Rounded down so a failing ratio is never shown as passing.
        XCTAssertEqual(Overview.ratioLabel(4.4999), "4.49")
        XCTAssertEqual(Overview.ratioLabel(21), "21.00")
        // Translucent text is drawn over its background first.
        let faint = DeveloperCSSColor(red: 0, green: 0, blue: 0, alpha: 0.5)
        XCTAssertEqual(DeveloperCSSColor.contrast(faint, .white), DeveloperCSSColor.contrast(DeveloperCSSColor(red: 127.5, green: 127.5, blue: 127.5), .white),
                       accuracy: 0.01)
    }

    func testLargeTextAndTheAAThresholds() {
        XCTAssertTrue(Overview.isLargeText(fontSize: "24px", fontWeight: "400"))
        XCTAssertTrue(Overview.isLargeText(fontSize: "18.66px", fontWeight: "700"))
        XCTAssertTrue(Overview.isLargeText(fontSize: "19px", fontWeight: "bold"))
        XCTAssertFalse(Overview.isLargeText(fontSize: "18.66px", fontWeight: "400"))
        XCTAssertFalse(Overview.isLargeText(fontSize: "16px", fontWeight: "900"))
        XCTAssertEqual(Overview.threshold(large: false), 4.5)
        XCTAssertEqual(Overview.threshold(large: true), 3)
    }

    func testStyleSwatchContrastUsesUnroundedAAAndAAAThresholds() throws {
        let normal = DeveloperStyleContrast(background: .white, largeText: false)
        let large = DeveloperStyleContrast(background: .white, largeText: true)
        let borderline = try XCTUnwrap(DeveloperCSSColor.parse("#777777"))
        let darker = try XCTUnwrap(DeveloperCSSColor.parse("#767676"))

        XCTAssertEqual(normal.measure(.black).ratio, 21, accuracy: 1e-9)
        XCTAssertTrue(normal.measure(.black).aaa)
        XCTAssertFalse(normal.measure(borderline).aa)
        XCTAssertTrue(normal.measure(darker).aa)
        XCTAssertFalse(normal.measure(darker).aaa)
        XCTAssertTrue(large.measure(borderline).aa)
        XCTAssertFalse(large.measure(borderline).aaa)
        XCTAssertTrue(large.measure(darker).aaa)
    }

    // MARK: Effective background and contrast issues

    private func element(_ index: Int, parent: Int? = nil, label: String = "div", text: Bool = false,
                         rendered: Bool = true, image: Bool = false, svg: Bool = false,
                         _ values: [String: String] = [:]) -> Element {
        Element(index: index, parent: parent, label: label, hasText: text, rendered: rendered,
                backgroundImage: image, svgShape: svg, values: values)
    }

    func testTheEffectiveBackgroundCompositesAncestorsDownToAnOpaqueOne() {
        let elements = [
            element(0, ["backgroundColor": "rgb(255, 255, 255)"]),
            element(1, parent: 0, ["backgroundColor": "rgba(0, 0, 0, 0.5)"]),
            element(2, parent: 1),
        ]
        XCTAssertEqual(Overview.effectiveBackground(of: 2, in: elements)?.hex, "#808080")
        XCTAssertEqual(Overview.effectiveBackground(of: 0, in: elements)?.hex, "#ffffff")
        // Nothing painted: the canvas's white.
        XCTAssertEqual(Overview.effectiveBackground(of: 0, in: [element(0)])?.hex, "#ffffff")
    }

    func testABackgroundImageInTheWayMeansNoVerdict() {
        let elements = [
            element(0, ["backgroundColor": "rgb(0, 0, 0)"]),
            element(1, parent: 0, image: true),
            element(2, parent: 1),
        ]
        XCTAssertNil(Overview.effectiveBackground(of: 2, in: elements))
        // An opaque background below the image hides it.
        let covered = [
            element(0, image: true),
            element(1, parent: 0, ["backgroundColor": "rgb(0, 0, 0)"]),
            element(2, parent: 1),
        ]
        XCTAssertEqual(Overview.effectiveBackground(of: 2, in: covered)?.hex, "#000000")
    }

    func testContrastIssuesAreTextBelowAAGroupedByColourPair() {
        let elements = [
            element(0, label: "body", ["backgroundColor": "rgb(255, 255, 255)"]),
            element(1, parent: 0, label: "p", text: true, ["color": "rgb(119, 119, 119)", "fontSize": "16px", "fontWeight": "400"]),
            element(2, parent: 0, label: "h1", text: true, ["color": "rgb(119, 119, 119)", "fontSize": "32px", "fontWeight": "700"]),
            element(3, parent: 0, label: "span", text: true, ["color": "rgb(0, 0, 0)", "fontSize": "16px"]),
            element(4, parent: 0, label: "p", text: true, ["color": "rgb(119, 119, 119)", "fontSize": "14px"]),
            element(5, parent: 0, label: "p", text: false, ["color": "rgb(200, 200, 200)"]),
            element(6, parent: 0, label: "p", text: true, rendered: false, ["color": "rgb(250, 250, 250)"]),
            element(7, parent: 0, label: "p", text: true, ["color": "rgb(250, 250, 250)", "fontSize": "16px"]),
        ]
        let issues = Overview.contrastIssues(elements)
        XCTAssertEqual(issues.count, 2)
        // Worst first.
        XCTAssertEqual(issues[0].text.hex, "#fafafa")
        XCTAssertEqual(issues[0].elements, [7])
        XCTAssertEqual(issues[1].text.hex, "#777777")
        XCTAssertEqual(issues[1].background.hex, "#ffffff")
        XCTAssertEqual(issues[1].threshold, 4.5)
        XCTAssertEqual(issues[1].elements, [1, 4])
    }

    // MARK: Selectors and media queries

    func testSelectorListsSplitOnlyAtTopLevelCommas() {
        XCTAssertEqual(Overview.splitSelectorList("a, b , :is(c, d), [x=\"1,2\"]"), ["a", "b", ":is(c, d)", "[x=\"1,2\"]"])
        XCTAssertEqual(Overview.compounds("div > p + span ~ a  b"), ["div", "p", "span", "a", "b"])
        XCTAssertEqual(Overview.compounds(":not(.a .b) li"), [":not(.a .b)", "li"])
    }

    func testSelectorsAreCountedByTheKindsInTheirKeyCompound() {
        let counts = Overview.selectorCounts([
            "div", ".a", "#b", "*", "[x]", "div > p", "a.b", "h1, h2", ":is(.a, .b) span", "a[href=\"x,y\"]", "",
        ])
        XCTAssertEqual(counts.type, 7)
        XCTAssertEqual(counts.classes, 2)
        XCTAssertEqual(counts.id, 1)
        XCTAssertEqual(counts.universal, 1)
        XCTAssertEqual(counts.attribute, 2)
        XCTAssertEqual(counts.nonSimple, 2)
    }

    func testMediaQueriesAreCountedMostUsedFirst() {
        let queries = Overview.mediaQueries(["(max-width: 600px)", "(max-width:  600px)", "print", "", "  "])
        XCTAssertEqual(queries, [.init(text: "(max-width: 600px)", count: 2), .init(text: "print", count: 1)])
    }

    // MARK: Colours and fonts

    func testColoursAreTalliedWhereTheyreUsed() {
        let elements = [
            element(0, ["backgroundColor": "rgb(255, 255, 255)", "color": "rgb(0, 0, 0)"]),
            element(1, text: true, ["backgroundColor": "rgba(0, 0, 0, 0)", "color": "rgb(0, 0, 0)",
                                    "borderTopColor": "rgb(255, 0, 0)", "borderLeftColor": "rgb(255, 0, 0)",
                                    "borderBottomColor": "rgb(0, 0, 255)"]),
            element(2, text: true, ["backgroundColor": "rgb(255, 255, 255)", "color": "rgb(51, 51, 51)"]),
            element(3, text: true, rendered: false, ["backgroundColor": "rgb(1, 2, 3)", "color": "rgb(1, 2, 3)"]),
            element(4, label: "path", svg: true, ["fill": "rgb(0, 128, 0)"]),
            element(5, ["fill": "rgb(0, 0, 0)"]),
        ]
        let colors = Overview.colors(elements)
        XCTAssertEqual(colors.background.map(\.key), ["#ffffff"])
        XCTAssertEqual(colors.background.first?.elements, [0, 2])
        XCTAssertEqual(colors.text.map(\.key), ["#000000", "#333333"])
        XCTAssertEqual(colors.text.first?.elements, [1])
        XCTAssertEqual(colors.fill.map(\.key), ["#008000"])
        XCTAssertEqual(colors.border.map(\.key), ["#ff0000", "#0000ff"])
        XCTAssertEqual(colors.border.first?.elements, [1])
        XCTAssertEqual(colors.unique, 6)
    }

    func testFontsAreGroupedByFamilyThenSizeWeightAndLineHeight() {
        let body = ["fontFamily": "Helvetica, sans-serif", "fontSize": "16px", "fontWeight": "400", "lineHeight": "normal"]
        var heading = body
        heading["fontSize"] = "32px"
        heading["fontWeight"] = "700"
        let elements = [
            element(0, text: true, body),
            element(1, text: true, body),
            element(2, text: true, heading),
            element(3, text: true, ["fontFamily": "Menlo", "fontSize": "12px", "fontWeight": "400", "lineHeight": "18px"]),
            element(4, text: false, ["fontFamily": "Georgia"]),
        ]
        let fonts = Overview.fonts(elements)
        XCTAssertEqual(fonts.map(\.family), ["Helvetica, sans-serif", "Menlo"])
        XCTAssertEqual(fonts[0].count, 3)
        XCTAssertEqual(fonts[0].uses.map(\.size), ["16px", "32px"])
        XCTAssertEqual(fonts[0].uses[0].elements, [0, 1])
        XCTAssertEqual(fonts[1].uses.first?.lineHeight, "18px")
    }

    // MARK: Unused declarations

    func testUnusedDeclarationsAreWhatTheElementIgnores() {
        let offsets = Overview.unused(element(0, ["position": "static", "display": "block", "top": "10px", "left": "auto"]))
        XCTAssertEqual(offsets.map(\.property), ["top"])
        XCTAssertEqual(offsets.first?.value, "10px")
        XCTAssertTrue(Overview.unused(element(0, ["position": "relative", "display": "block", "top": "10px"])).isEmpty)

        let inline = Overview.unused(element(0, label: "span.note", ["display": "inline", "width": "100px", "height": "auto"]))
        XCTAssertEqual(inline.map(\.property), ["width"])
        XCTAssertTrue(Overview.unused(element(0, label: "img#logo", ["display": "inline", "width": "100px"])).isEmpty)

        let align = Overview.unused(element(0, ["display": "block", "verticalAlign": "middle"]))
        XCTAssertEqual(align.map(\.property), ["vertical-align"])
        XCTAssertTrue(Overview.unused(element(0, ["display": "inline-block", "verticalAlign": "middle"])).isEmpty)
        XCTAssertTrue(Overview.unused(element(0, ["display": "table-cell", "verticalAlign": "top"])).isEmpty)
        XCTAssertTrue(Overview.unused(element(0, ["display": "block", "verticalAlign": "baseline"])).isEmpty)

        let cell = Overview.unused(element(0, ["display": "table-cell", "marginTop": "4px", "marginLeft": "0px", "marginRight": "auto"]))
        XCTAssertEqual(cell.map(\.property), ["margin-top"])
    }

    func testUnusedDeclarationsAreGroupedByReason() {
        let elements = [
            element(0, ["position": "static", "display": "block", "top": "10px"]),
            element(1, ["position": "static", "display": "block", "top": "4px"]),
            element(2, ["position": "static", "display": "block", "top": "10px", "verticalAlign": "middle"]),
            element(3, rendered: false, ["position": "static", "display": "none", "top": "1px"]),
        ]
        let groups = Overview.unusedGroups(elements)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].property, "top")
        XCTAssertEqual(groups[0].elements, [0, 1, 2])
        XCTAssertEqual(groups[0].values, ["10px", "4px"])
        XCTAssertEqual(groups[1].property, "vertical-align")
    }

    func testTheTagIsTheStartOfTheLabel() {
        XCTAssertEqual(element(0, label: "img#logo.big").tag, "img")
        XCTAssertEqual(element(0, label: "DIV.a").tag, "div")
    }

    // MARK: The page's answer

    func testThePageScriptsRowsAreDecodedByField() {
        let data: [String: Any] = [
            "fields": ["color", "backgroundColor"],
            "strings": ["", "p.intro", "rgb(0, 0, 0)", "rgb(255, 255, 255)"],
            "rows": [[-1, 2, 1, 2, 3], [0, 1 | 2 | 4, 1, 2, 0], [7, 8, 1]],
            "total": 40, "truncated": true, "externalSheets": 2, "inlineSheets": 1, "unreadableSheets": 1,
            "styleRules": 12, "selectors": ["p", ".intro"], "media": ["print", "print"],
        ]
        let elements = Overview.elements(data)
        XCTAssertEqual(elements.count, 3)
        XCTAssertNil(elements[0].parent)
        XCTAssertEqual(elements[0].label, "p.intro")
        XCTAssertEqual(elements[0]["color"], "rgb(0, 0, 0)")
        XCTAssertEqual(elements[0]["backgroundColor"], "rgb(255, 255, 255)")
        XCTAssertFalse(elements[0].hasText)
        XCTAssertTrue(elements[0].rendered)
        XCTAssertEqual(elements[1].parent, 0)
        XCTAssertTrue(elements[1].hasText && elements[1].rendered && elements[1].backgroundImage)
        XCTAssertEqual(elements[1]["backgroundColor"], "")
        XCTAssertNil(elements[2].parent, "a parent out of range is none")
        XCTAssertTrue(elements[2].svgShape)

        let report = Overview.report(data)
        XCTAssertEqual(report.summary.elements, 40)
        XCTAssertTrue(report.summary.truncated)
        XCTAssertEqual(report.summary.externalSheets, 2)
        XCTAssertEqual(report.summary.inlineSheets, 1)
        XCTAssertEqual(report.summary.unreadableSheets, 1)
        XCTAssertEqual(report.summary.styleRules, 12)
        XCTAssertEqual(report.summary.mediaQueries, 2)
        XCTAssertEqual(report.summary.selectors.type, 1)
        XCTAssertEqual(report.summary.selectors.classes, 1)
        XCTAssertEqual(report.media, [.init(text: "print", count: 2)])
        XCTAssertEqual(report.label(0), "p.intro")
        XCTAssertEqual(report.label(99), "element")
    }
}
