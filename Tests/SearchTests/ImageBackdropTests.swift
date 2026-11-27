import AppKit
import WebKit
import XCTest
@testable import Search

/// A picture opened on its own sits on neutral dark grey, a page with
/// pictures in it keeps its own background. An unshown web view, no window.
@MainActor
final class ImageBackdropTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("image-backdrop-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func background(of file: URL) async throws -> String {
        let config = WKWebViewConfiguration()
        config.userContentController.addUserScript(
            WKUserScript(source: ImageBackdrop.script, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 300, height: 300), configuration: config)
        let loaded = expectation(description: "loaded")
        let delegate = Done { loaded.fulfill() }
        web.navigationDelegate = delegate
        web.loadFileURL(file, allowingReadAccessTo: dir)
        await fulfillment(of: [loaded], timeout: 20)
        withExtendedLifetime(delegate) {}
        return try await web.evaluateJavaScript("getComputedStyle(document.documentElement).backgroundColor") as? String ?? ""
    }

    private final class Done: NSObject, WKNavigationDelegate {
        let done: () -> Void
        init(_ done: @escaping () -> Void) { self.done = done }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done() }
    }

    func testPictureOnItsOwnIsGrey() async throws {
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
        let file = dir.appendingPathComponent("p.png")
        try png.write(to: file)
        let bg = try await background(of: file)
        XCTAssertEqual(bg, "rgb(28, 28, 30)")
    }

    func testPageWithPicturesKeepsItsOwn() async throws {
        let file = dir.appendingPathComponent("p.html")
        try "<html><body><p>hi</p></body></html>".write(to: file, atomically: true, encoding: .utf8)
        let bg = try await background(of: file)
        XCTAssertNotEqual(bg, "rgb(28, 28, 30)")
    }
}
