import AppKit
import WebKit
import XCTest
@testable import Search

/// The selected element found again when the document is sent anew, as
/// Chrome's Elements panel keeps its selection across a reload.
@MainActor
final class DeveloperElementsReselectTests: XCTestCase {
    private typealias Node = DeveloperToolsSession.DOMNode

    private func element(_ id: Int, _ name: String, parent: Int?, children: [Int] = [],
                         pseudo: String? = nil, shadow: String? = nil, type: Int = 1) -> Node {
        Node(id: id, parent: parent, type: type, name: name, text: "", attributes: [],
             children: children, count: children.count, pseudoType: pseudo, shadowRootType: shadow)
    }

    private func session(_ nodes: [Node]) async -> DeveloperToolsSession {
        _ = NSApplication.shared
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let page = WKWebView(frame: .zero, configuration: configuration)
        let session = DeveloperToolsSession(tab: Tab(shy: true), web: page, after: nil)
        await session.disconnect().value
        session.loadTreeForTesting(Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) }), root: 1, expanded: [1])
        return session
    }

    func testTheSelectorCountsOnlyElementSiblings() async {
        // #document > (doctype, html > (head, body > (text, ::before, div, p > span)))
        let session = await session([
            element(1, "#document", parent: nil, children: [2, 3], type: 9),
            element(2, "html", parent: 1, type: 10),
            element(3, "html", parent: 1, children: [4, 5]),
            element(4, "head", parent: 3),
            element(5, "body", parent: 3, children: [6, 7, 8, 9]),
            element(6, "#text", parent: 5, type: 3),
            element(7, "::before", parent: 5, pseudo: "before"),
            element(8, "div", parent: 5),
            element(9, "p", parent: 5, children: [10]),
            element(10, "span", parent: 9),
        ])
        XCTAssertEqual(session.selectorPath(of: 3), ":root")
        XCTAssertEqual(session.selectorPath(of: 5), ":root > *:nth-child(2)")
        XCTAssertEqual(session.selectorPath(of: 9), ":root > *:nth-child(2) > *:nth-child(2)")
        XCTAssertEqual(session.selectorPath(of: 10), ":root > *:nth-child(2) > *:nth-child(2) > *:nth-child(1)")
        XCTAssertNil(session.selectorPath(of: 6), "a text node isn't found by a selector")
        XCTAssertNil(session.selectorPath(of: 7), "nor a pseudo-element")
    }

    func testNoSelectorUnderAShadowRootOrAPartlyKnownParent() async {
        var body = element(4, "body", parent: 3, children: [5])
        body.count = 3  // two children not sent yet
        let session = await session([
            element(1, "#document", parent: nil, children: [3], type: 9),
            element(3, "html", parent: 1, children: [4]),
            body,
            element(5, "x-card", parent: 4, children: [6]),
            element(6, "#shadow-root", parent: 5, children: [7], shadow: "open", type: 11),
            element(7, "slot", parent: 6),
        ])
        XCTAssertNil(session.selectorPath(of: 5), "body's other children aren't known: its place can't be told")
        XCTAssertNil(session.selectorPath(of: 7), "inside a shadow root")
    }
}
