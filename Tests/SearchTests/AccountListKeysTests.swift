import AppKit
import XCTest
@testable import Search

/// The list under a box from the keyboard: ↓ and ↑ light a row, Return takes
/// it as a click would. Until a row is lit, Return and ↑ stay the page's.
@MainActor
final class AccountListKeysTests: XCTestCase {
    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    override func setUp() { _ = NSApplication.shared }

    private func browser() -> Browser { Browser(record: WindowRecord()) }

    private func offer(_ id: String) -> MeCard.Offer {
        MeCard.Offer(id: id, title: id + "@example.com", detail: "Home", fields: ["email": id + "@example.com"])
    }

    /// A list of rows of your card, hung under a box on `tab`.
    private func list(on tab: UUID, rows: [String] = ["ann", "bob", "cat"]) -> Browser.Suggesting {
        var list = Browser.Suggesting(
            tab: tab, spot: CGRect(x: 40, y: 120, width: 280, height: 30), host: "mail.example.com", clear: false)
        list.contacts = rows.map(offer)
        list.box = 1
        list.page = URL(string: "https://mail.example.com/")
        list.shown = Date().addingTimeInterval(-1)
        return list
    }

    func testTheRowsInTheOrderTheyAreDrawn() {
        let list = list(on: UUID())
        XCTAssertEqual(list.choices, [.contact(offer("ann")), .contact(offer("bob")), .contact(offer("cat"))])
    }

    func testArrowsMoveTheLight() {
        let browser = browser()
        defer { browser.closeAll() }
        let tab = UUID()
        browser.activeID = tab
        browser.testSuggest(list(on: tab))
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

    func testReturnTakesTheRowLit() {
        let browser = browser()
        defer { browser.closeAll() }
        let tab = UUID()
        browser.activeID = tab
        browser.testSuggest(list(on: tab))
        XCTAssertTrue(browser.moveChoice(by: 1))
        // Return takes the row lit, as a click on it does: the answer is
        // that the key was the list's.
        XCTAssertTrue(browser.takeLitChoice())
    }

    func testTheLightStaysOnItsRowAsRowsChange() {
        let browser = browser()
        defer { browser.closeAll() }
        let tab = UUID()
        browser.activeID = tab
        browser.testSuggest(list(on: tab, rows: ["bob", "cat"]))
        _ = browser.moveChoice(by: 1)
        XCTAssertEqual(browser.suggesting?.lit, 0)
        // A row joins above the one that is lit: the light goes with its row.
        var joined = try! XCTUnwrap(browser.suggesting)
        joined.contacts = ["ann", "bob", "cat"].map(offer)
        browser.testSuggest(joined)
        XCTAssertEqual(browser.suggesting?.lit, 1)
        XCTAssertEqual(browser.suggesting?.choices[1], .contact(offer("bob")))
    }
}
