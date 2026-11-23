import XCTest
@testable import Search

/// The full-page accessibility tree's rows: open nodes list their children
/// under them, closed ones don't, and the bridge's rows parse.
@MainActor
final class DeveloperElementsAccessibilityTreeTests: XCTestCase {
    private typealias Tree = DeveloperAccessibilityTree

    private func node(_ id: Int, _ role: String, children: Int = 0) -> Tree.Node {
        Tree.Node(id: id, role: role, name: "", childCount: children)
    }

    func testOpenRowsListTheirChildrenUnderThem() {
        let roots = [node(1, "WebArea", children: 2)]
        let children = [1: [node(2, "main", children: 1), node(3, "contentinfo")], 2: [node(4, "button")]]
        let closed = Tree.rows(roots: roots, children: children, expanded: [1])
        XCTAssertEqual(closed.map(\.id), [1, 2, 3])
        XCTAssertEqual(closed.map(\.depth), [0, 1, 1])
        let open = Tree.rows(roots: roots, children: children, expanded: [1, 2])
        XCTAssertEqual(open.map(\.id), [1, 2, 4, 3])
        XCTAssertEqual(open.map(\.depth), [0, 1, 2, 1])
    }

    func testANodeReachedTwiceIsListedOnce() {
        let roots = [node(1, "WebArea", children: 1)]
        let rows = Tree.rows(roots: roots, children: [1: [node(2, "group", children: 1)], 2: [node(1, "WebArea")]],
                             expanded: [1, 2])
        XCTAssertEqual(rows.map(\.id), [1, 2])
    }

    func testBridgeRowsParse() {
        let raw: [[String: Any]] = [["nodeId": 7, "role": "button", "name": "Open", "childCount": 1], ["role": "x"]]
        let parsed = Tree.nodes(raw)
        XCTAssertEqual(parsed, [Tree.Node(id: 7, role: "button", name: "Open", childCount: 1)])
        XCTAssertEqual(Tree.nodes(nil), [])
    }
}
