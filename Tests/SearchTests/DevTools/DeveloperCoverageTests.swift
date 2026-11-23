import XCTest
@testable import Search

/// The Coverage tool's pure logic: basic blocks into used and unused
/// ranges, ranges into gutter lines, CSS rules into used bytes, and the
/// table's filtering and footer.
final class DeveloperCoverageTests: XCTestCase {
    typealias Math = DeveloperCoverageMath

    // MARK: Basic blocks

    func testBlocksParseFromTheProtocolAndSkipIncompleteOnes() {
        let blocks = Math.blocks([
            ["startOffset": 0, "endOffset": 9, "hasExecuted": true, "executionCount": 1],
            ["startOffset": 10, "endOffset": 19, "executionCount": 0],
            ["startOffset": 20],
        ])
        XCTAssertEqual(blocks, [.init(start: 0, end: 9, executed: true), .init(start: 10, end: 19, executed: false)])
    }

    func testNoBlocksMeansTheScriptWasNotInstrumented() {
        XCTAssertEqual(Math.ranges([], length: 100), [])
        XCTAssertEqual(Math.ranges([.init(start: 0, end: 9, executed: true)], length: 0), [])
    }

    func testAnInnerBlockDecidesItsOwnTextAndNeighboursMerge() {
        // A function that ran (0...29) with a branch that didn't (10...19).
        let ranges = Math.ranges([
            .init(start: 0, end: 29, executed: true),
            .init(start: 10, end: 19, executed: false),
        ], length: 30)
        XCTAssertEqual(ranges, [
            .init(start: 0, end: 10, used: true),
            .init(start: 10, end: 20, used: false),
            .init(start: 20, end: 30, used: true),
        ])
        XCTAssertEqual(Math.usedBytes(ranges), 20)
    }

    func testAnExecutedBlockInsideAnUnexecutedOneCountsAsUsed() {
        let ranges = Math.ranges([
            .init(start: 0, end: 19, executed: false),
            .init(start: 5, end: 9, executed: true),
        ], length: 20)
        XCTAssertEqual(ranges, [
            .init(start: 0, end: 5, used: false),
            .init(start: 5, end: 10, used: true),
            .init(start: 10, end: 20, used: false),
        ])
    }

    func testTextNoBlockCoversCountsAsUsedAndBlocksAreClampedToTheScript() {
        let ranges = Math.ranges([.init(start: 4, end: 50, executed: false)], length: 10)
        XCTAssertEqual(ranges, [.init(start: 0, end: 4, used: true), .init(start: 4, end: 10, used: false)])
    }

    func testTheSameTextReportedBothWaysCountsAsUsed() {
        let ranges = Math.ranges([
            .init(start: 0, end: 9, executed: false),
            .init(start: 0, end: 9, executed: true),
        ], length: 10)
        XCTAssertEqual(ranges, [.init(start: 0, end: 10, used: true)])
    }

    func testAdjacentUnusedBlocksMergeIntoOneRange() {
        let ranges = Math.ranges([
            .init(start: 0, end: 4, executed: false),
            .init(start: 5, end: 9, executed: false),
        ], length: 10)
        XCTAssertEqual(ranges, [.init(start: 0, end: 10, used: false)])
    }

    // MARK: Gutter lines

    func testLinesAreUsedWhenAnyOfTheirCodeRanAndBlankLinesGetNoMark() {
        let text = "a();\n  b();\n\nc(); d();\n"
        // Line 0 used; line 1 ("  b();", 5...10) unused; line 3: c() (13...16)
        // used, d() (18...21) unused.
        let ranges = [
            Math.Range(start: 0, end: 5, used: true),
            Math.Range(start: 5, end: 12, used: false),
            Math.Range(start: 12, end: 17, used: true),
            Math.Range(start: 17, end: 23, used: false),
        ]
        let lines = Math.lineUsage(ranges, text: text)
        XCTAssertEqual(lines[0], true)
        XCTAssertEqual(lines[1], false)
        XCTAssertNil(lines[2])
        XCTAssertEqual(lines[3], true)
    }

    func testLeadingWhitespaceInAUsedRangeDoesNotMarkAnUnusedLineUsed() {
        // The gap before an unexecuted function holds only its indentation.
        let text = "x();\n    function f() {\n    }\n"
        let start = (text as NSString).range(of: "function").location
        let ranges = Math.ranges([.init(start: start, end: text.utf16.count - 2, executed: false)], length: text.utf16.count)
        let lines = Math.lineUsage(ranges, text: text)
        XCTAssertEqual(lines, [0: true, 1: false, 2: false])
    }

    // MARK: CSS

    func testCSSRulesParseFromThePageScript() {
        let rules = Math.cssRules([
            ["kind": "style", "length": 20, "matched": true, "media": true, "refs": ["spin"]],
            ["kind": "keyframes", "length": 30, "media": true, "name": "spin"],
            ["kind": "bogus", "length": 5],
            ["kind": "other"],
        ])
        XCTAssertEqual(rules, [
            .init(kind: .style, length: 20, matched: true, media: true, references: ["spin"]),
            .init(kind: .keyframes, length: 30, media: true, name: "spin"),
        ])
    }

    func testStyleRulesAreUsedWhenTheyMatchUnderMediaThatApplies() {
        let usage = Math.cssUsage([
            .init(kind: .style, length: 10, matched: true),
            .init(kind: .style, length: 20, matched: false),
            .init(kind: .style, length: 40, matched: true, media: false),
            .init(kind: .other, length: 5),
        ])
        XCTAssertEqual(usage.used, 15)
        XCTAssertEqual(usage.total, 75)
    }

    func testKeyframesAndFontFacesAreUsedWhenAUsedRuleNamesThem() {
        let usage = Math.cssUsage([
            .init(kind: .style, length: 10, matched: true, references: ["Spin", "\"Inter\""]),
            .init(kind: .style, length: 10, matched: false, references: ["fade"]),
            .init(kind: .keyframes, length: 100, name: "spin"),
            .init(kind: .keyframes, length: 200, name: "fade"),
            .init(kind: .fontFace, length: 50, name: "Inter"),
            .init(kind: .fontFace, length: 70, name: "Unused Sans"),
            .init(kind: .keyframes, length: 1000, media: false, name: "spin"),
        ])
        XCTAssertEqual(usage.used, 10 + 100 + 50)
        XCTAssertEqual(usage.total, 1440)
    }

    // MARK: Table

    private let entries = [
        Math.Entry(url: "https://example.com/app.js", kind: .javaScript, total: 1000, unused: 300),
        Math.Entry(url: "https://example.com/site.css", kind: .css, total: 2000, unused: 1500),
        Math.Entry(url: "https://cdn.example.com/lib.js", kind: .javaScript, total: 500, unused: 300),
    ]

    func testRowsSortByUnusedBytesThenURL() {
        XCTAssertEqual(Math.shown(entries, text: "", filter: .all).map(\.url), [
            "https://example.com/site.css", "https://cdn.example.com/lib.js", "https://example.com/app.js",
        ])
    }

    func testTheTypeAndURLFiltersNarrowTheRows() {
        XCTAssertEqual(Math.shown(entries, text: "", filter: .css).map(\.kind), [.css])
        XCTAssertEqual(Math.shown(entries, text: "", filter: .javaScript).count, 2)
        XCTAssertEqual(Math.shown(entries, text: " CDN ", filter: .all).map(\.url), ["https://cdn.example.com/lib.js"])
        XCTAssertEqual(Math.shown(entries, text: "app", filter: .css), [])
    }

    func testTheFooterSumsWhatIsShown() {
        XCTAssertEqual(Math.summary(entries), "1.4 kB of 3.5 kB used (40.0%)")
        XCTAssertEqual(Math.summary([]), "0 B of 0 B used (0%)")
        XCTAssertEqual(entries[0].used, 700)
        XCTAssertEqual(entries[0].usedFraction, 0.7, accuracy: 0.0001)
    }

    func testPercentagesAndByteCounts() {
        XCTAssertEqual(Math.percent(used: 1, total: 3), "33.3%")
        XCTAssertEqual(Math.percent(used: 5, total: 5), "100%")
        XCTAssertEqual(Math.percent(used: 0, total: 5), "0%")
        XCTAssertEqual(Math.percent(used: 3, total: 0), "0%")
        XCTAssertEqual(Math.bytes(999), "999 B")
        XCTAssertEqual(Math.bytes(12_345), "12.3 kB")
        XCTAssertEqual(Math.bytes(2_500_000), "2.5 MB")
    }
}
