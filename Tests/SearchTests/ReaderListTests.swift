import AppKit
import WebKit
import XCTest
@testable import Search

@MainActor
final class ReaderListTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
    }

    // Tailwind's reset takes list-style, margin and padding off every list,
    // and the site's stylesheets still apply under reading mode.
    func testListsKeepTheirMarkersUnderASiteReset() async throws {
        let sentence = "The reader keeps the words and sets aside what was arranged around them. "
        let paragraph = "<p>" + String(repeating: sentence, count: 6) + "</p>"
        let html = """
        <!doctype html><html><head><style>
        ol, ul { list-style: none; margin: 0; padding: 0 }
        </style></head><body><article>
        \(String(repeating: paragraph, count: 4))
        <ol><li>one<ul><li>inner</li></ul></li><li>two</li></ol>
        <ul><li>a bullet</li></ul>
        </article></body></html>
        """

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        let loaded = Loaded()
        web.navigationDelegate = loaded
        try await withCheckedThrowingContinuation { continuation in
            loaded.continuation = continuation
            web.loadHTMLString(html, baseURL: URL(string: "https://example.test/"))
        }

        let result = try await web.evaluateJavaScript(Reader.script) as? String
        XCTAssertEqual(result, "read")

        func style(_ selector: String, _ property: String) async throws -> String? {
            try await web.evaluateJavaScript(
                "getComputedStyle(document.querySelector('#office-reader').querySelector('\(selector)')).\(property)"
            ) as? String
        }
        let ordered = try await style(":scope > ol", "listStyleType")
        let bullets = try await style(":scope > ul", "listStyleType")
        let nested = try await style("ol ul", "listStyleType")
        let indent = try await style(":scope > ol", "paddingLeft")
        XCTAssertEqual(ordered, "decimal")
        XCTAssertEqual(bullets, "disc")
        XCTAssertEqual(nested, "circle")
        XCTAssertNotEqual(indent, "0px")
    }
}

private final class Loaded: NSObject, WKNavigationDelegate {
    var continuation: CheckedContinuation<Void, Error>?

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume()
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
