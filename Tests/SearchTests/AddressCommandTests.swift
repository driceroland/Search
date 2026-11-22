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
        TestWorld.enter()
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

    func testMenuCommandsAndSettingsPagesAreOfferedUnderTheRest() {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        let prefs = browser.prefs
        let saved = (prefs.commandBar, prefs.splitView, prefs.ai, prefs.bookmarksBar)
        defer { (prefs.commandBar, prefs.splitView, prefs.ai, prefs.bookmarksBar) = saved }
        prefs.commandBar = true

        // By the words of the name, in any order, from their start.
        XCTAssertEqual(AddressCommand.listed("hide el", in: browser).first, .menu("view.hide"))
        XCTAssertEqual(AddressCommand.listed("bar bookm", in: browser).first, .menu("bookmarks.bar"))
        XCTAssertEqual(AddressCommand.listed("priv tab", in: browser).first, .menu("file.newPrivateTab"))
        XCTAssertEqual(AddressCommand.listed("appear", in: browser).first, .page(.appearance))
        XCTAssertEqual(AddressCommand.listed("privacy", in: browser).first, .page(.privacy))
        XCTAssertTrue(AddressCommand.listed("zoom", in: browser).starts(with: [.menu("view.zoomIn"), .menu("view.zoomOut")]))
        XCTAssertEqual(AddressCommand.menu("view.hide").title, "Hide Elements…")
        XCTAssertEqual(AddressCommand.menu("view.hide").key, ShortcutStore.shared.key(for: "view.hide")?.display)
        XCTAssertEqual(AddressCommand.page(.privacy).title, "Privacy Settings")

        // Never an address, nor two letters, nor what a word above already is.
        XCTAssertTrue(AddressCommand.listed("reload.com", in: browser).isEmpty)
        XCTAssertTrue(AddressCommand.listed("zo", in: browser).isEmpty)
        XCTAssertFalse(AddressCommand.listed("downloads", in: browser).contains(.menu("history.downloads")))
        XCTAssertFalse(AddressCommand.listed("address", in: browser).contains(.menu("file.openAddress")), "the field is open")

        // Hidden where the menu hides it: a feature off, no page, no pair.
        prefs.splitView = false
        XCTAssertFalse(AddressCommand.listed("split", in: browser).contains(.menu("tabs.split")))
        prefs.splitView = true
        XCTAssertTrue(AddressCommand.listed("split", in: browser).contains(.menu("tabs.split")))
        XCTAssertFalse(AddressCommand.listed("swap pages", in: browser).contains(.menu("tabs.swapSplit")), "no pair on screen")
        prefs.ai = false
        XCTAssertTrue(AddressCommand.listed("summarize", in: browser).isEmpty)
        let captures = prefs.capturesPages
        prefs.capturesPages = false
        XCTAssertFalse(AddressCommand.listed("capture", in: browser).contains(.menu("view.capture")), "Capture pages off")
        prefs.capturesPages = true
        XCTAssertTrue(AddressCommand.listed("capture", in: browser).contains(.menu("view.capture")))
        prefs.capturesPages = captures
        XCTAssertNotEqual(browser.active?.isWeb, true)
        XCTAssertTrue(AddressCommand.listed("reader", in: browser).isEmpty, "no page to read")

        // Under the search, so Return still searches; the menu's action runs.
        let offers = browser.placeOffers(for: "bookmarks bar").offers
        XCTAssertFalse(offers.first?.kind.isCommand ?? true)
        XCTAssertEqual(offers.last?.kind, .command(.menu("bookmarks.bar")))
        let before = prefs.bookmarksBar
        AddressCommand.menu("bookmarks.bar").run(on: browser)
        XCTAssertNotEqual(prefs.bookmarksBar, before, "the menu's own action")

        prefs.commandBar = false
        XCTAssertFalse(browser.placeOffers(for: "bookmarks bar").offers.contains { $0.kind.isCommand }, "off means off")
    }

    func testABookmarkFoundOnlyThroughATypoGoesUnderHistory() throws {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        let slip = try XCTUnwrap(URL(string: "https://dashboards.example/d/nodes"))
        let mark = try XCTUnwrap(browser.bookmarks.add(slip, title: "Nodes dashboard"))
        defer { browser.bookmarks.remove(mark.id) }

        // "noda": one letter from "nodes", exact only in history.
        let alone = browser.placeOffers(for: "noda").offers.filter { $0.kind == .bookmark }
        XCTAssertEqual(alone.first?.url, slip, "with nothing else, the slip is offered")
        let page = try XCTUnwrap(URL(string: "https://wiki.example/noda"))
        browser.history.record(page, title: "Noda")
        defer { browser.history.forget(History.identity(for: page)) }
        let offers = browser.placeOffers(for: "noda").offers.filter { $0.kind == .visited || $0.kind == .bookmark }
        XCTAssertEqual(offers.first?.url, page, "where you have been, as typed, before a bookmark one letter off")
        XCTAssertTrue(offers.contains { $0.url == slip }, "the bookmark is still offered, under it")

        let exact = browser.placeOffers(for: "nodes").offers.filter { $0.kind == .visited || $0.kind == .bookmark }
        XCTAssertEqual(exact.first?.url, slip, "a bookmark that fits as typed still leads")
    }
}
