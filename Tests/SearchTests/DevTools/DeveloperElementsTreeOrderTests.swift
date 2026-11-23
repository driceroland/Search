import XCTest
@testable import Search

/// The Elements tree's rows under a node, as Chrome DevTools orders them:
/// ::marker, ::before, the shadow root, a template's content, a frame's
/// document, the children, then ::after.
@MainActor
final class DeveloperElementsTreeOrderTests: XCTestCase {
    private typealias Session = DeveloperToolsSession
    private typealias Node = DeveloperToolsSession.DOMNode

    /// A host as WebKit describes it: pseudo-elements and the shadow root
    /// apart from its one child.
    private static let host: [String: Any] = [
        "nodeId": 10, "nodeType": 1, "nodeName": "MY-CARD", "childNodeCount": 1, "attributes": ["id", "card"],
        "children": [["nodeId": 13, "nodeType": 1, "nodeName": "SPAN", "childNodeCount": 0, "attributes": []]],
        "pseudoElements": [
            ["nodeId": 11, "nodeType": 1, "nodeName": "::after", "pseudoType": "after"],
            ["nodeId": 12, "nodeType": 1, "nodeName": "::before", "pseudoType": "before"],
            ["nodeId": 15, "nodeType": 1, "nodeName": "::marker", "pseudoType": "marker"],
        ],
        "shadowRoots": [["nodeId": 14, "nodeType": 11, "nodeName": "#document-fragment",
                         "shadowRootType": "open", "childNodeCount": 2]],
    ]

    func testHostRowsComeInChromesOrder() {
        var tree: [Int: Node] = [:]
        let ids = Session.addNodes([Self.host], into: &tree, parent: nil)
        XCTAssertEqual(ids, [10])
        XCTAssertEqual(tree[10]?.children, [15, 12, 14, 13, 11])
        // One child of its own, and four rows beside it: all to expand.
        XCTAssertEqual(tree[10]?.count, 5)
        XCTAssertEqual(tree[12]?.display, "::before")
        XCTAssertEqual(tree[14]?.display, "#shadow-root (open)")
        XCTAssertEqual(tree[14]?.parent, 10)
        XCTAssertNil(tree[10]?.inlineText(in: tree))
    }

    func testTemplateContentAndFrameDocumentComeBeforeChildren() {
        var tree: [Int: Node] = [:]
        _ = Session.addNodes([
            ["nodeId": 20, "nodeType": 1, "nodeName": "TEMPLATE", "childNodeCount": 0, "attributes": [],
             "templateContent": ["nodeId": 21, "nodeType": 11, "nodeName": "#document-fragment", "childNodeCount": 3]],
            // WebKit counts a frame's document as its child already.
            ["nodeId": 30, "nodeType": 1, "nodeName": "IFRAME", "childNodeCount": 1, "attributes": ["src", "a.html"],
             "contentDocument": ["nodeId": 31, "nodeType": 9, "nodeName": "#document", "childNodeCount": 1]],
        ], into: &tree, parent: 1)
        XCTAssertEqual(tree[20]?.children, [21])
        XCTAssertEqual(tree[20]?.count, 1)
        XCTAssertEqual(tree[21]?.display, "#document-fragment")
        XCTAssertEqual(tree[30]?.children, [31])
        XCTAssertEqual(tree[30]?.count, 1)
        XCTAssertEqual(tree[31]?.display, "#document")
    }

    func testBrowsersOwnShadowRootsStayHidden() {
        var tree: [Int: Node] = [:]
        _ = Session.addNodes([
            ["nodeId": 40, "nodeType": 1, "nodeName": "INPUT", "childNodeCount": 0, "attributes": [],
             "shadowRoots": [["nodeId": 41, "nodeType": 11, "nodeName": "#document-fragment",
                              "shadowRootType": "user-agent", "childNodeCount": 1]]],
        ], into: &tree, parent: 1)
        XCTAssertEqual(tree[40]?.children, [])
        XCTAssertEqual(tree[40]?.count, 0)
        XCTAssertNil(tree[41])
    }

    func testChildrenSentLaterKeepTheRowsBesideThem() {
        var tree: [Int: Node] = [:]
        var host = Self.host
        host["children"] = nil
        _ = Session.addNodes([host], into: &tree, parent: nil)
        XCTAssertEqual(tree[10]?.children, [15, 12, 14, 11])
        XCTAssertEqual(tree[10]?.count, 5)
        // The host again, as a parent's setChildNodes sends it with its
        // children and without the rest: ::before and the root stay.
        _ = Session.addNodes([[
            "nodeId": 10, "nodeType": 1, "nodeName": "MY-CARD", "childNodeCount": 1, "attributes": [],
            "children": [["nodeId": 13, "nodeType": 1, "nodeName": "SPAN", "childNodeCount": 0, "attributes": []]],
        ]], into: &tree, parent: nil)
        XCTAssertEqual(tree[10]?.children, [15, 12, 14, 13, 11])
    }

    func testBridgePayloadInTreeOrderIsTakenAsIs() {
        var tree: [Int: Node] = [:]
        // perchElements.children: rows already ordered, with the count of
        // those beside the node's own children.
        _ = Session.addNodes([[
            "nodeId": 50, "nodeType": 1, "nodeName": "DIV", "childNodeCount": 1, "extraChildCount": 2, "attributes": [],
            "children": [
                ["nodeId": 51, "nodeType": 1, "nodeName": "::before", "pseudoType": "before", "childNodeCount": 0],
                ["nodeId": 52, "nodeType": 3, "nodeName": "#text", "nodeValue": "hi", "childNodeCount": 0],
                ["nodeId": 53, "nodeType": 1, "nodeName": "::after", "pseudoType": "after", "childNodeCount": 0],
            ],
        ]], into: &tree, parent: 1)
        XCTAssertEqual(tree[50]?.children, [51, 52, 53])
        XCTAssertEqual(tree[50]?.count, 3)
        XCTAssertNil(tree[50]?.inlineText(in: tree), "a ::before keeps the text on a row of its own")
    }

    func testTreeOrderIsStableWithinAKind() {
        let tree: [Int: Node] = [
            1: Node(id: 1, parent: 0, type: 1, name: "a", text: "", attributes: [], children: [], count: 0),
            2: Node(id: 2, parent: 0, type: 1, name: "", text: "", attributes: [], children: [], count: 0, pseudoType: "after"),
            3: Node(id: 3, parent: 0, type: 1, name: "b", text: "", attributes: [], children: [], count: 0),
            4: Node(id: 4, parent: 0, type: 11, name: "", text: "", attributes: [], children: [], count: 0,
                    shadowRootType: "closed"),
        ]
        XCTAssertEqual(Node.treeOrder([2, 1, 3, 4, 1], in: tree), [4, 1, 3, 2])
        XCTAssertEqual(tree[4]?.display, "#shadow-root (closed)")
    }

    func testFlattenShowsShadowContentUnderAnOpenHost() {
        var tree: [Int: Node] = [
            1: Node(id: 1, parent: nil, type: 9, name: "#document", text: "", attributes: [], children: [10], count: 1),
        ]
        _ = Session.addNodes([Self.host], into: &tree, parent: 1)
        let rows = DeveloperDOMTreeModel.flatten(nodes: tree, root: 1, expanded: [1, 10])
        XCTAssertEqual(rows.map(\.id), [1, 10, 15, 12, 14, 13, 11])
        XCTAssertTrue(rows.first { $0.id == 14 }?.expandable ?? false, "the shadow root has children to open")
        XCTAssertEqual(String(DeveloperDOMTreeModel.styledLine(tree[12]!, closed: false).characters), "::before")
        XCTAssertEqual(String(DeveloperDOMTreeModel.styledLine(tree[14]!, closed: true).characters), "#shadow-root (open)")
    }
}
