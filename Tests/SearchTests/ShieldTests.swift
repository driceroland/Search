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
        _ = try await store.compileContentRuleList(forIdentifier: "office-shield-custom-kept", encodedContentRuleList: marker)

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
        shield.apply()
        display = try await markerDisplay(web)
        XCTAssertEqual(display, "block")
        shield.enabled = true
        shield.apply()
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
        XCTAssertTrue(names.contains("office-shield-custom-kept"))
        XCTAssertFalse(names.contains("office-shield"))
        XCTAssertFalse(names.contains("office-shield-old"))
    }

    func testAllowlistNormalizationAndParentMatching() throws {
        let suite = "shield-allowlist-\(UUID())"
        let settings = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { settings.removePersistentDomain(forName: suite) }
        let shield = Shield(store: nil, settings: settings)

        let site = try XCTUnwrap(Shield.normalizedHost("  HTTPS://WWW.Example.COM.:8443/a?b=1  "))
        XCTAssertEqual(site, "example.com")
        XCTAssertEqual(Shield.normalizedHost(" News.Example.com/path "), "news.example.com")
        XCTAssertNil(Shield.normalizedHost("https:///path"))
        XCTAssertNil(Shield.normalizedHost("just words"))

        shield.pause(site, true)
        shield.pause("news.example.com", true)
        shield.pause("com", true)
        for host in ["example.com", "www.example.com", "news.example.com", "deep.news.example.com"] {
            XCTAssertTrue(shield.isPaused(on: host), host)
        }
        for host in ["notexample.com", "example.com.evil.test", "elsewhere.com"] {
            XCTAssertFalse(shield.isPaused(on: host), host)
        }
        XCTAssertFalse(shield.isPaused(on: nil))

        shield.resumeBlocking(on: "deep.news.example.com")
        XCTAssertFalse(shield.isPaused(on: "deep.news.example.com"))
        XCTAssertEqual(settings.stringArray(forKey: "shield.paused"), ["com"])
    }

    func testAttachingAndRemovingChunksKeepsAllowlistedTabsUnblocked() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let suite = "shield-allowlist-\(UUID())"
        let settings = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { settings.removePersistentDomain(forName: suite) }
        let store = try XCTUnwrap(WKContentRuleListStore(url: folder))
        let shield = Shield(store: store, settings: settings)
        let config = WKWebViewConfiguration()
        let controller = config.userContentController
        shield.protect(controller)
        shield.tune(controller, for: "news.example.invalid")
        shield.pause("example.invalid", true)
        shield.compile()
        try await waitForList(shield)
        var lists: [WKContentRuleList] = []
        let markers = ["custom-one", "custom-two"]
        for marker in markers {
            let json = ##"[{"trigger":{"url-filter":".*"},"action":{"type":"css-display-none","selector":"#\##(marker)"}}]"##
            let list = try await store.compileContentRuleList(forIdentifier: "office-shield-custom-\(marker)", encodedContentRuleList: json)
            lists.append(try XCTUnwrap(list))
        }
        let web = WKWebView(frame: .zero, configuration: config)

        func check(_ custom: String, builtIn: String) async throws {
            for marker in markers {
                let display = try await markerDisplay(web, builtIn: false, markerID: marker)
                XCTAssertEqual(display, custom, marker)
            }
            let display = try await markerDisplay(web, markerID: "builtin")
            XCTAssertEqual(display, builtIn)
        }

        shield.setCustomList(lists)
        try await check("block", builtIn: "block")
        shield.enabled = false
        shield.apply()
        shield.enabled = true
        shield.apply()
        try await check("block", builtIn: "block")

        shield.pause("example.invalid", false)
        try await check("none", builtIn: "none")
        shield.enabled = false
        shield.apply()
        try await check("block", builtIn: "block")
        shield.enabled = true
        shield.apply()
        try await check("none", builtIn: "none")

        shield.setCustomList([])
        try await check("block", builtIn: "none")
        shield.setCustomList(lists)
        shield.pause("example.invalid", true)
        try await check("block", builtIn: "block")
    }

    private func waitForList(_ shield: Shield) async throws {
        for _ in 0..<9_000 where shield.list == nil && shield.trouble == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNil(shield.trouble)
        XCTAssertNotNil(shield.list)
    }

    private func markerDisplay(_ web: WKWebView, builtIn: Bool = true, markerID: String = "marker") async throws -> String? {
        let token = UUID().uuidString
        let element = "<div id='\(markerID)' class='\(builtIn ? "adsbygoogle" : "")'>marker</div>"
        web.loadHTMLString("<body data-token='\(token)'>\(element)</body>", baseURL: URL(string: "https://example.invalid/"))
        for _ in 0..<500 {
            if let display = try? await web.evaluateJavaScript("document.body?.dataset.token === '\(token)' && getComputedStyle(document.getElementById('\(markerID)')).display") as? String {
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
