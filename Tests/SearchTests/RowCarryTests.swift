import AppKit
import SwiftUI
import XCTest
@testable import Search

/// A tab carried down the column past a pair, which stands two lines tall:
/// the row stays under the hand and passes the pair at its middle. Hosted
/// as PinDragTests does, in a borderless window far off every screen.
@MainActor
final class RowCarryTests: XCTestCase {
    private var browsers: [Browser] = []
    private var windows: [NSWindow] = []
    private var restorePreferences: (() -> Void)?
    private var activationPolicy: NSApplication.ActivationPolicy?

    override class func setUp() {
        setenv("SEARCH_PROBE", "row-carry-\(getpid())", 1)
        super.setUp()
    }

    override class func tearDown() {
        if let world = Store.world, world.hasPrefix("row-carry-") {
            try? FileManager.default.removeItem(at: Store.folder)
            UserDefaults.standard.removePersistentDomain(forName: "com.officecommun.search.test.\(world)")
        }
        super.tearDown()
    }

    override func tearDown() async throws {
        for window in windows { window.contentView = nil; window.close() }
        for browser in browsers { browser.closeAll() }
        restorePreferences?()
        if let activationPolicy { NSApp.setActivationPolicy(activationPolicy) }
        windows.removeAll()
        browsers.removeAll()
        try await Task.sleep(for: .milliseconds(250))
        try await super.tearDown()
    }

    // MARK: - the places

    func testEvenPlacesMoveEachHalfStep() {
        let steps: [CGFloat] = [30, 30, 30, 30]
        XCTAssertEqual(Carried.leading(of: 2, in: steps), 60)
        XCTAssertEqual(Carried.slot(at: 30 + 14, carrying: 1, in: steps), 1)
        XCTAssertEqual(Carried.slot(at: 30 + 16, carrying: 1, in: steps), 2)
        XCTAssertEqual(Carried.slot(at: 30 - 16, carrying: 1, in: steps), 0)
        XCTAssertEqual(Carried.slot(at: 500, carrying: 1, in: steps), 3, "no further than the end")
        XCTAssertEqual(Carried.slot(at: -500, carrying: 1, in: steps), 0)
    }

    func testAPairIsPassedAtItsMiddle() {
        // one, a pair (two lines), four: four carried up.
        let steps: [CGFloat] = [30, 58, 30]
        XCTAssertEqual(Carried.slot(at: 88 - 28, carrying: 2, in: steps), 2, "not yet half the pair")
        XCTAssertEqual(Carried.slot(at: 88 - 30, carrying: 2, in: steps), 1)
        // Now above it: back down only past the same middle, so it can't
        // shuttle.
        XCTAssertEqual(Carried.slot(at: 88 - 30, carrying: 1, in: [30, 30, 58]), 1)
        XCTAssertEqual(Carried.slot(at: 88 - 28, carrying: 1, in: [30, 30, 58]), 2)
        // A pair carried down past one tab: the tab's half.
        XCTAssertEqual(Carried.slot(at: 30 + 16, carrying: 1, in: steps), 2)
    }

    // MARK: - the real gesture

    /// "four" carried up past the pair and let go just over "one": it
    /// lands between "one" and the pair. With one step for every row it
    /// counted the pair as one line, ran a line ahead of the hand, and
    /// landed above "one".
    func testRowCarriedPastAPairLandsWhereItWasLetGo() async throws {
        let browser = makeBrowser()
        let t = browser.tabs
        browser.pair(t[2], with: t[1], onLeft: false)
        browser.select(t[4])
        let window = makeWindow(browser)
        try await settle()
        // one 0–28, the pair 30–86, four 88–116, five 118–146.
        let grab: CGFloat = 102
        try await send(.leftMouseDown, at: point(y: grab, in: window), in: window)
        for y in stride(from: grab - 2, through: grab - 60, by: -2) {
            try await send(.leftMouseDragged, at: point(y: y, in: window), in: window)
        }
        try await send(.leftMouseUp, at: point(y: grab - 60, in: window), in: window)
        try await settle()
        XCTAssertEqual(browser.tabs.map(\.id), [t[0], t[3], t[1], t[2], t[4]].map(\.id))
        XCTAssertNotNil(browser.split(for: t[1]), "the pair stays a pair")
    }

    /// The column mid-carry, with a red line where the hand is, for looking
    /// at by eye: only when ROW_CARRY_SHOTS names a folder. "five" is
    /// carried up past "four", the pair and "one", and back down.
    func testLooks() async throws {
        guard let folder = ProcessInfo.processInfo.environment["ROW_CARRY_SHOTS"] else { return }
        let browser = makeBrowser()
        let t = browser.tabs
        browser.pair(t[2], with: t[1], onLeft: false)
        browser.select(t[0])
        let window = makeWindow(browser)
        try await settle()
        // five's middle: 132.
        let path = Array(stride(from: CGFloat(132), through: 10, by: -2)) + Array(stride(from: CGFloat(12), through: 132, by: 2))
        try await send(.leftMouseDown, at: point(y: path[0], in: window), in: window)
        for (n, y) in path.enumerated() {
            try await send(.leftMouseDragged, at: point(y: y, in: window), in: window)
            try await Task.sleep(for: .milliseconds(20))
            guard n % 3 == 0, let view = window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSColor.systemRed.setFill()
            NSRect(x: 0, y: view.bounds.height - Metrics.strip - y - 0.5, width: 8, height: 1).fill()
            NSRect(x: view.bounds.width - 8, y: view.bounds.height - Metrics.strip - y - 0.5, width: 8, height: 1).fill()
            NSGraphicsContext.restoreGraphicsState()
            try rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: String(format: "%@/%03d.png", folder, n)))
        }
        try await send(.leftMouseUp, at: point(y: path.last!, in: window), in: window)
        try await settle()
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
        for word in ["one", "two", "three", "four", "five"] {
            if browser.tabs.last?.isBlank == false { browser.newTab() }
            browser.tabs.last?.restore(url: URL(string: "about:blank#\(word)")!, title: word)
        }
        return browser
    }

    private func makeWindow(_ browser: Browser) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: browser.prefs.sideWidth, height: 400),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SideBar(browser: browser, prefs: browser.prefs))
        window.orderFrontRegardless()
        XCTAssertFalse(NSScreen.screens.contains { $0.frame.intersects(window.frame) }, "never on a screen")
        windows.append(window)
        return window
    }

    /// A point down the rows, from their top, in the window's terms.
    private func point(y: CGFloat, in window: NSWindow) -> NSPoint {
        NSPoint(x: 70, y: window.frame.height - Metrics.strip - y)
    }

    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(250))
    }

    private func send(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) async throws {
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
            pressure: type == .leftMouseUp ? 0 : 1
        ))
        window.sendEvent(event)
        try await Task.sleep(for: .milliseconds(30))
    }
}
