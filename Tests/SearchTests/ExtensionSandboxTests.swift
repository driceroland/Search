import Foundation
import XCTest
@testable import Search

/// What ExtensionSandbox serves, to whom, and which extensions may have eval
/// left to each frame's policy. Eval in the frames themselves is
/// Tests/extension_sandbox_pages.py.
@available(macOS 15.4, *)
@MainActor
@available(macOS 14, *)
final class ExtensionSandboxTests: XCTestCase {
    private var root: URL!
    private var sandbox: ExtensionSandbox!
    private let page = URL(string: "chrome-extension://abc/page.html")

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("sandbox-tests-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("abc", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("lib"), withIntermediateDirectories: true)
        try #"<script src="/search-shim.js"></script><title>sb</title>"#.write(to: folder.appendingPathComponent("sb.html"), atomically: true, encoding: .utf8)
        try "<title>page</title>".write(to: folder.appendingPathComponent("page.html"), atomically: true, encoding: .utf8)
        try "eval('1')".write(to: folder.appendingPathComponent("lib/run.js"), atomically: true, encoding: .utf8)
        try "secret".write(to: root.appendingPathComponent("outside.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("link.txt"), withDestinationURL: root.appendingPathComponent("outside.txt"))
        sandbox = ExtensionSandbox(id: "abc", folder: folder, pages: ["sb.html"])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func served(_ address: String, for document: URL?) -> (HTTPURLResponse, Data)? {
        URL(string: address).flatMap { sandbox.serve($0, for: document) }
    }

    func testItsSandboxPageAndFilesAreServedWithChromesPolicy() throws {
        let (html, body) = try XCTUnwrap(served("chrome-extension-sandbox://abc/sb.html?role=x", for: page))
        XCTAssertEqual(html.value(forHTTPHeaderField: "Content-Security-Policy"), ExtensionSandbox.policy)
        XCTAssertEqual(html.value(forHTTPHeaderField: "Content-Type"), "text/html", "its own <meta charset> decides")
        XCTAssertEqual(String(decoding: body, as: UTF8.self), "<title>sb</title>", "without Search's shim")
        let (script, _) = try XCTUnwrap(served("chrome-extension-sandbox://abc/lib/run.js", for: page))
        XCTAssertEqual(script.value(forHTTPHeaderField: "Content-Type"), "text/javascript; charset=utf-8")
        XCTAssertEqual(script.value(forHTTPHeaderField: "Content-Security-Policy"), ExtensionSandbox.policy)
    }

    func testNothingElseIsServed() {
        XCTAssertNil(served("chrome-extension-sandbox://abc/page.html", for: page), "a page the manifest doesn't list")
        XCTAssertNil(served("chrome-extension-sandbox://abc/sb.html", for: URL(string: "chrome-extension://other/page.html")), "another extension's page")
        XCTAssertNil(served("chrome-extension-sandbox://abc/sb.html", for: URL(string: "https://example.com/")), "a website")
        XCTAssertNil(served("chrome-extension-sandbox://abc/sb.html", for: nil))
        XCTAssertNil(served("chrome-extension-sandbox://other/sb.html", for: URL(string: "chrome-extension://other/page.html")), "another extension's files")
        XCTAssertNil(served("chrome-extension://abc/sb.html", for: page))
        for way in ["/../outside.txt", "/%2e%2e/outside.txt", "/lib/../../outside.txt", "/link.txt", "/missing.js"] {
            XCTAssertNil(served("chrome-extension-sandbox://abc" + way, for: page), way)
        }
    }

    func testSandboxPagesAreReadAsPathsInThePackage() {
        XCTAssertEqual(ExtensionSandbox.sandboxPages(["sandbox": ["pages": ["/sb.html", "a/b.html", ""]]]), ["sb.html", "a/b.html"])
        XCTAssertNil(ExtensionSandbox.sandboxPages(["name": "x"]))
        XCTAssertNil(ExtensionSandbox.sandboxPages(["sandbox": ["pages": "sb.html"]]), "a list, as Chrome takes it")
    }

    func testEvalIsLeftToFramesOnlyWhereTheExtensionsOwnPagesStayStrict() {
        let may = { (csp: Any?, version: Int) -> Bool in
            var manifest: [String: Any] = ["manifest_version": version]
            if let csp { manifest["content_security_policy"] = csp }
            return ExtensionSandbox.mayLeaveEvalToFrames(manifest)
        }
        XCTAssertTrue(may(nil, 3), "WebKit's own policy")
        XCTAssertTrue(may(["sandbox": "sandbox allow-scripts; script-src 'self' 'unsafe-eval'"], 3), "the sandbox's own is for its frames")
        XCTAssertTrue(may(["extension_pages": "script-src 'self'; object-src 'self'"], 3), "Zotero Connector's")
        XCTAssertTrue(may(["extension_pages": "script-src 'self' 'wasm-unsafe-eval'; img-src https:"], 3))
        for loose in [
            "script-src 'self' 'unsafe-eval'",
            "script-src 'self' 'unsafe-inline'",
            "script-src 'self' https://cdn.example.com",
            "script-src 'self'; script-src-elem 'self' https://cdn.example.com",
            "script-src 'self'; script-src-attr 'unsafe-inline'",
            "script-src 'self'; worker-src https:",
            "script-src 'self'; object-src *",
            "img-src *, script-src 'self' 'unsafe-eval'",
            "default-src *",
        ] {
            XCTAssertFalse(may(["extension_pages": loose], 3), loose)
        }
        XCTAssertFalse(may("script-src 'self'", 3), "one string, as Manifest V2 writes it")
        XCTAssertFalse(may(nil, 2), "Manifest V2 has a mode of its own")
    }
}
