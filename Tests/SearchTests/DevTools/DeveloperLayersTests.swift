import CoreGraphics
import XCTest
@testable import Search

/// The Layers drawer's pure logic: parsing WebKit's LayerTree.Layer, the
/// rows' labels, the tree by DOM nesting, sorting, the summary, the
/// compositing reasons in words and the diagram's geometry.
final class DeveloperLayersTests: XCTestCase {
    private typealias Tree = DeveloperLayerTree
    private typealias Geometry = DeveloperLayerGeometry

    private func layer(_ id: String, node: Int, order: Int, paints: Int = 0, memory: Double = 0,
                       bounds: DeveloperLayerRect = .init(width: 10, height: 10)) -> DeveloperLayer {
        DeveloperLayer(id: id, nodeId: node, bounds: bounds, paintCount: paints, memory: memory, order: order)
    }

    // MARK: Parsing

    func testALayerReadsWebKitsFieldsAndPlacesItsCompositedBoundsOnThePage() throws {
        let raw: [String: Any] = [
            "layerId": "12", "nodeId": 34,
            "bounds": ["x": 10, "y": 20, "width": 300, "height": 150],
            "compositedBounds": ["x": -5, "y": 0, "width": 310, "height": 160],
            "paintCount": 7, "memory": 186_000,
            "isInShadowTree": true, "isGeneratedContent": true, "pseudoElementId": "9", "pseudoElement": "before",
        ]
        let layer = try XCTUnwrap(DeveloperLayer(raw: raw, order: 3))
        XCTAssertEqual(layer.id, "12")
        XCTAssertEqual(layer.nodeId, 34)
        XCTAssertEqual(layer.bounds, DeveloperLayerRect(x: 10, y: 20, width: 300, height: 150))
        XCTAssertEqual(layer.compositedBounds, DeveloperLayerRect(x: 5, y: 20, width: 310, height: 160))
        XCTAssertEqual(layer.paintCount, 7)
        XCTAssertEqual(layer.memory, 186_000)
        XCTAssertTrue(layer.isInShadowTree)
        XCTAssertTrue(layer.isGeneratedContent)
        XCTAssertFalse(layer.isPrimary)
        XCTAssertEqual(layer.pseudoElementId, "9")
        XCTAssertEqual(layer.pseudoElement, "before")
        XCTAssertEqual(layer.order, 3)
    }

    func testALayerWithoutAnIdIsDroppedAndOneSentTwiceIsKeptOnce() {
        let layers = Tree.layers([
            ["layerId": "1", "nodeId": 1],
            ["nodeId": 2],
            ["layerId": "1", "nodeId": 3],
            ["layerId": 4, "nodeId": 4],
        ])
        XCTAssertEqual(layers.map(\.id), ["1", "4"])
        XCTAssertEqual(layers.map(\.order), [0, 3])
        XCTAssertEqual(layers[0].compositedBounds, layers[0].bounds)
    }

    // MARK: Labels

    func testLabelsSayWhatKindOfExtraLayerItIs() {
        var generated = layer("a", node: 5, order: 0)
        generated.isGeneratedContent = true
        generated.pseudoElement = "after"
        XCTAssertEqual(Tree.label(generated, node: "div#card"), "div#card::after")
        var reflection = layer("b", node: 5, order: 1)
        reflection.isReflection = true
        XCTAssertEqual(Tree.label(reflection, node: "img"), "img (reflection)")
        var anonymous = layer("c", node: 5, order: 2)
        anonymous.isAnonymous = true
        XCTAssertEqual(Tree.label(anonymous, node: "body"), "anonymous in body")
        XCTAssertEqual(Tree.label(layer("d", node: 8, order: 3), node: nil), "node 8")
        XCTAssertEqual(Tree.label(layer("e", node: 0, order: 4), node: ""), "layer")
    }

    // MARK: Tree

    /// #document › div#app (with its ::before) › video; the video's info
    /// says its nearest ancestor with a layer is div#app.
    private func nested() -> (layers: [DeveloperLayer], nodes: [Int: DeveloperLayerNodeInfo], order: [Int]) {
        var before = layer("C", node: 3, order: 2, paints: 9, memory: 100)
        before.isGeneratedContent = true
        before.pseudoElement = "before"
        let layers = [
            layer("A", node: 1, order: 0, paints: 1, memory: 4000),
            layer("B", node: 3, order: 1, paints: 5, memory: 200),
            before,
            layer("D", node: 4, order: 3, paints: 5, memory: 300),
        ]
        let nodes: [Int: DeveloperLayerNodeInfo] = [
            1: .init(label: "#document", parent: nil),
            3: .init(label: "div#app", parent: 0),
            4: .init(label: "video", parent: 1),
        ]
        return (layers, nodes, [1, 3, 4])
    }

    func testParentsFollowTheDomAndExtraLayersGoUnderTheirNodesOwn() {
        let (layers, nodes, order) = nested()
        let parents = Tree.parents(layers, nodes: nodes, order: order)
        XCTAssertEqual(parents, ["B": "A", "C": "B", "D": "B"])
    }

    func testABadParentCycleIsBrokenSoEveryLayerStillShows() {
        let layers = [layer("A", node: 1, order: 0), layer("B", node: 2, order: 1)]
        let nodes: [Int: DeveloperLayerNodeInfo] = [1: .init(label: "a", parent: 1), 2: .init(label: "b", parent: 0)]
        let parents = Tree.parents(layers, nodes: nodes, order: [1, 2])
        let rows = Tree.rows(layers, parents: parents, sort: .tree)
        XCTAssertEqual(Set(rows.map(\.id)), ["A", "B"])
    }

    func testTreeRowsAreDepthFirstWithSiblingsInPaintOrder() {
        let (layers, nodes, order) = nested()
        let rows = Tree.rows(layers, parents: Tree.parents(layers, nodes: nodes, order: order), sort: .tree)
        XCTAssertEqual(rows.map(\.id), ["A", "B", "C", "D"])
        XCTAssertEqual(rows.map(\.depth), [0, 1, 2, 2])
    }

    func testFlatSortsPutTheMostPaintedOrLargestFirstTiesInPaintOrder() {
        let (layers, _, _) = nested()
        XCTAssertEqual(Tree.rows(layers, parents: [:], sort: .paintCount).map(\.id), ["C", "B", "D", "A"])
        XCTAssertEqual(Tree.rows(layers, parents: [:], sort: .memory).map(\.id), ["A", "D", "B", "C"])
        XCTAssertTrue(Tree.rows(layers, parents: [:], sort: .memory).allSatisfy { $0.depth == 0 })
    }

    // MARK: Summary

    func testTheSummaryCountsLayersAndAddsTheirMemory() {
        let (layers, _, _) = nested()
        XCTAssertEqual(Tree.totalMemory(layers), 4600)
        XCTAssertEqual(Tree.summary(layers), "4 layers · 4.6 kB")
        XCTAssertEqual(Tree.summary([layer("x", node: 1, order: 0, memory: 812)]), "1 layer · 812 B")
        XCTAssertEqual(Tree.summary([]), "0 layers · 0 B")
    }

    func testBytesAreWrittenInThousandsAsChromeDoes() {
        XCTAssertEqual(Tree.bytes(0), "0 B")
        XCTAssertEqual(Tree.bytes(-3), "0 B")
        XCTAssertEqual(Tree.bytes(812), "812 B")
        XCTAssertEqual(Tree.bytes(4100), "4.1 kB")
        XCTAssertEqual(Tree.bytes(150_000), "150 kB")
        XCTAssertEqual(Tree.bytes(12_300_000), "12.3 MB")
        XCTAssertEqual(Tree.bytes(999_960), "1.0 MB")
    }

    func testSizesAreWholePixels() {
        let rect = DeveloperLayerRect(x: 0.4, y: 64, width: 1279.6, height: 720.2)
        XCTAssertEqual(rect.sizeLabel, "1280 × 720")
        XCTAssertEqual(rect.label, "(0, 64) 1280 × 720")
    }

    // MARK: Compositing reasons

    func testReasonsAreWebKitsSentencesInItsOrderThenAnyNewOnesSpelledOut() {
        let labels = DeveloperLayerReasons.labels([
            "root": true, "transform3D": true, "willChange": NSNumber(value: 1), "video": false,
            "someNewReason": true, "anotherThing": false,
        ])
        XCTAssertEqual(labels, [
            "Element has a 3D transform",
            "Element has “will-change” style which includes opacity, transform, transform-style, perspective, filter or backdrop-filter",
            "Element is the root element",
            "Some new reason",
        ])
        XCTAssertEqual(DeveloperLayerReasons.labels([:]), [])
        XCTAssertEqual(DeveloperLayerReasons.labels(["positionSticky": true]), ["Element has “position: sticky” style"])
    }

    func testReasonNamesAreSpelledAsWords() {
        XCTAssertEqual(DeveloperLayerReasons.spelled("someNewReason"), "Some new reason")
        XCTAssertEqual(DeveloperLayerReasons.spelled("transform3D"), "Transform 3D")
        XCTAssertEqual(DeveloperLayerReasons.spelled("usesHTMLCanvas"), "Uses HTML canvas")
        XCTAssertEqual(DeveloperLayerReasons.spelled("x"), "X")
    }

    // MARK: Geometry

    private let page = [
        DeveloperLayer(id: "back", bounds: .init(x: 0, y: 0, width: 100, height: 50), order: 0),
        DeveloperLayer(id: "front", bounds: .init(x: 50, y: 25, width: 50, height: 25), order: 1),
    ]

    func testTheExtentCoversEveryLayerAndTheStackIsSpacedByItsSize() {
        XCTAssertEqual(Geometry.extent(page), DeveloperLayerRect(x: 0, y: 0, width: 100, height: 50))
        XCTAssertEqual(Geometry.spacing(extent: Geometry.extent(page), count: 2), 10)
        XCTAssertEqual(Geometry.spacing(extent: Geometry.extent(page), count: 51), 1)
        XCTAssertEqual(Geometry.spacing(extent: Geometry.extent(page), count: 1), 0)
    }

    func testStraightOnTheLayersFitTheViewAsThePageLaysThemOut() {
        let quads = Geometry.quads(page, yaw: 0, pitch: 0)
        XCTAssertEqual(quads.map(\.id), ["back", "front"])
        let fit = Geometry.fit(quads.flatMap(\.corners), into: CGSize(width: 220, height: 120), padding: 10)
        XCTAssertEqual(fit.scale, 2, accuracy: 1e-9)
        let corners = quads[0].corners.map(fit.apply)
        let expected = [CGPoint(x: 10, y: 10), CGPoint(x: 210, y: 10), CGPoint(x: 210, y: 110), CGPoint(x: 10, y: 110)]
        for (corner, want) in zip(corners, expected) {
            XCTAssertEqual(corner.x, want.x, accuracy: 1e-9)
            XCTAssertEqual(corner.y, want.y, accuracy: 1e-9)
        }
    }

    func testTheFrontMostLayerUnderThePointerIsHit() {
        let quads = Geometry.quads(page, yaw: 0, pitch: 0)
        let fit = Geometry.fit(quads.flatMap(\.corners), into: CGSize(width: 220, height: 120), padding: 10)
        let fitted = quads.map { quad -> Geometry.Quad in
            var copy = quad
            copy.corners = quad.corners.map(fit.apply)
            return copy
        }
        XCTAssertEqual(Geometry.hit(fitted, at: CGPoint(x: 150, y: 80)), "front")
        XCTAssertEqual(Geometry.hit(fitted, at: CGPoint(x: 20, y: 20)), "back")
        XCTAssertNil(Geometry.hit(fitted, at: CGPoint(x: 1, y: 1)))
    }

    func testTurningProjectsDepthAcrossTheView() {
        let center = Geometry.Point3(x: 0, y: 0, z: 0)
        let turned = Geometry.project(.init(x: 1, y: 0, z: 0), center: center, yaw: .pi / 2, pitch: 0)
        XCTAssertEqual(turned.point.x, 0, accuracy: 1e-9)
        XCTAssertEqual(turned.depth, -1, accuracy: 1e-9)
        let deep = Geometry.project(.init(x: 0, y: 0, z: 2), center: center, yaw: .pi / 2, pitch: 0)
        XCTAssertEqual(deep.point.x, 2, accuracy: 1e-9)
        let tilted = Geometry.project(.init(x: 0, y: 0, z: 2), center: center, yaw: 0, pitch: .pi / 2)
        XCTAssertEqual(tilted.point.y, -2, accuracy: 1e-9)
        let straight = Geometry.project(.init(x: 3, y: 4, z: 5), center: center, yaw: 0, pitch: 0)
        XCTAssertEqual(straight.point, CGPoint(x: 3, y: 4))
        XCTAssertEqual(straight.depth, 5)
    }

    func testTurnedQuadsAreDrawnBackToFront() {
        // Turned so the stack is seen from behind: the last painted is furthest.
        let quads = Geometry.quads(page, yaw: .pi, pitch: 0)
        XCTAssertEqual(quads.map(\.id), ["front", "back"])
    }

    func testPolygonContainment() {
        let square = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 10), CGPoint(x: 0, y: 10)]
        XCTAssertTrue(Geometry.contains(square, CGPoint(x: 5, y: 5)))
        XCTAssertFalse(Geometry.contains(square, CGPoint(x: 15, y: 5)))
        XCTAssertFalse(Geometry.contains([CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)], CGPoint(x: 0.5, y: 0.5)))
    }
}
