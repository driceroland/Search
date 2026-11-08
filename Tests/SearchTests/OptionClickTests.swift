import AppKit
import SwiftUI
import XCTest
@testable import Search

/// ⌥-click on a tab puts it beside the page on screen in Split View (#939),
/// as its menu's Open in Split View does; on a half of the pair on screen it
/// takes that half out. Hosted as SidebarPressTests does, far off every
/// screen. The clicks go through NSApp, as a hand's do, so the ⌥ they carry
/// is the one the tab reads (TabClick.flags); the keyboard's is never held.
@MainActor
final class OptionClickTests: XCTestCase {
    private var browsers: [Browser] = []
    private var windows: [NSWindow] = []
    private var restorePreferences: (() -> Void)?
    private var activationPolicy: NSApplication.ActivationPolicy?

    override class func setUp() {
        setenv("SEARCH_PROBE", "option-click-\(getpid())", 1)
        super.setUp()
    }

    override class func tearDown() {
        if let world = Store.world, world.hasPrefix("option-click-") {
            try? FileManager.default.removeItem(at: Store.folder)
            UserDefaults.standard.removePersistentDomain(forName: "com.officecommun.search.test.\(world)")
        }
        super.tearDown()
    }

    override func tearDown() async throws {
        TabClick.forget()
        for window in windows { window.contentView = nil; window.close() }
        for browser in browsers {
            browser.window = nil
            browser.cancelTabEdit()
            // Pins are kept for the space in every window (Pins.swift): the
            // one made here would be a row in the next suite's column.
            for tab in browser.tabs where tab.pin != nil { browser.unpin(tab) }
            browser.closeAll()
        }
        restorePreferences?()
        if let activationPolicy { NSApp.setActivationPolicy(activationPolicy) }
        windows.removeAll()
        browsers.removeAll()
        try await settle()
        try await super.tearDown()
    }

    // MARK: - the column

    func testOptionClickInTheColumnPutsTheTabBesideThePage() async throws {
        let browser = makeBrowser()
        let t = browser.tabs
        browser.select(t[0])
        let window = makeColumn(browser)
        try await settle()
        try await click(rowPoint(2, in: window), in: window, option: true)
        let pair = try XCTUnwrap(browser.split(for: t[2]), "a pair")
        XCTAssertEqual(pair.tabs, [t[0].id, t[2].id], "beside the page, on the right")
        XCTAssertEqual(browser.activeSplit?.id, pair.id, "on screen")
        XCTAssertEqual(browser.activeID, t[2].id, "the tab clicked has the keys, as with Open in Split View")
        XCTAssertNil(browser.editingTab)
    }

    func testAPlainClickStillOnlyOpensTheTab() async throws {
        let browser = makeBrowser()
        let t = browser.tabs
        browser.select(t[0])
        let window = makeColumn(browser)
        try await settle()
        try await click(rowPoint(2, in: window), in: window, option: false)
        XCTAssertEqual(browser.activeID, t[2].id)
        XCTAssertTrue(browser.splits.isEmpty, "no pair")
    }

    func testOptionClickOnTheTabOnScreenPutsAnEmptyPageBeside() async throws {
        let browser = makeBrowser()
        let t = browser.tabs
        browser.select(t[1])
        let window = makeColumn(browser)
        try await settle()
        try await click(rowPoint(1, in: window), in: window, option: true)
        let pair = try XCTUnwrap(browser.activeSplit, "a pair, as ⌥⌘N makes")
        XCTAssertEqual(pair.left, t[1].id)
        XCTAssertTrue(browser.active?.isBlank == true, "the empty page beside it has the keys")
        XCTAssertNil(browser.editingTab, "not the address field of the tab clicked")
    }

    func testOptionClickOnAHalfOfThePairOnScreenTakesItOut() async throws {
        let browser = makeBrowser()
        let t = browser.tabs
        browser.prefs.splitView = true
        browser.pair(t[1], with: t[0], onLeft: false)
        browser.focusPane(t[0])
        let window = makeColumn(browser)
        try await settle()
        // The pair is two lines, 0–28 and 28–56: its lower half is t[1].
        try await click(NSPoint(x: 70, y: window.frame.height - Metrics.strip - 42), in: window, option: true)
        XCTAssertTrue(browser.splits.isEmpty, "apart")
        XCTAssertEqual(browser.activeID, t[0].id, "the other page stays on screen")
        XCTAssertEqual(browser.tabs.map(\.id), t.map(\.id), "both stay, in place")
    }

    func testOptionClickOnAHalfOfAnotherPairBringsItBeside() async throws {
        let browser = makeBrowser()
        let t = browser.tabs
        browser.prefs.splitView = true
        browser.pair(t[2], with: t[1], onLeft: false)
        browser.select(t[0])
        let window = makeColumn(browser)
        try await settle()
        // Rows: t[0] 0–28, the pair 30–86 (t[1] 30–58, t[2] 58–86).
        try await click(NSPoint(x: 70, y: window.frame.height - Metrics.strip - 72), in: window, option: true)
        XCTAssertEqual(browser.split(for: t[2])?.tabs, [t[0].id, t[2].id], "out of its pair, beside the page")
        XCTAssertNil(browser.split(for: t[1]), "its old partner is a tab of its own")
    }

    func testAPrivateTabIsOnlyOpenedBesideOneThatIsNot() async throws {
        let browser = makeBrowser()
        browser.newShyTab()
        let shy = try XCTUnwrap(browser.active)
        let t = browser.tabs
        browser.select(t[0])
        let window = makeColumn(browser)
        try await settle()
        let row = try XCTUnwrap(t.firstIndex { $0.id == shy.id })
        try await click(rowPoint(row, in: window), in: window, option: true)
        XCTAssertTrue(browser.splits.isEmpty, "no pair of a private tab and one that isn't")
        XCTAssertEqual(browser.activeID, shy.id, "chosen, as a plain click chooses it")
    }

    // MARK: - across the top, and a pin

    func testOptionClickAcrossTheTopPutsTheTabBesideThePage() async throws {
        let browser = makeBrowser()
        browser.prefs.sidebar = false
        let t = browser.tabs
        browser.select(t[0])
        let window = makeStrip(browser)
        try await settle()
        try await click(pillPoint(2), in: window, option: true)
        XCTAssertEqual(browser.split(for: t[2])?.tabs, [t[0].id, t[2].id])
    }

    func testOptionClickOnThePinOnScreenStillSplits() async throws {
        let browser = makeBrowser()
        let t = browser.tabs
        browser.pin(t[0])
        browser.select(t[0])
        let window = makeColumn(browser)
        try await settle()
        // The pin's square, which answers only a double click while it is on
        // screen (it goes home): ⌥-click is heard all the same.
        try await click(NSPoint(x: 40, y: window.frame.height - Metrics.strip - 17), in: window, option: true)
        XCTAssertNotNil(browser.activeSplit, "its page split, as ⌥⌘N splits it")
        XCTAssertNil(browser.editingPin)
    }

    // MARK: - helpers

    private func makeBrowser() -> Browser {
        _ = NSApplication.shared
        activationPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.prohibited)
        let prefs = Shared.prefs
        let previous = (prefs.sidebar, prefs.usesTabGroups, prefs.splitView, prefs.listsPins, prefs.roomyTabs)
        restorePreferences = {
            (prefs.sidebar, prefs.usesTabGroups, prefs.splitView, prefs.listsPins, prefs.roomyTabs) = previous
        }
        let browser = Browser(record: WindowRecord())
        browsers.append(browser)
        browser.prefs.sidebar = true
        browser.prefs.usesTabGroups = false
        browser.prefs.splitView = true
        browser.prefs.listsPins = false
        browser.prefs.roomyTabs = false
        for word in ["one", "two", "three", "four"] {
            if browser.tabs.last?.isBlank == false { browser.newTab() }
            browser.tabs.last?.restore(url: URL(string: "https://example.invalid/\(word)")!, title: word)
        }
        return browser
    }

    private func makeColumn(_ browser: Browser) -> NSWindow {
        let window = makeWindow(root: SideBar(browser: browser, prefs: browser.prefs), width: browser.prefs.sideWidth, height: 500)
        browser.window = window
        return window
    }

    private func makeStrip(_ browser: Browser) -> NSWindow {
        let window = makeWindow(root: TabBar(browser: browser), width: 900, height: Metrics.strip)
        browser.window = window
        return window
    }

    private func makeWindow<V: View>(root: V, width: CGFloat, height: CGFloat) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: width, height: height),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: root)
        window.orderFrontRegardless()
        XCTAssertFalse(NSScreen.screens.contains { $0.frame.intersects(window.frame) }, "never on a screen")
        windows.append(window)
        return window
    }

    /// The middle of a pill in the 900-point strip of four tabs.
    private func pillPoint(_ index: Int) -> NSPoint {
        NSPoint(x: 195 + CGFloat(index) * 150, y: Metrics.strip / 2)
    }

    private func rowPoint(_ index: Int, in window: NSWindow) -> NSPoint {
        NSPoint(x: 70, y: window.frame.height - Metrics.strip - 14 - CGFloat(index) * 30)
    }

    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(250))
    }

    /// Down and up, through NSApp as the hand's are, with ⌥ on both or not.
    private func click(_ point: NSPoint, in window: NSWindow, option: Bool) async throws {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: option ? .option : [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                pressure: type == .leftMouseUp ? 0 : 1
            ))
            NSApp.sendEvent(event)
            try await Task.sleep(for: .milliseconds(40))
        }
        try await settle()
    }
}
