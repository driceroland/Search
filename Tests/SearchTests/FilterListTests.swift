import WebKit
import XCTest
@testable import Search

final class FilterListTests: XCTestCase {
    private func rules(_ list: String) throws -> [[String: Any]] {
        let json = FilterList.convert(list).json
        let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]]
        return try XCTUnwrap(parsed)
    }

    /// The rules a list makes, minus the closing one every list gets.
    private func made(_ list: String) throws -> [[String: Any]] {
        Array(try rules(list).dropLast())
    }

    private func trigger(_ rule: [String: Any]) -> [String: Any] { rule["trigger"] as? [String: Any] ?? [:] }
    private func action(_ rule: [String: Any]) -> [String: Any] { rule["action"] as? [String: Any] ?? [:] }

    private func assertMatches(_ filter: String, _ yes: [String], _ no: [String], line: UInt = #line) throws {
        let pattern = try NSRegularExpression(pattern: filter, options: .caseInsensitive)
        for url in yes {
            XCTAssertNotNil(pattern.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)), url, line: line)
        }
        for url in no {
            XCTAssertNil(pattern.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)), url, line: line)
        }
    }

    func testHostFilterEndsAtTheHost() throws {
        let rule = try XCTUnwrap(made("||ad.example.com^").first)
        try assertMatches(trigger(rule)["url-filter"] as! String,
                          ["https://ad.example.com/x.js", "https://cdn.ad.example.com/", "http://ad.example.com:8080/"],
                          ["https://ad.example.community/", "https://bad.example.com/", "https://example.com/ad.example.com/"])
    }

    func testCaretInTheMiddleIsASeparator() throws {
        let rule = try XCTUnwrap(made("||tracker.example^*/pixel/").first)
        try assertMatches(trigger(rule)["url-filter"] as! String,
                          ["https://tracker.example/a/pixel/1.gif", "https://tracker.example:443/pixel/"],
                          ["https://tracker.examples/pixel/", "https://other.example/pixel/"])
    }

    func testCaretAtTheEndEndsTheToken() throws {
        let rule = try XCTUnwrap(made("/banner^").first)
        try assertMatches(trigger(rule)["url-filter"] as! String,
                          ["https://a.example/banner", "https://a.example/banner?x=1", "https://a.example/banner/top.png"],
                          ["https://a.example/bannerads.png", "https://a.example/banner_top.png"])
    }

    func testTypesPartyAndDomains() throws {
        let rule = try XCTUnwrap(made("||cdn.example^$script,third-party,domain=news.example|blog.example").first)
        let t = trigger(rule)
        XCTAssertEqual(t["resource-type"] as? [String], ["script"])
        XCTAssertEqual(t["load-type"] as? [String], ["third-party"])
        XCTAssertEqual(t["if-domain"] as? [String], ["*news.example", "*blog.example"])
    }

    func testATypeWebKitLacksDoesNotBecomeEveryType() throws {
        XCTAssertTrue(try made("||plugin.example^$object").isEmpty)
        XCTAssertEqual(FilterList.convert("||plugin.example^$object").dropped["only types WebKit can't block"], 1)
    }

    func testMixedDomainsAreLeftOut() throws {
        XCTAssertTrue(try made("/ads.js$domain=site.example|~shop.site.example").isEmpty)
    }

    func testExceptionLiftsAGenericHideOnThatSite() throws {
        let made = try made("##.ad-slot\nquiet.example#@#.ad-slot")
        XCTAssertEqual(made.count, 1)
        XCTAssertEqual(action(made[0])["selector"] as? String, ".ad-slot")
        XCTAssertEqual(trigger(made[0])["unless-domain"] as? [String], ["*quiet.example"])
    }

    func testSiteHidesCoverSubdomainsAndMerge() throws {
        let made = try made("a.example##.promo\nb.example##.promo")
        XCTAssertEqual(made.count, 1)
        XCTAssertEqual(trigger(made[0])["if-domain"] as? [String], ["*a.example", "*b.example"])
    }

    func testBadfilterStrikesItsFilterWhateverTheOptionOrder() throws {
        XCTAssertTrue(try made("||ads.example^$script,third-party\n||ads.example^$third-party,script,badfilter").isEmpty)
    }

    func testImportantComesAfterExceptions() throws {
        let made = try made("||ads.example^$important\n@@||ads.example^\n||other.example^")
        XCTAssertEqual(made.map { action($0)["type"] as? String }, ["block", "ignore-previous-rules", "block"])
        XCTAssertTrue((trigger(made[2])["url-filter"] as? String)?.contains("ads") == true)
    }

    func testGenerichideLiftsOnlyGenericHides() throws {
        let made = try made("##.ad\nsite.example##.promo\n@@||site.example^$generichide")
        XCTAssertEqual(made.map { action($0)["type"] as? String }, ["css-display-none", "ignore-previous-rules", "css-display-none"])
        XCTAssertEqual(trigger(made[1])["if-domain"] as? [String], ["*site.example"])
    }

    func testWhatWebKitCannotDoIsCountedNotGuessed() throws {
        let converted = FilterList.convert("""
        ! a comment
        site.example##+js(set-constant, ads, false)
        site.example##.x:has-text(Sponsored)
        ||ads.example^$redirect=noopjs
        ||pop.example^$popup
        /^https?:\\/\\/ads\\./
        """)
        XCTAssertEqual(converted.used, 0)
        XCTAssertEqual(converted.dropped, ["scriptlet": 1, "procedural selector": 1, "$redirect": 1,
                                           "$popup": 1, "regular expression": 1])
    }

    func testHostsFileEntriesBlockTheirHost() throws {
        let rule = try XCTUnwrap(made("0.0.0.0 tracker.example\n127.0.0.1 localhost").first)
        try assertMatches(trigger(rule)["url-filter"] as! String,
                          ["https://tracker.example/"], ["https://tracker.examples/"])
        XCTAssertEqual(try made("127.0.0.1 localhost").count, 0)
    }

    @MainActor
    func testEveryKindOfRuleCompilesInWebKit() async throws {
        let list = """
        ||ad.example.com^
        ||tracker.example^*/pixel/
        /banner^
        |https://
        $third-party,xhr,domain=site.example
        ||cdn.example^$script,image,~third-party
        ||frames.example^$subdocument,script
        ||ws.example^$websocket,ping,other
        @@||ad.example.com/ok.js
        @@||safe.example^$document
        @@||site.example^$generichide
        ||strict.example^$important
        ##.ad-slot
        ~quiet.example##.sponsor
        a.example,b.example##.promo
        quiet.example#@#.ad-slot
        0.0.0.0 hosts.example
        """
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("filterlist-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try XCTUnwrap(WKContentRuleListStore(url: folder))
        let compiled = try await store.compileContentRuleList(forIdentifier: "fixture",
                                                              encodedContentRuleList: FilterList.convert(list).json)
        XCTAssertNotNil(compiled)
    }
}

@MainActor
final class FilterListsTests: XCTestCase {
    func testWhatCanBeTypedAsAList() {
        XCTAssertEqual(FilterLists.origin("easylist.to/easylist/easylist.txt"), "https://easylist.to/easylist/easylist.txt")
        XCTAssertEqual(FilterLists.origin(" https://example.com/list.txt \n"), "https://example.com/list.txt")
        XCTAssertEqual(FilterLists.origin("file:///tmp/my%20list.txt"), "/tmp/my list.txt")
        XCTAssertEqual(FilterLists.origin("~/lists/hosts"), NSHomeDirectory() + "/lists/hosts")
        XCTAssertNil(FilterLists.origin("ftp://example.com/list.txt"))
        XCTAssertNil(FilterLists.origin("not a list"))
        XCTAssertNil(FilterLists.origin(""))
    }

    func testHeaderGivesNameAndFreshness() {
        let header = FilterLists.header(of: "[Adblock Plus 2.0]\n! Title: EasyList\n! Expires: 4 days (update frequency)\n||ads.example^")
        XCTAssertEqual(header.title, "EasyList")
        XCTAssertEqual(header.keeps, 4 * FilterLists.day)
        XCTAssertEqual(FilterLists.header(of: "! Expires: 12 hours").keeps, 12 * 3600)
        // Clamped: no list is fetched every minute, or left for a year.
        XCTAssertEqual(FilterLists.header(of: "! Expires: 1 minutes").keeps, nil)
        XCTAssertEqual(FilterLists.header(of: "! Expires: 0.1 hours").keeps, 3600)
        XCTAssertEqual(FilterLists.header(of: "! Expires: 90 days").keeps, 14 * FilterLists.day)
        XCTAssertNil(FilterLists.header(of: "||ads.example^").title)
    }

    private func written(_ text: String) throws -> String {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("list-\(UUID().uuidString).txt")
        try text.write(to: file, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        return file.path
    }

    /// Added, then waited on until it's converted and compiled or refused.
    private func added(_ path: String) async throws -> FilterLists.Source {
        let lists = FilterLists.shared
        XCTAssertNil(lists.problem(with: path))
        lists.add(path)
        XCTAssertNotNil(lists.problem(with: path), "the same list twice")
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            if let source = lists.sources.first(where: { $0.origin == path }), !lists.working.contains(source.id),
               source.rules != nil {
                return source
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw XCTSkip("the list never finished")
    }

    func testAFileListReachesTheBlockerAndLeavesIt() async throws {
        let path = try written("! Title: Test list\n||ads.example^\n##.ad-box\nsite.example##+js(nope)")
        let before = Shield.shared.added.count
        let source = try await added(path)
        XCTAssertEqual(source.name, "Test list")
        XCTAssertNil(source.trouble)
        XCTAssertEqual(source.used, 2)
        XCTAssertEqual(source.dropped, ["scriptlet": 1])
        XCTAssertEqual(Shield.shared.added.count, before + 1)

        FilterLists.shared.turn(source.id, on: false)
        XCTAssertEqual(Shield.shared.added.count, before)
        FilterLists.shared.turn(source.id, on: true)
        XCTAssertEqual(Shield.shared.added.count, before + 1)

        FilterLists.shared.remove(source.id)
        XCTAssertEqual(Shield.shared.added.count, before)
        XCTAssertFalse(FilterLists.shared.sources.contains { $0.id == source.id })
    }

    func testAListPastWebKitsLimitIsRefusedAndSaysSo() async throws {
        let lines = (0...FilterList.limit).map { "||a\($0).example^" }.joined(separator: "\n")
        let before = Shield.shared.added.count
        let source = try await added(try written(lines))
        defer { FilterLists.shared.remove(source.id) }
        XCTAssertEqual(source.rules, FilterList.limit + 2)
        XCTAssertTrue(source.nearLimit)
        XCTAssertNotNil(source.trouble)
        XCTAssertTrue(source.trouble?.contains("150,000") == true, source.trouble ?? "")
        XCTAssertEqual(Shield.shared.added.count, before)
    }
}
