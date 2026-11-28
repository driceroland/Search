import WebKit
import XCTest
@testable import Search

final class FilterRulesTests: XCTestCase {
    func testDomainAnchorOnlyMatchesTheHostAndItsSubdomains() throws {
        let result = convertSingleChunk("||ads.example.com^")
        XCTAssertEqual(result.skipped, 0)
        XCTAssertEqual(result.rules.count, 1)
        let patterns = try result.rules.map { try NSRegularExpression(pattern: XCTUnwrap(trigger($0)["url-filter"] as? String)) }
        for url in ["https://ads.example.com/x", "https://sub.ads.example.com/", "http://ads.example.com/",
                    "https://ads.example.com:8443/x", "wss://ads.example.com/socket"] {
            XCTAssertTrue(matches(patterns, url), url)
        }
        for url in ["https://notads.example.com/", "https://ads.example.com.evil.test/",
                    "https://example.com/ads.example.com/x", "https://ads.example.com:123@evil.test/",
                    "https://ads.example.com@evil.test/"] {
            XCTAssertFalse(matches(patterns, url), url)
        }
    }

    func testNetworkOptionsAndExceptionOrdering() throws {
        let result = convertSingleChunk("""
        @@||example.com^$document
        @@safe.js$script
        blocked.js$third-party,script,match-case
        other$1p,xhr,important
        """)
        XCTAssertEqual(result.skipped, 0)
        XCTAssertEqual(result.rules.map(action), ["block", "block", "ignore-previous-rules", "ignore-previous-rules"])
        let block = trigger(result.rules[0])
        XCTAssertEqual(block["load-type"] as? [String], ["third-party"])
        XCTAssertEqual(block["resource-type"] as? [String], ["script"])
        XCTAssertEqual(block["url-filter-is-case-sensitive"] as? Bool, true)
        XCTAssertEqual(trigger(result.rules[1])["load-type"] as? [String], ["first-party"])
        XCTAssertEqual(trigger(result.rules[1])["resource-type"] as? [String], ["fetch", "raw"])
        let document = trigger(result.rules[2])
        XCTAssertEqual(document["url-filter"] as? String, ".*")
        let top = try XCTUnwrap(document["if-top-url"] as? [String])
        XCTAssertTrue(matches(try top.map { try NSRegularExpression(pattern: $0) }, "https://www.example.com/"))
    }

    func testNetworkDomainOptionsAndCosmetics() {
        let result = convertSingleChunk("""
        resource$domain=example.com|news.test
        another$domain=~example.com
        ##.generic
        ##.also-generic
        a.com,b.com##.site
        ~a.com##.outside
        """)
        XCTAssertEqual(result.skipped, 0)
        XCTAssertEqual(result.rules.count, 5)
        XCTAssertEqual(result.rules[0]["action"] as? [String: String],
                       ["type": "css-display-none", "selector": ".generic, .also-generic"])
        XCTAssertEqual(trigger(result.rules[1])["if-domain"] as? [String], ["a.com", "*.a.com", "b.com", "*.b.com"])
        XCTAssertEqual(trigger(result.rules[2])["unless-domain"] as? [String], ["a.com", "*.a.com"])
        XCTAssertEqual(trigger(result.rules[3])["if-domain"] as? [String], ["example.com", "*.example.com", "news.test", "*.news.test"])
        XCTAssertEqual(trigger(result.rules[4])["unless-domain"] as? [String], ["example.com", "*.example.com"])
    }

    func testCosmeticExceptionsRunBeforeNetworkRules() {
        let result = convertSingleChunk("""
        @@||site.test^$elemhide
        @@||site.test^$generichide
        site.test##.site
        ##.generic
        ads.js
        """)
        XCTAssertEqual(result.skipped, 0)
        XCTAssertEqual(result.rules.map(action),
                       ["css-display-none", "ignore-previous-rules", "css-display-none", "ignore-previous-rules", "block"])
        XCTAssertNotNil(trigger(result.rules[1])["if-top-url"])
        XCTAssertNotNil(trigger(result.rules[3])["if-top-url"])
    }

    func testAnchorsSeparatorsWildcardsAndSafeRegex() throws {
        let result = convertSingleChunk("""
        |https://example.com/ads^*pixel.js|
        /asset[0-9]+\\.png$/
        """)
        XCTAssertEqual(result.skipped, 0)
        let patterns = try result.rules.map { try NSRegularExpression(pattern: XCTUnwrap(trigger($0)["url-filter"] as? String)) }
        XCTAssertTrue(matches([patterns[0]], "https://example.com/ads/a/pixel.js"))
        XCTAssertFalse(matches([patterns[0]], "https://example.com/adstuff/pixel.js"))
        XCTAssertFalse(matches([patterns[0]], "https://example.com/ads/a/pixel.js?x"))
        XCTAssertTrue(matches([patterns[1]], "https://example.com/asset20.png"))
    }

    func testCommentsAndUnsupportedLines() {
        let result = convertSingleChunk("""
        [Adblock Plus 2.0]
        ! A comment

        supported
        a.com##+js(something)
        a.com#?#.procedural
        a.com##p:has-text(Example)
        a.com##^script
        a.com#@#.slot
        thing$redirect=noop
        thing$csp=none
        thing$removeparam=x
        thing$header=x
        thing$domain=a.com|~b.com
        /x|y/
        /x{4}/
        /\\d+/
        /\\btrack/
        café
        """)
        XCTAssertEqual(result.rules.count, 1)
        XCTAssertEqual(result.skipped, 15)
    }

    func testOverallCapCountsRulesBeyondEightChunksAsSkipped() {
        let exceptions = String(repeating: "@@allowed.js\n", count: 149_999)
        let blocks = String(repeating: "pixel.js\n", count: 10)
        let result = FilterRules.convert(exceptions + blocks)
        XCTAssertEqual(result.chunks.map(\.count), Array(repeating: 150_000, count: 8))
        XCTAssertEqual(result.count, 150_007)
        XCTAssertEqual(result.skipped, 2)
    }

    @MainActor
    func testLargeInputCompilesBothChunksWithTheSameExceptions() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try XCTUnwrap(WKContentRuleListStore(url: folder))
        let input = """
        ##.generic
        @@||generic.invalid^$generichide
        site.invalid##.specific
        @@||elements.invalid^$elemhide
        @@safe.js$script
        @@||document.invalid^$document
        """ + "\n" + String(repeating: "||ads.example.invalid^\n", count: 150_001)
        let result = FilterRules.convert(input)
        XCTAssertEqual(result.skipped, 0)
        XCTAssertEqual(result.count, 150_007)
        XCTAssertEqual(result.chunks.map(\.count), [150_000, 11])
        let signatures = result.chunks.map { chunk in
            chunk.filter { action($0) == "ignore-previous-rules" }.map { rule in
                let match = trigger(rule)
                return (match["if-top-url"] as? [String])?.first ?? match["url-filter"] as? String
            }
        }
        XCTAssertEqual(signatures.map(\.count), [4, 4])
        XCTAssertEqual(signatures.first, signatures.last)
        let first = try XCTUnwrap(result.chunks.first)
        XCTAssertEqual(first.prefix(5).map(action),
                       ["css-display-none", "ignore-previous-rules", "css-display-none", "ignore-previous-rules", "block"])
        XCTAssertEqual(result.chunks.last?.prefix(3).map(action), ["ignore-previous-rules", "ignore-previous-rules", "block"])
        for (index, chunk) in result.chunks.enumerated() {
            let data = try JSONSerialization.data(withJSONObject: chunk, options: [.sortedKeys])
            let identifier = "large-input-\(index)"
            let list = try await store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: String(decoding: data, as: UTF8.self))
            XCTAssertEqual(list?.identifier, identifier)
        }
    }

    @MainActor
    func testEasyListLikeRulesCompileInWebKit() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try XCTUnwrap(WKContentRuleListStore(url: folder))
        let converted = convertSingleChunk("""
        [Adblock Plus 2.0]
        ||ads.example.com^$third-party,script,image
        |https://example.com/ads^*pixel.js|
        |https://example.com/slot^
        /asset[0-9]+\\.png$/
        /ping.js$xmlhttprequest,media,font,stylesheet,subdocument,popup,websocket,other,ping
        pixel$domain=news.test|shop.test
        pixel$domain=~news.test
        ##.ads
        ##div[data-ad]
        news.test##.sponsor
        ~shop.test##.promoted
        @@||news.test^$generichide
        @@||other.test^$elemhide
        @@||example.com^$document
        @@|https://ads.example.com/allowed.js|$script
        """)
        XCTAssertEqual(converted.skipped, 0)
        let data = try JSONSerialization.data(withJSONObject: converted.rules)
        let list = try await store.compileContentRuleList(forIdentifier: "example", encodedContentRuleList: String(decoding: data, as: UTF8.self))
        XCTAssertEqual(list?.identifier, "example")
    }

    @MainActor
    func testWebKitAppliesEachCosmeticExceptionAtItsIntendedScope() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try XCTUnwrap(WKContentRuleListStore(url: folder))
        let converted = convertSingleChunk("""
        ##.generic
        ~never.invalid##.site
        @@||generic.invalid^$generichide
        @@||elements.invalid^$elemhide
        @@||document.invalid^$document
        """)
        let data = try JSONSerialization.data(withJSONObject: converted.rules)
        let compiled = try await store.compileContentRuleList(forIdentifier: "exceptions", encodedContentRuleList: String(decoding: data, as: UTF8.self))
        let config = WKWebViewConfiguration()
        config.userContentController.add(try XCTUnwrap(compiled))
        let web = WKWebView(frame: .zero, configuration: config)
        for (host, expected) in [("ordinary", "none,none"), ("generic", "block,none"),
                                 ("elements", "block,block"), ("document", "block,block")] {
            let url = try XCTUnwrap(URL(string: "https://\(host).invalid/"))
            web.loadHTMLString("<body id='\(host)'><div class='generic'></div><div class='site'></div></body>", baseURL: url)
            var display: String?
            for _ in 0..<500 {
                display = try? await web.evaluateJavaScript("""
                    document.body?.id === '\(host)' &&
                    Array.from(document.body.children, element => getComputedStyle(element).display).join(',')
                    """) as? String
                if display != nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(display, expected, host)
        }
    }

    private func convertSingleChunk(_ input: String) -> (rules: [FilterRules.Rule], skipped: Int) {
        let result = FilterRules.convert(input)
        XCTAssertEqual(result.chunks.count, 1)
        return (result.chunks.first ?? [], result.skipped)
    }

    private func trigger(_ rule: [String: Any]) -> [String: Any] {
        rule["trigger"] as? [String: Any] ?? [:]
    }

    private func action(_ rule: [String: Any]) -> String? {
        (rule["action"] as? [String: String])?["type"]
    }

    private func matches(_ patterns: [NSRegularExpression], _ url: String) -> Bool {
        patterns.contains { $0.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil }
    }
}
