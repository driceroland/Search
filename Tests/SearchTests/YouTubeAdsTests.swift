import JavaScriptCore
import WebKit
import XCTest
@testable import Search

/// YouTubeAds' page script run in JavaScriptCore over a stand-in window (a
/// location, a Response with json()), its rules matched and compiled. No
/// page, no network, nothing started.
@MainActor
final class YouTubeAdsTests: XCTestCase {
    private static let world = "bld-yt-unit"

    override class func setUp() {
        setenv("SEARCH_PROBE", world, 1)
        super.setUp()
    }

    override class func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: "com.officecommun.search.test.\(world)")
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.removeItem(at: support.appendingPathComponent("Search (\(world))"))
        super.tearDown()
    }

    /// A context where `location.hostname` is `host`, `window` is the global
    /// object, and Response.prototype.json parses a stored text.
    private func context(host: String) -> JSContext {
        let context = JSContext()!
        context.exceptionHandler = { _, error in XCTFail("JS: \(error?.toString() ?? "?")") }
        context.evaluateScript("""
        var window = this;
        var location = { hostname: \(YouTubeAds.hostList([host]).dropFirst().dropLast()) };
        function Response(text) { this.text_ = text; }
        Response.prototype.json = function () { var t = this.text_; return Promise.resolve().then(function () { return JSON.parse.call(JSON, t); }); };
        var nativeParse = JSON.parse;
        """)
        return context
    }

    private let answer = """
    {"responseContext":{},"playabilityStatus":{"status":"OK"},
     "streamingData":{"formats":[{"itag":18}]},"videoDetails":{"videoId":"x"},
     "adPlacements":[{"a":1}],"playerAds":[{"b":2}],"adSlots":[{"c":3}],"adBreakHeartbeatParams":"h",
     "captions":{"k":1}}
    """

    private func run(_ context: JSContext, _ js: String) -> JSValue {
        context.evaluateScript(js)!
    }

    func testPlayerAnswerLosesItsAdsAndKeepsEverythingElse() {
        let c = context(host: "www.youtube.com")
        c.evaluateScript(YouTubeAds.page(hosts: YouTubeAds.hosts))
        c.setObject(answer, forKeyedSubscript: "answer" as NSString)
        let keys = run(c, "Object.keys(JSON.parse(answer)).sort().join(',')").toString()
        XCTAssertEqual(keys, "captions,playabilityStatus,responseContext,streamingData,videoDetails")
        XCTAssertEqual(run(c, "JSON.parse(answer).streamingData.formats[0].itag").toInt32(), 18)
    }

    func testResponseJsonIsPrunedToo() {
        let c = context(host: "music.youtube.com")
        c.evaluateScript(YouTubeAds.page(hosts: YouTubeAds.hosts))
        c.setObject(answer, forKeyedSubscript: "answer" as NSString)
        c.evaluateScript("var got; new Response(answer).json().then(function (v) { got = v; });")
        // JSC drains its microtasks once the evaluation returns.
        XCTAssertEqual(run(c, "typeof got").toString(), "object")
        XCTAssertEqual(run(c, "'adPlacements' in got || 'playerAds' in got").toBool(), false)
        XCTAssertEqual(run(c, "got.videoDetails.videoId").toString(), "x")
    }

    func testNestedPlayerResponseAndArraysOfThem() {
        let c = context(host: "m.youtube.com")
        c.evaluateScript(YouTubeAds.page(hosts: YouTubeAds.hosts))
        c.setObject("[{\"playerResponse\":\(answer)},{\"response\":{\"responseContext\":{},\"adSlots\":[1]}}]",
                    forKeyedSubscript: "answer" as NSString)
        XCTAssertEqual(run(c, "'adPlacements' in JSON.parse(answer)[0].playerResponse").toBool(), false)
        XCTAssertEqual(run(c, "'streamingData' in JSON.parse(answer)[0].playerResponse").toBool(), true)
    }

    func testInlineInitialPlayerResponseGoesThroughTheSetter() {
        let c = context(host: "www.youtube-nocookie.com")
        c.evaluateScript(YouTubeAds.page(hosts: YouTubeAds.hosts))
        // As YouTube's own page script writes it.
        c.evaluateScript("var ytInitialPlayerResponse = \(answer);")
        XCTAssertEqual(run(c, "'adPlacements' in ytInitialPlayerResponse").toBool(), false)
        XCTAssertEqual(run(c, "window.ytInitialPlayerResponse.streamingData.formats.length").toInt32(), 1)
    }

    func testOtherShapesAndOtherSitesAreUntouched() {
        // Not YouTube's shape: a key named adSlots elsewhere is the page's own.
        let c = context(host: "www.youtube.com")
        c.evaluateScript(YouTubeAds.page(hosts: YouTubeAds.hosts))
        XCTAssertEqual(run(c, "JSON.parse('{\"adSlots\":[1],\"x\":1}').adSlots.length").toInt32(), 1)
        XCTAssertEqual(run(c, "JSON.parse('[1,2]').length").toInt32(), 2)
        XCTAssertEqual(run(c, "JSON.parse('\"s\"')").toString(), "s")
        XCTAssertEqual(run(c, "JSON.parse('{\"a\":2}', function (k, v) { return k === 'a' ? v * 2 : v; }).a").toInt32(), 4)
        var threw = run(c, "try { JSON.parse('{'); false } catch (e) { e instanceof SyntaxError }").toBool()
        XCTAssertTrue(threw)
        // The function keeps a native one's shape.
        XCTAssertEqual(run(c, "JSON.parse.name + JSON.parse.length").toString(), "parse2")
        threw = run(c, "try { new JSON.parse('1'); false } catch (e) { e instanceof TypeError }").toBool()
        XCTAssertTrue(threw)

        let other = context(host: "example.com")
        other.evaluateScript(YouTubeAds.page(hosts: YouTubeAds.hosts))
        XCTAssertEqual(run(other, "JSON.parse === nativeParse").toBool(), true)
        XCTAssertEqual(run(other, "Object.getOwnPropertyDescriptor(window, 'ytInitialPlayerResponse') === undefined").toBool(), true)
        let lookalike = context(host: "accounts.youtube.com")
        lookalike.evaluateScript(YouTubeAds.page(hosts: YouTubeAds.hosts))
        XCTAssertEqual(run(lookalike, "JSON.parse === nativeParse").toBool(), true)
    }

    func testTheScriptLeavesNoNameBehind() {
        let c = context(host: "www.youtube.com")
        let before = Set(run(c, "Object.getOwnPropertyNames(this)").toArray().compactMap { $0 as? String })
        c.evaluateScript(YouTubeAds.page(hosts: YouTubeAds.hosts))
        let after = Set(run(c, "Object.getOwnPropertyNames(this)").toArray().compactMap { $0 as? String })
        XCTAssertEqual(after.subtracting(before), ["ytInitialPlayerResponse", "ytInitialData"])
        XCTAssertFalse(YouTubeAds.page(hosts: YouTubeAds.hosts).contains("eval"))
        XCTAssertFalse(YouTubeAds.page(hosts: YouTubeAds.hosts).contains("Function("))
        XCTAssertFalse(YouTubeAds.page(hosts: YouTubeAds.hosts).contains("webkit"))
    }

    func testSkipperMutesAndSpeedsAnAdThenPutsTheVideoBack() {
        let c = context(host: "www.youtube.com")
        c.evaluateScript("""
        function HTMLVideoElement() { this.muted = false; this.playbackRate = 1.5; this.player = null; }
        HTMLVideoElement.prototype.closest = function () { return this.player; };
        var heard = {};
        var document = { addEventListener: function (t, f, capture) { (heard[t] = heard[t] || []).push(f); } };
        function fire(t, v) { (heard[t] || []).forEach(function (f) { f({ target: v }); }); }
        var shown = {};
        var player = { classList: { contains: function (c) { return !!shown[c]; } } };
        var v = new HTMLVideoElement(); v.player = player;
        """)
        c.evaluateScript(YouTubeAds.skipper(hosts: YouTubeAds.hosts))
        c.evaluateScript("fire('playing', v)")
        XCTAssertEqual(run(c, "v.muted + ' ' + v.playbackRate").toString(), "false 1.5", "no ad: untouched")
        c.evaluateScript("shown['ad-showing'] = true; fire('timeupdate', v)")
        XCTAssertEqual(run(c, "v.muted + ' ' + v.playbackRate").toString(), "true 16")
        c.evaluateScript("v.playbackRate = 1; fire('timeupdate', v)")
        XCTAssertEqual(run(c, "v.playbackRate").toInt32(), 16, "the player setting it back is undone while the ad lasts")
        c.evaluateScript("shown['ad-showing'] = false; fire('playing', v)")
        XCTAssertEqual(run(c, "v.muted + ' ' + v.playbackRate").toString(), "false 1.5", "the video's own sound and speed")
        // Muted before the ad: still muted after.
        c.evaluateScript("v.muted = true; shown['ad-showing'] = true; fire('playing', v); shown['ad-showing'] = false; fire('playing', v)")
        XCTAssertEqual(run(c, "v.muted").toBool(), true)
        // A video outside YouTube's player is never touched.
        c.evaluateScript("var w = new HTMLVideoElement(); fire('playing', w)")
        XCTAssertEqual(run(c, "w.muted + ' ' + w.playbackRate").toString(), "false 1.5")
    }

    func testRulesBlockAdPathsAndNeverTheVideo() throws {
        let filters = YouTubeAds.rules.compactMap { ($0["trigger"] as? [String: Any])?["url-filter"] as? String }
        let patterns = try filters.map { try NSRegularExpression(pattern: $0) }
        func blocked(_ url: String) -> Bool {
            patterns.contains { $0.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil }
        }
        for url in ["https://www.youtube.com/api/stats/ads?ver=2", "https://www.youtube.com/pagead/adview?x",
                    "https://www.youtube.com/ptracking?pltype=adhost", "https://www.youtube.com/get_midroll_info?ei=1",
                    "https://www.youtube.com/youtubei/v1/player/ad_break?key=1", "https://www.youtube.com/pcs/activeview?x",
                    "https://s.youtube.com/api/stats/qoe?event=streamingstats&adformat=15_2",
                    "https://www.google.com/pagead/lvz?x", "https://imasdk.googleapis.com/js/sdkloader/ima3.js"] {
            XCTAssertTrue(blocked(url), url)
        }
        for url in ["https://rr1---sn-abc.googlevideo.com/videoplayback?expire=1&itag=18",
                    "https://www.youtube.com/youtubei/v1/player?key=1", "https://www.youtube.com/youtubei/v1/next?key=1",
                    "https://www.youtube.com/api/stats/watchtime?x", "https://www.youtube.com/api/stats/playback?x",
                    "https://s.youtube.com/api/stats/qoe?event=streamingstats&fmt=18",
                    "https://www.youtube.com/watch?v=pagead", "https://i.ytimg.com/vi/x/hqdefault.jpg",
                    "https://example.com/api/stats/ads", "https://notyoutube.com/pagead/x"] {
            XCTAssertFalse(blocked(url), url)
        }
    }

    func testShieldListWithYouTubeRulesCompilesInWebKit() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ytads-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try XCTUnwrap(WKContentRuleListStore(url: folder))
        let data = try JSONSerialization.data(withJSONObject: YouTubeAds.rules)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        let list = try await store.compileContentRuleList(forIdentifier: "fixture", encodedContentRuleList: json)
        XCTAssertNotNil(list)
    }

    func testScriptsFollowShieldAndItsPause() {
        let shield = Shield.shared
        let was = shield.enabled
        let paused = shield.isPaused(on: "youtube.com")
        defer { shield.enabled = was; shield.pause("youtube.com", paused) }
        shield.enabled = true
        shield.pause("youtube.com", false)
        XCTAssertEqual(YouTubeAds.scripts(for: "youtube.com").count, 2)
        shield.pause("youtube.com", true)
        XCTAssertEqual(YouTubeAds.scripts(for: "youtube.com").count, 0)
        XCTAssertEqual(YouTubeAds.scripts(for: "example.com").count, 2)
        shield.enabled = false
        XCTAssertEqual(YouTubeAds.scripts(for: "example.com").count, 0)
    }
}
