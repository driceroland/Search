import XCTest
@testable import Search

/// The Memory panel's pure logic: reading JavaScriptCore's heap snapshot
/// JSON, the dominator tree and retained sizes, the Summary per class,
/// sorting, and Comparison between two snapshots.
final class DeveloperMemoryTests: XCTestCase {
    /// The root holds a Window, which holds an Object (that holds another
    /// Object and, with an Array, a third Object both reach) and an Array.
    /// Object @5 is internal and nothing reaches it. One edge points at an
    /// id the snapshot doesn't have.
    ///
    ///     root ─ Window@1 ─┬─ Object@2 ─┬─ Object@3
    ///                      │            └─ Object@6
    ///                      └─ Array@4 ──── Object@3
    private let first = """
    {"version":2,"type":"Inspector",
     "nodes":[0,0,0,0, 1,100,1,0, 2,10,2,0, 3,20,2,0, 4,30,3,0, 5,5,2,1, 6,7,2,0],
     "nodeClassNames":["<root>","Window","Object","Array"],
     "edges":[0,1,0,0, 1,2,1,0, 1,4,1,1, 2,3,1,2, 4,3,2,0, 2,6,1,3, 2,99,1,0],
     "edgeTypes":["Internal","Property","Index","Variable"],
     "edgeNames":["window","a","b","c"]}
    """

    /// Later: Objects @3, @5 and @6 are gone, Object @7 and String @8 are new.
    private let second = """
    {"version":2,"type":"Inspector",
     "nodes":[0,0,0,0, 1,100,1,0, 2,10,2,0, 4,30,3,0, 7,8,2,0, 8,12,3,0],
     "nodeClassNames":["<root>","Window","Object","String"],
     "edges":[0,1,0,0, 1,2,1,0, 1,4,1,1, 1,7,1,2, 0,8,0,0],
     "edgeTypes":["Internal","Property","Index","Variable"],
     "edgeNames":["window","a","b","c"]}
    """

    private func node(_ snapshot: DeveloperHeapSnapshot, _ id: Int) -> Int {
        snapshot.indexByID[id]!
    }

    // MARK: Parsing

    func testParsesNodesClassesAndFlags() throws {
        let snapshot = try DeveloperHeapSnapshot(json: first, timestamp: 12)
        XCTAssertEqual(snapshot.nodeCount, 7)
        XCTAssertEqual(snapshot.ids, [0, 1, 2, 3, 4, 5, 6])
        XCTAssertEqual(snapshot.sizes, [0, 100, 10, 20, 30, 5, 7])
        XCTAssertEqual(snapshot.root, 0)
        XCTAssertEqual(snapshot.timestamp, 12)
        XCTAssertTrue(snapshot.isInternal(node(snapshot, 5)))
        XCTAssertFalse(snapshot.isInternal(node(snapshot, 2)))
        XCTAssertEqual(snapshot.totalSize, 172)
    }

    func testGCDebuggingSnapshotsHaveSevenFieldsPerNode() throws {
        let json = """
        {"version":2,"type":"GCDebugging",
         "nodes":[0,0,0,0,0,0,0, 1,40,1,0,0,4096,0],
         "nodeClassNames":["<root>","Object"],"edges":[0,1,0,0],
         "edgeTypes":["Internal"],"edgeNames":[],"roots":[],"labels":[]}
        """
        let snapshot = try DeveloperHeapSnapshot(json: json)
        XCTAssertEqual(snapshot.ids, [0, 1])
        XCTAssertEqual(snapshot.retained, [40, 40])
    }

    func testRejectsWhatIsntASnapshot() {
        XCTAssertThrowsError(try DeveloperHeapSnapshot(json: "{\"nodes\": 3}"))
        XCTAssertThrowsError(try DeveloperHeapSnapshot(json: """
        {"nodes":[0,0,0],"nodeClassNames":["<root>"],"edges":[]}
        """))
    }

    func testSnapshotDistinguishesAnElementFromItsPrototype() throws {
        let json = """
        {"version":3,"type":"Inspector",
         "nodes":[0,0,0,0, 1,40,1,4, 2,40,2,0, 3,40,3,0, 4,40,4,0, 5,40,5,0, 6,40,6,0, 7,40,7,0],
         "nodeClassNames":["<root>","FixtureWidget","HTMLDivElement","Text","Comment","Document","DocumentFragment","AppDocument"],
         "edges":[]}
        """
        let snapshot = try DeveloperHeapSnapshot(json: json)
        XCTAssertTrue(snapshot.suggestsDOMNode(node(snapshot, 1)))
        XCTAssertFalse(snapshot.suggestsDOMNode(node(snapshot, 2)))
        for id in 3...6 { XCTAssertTrue(snapshot.suggestsDOMNode(node(snapshot, id))) }
        XCTAssertFalse(snapshot.suggestsDOMNode(node(snapshot, 7)))

        let older = try DeveloperHeapSnapshot(json: """
        {"version":2,"type":"Inspector","nodes":[0,0,0,0, 1,40,1,0, 2,40,2,0],
         "nodeClassNames":["<root>","JSHTMLDivElement","Widget"],"edges":[]}
        """)
        XCTAssertTrue(older.suggestsDOMNode(node(older, 1)))
        XCTAssertFalse(older.suggestsDOMNode(node(older, 2)))
    }

    // MARK: Dominators

    func testDominatorTreeAndRetainedSizes() throws {
        let snapshot = try DeveloperHeapSnapshot(json: first)
        func dominator(_ id: Int) -> Int { snapshot.ids[snapshot.dominators[node(snapshot, id)]] }
        XCTAssertEqual(dominator(1), 0)
        XCTAssertEqual(dominator(2), 1)
        XCTAssertEqual(dominator(4), 1)
        // Both Object@2 and Array@4 reach it, so only the Window holds it.
        XCTAssertEqual(dominator(3), 1)
        XCTAssertEqual(dominator(6), 2)
        // Unreachable objects are counted as held by the root.
        XCTAssertEqual(dominator(5), 0)

        func retained(_ id: Int) -> Int { snapshot.retained[node(snapshot, id)] }
        XCTAssertEqual(retained(6), 7)
        XCTAssertEqual(retained(3), 20)
        XCTAssertEqual(retained(2), 17)
        XCTAssertEqual(retained(4), 30)
        XCTAssertEqual(retained(1), 167)
        XCTAssertEqual(retained(5), 5)
        XCTAssertEqual(retained(0), 172)
    }

    /// A diamond with a loop beneath it: 0 → 1, 2 → 3 ⇄ 4.
    func testCooperHarveyKennedyOnADiamondWithALoop() {
        let graph = DeveloperHeapGraph(count: 5, from: [0, 0, 1, 2, 3, 4], to: [1, 2, 3, 3, 4, 3])
        let (dominators, postorder) = graph.dominators(root: 0)
        XCTAssertEqual(dominators, [0, 0, 0, 0, 3])
        XCTAssertEqual(postorder.last, 0)
        XCTAssertEqual(Set(postorder), Set(0..<5))
    }

    func testUnreachableChainsHangOffTheRoot() {
        // 1 → 2 and nothing reaches 1.
        let graph = DeveloperHeapGraph(count: 3, from: [1], to: [2])
        let (dominators, _) = graph.dominators(root: 0)
        XCTAssertEqual(dominators, [0, 0, 1])
    }

    func testRetainersPreserveEdgeLabelsAndDistanceToRoots() throws {
        let snapshot = try DeveloperHeapSnapshot(json: first)
        let retainers = snapshot.retainers(of: node(snapshot, 3))
        XCTAssertEqual(retainers.map { snapshot.ids[$0.node] }, [2, 4])
        XCTAssertEqual(retainers.map(\.label), ["b", "[0]"])
        XCTAssertEqual(retainers.map(\.distance), [2, 2])

        let parent = try XCTUnwrap(snapshot.retainers(of: retainers[0].node).first)
        XCTAssertEqual(snapshot.ids[parent.node], 1)
        XCTAssertEqual(parent.distance, 1)
        let root = try XCTUnwrap(snapshot.retainers(of: parent.node).first)
        XCTAssertEqual(root.node, snapshot.root)
        XCTAssertEqual(root.distance, 0)
        XCTAssertFalse(snapshot.hasRetainers(root.node))
        XCTAssertTrue(snapshot.retainers(of: node(snapshot, 5)).isEmpty)
    }

    func testRetainerRowsGiveEachPathItsOwnRow() throws {
        let snapshot = try DeveloperHeapSnapshot(json: first)
        let target = node(snapshot, 3)
        let closed = snapshot.retainerRows(of: target, expanded: []) { snapshot.retainers(of: $0) }
        XCTAssertEqual(closed.map { snapshot.ids[$0.reference!.node] }, [2, 4])
        XCTAssertEqual(closed.map(\.expandable), [true, true])
        XCTAssertEqual(closed.map(\.expanded), [false, false])

        // Window@1 holds both Object@2 and Array@4, so it shows under each.
        let open = snapshot.retainerRows(of: target, expanded: Set(closed.map(\.id))) { snapshot.retainers(of: $0) }
        XCTAssertEqual(open.map { snapshot.ids[$0.reference!.node] }, [2, 1, 4, 1])
        XCTAssertEqual(open.map { $0.reference!.label }, ["b", "window", "[0]", "a"])
        XCTAssertEqual(open.map { $0.reference!.distance }, [2, 1, 2, 1])
        XCTAssertEqual(open.map(\.depth), [0, 1, 0, 1])
        XCTAssertEqual(Set(open.map(\.id)).count, 4)
        XCTAssertEqual(open[1].parent, closed[0].id)
        XCTAssertEqual(open[3].parent, closed[1].id)

        // Under Window@1, the GC roots: distance 0, nothing further.
        let deeper = snapshot.retainerRows(of: target, expanded: [closed[0].id, open[1].id]) { snapshot.retainers(of: $0) }
        let root = try XCTUnwrap(deeper.first { $0.reference?.node == snapshot.root })
        XCTAssertEqual(root.depth, 2)
        XCTAssertEqual(root.reference?.distance, 0)
        XCTAssertFalse(root.expandable)
    }

    func testRetainerRowsListAPageThenShowMore() throws {
        let holders = 1...150
        let nodes = [0, 0, 0, 0] + holders.flatMap { [$0, 1, 1, 0] } + [1000, 1, 1, 0]
        let edges = holders.flatMap { [0, $0, 0, 0] } + holders.flatMap { [$0, 1000, 1, 0] }
        let json = """
        {"version":2,"type":"Inspector","nodes":\(nodes),"nodeClassNames":["<root>","Object"],
         "edges":\(edges),"edgeTypes":["Internal","Property"],"edgeNames":["shared"]}
        """
        let snapshot = try DeveloperHeapSnapshot(json: json)
        let target = node(snapshot, 1000)
        XCTAssertEqual(snapshot.retainers(of: target).count, 150)

        let rows = snapshot.retainerRows(of: target, expanded: []) { snapshot.retainers(of: $0) }
        XCTAssertEqual(rows.count, DeveloperHeapSnapshot.retainerPageSize + 1)
        let more = try XCTUnwrap(rows.last)
        XCTAssertNil(more.reference)
        XCTAssertEqual(more.parent, "")
        XCTAssertEqual(more.remaining, 50)
        XCTAssertEqual(rows.dropLast().map { $0.reference?.label }, Array(repeating: "shared", count: 100))

        let all = snapshot.retainerRows(of: target, expanded: [], limits: ["": 600]) { snapshot.retainers(of: $0) }
        XCTAssertEqual(all.count, 150)
        XCTAssertTrue(all.allSatisfy { $0.reference != nil })
    }

    // MARK: Containment

    func testContainmentRowsWalkDownFromTheGCRoots() throws {
        let snapshot = try DeveloperHeapSnapshot(json: first)
        let children = { (node: Int) in snapshot.children(of: node) }
        let top = snapshot.containmentRows(expanded: [], children: children)
        XCTAssertEqual(top.map { snapshot.ids[$0.reference!.node] }, [1])
        XCTAssertEqual(top[0].reference?.distance, 1)
        XCTAssertEqual(top[0].depth, 0)
        XCTAssertTrue(top[0].expandable)
        XCTAssertFalse(top[0].expanded)

        // The Window's references, largest retained size first.
        let window = snapshot.containmentRows(expanded: [top[0].id], children: children)
        XCTAssertEqual(window.map { snapshot.ids[$0.reference!.node] }, [1, 4, 2])
        XCTAssertEqual(window.map { $0.reference!.label }, ["Internal", "a", "window"])
        XCTAssertEqual(window.map(\.depth), [0, 1, 1])
        XCTAssertEqual(window.map { $0.reference!.distance }, [1, 2, 2])
        XCTAssertEqual(window[1].parent, top[0].id)

        // Object@3 is held by both, so it gets a row under each.
        let open = snapshot.containmentRows(expanded: [top[0].id, window[1].id, window[2].id], children: children)
        XCTAssertEqual(open.map { snapshot.ids[$0.reference!.node] }, [1, 4, 3, 2, 3, 6])
        XCTAssertEqual(open.map { $0.reference!.label }, ["Internal", "a", "[0]", "window", "b", "c"])
        XCTAssertEqual(open.map(\.depth), [0, 1, 2, 1, 2, 2])
        XCTAssertEqual(open[2].reference?.distance, 3)
        XCTAssertFalse(open[2].expandable)
        XCTAssertEqual(Set(open.map(\.id)).count, open.count)
        // Unreachable Object@5 isn't in the tree.
        XCTAssertFalse(open.contains { snapshot.ids[$0.reference!.node] == 5 })
    }

    func testContainmentRowsListAPageThenShowMore() throws {
        let held = 1...150
        let nodes = [0, 0, 0, 0, 1000, 1, 1, 0] + held.flatMap { [$0, 1, 1, 0] }
        let edges = [0, 1000, 0, 0] + held.flatMap { [1000, $0, 2, $0 - 1] }
        let json = """
        {"version":2,"type":"Inspector","nodes":\(nodes),"nodeClassNames":["<root>","Object"],
         "edges":\(edges),"edgeTypes":["Internal","Property","Index"],"edgeNames":[]}
        """
        let snapshot = try DeveloperHeapSnapshot(json: json)
        let children = { (node: Int) in snapshot.children(of: node) }
        let top = snapshot.containmentRows(expanded: [], children: children)
        XCTAssertEqual(top.count, 1)
        let rows = snapshot.containmentRows(expanded: [top[0].id], children: children)
        XCTAssertEqual(rows.count, 1 + DeveloperHeapSnapshot.retainerPageSize + 1)
        let more = try XCTUnwrap(rows.last)
        XCTAssertNil(more.reference)
        XCTAssertEqual(more.parent, top[0].id)
        XCTAssertEqual(more.remaining, 50)
        XCTAssertEqual(rows[1].reference?.label, "[0]")

        let all = snapshot.containmentRows(expanded: [top[0].id], limits: [top[0].id: 600], children: children)
        XCTAssertEqual(all.count, 151)
    }

    // MARK: Statistics

    func testStatisticsAddUpSizesByCategory() throws {
        let json = """
        {"version":3,"type":"Inspector",
         "nodes":[0,0,0,0, 1,10,1,0, 2,20,2,1, 3,30,3,0, 4,40,4,0, 5,50,5,0, 6,60,6,1, 7,70,7,4, 8,80,8,0, 9,5,8,1],
         "nodeClassNames":["<root>","Function","FunctionExecutable","string","Array","Uint8Array","Structure","HTMLDivElement","Object"],
         "edges":[]}
        """
        let statistics = try DeveloperHeapSnapshot(json: json).statistics()
        XCTAssertEqual(statistics.buckets.map(\.category), DeveloperHeapCategory.allCases)
        XCTAssertEqual(statistics.total, 365)
        XCTAssertEqual(statistics[.code].size, 30)
        XCTAssertEqual(statistics[.code].count, 2)
        XCTAssertEqual(statistics[.strings].size, 30)
        XCTAssertEqual(statistics[.arrays].size, 40)
        XCTAssertEqual(statistics[.typedArrays].size, 50)
        // Structure, and the internal Object.
        XCTAssertEqual(statistics[.system].size, 65)
        XCTAssertEqual(statistics[.system].count, 2)
        XCTAssertEqual(statistics[.dom].size, 70)
        XCTAssertEqual(statistics[.other].size, 80)
        XCTAssertEqual(statistics.buckets.map(\.size).reduce(0, +), statistics.total)
    }

    func testCategoriesFollowJavaScriptCoreClassNames() {
        func category(_ name: String, isInternal: Bool = false, dom: Bool = false) -> DeveloperHeapCategory {
            DeveloperHeapCategory.of(className: name, isInternal: isInternal, domNode: dom)
        }
        XCTAssertEqual(category("AsyncGeneratorFunction"), .code)
        XCTAssertEqual(category("UnlinkedFunctionCodeBlock", isInternal: true), .code)
        XCTAssertEqual(category("JSRopeString"), .strings)
        XCTAssertEqual(category("JSArray"), .arrays)
        XCTAssertEqual(category("Float64Array"), .typedArrays)
        XCTAssertEqual(category("ArrayBuffer"), .typedArrays)
        XCTAssertEqual(category("SymbolTable"), .system)
        XCTAssertEqual(category("HTMLDivElement", dom: true), .dom)
        XCTAssertEqual(category("Map"), .other)
    }

    // MARK: Allocation profile

    func testAllocationProfileCountsOnlyNewObjects() throws {
        // Objects @3, @5 and @6 were collected; @7 and String @8 are new.
        let start = try DeveloperHeapSnapshot(json: first, timestamp: 10)
        let end = try DeveloperHeapSnapshot(json: second, timestamp: 20)
        let profile = DeveloperHeapAllocationProfile(start: start, end: end, collections: [])
        let rows = Dictionary(uniqueKeysWithValues: profile.classes.map { ($0.name, $0) })
        XCTAssertEqual(Set(rows.keys), ["Object", "String"])
        XCTAssertEqual(rows["Object"]?.count, 1)
        XCTAssertEqual(rows["Object"]?.shallowSize, 8)
        XCTAssertEqual(rows["Object"]?.retainedSize, 8)
        XCTAssertEqual(rows["String"]?.count, 1)
        let object = try XCTUnwrap(rows["Object"])
        XCTAssertEqual(end.instances(of: object.index, in: profile.instances).map { end.ids[$0] }, [7])
        XCTAssertNotNil(profile.start.indexByID[3])
        XCTAssertNil(end.indexByID[3])
    }

    func testCollectionMarksFallBackWhenTimestampsDontLineUp() throws {
        let start = try DeveloperHeapSnapshot(json: first, timestamp: 10)
        let end = try DeveloperHeapSnapshot(json: second, timestamp: 20)
        typealias Collection = DeveloperHeapAllocationProfile.Collection

        let timed = DeveloperHeapAllocationProfile(start: start, end: end, collections: [
            Collection(start: 12, end: 13, full: true),
        ]).marks(end: 20)
        XCTAssertEqual(timed.count, 1)
        XCTAssertEqual(timed[0].offset, 0.2, accuracy: 1e-9)
        XCTAssertEqual(timed[0].width, 0.1, accuracy: 1e-9)
        XCTAssertTrue(timed[0].full)

        // Another clock: placed along the collections' own span.
        let elsewhere = DeveloperHeapAllocationProfile(start: start, end: end, collections: [
            Collection(start: 0.5, end: 0.6, full: false), Collection(start: 1.5, end: 1.6, full: true),
        ])
        XCTAssertEqual(elsewhere.collections.count, 2)
        let spread = elsewhere.marks(end: 20)
        XCTAssertEqual(spread.map(\.offset)[0], 0, accuracy: 1e-9)
        XCTAssertEqual(spread.map(\.offset)[1], 1.0 / 1.1, accuracy: 1e-9)

        // No time passes at all: evenly, in arrival order.
        let stalled = DeveloperHeapAllocationProfile(start: start, end: start, collections: [
            Collection(start: 0, end: 0, full: false), Collection(start: 0, end: 0, full: true),
        ]).marks(end: 10)
        XCTAssertEqual(stalled.map(\.offset), [0.25, 0.75])
        XCTAssertEqual(stalled.map(\.full), [false, true])
    }

    // MARK: Summary

    func testSummaryGroupsByClassWithoutCountingNestedInstancesTwice() throws {
        let snapshot = try DeveloperHeapSnapshot(json: first)
        let rows = Dictionary(uniqueKeysWithValues: snapshot.classes.map { ($0.name, $0) })
        XCTAssertNil(rows["<root>"])
        XCTAssertEqual(rows["Object"]?.count, 4)
        XCTAssertEqual(rows["Object"]?.shallowSize, 42)
        // @2 (17, which includes @6), @3 (20) and @5 (5); @6 is inside @2.
        XCTAssertEqual(rows["Object"]?.retainedSize, 42)
        XCTAssertEqual(rows["Window"]?.retainedSize, 167)
        XCTAssertEqual(rows["Array"]?.count, 1)
        XCTAssertEqual(rows["Array"]?.retainedSize, 30)
    }

    func testSummarySortsAndFilters() throws {
        let snapshot = try DeveloperHeapSnapshot(json: first)
        XCTAssertEqual(snapshot.summary().map(\.name), ["Window", "Object", "Array"])
        var sort = DeveloperHeapSort()
        sort.toggle(.count)
        XCTAssertEqual(snapshot.summary(sort: sort).map(\.name), ["Object", "Array", "Window"])
        sort.toggle(.count)
        XCTAssertTrue(sort.ascending)
        XCTAssertEqual(snapshot.summary(sort: sort).first?.name, "Array")
        sort.toggle(.name)
        XCTAssertTrue(sort.ascending)
        XCTAssertEqual(snapshot.summary(sort: sort).map(\.name), ["Array", "Object", "Window"])
        XCTAssertEqual(snapshot.summary(filter: "obj").map(\.name), ["Object"])
        XCTAssertEqual(snapshot.summary(filter: "  ").count, 3)
    }

    func testInstancesSortLargestRetainedFirst() throws {
        let snapshot = try DeveloperHeapSnapshot(json: first)
        let object = try XCTUnwrap(snapshot.classes.first { $0.name == "Object" })
        XCTAssertEqual(snapshot.instances(of: object.index).map { snapshot.ids[$0] }, [3, 2, 6, 5])
        var sort = DeveloperHeapSort()
        sort.toggle(.shallow)
        XCTAssertEqual(snapshot.instances(of: object.index, sort: sort).map { snapshot.ids[$0] }, [3, 2, 6, 5])
        sort.toggle(.name)
        XCTAssertEqual(snapshot.instances(of: object.index, sort: sort).map { snapshot.ids[$0] }, [2, 3, 5, 6])
        XCTAssertEqual(snapshot.instances(of: 99), [])
    }

    // MARK: Summary filter

    @MainActor
    func testSummaryFiltersObjectsAllocatedBetweenSnapshots() throws {
        typealias Entry = DeveloperMemory.Entry
        let one = try DeveloperHeapSnapshot(json: first)
        let two = try DeveloperHeapSnapshot(json: second)
        XCTAssertEqual(one.maxObjectID, 6)
        XCTAssertEqual(two.maxObjectID, 8)
        let loaded = Entry(id: 2, snapshot: one, allocations: nil, objectGeneration: DeveloperMemory.loadedGeneration,
                           json: first, fileName: "Heap-saved")
        let entries = [Entry(id: 1, snapshot: one, allocations: nil, objectGeneration: 0), loaded,
                       Entry(id: 3, snapshot: two, allocations: nil, objectGeneration: 0)]

        XCTAssertEqual(DeveloperMemory.allocationFilters(for: entries[0], in: entries).map(\.title),
                       ["All objects", "Objects allocated before Snapshot 1"])
        // The loaded snapshot isn't one of this page's, so it's skipped.
        let options = DeveloperMemory.allocationFilters(for: entries[2], in: entries)
        XCTAssertEqual(options.map(\.title), ["All objects", "Objects allocated before Snapshot 1",
                                              "Objects allocated between Snapshot 1 and Snapshot 3"])
        XCTAssertEqual(options.map(\.filter), [.all, .before(1), .between(1, 3)])
        XCTAssertNil(options[0].range)
        XCTAssertEqual(options[1].range, DeveloperHeapIDRange(after: nil, through: 6))
        XCTAssertEqual(options[2].range, DeveloperHeapIDRange(after: 6, through: 8))
        XCTAssertEqual(DeveloperMemory.allocationFilters(for: loaded, in: entries).map(\.filter), [.all])

        // Between: Object @7 and String @8, the objects new since Snapshot 1.
        let between = two.allocated(in: try XCTUnwrap(options[2].range))
        let rows = Dictionary(uniqueKeysWithValues: between.classes.map { ($0.name, $0) })
        XCTAssertEqual(Set(rows.keys), ["Object", "String"])
        XCTAssertEqual(rows["Object"]?.count, 1)
        XCTAssertEqual(rows["Object"]?.shallowSize, 8)
        XCTAssertEqual(rows["String"]?.count, 1)
        let object = try XCTUnwrap(rows["Object"])
        XCTAssertEqual(two.instances(of: object.index, in: between.instances).map { two.ids[$0] }, [7])

        // Before: what Snapshot 1 already had and Snapshot 3 still has.
        let before = two.allocated(in: try XCTUnwrap(options[1].range))
        XCTAssertEqual(Set(before.classes.map(\.name)), ["Window", "Object", "String"])
        let older = try XCTUnwrap(before.classes.first { $0.name == "Object" })
        XCTAssertEqual(two.instances(of: older.index, in: before.instances).map { two.ids[$0] }, [2])
        XCTAssertEqual(before.classes.map(\.count).reduce(0, +) + between.classes.map(\.count).reduce(0, +),
                       two.nodeCount - 1)
    }

    func testIDRangesExcludeTheirLowerBound() {
        let range = DeveloperHeapIDRange(after: 6, through: 8)
        XCTAssertFalse(range.contains(6))
        XCTAssertTrue(range.contains(7))
        XCTAssertTrue(range.contains(8))
        XCTAssertFalse(range.contains(9))
        XCTAssertTrue(DeveloperHeapIDRange(after: nil, through: 8).contains(0))
    }

    // MARK: Comparison

    func testComparisonCountsNewAndDeletedObjectsPerClass() throws {
        let before = try DeveloperHeapSnapshot(json: first)
        let after = try DeveloperHeapSnapshot(json: second)
        let rows = Dictionary(uniqueKeysWithValues: after.comparison(from: before).map { ($0.name, $0) })
        XCTAssertEqual(Set(rows.keys), ["Object", "String"])
        XCTAssertEqual(rows["Object"], DeveloperHeapDelta(name: "Object", added: 1, deleted: 3, allocatedSize: 8, freedSize: 32))
        XCTAssertEqual(rows["Object"]?.delta, -2)
        XCTAssertEqual(rows["Object"]?.sizeDelta, -24)
        XCTAssertEqual(rows["String"], DeveloperHeapDelta(name: "String", added: 1, allocatedSize: 12))
        XCTAssertTrue(after.comparison(from: after).isEmpty)
    }

    func testComparisonSorts() throws {
        let rows = try DeveloperHeapSnapshot(json: second).comparison(from: DeveloperHeapSnapshot(json: first))
        var sort = DeveloperHeapDeltaSort()
        XCTAssertEqual(sort.sorted(rows).map(\.name), ["String", "Object"])
        sort.toggle(.deleted)
        XCTAssertEqual(sort.sorted(rows).map(\.name), ["Object", "String"])
        XCTAssertEqual(sort.sorted(rows, filter: "str").map(\.name), ["String"])
    }

    // MARK: Save and load

    @MainActor
    func testSavedSnapshotLoadsBackAsTheSameSnapshot() throws {
        let (original, json) = try DeveloperMemory.readSnapshotFile(Data(first.utf8))
        let taken = DeveloperMemory.Entry(id: 1, snapshot: original, allocations: nil, objectGeneration: 0, json: json)
        XCTAssertTrue(taken.canSave)
        XCTAssertFalse(taken.loaded)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("heapsnapshot")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(try XCTUnwrap(taken.json).utf8).write(to: url)
        let (loaded, again) = try DeveloperMemory.readSnapshotFile(Data(contentsOf: url))
        XCTAssertEqual(again, first)
        XCTAssertEqual(loaded.ids, original.ids)
        XCTAssertEqual(loaded.sizes, original.sizes)
        XCTAssertEqual(loaded.dominators, original.dominators)
        XCTAssertEqual(loaded.retained, original.retained)
        XCTAssertEqual(loaded.summary(), original.summary())

        let entry = DeveloperMemory.Entry(id: 2, snapshot: loaded, allocations: nil,
                                          objectGeneration: DeveloperMemory.loadedGeneration,
                                          json: again, fileName: url.deletingPathExtension().lastPathComponent)
        XCTAssertTrue(entry.loaded)
        XCTAssertTrue(entry.canSave)
        XCTAssertEqual(entry.title, url.deletingPathExtension().lastPathComponent)
        // Object actions are off: no live generation is ever negative.
        XCTAssertLessThan(entry.objectGeneration, 0)
    }

    @MainActor
    func testOnlySnapshotsWithTheirJSONCanBeSaved() throws {
        let snapshot = try DeveloperHeapSnapshot(json: first)
        XCTAssertFalse(DeveloperMemory.Entry(id: 1, snapshot: snapshot, allocations: nil, objectGeneration: 0).canSave)
        let profile = DeveloperHeapAllocationProfile(start: snapshot, end: snapshot, collections: [])
        XCTAssertFalse(DeveloperMemory.Entry(id: 2, snapshot: snapshot, allocations: profile, objectGeneration: 0,
                                             json: first).canSave)
    }

    func testChromeSnapshotsAreRecognisedWhenLoading() {
        let chrome = """
        {"snapshot":{"meta":{"node_fields":["type","name","id","self_size","edge_count","trace_node_id","detachedness"],
         "node_types":[["hidden","object"]],"edge_fields":["type","name_or_index","to_node"],"edge_types":[["element"]]},
         "node_count":1,"edge_count":0,"trace_function_count":0},
         "nodes":[0,0,1,0,0,0,0],"edges":[],"strings":["(GC roots)"]}
        """
        XCTAssertThrowsError(try DeveloperMemory.readSnapshotFile(Data(chrome.utf8))) { error in
            XCTAssertEqual(error as? DeveloperHeapSnapshot.ParseError, .chromeFormat)
            XCTAssertTrue(error.localizedDescription.contains("Chrome"))
        }
        XCTAssertThrowsError(try DeveloperMemory.readSnapshotFile(Data("not json".utf8))) { error in
            XCTAssertNotEqual(error as? DeveloperHeapSnapshot.ParseError, .chromeFormat)
        }
    }

    func testSavedSnapshotsAreNamedAsChromeNamesThem() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let date = calendar.date(from: DateComponents(year: 2026, month: 11, day: 22, hour: 9, minute: 5, second: 7))!
        XCTAssertEqual(DeveloperMemory.snapshotFileName(date: date), "Heap-20261122T090507.heapsnapshot")
    }

    // MARK: Detached elements

    func testDOMWrapperClassNames() {
        for name in ["HTMLDivElement", "JSHTMLDivElement", "SVGPathElement", "MathMLElement", "Element",
                     "Text", "Comment", "DocumentFragment", "ShadowRoot", "CDATASection"] {
            XCTAssertTrue(DeveloperHeapSnapshot.isDOMWrapperClassName(name), name)
        }
        for name in ["HTMLDocument", "Document", "Window", "Object", "MyElement", "HTMLCollection",
                     "NodeList", "string", "HTML", "Element2"] {
            XCTAssertFalse(DeveloperHeapSnapshot.isDOMWrapperClassName(name), name)
        }
    }

    func testDetachedCandidatesSkipPrototypesInVersionThreeAndSortByRetainedSize() throws {
        // @1 a flagged custom element, @2 an unflagged HTMLDivElement (the
        // prototype), @3 a flagged div, @4 a Text, @5 a Document, @6 an Object.
        let json = """
        {"version":3,"type":"Inspector",
         "nodes":[0,0,0,0, 1,10,1,4, 2,40,2,0, 3,30,2,4, 4,20,3,0, 5,50,4,0, 6,60,5,0],
         "nodeClassNames":["<root>","FixtureWidget","HTMLDivElement","Text","HTMLDocument","Object"],
         "edges":[0,1,0,0, 0,2,0,0, 0,3,0,0, 0,4,0,0, 0,5,0,0, 0,6,0,0],
         "edgeTypes":["Internal"],"edgeNames":[]}
        """
        let snapshot = try DeveloperHeapSnapshot(json: json)
        let candidates = snapshot.detachedCandidates()
        XCTAssertEqual(candidates.nodes.map { snapshot.ids[$0] }, [3, 4, 1])
        XCTAssertEqual(candidates.total, 3)
        let capped = snapshot.detachedCandidates(limit: 2)
        XCTAssertEqual(capped.nodes.map { snapshot.ids[$0] }, [3, 4])
        XCTAssertEqual(capped.total, 3)

        // Before version 3 the class name is all there is to go by.
        let older = try DeveloperHeapSnapshot(json: """
        {"version":2,"type":"Inspector","nodes":[0,0,0,0, 1,40,1,0, 2,40,2,0, 3,40,3,0],
         "nodeClassNames":["<root>","JSHTMLDivElement","Widget","Comment"],"edges":[]}
        """)
        XCTAssertEqual(Set(older.detachedCandidates().nodes.map { older.ids[$0] }), [1, 3])
    }

    func testDOMProbeReadsThePagesAnswerAndDescribesNodesAsChromeDoes() {
        XCTAssertNil(DeveloperHeapDOMProbe(nil))
        XCTAssertNil(DeveloperHeapDOMProbe(NSNull()))
        XCTAssertEqual(DeveloperHeapDOMProbe(["connected": true]), DeveloperHeapDOMProbe(connected: true))
        let probe = DeveloperHeapDOMProbe(["connected": false, "name": "DIV", "id": "main", "classes": " card  open "] as [String: Any])
        XCTAssertEqual(probe?.connected, false)
        XCTAssertEqual(probe?.description, "div#main.card.open")
        XCTAssertEqual(DeveloperHeapDOMProbe.describe(nodeName: "#text", id: "", classes: ""), "#text")
        XCTAssertEqual(DeveloperHeapDOMProbe.describe(nodeName: "svg", id: "", classes: "icon"), "svg.icon")
        XCTAssertEqual(DeveloperHeapDOMProbe.describe(nodeName: "", id: "", classes: ""), "(node)")
    }

    func testDetachedGroupsCountNodesAndDontCountNestedNodesTwice() {
        // 1 is a detached div holding span 2 (it dominates it); 3 is
        // another detached div; 4 a detached span on its own.
        let retained = [100, 50, 20, 30, 5]
        let dominators = [0, 0, 1, 0, 0]
        let groups = DeveloperHeapDetachedReport.group([1: "div", 2: "span", 3: "div", 4: "span"],
                                                       retained: retained, dominators: dominators, root: 0)
        XCTAssertEqual(groups.map(\.description), ["div", "span"])
        XCTAssertEqual(groups[0].nodes, [1, 3])
        XCTAssertEqual(groups[0].retainedSize, 80)
        XCTAssertEqual(groups[1].nodes, [2, 4])
        // Span 2 is inside div 1's retained size already.
        XCTAssertEqual(groups[1].retainedSize, 5)

        let report = DeveloperHeapDetachedReport(groups: groups, checked: 10, candidates: 12)
        XCTAssertEqual(report.detachedCount, 4)
        XCTAssertTrue(report.truncated)
        XCTAssertEqual(report.filtered("SPA").map(\.description), ["span"])
        XCTAssertEqual(report.filtered(" ").count, 2)
    }

    func testDetachedReportKeepsOnlyNodesOutOfTheDocument() throws {
        let snapshot = try DeveloperHeapSnapshot(json: first)
        let report = snapshot.detachedReport(probes: [
            node(snapshot, 2): DeveloperHeapDOMProbe(connected: false, nodeName: "P"),
            node(snapshot, 3): DeveloperHeapDOMProbe(connected: true),
            node(snapshot, 6): DeveloperHeapDOMProbe(connected: false, nodeName: "P"),
        ], checked: 3, candidates: 3)
        XCTAssertFalse(report.truncated)
        XCTAssertEqual(report.groups.map(\.description), ["p"])
        XCTAssertEqual(Set(report.groups[0].nodes), [node(snapshot, 2), node(snapshot, 6)])
        // Object@6 is inside Object@2's retained size.
        XCTAssertEqual(report.groups[0].retainedSize, snapshot.retained[node(snapshot, 2)])
    }

    @MainActor
    func testDetachedProfilesAreTitledAsSuch() throws {
        let snapshot = try DeveloperHeapSnapshot(json: first)
        let report = DeveloperHeapDetachedReport(groups: [], checked: 0, candidates: 0)
        let entry = DeveloperMemory.Entry(id: 4, snapshot: snapshot, allocations: nil, objectGeneration: 0,
                                          detached: report)
        XCTAssertEqual(entry.title, "Detached elements 4")
    }

    // MARK: Preview

    func testPreviewText() {
        XCTAssertEqual(DeveloperMemory.previewText(["string": "hello"]), "\"hello\"")
        XCTAssertEqual(DeveloperMemory.previewText(["functionDetails": ["name": "tick", "displayName": ""]]), "function tick()")
        XCTAssertEqual(DeveloperMemory.previewText(["preview": [
            "type": "object", "description": "Object", "overflow": true,
            "properties": [["name": "a", "type": "number", "value": "1"], ["name": "b", "type": "string", "value": "x"]],
        ] as [String: Any]]), "Object {a: 1, b: \"x\", …}")
        XCTAssertEqual(DeveloperMemory.previewText([:]), "No preview for this object.")
    }
}
