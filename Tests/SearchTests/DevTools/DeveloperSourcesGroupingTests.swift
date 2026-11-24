import XCTest
@testable import Search

/// The Sources navigator's Group by Authored/Deployed.
@MainActor
final class DeveloperSourcesGroupingTests: XCTestCase {
    private typealias Frame = DeveloperToolsSession.ResourceFrame

    private func files(_ nodes: [SourceTreeNode]) -> [String] {
        nodes.flatMap { node -> [String] in
            if case let .file(resource) = node.kind { return [resource.url] }
            return files(node.children)
        }
    }

    private let resources = [
        SourceResource(frame: "main", url: "https://example.com/", type: "Document"),
        SourceResource(frame: "main", url: "https://example.com/bundle.js", type: "Script"),
    ]
    private let frames = [Frame(id: "main", parent: nil, url: "https://example.com/", name: "")]
    private let authored = [
        SourceResource(frame: "authored", url: "webpack:///src/App.tsx", type: DeveloperSourceMaps.authoredType),
        SourceResource(frame: "authored", url: "https://example.com/src/util.ts", type: DeveloperSourceMaps.authoredType),
    ]

    func testAuthoredThenDeployed() {
        let nodes = SourceTree.grouped(resources, frames: frames, authored: authored)
        XCTAssertEqual(nodes.map(\.name), ["Authored", "Deployed"])
        XCTAssertEqual(nodes.map(\.id), [SourceTree.authoredGroupID, SourceTree.deployedGroupID])
        XCTAssertEqual(Set(files([nodes[0]])), Set(authored.map(\.url)))
        XCTAssertEqual(Set(files([nodes[1]])), Set(resources.map(\.url)))
        // Deployed holds the frame tree as the ungrouped navigator shows it, without the originals.
        XCTAssertEqual(nodes[1].children.map(\.name), ["top"])
        XCTAssertEqual(nodes[1].children, SourceTree.build(resources, frames: frames))
    }

    func testUngroupedTreeKeepsTheOriginalsUnderTop() {
        let nodes = SourceTree.build(resources, frames: frames, authored: authored)
        XCTAssertEqual(nodes.map(\.name), ["top"])
        XCTAssertEqual(Set(files(nodes)), Set((resources + authored).map(\.url)))
    }

    /// Chrome puts https://example.com/src/util.ts under example.com beside
    /// bundle.js, with one example.com node, and webpack:// on its own.
    func testAnAuthoredFileFromThePagesHostSharesItsNode() {
        let top = SourceTree.build(resources, frames: frames, authored: authored)[0]
        XCTAssertEqual(top.children.map(\.name), ["webpack://", "example.com"])
        let host = top.children[1]
        XCTAssertEqual(host.children.map(\.name), ["src", "(index)", "bundle.js"])
        XCTAssertEqual(files([host.children[0]]), ["https://example.com/src/util.ts"])
    }

    func testEmptyGroupsAreLeftOut() {
        XCTAssertEqual(SourceTree.grouped(resources, frames: frames, authored: []).map(\.name), ["Deployed"])
        XCTAssertEqual(SourceTree.grouped([], frames: [], authored: authored).map(\.name), ["Authored"])
        XCTAssertTrue(SourceTree.grouped([], frames: [], authored: []).isEmpty)
    }

    func testRevealFindsAFileUnderItsGroup() {
        let nodes = SourceTree.grouped(resources, frames: frames, authored: authored)
        let above = SourceTree.ancestors(of: authored[0].id, in: nodes)
        XCTAssertEqual(above?.first, SourceTree.authoredGroupID)
        XCTAssertEqual(SourceTree.ancestors(of: resources[1].id, in: nodes)?.first, SourceTree.deployedGroupID)
    }
}
