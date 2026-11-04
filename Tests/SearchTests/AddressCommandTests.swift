import AppKit
import XCTest
@testable import Search

final class FuzzyTests: XCTestCase {
    private func nearly(_ typed: String, _ text: String) -> Bool {
        Fuzzy.nearly(Array(typed.utf8), in: text.lowercased())
    }

    func testASlipFindsTheWordItMeant() {
        XCTAssertTrue(nearly("githb", "GitHub"), "a letter left out")
        XCTAssertTrue(nearly("gihtub", "github.com"), "two letters swapped")
        XCTAssertTrue(nearly("youtbe", "YouTube"))
        XCTAssertTrue(nearly("wikipeida", "wikipedia.org"))
        XCTAssertTrue(nearly("igthub", "github"), "the first two swapped")
        XCTAssertTrue(nearly("documantation", "Swift Documentation"), "two slips in a long word")
    }

    func testTooFarOrTooShortFindsNothing() {
        XCTAssertFalse(nearly("gti", "git"), "under four letters, no slips")
        XCTAssertFalse(nearly("xithub", "github"), "the first letter has to be right")
        XCTAssertFalse(nearly("gthbb", "github"))
        XCTAssertFalse(nearly("hello", "world wide web"))
    }

    func testLettersInOrderAbbreviate() {
        XCTAssertTrue(Fuzzy.abbreviates("dwn", "downloads"))
        XCTAssertFalse(Fuzzy.abbreviates("wnd", "downloads"))
        XCTAssertFalse(Fuzzy.abbreviates("dnw", "downloads"))
    }
}

@MainActor
final class AddressCommandTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "address-commands-\(getpid())", 1)
        super.setUp()
    }

    func testPartOfANameIsOfferedButNeverTakesReturn() {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        let saved = browser.prefs.commandBar
        defer { browser.prefs.commandBar = saved }
        browser.prefs.commandBar = true

        XCTAssertEqual(AddressCommand.matching("downloads", in: browser), .downloads)
        XCTAssertNil(AddressCommand.near("downloads", in: browser), "a whole name is the command itself")
        for typed in ["down", "dwn", "Downl", "downlaods", "dowloads"] {
            XCTAssertEqual(AddressCommand.near(typed, in: browser), .downloads, typed)
        }
        XCTAssertEqual(AddressCommand.near("priv", in: browser), .newPrivateTab)
        XCTAssertEqual(AddressCommand.near("setings", in: browser), .settings)
        XCTAssertEqual(AddressCommand.near("side", in: browser), .toggleSidebar)
        XCTAssertNil(AddressCommand.near("do", in: browser), "two letters are any search")
        XCTAssertNil(AddressCommand.near("weather", in: browser))

        let exact = browser.placeOffers(for: "downloads").offers
        XCTAssertEqual(exact.first?.kind, .command(.downloads), "a whole name still runs on Return")

        let part = browser.placeOffers(for: "dwn").offers
        XCTAssertEqual(part.last?.kind, .command(.downloads), "part of a name is offered, last")
        XCTAssertFalse(part.first?.kind.isCommand ?? true, "and Return still searches")

        browser.prefs.commandBar = false
        XCTAssertFalse(browser.placeOffers(for: "dwn").offers.contains { $0.kind.isCommand }, "off means off")
    }
}
