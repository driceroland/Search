import AppKit
import WebKit
import XCTest
@testable import Search

@available(macOS 15.4, *)
@MainActor
final class ExtensionSiteGrantTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "site-grants-\(getpid())", 1)
        super.setUp()
    }

    private func fixture(_ patterns: [String]) async throws -> (URL, WKWebExtension) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("site-grants-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "manifest_version": 3, "name": "Site grants", "version": "1",
            "host_permissions": patterns,
            "content_scripts": [["matches": patterns.filter { !$0.hasPrefix("file:") }, "js": ["content.js"]]],
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("manifest.json"))
        try Data("document.documentElement.dataset.injected = 'yes';".utf8).write(to: folder.appendingPathComponent("content.js"))
        return (folder, try await WKWebExtension(resourceBaseURL: folder))
    }

    func testWildcardRemovesCoveredGrantsWithoutChangingSiteAccess() async throws {
        let (folder, ext) = try await fixture([
            "https://*.example.com/*", "https://example.com/*", "https://news.example.com/*",
            "http://example.com/*", "https://other.example/*", "file:///*",
        ])
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = WKWebExtensionContext(for: ext)
        for pattern in ext.allRequestedMatchPatterns where !Extensions.withheld(pattern) {
            original.setPermissionStatus(.grantedExplicitly, for: pattern)
        }
        Extensions.fence(original)
        let compact = WKWebExtensionContext(for: ext)
        Extensions.grantSites(compact)
        Extensions.fence(compact)
        XCTAssertEqual(Set(compact.grantedPermissionMatchPatterns.keys.map(\.string)), [
            "https://*.example.com/*", "http://example.com/*", "https://other.example/*",
        ])
        for text in ["https://example.com/", "https://news.example.com/article", "https://deep.news.example.com/",
                     "http://example.com/", "http://news.example.com/", "https://other.example/",
                     "https://notexample.com/", "https://example.com.evil.invalid/", "https://unrelated.invalid/", "file:///tmp/example"] {
            let url = try XCTUnwrap(URL(string: text))
            XCTAssertEqual(compact.hasAccess(to: url), original.hasAccess(to: url), text)
        }
        let named = try WKWebExtension.MatchPattern(string: "https://news.example.com/*")
        XCTAssertTrue(compact.hasAccess(to: URL(string: "https://news.example.com/article")!))
        let browser = Browser(record: WindowRecord())
        Browsers.register(browser)
        defer { browser.closeAll() }
        Extensions.clicked[compact.uniqueIdentifier] = Date()
        let reply = try await ExtensionShims.answer([
            "api": "permissions.afterClick", "args": [[], [named.string]],
        ], from: compact, owner: Extensions.shared) as? [String: Any]
        XCTAssertEqual(reply?["value"] as? Bool, true, "an existing wildcard grant must not ask again: \(String(describing: reply))")
        XCTAssertEqual(compact.grantedPermissionMatchPatterns.count, 3)
        Extensions.clicked[compact.uniqueIdentifier] = Date()
        let refused = try await ExtensionShims.answer([
            "api": "permissions.afterClick", "args": [[], ["https://unrelated.invalid/*"]],
        ], from: compact, owner: Extensions.shared) as? [String: Any]
        XCTAssertNotNil(refused?["error"])
        XCTAssertFalse(compact.hasAccess(to: URL(string: "https://unrelated.invalid/")!))
        compact.setPermissionStatus(.deniedExplicitly, for: try WKWebExtension.MatchPattern(string: "https://*.news.example.com/*"))
        let previousAnswer = Extensions.shared.answerForTests
        Extensions.shared.answerForTests = false
        defer { Extensions.shared.answerForTests = previousAnswer }
        Extensions.clicked[compact.uniqueIdentifier] = Date()
        let denied = try await ExtensionShims.answer([
            "api": "permissions.afterClick", "args": [[], [named.string]],
        ], from: compact, owner: Extensions.shared) as? [String: Any]
        XCTAssertEqual(denied?["value"] as? Bool, false, "a denied subdomain must not inherit approval")
        XCTAssertFalse(compact.hasAccess(to: URL(string: "https://news.example.com/article")!))
    }

    func testDifferentPathsAndSchemesAreKept() async throws {
        let patterns = ["https://*.example.com/one/*", "https://example.com/two/*", "http://example.com/one/*"]
        let (folder, ext) = try await fixture(patterns)
        defer { try? FileManager.default.removeItem(at: folder) }
        let context = WKWebExtensionContext(for: ext)
        Extensions.grantSites(context)
        XCTAssertEqual(Set(context.grantedPermissionMatchPatterns.keys.map(\.string)), Set(patterns))
    }

    func testContentStillInjectsOnlyOnAllowedSites() async throws {
        _ = NSApplication.shared
        let (folder, ext) = try await fixture(["https://*.example.com/*", "https://example.com/*"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let controller = WKWebExtensionController(configuration: .nonPersistent())
        let context = WKWebExtensionContext(for: ext)
        Extensions.grantSites(context)
        Extensions.fence(context)
        context.hasAccessToPrivateData = true
        try controller.load(context)
        defer { try? controller.unload(context) }
        for host in ["example.com", "sub.example.com", "example.com.evil.invalid"] {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            config.webExtensionController = controller
            let web = WKWebView(frame: .zero, configuration: config)
            web.loadHTMLString("<html><body>fixture</body></html>", baseURL: URL(string: "https://\(host)/"))
            for _ in 0..<100 {
                if !web.isLoading, (try? await web.evaluateJavaScript("document.readyState")) as? String == "complete" { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            let injected = try await web.evaluateJavaScript("document.documentElement.dataset.injected || ''") as? String
            XCTAssertEqual(injected, host.hasSuffix(".invalid") ? "" : "yes", host)
            web.stopLoading()
        }
    }
}
