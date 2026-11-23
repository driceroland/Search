import XCTest
@testable import Search

/// The pure logic behind the Sources panel's Chrome parity: search across
/// sources, ⌘P's file:line:col, hover expressions, gutter markers, property
/// paths, navigator keys and Local Overrides' paths.
@MainActor
final class DeveloperSourcesParityTests: XCTestCase {
    // MARK: Search across sources

    func testSearchFindsEachLineOnceWithAllItsMatches() throws {
        let text = "  let foo = foo + 1\nbar()\nfoo()"
        let matches = try SourceSearch.find("foo", in: text, caseSensitive: false, regex: false)
        XCTAssertEqual(matches.map(\.line), [1, 3])
        XCTAssertEqual(matches[0].column, 7)
        XCTAssertEqual(matches[0].text, "let foo = foo + 1")
        XCTAssertEqual(matches[0].ranges, [NSRange(location: 4, length: 3), NSRange(location: 10, length: 3)])
        XCTAssertEqual(matches[1].column, 1)
        XCTAssertEqual(matches[1].ranges, [NSRange(location: 0, length: 3)])
    }

    func testSearchMatchCase() throws {
        let text = "Foo\nfoo"
        XCTAssertEqual(try SourceSearch.find("foo", in: text, caseSensitive: false, regex: false).count, 2)
        XCTAssertEqual(try SourceSearch.find("foo", in: text, caseSensitive: true, regex: false).map(\.line), [2])
    }

    func testSearchPlainTextIsNotAPattern() throws {
        XCTAssertEqual(try SourceSearch.find("a.b", in: "axb\na.b", caseSensitive: false, regex: false).map(\.line), [2])
        XCTAssertEqual(try SourceSearch.find("a.b", in: "axb\na.b", caseSensitive: false, regex: true).map(\.line), [1, 2])
    }

    func testSearchBadPatternThrows() {
        XCTAssertThrowsError(try SourceSearch.find("(", in: "(", caseSensitive: false, regex: true))
        XCTAssertNoThrow(try SourceSearch.find("(", in: "(", caseSensitive: false, regex: false))
    }

    func testSearchEmptyQueryAndLimit() throws {
        XCTAssertTrue(try SourceSearch.find("", in: "abc", caseSensitive: false, regex: false).isEmpty)
        let text = Array(repeating: "x", count: 10).joined(separator: "\n")
        XCTAssertEqual(try SourceSearch.find("x", in: text, caseSensitive: false, regex: false, limit: 3).count, 3)
    }

    func testSearchCutsALongLineAroundTheMatch() throws {
        let line = String(repeating: "a", count: 1_000) + "needle" + String(repeating: "b", count: 1_000)
        let match = try XCTUnwrap(SourceSearch.find("needle", in: line, caseSensitive: false, regex: false).first)
        XCTAssertTrue(match.text.hasPrefix("…"))
        XCTAssertLessThanOrEqual(match.text.count, SourceSearch.window + 1)
        let range = try XCTUnwrap(match.ranges.first)
        XCTAssertEqual((match.text as NSString).substring(with: range), "needle")
        XCTAssertEqual(match.column, 1_001)
    }

    func testSearchGoesThroughTheSourceMapsAuthoredFilesAfterThePagesOwn() {
        let page = [
            SourceResource(frame: "f", url: "https://example.com/", type: "Document"),
            SourceResource(frame: "f", url: "https://example.com/bundle.js", type: "Script"),
            SourceResource(frame: "f", url: "https://example.com/logo.png", type: "Image"),
            SourceResource(frame: "f", url: "https://example.com/api", type: "Fetch"),
            SourceResource(frame: "f", url: "https://example.com/app.css", type: "Stylesheet"),
        ]
        let content = [SourceResource(frame: "7", url: "safari-web-extension://x/content.js", type: "ContentScript")]
        let authored = [
            SourceResource(frame: "authored", url: "webpack:///src/App.tsx", type: DeveloperSourceMaps.authoredType),
            SourceResource(frame: "authored", url: "https://example.com/src/util.ts", type: DeveloperSourceMaps.authoredType),
            // A map naming the bundle itself among its sources: searched once, as the page's.
            SourceResource(frame: "authored", url: "https://example.com/bundle.js", type: DeveloperSourceMaps.authoredType),
        ]
        let files = SourceSearch.files(resources: page, contentScripts: content, authored: authored)
        XCTAssertEqual(files.map(\.url), [
            "https://example.com/", "https://example.com/bundle.js", "https://example.com/app.css",
            "safari-web-extension://x/content.js", "webpack:///src/App.tsx", "https://example.com/src/util.ts",
        ])
        XCTAssertEqual(files.filter { $0.type == DeveloperSourceMaps.authoredType }.count, 2)
        XCTAssertEqual(SourceSearch.files(resources: page, contentScripts: [], authored: []).count, 3)
    }

    // MARK: Quick open file:line:col

    func testQuickOpenLocation() {
        func check(_ query: String, _ name: String, _ line: Int?, _ column: Int?, file: StaticString = #filePath, line l: UInt = #line) {
            let found = QuickOpenMatch.location(query)
            XCTAssertEqual(found.name, name, file: file, line: l)
            XCTAssertEqual(found.line, line, file: file, line: l)
            XCTAssertEqual(found.column, column, file: file, line: l)
        }
        check("app.js", "app.js", nil, nil)
        check("app.js:120", "app.js", 120, nil)
        check("app.js:120:5", "app.js", 120, 5)
        check("app.js:", "app.js", nil, nil)
        check("app.js:120:", "app.js", 120, nil)
        check(":120", ":120", nil, nil)
        check("a:b", "a:b", nil, nil)
        check("https://example.com/app.js:12", "https://example.com/app.js", 12, nil)
    }

    // MARK: Hover expressions

    func testHoverExpressionTakesTheChainUpToTheHoveredName() {
        let line = "const x = a.b.c + y"
        let b = (line as NSString).range(of: "b").location
        XCTAssertEqual(SourceHoverExpression.expression(in: line, at: b)?.text, "a.b")
        let c = (line as NSString).range(of: "c +").location
        XCTAssertEqual(SourceHoverExpression.expression(in: line, at: c)?.text, "a.b.c")
        let y = (line as NSString).range(of: "y").location
        let found = SourceHoverExpression.expression(in: line, at: y)
        XCTAssertEqual(found?.text, "y")
        XCTAssertEqual(found?.start, y)
        XCTAssertEqual(found?.end, y + 1)
    }

    func testHoverExpressionOptionalChaining() {
        let line = "a?.b"
        XCTAssertEqual(SourceHoverExpression.expression(in: line, at: 3)?.text, "a?.b")
    }

    func testHoverExpressionSkipsKeywordsNumbersAndCalls() {
        XCTAssertNil(SourceHoverExpression.expression(in: "return x", at: 1))
        XCTAssertNil(SourceHoverExpression.expression(in: "x = 42", at: 4))
        XCTAssertNil(SourceHoverExpression.expression(in: "f().b", at: 4))
        XCTAssertNil(SourceHoverExpression.expression(in: "a[0].b", at: 5))
        XCTAssertNil(SourceHoverExpression.expression(in: "a + b", at: 1))
        XCTAssertNil(SourceHoverExpression.expression(in: "a", at: 5))
        // `this` is a value, as in Chrome: hovering `value` reads `this.value`.
        XCTAssertEqual(SourceHoverExpression.expression(in: "this.value", at: 6)?.text, "this.value")
    }

    // MARK: Gutter markers

    private func breakpoint(_ kind: DeveloperDebugger.Breakpoint.Kind, enabled: Bool = true) -> DeveloperDebugger.Breakpoint {
        var item = DeveloperDebugger.Breakpoint(url: "https://example.com/a.js", line: 3, snippet: "x()")
        item.kind = kind
        item.enabled = enabled
        return item
    }

    func testGutterMarkerKindAndState() {
        XCTAssertNil(SourceGutterMarker.combine([], active: true))
        XCTAssertEqual(SourceGutterMarker.combine([breakpoint(.regular)], active: true),
                       SourceGutterMarker(kind: .regular, enabled: true, count: 1))
        XCTAssertEqual(SourceGutterMarker.combine([breakpoint(.conditional), breakpoint(.regular)], active: true)?.kind, .conditional)
        XCTAssertEqual(SourceGutterMarker.combine([breakpoint(.conditional), breakpoint(.logpoint)], active: true)?.kind, .logpoint)
        XCTAssertEqual(SourceGutterMarker.combine([breakpoint(.regular)], active: false)?.enabled, false)
        XCTAssertEqual(SourceGutterMarker.combine([breakpoint(.regular, enabled: false)], active: true)?.enabled, false)
    }

    func testGutterMarkerEnabledBreakpointsDecide() {
        let marker = SourceGutterMarker.combine([breakpoint(.logpoint, enabled: false), breakpoint(.regular)], active: true)
        XCTAssertEqual(marker, SourceGutterMarker(kind: .regular, enabled: true, count: 2))
        let disabled = SourceGutterMarker.combine([breakpoint(.logpoint, enabled: false), breakpoint(.regular, enabled: false)], active: true)
        XCTAssertEqual(disabled, SourceGutterMarker(kind: .logpoint, enabled: false, count: 2))
    }

    // MARK: Property paths and literals

    func testPropertyPath() {
        XCTAssertEqual(DeveloperDebugger.propertyPath(.scope(0), names: ["a", "b", "0", "c-d"]), "a.b[0][\"c-d\"]")
        XCTAssertEqual(DeveloperDebugger.propertyPath(.scope(0), names: ["a", "[[Prototype]]", "b"]), "a.b")
        XCTAssertNil(DeveloperDebugger.propertyPath(.scope(0), names: ["a", "[[Entries]]", "b"]))
        XCTAssertNil(DeveloperDebugger.propertyPath(.scope(0), names: ["not-a-name"]))
        XCTAssertEqual(DeveloperDebugger.propertyPath(.expression("window.app"), names: ["state"]), "window.app.state")
        XCTAssertEqual(DeveloperDebugger.propertyPath(.expression("f()"), names: ["x"]), "(f()).x")
    }

    func testLiteral() {
        XCTAssertEqual(DeveloperDebugger.literal(.init(["type": "string", "value": "a\"b"])), "\"a\\\"b\"")
        XCTAssertEqual(DeveloperDebugger.literal(.init(["type": "number", "value": 4.5, "description": "4.5"])), "4.5")
        XCTAssertEqual(DeveloperDebugger.literal(.init(["type": "boolean", "value": true])), "true")
        XCTAssertEqual(DeveloperDebugger.literal(.init(["type": "undefined"])), "undefined")
        XCTAssertEqual(DeveloperDebugger.literal(.init(["type": "object", "subtype": "null", "value": NSNull()])), "null")
        XCTAssertEqual(DeveloperDebugger.literal(.init(["type": "bigint", "description": "10n"])), "10n")
        XCTAssertNil(DeveloperDebugger.literal(.init(["type": "object", "objectId": "1", "description": "Object"])))
    }

    // MARK: Navigator keys and reveal

    private var tree: [SourceTreeNode] {
        [
            SourceTreeNode(id: "a", name: "a", kind: .folder, children: [
                SourceTreeNode(id: "a/b", name: "b", kind: .folder, children: [
                    SourceTreeNode(id: "a/b/c", name: "c", kind: .folder),
                ]),
            ]),
            SourceTreeNode(id: "d", name: "d", kind: .folder),
        ]
    }

    func testAncestors() {
        XCTAssertEqual(SourceTree.ancestors(of: "a/b/c", in: tree), ["a", "a/b"])
        XCTAssertEqual(SourceTree.ancestors(of: "d", in: tree), [])
        XCTAssertNil(SourceTree.ancestors(of: "missing", in: tree))
    }

    func testTreeKeys() {
        let open = SourceTree.rows(tree, collapsed: [])
        XCTAssertEqual(SourceTree.move(.down, from: nil, rows: open, collapsed: []).selection, "a")
        XCTAssertEqual(SourceTree.move(.up, from: nil, rows: open, collapsed: []).selection, "d")
        XCTAssertEqual(SourceTree.move(.down, from: "a", rows: open, collapsed: []).selection, "a/b")
        XCTAssertEqual(SourceTree.move(.up, from: "a", rows: open, collapsed: []).selection, "a")
        XCTAssertEqual(SourceTree.move(.down, from: "d", rows: open, collapsed: []).selection, "d")
        // → on an open folder goes to its first child.
        XCTAssertEqual(SourceTree.move(.right, from: "a", rows: open, collapsed: []).selection, "a/b")
        // ← on an open folder closes it.
        let closed = SourceTree.move(.left, from: "a", rows: open, collapsed: [])
        XCTAssertEqual(closed.selection, "a")
        XCTAssertEqual(closed.collapsed, ["a"])
        // → on a closed folder opens it.
        let reopened = SourceTree.move(.right, from: "a", rows: SourceTree.rows(tree, collapsed: ["a"]), collapsed: ["a"])
        XCTAssertEqual(reopened.selection, "a")
        XCTAssertEqual(reopened.collapsed, [])
        // ← on an empty folder goes to the parent.
        XCTAssertEqual(SourceTree.move(.left, from: "a/b/c", rows: open, collapsed: []).selection, "a/b")
    }

    // MARK: Local Overrides

    func testOverridesRelativePath() {
        XCTAssertEqual(DeveloperLocalOverrides.relativePath(for: "https://example.com/js/app.js"), "example.com/js/app.js")
        XCTAssertEqual(DeveloperLocalOverrides.relativePath(for: "https://example.com/"), "example.com/index.html")
        XCTAssertEqual(DeveloperLocalOverrides.relativePath(for: "https://example.com"), "example.com/index.html")
        XCTAssertEqual(DeveloperLocalOverrides.relativePath(for: "https://example.com/docs/"), "example.com/docs/index.html")
        XCTAssertEqual(DeveloperLocalOverrides.relativePath(for: "https://example.com/app.js?v=2"), "example.com/app.js%3Fv=2")
        XCTAssertEqual(DeveloperLocalOverrides.relativePath(for: "http://localhost:8080/a.css"), "localhost%3A8080/a.css")
        XCTAssertNil(DeveloperLocalOverrides.relativePath(for: "file:///tmp/a.js"))
        XCTAssertNil(DeveloperLocalOverrides.relativePath(for: "data:text/plain,hi"))
    }

    func testOverridesURLPatternMatchesItsAddresses() throws {
        func matches(_ url: String) throws -> Bool {
            let path = try XCTUnwrap(DeveloperLocalOverrides.relativePath(for: url))
            let pattern = try NSRegularExpression(pattern: DeveloperLocalOverrides.urlPattern(forRelativePath: path))
            return pattern.firstMatch(in: url, range: NSRange(location: 0, length: (url as NSString).length)) != nil
        }
        for url in [
            "https://example.com/js/app.js", "https://example.com/", "https://example.com/docs/",
            "https://example.com/app.js?v=2", "http://localhost:8080/a.css",
        ] {
            XCTAssertTrue(try matches(url), url)
        }
        let index = try NSRegularExpression(pattern: DeveloperLocalOverrides.urlPattern(forRelativePath: "example.com/docs/index.html"))
        for (url, expected) in [
            ("https://example.com/docs/", true), ("http://example.com/docs/index.html", true),
            ("https://example.com/docs/#top", true), ("https://example.com/docs/other", false),
            ("https://other.com/docs/", false),
        ] {
            let found = index.firstMatch(in: url, range: NSRange(location: 0, length: (url as NSString).length)) != nil
            XCTAssertEqual(found, expected, url)
        }
    }
}
