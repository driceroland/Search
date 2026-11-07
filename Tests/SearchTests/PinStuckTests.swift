import AppKit
import SwiftUI
import XCTest
@testable import Search

/// #846: a square carried across the grid stayed floating mid-drag. SwiftUI
/// calls a drag off, without onEnded, when what is carried changes under the
/// hand (its page starting to load as the press selects it, its icon
/// arriving); the carry has to end then too (CarryGuard). Windows far off
/// every screen, never activated, as PinDragTests.
@MainActor
final class PinStuckTests: XCTestCase {
    private var browsers: [Browser] = []
    private var windows: [NSWindow] = []
    private var restorePreferences: (() -> Void)?
    private var activationPolicy: NSApplication.ActivationPolicy?

    override class func setUp() {
        setenv("SEARCH_PROBE", "pin-stuck-\(getpid())", 1)
        super.setUp()
    }

    override class func tearDown() {
        if let world = Store.world, world.hasPrefix("pin-stuck-") {
            try? FileManager.default.removeItem(at: Store.folder)
            UserDefaults.standard.removePersistentDomain(forName: "com.officecommun.search.test.\(world)")
        }
        super.tearDown()
    }

    override func tearDown() async throws {
        for window in windows { window.contentView = nil; window.close() }
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

    /// The square picked up, its icon arriving mid-carry: called off, and
    /// put down at once rather than left held.
    func testASquareCalledOffMidCarryIsPutDown() async throws {
        let browser = makeBrowser(count: 10)
        for tab in browser.tabs.prefix(6) { browser.pin(tab) }
        let window = makeWindow(browser)
        try await settle()
        let room = browser.prefs.sideWidth - 20
        let x = 10 + room / 6, y = Metrics.strip + 17
        let last = try await carry(from: point(x: x, y: y, in: window), through: [
            point(x: x + 20, y: y, in: window),
            point(x: x + 10, y: y, in: window),
        ], in: window)
        XCTAssertEqual(CarryGuard.count, 1, "carried")
        iconArrives(browser.tabs[0], in: browser)
        try await settle()
        XCTAssertEqual(CarryGuard.count, 0, "put down as the drag was called off")
        try await send(.leftMouseUp, at: last, in: window)
        try await settle()
        XCTAssertEqual(CarryGuard.count, 0)
        XCTAssertEqual(browser.squarePins.count, 6)
        // Picked up again, it goes where it is carried — once the page the
        // first press selected has loaded, which would call it off too.
        try await Task.sleep(for: .seconds(2))
        let first = browser.tabs[0]
        try await drag(from: point(x: x, y: y, in: window), through: [
            point(x: x + room / 3, y: y, in: window),
            point(x: x + room / 3 + 4, y: y, in: window),
        ], in: window)
        XCTAssertEqual(browser.squarePins[1].id, first.id)
        XCTAssertEqual(CarryGuard.count, 0)
    }

    /// Called off out over the rows: the line it opened among them closes,
    /// it stays a pin, and the rows take clicks where they are.
    func testASquareCalledOffOverTheRowsLeavesNoLineOpen() async throws {
        let browser = makeBrowser(count: 6)
        let t = browser.tabs
        browser.pin(t[0]); browser.pin(t[1])
        browser.select(t[2])
        let window = makeWindow(browser)
        try await settle()
        let room = browser.prefs.sideWidth - 20
        let last = try await carry(from: point(x: 10 + room / 6, y: Metrics.strip + 17, in: window), through: [
            point(x: 10 + room / 6, y: Metrics.strip + 40, in: window),
            point(x: 80, y: Metrics.strip + 44 + 30 + 30 + 4, in: window),
        ], in: window)
        iconArrives(t[0], in: browser)
        try await settle()
        try await send(.leftMouseUp, at: last, in: window)
        try await settle()
        XCTAssertEqual(CarryGuard.count, 0)
        XCTAssertNotNil(t[0].pin, "nothing dropped: still a pin")
        XCTAssertEqual(browser.squarePins.map(\.id), [t[0], t[1]].map(\.id))
        let loose = browser.tabs.filter { $0.pin == nil }
        for row in [1, 2, 0] {
            try await click(point(x: 160, y: Metrics.strip + 44 + 14 + CGFloat(row) * 30, in: window), in: window)
            XCTAssertEqual(browser.activeID, loose[row].id, "row \(row) where it was before the carry")
        }
    }

    /// A row carried onto the grid whose drag never hears its end: the next
    /// press puts it down, nothing dropped, the place it opened among the
    /// squares closed; and the release, should it come late, drops nothing.
    func testARowLeftOpenIsPutDownByTheNextPress() async throws {
        let browser = makeBrowser(count: 6)
        let t = browser.tabs
        browser.pin(t[0])
        browser.select(t[5])
        let window = makeWindow(browser)
        try await settle()
        let top = Metrics.strip + 44
        let room = browser.prefs.sideWidth - 20
        let last = try await carry(from: point(x: 70, y: top + 14, in: window), through: [
            point(x: 70, y: Metrics.strip + 30, in: window),
            point(x: 10 + room / 2, y: Metrics.strip + 17, in: window),
        ], in: window)
        XCTAssertEqual(CarryGuard.count, 1, "carried")
        let empty = point(x: 100, y: 480, in: window)
        try await post(.leftMouseDown, at: empty, in: window)
        try await post(.leftMouseUp, at: empty, in: window)
        try await settle()
        XCTAssertEqual(CarryGuard.count, 0, "put down by the press")
        XCTAssertNil(t[1].pin, "not pinned")
        XCTAssertEqual(browser.squarePins.map(\.id), [t[0].id])
        // The rows where they were: no line left open among them.
        try await click(point(x: 160, y: top + 14 + 30, in: window), in: window)
        XCTAssertEqual(browser.activeID, t[2].id)
        // The release it never had, over the grid: nothing comes of it.
        try await send(.leftMouseUp, at: last, in: window)
        try await settle()
        XCTAssertNil(t[1].pin, "not pinned by a late release")
        XCTAssertEqual(browser.squarePins.map(\.id), [t[0].id])
        XCTAssertEqual(CarryGuard.count, 0)
    }

    /// A carry that heard neither its end nor its call-off ends at the next
    /// press: the button can't go down twice.
    func testTheNextPressEndsACarryLeftOpen() async throws {
        let browser = makeBrowser(count: 2)
        let window = makeWindow(browser)
        try await settle()
        var ended = 0
        CarryGuard.open(UUID()) { ended += 1 }
        let empty = point(x: 100, y: 480, in: window)
        try await post(.leftMouseDown, at: empty, in: window)
        try await post(.leftMouseUp, at: empty, in: window)
        XCTAssertEqual(ended, 1)
        XCTAssertEqual(CarryGuard.count, 0)
        try await post(.leftMouseDown, at: empty, in: window)
        try await post(.leftMouseUp, at: empty, in: window)
        XCTAssertEqual(ended, 1, "once")
    }

    // MARK: - helpers

    /// What is carried changes under the hand: an icon arriving, shown.
    private func iconArrives(_ tab: Search.Tab, in browser: Browser) {
        browser.prefs.glyph = .icons
        tab.icon = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            NSColor.systemBlue.setFill()
            rect.fill()
            return true
        }
    }

    private func makeBrowser(count: Int) -> Browser {
        _ = NSApplication.shared
        activationPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.prohibited)
        let prefs = Shared.prefs
        let previous = (prefs.sidebar, prefs.usesTabGroups, prefs.splitView, prefs.listsPins, prefs.roomyTabs,
                        prefs.usesSpaces, prefs.sharesPins, prefs.glyph)
        restorePreferences = {
            (prefs.sidebar, prefs.usesTabGroups, prefs.splitView, prefs.listsPins, prefs.roomyTabs,
             prefs.usesSpaces, prefs.sharesPins, prefs.glyph) = previous
        }
        let browser = Browser(record: WindowRecord())
        browsers.append(browser)
        browser.prefs.sidebar = true
        browser.prefs.usesTabGroups = false
        browser.prefs.splitView = false
        browser.prefs.listsPins = false
        browser.prefs.roomyTabs = false
        browser.prefs.sharesPins = false
        browser.prefs.glyph = .letters
        for word in (0..<count).map({ "t\($0)" }) {
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

    private func point(x: CGFloat, y: CGFloat, in window: NSWindow) -> NSPoint {
        NSPoint(x: x, y: window.frame.height - y)
    }

    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(250))
    }

    private func click(_ point: NSPoint, in window: NSWindow) async throws {
        try await send(.leftMouseDown, at: point, in: window)
        try await send(.leftMouseUp, at: point, in: window)
        try await settle()
    }

    /// See PinDragTests.drag: not held still long, or a tooltip ends it.
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

    private func event(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
            pressure: type == .leftMouseUp ? 0 : 1
        ))
    }

    /// Straight to the window, as PinDragTests does.
    private func send(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) async throws {
        window.sendEvent(try event(type, at: point, in: window))
        try await Task.sleep(for: .milliseconds(30))
    }

    /// Through Search's own event queue, so its monitors see it: posted to
    /// this app alone, for the off-screen window, and taken off the queue
    /// here (a test has no running NSApp to do it). The real mouse is
    /// untouched.
    private func post(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) async throws {
        NSApp.postEvent(try event(type, at: point, in: window), atStart: false)
        for _ in 0..<20 {
            guard let queued = NSApp.nextEvent(matching: .any, until: Date(timeIntervalSinceNow: 0.2),
                                               inMode: .default, dequeue: true) else { break }
            NSApp.sendEvent(queued)
            if queued.type == type, queued.window === window { break }
        }
        try await Task.sleep(for: .milliseconds(30))
    }
}
