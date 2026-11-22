import AppKit
import XCTest
@testable import Search

/// The accounts under a sign-in box from the keyboard: ↓ and ↑ light a row,
/// Return takes it as a click would. Until a row is lit, Return and ↑ stay the
/// page's.
@MainActor
final class AccountListKeysTests: XCTestCase {
    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    private var suite = ""
    private var store: UserDefaults!

    override func setUp() {
        _ = NSApplication.shared
        suite = "bld-account-keys-store-\(getpid())"
        store = UserDefaults(suiteName: suite)
    }

    override func tearDown() { store.removePersistentDomain(forName: suite) }

    private func browser() -> Browser {
        let browser = Browser(record: WindowRecord())
        browser.applePasswordsOffer = ApplePasswordsOffer(store: store)
        let link = StandInLink()
        browser.applePasswords = ApplePasswords(makeLink: { link })
        browser.applePasswords.standIn = link
        return browser
    }

    /// Two of Apple Passwords' accounts, one of this host's own and one of
    /// its site's, unless `apple` says none yet.
    private func list(on tab: UUID, offer: Bool = false, apple: Bool = true) -> Browser.Suggesting {
        var list = Browser.Suggesting(
            tab: tab, spot: CGRect(x: 40, y: 120, width: 280, height: 30),
            host: "mail.example.com", clear: false, appleOffer: offer ? "example.com" : nil)
        if apple {
            list.apple = [AppleLogin(user: "cat", sites: ["mail.example.com"]), AppleLogin(user: "dan", sites: ["example.com"])]
            list.appleHost = "mail.example.com"
        }
        list.shown = Date().addingTimeInterval(-1)
        return list
    }

    func testTheRowsInTheOrderTheyAreDrawn() {
        let list = list(on: UUID(), offer: true)
        XCTAssertEqual(list.choices, [
            .apple(AppleLogin(user: "cat", sites: ["mail.example.com"])),
            .apple(AppleLogin(user: "dan", sites: ["example.com"])),
            .offer,
        ])
        XCTAssertEqual(list.othersFrom, 1, "the rest of the site's under a line")
    }

    func testArrowsMoveTheLight() {
        let browser = browser()
        defer { browser.closeAll() }
        let tab = UUID()
        browser.activeID = tab
        browser.testSuggest(list(on: tab, offer: true))
        XCTAssertFalse(browser.moveChoice(by: -1), "↑ with nothing lit is the page's")
        XCTAssertFalse(browser.takeLitChoice(), "Return with nothing lit is the page's")
        XCTAssertTrue(browser.moveChoice(by: 1))
        XCTAssertEqual(browser.suggesting?.lit, 0)
        XCTAssertTrue(browser.moveChoice(by: 1))
        XCTAssertTrue(browser.moveChoice(by: 1))
        XCTAssertTrue(browser.moveChoice(by: 1))
        XCTAssertEqual(browser.suggesting?.lit, 2, "↓ on the last stays there")
        XCTAssertTrue(browser.moveChoice(by: -1))
        XCTAssertTrue(browser.moveChoice(by: -1))
        XCTAssertEqual(browser.suggesting?.lit, 0)
        XCTAssertTrue(browser.moveChoice(by: -1), "↑ from the first is the list's: back to the box")
        XCTAssertNil(browser.suggesting?.lit)
    }

    func testOnlyTheTabInFront() {
        let browser = browser()
        defer { browser.closeAll() }
        browser.activeID = UUID()
        browser.testSuggest(list(on: UUID()))
        XCTAssertFalse(browser.moveChoice(by: 1))
        XCTAssertNil(browser.suggesting?.lit)
    }

    func testReturnTakesTheRowLit() async throws {
        let browser = browser()
        defer { browser.closeAll(); browser.prefs.applePasswords = false }
        browser.prefs.applePasswords = false
        let tab = UUID()
        browser.activeID = tab
        var up = list(on: tab, offer: true)
        // Just up: a click would be refused, a row come to with the arrows isn't.
        up.shown = Date()
        browser.testSuggest(up)
        for _ in 0..<3 { _ = browser.moveChoice(by: 1) }
        XCTAssertEqual(browser.suggesting?.choices[browser.suggesting?.lit ?? 0], .offer)
        XCTAssertTrue(browser.takeLitChoice())
        XCTAssertNil(browser.suggesting)
        XCTAssertTrue(browser.prefs.applePasswords, "as a click on the offer")
        XCTAssertEqual(browser.applePairing?.tab, tab)
        browser.endApplePairing(paired: false)
    }

    func testTheLightStaysOnItsRowAsRowsJoin() {
        let browser = browser()
        defer { browser.closeAll() }
        let tab = UUID()
        browser.activeID = tab
        var first = list(on: tab, apple: false)
        first.apple = [AppleLogin(user: "dan", sites: ["example.com"])]
        first.appleHost = "mail.example.com"
        browser.testSuggest(first)
        _ = browser.moveChoice(by: 1)
        XCTAssertEqual(browser.suggesting?.lit, 0)
        // Apple Passwords answers: one of this host's own, above dan's.
        var joined = try! XCTUnwrap(browser.suggesting)
        joined.apple = [AppleLogin(user: "cat", sites: ["mail.example.com"]), AppleLogin(user: "dan", sites: ["example.com"])]
        browser.testSuggest(joined)
        XCTAssertEqual(browser.suggesting?.lit, 1)
        XCTAssertEqual(browser.suggesting?.choices[1], .apple(AppleLogin(user: "dan", sites: ["example.com"])))
    }
}
