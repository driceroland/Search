import XCTest
@testable import Search

/// Summary's Duplicated strings, Objects retained by detached DOM nodes
/// and Objects retained by the DevTools console, over a parsed snapshot.
final class DeveloperMemoryFiltersTests: XCTestCase {
    /// The root holds a Window and WebKit's injected script (Object @2),
    /// whose `_idToWrappedObject` Map @3 holds Objects @5 and @6 and whose
    /// `_savedResults` is Array @4. The Window holds Object @6 too, a
    /// detached div @7 that alone holds Object @8, and two strings.
    ///
    ///     root ─┬─ Window@1 ─┬─ Object@6
    ///           │            ├─ HTMLDivElement@7 ── Object@8
    ///           │            └─ string@9, string@10
    ///           └─ Object@2 ─┬─ Map@3 ─┬─ Object@5
    ///                        │         └─ Object@6
    ///                        └─ Array@4
    private let json = """
    {"version":2,"type":"Inspector",
     "nodes":[0,0,0,0, 1,100,1,0, 2,20,2,0, 3,30,3,0, 4,40,4,0, 5,5,2,0, 6,6,2,0, 7,70,5,0, 8,8,2,0,
              9,9,6,0, 10,9,6,0],
     "nodeClassNames":["<root>","Window","Object","Map","Array","HTMLDivElement","string"],
     "edges":[0,1,0,0, 0,2,0,0, 2,3,1,2, 2,4,1,3, 3,5,0,0, 3,6,0,0, 1,6,1,5, 1,7,1,4, 7,8,1,6,
              1,9,1,7, 1,10,1,8],
     "edgeTypes":["Internal","Property","Index","Variable"],
     "edgeNames":["window","injected","_idToWrappedObject","_savedResults","leak","a","b","s1","s2"]}
    """

    private func node(_ snapshot: DeveloperHeapSnapshot, _ id: Int) -> Int { snapshot.indexByID[id]! }

    private func rows(_ grouping: DeveloperHeapGrouping) -> [String: DeveloperHeapClass] {
        Dictionary(uniqueKeysWithValues: grouping.classes.map { ($0.name, $0) })
    }

    func testConsoleKeepsOnlyWhatNothingElseHolds() throws {
        let snapshot = try DeveloperHeapSnapshot(json: json)
        XCTAssertEqual(Set(snapshot.consoleHolders().map { snapshot.ids[$0] }), [3, 4])
        let retained = snapshot.retainedByConsole()
        let byName = rows(retained)
        // Object @6 is the Window's too, so only Object @5 is the console's.
        XCTAssertEqual(Set(byName.keys), ["Object"])
        XCTAssertEqual(byName["Object"]?.count, 1)
        XCTAssertEqual(byName["Object"]?.shallowSize, 5)
        let object = try XCTUnwrap(byName["Object"])
        XCTAssertEqual(snapshot.instances(of: object.index, in: retained.instances).map { snapshot.ids[$0] }, [5])
    }

    func testNoInjectedScriptMeansNothingIsTheConsoles() throws {
        let plain = json.replacingOccurrences(of: "_idToWrappedObject", with: "wrapped")
        let snapshot = try DeveloperHeapSnapshot(json: plain)
        XCTAssertEqual(snapshot.consoleHolders(), [])
        XCTAssertTrue(snapshot.retainedByConsole().classes.isEmpty)
    }

    func testDetachedNodesAndWhatOnlyTheyHold() throws {
        let snapshot = try DeveloperHeapSnapshot(json: json)
        let retained = snapshot.retained(byDetached: [node(snapshot, 7)])
        let byName = rows(retained)
        XCTAssertEqual(Set(byName.keys), ["HTMLDivElement", "Object"])
        XCTAssertEqual(byName["HTMLDivElement"]?.count, 1)
        XCTAssertEqual(byName["Object"]?.shallowSize, 8)
        XCTAssertTrue(snapshot.retained(byDetached: []).classes.isEmpty)
    }

    func testDuplicatedStringsGroupByValue() throws {
        let snapshot = try DeveloperHeapSnapshot(json: json)
        let candidates = snapshot.stringCandidates()
        XCTAssertEqual(candidates.nodes.map { snapshot.ids[$0] }, [9, 10])
        XCTAssertEqual(candidates.total, 2)
        XCTAssertEqual(snapshot.stringCandidates(limit: 1).nodes.count, 1)

        let grouping = snapshot.duplicatedStrings([node(snapshot, 9): "hello", node(snapshot, 10): "hello",
                                                   node(snapshot, 1): "alone"])
        XCTAssertEqual(grouping.classes.map(\.name), ["\"hello\""])
        let row = try XCTUnwrap(grouping.classes.first)
        XCTAssertEqual(row.count, 2)
        XCTAssertEqual(row.shallowSize, 18)
        XCTAssertEqual(Set(snapshot.instances(of: row.index, in: grouping.instances).map { snapshot.ids[$0] }), [9, 10])
        XCTAssertTrue(snapshot.duplicatedStrings([:]).classes.isEmpty)
    }

    func testStringsAreNamedOnOneLineAndCut() {
        XCTAssertEqual(DeveloperHeapSnapshot.quoted("a\nb\tc"), "\"a\\nb\\tc\"")
        XCTAssertEqual(DeveloperHeapSnapshot.quoted(String(repeating: "x", count: 5), limit: 3), "\"xxx…\"")
    }

    func testRetentionFiltersFollowChromesMenu() async throws {
        typealias Entry = DeveloperMemory.Entry
        let snapshot = try DeveloperHeapSnapshot(json: json)
        let taken = Entry(id: 1, snapshot: snapshot, allocations: nil, objectGeneration: 0)
        XCTAssertEqual(DeveloperMemory.retentionFilters(for: taken).map(\.title),
                       ["Duplicated strings", "Objects retained by detached DOM nodes",
                        "Objects retained by the DevTools console"])
        XCTAssertEqual(DeveloperMemory.retentionFilters(for: taken).map(\.scope),
                       [.duplicatedStrings, .retainedByDetachedNodes, .retainedByConsole])
        let generation = await DeveloperMemory.loadedGeneration
        let loaded = Entry(id: 2, snapshot: snapshot, allocations: nil, objectGeneration: generation,
                           json: json, fileName: "Heap-saved")
        XCTAssertEqual(DeveloperMemory.retentionFilters(for: loaded).map(\.filter), [.retainedByConsole])
        let options = DeveloperMemory.allocationFilters(for: taken, in: [taken])
        XCTAssertNil(options[0].scope)
        XCTAssertEqual(options[1].scope, .range(DeveloperHeapIDRange(after: nil, through: 10)))
    }
}
