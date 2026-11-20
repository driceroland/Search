import AppKit
import WebKit
import XCTest
@testable import Search

@MainActor
final class BlockedPopupsTests: XCTestCase {
    private var browser: Browser!

    override class func setUp() {
        setenv("SEARCH_PROBE", "blocked-popups-\(getpid())", 1)
        super.setUp()
    }

    override func setUp() {
        _ = NSApplication.shared
        browser = Browser(record: WindowRecord())
        browser.prefs.popupSites = []
    }

    override func tearDown() {
        browser.closeAll()
        browser.prefs.popupSites = []
        browser = nil
    }

    private func tab(_ url: String, privateMode: Bool = false) -> Tab {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let tab = Tab(shy: privateMode, configuration: configuration)
        tab.setAddressOptimistically(URL(string: url)!)
        return tab
    }

    func testOnlyWebAddressesCanBeOpened() {
        XCTAssertNotNil(BlockedPopups.openable(URL(string: "https://hark.com/a?b=1")))
        XCTAssertNotNil(BlockedPopups.openable(URL(string: "http://127.0.0.1:8080/x")))
        for refused in ["javascript:alert(1)", "data:text/html,hi", "blob:https://hark.com/1234",
                        "file:///etc/hosts", "about:blank", "about:srcdoc", "ftp://example.com/", "https://"] {
            XCTAssertNil(BlockedPopups.openable(URL(string: refused)), refused)
        }
        XCTAssertNil(BlockedPopups.openable(nil))
    }

    func testSiteIsTheRegistrableDomainOfAWebPage() {
        XCTAssertEqual(BlockedPopups.site(of: URL(string: "https://app.hark.com/chat")), "hark.com")
        XCTAssertEqual(BlockedPopups.site(of: URL(string: "https://www.bbc.co.uk/")), "bbc.co.uk")
        XCTAssertEqual(BlockedPopups.site(of: URL(string: "http://127.0.0.1:9000/")), "127.0.0.1")
        XCTAssertNil(BlockedPopups.site(of: URL(string: "file:///Users/x/a.html")))
        XCTAssertNil(BlockedPopups.site(of: URL(string: "about:blank")))
        XCTAssertNil(BlockedPopups.site(scheme: "https", host: ""))
    }

    func testAllowedSiteOnlyForItsOwnPageAndSameSiteFrames() {
        let sites: Set<String> = ["hark.com"]
        let top = URL(string: "https://app.hark.com/chat")
        XCTAssertTrue(BlockedPopups.allows(sites, top: top, frameScheme: "https", frameHost: "app.hark.com"))
        XCTAssertTrue(BlockedPopups.allows(sites, top: top, frameScheme: "https", frameHost: "cdn.hark.com"))
        // A frame of another site on the allowed page: still needs a click.
        XCTAssertFalse(BlockedPopups.allows(sites, top: top, frameScheme: "https", frameHost: "ads.example.net"))
        XCTAssertFalse(BlockedPopups.allows(sites, top: top, frameScheme: "https", frameHost: "hark.com.evil.net"))
        // A sandboxed frame's opaque origin has no host.
        XCTAssertFalse(BlockedPopups.allows(sites, top: top, frameScheme: "", frameHost: ""))
        // The allowed site's frame on a page of another site.
        XCTAssertFalse(BlockedPopups.allows(sites, top: URL(string: "https://example.com"), frameScheme: "https", frameHost: "hark.com"))
        XCTAssertFalse(BlockedPopups.allows([], top: top, frameScheme: "https", frameHost: "app.hark.com"))
        XCTAssertFalse(BlockedPopups.allows(sites, top: nil, frameScheme: "https", frameHost: "app.hark.com"))
    }

    func testListKeepsAFewOncePerAddress() {
        var list: [BlockedPopup] = []
        for n in 1...7 { list = BlockedPopups.noting(URL(string: "https://a.com/\(n)"), in: list) ?? list }
        XCTAssertEqual(list.map { $0.url?.lastPathComponent }, ["3", "4", "5", "6", "7"])
        XCTAssertNil(BlockedPopups.noting(URL(string: "https://a.com/7"), in: list))
        // A window with no address (window.open() to write into) is noted once.
        let blank = BlockedPopups.noting(nil, in: [])!
        XCTAssertEqual(blank.count, 1)
        XCTAssertNil(blank[0].url)
        XCTAssertNil(BlockedPopups.noting(URL(string: ""), in: blank))
    }

    func testSpentOnlyAfterTheInteractionHadItsWindow() {
        var gesture = PopupGesture()
        XCTAssertFalse(gesture.spent(now: 1))
        gesture.record(origin: "https://a.com:443", kind: "click", now: 1)
        XCTAssertFalse(gesture.spent(now: 2))
        XCTAssertTrue(gesture.take(origin: "https://a.com:443", mainFrame: true, now: 2))
        XCTAssertTrue(gesture.spent(now: 3))
        XCTAssertFalse(gesture.spent(now: 7))
        var claimed = PopupGesture()
        claimed.record(origin: "https://a.com:443", kind: "click", now: 1)
        XCTAssertNil(claimed.claim(now: 1.5))
        XCTAssertTrue(claimed.spent(now: 2))
    }

    /// #1243: the middle button grants one window as any press does, and
    /// says it goes behind; the next press of another kind says otherwise.
    func testMiddlePressGrantsOneWindowBehind() {
        var gesture = PopupGesture()
        gesture.record(origin: "https://a.com:443", kind: "middle", now: 1)
        XCTAssertTrue(gesture.middle)
        XCTAssertTrue(gesture.take(origin: "https://a.com:443", mainFrame: true, now: 1.2))
        XCTAssertFalse(gesture.take(origin: "https://a.com:443", mainFrame: true, now: 1.3))
        gesture.record(origin: "https://a.com:443", kind: "input", now: 2)
        XCTAssertFalse(gesture.middle)
        gesture.record(origin: "https://a.com:443", kind: "middle", now: 3)
        gesture.record(origin: "https://a.com:443", kind: "click", now: 3.1)
        XCTAssertTrue(gesture.middle)
    }

    func testAlwaysAllowIsSavedFromANormalTabAndClearsTheSign() {
        let page = tab("https://app.hark.com/chat")
        page.noteBlocked(URL(string: "https://app.hark.com/answer/1"))
        XCTAssertEqual(page.blockedPopups.count, 1)
        browser.allowPopups(from: page)
        XCTAssertEqual(browser.prefs.popupSites, ["hark.com"])
        XCTAssertEqual(Preferences().popupSites, ["hark.com"])
        XCTAssertTrue(page.blockedPopups.isEmpty)
        browser.prefs.popupSites.remove("hark.com")
        XCTAssertTrue(Preferences().popupSites.isEmpty)
    }

    func testPrivateTabAllowsOnlyForItselfAndWritesNothing() {
        let page = tab("https://app.hark.com/chat", privateMode: true)
        page.noteBlocked(URL(string: "https://app.hark.com/answer/1"))
        browser.allowPopups(from: page)
        XCTAssertEqual(page.popupSites, ["hark.com"])
        XCTAssertTrue(browser.prefs.popupSites.isEmpty)
        XCTAssertTrue(Preferences().popupSites.isEmpty)
        // But the saved list does apply in a private tab.
        browser.prefs.popupSites = ["example.com"]
        XCTAssertTrue(BlockedPopups.allows(browser.prefs.popupSites.union(tab("https://example.com", privateMode: true).popupSites),
                                           top: URL(string: "https://example.com"), frameScheme: "https", frameHost: "example.com"))
    }

    func testOpenMakesAPlainTabAtTheAddressWithNoOpener() throws {
        let page = tab("https://app.hark.test/chat")
        page.noteBlocked(URL(string: "javascript:alert(1)"))
        page.noteBlocked(URL(string: "https://app.hark.test/answer/2"))
        let refused = page.blockedPopups[0]
        XCTAssertNil(browser.openBlocked(refused, from: page))
        XCTAssertEqual(page.blockedPopups.count, 1)
        let opened = try XCTUnwrap(browser.openBlocked(page.blockedPopups[0], from: page))
        XCTAssertEqual(opened.address?.absoluteString, "https://app.hark.test/answer/2")
        XCTAssertNil(opened.opener)
        XCTAssertFalse(opened.shy)
        XCTAssertEqual(browser.activeID, opened.id)
        XCTAssertTrue(page.blockedPopups.isEmpty)
    }

    func testOpenFromAPrivateTabIsPrivate() throws {
        let page = tab("https://example.test", privateMode: true)
        page.noteBlocked(URL(string: "https://example.test/pop"))
        let opened = try XCTUnwrap(browser.openBlocked(page.blockedPopups[0], from: page))
        XCTAssertTrue(opened.shy)
        XCTAssertNil(opened.opener)
    }

    func testANewPageClearsTheList() {
        let page = tab("https://example.com")
        page.noteBlocked(URL(string: "https://example.com/pop"))
        page.didCommit()
        XCTAssertTrue(page.blockedPopups.isEmpty)
    }
}
