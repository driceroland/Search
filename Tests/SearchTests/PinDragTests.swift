import AppKit
import SwiftUI
import XCTest
@testable import Search

/// A tab dragged onto the pins, and a pin dragged out among the tabs, with
/// the column's own gestures: the column is hosted in a borderless window
/// far off every screen (as SidebarPressTests does), never activated, and
/// the mouse events go to that window alone.
@MainActor
final class PinDragTests: XCTestCase {
    private var browsers: [Browser] = []
    private var windows: [NSWindow] = []
    private var restorePreferences: (() -> Void)?
    private var activationPolicy: NSApplication.ActivationPolicy?

    override class func setUp() {
        setenv("SEARCH_PROBE", "pin-drag-\(getpid())", 1)
        super.setUp()
    }

    /// This run's world is its own (by pid): gone with it.
    override class func tearDown() {
        if let world = Store.world, world.hasPrefix("pin-drag-") {
            try? FileManager.default.removeItem(at: Store.folder)
            UserDefaults.standard.removePersistentDomain(forName: "com.officecommun.search.test.\(world)")
        }
        super.tearDown()
    }

    override func tearDown() async throws {
        for window in windows { window.contentView = nil; window.close() }
        // Pins are kept for the space in every window (Pins.swift): put
        // down, or the next test's window would hold them too.
        for browser in browsers {
            browser.cancelTabEdit()
            for tab in browser.tabs where tab.pin != nil { browser.unpin(tab) }
            browser.closeAll()
        }
        restorePreferences?()
        if let activationPolicy { NSApp.setActivationPolicy(activationPolicy) }
        windows.removeAll()
        browsers.removeAll()
        try await Task.sleep(for: .milliseconds(250))
        try await super.tearDown()
    }

    // MARK: - the pure parts

    func testZones() {
        XCTAssertEqual(PinDrop.zone(CGPoint(x: 50, y: 10), width: 212, gridBottom: 34, listed: nil), .squares)
        XCTAssertEqual(PinDrop.zone(CGPoint(x: 50, y: 38), width: 212, gridBottom: 34, listed: nil), .squares, "the upper half of the margin is the grid's")
        XCTAssertEqual(PinDrop.zone(CGPoint(x: 50, y: 41), width: 212, gridBottom: 34, listed: nil), .loose)
        XCTAssertEqual(PinDrop.zone(CGPoint(x: 50, y: -20), width: 212, gridBottom: nil, listed: nil), .squares, "no pins: above the rows makes the first")
        XCTAssertEqual(PinDrop.zone(CGPoint(x: 50, y: 5), width: 212, gridBottom: nil, listed: nil), .loose)
        XCTAssertEqual(PinDrop.zone(CGPoint(x: 50, y: 60), width: 212, gridBottom: 34,
                                    listed: CGRect(x: 0, y: 44, width: 212, height: 58)), .listed)
        XCTAssertEqual(PinDrop.zone(CGPoint(x: 400, y: 10), width: 212, gridBottom: 34, listed: nil), .none, "over the page: not the column")
    }

    func testRowSlots() {
        let rows: [CGFloat] = [28, 28, 28]
        XCTAssertEqual(PinDrop.rowSlot(y: 5, heights: rows, gap: 2, ghost: nil), 0)
        XCTAssertEqual(PinDrop.rowSlot(y: 20, heights: rows, gap: 2, ghost: nil), 1)
        XCTAssertEqual(PinDrop.rowSlot(y: 200, heights: rows, gap: 2, ghost: nil), 3)
        // A line open at 1: anywhere on it keeps it, and the rows after it
        // are where they now are.
        XCTAssertEqual(PinDrop.rowSlot(y: 31, heights: rows, gap: 2, ghost: (1, 28)), 1)
        XCTAssertEqual(PinDrop.rowSlot(y: 57, heights: rows, gap: 2, ghost: (1, 28)), 1)
        XCTAssertEqual(PinDrop.rowSlot(y: 70, heights: rows, gap: 2, ghost: (1, 28)), 1, "upper half of the row now under it")
        XCTAssertEqual(PinDrop.rowSlot(y: 80, heights: rows, gap: 2, ghost: (1, 28)), 2)
    }

    func testGridSlots() {
        let cells = (0..<3).map { CGRect(x: CGFloat($0) * 70, y: 0, width: 66, height: 34) }
        XCTAssertEqual(PinDrop.gridSlot(CGPoint(x: 10, y: 17), cells: cells), 0)
        XCTAssertEqual(PinDrop.gridSlot(CGPoint(x: 100, y: 17), cells: cells), 1)
        XCTAssertEqual(PinDrop.gridSlot(CGPoint(x: 300, y: 60), cells: cells), 2)
    }

    func testPinSlotKeepsSharedPinsAhead() {
        let browser = makeBrowser(count: 4)
        let t = browser.tabs
        browser.pin(t[0]); browser.pin(t[1])
        t[0].everywhere = true
        browser.prefs.usesSpaces = true
        browser.prefs.sharesPins = true
        XCTAssertEqual(browser.pinSlot(t[2], listed: false, proposed: 0), 1, "after the one every space shows")
        XCTAssertEqual(browser.pinSlot(t[2], listed: false, proposed: 9), 2)
        browser.prefs.sharesPins = false
        XCTAssertEqual(browser.pinSlot(t[2], listed: false, proposed: 0), 0)
    }

    // MARK: - the model, as the drop calls it

    func testDroppedOnThePinsPinsInPlaceAndKeepsThePage() {
        let browser = makeBrowser(count: 5)
        let t = browser.tabs
        browser.pin(t[0]); browser.pin(t[1])
        let page = t[3].built
        XCTAssertTrue(browser.pinDropped(t[3], listed: false, at: 1))
        XCTAssertEqual(browser.tabs.map(\.id), [t[0], t[3], t[1], t[2], t[4]].map(\.id))
        XCTAssertNotNil(t[3].pin)
        XCTAssertTrue(t[3].built === page, "the same web view, not a reload")
        XCTAssertTrue(browser.unpinDropped(t[0], at: 1))
        XCTAssertEqual(browser.tabs.map(\.id), [t[3], t[1], t[2], t[0], t[4]].map(\.id))
        XCTAssertNil(t[0].pin)
        XCTAssertNil(t[0].home)
    }

    func testAPairIsNotPinnedByADrag() {
        let browser = makeBrowser(count: 4)
        let t = browser.tabs
        browser.prefs.splitView = true
        browser.pair(t[2], with: t[1], onLeft: false)
        XCTAssertFalse(browser.pinsByDrag(t[1]))
        XCTAssertFalse(browser.pinDropped(t[1], listed: false, at: 0))
        XCTAssertNil(t[1].pin)
        XCTAssertNotNil(browser.split(for: t[1]), "the pair stays a pair")
    }

    // MARK: - the real gestures

    func testRowDraggedOntoTheGridBecomesAPinWhereItWasLetGo() async throws {
        let browser = makeBrowser(count: 5)
        let t = browser.tabs
        browser.pin(t[0]); browser.pin(t[1])
        // On screen first, so its page is made before the drag, as a tab
        // you pick up is selected by the press that picks it up.
        browser.select(t[3])
        let window = makeWindow(browser)
        try await settle()
        let page = t[3].built
        XCTAssertNotNil(page)
        // The rows start under the grid: 34 + 10.
        let start = point(x: 70, y: Metrics.strip + 44 + 14 + 30, in: window)
        // Between the two squares: the middle of three places.
        let room = browser.prefs.sideWidth - 20
        let middle = 10 + room / 2
        try await drag(from: start, through: [
            point(x: 70, y: Metrics.strip + 44, in: window),
            point(x: middle, y: Metrics.strip + 30, in: window),
            point(x: middle, y: Metrics.strip + 17, in: window),
        ], in: window)
        XCTAssertEqual(browser.tabs.map(\.id), [t[0], t[3], t[1], t[2], t[4]].map(\.id))
        XCTAssertNotNil(t[3].pin, "pinned")
        XCTAssertFalse(t[3].listed)
        XCTAssertTrue(t[3].built === page, "the same web view")
    }

    func testPinDraggedAmongTheRowsBecomesATabThere() async throws {
        let browser = makeBrowser(count: 5)
        let t = browser.tabs
        browser.pin(t[0]); browser.pin(t[1])
        browser.select(t[2])
        let window = makeWindow(browser)
        try await settle()
        let room = browser.prefs.sideWidth - 20
        let start = point(x: 10 + room / 6, y: Metrics.strip + 17, in: window)
        // Into the upper half of the second row (t[3]), as the rows stand
        // once a line has opened for it above the first: 30 lower.
        try await drag(from: start, through: [
            point(x: 10 + room / 6, y: Metrics.strip + 40, in: window),
            point(x: 80, y: Metrics.strip + 44 + 30 + 30 + 4, in: window),
            point(x: 80, y: Metrics.strip + 44 + 30 + 30 + 4, in: window),
        ], in: window)
        XCTAssertNil(t[0].pin, "unpinned")
        XCTAssertEqual(browser.tabs.map(\.id), [t[1], t[2], t[0], t[3], t[4]].map(\.id))
    }

    func testDropsWhileTheRowsScroll() async throws {
        // More rows than the window holds: they scroll, under the grid.
        let browser = makeBrowser(count: 20)
        let t = browser.tabs
        browser.pin(t[0]); browser.pin(t[1])
        browser.select(t[2])
        let window = makeWindow(browser)
        try await settle()
        let room = browser.prefs.sideWidth - 20
        try await drag(from: point(x: 10 + room / 6, y: Metrics.strip + 17, in: window), through: [
            point(x: 10 + room / 6, y: Metrics.strip + 40, in: window),
            point(x: 80, y: Metrics.strip + 44 + 30 + 30 + 4, in: window),
        ], in: window)
        XCTAssertNil(t[0].pin)
        XCTAssertEqual(browser.tabs.prefix(4).map(\.id), [t[1], t[2], t[0], t[3]].map(\.id))
        // And back up into the grid, first.
        try await drag(from: point(x: 70, y: Metrics.strip + 44 + 14 + 30, in: window), through: [
            point(x: 30, y: Metrics.strip + 30, in: window),
            point(x: 20, y: Metrics.strip + 17, in: window),
        ], in: window)
        XCTAssertEqual(browser.squarePins.map(\.id), [t[0], t[1]].map(\.id))
    }

    func testFirstPinMadeAboveTheRows() async throws {
        let browser = makeBrowser(count: 3)
        let t = browser.tabs
        let window = makeWindow(browser)
        try await settle()
        try await drag(from: point(x: 70, y: Metrics.strip + 14 + 30, in: window), through: [
            point(x: 70, y: Metrics.strip + 4, in: window),
            point(x: 70, y: Metrics.strip - 12, in: window),
            point(x: 70, y: Metrics.strip + 10, in: window),
        ], in: window)
        XCTAssertNotNil(t[1].pin)
        XCTAssertEqual(browser.tabs.first?.id, t[1].id)
    }

    func testReorderingStaysWithinEachBlock() async throws {
        let browser = makeBrowser(count: 5)
        let t = browser.tabs
        browser.pin(t[0]); browser.pin(t[1])
        browser.select(t[2])
        let window = makeWindow(browser)
        try await settle()
        // A row carried down its own list.
        try await drag(from: point(x: 70, y: Metrics.strip + 44 + 14, in: window), through: [
            point(x: 70, y: Metrics.strip + 44 + 14 + 30, in: window),
            point(x: 70, y: Metrics.strip + 44 + 14 + 62, in: window),
        ], in: window)
        XCTAssertEqual(browser.tabs.map(\.id), [t[0], t[1], t[3], t[4], t[2]].map(\.id))
        XCTAssertEqual(browser.pinnedCount, 2)
        // A square carried along the grid.
        let room = browser.prefs.sideWidth - 20
        try await drag(from: point(x: 10 + room / 6, y: Metrics.strip + 17, in: window), through: [
            point(x: 10 + room / 2, y: Metrics.strip + 17, in: window),
            point(x: 10 + room / 2 + 4, y: Metrics.strip + 17, in: window),
        ], in: window)
        XCTAssertEqual(browser.tabs.prefix(2).map(\.id), [t[1], t[0]].map(\.id))
        XCTAssertEqual(browser.pinnedCount, 2)
    }

    func testRowDraggedOntoThePinnedRows() async throws {
        let browser = makeBrowser(count: 5, rows: true)
        let t = browser.tabs
        browser.pin(t[0]); browser.pin(t[1], listed: true)
        browser.select(t[2])
        let window = makeWindow(browser)
        try await settle()
        // Grid 34 + 10; the pinned row 28 + 2 under it; the line 18 + 2; the rows.
        let rowsTop = Metrics.strip + 44 + 30 + 20
        try await drag(from: point(x: 70, y: rowsTop + 14 + 30, in: window), through: [
            point(x: 70, y: rowsTop, in: window),
            point(x: 70, y: Metrics.strip + 44 + 20, in: window),
            point(x: 70, y: Metrics.strip + 44 + 22, in: window),
        ], in: window)
        XCTAssertNotNil(t[3].pin)
        XCTAssertTrue(t[3].listed, "a pinned row")
        XCTAssertEqual(browser.listedPins.map(\.id), [t[1], t[3]].map(\.id))
        // And that pinned row carried up into the grid: a square, first.
        try await drag(from: point(x: 70, y: Metrics.strip + 44 + 30 + 14, in: window), through: [
            point(x: 40, y: Metrics.strip + 30, in: window),
            point(x: 20, y: Metrics.strip + 17, in: window),
        ], in: window)
        XCTAssertFalse(t[3].listed)
        XCTAssertEqual(browser.squarePins.map(\.id), [t[3], t[0]].map(\.id))
    }

    func testAPairRowGetsNoPlaceInTheGrid() async throws {
        let browser = makeBrowser(count: 4)
        let t = browser.tabs
        browser.prefs.splitView = true
        browser.pin(t[0])
        browser.pair(t[2], with: t[1], onLeft: false)
        browser.select(t[3])
        let window = makeWindow(browser)
        try await settle()
        try await drag(from: point(x: 70, y: Metrics.strip + 44 + 14, in: window), through: [
            point(x: 70, y: Metrics.strip + 30, in: window),
            point(x: 70, y: Metrics.strip + 17, in: window),
        ], in: window)
        XCTAssertNil(t[1].pin)
        XCTAssertNil(t[2].pin)
        XCTAssertNotNil(browser.split(for: t[1]))
        XCTAssertEqual(browser.pinnedCount, 1)
    }

    // MARK: - helpers

    private func makeBrowser(count: Int, rows: Bool = false) -> Browser {
        _ = NSApplication.shared
        activationPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.prohibited)
        let prefs = Shared.prefs
        let previous = (prefs.sidebar, prefs.usesTabGroups, prefs.splitView, prefs.listsPins, prefs.roomyTabs,
                        prefs.usesSpaces, prefs.sharesPins)
        restorePreferences = {
            (prefs.sidebar, prefs.usesTabGroups, prefs.splitView, prefs.listsPins, prefs.roomyTabs,
             prefs.usesSpaces, prefs.sharesPins) = previous
        }
        let browser = Browser(record: WindowRecord())
        browsers.append(browser)
        browser.prefs.sidebar = true
        browser.prefs.usesTabGroups = false
        browser.prefs.splitView = false
        browser.prefs.listsPins = rows
        browser.prefs.roomyTabs = false
        browser.prefs.sharesPins = false
        for word in ["one", "two", "three", "four", "five", "six"].prefix(count) {
            if browser.tabs.last?.isBlank == false { browser.newTab() }
            browser.tabs.last?.restore(url: URL(string: "about:blank#\(word)")!, title: word)
        }
        return browser
    }

    private func makeWindow(_ browser: Browser) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: browser.prefs.sideWidth, height: 500),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SideBar(browser: browser, prefs: browser.prefs))
        window.orderFrontRegardless()
        XCTAssertFalse(NSScreen.screens.contains { $0.frame.intersects(window.frame) }, "never on a screen")
        windows.append(window)
        return window
    }

    /// A point given from the column's top-left, in the window's terms.
    private func point(x: CGFloat, y: CGFloat, in window: NSWindow) -> NSPoint {
        NSPoint(x: x, y: window.frame.height - y)
    }

    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(250))
    }

    /// Down at `start`, through `points` a few points at a time, and up at
    /// the last. Not held still long before letting go: a window that isn't
    /// on a screen gets these events from the test, not from the mouse, so
    /// AppKit doesn't know a button is down and puts up a pin's tooltip after
    /// half a second at rest, which ends the drag. A real hand's button is
    /// down, and no tooltip comes during a drag.
    private func drag(from start: NSPoint, through points: [NSPoint], in window: NSWindow) async throws {
        let last = try await carry(from: start, through: points, in: window)
        try await Task.sleep(for: .milliseconds(120))
        try await send(.leftMouseUp, at: last, in: window)
        try await settle()
    }

    private func carry(from start: NSPoint, through points: [NSPoint], in window: NSWindow) async throws -> NSPoint {
        try await send(.leftMouseDown, at: start, in: window)
        var last = start
        for target in points {
            // As a hand moves: a few points at a time.
            let steps = max(1, Int((hypot(target.x - last.x, target.y - last.y) / 4).rounded(.up)))
            for step in 1...steps {
                let f = CGFloat(step) / CGFloat(steps)
                let p = NSPoint(x: last.x + (target.x - last.x) * f, y: last.y + (target.y - last.y) * f)
                try await send(.leftMouseDragged, at: p, in: window)
            }
            last = target
        }
        return last
    }

    /// What the column looks like mid-drag, for looking at by eye: only
    /// when PIN_DRAG_SHOTS names a folder. The column is drawn into a
    /// picture, never onto a screen.
    func testLooks() async throws {
        guard let folder = ProcessInfo.processInfo.environment["PIN_DRAG_SHOTS"] else { return }
        func shoot(_ name: String, _ window: NSWindow) async throws {
            try await Task.sleep(for: .milliseconds(350))
            guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(folder)/\(name).png"))
        }
        let room = Shared.prefs.sideWidth - 20
        for (name, rows) in [("row-over-grid", false), ("pin-over-rows", false), ("row-over-pinned-rows", true), ("first-pin", false), ("pair-refused", false)] {
            let browser = makeBrowser(count: 5, rows: rows)
            let t = browser.tabs
            if name == "pair-refused" { browser.prefs.splitView = true; browser.pair(t[3], with: t[2], onLeft: false) }
            if name != "first-pin" { browser.pin(t[0]); browser.pin(t[1], listed: rows) }
            browser.select(t[4])
            let window = makeWindow(browser)
            try await settle()
            var last: NSPoint
            switch name {
            case "row-over-grid", "pair-refused":
                last = try await carry(from: point(x: 70, y: Metrics.strip + 44 + 14 + (name == "pair-refused" ? 0 : 30), in: window), through: [
                    point(x: 10 + room / 2, y: Metrics.strip + 30, in: window), point(x: 10 + room / 2, y: Metrics.strip + 17, in: window)], in: window)
            case "pin-over-rows":
                last = try await carry(from: point(x: 10 + room / 6, y: Metrics.strip + 17, in: window), through: [
                    point(x: 80, y: Metrics.strip + 44 + 64, in: window)], in: window)
            case "row-over-pinned-rows":
                let rowsTop = Metrics.strip + 44 + 30 + 20
                last = try await carry(from: point(x: 70, y: rowsTop + 14 + 30, in: window), through: [
                    point(x: 70, y: Metrics.strip + 44 + 22, in: window)], in: window)
            default:
                last = try await carry(from: point(x: 70, y: Metrics.strip + 14 + 30, in: window), through: [
                    point(x: 70, y: Metrics.strip - 12, in: window), point(x: 70, y: Metrics.strip + 10, in: window)], in: window)
            }
            try await shoot(name, window)
            try await send(.leftMouseUp, at: last, in: window)
            try await settle()
            try await shoot(name + "-after", window)
            for tab in browser.tabs where tab.pin != nil { browser.unpin(tab) }
            window.contentView = nil
            window.close()
        }
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
