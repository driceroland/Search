import XCTest
@testable import Search

/// Source maps in Sources: base64 VLQ, a hand-written map looked up both
/// ways, sourceRoot and relative sources, data: URLs, the comment that
/// names a map, and index maps' sections.
final class DeveloperSourceMapTests: XCTestCase {
    typealias Map = DeveloperSourceMap
    typealias Address = DeveloperSourceMapURL

    // MARK: VLQ

    func testVLQDecodesSignsAndContinuations() {
        XCTAssertEqual(Map.decodeVLQ("A"), [0])
        XCTAssertEqual(Map.decodeVLQ("C"), [1])
        XCTAssertEqual(Map.decodeVLQ("D"), [-1])
        XCTAssertEqual(Map.decodeVLQ("I"), [4])
        XCTAssertEqual(Map.decodeVLQ("J"), [-4])
        // 16 needs a continuation digit: g (32, more follows) then B.
        XCTAssertEqual(Map.decodeVLQ("gB"), [16])
        XCTAssertEqual(Map.decodeVLQ("2H"), [123])
        XCTAssertEqual(Map.decodeVLQ("IAAIA"), [4, 0, 0, 4, 0])
    }

    func testVLQRejectsBadDigitsAndCutOffNumbers() {
        XCTAssertNil(Map.decodeVLQ("A!"))
        XCTAssertNil(Map.decodeVLQ("g"))
    }

    func testMappingsRunOnAcrossSegmentsAndLines() throws {
        let mappings = try XCTUnwrap(Map.decodeMappings("AAAA,IAAIA;AACJ;;C"))
        XCTAssertEqual(mappings, [
            .init(generatedLine: 0, generatedColumn: 0, source: 0, originalLine: 0, originalColumn: 0),
            .init(generatedLine: 0, generatedColumn: 4, source: 0, originalLine: 0, originalColumn: 4, name: 0),
            // The generated column restarts each line; the rest run on.
            .init(generatedLine: 1, generatedColumn: 0, source: 0, originalLine: 1, originalColumn: 0),
            .init(generatedLine: 3, generatedColumn: 1),
        ])
    }

    // MARK: A hand-written map

    /// bundle.js line 0: `var a=1;` from a.ts line 0 (column 4 is `a`);
    /// line 1 from a.ts line 1, then b.ts line 1 at column 2, then
    /// nothing from column 3.
    private func handWritten() throws -> Map {
        try Map(text: """
            {"version":3,"file":"bundle.js","sources":["a.ts","b.ts"],"names":["a"],
             "sourcesContent":["let a = 1;\\nlet b = 2;","x\\ny"],
             "mappings":"AAAA,IAAIA;AACJ,ECAA,C"}
            """, mapURL: "https://example.com/js/bundle.js.map", scriptURL: "https://example.com/js/bundle.js")
    }

    func testGeneratedPositionsMapToTheirOriginals() throws {
        let map = try handWritten()
        XCTAssertEqual(map.sources, ["https://example.com/js/a.ts", "https://example.com/js/b.ts"])
        XCTAssertEqual(map.original(line: 0, column: 0),
                       .init(url: "https://example.com/js/a.ts", line: 0, column: 0, name: nil))
        // Between segments: the one at or before the column.
        XCTAssertEqual(map.original(line: 0, column: 6),
                       .init(url: "https://example.com/js/a.ts", line: 0, column: 4, name: "a"))
        XCTAssertEqual(map.original(line: 1, column: 2),
                       .init(url: "https://example.com/js/b.ts", line: 1, column: 0, name: nil))
        // A segment that maps to nothing, and a line with no segments.
        XCTAssertNil(map.original(line: 1, column: 5))
        XCTAssertNil(map.original(line: 2, column: 0))
    }

    func testOriginalLinesMapToGeneratedPositions() throws {
        let map = try handWritten()
        let a = "https://example.com/js/a.ts", b = "https://example.com/js/b.ts"
        // One position per compiled line, at its first column.
        XCTAssertEqual(map.generated(source: a, line: 0), [.init(line: 0, column: 0)])
        XCTAssertEqual(map.generated(source: a, line: 1), [.init(line: 1, column: 0)])
        // b.ts line 0 has no code; a breakpoint there moves on to line 1.
        XCTAssertEqual(map.generated(source: b, line: 0), [.init(line: 1, column: 2)])
        // A column keeps the segments at or after it.
        XCTAssertEqual(map.generated(source: a, line: 0, column: 3), [.init(line: 0, column: 4)])
        XCTAssertEqual(map.generated(source: a, line: 9), [])
        XCTAssertEqual(map.generated(source: "https://example.com/js/c.ts", line: 0), [])
    }

    func testSourcesContentIsKeptPerSource() throws {
        let map = try handWritten()
        XCTAssertEqual(map.content(of: "https://example.com/js/b.ts"), "x\ny")
        XCTAssertNil(map.content(of: "https://example.com/js/c.ts"))
    }

    func testOtherVersionsAndBadJSONAreRefused() {
        XCTAssertThrowsError(try Map(text: #"{"version":2,"sources":[],"mappings":""}"#, mapURL: nil, scriptURL: nil))
        XCTAssertThrowsError(try Map(text: "not a map", mapURL: nil, scriptURL: nil))
    }

    func testTheXSSIGuardIsSkipped() throws {
        let map = try Map(text: ")]}'\n{\"version\":3,\"sources\":[\"a.js\"],\"mappings\":\"AAAA\"}",
                          mapURL: "https://example.com/a.js.map", scriptURL: nil)
        XCTAssertEqual(map.sources, ["https://example.com/a.js"])
    }

    // MARK: Sources and sourceRoot

    func testSourceRootJoinsAndResolves() {
        let base = "https://example.com/js/app.js.map"
        XCTAssertEqual(Address.source("a.js", root: "src", base: base), "https://example.com/js/src/a.js")
        XCTAssertEqual(Address.source("a.js", root: "src/", base: base), "https://example.com/js/src/a.js")
        XCTAssertEqual(Address.source("../lib/b.js", root: "https://cdn.example.com/root/", base: base),
                       "https://cdn.example.com/lib/b.js")
        XCTAssertEqual(Address.source("./src/App.tsx", root: "webpack:///", base: base), "webpack:///src/App.tsx")
        // An absolute source ignores the root and loses its ./ parts.
        XCTAssertEqual(Address.source("webpack://app/./src/App.tsx", root: "lib", base: base), "webpack://app/src/App.tsx")
        XCTAssertEqual(Address.source("/abs/a.js", root: nil, base: base), "https://example.com/abs/a.js")
        XCTAssertEqual(Address.source("a.js", root: "", base: base), "https://example.com/js/a.js")
    }

    func testAMapsSourcesUseItsSourceRoot() throws {
        let map = try Map(text: #"{"version":3,"sourceRoot":"webpack://app/","sources":["./src/App.tsx"],"mappings":"AAAA"}"#,
                          mapURL: "https://example.com/static/main.js.map", scriptURL: nil)
        XCTAssertEqual(map.sources, ["webpack://app/src/App.tsx"])
    }

    func testRelativeMapAddressesResolveAgainstTheScript() {
        XCTAssertEqual(Address.resolve("app.js.map", against: "https://example.com/js/app.js"),
                       "https://example.com/js/app.js.map")
        XCTAssertEqual(Address.resolve("../maps/app.js.map", against: "https://example.com/js/app.js"),
                       "https://example.com/maps/app.js.map")
        XCTAssertEqual(Address.resolve("//cdn.example.com/a.map", against: "https://example.com/js/app.js"),
                       "https://cdn.example.com/a.map")
        XCTAssertEqual(Address.resolve("https://other.example/a.map", against: "https://example.com/js/app.js"),
                       "https://other.example/a.map")
    }

    func testNavigatorGroupsAuthoredFilesByOrigin() {
        XCTAssertEqual(Address.origin(of: "webpack://app/src/App.tsx"), "webpack://app")
        XCTAssertEqual(Address.origin(of: "webpack:///src/App.tsx"), "webpack://")
        XCTAssertEqual(Address.origin(of: "https://example.com/src/a.ts"), "example.com")
        XCTAssertEqual(Address.folders(of: "webpack:///src/components/App.tsx"), ["src", "components"])
        XCTAssertEqual(SourceTree.fileName("webpack:///src/App.tsx"), "App.tsx")
        let tree = SourceTree.authored([
            .init(frame: "authored", url: "webpack://app/src/App.tsx", type: DeveloperSourceMaps.authoredType),
            .init(frame: "authored", url: "webpack://app/src/index.ts", type: DeveloperSourceMaps.authoredType),
        ])
        XCTAssertEqual(tree.map(\.name), ["webpack://app"])
        XCTAssertEqual(tree.first?.children.map(\.name), ["src"])
        XCTAssertEqual(tree.first?.children.first?.children.map(\.name), ["App.tsx", "index.ts"])
    }

    // MARK: data: URLs and the comment

    func testDataURLMapsDecode() throws {
        let json = #"{"version":3,"sources":["a.js"],"mappings":"AAAA"}"#
        let base64 = "data:application/json;charset=utf-8;base64," + Data(json.utf8).base64EncodedString()
        XCTAssertEqual(Address.decodeData(base64), json)
        let percent = "data:application/json," + (json.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")
        XCTAssertEqual(Address.decodeData(percent), json)
        XCTAssertNil(Address.decodeData("https://example.com/a.map"))
        // A data: map's relative sources resolve against the script.
        let map = try Map(text: try XCTUnwrap(Address.decodeData(base64)), mapURL: nil,
                          scriptURL: "https://example.com/js/a.min.js")
        XCTAssertEqual(map.sources, ["https://example.com/js/a.js"])
    }

    func testTheLastSourceMappingURLCommentNamesTheMap() {
        XCTAssertEqual(Address.comment(in: "var a;\n//# sourceMappingURL=app.js.map\n"), "app.js.map")
        XCTAssertEqual(Address.comment(in: "var a;\n//@ sourceMappingURL=old.map"), "old.map")
        XCTAssertEqual(Address.comment(in: "//# sourceMappingURL=first.map\nx\n//# sourceMappingURL=last.map"), "last.map")
        XCTAssertEqual(Address.comment(in: "a{}\n/*# sourceMappingURL=site.css.map */"), "site.css.map")
        XCTAssertEqual(Address.comment(in: "a{}\n/*# sourceMappingURL=site.css.map*/"), "site.css.map")
        XCTAssertEqual(Address.comment(in: "x\n//# sourceMappingURL=data:application/json;base64,eyJ9"),
                       "data:application/json;base64,eyJ9")
        // Not in a comment.
        XCTAssertNil(Address.comment(in: "var s = 'sourceMappingURL=x.map';"))
        XCTAssertNil(Address.comment(in: "var a;"))
    }

    // MARK: Index maps

    func testIndexMapSectionsAreOffsetAndMerged() throws {
        let map = try Map(text: """
            {"version":3,"sections":[
              {"offset":{"line":0,"column":0},
               "map":{"version":3,"sources":["a.js"],"names":["first"],"mappings":"AAAAA"}},
              {"offset":{"line":2,"column":10},
               "map":{"version":3,"sources":["b.js","a.js"],"names":["second"],"mappings":"AAAAA;ACCA"}}
            ]}
            """, mapURL: "https://example.com/all.js.map", scriptURL: nil)
        XCTAssertEqual(map.sources, ["https://example.com/a.js", "https://example.com/b.js"])
        XCTAssertEqual(map.original(line: 0, column: 0)?.name, "first")
        // The section's column offset applies to its first line only.
        XCTAssertEqual(map.mappings.map(\.generatedColumn), [0, 10, 0])
        XCTAssertEqual(map.original(line: 2, column: 10),
                       .init(url: "https://example.com/b.js", line: 0, column: 0, name: "second"))
        // A source the earlier section named keeps its index.
        XCTAssertEqual(map.original(line: 3, column: 0),
                       .init(url: "https://example.com/a.js", line: 1, column: 0, name: nil))
        XCTAssertEqual(map.generated(source: "https://example.com/b.js", line: 0), [.init(line: 2, column: 10)])
        XCTAssertEqual(map.generated(source: "https://example.com/a.js", line: 1), [.init(line: 3, column: 0)])
    }
}
