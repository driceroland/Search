import AppKit
import Combine
import SwiftUI
import XCTest
@testable import Search

/// The column's edge and the side panel's handle, pulled: what they move
/// follows the pointer, and the setting is written once, when it is let go.
/// Written on every step, each one was a write to the settings and a change
/// heard by every window and everything in it.
@MainActor
final class ColumnDragTests: XCTestCase {
    private var browsers: [Browser] = []
    private var windows: [NSWindow] = []
    private var restorePreferences: (() -> Void)?
    private var activationPolicy: NSApplication.ActivationPolicy?
    private var bag: Set<AnyCancellable> = []
    private var published = 0
    private var heard = 0
    private var written = 0

    override class func setUp() {
        setenv("SEARCH_PROBE", "column-drag-\(getpid())", 1)
        super.setUp()
    }

    override func tearDown() async throws {
        bag.removeAll()
        for window in windows { window.contentView = nil; window.close() }
        for browser in browsers { browser.closeAll() }
        restorePreferences?()
        if let activationPolicy { NSApp.setActivationPolicy(activationPolicy) }
        windows.removeAll()
        browsers.removeAll()
        try await settle()
        try await super.tearDown()
    }

    func testColumnEdgeWritesItsWidthOnceAndThePageFollowsIt() async throws {
        let browser = makeBrowser()
        let prefs = browser.prefs
        prefs.sideWidth = Metrics.side
        let window = makeWindow(root: ContentView(browser: browser), width: 1000, height: 600)
        browser.window = window
        try await settle()
        let start = prefs.sideWidth
        XCTAssertEqual(try XCTUnwrap(pageFrame(in: window)).minX, start, accuracy: 1, "The page starts where the column ends")
        count(browser)

        let y = window.frame.height / 2
        let grab = NSPoint(x: start - 3, y: y)
        let steps = 12
        try await send(.leftMouseDown, at: grab, in: window)
        for step in 1...steps {
            try await send(.leftMouseDragged, at: NSPoint(x: grab.x + CGFloat(step) * 4, y: y), in: window)
        }
        let moved = CGFloat(steps) * 4
        let held = try XCTUnwrap(pageFrame(in: window))
        print("column edge, \(steps) steps held: \(published) settings published, \(heard) window changes, \(written) defaults written")
        XCTAssertEqual(held.minX, start + moved, accuracy: 1, "The page follows the edge while it is held")
        XCTAssertEqual(published, 0, "Nothing about the settings is published while the edge is held")
        XCTAssertEqual(heard, 0, "Nor is the window told")
        XCTAssertEqual(prefs.sideWidth, start, "The setting waits for the edge to be let go")

        try await send(.leftMouseUp, at: NSPoint(x: grab.x + moved, y: y), in: window)
        try await settle()
        XCTAssertEqual(prefs.sideWidth, start + moved, accuracy: 1, "Let go, the width is kept")
        XCTAssertEqual(published, 1, "and published once")
        XCTAssertEqual(try XCTUnwrap(pageFrame(in: window)).minX, start + moved, accuracy: 1,
                       "The page stays where the edge was let go")
    }

    func testSidePanelHandleWritesItsWidthOnce() async throws {
        let browser = makeBrowser()
        let prefs = browser.prefs
        prefs.sidePanelWidth = Preferences.sidePanelStart
        let start = prefs.sidePanelWidth
        var live: [CGFloat?] = []
        let panel = SidePanelBeside(browser: browser, prefs: prefs, onLeft: false, card: true, width: start,
                                    onDrag: { live.append($0) })
        let window = makeWindow(root: panel, width: Metrics.cardGap + start, height: 500)
        try await settle()
        count(browser)

        // The handle is the card's gap, on the panel's left: pulled left, the
        // panel is wider.
        let grab = NSPoint(x: Metrics.cardGap / 2, y: 250)
        let steps = 10
        try await send(.leftMouseDown, at: grab, in: window)
        for step in 1...steps {
            try await send(.leftMouseDragged, at: NSPoint(x: grab.x - CGFloat(step) * 4, y: 250), in: window)
        }
        let moved = CGFloat(steps) * 4
        print("side panel handle, \(steps) steps held: \(published) settings published, \(heard) window changes, \(written) defaults written")
        XCTAssertEqual(live.last ?? nil, start + moved, "The width as drawn follows the handle")
        XCTAssertEqual(published, 0, "Nothing about the settings is published while the handle is held")
        XCTAssertEqual(prefs.sidePanelWidth, start, "The setting waits for the handle to be let go")

        try await send(.leftMouseUp, at: NSPoint(x: grab.x - moved, y: 250), in: window)
        try await settle()
        XCTAssertEqual(prefs.sidePanelWidth, start + moved, "Let go, the width is kept")
        XCTAssertEqual(published, 1, "and published once")
        XCTAssertNil(live.last ?? nil, "and the window goes back to the setting")
    }

    // MARK: - helpers

    private func makeBrowser() -> Browser {
        _ = NSApplication.shared
        activationPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.prohibited)
        let prefs = Shared.prefs
        let previous = (prefs.sidebar, prefs.splitView, prefs.sideWidth, prefs.sideHides, prefs.sidePanelWidth)
        restorePreferences = {
            (prefs.sidebar, prefs.splitView, prefs.sideWidth, prefs.sideHides, prefs.sidePanelWidth) = previous
        }
        let browser = Browser(record: WindowRecord())
        browsers.append(browser)
        browser.prefs.sidebar = true
        browser.prefs.splitView = false
        browser.prefs.sideHides = false
        browser.folded = false
        // The welcome would lie over the whole window.
        browser.welcoming = false
        // A tab with somewhere to be: a blank one stands the address field
        // over the page.
        browser.tabs.last?.restore(url: URL(string: "about:blank#one")!, title: "one")
        return browser
    }

    private func count(_ browser: Browser) {
        published = 0
        heard = 0
        written = 0
        browser.prefs.objectWillChange.sink { [weak self] in self?.published += 1 }.store(in: &bag)
        browser.objectWillChange.sink { [weak self] in self?.heard += 1 }.store(in: &bag)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .sink { [weak self] _ in self?.written += 1 }.store(in: &bag)
    }

    private func makeWindow<V: View>(root: V, width: CGFloat, height: CGFloat) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: width, height: height),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: root)
        window.orderFrontRegardless()
        windows.append(window)
        return window
    }

    /// Where the page's stage is, in the window.
    private func pageFrame(in window: NSWindow) -> CGRect? {
        func find(_ view: NSView) -> NSView? {
            if view is StageView { return view }
            for sub in view.subviews { if let found = find(sub) { return found } }
            return nil
        }
        window.contentView?.layoutSubtreeIfNeeded()
        guard let root = window.contentView, let stage = find(root) else { return nil }
        return stage.convert(stage.bounds, to: nil)
    }

    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(400))
    }

    private func send(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) async throws {
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
            pressure: type == .leftMouseUp ? 0 : 1
        ))
        window.sendEvent(event)
        try await Task.sleep(for: .milliseconds(20))
    }
}
