import XCTest
@testable import Search

/// Coverage's "Export…" file and its per-function view of WebKit's basic blocks.
final class DeveloperCoverageExportTests: XCTestCase {
    typealias Math = DeveloperCoverageMath

    private func offset(of needle: String, in text: String) throws -> Int {
        let range = try XCTUnwrap(text.range(of: needle))
        return text.utf16.distance(from: text.startIndex, to: range.lowerBound)
    }

    // MARK: Functions

    func testFunctionsFoundInAScript() throws {
        let source = """
        function a(x) { if (x) { return 1 } return 2 }
        const b = (y) => { return y }
        const c = z => z * 2
        class K { method(q) { for (;;) {} } get v() { return `${1}` } }
        """
        let found = Math.functions(source)
        let a = try offset(of: "function a", in: source)
        let b = try offset(of: "(y) =>", in: source)
        let method = try offset(of: "method(q)", in: source)
        let getter = try offset(of: "v() {", in: source)
        XCTAssertEqual(found.map(\.start), [a, b, method, getter])
        // a's range runs to its own closing brace, past the `if` block inside it.
        let aEnd = try offset(of: "\nconst b", in: source)
        XCTAssertEqual(found.first?.end, aEnd)
    }

    func testNamedAndGeneratorFunctionExpressions() throws {
        let source = "x = function named() {}; y = function* gen() {}; if (z) {}"
        let found = Math.functions(source)
        XCTAssertEqual(found.map(\.start), [try offset(of: "function named", in: source),
                                            try offset(of: "function* gen", in: source)])
    }

    // MARK: Per function

    func testAFunctionThatRanCountsAsUsedAllOfIt() throws {
        // Top level 0..<40; a function 10..<30 whose first block ran and
        // whose branch (20...25) didn't.
        let blocks: [Math.Block] = [
            .init(start: 0, end: 39, executed: true),
            .init(start: 10, end: 29, executed: true),
            .init(start: 20, end: 25, executed: false),
        ]
        let functions = [Math.Function(start: 10, end: 30)]
        let ranges = Math.ranges(Math.functionBlocks(blocks, functions: functions, length: 40), length: 40)
        XCTAssertEqual(ranges, [.init(start: 0, end: 40, used: true)])
        // Per block, the branch stays unused.
        XCTAssertEqual(Math.usedBytes(Math.ranges(blocks, length: 40)), 34)
    }

    func testAFunctionThatNeverRanIsUnusedAndNestedFunctionsDecideTheirOwn() {
        // outer 0..<50 never ran; JavaScriptCore reports it as one block.
        // A second function 60..<90 ran, but its nested function 70..<80 didn't.
        let blocks: [Math.Block] = [
            .init(start: 0, end: 99, executed: true),
            .init(start: 0, end: 49, executed: false),
            .init(start: 60, end: 89, executed: true),
            .init(start: 70, end: 79, executed: false),
        ]
        let functions = [Math.Function(start: 0, end: 50), Math.Function(start: 60, end: 90),
                         Math.Function(start: 70, end: 80)]
        let ranges = Math.ranges(Math.functionBlocks(blocks, functions: functions, length: 100), length: 100)
        XCTAssertEqual(ranges, [
            .init(start: 0, end: 50, used: false),
            .init(start: 50, end: 70, used: true),
            .init(start: 70, end: 80, used: false),
            .init(start: 80, end: 100, used: true),
        ])
    }

    func testNoBlocksStaysUninstrumentedPerFunction() {
        XCTAssertEqual(Math.functionBlocks([], functions: [.init(start: 0, end: 5)], length: 10), [])
    }

    // MARK: Export

    func testExportIsChromesArrayOfURLRangesAndText() throws {
        let entry = Math.exportEntry(url: "https://example.com/app.js", text: "abcdefghij", ranges: [
            .init(start: 0, end: 4, used: true), .init(start: 4, end: 7, used: false), .init(start: 7, end: 10, used: true),
        ])
        XCTAssertEqual(entry.ranges, [.init(start: 0, end: 4), .init(start: 7, end: 10)])
        let data = try Math.exportJSON([entry])
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0]["url"] as? String, "https://example.com/app.js")
        XCTAssertEqual(parsed[0]["text"] as? String, "abcdefghij")
        let ranges = try XCTUnwrap(parsed[0]["ranges"] as? [[String: Int]])
        XCTAssertEqual(ranges, [["start": 0, "end": 4], ["start": 7, "end": 10]])
        XCTAssertEqual(Set(parsed[0].keys), ["url", "ranges", "text"])
    }

    func testGranularityNamesAreChromes() {
        XCTAssertEqual(Math.Granularity.allCases.map(\.rawValue), ["Per function", "Per block"])
    }
}
