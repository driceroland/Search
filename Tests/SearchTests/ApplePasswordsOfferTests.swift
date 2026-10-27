import AppKit
import XCTest
@testable import Search

/// "Use your Apple passwords?" under a sign-in box (Drice, 25 Oct 2026): off
/// by default, offered once per site where Search keeps nothing, never again
/// after two unanswered or one ✕, never where it must not be. Apple's helper
/// is never run: the pairing it starts is a stand-in's.
@MainActor
final class ApplePasswordsOfferTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "bld-ai-offer-\(getpid())", 1)
        super.setUp()
    }

    private var suite = ""
    private var store: UserDefaults!

    override func setUp() {
        _ = NSApplication.shared
        suite = "bld-ai-offer-store-\(getpid())"
        store = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        store.removePersistentDomain(forName: suite)
        ApplePasswordsOffer.benchAsks = false
        ApplePasswordsOffer.benchHelper = nil
    }

    private let page = URL(string: "https://accounts.example.com/login")!
    /// As a person would have it: no test run, the helper there.
    private let person = ApplePasswordsOffer.Settings()

    private func field(_ url: URL? = nil, privateTab: Bool = false, frame: String? = nil,
                       passwords: Bool = true, kept: Int = 0) -> ApplePasswordsOffer.Field {
        .init(page: url ?? page, privateTab: privateTab, frameHost: frame, passwords: passwords, kept: kept)
    }

    // MARK: - where

    func testOfferedOnAnHttpsPageWithNothingKept() {
        let offer = ApplePasswordsOffer(store: store)
        XCTAssertEqual(offer.site(for: field(), person), "example.com")
        // A frame of the page's own site is the page's.
        XCTAssertEqual(offer.site(for: field(frame: "login.example.com"), person), "example.com")
    }

    func testNeverWhereItMustNotBe() {
        let offer = ApplePasswordsOffer(store: store)
        XCTAssertNil(offer.site(for: field(kept: 1), person), "an account of Search's own for the site")
        XCTAssertNil(offer.site(for: field(privateTab: true), person), "a private tab")
        XCTAssertNil(offer.site(for: field(URL(string: "http://accounts.example.com/login")), person), "http")
        XCTAssertNil(offer.site(for: field(frame: "auth.other.test"), person), "a frame of another site")
        XCTAssertNil(offer.site(for: field(passwords: false), person), "a box for passkeys alone")
        XCTAssertNil(offer.site(for: field(URL(string: "file:///tmp/login.html")), person))
        XCTAssertNil(offer.site(for: field(URL(string: "chrome-extension://abc/popup.html")), person))
        var settings = person
        settings.appleOn = true
        XCTAssertNil(offer.site(for: field(), settings), "already on")
        settings = person
        settings.fills = false
        XCTAssertNil(offer.site(for: field(), settings), "filling turned off")
        settings = person
        settings.helper = false
        XCTAssertNil(offer.site(for: field(), settings), "no helper on this Mac (or macOS before 15.4)")
        XCTAssertTrue(offer.offered.isEmpty, "asking writes nothing down")
    }

    func testNeverInATestRunUnlessTheBenchAsks() {
        let offer = ApplePasswordsOffer(store: store)
        var settings = person
        settings.testRun = true
        XCTAssertNil(offer.site(for: field(), settings))
        settings.benchAsks = true
        XCTAssertEqual(offer.site(for: field(), settings), "example.com")
    }

    // MARK: - how often

    func testOncePerSite() {
        let offer = ApplePasswordsOffer(store: store)
        offer.shown(on: "example.com")
        XCTAssertNil(offer.site(for: field(), person))
        XCTAssertNil(offer.site(for: field(URL(string: "https://www.example.com/")), person), "the same site, another host")
        XCTAssertEqual(offer.site(for: field(URL(string: "https://bank.test/")), person), "bank.test")
    }

    func testTwiceUnansweredAndItStops() {
        let offer = ApplePasswordsOffer(store: store)
        offer.unanswered()
        XCTAssertFalse(offer.retired)
        XCTAssertEqual(offer.site(for: field(), person), "example.com")
        offer.unanswered()
        XCTAssertTrue(offer.retired)
        XCTAssertNil(offer.site(for: field(URL(string: "https://bank.test/")), person))
    }

    func testTheCrossStopsItAtOnce() {
        let offer = ApplePasswordsOffer(store: store)
        offer.dismissed()
        XCTAssertTrue(offer.retired)
        XCTAssertNil(offer.site(for: field(), person))
        offer.forget()
        XCTAssertEqual(offer.site(for: field(), person), "example.com")
    }

    func testTheHelperIsNeverRunFromATest() async {
        // The default connection, in a test run, refuses before running
        // anything: Apple's helper would show its window on a real screen.
        let apple = ApplePasswords()
        await apple.connect()
        XCTAssertEqual(apple.state, .idle)
        XCTAssertEqual(apple.trouble, "Apple's Passwords helper isn't run in a test")
    }

    // MARK: - the row in the list

    private func browser() -> Browser {
        let browser = Browser(record: WindowRecord())
        browser.applePasswordsOffer = ApplePasswordsOffer(store: store)
        let link = StandInLink()
        browser.applePasswords = ApplePasswords(makeLink: { link })
        browser.applePasswords.standIn = link
        return browser
    }

    func testClickingTurnsItOnAndPairs() async throws {
        let browser = browser()
        defer { browser.closeAll(); browser.prefs.applePasswords = false }
        browser.prefs.applePasswords = false
        let tab = UUID()
        browser.testOffer(on: tab, site: "example.com")
        XCTAssertEqual(browser.suggesting?.appleOffer, "example.com")
        XCTAssertEqual(browser.applePasswordsOffer.offered, ["example.com"])
        browser.useApplePasswords()
        XCTAssertNil(browser.suggesting)
        XCTAssertTrue(browser.prefs.applePasswords, "the switch is on")
        XCTAssertEqual(browser.applePairing?.tab, tab, "the pairing card where the list was")
        try await settle { (browser.applePasswords.standIn as? StandInLink)?.starts == 1 }
        // Taken, not ignored.
        XCTAssertEqual(store.integer(forKey: ApplePasswordsOffer.unansweredKey), 0)
        XCTAssertFalse(browser.applePasswordsOffer.retired)
    }

    func testAClickTooSoonIsNotAChoice() {
        let browser = browser()
        defer { browser.closeAll(); browser.prefs.applePasswords = false }
        browser.prefs.applePasswords = false
        browser.testOffer(on: UUID(), site: "example.com", age: 0)
        browser.useApplePasswords()
        browser.neverOfferApplePasswords()
        XCTAssertNotNil(browser.suggesting?.appleOffer)
        XCTAssertFalse(browser.prefs.applePasswords)
        XCTAssertFalse(browser.applePasswordsOffer.retired)
    }

    func testTheCrossInTheList() {
        let browser = browser()
        defer { browser.closeAll() }
        browser.testOffer(on: UUID(), site: "example.com")
        browser.neverOfferApplePasswords()
        XCTAssertNil(browser.suggesting, "the offer alone: the list goes with it")
        XCTAssertTrue(store.bool(forKey: ApplePasswordsOffer.neverKey))
        XCTAssertEqual(store.integer(forKey: ApplePasswordsOffer.unansweredKey), 0, "a ✕ is an answer")
        XCTAssertFalse(browser.prefs.applePasswords)
        XCTAssertNil(browser.applePairing)
    }

    func testLeftUnansweredIsCounted() {
        let browser = browser()
        defer { browser.closeAll() }
        browser.testOffer(on: UUID(), site: "example.com")
        browser.testOffer(on: nil)
        XCTAssertEqual(store.integer(forKey: ApplePasswordsOffer.unansweredKey), 1)
        browser.testOffer(on: UUID(), site: "bank.test")
        browser.testOffer(on: nil)
        XCTAssertTrue(browser.applePasswordsOffer.retired)
        XCTAssertNil(browser.applePasswordsOffer.site(for: field(URL(string: "https://third.test/")), person))
        XCTAssertEqual(browser.applePasswordsOffer.offered, ["bank.test", "example.com"])
    }

    private func settle(_ done: () -> Bool) async throws {
        for _ in 0..<100 where !done() { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(done())
    }
}
