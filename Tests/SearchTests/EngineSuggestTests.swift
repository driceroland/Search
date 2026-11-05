import AppKit
import WebKit
import XCTest
@testable import Search

/// Settings › General › Suggestions from your search engine (idea 347).
@MainActor
final class EngineSuggestTests: XCTestCase {
    /// Shaped like a GitHub token, made up, and put together here so no
    /// secret scanner takes the file for one.
    private let fakeToken = "gh" + "p_" + "0000Fake1111Token2222Shape3333Only44"

    override class func setUp() {
        setenv("SEARCH_PROBE", "engine-suggest-\(getpid())", 1)
        super.setUp()
    }

    // MARK: - what each engine answers

    func testOpenSearchAnswersAreRead() {
        // Google's (client=firefox), with its extra members after the words.
        let google = #"["coffee",["coffee shop","coffee shop nantes","Coffee","coffee pot"],[],{"google:suggestsubtypes":[[512]]}]"#
        XCTAssertEqual(EngineSuggest.parse(Data(google.utf8), asked: "coffee"),
                       ["coffee shop", "coffee shop nantes", "coffee pot"])
        // DuckDuckGo's, Bing's, Ecosia's, Startpage's, Kagi's, Brave's, Qwant's.
        let plain = #"["café",["café","café del mar"," café au lait ","café del mar"]]"#
        XCTAssertEqual(EngineSuggest.parse(Data(plain.utf8), asked: "Café "), ["café del mar", "café au lait"])
    }

    func testAnswersAreCappedAtSix() {
        let many = #"["a",["a1","a2","a3","a4","a5","a6","a7","a8"]]"#
        XCTAssertEqual(EngineSuggest.parse(Data(many.utf8), asked: "a").count, 6)
    }

    func testAnythingElseIsNothing() {
        for junk in ["", "null", "{}", #"{"query":"x","suggestions":["y"]}"#, #"["x"]"#, #"["x","y"]"#,
                     #"["x",[1,2,{"a":1}]]"#, "<html>nope</html>", #"["x",["","  ","line\nbreak"]]"#] {
            XCTAssertEqual(EngineSuggest.parse(Data(junk.utf8), asked: "x"), [], junk)
        }
        let long = String(repeating: "x", count: 300)
        XCTAssertEqual(EngineSuggest.parse(Data(#"["x",["\#(long)"]]"#.utf8), asked: "x"), [])
    }

    func testEveryEngineButCustomHasAnHTTPSAddress() throws {
        for engine in Engine.allCases {
            guard engine != .custom else {
                XCTAssertNil(EngineSuggest.endpoint(for: engine))
                XCTAssertNil(EngineSuggest.url(for: "coffee", engine: engine))
                continue
            }
            let url = try XCTUnwrap(EngineSuggest.url(for: "café crème", engine: engine), engine.title)
            XCTAssertEqual(url.scheme, "https", engine.title)
            XCTAssertTrue(url.absoluteString.contains("caf%C3%A9%20cr%C3%A8me"), url.absoluteString)
        }
        XCTAssertEqual(EngineSuggest.url(for: "a&b", engine: .google)?.absoluteString,
                       "https://suggestqueries.google.com/complete/search?client=firefox&q=a%26b")
        XCTAssertEqual(EngineSuggest.url(for: "x y", engine: .qwant)?.absoluteString,
                       "https://api.qwant.com/api/suggest/?q=x%20y&client=opensearch")
    }

    func testOnlyHTTPSOrATestRunsLoopback() {
        XCTAssertNotNil(EngineSuggest.url(for: "a", engine: .google, test: "http://127.0.0.1:9/s?q=%s"))
        XCTAssertNotNil(EngineSuggest.url(for: "a", engine: .google, test: "http://localhost:9/s?q=%s"))
        XCTAssertNil(EngineSuggest.url(for: "a", engine: .google, test: "http://example.com/s?q=%s"))
        XCTAssertNil(EngineSuggest.url(for: "a", engine: .google, test: "ftp://127.0.0.1/s?q=%s"))
        XCTAssertNil(EngineSuggest.url(for: "a", engine: .google, test: "file:///tmp/%s"))
    }

    // MARK: - what may leave the Mac

    func testPlainWordsAreSent() {
        for words in ["coffee", "coffee shop near me", "café crème", "iphone 15 pro", "how to tie a tie",
                      "what is node.js", "c++ tutorial", "東京 天気", "re: meeting notes", "10:30 train"] {
            XCTAssertTrue(EngineSuggest.sendable(words), words)
        }
    }

    func testAddressesAreNeverSent() {
        for address in ["https://example.com", "http://x", "example.com", "www.apple.com/mac", "localhost",
                        "localhost:3000", "127.0.0.1", "192.168.1.1:8080", "[::1]:3000", "mailto:me@x.com",
                        "javascript:alert(1)", "about:blank", "data:text/html,x", "file:///etc/hosts",
                        "node.js", "a/b", "foo.bar", "ftp://files", "chrome-extension://abc"] {
            XCTAssertFalse(EngineSuggest.sendable(address), address)
        }
    }

    func testPathsAreNeverSent() {
        for path in ["/Users/drice/Documents/taxes.pdf", "~/Desktop", "./build.sh", "../secret",
                     "C:\\Users\\x", "src/main.swift"] {
            XCTAssertFalse(EngineSuggest.sendable(path), path)
        }
    }

    func testSecretsAndPersonalDetailsAreNeverSent() {
        for secret in ["hunter2hunter2x", "sk-proj-4f9aX2kQ7", fakeToken,
                       "AKIAIOSFODNN7EXAMPLE", "correcthorsebatterystaplecorrecthorse",
                       "4111111111111111", "4111-1111-1111-1111", "my password is Tr0ub4dor&3xyzzy",
                       "drice@officecommun.com", "write to me@example.org", "line one\nline two",
                       String(repeating: "word ", count: 17)] {
            XCTAssertFalse(EngineSuggest.sendable(secret), secret)
        }
    }

    func testEmptyIsNeverSent() {
        for blank in ["", " ", "\n", "\t "] { XCTAssertFalse(EngineSuggest.sendable(blank)) }
    }

    // MARK: - when the field asks

    func testTheFieldAsksOnlyWhenOnAndNeverInPrivate() throws {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        defer {
            browser.prefs.engineSuggests = false
            browser.closeAll()
        }
        browser.prefs.engine = .duckduckgo
        browser.prefs.engineSuggests = false
        XCTAssertNil(browser.engineQuestion(for: "coffee"), "off by default: nothing asked")

        browser.prefs.engineSuggests = true
        let question = try XCTUnwrap(browser.engineQuestion(for: "coffee"))
        XCTAssertEqual(question.host(), "duckduckgo.com")
        XCTAssertNil(browser.engineQuestion(for: "example.com"))
        XCTAssertNil(browser.engineQuestion(for: fakeToken))

        browser.prefs.engine = .custom
        XCTAssertNil(browser.engineQuestion(for: "coffee"), "a custom engine has nowhere to ask")
        browser.prefs.engine = .duckduckgo

        browser.newShyTab()
        XCTAssertEqual(browser.active?.shy, true)
        XCTAssertNil(browser.engineQuestion(for: "coffee"), "a private tab never asks")
    }

    func testAKeywordIsNotAskedAbout() {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        let kept = browser.prefs.keywords
        defer {
            browser.prefs.keywords = kept
            browser.prefs.engineSuggests = false
            browser.closeAll()
        }
        browser.prefs.engineSuggests = true
        browser.prefs.engine = .google
        browser.prefs.keywords = [Keyword(keyword: "yt", template: "https://www.youtube.com/results?search_query=%s")]
        XCTAssertNil(browser.engineQuestion(for: "yt cats"), "a shortcut's words go to its site, not the engine")
        XCTAssertNotNil(browser.engineQuestion(for: "cats"))
    }

    // MARK: - a site in the field

    func testAChipIsAskedOnlyWhenItIsYourEngine() throws {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        defer {
            browser.siteChip = nil
            browser.prefs.engineSuggests = false
            browser.closeAll()
        }
        let google = SearchSite(name: "Google", host: "google.com", template: "https://www.google.com/search?q=%s")
        browser.prefs.engine = .google
        browser.prefs.engineSuggests = true
        browser.siteChip = google
        XCTAssertEqual(try XCTUnwrap(browser.engineQuestion(for: "coffee")).host(), "suggestqueries.google.com",
                       "Google in the field, and Google is yours: asked")
        XCTAssertNotNil(browser.engineQuestion(for: "yt cats"), "after a chip, a shortcut's word is only words")
        browser.siteChip = SearchSite(name: "Reddit", host: "reddit.com", template: "https://www.reddit.com/search/?q=%s")
        XCTAssertNil(browser.engineQuestion(for: "coffee"), "words typed to Reddit never go to the engine")
        browser.prefs.engine = .duckduckgo
        browser.siteChip = google
        XCTAssertNil(browser.engineQuestion(for: "coffee"), "Google in the field isn't your engine: nothing asked")
        browser.prefs.engine = .google
        browser.prefs.engineSuggests = false
        XCTAssertNil(browser.engineQuestion(for: "coffee"), "off is off, chip or not")
    }

    func testPastSearchesAreReadBackFromHistory() {
        func trace(_ address: String) -> History.Trace {
            History.Trace(key: address, address: address, title: "", url: URL(string: address)!, last: Date(), count: 1)
        }
        let reddit = SearchSite(name: "Reddit", host: "reddit.com", template: "https://www.reddit.com/search/?q=%s")
        let traces = [
            trace("https://www.reddit.com/search/?q=naruto%20ending&type=link"),
            trace("https://reddit.com/search?q=naruto+vs+one+piece"),
            trace("https://www.reddit.com/r/Naruto/search/?q=naruto%20art"),
            trace("https://www.reddit.com/search/?q=Naruto%20ending"),
            trace("https://www.reddit.com/search/?q=boruto"),
            trace("https://evil.example/search/?q=naruto%20elsewhere"),
            trace("https://www.reddit.com/search/?q=naruto"),
        ]
        XCTAssertEqual(SiteSearch.pastSearches(on: reddit, in: traces),
                       ["naruto ending", "naruto vs one piece", "boruto", "naruto"],
                       "Reddit's own search only, each once, newest first; a subreddit's or another site's isn't")
        XCTAssertEqual(SiteSearch.words(in: URL(string: "https://www.google.com/search?q=naruto+shippuden&sca_esv=1")!,
                                        searchedOn: SearchSite(name: "Google", host: "google.com",
                                                               template: "https://www.google.com/search?q=%s")),
                       "naruto shippuden", "a page's other parameters don't matter")
        XCTAssertNil(SiteSearch.words(in: URL(string: "https://www.reddit.com/r/Naruto/")!, searchedOn: reddit))
        let spotify = SearchSite(name: "Spotify", host: "open.spotify.com", template: "https://open.spotify.com/search/%s")
        XCTAssertEqual(SiteSearch.pastSearches(on: spotify, in: [trace("https://open.spotify.com/search/daft%20punk"),
                                                                   trace("https://open.spotify.com/search/daft%20punk/albums")]),
                       ["daft punk"], "words at the end of the path, and only there")
    }
}
