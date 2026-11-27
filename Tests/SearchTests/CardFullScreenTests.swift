import AppKit
import XCTest
@testable import Search

/// Keep the card in full screen (#1152): off, the page goes edge to edge
/// when the window fills the screen (#607); on, it stays a card there too.
@available(macOS 14, *)
@MainActor
final class CardFullScreenTests: XCTestCase {
    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    func testCardInFullScreenOnlyWhenTurnedOn() {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        let prefs = browser.prefs
        let saved = (prefs.sidebar, prefs.cards, prefs.cardsInFullScreen)
        defer { prefs.sidebar = saved.0; prefs.cards = saved.1; prefs.cardsInFullScreen = saved.2 }
        prefs.sidebar = true
        prefs.cards = true
        prefs.cardsInFullScreen = false

        browser.fullScreen = false
        XCTAssertTrue(browser.asCards, "A card in a window")
        browser.fullScreen = true
        XCTAssertFalse(browser.asCards, "Off: edge to edge in full screen, as before")

        prefs.cardsInFullScreen = true
        XCTAssertTrue(browser.asCards, "On: still a card in full screen")
        prefs.cards = false
        XCTAssertFalse(browser.asCards, "Edge to edge chosen: never a card")
        prefs.cards = true
        prefs.sidebar = false
        XCTAssertFalse(browser.asCards, "Tabs across the top: never a card")
    }

    func testOffByDefault() {
        let store = UserDefaults(suiteName: "card-fullscreen-\(UUID().uuidString)")!
        XCTAssertFalse(store.bool(forKey: "layout.cardsFullScreen"))
        XCTAssertNotNil(SettingsIndex.items.first { $0.id == "layout.cardsFullScreen" })
    }
}
