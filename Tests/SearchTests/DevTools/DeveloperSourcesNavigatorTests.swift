import XCTest
@testable import Search

@MainActor
final class DeveloperSourcesNavigatorTests: XCTestCase {
    private typealias Frame = DeveloperToolsSession.ResourceFrame

    private func names(_ nodes: [SourceTreeNode], depth: Int = 0) -> [String] {
        nodes.flatMap { [String(repeating: "  ", count: depth) + $0.name] + names($0.children, depth: depth + 1) }
    }

    func testPageTreeGroupsByFrameOriginAndFolder() {
        let resources = [
            SourceResource(frame: "main", url: "https://example.com/", type: "Document"),
            SourceResource(frame: "main", url: "https://example.com/static/js/app.js?v=3", type: "Script"),
            SourceResource(frame: "main", url: "https://example.com/static/js/vendor.js", type: "Script"),
            SourceResource(frame: "main", url: "https://example.com/static/css/site.css", type: "Stylesheet"),
            SourceResource(frame: "main", url: "https://cdn.example.net/lib/deep/only/x.js", type: "Script"),
            SourceResource(frame: "ad", url: "https://ads.example.org/frame.html", type: "Document"),
        ]
        let frames = [
            Frame(id: "main", parent: nil, url: "https://example.com/", name: ""),
            Frame(id: "ad", parent: "main", url: "https://ads.example.org/frame.html", name: "banner"),
        ]
        XCTAssertEqual(names(SourceTree.build(resources, frames: frames)), [
            "top",
            "  cdn.example.net",
            "    lib/deep/only",
            "      x.js",
            "  example.com",
            "    static",
            "      css",
            "        site.css",
            "      js",
            "        app.js?v=3",
            "        vendor.js",
            "    (index)",
            "  banner",
            "    ads.example.org",
            "      frame.html",
        ])
    }

    func testCollapsedFoldersHideTheirRows() {
        let resources = [SourceResource(frame: "f", url: "https://a.com/js/x.js", type: "Script")]
        let nodes = SourceTree.build(resources, frames: [Frame(id: "f", parent: nil, url: "https://a.com/", name: "")])
        XCTAssertEqual(SourceTree.rows(nodes, collapsed: []).count, 4)
        let origin = nodes[0].children[0].id
        XCTAssertEqual(SourceTree.rows(nodes, collapsed: [origin]).map(\.node.name), ["top", "a.com"])
        XCTAssertEqual(SourceTree.origin(of: "data:text/javascript,1"), "(no domain)")
        XCTAssertEqual(SourceTree.origin(of: "http://localhost:8080/a.js"), "localhost:8080")
    }

    func testSnippetsAreNamedRenamedAndKept() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "DeveloperSourcesNavigatorTests"))
        defaults.removePersistentDomain(forName: "DeveloperSourcesNavigatorTests")
        let store = DeveloperSnippets(defaults: defaults)
        XCTAssertEqual(store.create().name, "Script snippet #1")
        XCTAssertEqual(store.create().name, "Script snippet #2")
        XCTAssertTrue(store.rename("Script snippet #1", to: "  hello  "))
        XCTAssertFalse(store.rename("hello", to: "Script snippet #2"), "two snippets can't share a name")
        XCTAssertFalse(store.rename("hello", to: " "))
        store.update("hello", text: "console.log(1)")
        XCTAssertEqual(store.create().name, "Script snippet #1")
        store.remove("Script snippet #2")

        let again = DeveloperSnippets(defaults: defaults)
        XCTAssertEqual(again.snippets.map(\.name), ["hello", "Script snippet #1"])
        XCTAssertEqual(again.snippet(named: "hello")?.text, "console.log(1)")
        defaults.removePersistentDomain(forName: "DeveloperSourcesNavigatorTests")
    }

    func testOutlineListsFunctionsClassesMethodsAndRules() {
        let js = """
        function load(url, options) { return fetch(url) }
        class Store extends Base {
            static create() {}
            async save(item) { await this.write(item) }
        }
        var api = { get: function(id) {}, put: async (id, value) => value };
        module.exports.handler = function* () {};
        if (ready) { start() }
        """
        XCTAssertEqual(SourceOutline.symbols(js, language: .js).map(\.name), [
            "load(url, options)", "class Store", "create()", "save(item)", "get(id)", "put(id, value)", "module.exports.handler()",
        ])
        let css = "/* top */ body{margin:0} @media (max-width:600px){ .a > b, .c{color:red} }"
        XCTAssertEqual(SourceOutline.symbols(css, language: .css).map(\.name), ["body", "@media (max-width:600px)", ".a > b, .c"])
    }

    func testQuickOpenMatchingPrefersNamesThatStartWithTheQuery() throws {
        let app = try XCTUnwrap(QuickOpenMatch.score("app", "app.js"))
        let mapper = try XCTUnwrap(QuickOpenMatch.score("app", "mapper.js"))
        XCTAssertGreaterThan(app, mapper)
        XCTAssertNotNil(QuickOpenMatch.score("vjs", "vendor.js"))
        XCTAssertNil(QuickOpenMatch.score("zzz", "vendor.js"))
    }

    func testStatusBarReadsAsChromes() {
        var position = SourceTextView.Position(line: 3, column: 7)
        XCTAssertEqual(DeveloperSourcePane.positionText(position), "Line 3, Column 7")
        position.selected = 12
        position.selectedLines = 1
        XCTAssertEqual(DeveloperSourcePane.positionText(position), "12 characters selected")
        position.selected = 40
        position.selectedLines = 2
        XCTAssertEqual(DeveloperSourcePane.positionText(position), "2 lines, 40 characters selected")
    }
}
