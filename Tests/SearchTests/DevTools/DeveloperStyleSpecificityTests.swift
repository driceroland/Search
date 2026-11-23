import XCTest
@testable import Search

/// Selector specificity as Chrome DevTools shows it on a hovered selector
/// in Styles, per Selectors Level 4.
final class DeveloperStyleSpecificityTests: XCTestCase {
    private func specificity(_ selector: String) -> String {
        DeveloperStyleSpecificity.of(selector).text
    }

    func testIdsClassesAndTypesCountInTheirOwnColumns() {
        XCTAssertEqual(specificity("#a .b:is(p,#c)"), "(2,1,0)")
        XCTAssertEqual(specificity("ul li.item[data-x=\"a,b\"]:hover"), "(0,3,2)")
        XCTAssertEqual(specificity("*"), "(0,0,0)")
        XCTAssertEqual(specificity("div > p + span ~ em"), "(0,0,4)")
    }

    func testWhereCountsNothingAndIsTakesItsMostSpecificArgument() {
        XCTAssertEqual(specificity(":where(#x)"), "(0,0,0)")
        XCTAssertEqual(specificity(":not(.a, #b)"), "(1,0,0)")
        XCTAssertEqual(specificity(":has(> img)"), "(0,0,1)")
    }

    func testNthChildOfAddsItsSelectors() {
        XCTAssertEqual(specificity("li:nth-child(2 of .x)"), "(0,2,1)")
        XCTAssertEqual(specificity("li:nth-child(2n+1)"), "(0,1,1)")
        XCTAssertEqual(specificity("li:nth-last-child(-n + 3 of #a, .b)"), "(1,1,1)")
        XCTAssertEqual(specificity("li:nth-of-type(odd)"), "(0,1,1)")
    }

    func testPseudoElementsCountAsTypes() {
        XCTAssertEqual(specificity("a::before"), "(0,0,2)")
        XCTAssertEqual(specificity("a:before"), "(0,0,2)", "the legacy one-colon form is a pseudo-element too")
        XCTAssertEqual(specificity("p:first-line"), "(0,0,2)")
        XCTAssertEqual(specificity("::slotted(.x)"), "(0,1,1)")
    }

    func testNamespacesAndEscapesAreNotCountedTwice() {
        XCTAssertEqual(specificity("svg|circle"), "(0,0,1)")
        XCTAssertEqual(specificity("*|a"), "(0,0,1)")
        XCTAssertEqual(specificity(".a\\:b"), "(0,1,0)")
        XCTAssertEqual(specificity("#\\31 23"), "(1,0,0)")
    }

    func testAListShowsEachSelector() {
        let parts = DeveloperStyleSpecificity.components(of: "h1, .title:is(a, b), #main")
        XCTAssertEqual(parts.map(\.selector), ["h1", ".title:is(a, b)", "#main"])
        XCTAssertEqual(parts.map(\.specificity.text), ["(0,0,1)", "(0,1,1)", "(1,0,0)"])
        XCTAssertEqual(DeveloperStyleSpecificity.tooltip(for: ".a"), "Specificity: (0,1,0)")
        XCTAssertEqual(DeveloperStyleSpecificity.tooltip(for: "a, #b"),
                       "a — Specificity: (0,0,1)\n#b — Specificity: (1,0,0)")
    }
}
