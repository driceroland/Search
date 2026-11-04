import AppKit
import WebKit
import XCTest
@testable import Search

/// Which tab a page's notification names and a click on it brings forward
/// (#776). Only the choice: what shows a tab and brings the app forward is never
/// run here, no window is made, and no page is loaded.
@MainActor
final class NotificationTabTests: XCTestCase {
    private static let world = "notification-tab-\(getpid())"
    private let site = "https://chat.example"
    private var browsers: [Browser] = []

    override class func setUp() {
        setenv("SEARCH_PROBE", world, 1)
        super.setUp()
    }

    override class func tearDown() {
        Disk.drain()
        if Store.world == world {
            try? FileManager.default.removeItem(at: Store.folder)
            UserDefaults(suiteName: "com.officecommun.search.test.\(world)")?.removePersistentDomain(forName: "com.officecommun.search.test.\(world)")
        }
        super.tearDown()
    }

    override func setUp() async throws {
        try await super.setUp()
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        // A new window starts with the row last saved, and a saved tab in
        // front would load: each test starts from none, and leaves none.
        Session.write(now: true, Session.Shape(tabs: [], active: 0))
    }

    override func tearDown() async throws {
        for browser in browsers { browser.closeAll() }
        browsers = []
        Session.write(now: true, Session.Shape(tabs: [], active: 0))
        XCTAssertTrue(NSApp.windows.allSatisfy { !$0.isVisible }, "a window was shown")
        XCTAssertFalse(NSApp.isActive, "the app came forward")
        try await super.tearDown()
    }

    /// A window that is never put on a screen.
    private func window() -> Browser {
        let browser = Browser(record: WindowRecord())
        browsers.append(browser)
        return browser
    }

    private func go(_ tab: Search.Tab, to address: String) throws {
        tab.restore(url: try XCTUnwrap(URL(string: address)), title: "A page")
    }

    /// A new tab at an address, in the row. Given the address once it is the
    /// one in front, as selecting a tab that has one starts to load it.
    private func tab(in browser: Browser, at address: String) throws -> Search.Tab {
        browser.newTab()
        let tab = try XCTUnwrap(browser.active)
        try go(tab, to: address)
        return tab
    }

    /// What a click finds: the notification as it was posted.
    private func chosen(tab id: String? = nil, from store: WKWebsiteDataStore?) -> (Browser, Search.Tab)? {
        var info: [AnyHashable: Any] = ["search.kind": "page", "search.id": "1", "search.origin": site]
        if let id { info[SiteNotifications.senderKey] = id }
        return SiteNotifications.tabToBringForward(info, from: store, among: browsers)
    }

    /// What is posted, not just what a click does with it: built from the
    /// page's own web view, it leads back to that tab, either of the two.
    func testANotificationNamesTheTabOfThePageThatSentIt() throws {
        let browser = window()
        let first = try tab(in: browser, at: "https://chat.example/one")
        let second = try tab(in: browser, at: "https://chat.example/two")
        for sender in [first, second] {
            let info = PageNotifications.info(id: 1, origin: site, web: sender.web, among: browsers)
            XCTAssertEqual(info[SiteNotifications.senderKey] as? String, sender.id.uuidString)
            XCTAssertTrue(SiteNotifications.tabToBringForward(info, from: sender.store, among: browsers)?.1 === sender)
            // On a test run this keeps what it would have posted, for the bench.
            SiteNotifications.shared.post(id: "page|1", title: "A title", body: "", origin: site, tag: "", info: info)
            XCTAssertEqual(SiteNotifications.shared.recorded.last?["tab"], sender.id.uuidString)
        }
    }

    func testAPageInNoTabNamesNone() throws {
        let browser = window()
        let first = try tab(in: browser, at: "https://chat.example/one")
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let info = PageNotifications.info(id: 1, origin: site, web: WKWebView(frame: .zero, configuration: configuration), among: browsers)
        XCTAssertEqual(info[SiteNotifications.senderKey] as? String, "")
        XCTAssertTrue(SiteNotifications.tabToBringForward(info, from: first.store, among: browsers)?.1 === first)
    }

    func testTheTabThatSentItIsChosenAndNotTheFirst() throws {
        let browser = window()
        let first = try tab(in: browser, at: "https://chat.example/one")
        let second = try tab(in: browser, at: "https://chat.example/two")
        let third = try tab(in: browser, at: "https://chat.example/three")
        XCTAssertTrue(chosen(tab: second.id.uuidString, from: second.store)?.1 === second)
        XCTAssertTrue(chosen(tab: third.id.uuidString, from: third.store)?.1 === third)
        XCTAssertTrue(chosen(tab: first.id.uuidString, from: first.store)?.1 === first)
    }

    func testASenderOnAnotherSiteNowFallsBackToTheFirstStillThere() throws {
        let browser = window()
        let first = try tab(in: browser, at: "https://chat.example/one")
        let sender = try tab(in: browser, at: "https://chat.example/two")
        try go(sender, to: "https://elsewhere.example/")
        XCTAssertTrue(chosen(tab: sender.id.uuidString, from: sender.store)?.1 === first)
    }

    func testASenderThatWasClosedFallsBackToTheFirstStillThere() throws {
        let browser = window()
        let first = try tab(in: browser, at: "https://chat.example/one")
        let sender = try tab(in: browser, at: "https://chat.example/two")
        browser.receive(Search.Tab()) // In front, so closing the sender selects nothing that would load.
        let id = sender.id.uuidString, store = sender.store
        browser.close(sender)
        XCTAssertFalse(browser.tabs.contains { $0 === sender })
        XCTAssertTrue(chosen(tab: id, from: store)?.1 === first)
    }

    /// A service worker's notification names no tab, and a page in no tab of
    /// a window, a peek, names none either: the first tab on the site.
    func testNoTabInTheNotificationLeavesTheChoiceAsItWas() throws {
        let browser = window()
        let first = try tab(in: browser, at: "https://chat.example/one")
        let second = try tab(in: browser, at: "https://chat.example/two")
        XCTAssertTrue(chosen(from: second.store)?.1 === first)
        XCTAssertTrue(chosen(from: nil)?.1 === first, "no store known either")
        XCTAssertTrue(chosen(tab: "", from: second.store)?.1 === first)
    }

    /// Tab ids are made at launch: one from before a restart matches nothing.
    func testAnIDFromBeforeARestartFallsBack() throws {
        let browser = window()
        let first = try tab(in: browser, at: "https://chat.example/one")
        _ = try tab(in: browser, at: "https://chat.example/two")
        XCTAssertTrue(chosen(tab: UUID().uuidString, from: nil)?.1 === first)
    }

    func testASenderMovedToAnotherWindowIsStillFound() throws {
        let from = window(), to = window()
        let first = try tab(in: from, at: "https://chat.example/one")
        // Taken across blank and not in front: nothing selected along the
        // way has an address to load. It gets its address on arriving.
        let sender = Search.Tab()
        from.receive(sender)
        from.receive(Search.Tab())
        from.moveToWindow(sender, to)
        XCTAssertTrue(to.tabs.contains { $0 === sender })
        XCTAssertFalse(from.tabs.contains { $0 === sender })
        try go(sender, to: "https://chat.example/two")
        XCTAssertTrue(first.store === sender.store, "so only being the sender can tell them apart")
        let found = chosen(tab: sender.id.uuidString, from: sender.store)
        XCTAssertTrue(found?.0 === to, "the window it is in now, to select it there")
        XCTAssertTrue(found?.1 === sender)
    }

    /// Moved to a window of another space since it sent, the sender uses that
    /// space's store, and the first tab still has the one it sent with.
    func testASenderOnAnotherStoreOfItsProfileIsStillFound() throws {
        let browser = window()
        let first = try tab(in: browser, at: "https://chat.example/one")
        // A bench tab, as any other is put back on the window's store. Its id
        // is fixed: WebKit keeps a folder per id outside the test world, so
        // runs share one rather than leave a new one each.
        let id = try XCTUnwrap(UUID(uuidString: "07760776-0776-4776-8776-077607760776"))
        let sender = Search.Tab(bench: true, configuration: Web.configuration(store: WKWebsiteDataStore(forIdentifier: id)))
        browser.receive(sender)
        try go(sender, to: "https://chat.example/two")
        XCTAssertFalse(first.store === sender.store)
        XCTAssertTrue(chosen(tab: sender.id.uuidString, from: first.store)?.1 === sender)
    }

    func testAPrivateTabIsNeverChosenEvenAsTheSender() throws {
        let browser = window()
        let first = try tab(in: browser, at: "https://chat.example/one")
        let hidden = Search.Tab(shy: true)
        browser.receive(hidden)
        try go(hidden, to: "https://chat.example/two")
        XCTAssertTrue(chosen(tab: hidden.id.uuidString, from: first.store)?.1 === first)
    }

    /// A store this window's profile doesn't hold stands for another
    /// profile's: nothing here is signed in as that person, the sender
    /// included, and nothing is brought forward.
    func testASenderOfAnotherProfileIsNeverChosen() throws {
        let browser = window()
        let sender = try tab(in: browser, at: "https://chat.example/one")
        XCTAssertNil(chosen(tab: sender.id.uuidString, from: .nonPersistent()))
    }

    func testNothingOnTheSiteChoosesNothing() throws {
        let browser = window()
        let sender = try tab(in: browser, at: "https://elsewhere.example/")
        XCTAssertNil(chosen(tab: sender.id.uuidString, from: sender.store))
    }
}
