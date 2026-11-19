import AppKit
import WebKit
import XCTest
@testable import Search

/// Which tab the player at the foot of the sidebar is for (Player.swift),
/// from the tabs' own sound and pause, without a page playing anything.
@MainActor
final class PlayerTests: XCTestCase {
    private var browser: Browser!
    private var sidebar = false

    override class func setUp() {
        setenv("SEARCH_PROBE", "player-\(getpid())", 1)
        super.setUp()
    }

    override func setUp() {
        _ = NSApplication.shared
        browser = Browser(record: WindowRecord())
        sidebar = browser.prefs.sidebar
        browser.prefs.sidebar = true
        browser.prefs.showsPlayer = true
    }

    override func tearDown() {
        browser.closeAll()
        browser.prefs.showsPlayer = false
        browser.prefs.sidebar = sidebar
        browser = nil
    }

    private func tab(_ url: String) -> Tab {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let tab = Tab(shy: false, configuration: configuration)
        tab.setAddressOptimistically(URL(string: url)!)
        browser.prepare(tab)
        browser.insert(tab, at: browser.tabs.count)
        return tab
    }

    func testTheNewestOutOfSight() {
        let a = tab("https://a.example"), b = tab("https://b.example"), c = tab("https://c.example")
        browser.activeID = a.id
        a.noisy = true
        XCTAssertNil(browser.player, "Playing on screen: nothing to show")
        browser.activeID = b.id
        XCTAssertTrue(browser.player === a)
        c.noisy = true
        XCTAssertTrue(browser.player === c, "The newest to start")
        browser.activeID = c.id
        XCTAssertTrue(browser.player === a, "The newest one on screen: the one before")
        c.noisy = false
        browser.activeID = b.id
        XCTAssertTrue(browser.player === a, "The newest gone quiet: the one before")
        a.noisy = false
        XCTAssertNil(browser.player, "Nothing plays")
    }

    func testPausedFromThePlayerStays() {
        let a = tab("https://a.example"), b = tab("https://b.example")
        browser.activeID = b.id
        a.noisy = true
        a.stilled = true
        a.noisy = false
        XCTAssertTrue(browser.player === a, "Paused from the player: kept, to play again")
        a.stilled = false
        XCTAssertNil(browser.player, "Put away: gone")
        a.noisy = true
        XCTAssertTrue(browser.player === a, "Playing again: back")
    }

    func testOnlyWithTheSwitchAndTheColumn() {
        let a = tab("https://a.example"), b = tab("https://b.example")
        browser.activeID = b.id
        a.noisy = true
        XCTAssertTrue(browser.player === a)
        browser.prefs.showsPlayer = false
        XCTAssertNil(browser.player, "The switch off")
        browser.prefs.showsPlayer = true
        browser.prefs.sidebar = false
        XCTAssertNil(browser.player, "The tabs across the top")
        browser.prefs.sidebar = true
        XCTAssertTrue(browser.player === a)
        browser.close(a)
        XCTAssertNil(browser.player, "A closed tab has nothing to show")
    }
}
