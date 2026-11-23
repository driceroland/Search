import XCTest
@testable import Search

/// The @keyframes, @property, @font-face and @position-try sections below
/// the matched rules: shown read-only and kept out of the cascade.
@MainActor
final class DeveloperStyleAtRulesTests: XCTestCase {
    private typealias Rule = DeveloperToolsSession.StyleRule

    private func rule(_ selector: String, section: String? = nil, _ properties: [(String, String)], id: Int) -> Rule {
        var raw: [String: Any] = [
            "selector": selector, "origin": "regular",
            "properties": properties.map { ["name": $0.0, "value": $0.1] },
        ]
        if let section { raw["section"] = section }
        return Rule(raw: raw, id: id)!
    }

    func testKeyframesDeclarationsNeitherWinNorLose() {
        let rules = Rule.cascade([
            rule(".box", [("opacity", "1")], id: 1),
            rule("0%", section: "@keyframes fade", [("opacity", "0")], id: 2),
            rule("100%", section: "@keyframes fade", [("opacity", "1")], id: 3),
        ])
        XCTAssertFalse(rules[0].properties[0].overridden, "a keyframe doesn't strike out the element's own value")
        XCTAssertFalse(rules[1].properties[0].overridden)
        XCTAssertFalse(rules[2].properties[0].overridden, "one keyframe doesn't strike out another")
        XCTAssertTrue(rules[1].atRule)
        XCTAssertFalse(rules[0].atRule)
        XCTAssertFalse(rules[1].editable, "at-rule sections are read-only")
        XCTAssertFalse(rules[1].selectorEditable)
    }

    func testAtRulesAreNotWhereADeclarationIsRevealedOrCopiedFrom() {
        let rules = [
            rule("0%", section: "@keyframes fade", [("opacity", "0")], id: 2),
            rule(".box", [("opacity", "1")], id: 1),
        ]
        XCTAssertEqual(DeveloperToolsSession.declaringRule("opacity", in: rules), 1)
        XCTAssertFalse(rules[1].atRule)
        XCTAssertTrue(Rule(raw: ["selector": "--x", "section": "@property", "properties": [[String: Any]]()], id: 4)!.atRule)
        XCTAssertFalse(Rule(raw: ["selector": "p", "section": "Inherited from div", "properties": [[String: Any]]()], id: 5)!.atRule)
    }
}
