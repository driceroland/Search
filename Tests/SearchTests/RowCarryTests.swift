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


    /// Carried down off the row across the top, the tab goes with the hand
    /// in a window of its own, and comes back to its row on the way back.
    /// ROW_CARRY_SHOTS: the last tab carried past the run's end, and the tab
    /// off the row, for looking at by eye.
    func testATabCarriedOffTheTopRowIsLifted() async throws {
        let browser = makeBrowser()
        browser.prefs.sidebar = false
        browser.select(browser.tabs[4])
        let shots = ProcessInfo.processInfo.environment["ROW_CARRY_SHOTS"]
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 1100, height: Metrics.strip),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: TabBar(browser: browser))
        window.orderFrontRegardless()
        windows.append(window)
        try await settle()
        let inside = NSPoint(x: window.frame.midX, y: window.frame.midY)
        TabDrag.testPointer = inside
        defer { TabDrag.testPointer = nil }
        let y = Metrics.strip / 2
        // The last of five, each about 150 wide after the lights.
        let grab: CGFloat = 800
        try await send(.leftMouseDown, at: NSPoint(x: grab, y: y), in: window)
        for x in stride(from: grab + 3, through: grab + 90, by: 3) {
            try await send(.leftMouseDragged, at: NSPoint(x: x, y: y), in: window)
        }
        XCTAssertFalse(TabLift.shared.carrying, "still on the row")
        try shoot(window.contentView, shots, "past-the-end")
        try await send(.leftMouseDragged, at: NSPoint(x: grab + 90, y: -40), in: window)
        XCTAssertTrue(TabLift.shared.carrying, "off the row")
        XCTAssertTrue(floating, "on screen")
        let before = try XCTUnwrap(TabLift.shared.content?.window).frame.origin
        TabDrag.testPointer = NSPoint(x: inside.x + 30, y: inside.y - 20)
        try await send(.leftMouseDragged, at: NSPoint(x: grab + 92, y: -40), in: window)
        let after = try XCTUnwrap(TabLift.shared.content?.window).frame.origin
        XCTAssertEqual(after.x - before.x, 30, "with the pointer")
        XCTAssertEqual(after.y - before.y, -20, "with the pointer")
        TabDrag.testPointer = inside
        try await settle()
        try shoot(TabLift.shared.content, shots, "lifted")
        try await send(.leftMouseDragged, at: NSPoint(x: grab + 90, y: y), in: window)
        XCTAssertFalse(TabLift.shared.carrying, "back on the row")
        try await send(.leftMouseDragged, at: NSPoint(x: grab + 90, y: -40), in: window)
        try await send(.leftMouseUp, at: NSPoint(x: grab + 90, y: -40), in: window)
        try await settle()
        XCTAssertFalse(TabLift.shared.carrying, "put down with the button")
        XCTAssertFalse(floating, "off the screen")
    }

    /// The row carried off can go while the button is down, and its drag
    /// never ends. Told only through that row, the floating tab stayed over
    /// every window after the button came up. (Checked after the release: a
    /// row leaves by its transition, and a hidden window draws no frames.)
    func testTheFloatingTabGoesWhenItsTabCloses() async throws {
        let browser = makeBrowser()
        let window = try await liftOffTheTopRow(browser)
        let held = try XCTUnwrap(browser.tabs.first { $0.id == TabLift.shared.shown })
        browser.closeTab(held)
        try await settle()
        try await send(.leftMouseUp, at: NSPoint(x: 400, y: -40), in: window)
        try await settle()
        XCTAssertFalse(floating, "gone with its tab")
    }

    func testTheFloatingTabGoesWhenItsRowBecomesAPairsRightHalf() async throws {
        let browser = makeBrowser()
        let window = try await liftOffTheTopRow(browser)
        let held = try XCTUnwrap(browser.tabs.first { $0.id == TabLift.shared.shown })
        let other = try XCTUnwrap(browser.tabs.first { $0.id != held.id })
        browser.pair(held, with: other, onLeft: false)
        try await settle()
        try await send(.leftMouseUp, at: NSPoint(x: 400, y: -40), in: window)
        try await settle()
        XCTAssertFalse(floating, "gone with its row")
    }

    /// A pair is one row, and either half can be picked up: the floating tab
    /// names the half a drop would take.
    func testTheFloatingTabNamesThePairsHalfUnderTheHand() async throws {
        let browser = makeBrowser()
        let t = browser.tabs
        browser.pair(t[2], with: t[1], onLeft: false)
        browser.select(t[4])
        let window = makeWindow(browser)
        browser.window = window
        try await settle()
        // The pair 30–86: its second half from 58.
        let y: CGFloat = 72
        TabDrag.testPointer = NSPoint(x: window.frame.minX + 70, y: window.frame.minY + point(y: y, in: window).y)
        defer { TabDrag.testPointer = nil }
        try await send(.leftMouseDown, at: point(y: y, in: window), in: window)
        for x in stride(from: CGFloat(73), through: browser.prefs.columnWidth + 30, by: 3) {
            try await send(.leftMouseDragged, at: NSPoint(x: x, y: point(y: y, in: window).y), in: window)
        }
        XCTAssertEqual(TabLift.shared.shown, t[2].id)
        try await send(.leftMouseUp, at: NSPoint(x: browser.prefs.columnWidth + 30, y: point(y: y, in: window).y), in: window)
        try await settle()
    }

    /// Out of the window's side, still level with the row: letting go there
    /// takes the tab away, so it has to show.
    func testLeavingTheWindowLevelWithTheRowLifts() async throws {
        let browser = makeBrowser()
        let window = try makeTopRow(browser)
        browser.window = window
        try await settle()
        let inside = NSPoint(x: window.frame.midX, y: window.frame.midY)
        TabDrag.testPointer = inside
        defer { TabDrag.testPointer = nil }
        let y = Metrics.strip / 2
        try await send(.leftMouseDown, at: NSPoint(x: 800, y: y), in: window)
        try await send(.leftMouseDragged, at: NSPoint(x: 808, y: y), in: window)
        XCTAssertFalse(TabLift.shared.carrying, "still in the window")
        TabDrag.testPointer = NSPoint(x: window.frame.maxX + 100, y: inside.y)
        try await send(.leftMouseDragged, at: NSPoint(x: 816, y: y), in: window)
        XCTAssertTrue(TabLift.shared.carrying, "past its side")
        TabDrag.testPointer = inside
        try await send(.leftMouseUp, at: NSPoint(x: 816, y: y), in: window)
        try await settle()
    }

    /// A pin can't leave its window (Browser.dragOut), so nothing says it could.
    func testAPinCarriedOffTheRowDoesNotLift() async throws {
        let browser = makeBrowser()
        let pinned = browser.tabs[0]
        browser.pin(pinned)
        // A pin is every window's: left in, the next test's rows start lower.
        defer { browser.unpin(pinned) }
        let window = try makeTopRow(browser)
        try await settle()
        TabDrag.testPointer = NSPoint(x: window.frame.midX, y: window.frame.midY)
        defer { TabDrag.testPointer = nil }
        let x = Metrics.lights + (browser.prefs.usesSpaces ? SpaceDot.width + Metrics.tabGap : 0) + Metrics.pinWidth / 2
        try await send(.leftMouseDown, at: NSPoint(x: x, y: Metrics.strip / 2), in: window)
        for y in stride(from: Metrics.strip / 2 - 6, through: -40, by: -6) {
            try await send(.leftMouseDragged, at: NSPoint(x: x, y: y), in: window)
        }
        XCTAssertEqual(CarryGuard.count, 1, "carried")
        XCTAssertFalse(TabLift.shared.carrying)
        try await send(.leftMouseUp, at: NSPoint(x: x, y: -40), in: window)
        try await settle()
    }

    /// The rows are set in from the column's edges, and measured from there:
    /// the same few points past either edge lift the tab.
    func testTheColumnLiftsAtItsOwnEdges() async throws {
        let browser = makeBrowser()
        browser.select(browser.tabs[0])
        let window = makeWindow(browser)
        try await settle()
        TabDrag.testPointer = NSPoint(x: window.frame.midX, y: window.frame.midY)
        defer { TabDrag.testPointer = nil }
        let width = browser.prefs.columnWidth
        let y = point(y: 14, in: window).y
        try await send(.leftMouseDown, at: NSPoint(x: 70, y: y), in: window)
        try await send(.leftMouseDragged, at: NSPoint(x: 60, y: y), in: window)
        try await send(.leftMouseDragged, at: NSPoint(x: -1, y: y), in: window)
        XCTAssertFalse(TabLift.shared.carrying, "just past the left edge")
        try await send(.leftMouseDragged, at: NSPoint(x: -10, y: y), in: window)
        XCTAssertTrue(TabLift.shared.carrying, "well past the left edge")
        try await send(.leftMouseDragged, at: NSPoint(x: width + 1, y: y), in: window)
        XCTAssertFalse(TabLift.shared.carrying, "just past the right edge")
        try await send(.leftMouseDragged, at: NSPoint(x: width + 10, y: y), in: window)
        XCTAssertTrue(TabLift.shared.carrying, "well past the right edge")
        try await send(.leftMouseUp, at: NSPoint(x: width + 10, y: y), in: window)
        try await settle()
    }

    private var floating: Bool { TabLift.shared.content?.window?.isVisible == true }

    private func makeTopRow(_ browser: Browser) throws -> NSWindow {
        browser.prefs.sidebar = false
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 1100, height: Metrics.strip),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: TabBar(browser: browser))
        window.orderFrontRegardless()
        windows.append(window)
        return window
    }

    /// A tab of the row across the top, carried down off it and still held.
    private func liftOffTheTopRow(_ browser: Browser) async throws -> NSWindow {
        let window = try makeTopRow(browser)
        try await settle()
        TabDrag.testPointer = NSPoint(x: window.frame.midX, y: window.frame.midY)
        addTeardownBlock { @MainActor in TabDrag.testPointer = nil }
        try await send(.leftMouseDown, at: NSPoint(x: 400, y: Metrics.strip / 2), in: window)
        for y in stride(from: Metrics.strip / 2 - 6, through: -40, by: -6) {
            try await send(.leftMouseDragged, at: NSPoint(x: 400, y: y), in: window)
        }
        XCTAssertTrue(floating, "lifted")
        return window
    }

    /// With Tabs Give on, a tab across the top has a press of its own under
    /// the drag. Holding on however far the hand went, it kept the mouse and
    /// the drag never began.
    func testATabCarriedAlongTheTopWhenTabsGive() async throws {
        let browser = makeBrowser()
        let wasGiving = browser.prefs.tabsGive
        defer { browser.prefs.tabsGive = wasGiving }
        browser.prefs.tabsGive = true
        browser.prefs.sidebar = false
        let order = browser.tabs.map(\.id)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 1100, height: Metrics.strip),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: TabBar(browser: browser))
        window.orderFrontRegardless()
        windows.append(window)
        try await settle()
        TabDrag.testPointer = NSPoint(x: window.frame.midX, y: window.frame.midY)
        defer { TabDrag.testPointer = nil }
        let y = Metrics.strip / 2
        let grab: CGFloat = 350
        try await send(.leftMouseDown, at: NSPoint(x: grab, y: y), in: window)
        for x in stride(from: grab + 3, through: grab + 240, by: 3) {
            try await send(.leftMouseDragged, at: NSPoint(x: x, y: y), in: window)
        }
        XCTAssertEqual(CarryGuard.count, 1, "carried")
        try await send(.leftMouseUp, at: NSPoint(x: grab + 240, y: y), in: window)
        try await settle()
        XCTAssertNotEqual(browser.tabs.map(\.id), order, "moved")
    }

    private func shoot(_ view: NSView?, _ folder: String?, _ name: String) throws {
        guard let view, let folder, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: "\(folder)/\(name).png"))
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
