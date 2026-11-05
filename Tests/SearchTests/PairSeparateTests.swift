import AppKit
import SwiftUI
import XCTest
@testable import Search

/// A pair carried down the column comes apart only where that was shown
/// (#883): the hand at rest over another tab dims the half that stays, and
/// only then does letting go take the other half out. Hosted as
/// PinDragTests does, in a borderless window far off every screen; the hand
/// is told to TabDrag through `testPointer`, since the mouse is elsewhere.
@MainActor
final class PairSeparateTests: XCTestCase {
    private var browsers: [Browser] = []
    private var windows: [NSWindow] = []
    private var restorePreferences: (() -> Void)?
    private var activationPolicy: NSApplication.ActivationPolicy?

    override class func setUp() {
        setenv("SEARCH_PROBE", "pair-separate-\(getpid())", 1)
        super.setUp()
    }

    override class func tearDown() {
        if let world = Store.world, world.hasPrefix("pair-separate-") {
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

    // The rows: one 0–28, the pair 30–86 (two 30–58, three 58–86), four
    // 88–116, five 118–146. "three" is held 4 points above the pair's foot
    // and carried 12 down: past the pair's edge, over "four".

    func testCarriedOnWithoutStoppingStaysAPair() async throws {
        let (browser, t, window) = try await setUpColumn()
        try await carry(from: 82, to: 94, in: window)
        XCTAssertNil(PairSeparation.shared.leaving, "nothing shown")
        try await send(.leftMouseUp, at: 94, in: window)
        try await settle()
        XCTAssertNotNil(browser.split(for: t[1]), "still a pair")
        XCTAssertEqual(browser.tabs.map(\.id), t.map(\.id))
    }

    func testAtRestOverAnotherTabShowsItThenSeparates() async throws {
        let (browser, t, window) = try await setUpColumn()
        try await carry(from: 82, to: 94, in: window)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(PairSeparation.shared.leaving, t[2].id, "the half held is the one leaving")
        try await send(.leftMouseUp, at: 94, in: window)
        try await settle()
        XCTAssertNil(browser.split(for: t[1]), "apart, as shown")
        XCTAssertNil(PairSeparation.shared.leaving, "nothing shown once let go")
    }

    func testBackOverItsOwnPlaceTakesTheSeparationBack() async throws {
        let (browser, t, window) = try await setUpColumn()
        try await carry(from: 82, to: 94, in: window)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(PairSeparation.shared.leaving, t[2].id)
        for y in stride(from: CGFloat(90), through: 78, by: -4) {
            try await send(.leftMouseDragged, at: y, in: window)
        }
        XCTAssertNil(PairSeparation.shared.leaving, "taken back")
        try await send(.leftMouseUp, at: 78, in: window)
        try await settle()
        XCTAssertNotNil(browser.split(for: t[1]), "still a pair")
    }

    /// The column with a separation shown, for looking at by eye: only when
    /// PAIR_SEPARATE_SHOTS names a folder.
    func testLooks() async throws {
        guard let folder = ProcessInfo.processInfo.environment["PAIR_SEPARATE_SHOTS"] else { return }
        let (_, _, window) = try await setUpColumn()
        func shoot(_ name: String) throws {
            guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(folder)/\(name).png"))
        }
        try await carry(from: 82, to: 94, in: window)
        try shoot("carried")
        try await Task.sleep(for: .milliseconds(500))
        try shoot("shown")
        try await send(.leftMouseUp, at: 94, in: window)
        try await settle()
        try shoot("after")
    }

    // MARK: - helpers

    private func setUpColumn() async throws -> (Browser, [Search.Tab], NSWindow) {
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
        for word in ["one", "two", "three", "four", "five"] {
            if browser.tabs.last?.isBlank == false { browser.newTab() }
            browser.tabs.last?.restore(url: URL(string: "about:blank#\(word)")!, title: word)
        }
        let t = browser.tabs
        browser.pair(t[2], with: t[1], onLeft: false)
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

    /// Down at `from`, then a hand's pace to `to`: 4 points a move, so it
    /// never reads as at rest on the way.
    private func carry(from: CGFloat, to: CGFloat, in window: NSWindow) async throws {
        try await send(.leftMouseDown, at: from, in: window)
        for y in stride(from: from + 4, through: to, by: 4) {
            try await send(.leftMouseDragged, at: y, in: window)
        }
    }

    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(250))
    }

    /// `y` down the rows from their top.
    private func send(_ type: NSEvent.EventType, at y: CGFloat, in window: NSWindow) async throws {
        let point = NSPoint(x: 70, y: window.frame.height - Metrics.strip - y)
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
