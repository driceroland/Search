import XCTest
@testable import Search

/// Folders among the pinned rows (PinFolders.swift): the files staying
/// readable both ways, what is drawn, what may go where, and Arc's nested
/// folders coming in nested. In memory only.
final class PinFoldersTests: XCTestCase {
    private func def(_ letter: String, folder: UUID? = nil) -> PinDef {
        PinDef(id: UUID(), letter: letter, home: "https://\(letter.lowercased()).example/",
               title: letter, name: nil, listed: true, folder: folder)
    }

    private func folder(_ name: String, in parent: UUID? = nil, collapsed: Bool = false) -> PinFolder {
        PinFolder(id: UUID(), name: name, parent: parent, collapsed: collapsed)
    }

    // MARK: - the files

    func testAPinInNoFolderIsWrittenAsItAlwaysWas() throws {
        let data = try JSONEncoder().encode(def("A"))
        let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]).keys
        XCTAssertFalse(keys.contains("folder"))
    }

    func testAPinsFolderRoundTripsAndAnOldPinReadsAsInNone() throws {
        let f = UUID()
        let a = def("A", folder: f)
        XCTAssertEqual(try JSONDecoder().decode(PinDef.self, from: JSONEncoder().encode(a)), a)
        let old = #"{"id":"\#(UUID().uuidString)","letter":"G","home":"https://g.example/","title":"G"}"#
        XCTAssertNil(try JSONDecoder().decode(PinDef.self, from: Data(old.utf8)).folder)
    }

    func testAPinsFileWithFoldersStillReadsAsPins() throws {
        let space = UUID()
        let a = def("A", folder: UUID())
        let data = try XCTUnwrap(Pins.encode(bySpace: [space: [a]], shared: []))
        XCTAssertEqual(Pins.decode(data)?.bySpace[space], [a])
    }

    func testAFolderSavedWithoutItsStateIsOpenAtTheTop() throws {
        let id = UUID()
        let json = #"{"id":"\#(id.uuidString)","name":"Work","parent":"not an id"}"#
        let read = try JSONDecoder().decode(PinFolder.self, from: Data(json.utf8))
        XCTAssertEqual(read, PinFolder(id: id, name: "Work", parent: nil, collapsed: false))
    }

    func testASpaceWhoseFoldersDontReadLosesNoOtherSpace() throws {
        let good = UUID(), bad = UUID()
        let work = folder("Work")
        let encoded = try XCTUnwrap(PinFolders.encode([good: [work]]))
        var top = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        top[bad.uuidString] = [["name": 3]]
        top["not a space"] = []
        let read = PinFolders.decode(try JSONSerialization.data(withJSONObject: top))
        XCTAssertEqual(read, [good: [work]])
    }

    func testSharingAPinTakesItOutOfItsFolder() {
        let a = def("A", folder: UUID())
        let moved = Pins.share(a.id, own: [a], shared: [])
        XCTAssertNil(moved.shared.first?.folder)
    }

    // MARK: - what is drawn

    func testFoldersComeFirstThenPinsEachFolderFollowedByWhatItHolds() {
        let work = folder("Work"), docs = folder("Docs", in: work.id)
        let a = def("A"), b = def("B", folder: work.id), c = def("C", folder: docs.id)
        let lines = PinTree.lines(pins: [a, b, c].map { ($0.id, $0.folder) }, folders: [work, docs])
        XCTAssertEqual(lines, [
            .folder(work, depth: 0),
            .folder(docs, depth: 1),
            .pin(c.id, depth: 2),
            .pin(b.id, depth: 1),
            .pin(a.id, depth: 0),
        ])
    }

    func testAFoldedFolderHidesWhatItHoldsButThePageYouAreOn() {
        let work = folder("Work", collapsed: true), docs = folder("Docs", in: work.id)
        let b = def("B", folder: work.id), c = def("C", folder: docs.id)
        let pins = [b, c].map { ($0.id, $0.folder) }
        XCTAssertEqual(PinTree.lines(pins: pins, folders: [work, docs]), [.folder(work, depth: 0)])
        XCTAssertEqual(PinTree.lines(pins: pins, folders: [work, docs], showing: c.id),
                       [.folder(work, depth: 0), .pin(c.id, depth: 2)])
    }

    func testAPinWhoseFolderIsGoneIsAtTheTop() {
        let a = def("A", folder: UUID())
        XCTAssertEqual(PinTree.lines(pins: [(a.id, a.folder)], folders: []), [.pin(a.id, depth: 0)])
    }

    func testOrderedPutsThePinsInTheOrderTheyAreDrawn() {
        let work = folder("Work")
        let a = def("A"), b = def("B", folder: work.id)
        XCTAssertEqual(PinTree.ordered([a, b], folders: [work]), [b, a])
    }

    // MARK: - what may go where

    func testAFolderThatWouldHoldItselfOrHasNoParentGoesToTheTop() {
        var x = folder("X"), y = folder("Y")
        x.parent = y.id
        y.parent = x.id
        let lost = folder("Lost", in: UUID())
        let clean = PinTree.sanitized([x, y, lost])
        XCTAssertTrue(clean.contains { $0.parent == nil && ($0.id == x.id || $0.id == y.id) })
        XCTAssertNil(clean.first { $0.id == lost.id }?.parent)
        XCTAssertEqual(PinTree.lines(pins: [], folders: [x, y, lost]).count, 3)
    }

    func testAFolderTooDeepGoesUpToTheDeepestThatMayHoldIt() {
        let one = folder("1"), two = folder("2", in: one.id), three = folder("3", in: two.id)
        let four = folder("4", in: three.id)
        let clean = PinTree.sanitized([one, two, three, four])
        XCTAssertEqual(clean.first { $0.id == four.id }?.parent, two.id)
        XCTAssertTrue(clean.allSatisfy { PinTree.depth(of: $0.id, in: clean) <= PinTree.maxDepth })
    }

    func testNestingStaysWithinTheLimitAndNeverInsideItself() {
        let one = folder("1"), two = folder("2", in: one.id), three = folder("3", in: two.id)
        let other = folder("Other"), inner = folder("Inner", in: other.id)
        let all = [one, two, three, other, inner]
        XCTAssertTrue(PinTree.canMake(in: two.id, in: all))
        XCTAssertFalse(PinTree.canMake(in: three.id, in: all))
        XCTAssertFalse(PinTree.canMove(one.id, into: three.id, in: all))
        XCTAssertFalse(PinTree.canMove(one.id, into: one.id, in: all))
        XCTAssertTrue(PinTree.canMove(other.id, into: one.id, in: all))
        XCTAssertFalse(PinTree.canMove(other.id, into: two.id, in: all))
        XCTAssertTrue(PinTree.canMove(three.id, into: nil, in: all))
    }

    func testRemovingAFolderHandsWhatItHeldToItsParent() {
        let work = folder("Work"), docs = folder("Docs", in: work.id), old = folder("Old", in: docs.id)
        let a = def("A", folder: docs.id), b = def("B", folder: work.id)
        let after = PinTree.removing(docs.id, folders: [work, docs, old], pins: [a, b])
        XCTAssertEqual(after.folders.map(\.id), [work.id, old.id])
        XCTAssertEqual(after.folders.last?.parent, work.id)
        XCTAssertEqual(after.pins.map(\.folder), [work.id, work.id])
    }

    func testAnImportMakesNoEmptyFolder() {
        let mine = folder("Mine"), work = folder("Work"), docs = folder("Docs", in: work.id), empty = folder("Empty")
        let a = def("A", folder: docs.id)
        let kept = PinTree.withoutEmpty([mine, work, docs, empty], keeping: [mine.id], pins: [a])
        XCTAssertEqual(kept.map(\.id), [mine.id, work.id, docs.id])
    }

    // MARK: - Arc

    /// A StorableSidebar.json with one space whose pinned list is a page and
    /// a folder four deep, each level holding a page.
    private func arcFile() throws -> Data {
        var items: [[String: Any]] = []
        func tab(_ id: String, _ url: String) -> [String: Any] {
            ["id": id, "title": id, "data": ["tab": ["savedURL": url, "savedTitle": id]]]
        }
        func list(_ id: String, _ children: [String]) -> [String: Any] {
            ["id": id, "title": id, "childrenIds": children, "data": ["list": [:] as [String: Any]]]
        }
        items.append(["id": "pinned", "childrenIds": ["top", "L1"], "data": [:] as [String: Any]])
        items.append(tab("top", "https://top.example/"))
        items.append(list("L1", ["p1", "L2"]))
        items.append(tab("p1", "https://one.example/"))
        items.append(list("L2", ["p2", "L3"]))
        items.append(tab("p2", "https://two.example/"))
        items.append(list("L3", ["p3", "L4"]))
        items.append(tab("p3", "https://three.example/"))
        items.append(list("L4", ["p4"]))
        items.append(tab("p4", "https://four.example/"))
        let space: [String: Any] = ["id": "s", "title": "Work", "containerIDs": ["pinned", "pinned"]]
        let main: [String: Any] = ["spaces": ["s", space], "items": items, "topAppsContainerIDs": [] as [Any]]
        return try JSONSerialization.data(withJSONObject: ["sidebar": ["containers": [["global": [:] as [String: Any]], main]]])
    }

    func testArcsParserKeepsTheNesting() throws {
        let sidebar = try XCTUnwrap(Arc.parse(arcFile(), profile: nil))
        let pinned = try XCTUnwrap(sidebar.spaces.first?.pinned)
        XCTAssertEqual(pinned.count, 2)
        guard case .folder(let l1) = pinned[1], case .folder(let l2) = l1.items[1],
              case .folder(let l3) = l2.items[1], case .folder(let l4) = l3.items[1]
        else { return XCTFail("folders not nested: \(pinned)") }
        XCTAssertEqual([l1.title, l2.title, l3.title, l4.title], ["L1", "L2", "L3", "L4"])
        XCTAssertEqual(sidebar.pinnedCount, 5)
    }

    func testArcsFoldersComeInNestedToTheLimit() throws {
        let sidebar = try XCTUnwrap(Arc.parse(arcFile(), profile: nil))
        let filed = PinTree.fromArc(try XCTUnwrap(sidebar.spaces.first?.pinned), into: [])
        // L1 › L2 › L3; L4 is one too deep, its page goes into L3.
        XCTAssertEqual(filed.folders.map(\.name), ["L1", "L2", "L3"])
        let byName = Dictionary(uniqueKeysWithValues: filed.folders.map { ($0.name, $0) })
        XCTAssertNil(byName["L1"]?.parent)
        XCTAssertEqual(byName["L2"]?.parent, byName["L1"]?.id)
        XCTAssertEqual(byName["L3"]?.parent, byName["L2"]?.id)
        let where_ = Dictionary(uniqueKeysWithValues: filed.pages.map { ($0.item.url.host() ?? "", $0.folder) })
        XCTAssertEqual(where_["top.example"], .some(nil))
        XCTAssertEqual(where_["one.example"], byName["L1"]?.id)
        XCTAssertEqual(where_["two.example"], byName["L2"]?.id)
        XCTAssertEqual(where_["three.example"], byName["L3"]?.id)
        XCTAssertEqual(where_["four.example"], byName["L3"]?.id)
        XCTAssertEqual(filed.pages.map(\.item.url.absoluteString).first, "https://top.example/")
    }

    func testBringingArcInAgainFillsTheFoldersThereAre() throws {
        let sidebar = try XCTUnwrap(Arc.parse(arcFile(), profile: nil))
        let pinned = try XCTUnwrap(sidebar.spaces.first?.pinned)
        let first = PinTree.fromArc(pinned, into: [])
        let again = PinTree.fromArc(pinned, into: first.folders)
        XCTAssertEqual(again.folders, first.folders)
        XCTAssertEqual(again.pages.map(\.folder), first.pages.map(\.folder))
    }

    func testArcsFoldersInsideAFolderCountItsDepth() {
        let deep = folder("Deep"), deeper = folder("Deeper", in: deep.id)
        let nodes: [ArcSidebar.Node] = [.folder(.init(title: "Arc", items: [
            .item(.init(title: "x", url: URL(string: "https://x.example/")!)),
        ]))]
        let filed = PinTree.fromArc(nodes, into: [deep, deeper], parent: deeper.id)
        // Deeper is at depth 2: Arc's folder can go in at 3, no further.
        XCTAssertEqual(filed.folders.last?.parent, deeper.id)
        XCTAssertEqual(filed.pages.first?.folder, filed.folders.last?.id)
    }
}
