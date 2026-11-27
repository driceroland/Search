import Foundation
import XCTest
@testable import Search

/// What an extension's own script refused by a page's policy may be
/// (ExtensionPageScript): which path, for which page, and what runs.
@available(macOS 15.4, *)
@available(macOS 14, *)
final class ExtensionPageScriptTests: XCTestCase {
    private let page = URL(string: "https://www.youtube.com/watch?v=1")!
    private let manifest: [String: Any] = [
        "web_accessible_resources": [
            ["resources": ["page.js", "scripts/*.js"], "matches": ["https://www.youtube.com/*"]],
            ["resources": ["other.js"], "matches": ["https://example.com/*"]],
        ],
        "content_scripts": [["matches": ["https://www.youtube.com/*"], "exclude_matches": ["https://www.youtube.com/embed/*"], "js": ["c.js"]]],
    ]

    func testPathsAreDecodedAndPlain() {
        XCTAssertEqual(ExtensionPageScript.normalized("/page.js"), "page.js")
        XCTAssertEqual(ExtensionPageScript.normalized("/%70age.js"), "page.js", "matched as decoded")
        XCTAssertEqual(ExtensionPageScript.normalized("/scripts/a.js"), "scripts/a.js")
        for bad in ["/../page.js", "/scripts/../page.js", "/./page.js", "/scripts//a.js", "/%2e%2e/page.js", "/a%00.js", "/a\\b.js", "/"] {
            XCTAssertNil(ExtensionPageScript.normalized(bad), bad)
        }
    }

    func testWebAccessibleForThatPage() {
        let ok = { (path: String) in ExtensionPageScript.normalized(path).map { ExtensionPageScript.accessible($0, to: self.page, manifest: self.manifest) } ?? false }
        XCTAssertTrue(ok("/page.js"))
        XCTAssertTrue(ok("/%70age.js"))
        XCTAssertTrue(ok("/scripts/x.js"))
        XCTAssertFalse(ok("/other.js"), "web-accessible to another site only")
        XCTAssertFalse(ok("/hidden.js"))
        XCTAssertFalse(ok("/scripts/../hidden.js"))
    }

    func testMayScriptThatPage() {
        XCTAssertTrue(ExtensionPageScript.mayScript(page, manifest: manifest, hasScripting: false), "a content script for the page")
        XCTAssertFalse(ExtensionPageScript.mayScript(URL(string: "https://www.youtube.com/embed/1")!, manifest: manifest, hasScripting: false), "excluded")
        XCTAssertFalse(ExtensionPageScript.mayScript(URL(string: "https://example.com/")!, manifest: manifest, hasScripting: false))
        XCTAssertTrue(ExtensionPageScript.mayScript(URL(string: "https://example.com/")!, manifest: manifest, hasScripting: true))
    }

    /// One evaluation: the check on the document first, then the element,
    /// then the file; a strict file stays strict.
    func testEvaluation() {
        let token = String(repeating: "a", count: 32)
        let plain = ExtensionPageScript.evaluation(source: "var x = 1;", expected: "https://www.youtube.com/watch?v=1", token: token)
        XCTAssertTrue(plain.hasPrefix("(() => {\n  if (location.origin + location.pathname + location.search !== \"https://www.youtube.com/watch?v=1\") throw \""), plain)
        XCTAssertTrue(plain.contains("queueMicrotask"))
        XCTAssertTrue(plain.hasSuffix("var x = 1;\n;void 0"))
        let strict = ExtensionPageScript.evaluation(source: "/* hi */\n'use strict'; var y;", expected: "https://a.b/", token: token)
        XCTAssertTrue(strict.hasPrefix("\"use strict\";(() => {"), strict)
        let quoted = ExtensionPageScript.evaluation(source: "", expected: "https://a.b/?q=\"</script>\\", token: token)
        XCTAssertTrue(quoted.contains(#"!== "https://a.b/?q=\"</script>\\")"#), quoted)
    }

    /// The address the evaluation checks, as location reads it.
    func testPageAddress() {
        let a = { (s: String) in ExtensionPageScript.pageAddress(URL(string: s)!) }
        XCTAssertEqual(a("https://www.youtube.com/watch?v=1#t=3"), "https://www.youtube.com/watch?v=1")
        XCTAssertEqual(a("HTTPS://WWW.Example.com"), "https://www.example.com/")
        XCTAssertEqual(a("http://127.0.0.1:8080/a%20b?x=%41"), "http://127.0.0.1:8080/a%20b?x=%41")
        XCTAssertEqual(a("https://a.example:443/p?"), "https://a.example/p")
        XCTAssertNil(a("file:///etc/hosts"))
    }
}
