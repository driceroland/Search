import XCTest
@testable import Search

/// The rules behind Styles' inactive-declaration hints and CSS Overview's
/// unused declarations.
final class DeveloperInactiveCSSTests: XCTestCase {
    private typealias Inactive = DeveloperInactiveCSS

    private func context(_ tag: String, _ computed: [String: String], parent: [String: String] = [:]) -> Inactive.Context {
        Inactive.Context(tag: tag, computed: computed, parent: parent)
    }

    private func context(_ computed: [String: String], parent: [String: String] = [:]) -> Inactive.Context {
        context("div", computed, parent: parent)
    }

    private func reason(_ property: String, _ value: String = "1", _ context: Inactive.Context) -> String? {
        Inactive.reason(property: property, value: value, in: context)
    }

    func testFlexAndGridContainerPropertiesNeedTheirDisplay() {
        let block = context(["display": "block", "position": "static"])
        XCTAssertEqual(reason("flex-wrap", "wrap", block),
                       "The display: block property prevents flex-wrap from having an effect. Try setting display to flex.")
        XCTAssertNil(reason("flex-wrap", "wrap", context(["display": "inline-flex"])))
        XCTAssertNotNil(reason("grid-template-columns", "1fr 1fr", block))
        XCTAssertNil(reason("grid-template-columns", "1fr 1fr", context(["display": "grid"])))
        XCTAssertNotNil(reason("justify-content", "center", block))
        XCTAssertNil(reason("justify-content", "center", context(["display": "grid"])))
        XCTAssertNotNil(reason("gap", "4px", block))
        XCTAssertNil(reason("column-gap", "4px", context(["display": "block", "column-count": "2"])))
    }

    func testItemPropertiesNeedTheParentsDisplay() {
        let inBlock = context(["display": "block"], parent: ["display": "block"])
        XCTAssertEqual(reason("flex-grow", "1", inBlock),
                       "The display: block property of the parent element prevents flex-grow from having an effect. "
                       + "Try setting the display of the parent to flex.")
        XCTAssertNil(reason("flex-grow", "1", context(["display": "block"], parent: ["display": "flex"])))
        XCTAssertNotNil(reason("grid-column", "1 / 3", context(["display": "block"], parent: ["display": "flex"])))
        XCTAssertNil(reason("grid-column", "1 / 3", context(["display": "block"], parent: ["display": "grid"])))
        XCTAssertNotNil(reason("order", "2", inBlock))
        XCTAssertNil(reason("order", "2", context(["display": "block"], parent: ["display": "grid"])))
        // Without a parent (or through display: contents) nothing is said.
        XCTAssertNil(reason("flex-grow", "1", context(["display": "block"])))
        XCTAssertNil(reason("flex-grow", "1", context(["display": "block"], parent: ["display": "contents"])))
    }

    func testSizeOffsetsAndAlignment() {
        XCTAssertNotNil(reason("width", "10px", context("span", ["display": "inline"])))
        XCTAssertNil(reason("width", "10px", context("img", ["display": "inline"])))
        XCTAssertNil(reason("width", "10px", Inactive.Context(tag: "rect", svgShape: true, computed: ["display": "inline"])))
        XCTAssertNotNil(reason("vertical-align", "middle", context(["display": "block"])))
        XCTAssertNil(reason("vertical-align", "middle", context(["display": "inline-block"])))
        XCTAssertNil(reason("vertical-align", "middle", context(["display": "table-cell"])))

        let staticBox = context(["display": "block", "position": "static"], parent: ["display": "block"])
        XCTAssertNotNil(reason("top", "1px", staticBox))
        XCTAssertNotNil(reason("z-index", "2", staticBox))
        XCTAssertNil(reason("z-index", "2", context(["display": "block", "position": "static"], parent: ["display": "flex"])))
        XCTAssertNil(reason("top", "1px", context(["display": "block", "position": "relative"])))
    }

    func testFloatColumnsAndTextOverflow() {
        XCTAssertNotNil(reason("float", "left", context(["display": "block"], parent: ["display": "flex"])))
        XCTAssertNil(reason("float", "none", context(["display": "block"], parent: ["display": "flex"])))
        XCTAssertNil(reason("float", "left", context(["display": "block", "position": "static"], parent: ["display": "block"])))
        XCTAssertNotNil(reason("float", "left", context(["display": "block", "position": "absolute"])))

        XCTAssertNotNil(reason("column-rule-style", "solid",
                               context(["display": "block", "column-count": "auto", "column-width": "auto"])))
        XCTAssertNil(reason("column-rule-style", "solid",
                            context(["display": "block", "column-count": "3", "column-width": "auto"])))

        XCTAssertEqual(reason("text-overflow", "ellipsis", context(["display": "block", "overflow-x": "visible"])),
                       "The overflow: visible property prevents text-overflow from having an effect. Try setting overflow to hidden.")
        XCTAssertNil(reason("text-overflow", "ellipsis", context(["display": "block", "overflow-x": "hidden"])))
    }

    func testAnUnknownPropertyOrThinContextSaysNothing() {
        XCTAssertNil(reason("color", "red", context(["display": "block", "position": "static"], parent: ["display": "block"])))
        XCTAssertNil(reason("flex-wrap", "wrap", context([:])))
    }
}
