import AppKit
import WebKit
import XCTest
@testable import Search

/// An extension's side panel beside a private tab: held back unless that
/// extension has been let into private tabs. On the model only: no window is
/// ever shown, and no extension is loaded, so the panel here belongs to one
/// that is gone, which is held back for the same reason as one shut out.
@MainActor
final class SidePanelPrivacyTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "panel-private-\(getpid())", 1)
        super.setUp()
    }

    override func setUp() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
    }

    override func tearDown() async throws {
        XCTAssertTrue(NSApp.windows.allSatisfy { !$0.isVisible }, "a window was shown")
    }

    /// A tab with somewhere to be, so the row keeps it: `receive` closes the
    /// blank tabs behind a tab that arrives, and a pair wants both halves
    /// still in the row.
    private func page(_ name: String, shy: Bool = false) -> Tab {
        let tab = Tab(shy: shy)
        tab.restore(url: URL(string: "about:blank#\(name)")!, title: name)
        return tab
    }

    private func panelUp(in browser: Browser) {
        browser.sidePanel = .page(extensionID: "panel-test-extension", url: URL(string: "chrome-extension://panel-test-extension/panel.html")!, tab: nil)
        browser.sidePanelShown = true
    }

    func testThePrivateTabAndTheSwitchDecideIt() {
        XCTAssertTrue(Browser.holdsPanel(shy: true, letIn: false), "a private tab, an extension not let in: held back")
        XCTAssertFalse(Browser.holdsPanel(shy: true, letIn: true), "let into private tabs: the panel shows")
        XCTAssertFalse(Browser.holdsPanel(shy: false, letIn: false))
        XCTAssertFalse(Browser.holdsPanel(shy: false, letIn: true))
    }

    func testAPrivateTabInFrontHoldsThePanelBack() {
        let browser = Browser(record: WindowRecord())
        panelUp(in: browser)
        browser.receive(Tab())
        XCTAssertFalse(browser.sidePanelHeld, "an ordinary tab: the panel stays")
        browser.receive(Tab(shy: true))
        XCTAssertTrue(browser.sidePanelHeld, "a private tab in front: the panel is held back")
        XCTAssertNotNil(browser.sidePanel, "held back, not closed")
        XCTAssertTrue(browser.sidePanelShown, "the panel is still the one you opened")
    }

    func testBackOnAnOrdinaryTabThePanelComesThrough() {
        let browser = Browser(record: WindowRecord())
        panelUp(in: browser)
        let plain = Tab()
        browser.receive(plain)
        browser.receive(Tab(shy: true))
        XCTAssertTrue(browser.sidePanelHeld)
        browser.select(plain)
        XCTAssertFalse(browser.sidePanelHeld, "the tab it may see is in front again")
    }

    func testNoPanelIsNeverHeldBack() {
        let browser = Browser(record: WindowRecord())
        browser.receive(Tab(shy: true))
        XCTAssertNil(browser.sidePanel)
        XCTAssertFalse(browser.sidePanelHeld, "nothing to hold back")
    }

    /// A pair holds two tabs of the same kind: `Browser.canSplit` asks for
    /// `first.shy == second.shy`, so a private page never stands beside an
    /// ordinary one. The panel is held back for the pair as it is for a tab.
    func testAPairOfPrivatePagesHoldsThePanelBack() {
        let browser = Browser(record: WindowRecord())
        browser.prefs.splitView = true
        panelUp(in: browser)
        let first = page("one", shy: true), second = page("two", shy: true)
        browser.receive(first)
        browser.receive(second)
        browser.pair(second, with: first, onLeft: false)
        XCTAssertNotNil(browser.activeSplit, "the pair was made")
        XCTAssertTrue(browser.sidePanelHeld)
    }

    func testAPrivatePageIsNeverPairedWithAnOrdinaryOne() {
        let browser = Browser(record: WindowRecord())
        browser.prefs.splitView = true
        let plain = page("plain"), shy = page("shy", shy: true)
        browser.receive(plain)
        browser.receive(shy)
        XCTAssertFalse(browser.canSplit(shy, with: plain), "a mixed pair is refused")
        browser.pair(shy, with: plain, onLeft: false)
        XCTAssertNil(browser.activeSplit, "so no pair was made")
    }

    func testAPairOfOrdinaryPagesKeepsThePanel() {
        let browser = Browser(record: WindowRecord())
        browser.prefs.splitView = true
        panelUp(in: browser)
        let first = page("one"), second = page("two")
        browser.receive(first)
        browser.receive(second)
        browser.pair(second, with: first, onLeft: false)
        XCTAssertFalse(browser.sidePanelHeld)
    }

    func testClosingThePanelLetsTheHoldGo() {
        let browser = Browser(record: WindowRecord())
        panelUp(in: browser)
        browser.receive(Tab(shy: true))
        XCTAssertTrue(browser.sidePanelHeld)
        browser.closeSidePanel()
        XCTAssertFalse(browser.sidePanelHeld)
        XCTAssertNil(browser.sidePanel)
    }
}
