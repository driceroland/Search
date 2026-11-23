import SwiftUI
import XCTest
@testable import Search

/// The Elements tree's keys and inline editing, as Chrome DevTools has
/// them: the selection's moves, the fields Tab walks, Return's edit, the
/// search marks, the badges and the page highlight.
@MainActor
final class DeveloperElementsKeysTests: XCTestCase {
    private typealias Model = DeveloperDOMTreeModel
    private typealias Tree = DeveloperDOMTreeView
    private typealias Node = DeveloperToolsSession.DOMNode

    // MARK: Moving the selection

    func testArrowsHomeEndAndPagesStayWithinTheRows() {
        XCTAssertEqual(Model.target(.down, from: 3, count: 10, page: 4), 4)
        XCTAssertEqual(Model.target(.up, from: 3, count: 10, page: 4), 2)
        XCTAssertEqual(Model.target(.up, from: 0, count: 10, page: 4), 0)
        XCTAssertEqual(Model.target(.down, from: 9, count: 10, page: 4), 9)
        XCTAssertEqual(Model.target(.home, from: 6, count: 10, page: 4), 0)
        XCTAssertEqual(Model.target(.end, from: 2, count: 10, page: 4), 9)
        XCTAssertEqual(Model.target(.pageDown, from: 2, count: 10, page: 4), 6)
        XCTAssertEqual(Model.target(.pageDown, from: 8, count: 10, page: 4), 9)
        XCTAssertEqual(Model.target(.pageUp, from: 5, count: 10, page: 4), 1)
        XCTAssertEqual(Model.target(.pageUp, from: 2, count: 10, page: 4), 0)
    }

    func testAMoveWithNothingSelectedStartsAtAnEnd() {
        XCTAssertEqual(Model.target(.down, from: nil, count: 5, page: 3), 0)
        XCTAssertEqual(Model.target(.end, from: nil, count: 5, page: 3), 4)
        XCTAssertNil(Model.target(.down, from: nil, count: 0, page: 3))
        // A tree too short for a page still moves a row.
        XCTAssertEqual(Model.target(.pageDown, from: 0, count: 5, page: 0), 1)
    }

    func testKeysThatMoveTheSelection() {
        XCTAssertEqual(Model.Move(.upArrow), .up)
        XCTAssertEqual(Model.Move(.home), .home)
        XCTAssertEqual(Model.Move(.pageDown), .pageDown)
        XCTAssertNil(Model.Move(.leftArrow))
        XCTAssertNil(Model.Move(.return))
    }

    // MARK: Inline editing

    private let element = Node(id: 7, parent: 1, type: 1, name: "a", text: "",
                               attributes: ["href", "/home", "class", "nav"], children: [], count: 0)

    func testTabWalksTheTagNameThenEachAttributeThenANewOne() {
        let id = element.id
        XCTAssertEqual(Tree.nextEdit(after: .tag(id), in: element, backwards: false, typedSomething: true),
                       .attribute(id, "href"))
        XCTAssertEqual(Tree.nextEdit(after: .attribute(id, "href"), in: element, backwards: false, typedSomething: true),
                       .attribute(id, "class"))
        XCTAssertEqual(Tree.nextEdit(after: .attribute(id, "class"), in: element, backwards: false, typedSomething: true),
                       .newAttribute(id))
        // Something typed in the new one: another; nothing: the editing ends.
        XCTAssertEqual(Tree.nextEdit(after: .newAttribute(id), in: element, backwards: false, typedSomething: true),
                       .newAttribute(id))
        XCTAssertNil(Tree.nextEdit(after: .newAttribute(id), in: element, backwards: false, typedSomething: false))
    }

    func testShiftTabWalksBackToTheTagName() {
        let id = element.id
        XCTAssertEqual(Tree.nextEdit(after: .newAttribute(id), in: element, backwards: true, typedSomething: false),
                       .attribute(id, "class"))
        XCTAssertEqual(Tree.nextEdit(after: .attribute(id, "href"), in: element, backwards: true, typedSomething: true),
                       .tag(id))
        XCTAssertNil(Tree.nextEdit(after: .tag(id), in: element, backwards: true, typedSomething: true))
    }

    func testTabFromATagWithoutAttributesAddsOne() {
        let bare = Node(id: 8, parent: 1, type: 1, name: "div", text: "", attributes: [], children: [], count: 0)
        XCTAssertEqual(Tree.nextEdit(after: .tag(8), in: bare, backwards: false, typedSomething: true), .newAttribute(8))
        XCTAssertEqual(Tree.enterEdit(for: bare), .newAttribute(8))
    }

    func testReturnEditsTheFirstAttribute() {
        XCTAssertEqual(Tree.enterEdit(for: element), .attribute(7, "href"))
        XCTAssertEqual(Tree.draft(for: .attribute(7, "class"), in: element), "class=\"nav\"")
        XCTAssertEqual(Tree.draft(for: .tag(7), in: element), "a")
        XCTAssertEqual(Tree.draft(for: .newAttribute(7), in: element), "")
    }

    // MARK: Search

    func testSearchMarksEachMatchNotTheRow() throws {
        let line = AttributedString("<div class=\"Card card\">")
        let marked = try XCTUnwrap(Model.marked(line, " card "))
        let runs = marked.runs.filter { $0.backgroundColor != nil }
        XCTAssertEqual(runs.map { String(marked[$0.range].characters) }, ["Card", "card"])
        XCTAssertEqual(String(marked.characters), String(line.characters), "the text itself is unchanged")
    }

    func testASelectorMatchMarksNothing() {
        XCTAssertNil(Model.marked(AttributedString("<div class=\"card\">"), "div.card > span"))
        XCTAssertNil(Model.marked(AttributedString("<div>"), "  "))
    }

    // MARK: Rows

    func testACollapsedElementEndsWithAClickableEllipsis() {
        let open = Node(id: 9, parent: 1, type: 1, name: "ul", text: "", attributes: [], children: [], count: 3)
        let closed = Model.Row(node: open, depth: 1, expanded: false)
        XCTAssertEqual(Model.closedTag(for: closed), "</ul>")
        XCTAssertNil(Model.closedTag(for: Model.Row(node: open, depth: 1, expanded: true)))
        XCTAssertFalse(String(DeveloperDOMTreeModel(session: nil).line(for: closed).characters).contains("…"),
                       "the row draws the ellipsis itself, to be clicked")
    }

    func testBadgesFollowTheLayoutFlagsAndSettings() {
        XCTAssertEqual(Tree.badges(flags: ["rendered", "scrollable", "event"], scroll: true, event: true), ["scroll", "event"])
        XCTAssertEqual(Tree.badges(flags: ["scrollable", "event"], scroll: false, event: true), ["event"])
        XCTAssertEqual(Tree.badges(flags: ["rendered", "flex"], scroll: true, event: true), [])
    }

    // MARK: Page highlight

    func testHighlightUsesChromesBoxColoursAndLabel() throws {
        let config = DeveloperHighlight.chrome.protocolValue
        XCTAssertEqual(config["showInfo"] as? Bool, true)
        let content = try XCTUnwrap(config["contentColor"] as? [String: Any])
        XCTAssertEqual(content["r"] as? Int, 111)
        XCTAssertEqual(content["g"] as? Int, 168)
        XCTAssertEqual(content["b"] as? Int, 220)
        XCTAssertEqual(content["a"] as? Double, 0.66)
        XCTAssertEqual((config["paddingColor"] as? [String: Any])?["a"] as? Double, 0.55)
        XCTAssertNotNil(config["borderColor"])
        XCTAssertNotNil(config["marginColor"])

        let padding = DeveloperHighlight.only(.padding).protocolValue
        XCTAssertNotNil(padding["paddingColor"])
        XCTAssertNil(padding["contentColor"])
        XCTAssertNil(padding["marginColor"])
    }
}
