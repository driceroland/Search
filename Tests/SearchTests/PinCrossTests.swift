import AppKit
import XCTest
@testable import Search

/// A pinned tab going between an extension's page and a website is swapped
/// for a new tab (Browser.replace): it has to stay the same pin, at the same
/// home, in the same spaces. In a test world of its own, nothing shown.
@MainActor
final class PinCrossTests: XCTestCase {
    private var browser: Browser!
    private let home = URL(string: "chrome-extension://pin-cross/options.html")!
    private let site = URL(string: "https://signin.example/")!

    override class func setUp() {
        setenv("SEARCH_PROBE", "pincross-\(getpid())", 1)
        super.setUp()
    }

    override func setUp() {
        _ = NSApplication.shared
        browser = Browser(record: WindowRecord())
    }

    override func tearDown() {
        browser.closeAll()
        browser = nil
    }

    /// A pin at its home, in the row.
    private func pin(everywhere: Bool = false) -> Tab {
        let tab = Tab(configuration: Web.configuration(space: browser.spaceID))
        tab.setAddressOptimistically(home)
        tab.pin = "P"
        tab.pinID = UUID()
        tab.home = home
        tab.everywhere = everywhere
        browser.prepare(tab)
        browser.insert(tab, at: browser.tabs.count)
        return tab
    }

    /// The tab standing where `tab` stood, once it has gone to `site`.
    private func cross(_ tab: Tab) throws -> Tab {
        let index = try XCTUnwrap(browser.tabs.firstIndex { $0 === tab })
        browser.replace(tab, going: site)
        let fresh = browser.tabs[index]
        XCTAssertFalse(fresh === tab, "The tab should have been swapped for a new one")
        return fresh
    }

    func testAPinThatCrossesIsTheSamePin() throws {
        let tab = pin()
        let id = tab.pinID
        let fresh = try cross(tab)
        XCTAssertEqual(fresh.pin, "P")
        // A new id would have every other window close its tab for this pin.
        XCTAssertEqual(fresh.pinID, id)
        // A double-click still goes back to where it was pinned, not to the
        // page the swap went to.
        XCTAssertEqual(fresh.home, home)
    }

    func testAPinEverySpaceShowsStaysInEverySpace() throws {
        let fresh = try cross(pin(everywhere: true))
        XCTAssertTrue(fresh.everywhere, "A shared pin would be written back as this space's own")
    }

    func testAPinOnlyHereStaysOnlyHere() throws {
        XCTAssertFalse(try cross(pin()).everywhere)
    }
}
