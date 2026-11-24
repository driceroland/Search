import XCTest
@testable import Search

/// Chrome's `#adopted-style-sheets` rows: after an open document's or
/// shadow root's children, its sheets listed while it is open, with ids
/// that are never a node's.
@MainActor
final class DeveloperElementsAdoptedSheetsTests: XCTestCase {
    private typealias Node = DeveloperToolsSession.DOMNode
    private typealias Model = DeveloperDOMTreeModel

    private let tree: [Int: Node] = [
        1: Node(id: 1, parent: nil, type: 9, name: "#document", text: "", attributes: [], children: [2], count: 1),
        2: Node(id: 2, parent: 1, type: 1, name: "my-card", text: "", attributes: [], children: [3], count: 1),
        3: Node(id: 3, parent: 2, type: 11, name: "", text: "", attributes: [], children: [4], count: 1, shadowRootType: "open"),
        4: Node(id: 4, parent: 3, type: 1, name: "span", text: "", attributes: [], children: [], count: 0),
    ]
    private let adopted: [Int: [[String]?]] = [1: [["a { color: red; }"]], 3: [["b { margin: 0px; }", "i { }"], nil]]

    func testGroupRowsFollowEachOpenRootsChildren() {
        let rows = Model.flatten(nodes: tree, root: 1, expanded: [1, 2, 3], adopted: adopted, adoptedOpen: [3])
        let group1 = Model.AdoptedSheet(root: 1, index: nil).id, group3 = Model.AdoptedSheet(root: 3, index: nil).id
        let sheet30 = Model.AdoptedSheet(root: 3, index: 0).id, sheet31 = Model.AdoptedSheet(root: 3, index: 1).id
        XCTAssertEqual(rows.map(\.id), [1, 2, 3, 4, group3, sheet30, sheet31, group1])
        XCTAssertEqual(rows.map(\.depth), [0, 1, 2, 3, 3, 4, 4, 1])
        XCTAssertEqual(rows[4].sheet?.label, "#adopted-style-sheets")
        XCTAssertTrue(rows[4].expandable && rows[4].expanded)
        XCTAssertFalse(rows[7].expanded, "the document's group stays closed")
        XCTAssertEqual(rows[5].sheet?.label, "<style>b { margin: 0px; } i { }</style>")
        XCTAssertFalse(rows[5].expandable)
        XCTAssertEqual(rows[6].sheet?.label, "<style> sheet 2, rules not readable")
        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count)
    }

    func testNoGroupForClosedRootsOrRootsWithoutSheets() {
        XCTAssertEqual(Model.flatten(nodes: tree, root: 1, expanded: [1, 2], adopted: adopted).map(\.id),
                       [1, 2, 3, Model.AdoptedSheet(root: 1, index: nil).id])
        XCTAssertEqual(Model.flatten(nodes: tree, root: 1, expanded: [1, 2, 3], adopted: [1: [], 3: []]).map(\.id), [1, 2, 3, 4])
    }

    func testSyntheticIDsNeverMatchNodeIDs() {
        var seen = Set<Int>()
        for root in [0, 1, 2, 3, 1023, 1024, 50_000] {
            for index in [nil, 0, 1, 999] as [Int?] {
                let id = Model.AdoptedSheet(root: root, index: index).id
                XCTAssertLessThan(id, 0)
                XCTAssertTrue(seen.insert(id).inserted, "root \(root), sheet \(String(describing: index))")
            }
        }
    }
}
