import XCTest
@testable import Search

/// Rendering's frame meter and layout shift layer live in the page, but the
/// Elements tree leaves them out, as Chrome draws its own outside the page.
@MainActor
final class DeveloperPerchOverlayTests: XCTestCase {
    func testPerchOverlaysStayOutOfTheElementsTree() {
        var tree: [Int: DeveloperToolsSession.DOMNode] = [:]
        let ids = DeveloperToolsSession.addNodes([
            ["nodeId": 5, "nodeType": 1, "nodeName": "BODY"],
            ["nodeId": 6, "nodeType": 1, "nodeName": "PERCH-FRAME-METER"],
            ["nodeId": 7, "nodeType": 3, "nodeName": "#text", "nodeValue": "perch-frame-meter"],
        ], into: &tree, parent: nil)
        XCTAssertEqual(ids, [5, 7])
        XCTAssertNil(tree[6])
    }
}
