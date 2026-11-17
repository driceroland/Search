import WebKit
import XCTest
@testable import Search

@MainActor
final class ShieldTests: XCTestCase {
    func testRepeatedLaunchesCanUseTheSameStore() async throws {
        let folder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/shield-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try XCTUnwrap(WKContentRuleListStore(url: folder))
        var times: [TimeInterval] = []
        var identifiers: [String] = []
        for _ in 0..<4 {
            let shield = Shield(store: store)
            let start = Date()
            shield.compile()
            while shield.list == nil && shield.trouble == nil && Date().timeIntervalSince(start) < 90 {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertNil(shield.trouble)
            let list = try XCTUnwrap(shield.list)
            identifiers.append(list.identifier)
            times.append(Date().timeIntervalSince(start))
        }
        print("Shield launch seconds (first, then three repeats): \(times)")
        XCTAssertTrue(identifiers[0].hasPrefix("office-shield-"))
        XCTAssertEqual(Set(identifiers).count, 1)
    }

    func testCachedListProtectsWaitingTabsAndLeavesOtherListsAlone() async throws {
        let folder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/shield-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try XCTUnwrap(WKContentRuleListStore(url: folder))
        let first = Shield(store: store)
        first.compile()
        try await waitForList(first)
        let identifier = try XCTUnwrap(first.list?.identifier)

        // A recognizable list in the store proves the next Shield uses the
        // saved list, instead of compiling its own under the same name.
        let marker = ##"[{"trigger":{"url-filter":".*"},"action":{"type":"css-display-none","selector":"#marker"}}]"##
        _ = try await store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: marker)
        _ = try await store.compileContentRuleList(forIdentifier: "office-shield-old", encodedContentRuleList: marker)
        _ = try await store.compileContentRuleList(forIdentifier: "office-shield", encodedContentRuleList: marker)
        _ = try await store.compileContentRuleList(forIdentifier: "unrelated", encodedContentRuleList: marker)

        let shield = Shield(store: store)
        let controller = WKUserContentController()
        shield.protect(controller)
        shield.compile()
        shield.compile()
        try await waitForList(shield)
        let config = WKWebViewConfiguration()
        config.userContentController = controller
        let web = WKWebView(frame: .zero, configuration: config)
        var display = try await markerDisplay(web)
        XCTAssertEqual(display, "none")

        shield.enabled = false
        shield.apply(to: [controller])
        display = try await markerDisplay(web)
        XCTAssertEqual(display, "block")
        shield.enabled = true
        shield.apply(to: [controller])
        display = try await markerDisplay(web)
        XCTAssertEqual(display, "none")

        for _ in 0..<100 {
            let names = await store.availableIdentifiers() ?? []
            if !names.contains("office-shield") && !names.contains("office-shield-old") { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let names = await store.availableIdentifiers() ?? []
        XCTAssertTrue(names.contains(identifier))
        XCTAssertTrue(names.contains("unrelated"))
        XCTAssertFalse(names.contains("office-shield"))
        XCTAssertFalse(names.contains("office-shield-old"))
    }

    private func waitForList(_ shield: Shield) async throws {
        for _ in 0..<9_000 where shield.list == nil && shield.trouble == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNil(shield.trouble)
        XCTAssertNotNil(shield.list)
    }

    private func markerDisplay(_ web: WKWebView) async throws -> String? {
        let token = UUID().uuidString
        web.loadHTMLString("<body data-token='\(token)'><div id='marker' class='adsbygoogle'>marker</div></body>", baseURL: URL(string: "https://example.invalid/"))
        for _ in 0..<500 {
            if let display = try? await web.evaluateJavaScript("document.body?.dataset.token === '\(token)' && getComputedStyle(document.getElementById('marker')).display") as? String {
                return display
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return nil
    }

    func testNetworkFilterMatchesOnlyTheListedHostAndItsSubdomains() throws {
        let pattern = try NSRegularExpression(pattern: Shield.networkFilter(for: "segment.com"))
        for url in ["https://segment.com/track", "http://segment.com/track",
                    "https://cdn.segment.com/track", "https://a.b.segment.com/track",
                    "https://segment.com:8443/track", "https://segment.com/",
                    "https://segment.com/?event=test", "https://segment.com/#event"] {
            XCTAssertNotNil(pattern.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)), url)
        }
        for url in ["https://segment.company/app.js", "https://cdn.segment.company/app.js",
                    "https://segment.com.example/app.js", "https://segment.com-example/app.js",
                    "https://notsegment.com/app.js", "https://example.com/segment.com/track",
                    "https://segmentXcom/app.js", "ftp://segment.com/track"] {
            XCTAssertNil(pattern.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)), url)
        }
    }

    func testNetworkFilterCompilesInWebKit() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("shield-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try XCTUnwrap(WKContentRuleListStore(url: folder))
        let rules: [[String: Any]] = [[
            "trigger": ["url-filter": Shield.networkFilter(for: "segment.com"), "load-type": ["third-party"]],
            "action": ["type": "block"],
        ]]
        let data = try JSONSerialization.data(withJSONObject: rules)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        let list = try await store.compileContentRuleList(forIdentifier: "fixture", encodedContentRuleList: json)
        XCTAssertNotNil(list)
    }
}
