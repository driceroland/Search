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
        TestWorld.enter()
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

/// Several tabs playing at once, as in idea 1332 (music, two videos one of
/// them pinned, a stream, one of them left in another space): every one out
/// of sight is listed, the newest first, not only the newest.
@MainActor
final class PlayerStackTests: XCTestCase {
    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    func testEveryTabPlayingOutOfSightIsListed() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let browser = Browser(record: WindowRecord())
        let sidebar = browser.prefs.sidebar, shows = browser.prefs.showsPlayer
        let usesSpaces = browser.prefs.usesSpaces, spaces = browser.spaces
        defer {
            browser.closeAll()
            browser.prefs.sidebar = sidebar
            browser.prefs.showsPlayer = shows
            browser.prefs.usesSpaces = usesSpaces
            browser.spaces = spaces
        }
        browser.prefs.sidebar = true
        browser.prefs.showsPlayer = true
        browser.prefs.usesSpaces = true
        let first = browser.spaceID, second = UUID()
        browser.spaces = [Space(id: first, name: "First", colour: 0), Space(id: second, name: "Second", colour: 1)]
        browser.closeAll()
        browser.showRow([], active: nil, blank: true)

        func tab(_ url: String) -> Tab {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            let tab = Tab(shy: false, configuration: configuration)
            tab.setAddressOptimistically(URL(string: url)!)
            browser.prepare(tab)
            browser.insert(tab, at: browser.tabs.count)
            return tab
        }

        // Left playing in the first space.
        let stream = tab("https://stream.example")
        stream.noisy = true
        browser.switchSpace(to: second)
        XCTAssertEqual(browser.spaceID, second)
        let music = tab("https://music.example"), video = tab("https://video.example")
        let pinned = tab("https://pinned.example"), here = tab("https://here.example")
        browser.pin(pinned)
        browser.activeID = here.id
        music.noisy = true
        video.noisy = true
        pinned.noisy = true
        here.noisy = true

        XCTAssertEqual(browser.players.map(\.id), [pinned.id, video.id, music.id, stream.id],
                       "Every tab playing but the one on screen, newest first")
        XCTAssertTrue(browser.player === pinned, "The newest still leads")
        video.noisy = false
        XCTAssertEqual(browser.players.map(\.id), [pinned.id, music.id, stream.id])
        browser.prefs.showsPlayer = false
        XCTAssertTrue(browser.players.isEmpty, "The switch off")
    }
}
