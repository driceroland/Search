import AppKit
import WebKit
import XCTest
@testable import Search

@MainActor
final class GmailRenderingTests: XCTestCase {
    func testStyleAppliesToDynamicGmailIconWithoutChangingPageAppearance() async throws {
        XCTAssertEqual(GmailRendering.userScript.injectionTime, .atDocumentStart)
        XCTAssertTrue(GmailRendering.userScript.isForMainFrameOnly)

        let webView = WKWebView(frame: .zero, configuration: configuration())
        webView.appearance = NSAppearance(named: .darkAqua)
        let loaded = expectation(description: "Gmail document loaded")
        let delegate = NavigationDelegate(loaded: loaded)
        webView.navigationDelegate = delegate
        webView.loadHTMLString("""
            <!doctype html>
            <html><head>
              <meta name="color-scheme" content="light">
              <style>
                :root { color-scheme: light; }
                @media (prefers-color-scheme: dark) { #scheme { color: rgb(2, 3, 4); } }
                @media (prefers-color-scheme: light) { #scheme { color: rgb(9, 8, 7); } }
              </style>
            </head><body>
              <div id="gb"></div>
              <div id="outside"></div>
              <div id="scheme"></div>
            </body></html>
            """, baseURL: try XCTUnwrap(URL(string: "https://mail.google.com/")))
        await fulfillment(of: [loaded], timeout: 5)

        let result = try await webView.evaluateJavaScript("""
            (() => {
              const icon = document.createElement('div');
              icon.className = 'HFMVod';
              icon.id = 'dynamic-icon';
              document.querySelector('#gb').append(icon);
              const outside = document.createElement('div');
              outside.className = 'HFMVod';
              document.querySelector('#outside').append(outside);

              return {
                styleCount: document.querySelectorAll('#search-gmail-rendering').length,
                iconTransform: getComputedStyle(icon).transform,
                outsideTransform: getComputedStyle(outside).transform,
                prefersDark: matchMedia('(prefers-color-scheme: dark)').matches,
                colorScheme: getComputedStyle(document.documentElement).colorScheme,
                schemeColor: getComputedStyle(document.querySelector('#scheme')).color
              };
            })()
            """)
        let values = try XCTUnwrap(result as? [String: Any])

        XCTAssertEqual(values["styleCount"] as? Int, 1)
        XCTAssertNotEqual(try XCTUnwrap(values["iconTransform"] as? String), "none")
        XCTAssertEqual(values["outsideTransform"] as? String, "none")

        let prefersDark = try XCTUnwrap(values["prefersDark"] as? Bool)
        XCTAssertTrue(prefersDark, "the WKWebView keeps macOS dark appearance")
        XCTAssertEqual(values["colorScheme"] as? String, "light", "Gmail's explicit light page scheme stays in place")
        XCTAssertEqual(values["schemeColor"] as? String, "rgb(2, 3, 4)", "the page still sees the dark system preference")

        _ = try await webView.evaluateJavaScript(GmailRendering.script)
        let styleCount = try await webView.evaluateJavaScript("document.querySelectorAll('#search-gmail-rendering').length") as? Int
        XCTAssertEqual(styleCount, 1, "injecting the rule twice should leave one style element")
    }

    func testStyleIsLimitedToSecureExactGmailHost() async throws {
        let cases: [(String, Int)] = [
            ("https://mail.google.com/", 1),
            ("http://mail.google.com/", 0),
            ("https://www.mail.google.com/", 0),
            ("https://mail.google.com.example.test/", 0)
        ]

        for (address, expectedStyleCount) in cases {
            let webView = WKWebView(frame: .zero, configuration: configuration())
            let loaded = expectation(description: "Document loaded at \(address)")
            let delegate = NavigationDelegate(loaded: loaded)
            webView.navigationDelegate = delegate
            webView.loadHTMLString("<!doctype html><html><head></head><body></body></html>",
                                   baseURL: try XCTUnwrap(URL(string: address)))
            await fulfillment(of: [loaded], timeout: 5)

            let count = try await webView.evaluateJavaScript("document.querySelectorAll('#search-gmail-rendering').length") as? Int
            XCTAssertEqual(count, expectedStyleCount, address)
        }
    }

    private func configuration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addUserScript(GmailRendering.userScript)
        return configuration
    }
}

@MainActor
private final class NavigationDelegate: NSObject, WKNavigationDelegate {
    private let loaded: XCTestExpectation

    init(loaded: XCTestExpectation) {
        self.loaded = loaded
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded.fulfill()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        XCTFail("WebKit failed to load the test document: \(error)")
        loaded.fulfill()
    }
}
