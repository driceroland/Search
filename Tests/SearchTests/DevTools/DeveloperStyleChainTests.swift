import XCTest
@testable import Search

final class DeveloperStyleChainTests: XCTestCase {
    private typealias Editing = DeveloperStyleEditing

    private func chain(_ reference: String, _ declared: [String: String]) -> [String] {
        Editing.variableChain(reference) { name in declared[name].map { Editing.Declared(value: $0, place: ":root") } }
    }

    func testVariableParts() {
        XCTAssertEqual(Editing.variableParts("var(--a)")?.name, "--a")
        XCTAssertNil(Editing.variableParts("var(--a)")?.fallback)
        XCTAssertEqual(Editing.variableParts("var( --a , var(--b, 1px) )")?.fallback, "var(--b, 1px)")
        XCTAssertEqual(Editing.variableParts("var(--a,)")?.fallback, "")
        XCTAssertNil(Editing.variableParts("var(a)"))
    }

    func testChainFollowsEachProperty() {
        XCTAssertEqual(chain("var(--a)", ["--a": "var(--b)", "--b": "calc(var(--c) * 2)", "--c": "4px"]), [
            "--a: var(--b) — :root",
            "  --b: calc(var(--c) * 2) — :root",
            "    --c: 4px — :root",
            "Value: calc(4px * 2)",
        ])
    }

    func testUnsetTakesTheFallback() {
        XCTAssertEqual(chain("var(--a, 10px)", [:]), ["--a is not defined", "Fallback: 10px", "Value: 10px"])
        XCTAssertEqual(chain("var(--a)", ["--a": "var(--b, var(--c))", "--c": "red"]), [
            "--a: var(--b, var(--c)) — :root",
            "  --b is not defined",
            "  Fallback: var(--c)",
            "    --c: red — :root",
            "Value: red",
        ])
        XCTAssertEqual(chain("var(--missing)", [:]), ["--missing is not defined", "Invalid at computed-value time"])
    }

    func testCycleIsInvalidUnlessThereIsAFallback() {
        let cycle = ["--a": "var(--b)", "--b": "var(--a)"]
        XCTAssertEqual(chain("var(--a)", cycle).last, "Invalid at computed-value time")
        XCTAssertTrue(chain("var(--a)", cycle).contains("    --a is in a cycle"))
        XCTAssertEqual(chain("var(--a, 3px)", cycle).last, "Value: 3px")
    }

    func testMathSteps() {
        XCTAssertEqual(Editing.mathSteps("calc(100% - clamp(1rem, 2vw, 30px) * 2)"), [
            "100%", "1rem", "2vw", "clamp(1rem, 2vw, 30px)", "clamp(1rem, 2vw, 30px) * 2",
            "calc(100% - clamp(1rem, 2vw, 30px) * 2)",
        ])
        XCTAssertEqual(Editing.mathSteps("min(50%, 600px) auto"), ["50%", "min(50%, 600px)"])
        XCTAssertEqual(Editing.mathSteps("calc((100% - 2em) / 3)"), [
            "100%", "2em", "(100% - 2em)", "calc((100% - 2em) / 3)",
        ])
        XCTAssertEqual(Editing.mathSteps("translateX(calc(1em + 2px))"), ["1em", "calc(1em + 2px)"])
        XCTAssertEqual(Editing.mathSteps("1px solid red"), [])
        XCTAssertEqual(Editing.mathSteps("rgb(0 0 0)"), [])
    }

    func testTopLevelSplitting() {
        XCTAssertEqual(Editing.topLevel("a, b(c, d), e", splitting: [","]), ["a", "b(c, d)", "e"])
        XCTAssertEqual(Editing.topLevel("1px + (2px - 3px) - 4px", splitting: [" + ", " - "]),
                       ["1px", "(2px - 3px)", "4px"])
    }

    func testMathLines() {
        XCTAssertEqual(Editing.mathLines(["50%", "min(50%, 600px)"], results: ["400px", nil], used: "400px"),
                       ["50% = 400px", "Used value: 400px"])
        XCTAssertEqual(Editing.mathLines(["50%"], results: [], used: "400px"), [])
    }

    func testAnEditorSetsADeclarationWhereItIs() {
        let rule = ["display", "grid-auto-flow", "gap", "grid-auto-flow"]
        XCTAssertEqual(DeveloperStyleEditing.setting("grid-auto-flow", to: ["grid-auto-flow"], in: rule, name: { $0 }),
                       ["display", "grid-auto-flow", "gap"])
        XCTAssertEqual(DeveloperStyleEditing.setting("grid-auto-flow", to: [], in: rule, name: { $0 }), ["display", "gap"])
        XCTAssertEqual(DeveloperStyleEditing.setting("align-items", to: ["align-items"], in: rule, name: { $0 }),
                       rule + ["align-items"])
    }
}
