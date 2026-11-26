import AppKit
import SwiftUI
import XCTest
@testable import Search

/// The column as icons only (idea 413), with its own gestures: hosted in a
/// borderless window far off every screen (as PinDragTests does), never
/// activated, the mouse events sent to that window alone.
@MainActor
final class IconColumnTests: XCTestCase {
    private var browsers: [Browser] = []
    private var windows: [NSWindow] = []
    private var restorePreferences: (() -> Void)?
    private var activationPolicy: NSApplication.ActivationPolicy?

    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    override class func tearDown() {
        if let world = Store.world, world.hasPrefix("bld-ai-iconcol-") {
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

    func testTilesOfAFixedNarrowWidth() async throws {
        let browser = makeBrowser(count: 4)
        let window = makeWindow(browser)
        try await settle()
        XCTAssertEqual(browser.prefs.columnWidth, Metrics.iconColumn)
        let frames = browser.tabs.compactMap { IconTiles.frames[$0.id] }
        XCTAssertEqual(frames.count, 4, "every tab a tile")
        for frame in frames {
            XCTAssertEqual(frame.size, CGSize(width: Metrics.iconTile, height: Metrics.iconTile))
            XCTAssertEqual(frame.minX, 10)
            XCTAssertLessThanOrEqual(frame.maxX, window.frame.width)
        }
        // The title and, on every tile, where the page is: a tile has no
        // room to say it (X, 26 Nov).
        let tips = browser.tabs.compactMap { IconTiles.tips[$0.id] }
        XCTAssertEqual(tips, ["one", "two", "three", "four"].map { "\($0)\nexample.com" })
        // A pulled width is kept, not used.
        XCTAssertGreaterThanOrEqual(browser.prefs.sideWidth, Metrics.sideMin)
    }

    func testNothingGrowsUnderThePointer() async throws {
        let browser = makeBrowser(count: 3)
        _ = makeWindow(browser)
        try await settle()
        let tab = browser.tabs[1]
        let before = try XCTUnwrap(IconTiles.frames[tab.id])
        XCTAssertNotNil(Bench.hoverRows[tab.id], "the tile can be hovered from here")
        Bench.hoverRows[tab.id]?(true)
        try await settle()
        XCTAssertEqual(IconTiles.frames[tab.id], before, "the tile stays the tile under the pointer")
        XCTAssertEqual(browser.prefs.columnWidth, Metrics.iconColumn, "the column doesn't widen")
        Bench.hoverRows[tab.id]?(false)
    }

    func testATileCarriedUpTheColumnMovesItsTab() async throws {
        let browser = makeBrowser(count: 4)
        let window = makeWindow(browser)
        try await settle()
        let order = browser.tabs.map(\.id)
        let from = try XCTUnwrap(IconTiles.frames[order[3]])
        let to = try XCTUnwrap(IconTiles.frames[order[0]])
        try await drag(from: point(from.midX, from.midY, window), to: point(to.midX, to.minY + 6, window), in: window)
        XCTAssertEqual(browser.tabs.map(\.id), [order[3], order[0], order[1], order[2]])
        try await settle()
        let moved = try XCTUnwrap(IconTiles.frames[order[3]])
        XCTAssertEqual(moved.minY, to.minY, accuracy: 0.5, "drawn at the top")
    }

    func testAPairIsOneTileOfTwo() async throws {
        let browser = makeBrowser(count: 3, split: true)
        _ = makeWindow(browser)
        try await settle()
        browser.pair(browser.tabs[2], with: browser.tabs[1], onLeft: false)
        try await Task.sleep(for: .milliseconds(800))
        let left = browser.tabs[1].id, right = browser.tabs[2].id
        XCTAssertEqual(IconTiles.pairs[left], right)
        let top = try XCTUnwrap(IconTiles.frames[left]), bottom = try XCTUnwrap(IconTiles.frames[right])
        XCTAssertEqual(top.minX, bottom.minX)
        XCTAssertEqual(bottom.minY - top.minY, Metrics.iconTile, accuracy: 0.5, "one above the other, in one tile")
        XCTAssertEqual(IconTiles.tips[right], "three")
    }

    /// The cross sits in a corner, small, clear of the middle a click to
    /// pick the tab (or open its address) lands on.
    func testTheCrossIsInACornerClearOfTheMiddle() {
        let cross = IconTile.crossFrame, tile = Metrics.iconTile
        let centre = CGPoint(x: tile / 2, y: tile / 2)
        XCTAssertFalse(cross.contains(centre))
        XCTAssertLessThanOrEqual(cross.maxX, tile / 3, "in the leading third")
        XCTAssertLessThanOrEqual(cross.maxY, tile / 3, "in the top third")
        // The mark (16 pt in the middle) is left all but a sliver.
        let mark = CGRect(x: centre.x - 8, y: centre.y - 8, width: 16, height: 16)
        let shared = cross.intersection(mark)
        XCTAssertLessThanOrEqual(shared.width * shared.height, 4)
        XCTAssertLessThan(cross.width * cross.height, tile * tile * 0.2)
        XCTAssertGreaterThanOrEqual(IconTile.crossDwell, .milliseconds(400), "a pass over the column is quicker")
    }

    func testHoveredActiveTileClosesOnlyFromTheCornerAfterTheDwell() async throws {
        let browser = makeBrowser(count: 3)
        let tab = try XCTUnwrap(browser.active)
        let window = makeWindow(browser)
        try await settle()
        let frame = try XCTUnwrap(IconTiles.frames[tab.id])
        Bench.hoverRows[tab.id]?(true)
        // At once, the corner is still the tile's: nothing closes.
        try await Task.sleep(for: .milliseconds(100))
        try await click(corner(frame), in: window)
        XCTAssertTrue(browser.tabs.contains { $0.id == tab.id }, "no cross before the dwell")
        if browser.editing { browser.edit() }
        try await Task.sleep(for: .milliseconds(700))
        // Long after the dwell, a click in the middle is still the tab's.
        try await click(frame, in: window)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(browser.tabs.contains { $0.id == tab.id }, "a click in the middle never closes")
        if browser.editing { browser.edit() }
        // ⌘L (Open Address…): the field over the page, with the address in it.
        browser.edit()
        XCTAssertTrue(browser.editing)
        XCTAssertTrue(browser.typed.contains("example.com/"), browser.typed)
        browser.edit()
        // The cross, in its corner, closes.
        Bench.hoverRows[tab.id]?(false)
        Bench.hoverRows[tab.id]?(true)
        try await Task.sleep(for: .milliseconds(700))
        try await click(corner(frame), in: window)
        XCTAssertFalse(browser.tabs.contains { $0.id == tab.id })
        XCTAssertEqual(browser.tabs.count, 2)
        XCTAssertEqual(browser.ghosts.last?.url, tab.address)
        XCTAssertNil(browser.editingTab)
        _ = window
    }

    func testHoveredBackgroundTileSelectsBeforeItCanClose() async throws {
        let browser = makeBrowser(count: 3)
        let tab = browser.tabs[1]
        let window = makeWindow(browser)
        try await settle()
        let frame = try XCTUnwrap(IconTiles.frames[tab.id])
        Bench.hoverRows[tab.id]?(true)
        try await Task.sleep(for: .milliseconds(800))
        try await click(corner(frame), in: window)
        XCTAssertEqual(browser.activeID, tab.id)
        XCTAssertEqual(browser.tabs.count, 3, "The selecting click must not also close the tab")
        XCTAssertTrue(browser.ghosts.isEmpty)
        XCTAssertNil(browser.editingTab)
        // Picked, its cross waits the dwell again.
        try await click(corner(frame), in: window)
        XCTAssertEqual(browser.tabs.count, 3, "no cross the instant it is picked")
        if browser.editing { browser.edit() }
        try await Task.sleep(for: .milliseconds(700))
        try await click(corner(frame), in: window)
        XCTAssertFalse(browser.tabs.contains { $0.id == tab.id })
    }

    func testHoveredSplitHalfClosesOnlyFocusedPage() async throws {
        let browser = makeBrowser(count: 3, split: true)
        let left = browser.tabs[1], right = browser.tabs[2]
        browser.pair(right, with: left, onLeft: false)
        let window = makeWindow(browser)
        try await settle()
        browser.focusPane(right)
        Bench.hoverRows[right.id]?(true)
        try await Task.sleep(for: .milliseconds(800))
        try await click(corner(try XCTUnwrap(IconTiles.frames[right.id])), in: window)
        XCTAssertEqual(browser.tabs.count, 2)
        XCTAssertTrue(browser.tabs.contains { $0.id == left.id })
        XCTAssertFalse(browser.tabs.contains { $0.id == right.id })
        XCTAssertNil(browser.split(for: left))
        XCTAssertNil(browser.editingTab)
    }

    // MARK: -

    /// The cross's middle, as a frame to click the middle of.
    private func corner(_ frame: CGRect) -> CGRect {
        IconTile.crossFrame.offsetBy(dx: frame.minX, dy: frame.minY)
    }

    private func click(_ frame: CGRect, in window: NSWindow) async throws {
        let centre = point(frame.midX, frame.midY, window)
        try await send(.leftMouseDown, at: centre, in: window)
        try await send(.leftMouseUp, at: centre, in: window)
        try await settle()
    }

    private func makeBrowser(count: Int, split: Bool = false) -> Browser {
        _ = NSApplication.shared
        activationPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.prohibited)
        let prefs = Shared.prefs
        let previous = (prefs.sidebar, prefs.sideIcons, prefs.usesTabGroups, prefs.splitView, prefs.listsPins, prefs.usesSpaces, prefs.sharesPins)
        restorePreferences = {
            (prefs.sidebar, prefs.sideIcons, prefs.usesTabGroups, prefs.splitView, prefs.listsPins, prefs.usesSpaces, prefs.sharesPins) = previous
        }
        // Each test its own tabs: the profile's first window reads the
        // session files the last test's window left (Browser.usesFiles), so
        // run alone, these tests found every earlier test's tabs. In the
        // whole suite another class's window still held the files.
        Disk.drain()
        for name in (try? FileManager.default.contentsOfDirectory(atPath: Store.folder.path)) ?? []
        where name.hasPrefix("session") && name.hasSuffix(".json") {
            try? FileManager.default.removeItem(at: Store.folder.appendingPathComponent(name))
        }
        let browser = Browser(record: WindowRecord())
        browsers.append(browser)
        browser.prefs.tabsLayout = .icons
        browser.prefs.usesTabGroups = false
        browser.prefs.splitView = split
        browser.prefs.listsPins = false
        browser.prefs.sharesPins = false
        for word in ["one", "two", "three", "four", "five", "six"].prefix(count) {
            if browser.tabs.last?.isBlank == false { browser.newTab() }
            browser.tabs.last?.restore(url: URL(string: "https://example.com/\(word)")!, title: word)
        }
        return browser
    }

    private func makeWindow(_ browser: Browser) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: browser.prefs.columnWidth, height: 600),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SideBar(browser: browser, prefs: browser.prefs))
        window.orderFrontRegardless()
        XCTAssertFalse(NSScreen.screens.contains { $0.frame.intersects(window.frame) }, "never on a screen")
        windows.append(window)
        return window
    }

    /// From the column's top-left, in the window's terms.
    private func point(_ x: CGFloat, _ y: CGFloat, _ window: NSWindow) -> NSPoint {
        NSPoint(x: x, y: window.frame.height - y)
    }

    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(400))
    }

    private func drag(from start: NSPoint, to end: NSPoint, in window: NSWindow) async throws {
        try await send(.leftMouseDown, at: start, in: window)
        let steps = max(1, Int((hypot(end.x - start.x, end.y - start.y) / 4).rounded(.up)))
        for step in 1...steps {
            let f = CGFloat(step) / CGFloat(steps)
            try await send(.leftMouseDragged, at: NSPoint(x: start.x + (end.x - start.x) * f, y: start.y + (end.y - start.y) * f), in: window)
        }
        try await Task.sleep(for: .milliseconds(120))
        try await send(.leftMouseUp, at: end, in: window)
        try await settle()
    }

    private func send(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) async throws {
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
            pressure: type == .leftMouseUp ? 0 : 1
        ))
        // CloseClick checks the current event, as it does in the app's loop.
        NSApp.postEvent(event, atStart: true)
        let queued = try XCTUnwrap(NSApp.nextEvent(matching: .any, until: .distantPast, inMode: .default, dequeue: true))
        NSApp.sendEvent(queued)
        try await Task.sleep(for: .milliseconds(30))
    }
}
