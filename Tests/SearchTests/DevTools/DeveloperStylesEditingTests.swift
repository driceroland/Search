import AppKit
import XCTest
@testable import Search

/// The Styles pane's editing rules, as Chrome DevTools has them: where Tab
/// goes, what the arrow keys do to a value, var() links, completions and
/// the copy items' text.
@MainActor
final class DeveloperStylesEditingTests: XCTestCase {
    private typealias Editing = DeveloperStyleEditing
    private typealias Detail = DeveloperToolsSession.Detail

    // MARK: Focus order

    func testTabGoesFromTheSelectorThroughEachNameAndValueToANewDeclaration() {
        let rows = [0, 1]
        func next(_ field: Editing.Field, change: Int = 1) -> Editing.Field? {
            Editing.next(from: field, forward: true, rows: rows, count: 2, change: change, selectorEditable: true)
        }
        XCTAssertEqual(next(.selector), .name(0))
        XCTAssertEqual(next(.name(0)), .value(0))
        XCTAssertEqual(next(.value(0)), .name(1))
        XCTAssertEqual(next(.name(1)), .value(1))
        XCTAssertEqual(next(.value(1)), .newName(2), "past the last value Tab opens a new declaration")
        XCTAssertEqual(next(.newName(2)), .newValue(2))
        XCTAssertEqual(next(.newValue(2)), .newName(3), "a declaration added, another follows it")
        XCTAssertNil(next(.newName(3), change: 0), "Tab on an empty new name closes the editor")
    }

    func testShiftTabGoesBackToTheSelector() {
        func back(_ field: Editing.Field, change: Int = 1, selector: Bool = true) -> Editing.Field? {
            Editing.next(from: field, forward: false, rows: [0, 1], count: 2, change: change, selectorEditable: selector)
        }
        XCTAssertEqual(back(.value(1)), .name(1))
        XCTAssertEqual(back(.name(1)), .value(0))
        XCTAssertEqual(back(.name(0)), .selector)
        XCTAssertNil(back(.name(0), selector: false), "element.style has no selector to go back to")
        XCTAssertNil(back(.selector))
        XCTAssertEqual(back(.newName(2)), .value(1))
        XCTAssertEqual(back(.newValue(2)), .newName(2))
    }

    func testAnEmptyRuleTabsFromItsSelectorToANewDeclaration() {
        XCTAssertEqual(Editing.next(from: .selector, forward: true, rows: [], count: 0, change: 1, selectorEditable: true),
                       .newName(0))
    }

    func testAnEmptiedDeclarationGoesAndTabMovesToTheOneAfterIt() {
        let before = [Detail(name: "color", value: "red"), Detail(name: "margin", value: "0")]
        let (after, change) = Editing.fold(before, field: .value(0), name: "color", value: "")
        XCTAssertEqual(after.map(\.name), ["margin"])
        XCTAssertEqual(change, 0)
        XCTAssertEqual(Editing.next(from: .value(0), forward: true, rows: [0], count: 1, change: change, selectorEditable: true),
                       .name(0))
    }

    func testFoldingKeepsAnUnchangedDeclarationAndSplitsSemicolons() {
        let before = [Detail(name: "color", value: "red")]
        let same = Editing.fold(before, field: .name(0), name: "color", value: "red")
        XCTAssertEqual(same.properties, before)
        XCTAssertEqual(same.change, 1)
        let split = Editing.fold(before, field: .value(0), name: "color", value: "blue; margin: 0")
        XCTAssertEqual(split.properties.map(\.name), ["color", "margin"])
        XCTAssertEqual(split.change, 2)
        let added = Editing.fold(before, field: .newValue(0), name: "--Gap", value: "4px !important")
        XCTAssertEqual(added.properties.first?.name, "--Gap", "custom properties keep their case")
        XCTAssertEqual(added.properties.first?.important, true)
        XCTAssertEqual(Editing.fold(before, field: .newName(1), name: "", value: "").change, 0)
    }

    func testEditingTheNameThenTheValueKeepsOneCheckpoint() {
        let style = DeveloperToolsSession.StyleID(sheet: "1", ordinal: 0)
        var edit = DeveloperElementsState.StyleEdit(style: style, field: .name(0),
                                                    properties: [Detail(name: "color", value: "red")], selector: "p")
        XCTAssertEqual(edit.name, "color")
        XCTAssertEqual(edit.value, "red")
        edit.working = [Detail(name: "background", value: "red")]
        edit.enter(.value(0), selector: "p")
        XCTAssertEqual(edit.checkpoint.map(\.name), ["color"], "Esc in the value still puts the old name back")
        edit.enter(.newName(1), selector: "p")
        XCTAssertEqual(edit.checkpoint.map(\.name), ["background"])
        XCTAssertEqual(edit.name, "")
    }

    // MARK: Arrow keys

    func testModifiersChooseChromesStep() {
        XCTAssertEqual(Editing.stepAmount([]), 1)
        XCTAssertEqual(Editing.stepAmount(.shift), 10)
        XCTAssertEqual(Editing.stepAmount(.option), 0.1)
        XCTAssertEqual(Editing.stepAmount(.command), 100)
    }

    func testTheNumberAtTheCaretStepsWithItsUnit() {
        XCTAssertEqual(Editing.step("10px", caret: 4, by: 1)?.text, "11px")
        XCTAssertEqual(Editing.step("10px", caret: 4, by: 1)?.range, NSRange(location: 0, length: 2))
        XCTAssertEqual(Editing.step("1px 2px 3px", caret: 5, by: 10)?.text, "1px 12px 3px")
        XCTAssertEqual(Editing.step("1px 2px 3px", caret: nil, by: 1)?.text, "2px 2px 3px", "a whole selection steps the first")
        XCTAssertEqual(Editing.step("0.5em", caret: 1, by: 0.1)?.text, "0.6em")
        XCTAssertEqual(Editing.step("1px", caret: 0, by: -1)?.text, "0px")
        XCTAssertEqual(Editing.step("0px", caret: 0, by: -1)?.text, "-1px")
        XCTAssertEqual(Editing.step("rotate(-45deg)", caret: 9, by: -10)?.text, "rotate(-55deg)")
        XCTAssertEqual(Editing.step("1.1", caret: 0, by: -0.1)?.text, "1")
        XCTAssertEqual(Editing.step("50%", caret: 1, by: 100)?.text, "150%")
    }

    func testNumbersInsideWordsAndColoursAreLeftAlone() {
        XCTAssertNil(Editing.step("h1", caret: 2, by: 1))
        XCTAssertNil(Editing.step("#123456", caret: 3, by: 1))
        XCTAssertNil(Editing.step("block", caret: 2, by: 1))
        XCTAssertEqual(Editing.step("translate3d(1px, 0, 0)", caret: 13, by: 1)?.text, "translate3d(2px, 0, 0)")
    }

    func testSteppedNumbersAreWrittenWithoutFloatingPointNoise() {
        XCTAssertEqual(Editing.format(0.1 + 0.2), "0.3")
        XCTAssertEqual(Editing.format(-0.0), "0")
        XCTAssertEqual(Editing.format(12), "12")
        XCTAssertEqual(Editing.format(-1.25), "-1.25")
    }

    func testKeywordsCycleThroughThePropertysValues() {
        let values = ["block", "flex", "grid", "none"]
        XCTAssertEqual(Editing.cycle("flex", through: values, up: false), "grid")
        XCTAssertEqual(Editing.cycle("flex", through: values, up: true), "block")
        XCTAssertEqual(Editing.cycle("none", through: values, up: false), "block")
        XCTAssertEqual(Editing.cycle(" Block ", through: values, up: true), "none")
        XCTAssertNil(Editing.cycle("10px", through: values, up: true))
    }

    func testBoxModelTabOrderGoesOutsideInClockwise() {
        let order = Editing.boxOrder(positioned: false)
        XCTAssertEqual(Array(order.prefix(5)), ["margin-top", "margin-right", "margin-bottom", "margin-left", "border-top-width"])
        XCTAssertEqual(Array(order.suffix(2)), ["width", "height"])
        XCTAssertEqual(Editing.boxOrder(positioned: true).first, "top")
    }

    // MARK: Completions

    func testCompletionsReplaceTheLastWordAndGreyTheRest() {
        XCTAssertEqual(Editing.completeValue("1px so", with: "solid"), "1px solid")
        XCTAssertEqual(Editing.completeValue("", with: "block"), "block")
        XCTAssertEqual(Editing.lastWord("1px so"), "so")
        XCTAssertEqual(Editing.remainder(of: "display", after: "dis"), "play")
        XCTAssertEqual(Editing.remainder(of: "display", after: "DIS"), "play")
        XCTAssertEqual(Editing.remainder(of: "display", after: ""), "")
        XCTAssertEqual(Editing.remainder(of: "display", after: "color"), "")
    }

    func testASemicolonEndsTheValueOnlyOutsideBracketsAndQuotes() {
        XCTAssertTrue(Editing.balanced("red"))
        XCTAssertFalse(Editing.balanced("url(data:image/png;base64"))
        XCTAssertFalse(Editing.balanced("\"a"))
        XCTAssertTrue(Editing.balanced("\"a;b\""))
    }

    // MARK: var()

    func testVarReferencesAreCutOutOfTheValue() {
        XCTAssertEqual(Editing.segments("1px solid var(--line, #ccc)"), [
            .init(text: "1px solid ", variable: nil),
            .init(text: "var(--line, #ccc)", variable: "--line"),
        ])
        XCTAssertEqual(Editing.segments("calc(var(--a) + var(--b))"), [
            .init(text: "calc(", variable: nil),
            .init(text: "var(--a)", variable: "--a"),
            .init(text: " + ", variable: nil),
            .init(text: "var(--b)", variable: "--b"),
            .init(text: ")", variable: nil),
        ])
        XCTAssertEqual(Editing.segments("var(--x, var(--y))").map(\.variable), ["--x"])
        XCTAssertEqual(Editing.segments("var(--open"), [.init(text: "var(--open", variable: nil)])
        XCTAssertEqual(Editing.segments("red"), [.init(text: "red", variable: nil)])
    }

    // MARK: Copying

    func testCopyItemsWriteChromesText() {
        let size = Detail(name: "font-size", value: "12px")
        let custom = Detail(name: "--it's", value: "'a'", important: true)
        XCTAssertEqual(Editing.declarationText(size), "font-size: 12px;")
        XCTAssertEqual(Editing.javaScript(size), "fontSize: '12px'")
        XCTAssertEqual(Editing.javaScript(Detail(name: "-webkit-box-shadow", value: "none")), "WebkitBoxShadow: 'none'")
        XCTAssertEqual(Editing.javaScript(custom), "'--it's': '\\'a\\' !important'")
        var off = Detail(name: "color", value: "red")
        off.enabled = false
        XCTAssertEqual(Editing.allDeclarations([size, off]), "font-size: 12px;\n/* color: red; */")
        XCTAssertEqual(Editing.allJavaScript([size, off]), "fontSize: '12px'")
        XCTAssertEqual(Editing.ruleText(selector: "p", properties: [size]), "p {\n  font-size: 12px;\n}")
    }

    func testCSSChangesCommentWhatWentAndListWhatCame() {
        let text = Editing.changesText(selector: ".a", original: [Detail(name: "color", value: "red")],
                                       current: [Detail(name: "color", value: "blue")])
        XCTAssertEqual(text, ".a {\n  /* color: red; */\n  color: blue;\n}")
        XCTAssertEqual(Editing.changesText(selector: ".a", original: [Detail(name: "color", value: "red")],
                                           current: [Detail(name: "color", value: "red")]), "")
    }

    // MARK: Moving between declarations

    func testArrowsInAnUntouchedNameMoveBetweenDeclarations() {
        XCTAssertTrue(Editing.navigates(.name(1), typed: "color", original: "color", suggesting: false))
        XCTAssertTrue(Editing.navigates(.name(1), typed: " color ", original: "color", suggesting: false))
        XCTAssertFalse(Editing.navigates(.name(1), typed: "colo", original: "color", suggesting: false),
                       "a name being typed keeps the arrows")
        XCTAssertFalse(Editing.navigates(.name(1), typed: "color", original: "color", suggesting: true),
                       "an open suggest box keeps the arrows")
        XCTAssertFalse(Editing.navigates(.value(1), typed: "red", original: "red", suggesting: false),
                       "a value steps instead")
        XCTAssertFalse(Editing.navigates(.newName(2), typed: "", original: nil, suggesting: false))
        XCTAssertFalse(Editing.navigates(.name(4), typed: "color", original: nil, suggesting: false))
    }

    /// A value laid out in a flow breaks between words, and a var() link
    /// (spaces and all) is never cut.
    func testFlowPiecesBreakBetweenWordsButKeepVarWhole() {
        let pieces = DeveloperStyleEditing.flowPieces("var(--weight, 400) var(--size) / 1.2 serif")
        XCTAssertEqual(pieces.map(\.text), ["var(--weight, 400)", " ", "var(--size)", " ", "/ ", "1.2 ", "serif"])
        XCTAssertEqual(pieces.compactMap(\.variable), ["--weight", "--size"])
        XCTAssertEqual(pieces.map(\.text).joined(), "var(--weight, 400) var(--size) / 1.2 serif")
    }

    func testAdjacentRuleSkipsBrowserRulesAndHiddenDeclarations() {
        typealias Rule = DeveloperToolsSession.StyleRule
        typealias Detail = DeveloperToolsSession.Detail
        func id(_ n: Int) -> DeveloperToolsSession.StyleID { .init(sheet: "s", ordinal: n) }
        let rules = [
            Rule(id: 0, selector: "element.style", origin: "", properties: [Detail(name: "color", value: "red")], style: id(0)),
            Rule(id: 1, selector: "p", origin: "", properties: [Detail(name: "margin", value: "0"), Detail(name: "padding", value: "1px")], style: id(1)),
            Rule(id: 2, selector: "p", origin: "user-agent", properties: [Detail(name: "display", value: "block")]),
            Rule(id: 3, selector: "body", origin: "", properties: [Detail(name: "margin", value: "0", inheritable: false),
                                                                    Detail(name: "color", value: "blue")],
                 style: id(3), inherited: true),
            Rule(id: 4, selector: "html", origin: "", properties: [Detail(name: "margin", value: "0", inheritable: false)],
                 style: id(4), inherited: true),
        ]
        let down = Editing.adjacentRule(from: 0, up: false, in: rules)
        XCTAssertEqual(down?.rule.id, 1); XCTAssertEqual(down?.index, 0, "↓ lands on the next rule's first")
        let up = Editing.adjacentRule(from: 1, up: true, in: rules)
        XCTAssertEqual(up?.rule.id, 0); XCTAssertEqual(up?.index, 0)
        let past = Editing.adjacentRule(from: 1, up: false, in: rules)
        XCTAssertEqual(past?.rule.id, 3, "the browser's own rule is passed over")
        XCTAssertEqual(past?.index, 1, "an inherited rule's hidden declaration is passed over")
        let back = Editing.adjacentRule(from: 3, up: true, in: rules)
        XCTAssertEqual(back?.rule.id, 1); XCTAssertEqual(back?.index, 1, "↑ lands on the rule above's last")
        XCTAssertNil(Editing.adjacentRule(from: 3, up: false, in: rules), "a rule with nothing shown is passed over")
        XCTAssertNil(Editing.adjacentRule(from: 0, up: true, in: rules), "the pane's top")
        XCTAssertNil(Editing.adjacentRule(from: 9, up: true, in: rules))
    }

    func testAdjacentNameFollowsTheRowsShownAndStopsAtTheEnds() {
        let rows = [0, 2, 3]
        XCTAssertEqual(Editing.adjacentName(from: .name(2), up: true, rows: rows), .name(0), "row 1 is hidden")
        XCTAssertEqual(Editing.adjacentName(from: .name(2), up: false, rows: rows), .name(3))
        XCTAssertEqual(Editing.adjacentName(from: .name(0), up: false, rows: rows), .name(2))
        XCTAssertNil(Editing.adjacentName(from: .name(0), up: true, rows: rows))
        XCTAssertNil(Editing.adjacentName(from: .name(3), up: false, rows: rows))
        XCTAssertNil(Editing.adjacentName(from: .value(2), up: true, rows: rows))
        XCTAssertNil(Editing.adjacentName(from: .selector, up: false, rows: rows))
    }

    func testPageKeysStepByTenOrAHundred() {
        XCTAssertEqual(Editing.stepAmount([], page: true), 10)
        XCTAssertEqual(Editing.stepAmount(.shift, page: true), 100)
        XCTAssertEqual(Editing.stepAmount(.option, page: false), 0.1)
        XCTAssertEqual(Editing.step("10px", caret: 1, by: Editing.stepAmount(.shift, page: true) * -1)?.text, "-90px")
    }

    // MARK: The value tooltip

    func testOptionDownOpensThePickerForAColourAndATooltipForFunctions() {
        XCTAssertEqual(Editing.valueTooltip("red"), .color("red"))
        XCTAssertEqual(Editing.valueTooltip(" #ff0000 "), .color("#ff0000"))
        XCTAssertEqual(Editing.valueTooltip("rgb(1, 2, 3)"), .color("rgb(1, 2, 3)"))
        XCTAssertEqual(Editing.valueTooltip("calc(var(--gap) + 2px)"), .functions(["calc", "var"]))
        XCTAssertEqual(Editing.valueTooltip("linear-gradient(red, blue)"), .functions(["linear-gradient"]))
        XCTAssertEqual(Editing.valueTooltip("1px solid red"), .color("red"), "a colour inside a value with no function")
        XCTAssertNil(Editing.valueTooltip("block"))
        XCTAssertEqual(Editing.functionNames("translate3d(0, 0, 0) Rotate(4deg) translate3d(1px)"), ["translate3d", "rotate"])
        XCTAssertTrue(Editing.functionHelp("calc").hasPrefix("calc() — "))
        XCTAssertEqual(Editing.functionHelp("made-up"), "made-up() — a CSS function")
    }

    // MARK: Colour formats

    func testShiftClickCyclesColourFormatsInChromesOrder() {
        let red = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        XCTAssertEqual(DeveloperColorFormats.next(after: "red", color: red), "#f00")
        XCTAssertEqual(DeveloperColorFormats.next(after: "#f00", color: red), "rgb(255 0 0)")
        XCTAssertEqual(DeveloperColorFormats.next(after: "rgb(255 0 0)", color: red), "hsl(0deg 100% 50%)")
        XCTAssertEqual(DeveloperColorFormats.next(after: "hsl(0deg 100% 50%)", color: red), "hwb(0deg 0% 0%)")
        XCTAssertEqual(DeveloperColorFormats.format(of: "rgba(1, 2, 3, 0.5)"), "rgb")
        XCTAssertEqual(DeveloperColorFormats.format(of: "oklab(0.6 0.2 0.1)"), "oklab")
        XCTAssertEqual(DeveloperColorFormats.format(of: "lab(50 20 10)"), "lab")
        XCTAssertTrue(DeveloperColorFormats.next(after: "oklab(0.63 0.22 0.13)", color: red).hasPrefix("color(srgb "))
    }
}
