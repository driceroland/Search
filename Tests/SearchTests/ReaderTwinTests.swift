import AppKit
import Foundation
import WebKit
import XCTest
@testable import Search

/// Reader.twin and Reader.show run in a real web view against pages on a
/// local http address: where a twin is found, and where it isn't.
@MainActor
final class ReaderTwinTests: XCTestCase {
    private var server: LocalPageServer!

    private static let markdown = "text/markdown; charset=utf-8"
    private static let html = "text/html; charset=utf-8"
    private static let article = "<article>" + String(repeating: "<p>" + String(repeating: "Words to read here. ", count: 20) + "</p>", count: 4) + "</article>"

    /// A site's styles of the kind that reached the reading page, beside one
    /// of Search's own (Curtain's, see Curtain.swift).
    private static let theirStyles = """
    <link rel="stylesheet" href="/page.css">
    <style>ol { list-style: none } body { font-family: Papyrus }
    .sr-only { position: absolute; width: 1px; height: 1px; overflow: hidden; clip: rect(0 0 0 0) }
    .mobile { display: none }</style>
    <style id="office-veil">.cookie-bar { display: none !important }</style>
    """

    private static let styledArticle = "<article>"
        + String(repeating: "<p style=\"color: white\">" + String(repeating: "Words to read here. ", count: 20) + "</p>", count: 4)
        + "<p>Steps <span class=\"sr-only\">for screen readers</span> to follow.</p>"
        + "<table class=\"mobile\"><tr><td>Mobile copy</td></tr></table>"
        + "<ol><li>one</li><li>two</li></ol>"
        + "<picture><source srcset=\"/a.webp\" type=\"image/webp\"><img src=\"/a.png\" alt=\"A\"></picture>"
        + "</article>"

    private static func page(_ head: String = "", body: String = "<h1>The page</h1>") -> LocalPageServer.Page {
        .init(type: html, body: "<!doctype html><html><head><title>Page title</title>\(head)</head><body>\(body)</body></html>")
    }

    override func setUp() async throws {
        try await super.setUp()
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        server = try LocalPageServer([
            "/declared": Self.page("<link rel=\"alternate\" type=\"text/markdown\" href=\"/notes/declared.md\">"),
            "/notes/declared.md": .init(type: Self.markdown, body: "# Declared\n\nFrom the link."),
            "/plain-named": Self.page("<link rel=\"Alternate\" type=\"text/markdown\" href=\"/plain-named.txt\">"),
            "/plain-named.txt": .init(type: "text/plain", body: "# Named\n\nServed as plain text."),
            "/guide": Self.page(),
            "/guide.md": .init(type: Self.markdown, body: "---\ntitle: Guide\n---\n\n## Step one\n\nDo [this](next)."),
            "/folder/": Self.page(),
            "/folder/index.html.md": .init(type: Self.markdown, body: "# Folder"),
            "/spa": Self.page(body: Self.article),
            "/spa.md": Self.page(body: "<p>Every address is the app</p>"),
            "/text": Self.page(),
            "/text.md": .init(type: "text/plain", body: "# Not vouched for"),
            "/nothing": Self.page(body: Self.article),
            "/README.md": .init(type: Self.markdown, body: "# Read me\n\n- one\n- two"),
            "/styled": Self.page(Self.theirStyles, body: Self.styledArticle),
            "/styled-twin": Self.page(Self.theirStyles + "<link rel=\"alternate\" type=\"text/markdown\" href=\"/styled-twin.md\">"),
            "/styled-twin.md": .init(type: Self.markdown, body: "# Twin\n\n1. one\n2. two"),
            "/page.css": .init(type: "text/css", body: "#office-reader li { list-style: none; color: rgb(255, 0, 0); }"),
        ])
    }

    override func tearDown() async throws {
        server.stop()
        server = nil
        try await super.tearDown()
    }

    // MARK: - finding

    func testDeclaredTwinIsReadFromWhereThePageSays() async throws {
        let twin = try await find("/declared")
        XCTAssertEqual(twin?["url"] as? String, server.url("/notes/declared.md").absoluteString)
        XCTAssertEqual(twin?["text"] as? String, "# Declared\n\nFrom the link.")
        XCTAssertEqual(twin?["title"] as? String, "The page")
        XCTAssertEqual(twin?["from"] as? String, "127.0.0.1:\(server.port)")
        XCTAssertFalse(server.requests.contains("/declared.md"), "a named twin needs no guessing")
    }

    func testDeclaredTwinMayBePlainText() async throws {
        let twin = try await find("/plain-named")
        XCTAssertEqual(twin?["text"] as? String, "# Named\n\nServed as plain text.")
    }

    /// Only the page's own site is asked: a twin it names on another one
    /// is never fetched, and the guess at its own address is read instead.
    func testATwinNamedOnAnotherSiteIsNeverAsked() async throws {
        let elsewhere = try LocalPageServer([
            "/twin.md": .init(type: Self.markdown, body: "# Elsewhere"),
        ])
        defer { elsewhere.stop() }
        let web = try await open("/guide")
        _ = try await call(web, """
        var link = document.createElement('link');
        link.rel = 'alternate'; link.type = 'text/markdown'; link.href = address;
        document.head.appendChild(link);
        """, ["address": elsewhere.url("/twin.md").absoluteString])
        let twin = try await call(web, Reader.twin) as? [String: Any]
        XCTAssertEqual(twin?["url"] as? String, server.url("/guide.md").absoluteString)
        XCTAssertEqual(elsewhere.requests, [], "another site is never asked")
    }

    func testTwinAtTheSameAddressWithMdOnTheEnd() async throws {
        let twin = try await find("/guide")
        XCTAssertEqual(twin?["url"] as? String, server.url("/guide.md").absoluteString)
    }

    func testFolderAddressLooksForIndexHtmlMd() async throws {
        let twin = try await find("/folder/")
        XCTAssertEqual(twin?["text"] as? String, "# Folder")
    }

    func testAnAnswerThatIsNotMarkdownIsNoTwin() async throws {
        let spa = try await find("/spa")
        XCTAssertNil(spa)
        // Plain text at a guessed address could be anything.
        let text = try await find("/text")
        XCTAssertNil(text)
    }

    func testNotFoundIsNoTwin() async throws {
        let twin = try await find("/nothing")
        XCTAssertNil(twin)
        XCTAssertTrue(server.requests.contains("/nothing.md"))
    }

    func testAMarkdownPageIsItsOwnTwin() async throws {
        let twin = try await find("/README.md")
        XCTAssertEqual(twin?["text"] as? String, "# Read me\n\n- one\n- two")
        XCTAssertEqual(server.requests.filter { $0.hasPrefix("/README") }, ["/README.md"], "nothing else is asked for")
    }

    // MARK: - drawing

    func testTwinIsDrawnInTheReadingPage() async throws {
        let web = try await open("/guide")
        let lookup = try await call(web, Reader.twin)
        let found = try XCTUnwrap(lookup as? [String: Any])
        let text = try XCTUnwrap(found["text"] as? String)
        let address = try XCTUnwrap((found["url"] as? String).flatMap(URL.init(string:)))
        let twin = Markdown.page(text, base: address)
        let answer = try await call(web, Reader.show, [
            "html": twin.html, "title": twin.title ?? "", "from": "fixture · markdown", "sheet": Reader.sheet,
        ])
        XCTAssertEqual(answer as? String, "read")

        let drawn = try await call(web, """
        var reader = document.getElementById('office-reader');
        return {
          title: reader.querySelector('h1').textContent,
          from: reader.querySelector('.office-from').textContent,
          heading: reader.querySelector('h2').id,
          link: reader.querySelector('a').href,
          styled: getComputedStyle(reader).maxWidth
        };
        """) as? [String: Any]
        XCTAssertEqual(drawn?["title"] as? String, "Guide")
        XCTAssertEqual(drawn?["from"] as? String, "fixture · markdown")
        XCTAssertEqual(drawn?["heading"] as? String, "step-one")
        XCTAssertEqual(drawn?["link"] as? String, server.url("/next").absoluteString)
        XCTAssertNotEqual(drawn?["styled"] as? String, "none")
    }

    func testTheGuessStillReadsAPageWithoutATwin() async throws {
        let web = try await open("/nothing")
        let answer = try await call(web, Reader.script, ["sheet": Reader.sheet], world: .page)
        XCTAssertEqual(answer as? String, "read")
        let title = try await call(web, "return document.querySelector('#office-reader h1').textContent;")
        XCTAssertEqual(title as? String, "Page title")
    }

    // MARK: - the page's own styles

    func testTheGuessLeavesThePageStylesBehind() async throws {
        let web = try await open("/styled")
        let answer = try await call(web, Reader.script, ["sheet": Reader.sheet], world: .page)
        XCTAssertEqual(answer as? String, "read")
        let left = try await call(web, Self.inspect) as? [String: Any]
        XCTAssertEqual(left?["sheets"] as? [String], ["office-veil", "office-reader-sheet"])
        XCTAssertEqual(left?["listStyle"] as? String, "decimal")
        XCTAssertEqual(left?["listColour"] as? String, "rgb(23, 23, 23)")
        XCTAssertFalse((left?["font"] as? String ?? "").contains("Papyrus"))
        let text = try XCTUnwrap(left?["text"] as? String)
        XCTAssertTrue(text.contains("Steps  to follow."))
        XCTAssertFalse(text.contains("for screen readers"))
        XCTAssertFalse(text.contains("Mobile copy"))
        XCTAssertEqual(left?["inline"] as? Int, 0)
        XCTAssertEqual(left?["sources"] as? Int, 1, "a picture's sources are WebKit's to hide")
    }

    func testTheTwinLeavesThePageStylesBehind() async throws {
        let web = try await open("/styled-twin")
        let lookup = try await call(web, Reader.twin)
        let found = try XCTUnwrap(lookup as? [String: Any])
        let twin = Markdown.page(try XCTUnwrap(found["text"] as? String), base: nil)
        _ = try await call(web, Reader.show, [
            "html": twin.html, "title": twin.title ?? "", "from": "fixture", "sheet": Reader.sheet,
        ])
        let left = try await call(web, Self.inspect) as? [String: Any]
        XCTAssertEqual(left?["sheets"] as? [String], ["office-veil", "office-reader-sheet"])
        XCTAssertEqual(left?["listStyle"] as? String, "decimal")
    }

    private static let inspect = """
    var reader = document.getElementById('office-reader');
    var item = reader.querySelector('li');
    var sheets = [];
    document.querySelectorAll('style, link[rel~="stylesheet"]').forEach(function (s) { sheets.push(s.id || s.tagName); });
    return {
      sheets: sheets,
      listStyle: getComputedStyle(item).listStyleType,
      listColour: getComputedStyle(item).color,
      font: getComputedStyle(document.body).fontFamily,
      text: reader.textContent,
      inline: reader.querySelectorAll('[style]').length,
      sources: reader.querySelectorAll('picture source').length
    };
    """

    // MARK: - plumbing

    private func find(_ path: String) async throws -> [String: Any]? {
        let web = try await open(path)
        return try await call(web, Reader.twin) as? [String: Any]
    }

    private var holding: [Loaded] = []

    private func open(_ path: String) async throws -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        let loaded = Loaded()
        holding.append(loaded)
        web.navigationDelegate = loaded
        web.load(URLRequest(url: server.url(path)))
        try await loaded.wait()
        return web
    }

    private func call(_ web: WKWebView, _ body: String, _ arguments: [String: Any] = [:],
                      world: WKContentWorld? = nil) async throws -> Any? {
        let world = world ?? Web.world
        return try await withCheckedThrowingContinuation { continuation in
            web.callAsyncJavaScript(body, arguments: arguments, in: nil, in: world) { (result: Result<Any, Error>) in
                continuation.resume(with: result.map { $0 is NSNull ? nil : $0 })
            }
        }
    }

    private final class Loaded: NSObject, WKNavigationDelegate {
        private var continuation: CheckedContinuation<Void, Error>?
        private var done = false

        func wait() async throws {
            if done { return }
            try await withCheckedThrowingContinuation { self.continuation = $0 }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            done = true
            continuation?.resume()
            continuation = nil
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            done = true
            continuation?.resume(throwing: error)
            continuation = nil
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            done = true
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }
}
