import XCTest
@testable import Search

final class DeveloperHeaderOverridesTests: XCTestCase {
    typealias Overrides = DeveloperHeaderOverrides
    typealias Header = DeveloperHeaderOverrides.Header

    private func h(_ name: String, _ value: String) -> Header { Header(name: name, value: value) }

    // MARK: Parsing

    func testParsesChromesFormat() throws {
        let rules = try Overrides.parse("""
            [
              {"applyTo": "index.html", "headers": [{"name": "foo", "value": "bar"}, {"name": "n", "value": 3}]},
              {"applyTo": "*.js", "headers": []}
            ]
            """)
        XCTAssertEqual(rules, [
            .init(applyTo: "index.html", headers: [h("foo", "bar"), h("n", "3")]),
            .init(applyTo: "*.js", headers: []),
        ])
        XCTAssertEqual(try Overrides.parse("  \n"), [])
    }

    func testRejectsMalformedFiles() {
        XCTAssertThrowsError(try Overrides.parse("{"))
        XCTAssertThrowsError(try Overrides.parse(#"{"applyTo": "a"}"#))
        XCTAssertThrowsError(try Overrides.parse(#"[{"applyTo": "a"}]"#))
        XCTAssertThrowsError(try Overrides.parse(#"[{"applyTo": "a", "headers": [{"value": "x"}]}]"#))
        XCTAssertThrowsError(try Overrides.parse(#"[{"applyTo": "a", "headers": [{"name": "x"}]}]"#))
    }

    func testEncodingRoundTrips() throws {
        let rules: [Overrides.Rule] = [
            .init(applyTo: "app.js", headers: [h("Cache-Control", "no-store"), h("x-quote", "a \"b\" / c")]),
            .init(applyTo: "*", headers: []),
        ]
        let text = Overrides.encode(rules)
        XCTAssertTrue(text.contains("\"applyTo\": \"app.js\""))
        XCTAssertEqual(try Overrides.parse(text), rules)
        XCTAssertEqual(Overrides.encode([]), "[]\n")
    }

    // MARK: Matching

    func testTargetIsHostAndPathWithIndexForFolders() throws {
        let page = try XCTUnwrap(Overrides.target(for: "https://Example.com/a/?q=1#top"))
        XCTAssertEqual(page.path, "example.com/a/index.html")
        XCTAssertEqual(page.query, "q=1")
        XCTAssertEqual(Overrides.target(for: "http://localhost:8080")?.path, "localhost:8080/index.html")
        XCTAssertEqual(Overrides.target(for: "https://a.com/b%20c.js")?.path, "a.com/b c.js")
        XCTAssertNil(Overrides.target(for: "data:text/plain,hi"))
    }

    func testApplyToIsRelativeToTheFilesFolder() {
        XCTAssertTrue(Overrides.matches("https://example.com/js/app.js", directory: "example.com/js", applyTo: "app.js"))
        XCTAssertTrue(Overrides.matches("http://example.com/js/app.js", directory: "example.com/js", applyTo: "app.js"))
        XCTAssertFalse(Overrides.matches("https://example.com/app.js", directory: "example.com/js", applyTo: "app.js"))
        XCTAssertFalse(Overrides.matches("https://example.com/js/app.json", directory: "example.com/js", applyTo: "app.js"))
        // Dots are literal.
        XCTAssertFalse(Overrides.matches("https://example.com/js/appxjs", directory: "example.com/js", applyTo: "app.js"))
    }

    func testWildcardsMatchAnything() {
        XCTAssertTrue(Overrides.matches("https://example.com/js/a/b.js", directory: "example.com", applyTo: "*.js"))
        XCTAssertTrue(Overrides.matches("https://example.com/", directory: "example.com", applyTo: "*"))
        XCTAssertFalse(Overrides.matches("https://other.com/x.js", directory: "example.com", applyTo: "*.js"))
        // At the top of the folder, applyTo names hosts too.
        XCTAssertTrue(Overrides.matches("https://any.org/x", directory: "", applyTo: "*"))
        XCTAssertTrue(Overrides.matches("https://cdn.any.org/x.css", directory: "", applyTo: "cdn.*/*.css"))
        XCTAssertEqual(Overrides.pattern(directory: "a.com/", applyTo: "*.js"), "^a\\.com\\/.*\\.js$")
    }

    func testFolderPagesAndQueries() {
        XCTAssertTrue(Overrides.matches("https://example.com/", directory: "example.com", applyTo: "index.html"))
        // The path alone matches whatever the query; a rule can also name one.
        XCTAssertTrue(Overrides.matches("https://example.com/app.js?v=2", directory: "example.com", applyTo: "app.js"))
        XCTAssertTrue(Overrides.matches("https://example.com/app.js?v=2", directory: "example.com", applyTo: "app.js?v=2"))
        XCTAssertFalse(Overrides.matches("https://example.com/app.js?v=3", directory: "example.com", applyTo: "app.js?v=2"))
    }

    func testDeeperFilesApplyLast() {
        let files: [Overrides.File] = [
            .init(directory: "example.com/js", rules: [.init(applyTo: "*", headers: [h("x-a", "deep")])]),
            .init(directory: "", rules: [.init(applyTo: "*", headers: [h("x-a", "top"), h("x-b", "top")])]),
            .init(directory: "example.com", rules: [
                .init(applyTo: "*.js", headers: [h("x-b", "host")]),
                .init(applyTo: "*.css", headers: [h("x-c", "css")]),
            ]),
        ]
        XCTAssertEqual(Overrides.overrides(for: "https://example.com/js/app.js", in: files), [h("x-a", "deep"), h("x-b", "host")])
        XCTAssertEqual(Overrides.overrides(for: "https://other.com/", in: files), [h("x-a", "top"), h("x-b", "top")])
        XCTAssertEqual(Overrides.compiled(files).map { $0.headers.count }, [2, 1, 1, 1])
    }

    // MARK: Merging

    func testOverridesReplaceSameNamedHeadersIgnoringCase() {
        let base = [h("Content-Type", "text/html"), h("Cache-Control", "max-age=60"), h("cache-control", "public"), h("Vary", "Accept")]
        let merged = Overrides.merge(base, [h("cache-control", "no-store"), h("X-New", "1"), h("vary", "")])
        XCTAssertEqual(merged, [h("Content-Type", "text/html"), h("cache-control", "no-store"), h("vary", ""), h("X-New", "1")])
    }

    func testRepeatedOverrideNamesAreAllSent() {
        let merged = Overrides.merge([h("Link", "a")], [h("link", "b"), h("link", "c")])
        XCTAssertEqual(merged, [h("link", "b"), h("link", "c")])
    }

    func testSetCookieMergesByCookieName() {
        let base = [h("Set-Cookie", "a=1; Path=/"), h("Set-Cookie", "b=2"), h("Set-Cookie", "odd")]
        let merged = Overrides.merge(base, [h("set-cookie", "b=override"), h("set-cookie", "c=3"), h("set-cookie", "odd")])
        XCTAssertEqual(merged.map(\.value), ["a=1; Path=/", "b=override", "odd", "c=3"])
        XCTAssertTrue(merged.allSatisfy { $0.name == "set-cookie" })
        XCTAssertEqual(Overrides.cookieKey("id=5; Secure"), "id=")
        XCTAssertEqual(Overrides.cookieKey("bad name=1"), "bad name=1")
    }

    func testApplyLeavesUnmatchedResponsesAlone() {
        let files = [Overrides.File(directory: "a.com", rules: [.init(applyTo: "x.js", headers: [h("x", "1")])])]
        let base = [h("A", "b")]
        XCTAssertEqual(Overrides.apply(to: base, url: "https://b.com/x.js", in: files), base)
        XCTAssertEqual(Overrides.apply(to: base, url: "https://a.com/x.js", in: files), [h("A", "b"), h("x", "1")])
    }

    func testObjectFormJoinsValues() {
        let object = Overrides.object([h("Set-Cookie", "a=1"), h("set-cookie", "b=2"), h("Link", "x"), h("link", "y")])
        XCTAssertEqual(object, ["Set-Cookie": "a=1\nb=2", "Link": "x, y"])
        XCTAssertEqual(Overrides.headers(from: ["Set-Cookie": "a=1\nb=2", "A": "1"]),
                       [h("A", "1"), h("Set-Cookie", "a=1"), h("Set-Cookie", "b=2")])
    }

    // MARK: Editing

    func testLocationIsTheFilesFolderAndName() throws {
        let script = try XCTUnwrap(Overrides.location(for: "https://example.com/js/app.js?v=1"))
        XCTAssertEqual(script.directory, "example.com/js")
        XCTAssertEqual(script.applyTo, "app.js")
        let page = try XCTUnwrap(Overrides.location(for: "https://example.com/"))
        XCTAssertEqual(page.directory, "example.com")
        XCTAssertEqual(page.applyTo, "index.html")
        XCTAssertTrue(Overrides.matches("https://example.com/js/app.js?v=1", directory: script.directory, applyTo: script.applyTo))
    }

    func testSettingReplacesAddsAndRemovesTheRule() {
        var rules: [Overrides.Rule] = [.init(applyTo: "*.js", headers: [h("a", "1")])]
        rules = Overrides.setting([h("b", "2"), h(" ", "dropped")], applyTo: "app.js", in: rules)
        XCTAssertEqual(rules, [.init(applyTo: "*.js", headers: [h("a", "1")]), .init(applyTo: "app.js", headers: [h("b", "2")])])
        rules = Overrides.setting([h("b", "3")], applyTo: "app.js", in: rules)
        XCTAssertEqual(Overrides.headers(applyTo: "app.js", in: rules), [h("b", "3")])
        rules = Overrides.setting([], applyTo: "app.js", in: rules)
        XCTAssertEqual(rules, [.init(applyTo: "*.js", headers: [h("a", "1")])])
        XCTAssertEqual(Overrides.setting([], applyTo: "none", in: rules), rules)
    }
}
