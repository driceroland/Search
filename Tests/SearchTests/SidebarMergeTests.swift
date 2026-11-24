import AppKit
import SwiftUI
import XCTest
@testable import Search

/// A tab carried down the column and held over the middle of another tab
/// makes a split of the two when let go (TabMerge): side by side in one row,
/// the carried tab on the half of the row the hand is on, left or right, and
/// moved from one to the other before letting go. Hosted as
/// PairSeparateTests does, the column alone, far off every screen.
@MainActor
final class SidebarMergeTests: XCTestCase {
    private var browsers: [Browser] = []
    private var windows: [NSWindow] = []
    private var restorePreferences: (() -> Void)?
    private var activationPolicy: NSApplication.ActivationPolicy?

    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    override class func tearDown() {
        if let world = Store.world, world.hasPrefix("sidebar-merge-") {
            try? FileManager.default.removeItem(at: Store.folder)
            UserDefaults.standard.removePersistentDomain(forName: "com.officecommun.search.test.\(world)")
        }
        super.tearDown()
    }

    override func tearDown() async throws {
        TabDrag.testPointer = nil
        for window in windows { window.contentView = nil; window.close() }
        for browser in browsers { browser.window = nil; browser.closeAll() }
        restorePreferences?()
        if let activationPolicy { NSApp.setActivationPolicy(activationPolicy) }
        windows.removeAll()
        browsers.removeAll()
        try await Task.sleep(for: .milliseconds(250))
        try await super.tearDown()
    }

    // The rows: one 0–28, two 30–58, three 60–88, four 90–118. "four" is
    // picked up and carried up onto "two", whose middle is 37–51.

    func testHeldOverTheRightOfATabSplitsWithItOnTheRight() async throws {
        let (browser, t, window) = try await setUp()
        try await carry(from: 104, to: 44, x: 0.75, in: window)
        try await rest()
        let shown = try XCTUnwrap(TabMerge.shared.shown, "the split is shown on the row")
        XCTAssertEqual(shown.targetID, t[1].id)
        XCTAssertEqual(shown.sourceID, t[3].id)
        XCTAssertFalse(shown.onLeft)
        try await send(.leftMouseUp, at: 44, x: 0.75, in: window)
        try await settle()
        XCTAssertEqual(browser.split(for: t[3])?.tabs, [t[1].id, t[3].id], "side by side, the carried tab on the right")
        XCTAssertEqual(browser.tabs.map(\.id), [t[0], t[1], t[3], t[2]].map(\.id), "the pair where the tab it was let go on was")
        XCTAssertNil(TabMerge.shared.shown, "nothing shown once let go")
    }

    func testMovedAcrossToTheLeftTakesTheLeft() async throws {
        let (browser, t, window) = try await setUp()
        try await carry(from: 104, to: 44, x: 0.75, in: window)
        try await rest()
        XCTAssertEqual(TabMerge.shared.shown?.onLeft, false)
        for share in stride(from: 0.7, through: 0.25, by: -0.05) {
            try await send(.leftMouseDragged, at: 44, x: share, in: window)
        }
        XCTAssertEqual(TabMerge.shared.shown?.targetID, t[1].id, "still over the same tab")
        XCTAssertEqual(TabMerge.shared.shown?.onLeft, true, "the half follows the hand, with no wait")
        try await send(.leftMouseUp, at: 44, x: 0.25, in: window)
        try await settle()
        XCTAssertEqual(browser.split(for: t[3])?.tabs, [t[3].id, t[1].id], "the carried tab on the left")
        XCTAssertEqual(browser.tabs.map(\.id), [t[0], t[3], t[1], t[2]].map(\.id))
    }

    func testCarriedThroughWithoutStoppingOnlyMoves() async throws {
        let (browser, t, window) = try await setUp()
        try await carry(from: 104, to: 32, x: 0.5, in: window)
        XCTAssertNil(TabMerge.shared.shown, "never at rest over a middle: nothing shown")
        try await send(.leftMouseUp, at: 32, x: 0.5, in: window)
        try await settle()
        XCTAssertTrue(browser.splits.isEmpty, "no pair")
        XCTAssertEqual(browser.tabs.map(\.id), [t[0], t[3], t[1], t[2]].map(\.id), "moved, as before")
    }

    func testTheMiddleHoldsTheRowsPlace() async throws {
        let (browser, t, window) = try await setUp()
        try await carry(from: 104, to: 44, x: 0.75, in: window)
        try await rest()
        XCTAssertEqual(browser.tabs.map(\.id), [t[0], t[1], t[3], t[2]].map(\.id),
                       "past three, but not yet past two: its middle is where it would split")
        // Back out of the middle and on up through it: now it passes.
        for y in stride(from: CGFloat(42), through: 32, by: -2) {
            try await send(.leftMouseDragged, at: y, x: 0.75, in: window)
        }
        XCTAssertNil(TabMerge.shared.shown, "out of the middle: nothing shown")
        try await send(.leftMouseUp, at: 32, x: 0.75, in: window)
        try await settle()
        XCTAssertTrue(browser.splits.isEmpty)
        XCTAssertEqual(browser.tabs.map(\.id), [t[0], t[3], t[1], t[2]].map(\.id))
    }

    func testOntoAHalfOfAPairJoinsItBesideThatHalf() async throws {
        let (browser, t, window) = try await setUp(pairFirstTwo: true)
        // The pair 0–28 (one on the left, two on the right), three 30–58,
        // four 60–88: four onto the right of two.
        try await carry(from: 74, to: 14, x: 0.9, in: window)
        try await rest()
        XCTAssertEqual(TabMerge.shared.shown?.targetID, t[1].id)
        XCTAssertEqual(TabMerge.shared.shown?.onLeft, false)
        try await send(.leftMouseUp, at: 14, x: 0.9, in: window)
        try await settle()
        XCTAssertEqual(browser.split(for: t[3])?.tabs, [t[0].id, t[1].id, t[3].id], "three side by side")
    }

    func testEscapeCallsItOff() async throws {
        let (browser, t, window) = try await setUp()
        try await carry(from: 104, to: 44, x: 0.75, in: window)
        try await rest()
        XCTAssertNotNil(TabMerge.shared.shown)
        TabDrag.shared.cancel()
        XCTAssertNil(TabMerge.shared.shown, "gone with the carry")
        try await send(.leftMouseUp, at: 44, x: 0.75, in: window)
        try await settle()
        XCTAssertTrue(browser.splits.isEmpty)
        XCTAssertEqual(browser.tabs.map(\.id), t.map(\.id), "back where it was")
    }

    /// The column with a split shown on a row, for looking at by eye: only
    /// when SIDEBAR_MERGE_SHOTS names a folder.
    func testLooks() async throws {
        guard let folder = ProcessInfo.processInfo.environment["SIDEBAR_MERGE_SHOTS"] else { return }
        let (_, _, window) = try await setUp()
        func shoot(_ name: String) throws {
            guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(folder)/\(name).png"))
        }
        try await carry(from: 104, to: 44, x: 0.75, in: window)
        try await rest()
        try shoot("right")
        for share in stride(from: 0.7, through: 0.25, by: -0.05) {
            try await send(.leftMouseDragged, at: 44, x: share, in: window)
        }
        try await settle()
        try shoot("left")
        try await send(.leftMouseUp, at: 44, x: 0.25, in: window)
        try await settle()
        try shoot("after")
    }

    // MARK: - helpers

    private func setUp(pairFirstTwo: Bool = false) async throws -> (Browser, [Search.Tab], NSWindow) {
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
            browser.tabs.last?.restore(url: URL(string: "about:blank#\(word)")!, title: word)
        }
        let t = browser.tabs
        if pairFirstTwo { browser.pair(t[1], with: t[0], onLeft: false) }
        browser.select(t[0])
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: browser.prefs.sideWidth, height: 400),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SideBar(browser: browser, prefs: browser.prefs))
        window.orderFrontRegardless()
        XCTAssertFalse(NSScreen.screens.contains { $0.frame.intersects(window.frame) }, "never on a screen")
        windows.append(window)
        browser.window = window
        try await settle()
        return (browser, t, window)
    }

    /// Down at `from`, then a hand's pace up to `to`: 2 points a move, so it
    /// never reads as at rest on the way.
    private func carry(from: CGFloat, to: CGFloat, x: CGFloat, in window: NSWindow) async throws {
        try await send(.leftMouseDown, at: from, x: x, in: window)
        for y in stride(from: from - 2, through: to, by: -2) {
            try await send(.leftMouseDragged, at: y, x: x, in: window)
        }
    }

    /// Still for longer than the split waits for.
    private func rest() async throws {
        try await Task.sleep(for: .milliseconds(300))
    }

    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(250))
    }

    /// `y` down the rows from their top, `x` a share of the column's width.
    private func send(_ type: NSEvent.EventType, at y: CGFloat, x: CGFloat, in window: NSWindow) async throws {
        let point = NSPoint(x: window.frame.width * x, y: window.frame.height - Metrics.strip - y)
        TabDrag.testPointer = window.convertToScreen(NSRect(origin: point, size: .zero)).origin
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
            pressure: type == .leftMouseUp ? 0 : 1
        ))
        window.sendEvent(event)
        try await Task.sleep(for: .milliseconds(30))
    }
}
