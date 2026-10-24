import AppKit
import SwiftUI
import XCTest
@testable import Search

@MainActor
final class SidebarPressTests: XCTestCase {
    private var browsers: [Browser] = []
    private var windows: [NSWindow] = []
    private var restorePreferences: (() -> Void)?
    private var activationPolicy: NSApplication.ActivationPolicy?

    override func tearDown() async throws {
        for window in windows { window.contentView = nil; window.close() }
        for browser in browsers { browser.cancelTabEdit(); browser.closeAll() }
        restorePreferences?()
        if let activationPolicy { NSApp.setActivationPolicy(activationPolicy) }
        windows.removeAll()
        browsers.removeAll()
        try await settle()
        try await super.tearDown()
    }

    override class func setUp() {
        setenv("SEARCH_PROBE", "sidebar-press-\(getpid())", 1)
        super.setUp()
    }

    func testSelectsOnPressWithoutEditingOnRelease() async throws {
        let browser = makeBrowser()
        let first = browser.tabs[0]
        let window = makeWindow(browser)
        try await settle()
        let point = rowPoint(0, in: window)
        try await send(.leftMouseDown, at: point, in: window)
        XCTAssertEqual(browser.activeID, first.id, "The page must change while the button is held")
        XCTAssertNil(browser.editingTab)
        try await send(.leftMouseUp, at: point, in: window)
        XCTAssertNil(browser.editingTab, "Releasing the selecting press must not edit the address")
        try await send(.leftMouseDown, at: point, in: window)
        try await send(.leftMouseUp, at: point, in: window)
        XCTAssertEqual(browser.editingTab, first.id, "A fresh click on the active row still edits")
    }

    func testPressThenDragStillReordersWithoutEditing() async throws {
        let browser = makeBrowser()
        let first = browser.tabs[0]
        let window = makeWindow(browser)
        try await settle()
        let start = rowPoint(0, in: window)
        try await send(.leftMouseDown, at: start, in: window)
        XCTAssertEqual(browser.activeID, first.id)
        for distance in [8.0, 20, 40, 60] {
            try await send(.leftMouseDragged, at: NSPoint(x: start.x, y: start.y - distance), in: window)
        }
        try await send(.leftMouseUp, at: NSPoint(x: start.x, y: start.y - 60), in: window)
        try await settle()
        XCTAssertEqual(browser.tabs.last?.id, first.id)
        XCTAssertNil(browser.editingTab)
    }

    func testSiblingControlsDoNotSelectTheRow() async throws {
        _ = NSApplication.shared
        var selected = 0
        var muted = 0
        var closed = 0
        let window = makeWindow(root: ControlsFixture(select: { selected += 1 }, mute: { muted += 1 }, close: { closed += 1 }))
        try await settle()
        for x in [200.0, 235] {
            let point = NSPoint(x: x, y: 20)
            try await send(.leftMouseDown, at: point, in: window)
            XCTAssertEqual(selected, 0)
            try await send(.leftMouseUp, at: point, in: window)
        }
        XCTAssertEqual(muted, 1)
        XCTAssertEqual(closed, 1)
        XCTAssertEqual(selected, 0)
    }

    func testPinSelectsOnPressAndStillDoubleClicks() async throws {
        let browser = makeBrowser()
        let first = browser.tabs[0]
        browser.pin(first)
        let window = makeWindow(browser)
        try await settle()
        let point = NSPoint(x: 40, y: window.frame.height - Metrics.strip - 17)
        try await send(.leftMouseDown, at: point, in: window)
        XCTAssertEqual(browser.activeID, first.id)
        try await send(.leftMouseUp, at: point, in: window)
        XCTAssertNil(browser.editingPin)
        try await send(.leftMouseDown, at: point, in: window)
        try await send(.leftMouseUp, at: point, in: window)
        try await send(.leftMouseDown, at: point, in: window, clicks: 2)
        try await send(.leftMouseUp, at: point, in: window, clicks: 2)
        XCTAssertEqual(browser.editingPin, first.id, "A pin already home still edits its letter on double-click")
    }

    func testEachSplitHalfFocusesOnPressWithoutEditingOnRelease() async throws {
        let browser = makeBrowser()
        let tabs = browser.tabs
        browser.prefs.splitView = true
        browser.pair(tabs[1], with: tabs[0], onLeft: false)
        browser.select(tabs[2])
        let window = makeWindow(browser)
        try await settle()
        for index in [0, 1] {
            let point = NSPoint(x: 70, y: window.frame.height - Metrics.strip - 14 - CGFloat(index) * 28)
            try await send(.leftMouseDown, at: point, in: window)
            XCTAssertEqual(browser.activeID, tabs[index].id)
            try await send(.leftMouseUp, at: point, in: window)
            XCTAssertNil(browser.editingTab)
        }
    }

    func testSplitPaddingClickAfterEarlierSelectionIsNotSuppressed() async throws {
        let browser = makeBrowser()
        let tabs = browser.tabs
        browser.prefs.splitView = true
        browser.pair(tabs[1], with: tabs[0], onLeft: false)
        browser.select(tabs[2])
        let window = makeWindow(browser)
        try await settle()
        let title = rowPoint(0, in: window)
        try await send(.leftMouseDown, at: title, in: window)
        try await send(.leftMouseUp, at: title, in: window)
        browser.select(tabs[2])
        try await settle()
        let padding = NSPoint(x: 14, y: title.y)
        try await send(.leftMouseDown, at: padding, in: window)
        XCTAssertEqual(browser.activeID, tabs[0].id, "The leading padding must also select on press")
        try await send(.leftMouseUp, at: padding, in: window)
        XCTAssertEqual(browser.activeID, tabs[0].id)
    }

    func testSmallPointerMovementDoesNotTurnSelectionIntoEditing() async throws {
        let browser = makeBrowser()
        let first = browser.tabs[0]
        let window = makeWindow(browser)
        try await settle()
        let start = rowPoint(0, in: window)
        let end = NSPoint(x: start.x + 1, y: start.y)
        try await send(.leftMouseDown, at: start, in: window)
        try await send(.leftMouseDragged, at: end, in: window)
        try await send(.leftMouseUp, at: end, in: window)
        XCTAssertEqual(browser.activeID, first.id)
        XCTAssertNil(browser.editingTab)
    }

    // What else a press in the column does, checked when it landed (#625).

    func testPressOnTheCrossLeavesTheRowAlone() async throws {
        // The cross itself answers only under a real pointer (onHover), which
        // a hidden test can't give; that it closes is checked by hand. Here:
        // its place at the end of the row takes the press, so the row isn't
        // selected under a click meant for the cross.
        let browser = makeBrowser()
        let first = browser.tabs[0], before = browser.activeID
        XCTAssertNotEqual(before, first.id)
        let window = makeWindow(browser)
        try await settle()
        let cross = NSPoint(x: browser.prefs.sideWidth - 24, y: rowPoint(0, in: window).y)
        try await send(.leftMouseDown, at: cross, in: window)
        XCTAssertEqual(browser.activeID, before, "A press on the cross must not select its row")
        try await send(.leftMouseUp, at: cross, in: window)
        try await settle()
        XCTAssertEqual(browser.activeID, before)
        XCTAssertTrue(browser.tabs.contains { $0 === first })
        let title = rowPoint(0, in: window)
        try await send(.leftMouseDown, at: title, in: window)
        XCTAssertEqual(browser.activeID, first.id, "The rest of the row still selects on press")
        try await send(.leftMouseUp, at: title, in: window)
    }

    func testRenameFieldKeepsItsClicks() async throws {
        let browser = makeBrowser()
        let first = browser.tabs[0]
        browser.select(first)
        let window = makeWindow(browser)
        try await settle()
        browser.beginTabRename(first)
        try await settle()
        // The field's own press waits in a loop for its release from the
        // queue: the release is queued first, in this process only.
        let point = rowPoint(0, in: window)
        NSApp.postEvent(try event(.leftMouseUp, at: point, in: window), atStart: false)
        window.sendEvent(try event(.leftMouseDown, at: point, in: window))
        try await settle()
        XCTAssertEqual(browser.editingTab, first.id, "A click in the name field keeps the rename open")
        XCTAssertTrue(browser.renamingTab)
        XCTAssertEqual(browser.activeID, first.id)
        browser.tabDraft = "Renamed"
        browser.commitTabEdit()
        XCTAssertEqual(first.name, "Renamed")
    }

    func testOtherButtonsDoNotSelectOnPress() async throws {
        _ = NSApplication.shared
        var selected = 0
        let window = makeWindow(root: ControlsFixture(select: { selected += 1 }, mute: {}, close: {}))
        try await settle()
        let point = NSPoint(x: 60, y: 20)
        for (down, up) in [(NSEvent.EventType.rightMouseDown, NSEvent.EventType.rightMouseUp),
                           (.otherMouseDown, .otherMouseUp)] {
            try await send(down, at: point, in: window)
            try await send(up, at: point, in: window)
        }
        XCTAssertEqual(selected, 0, "Only the left button selects on press; right-click stays the menu's")
    }

    func testPinDragStillReorders() async throws {
        let browser = makeBrowser()
        let (first, second) = (browser.tabs[0], browser.tabs[1])
        browser.pin(first)
        browser.pin(second)
        let window = makeWindow(browser)
        try await settle()
        let start = NSPoint(x: 40, y: window.frame.height - Metrics.strip - 17)
        try await send(.leftMouseDown, at: start, in: window)
        XCTAssertEqual(browser.activeID, first.id)
        for distance in [8.0, 20, 40, 60, 80] {
            try await send(.leftMouseDragged, at: NSPoint(x: start.x + distance, y: start.y), in: window)
        }
        try await send(.leftMouseUp, at: NSPoint(x: start.x + 80, y: start.y), in: window)
        try await settle()
        XCTAssertEqual(browser.tabs.prefix(2).map(\.id), [second.id, first.id], "A pin carried past the next swaps with it")
        XCTAssertNil(browser.editingPin)
    }

    /// The press that selects (TabPress) held the drag back until the
    /// release: nothing moved under the hand, the row jumped on letting go,
    /// and a pin held still a moment before letting go wasn't moved at all.
    func testRowsAndPinsMoveWhileTheButtonIsDown() async throws {
        for kind in ["row", "pin"] {
            let browser = makeBrowser()
            let tabs = browser.tabs
            if kind == "pin" { browser.pin(tabs[0]); browser.pin(tabs[1]) }
            let window = makeWindow(browser)
            try await settle()
            let before = browser.tabs.map(\.id)
            let start = kind == "pin" ? NSPoint(x: 40, y: window.frame.height - Metrics.strip - 17) : rowPoint(0, in: window)
            try await send(.leftMouseDown, at: start, in: window)
            var last = start
            for distance in [8.0, 20, 40, 60, 80] {
                last = kind == "pin" ? NSPoint(x: start.x + distance, y: start.y) : NSPoint(x: start.x, y: start.y - distance * 0.8)
                try await send(.leftMouseDragged, at: last, in: window)
            }
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertNotEqual(browser.tabs.map(\.id), before, "\(kind): moved while the button is still down")
            // Held still a little, then let go (not long: a window off the
            // screen gets no real button, and a pin's tooltip ends the drag).
            try await Task.sleep(for: .milliseconds(150))
            try await send(.leftMouseUp, at: last, in: window)
            try await settle()
            XCTAssertNotEqual(browser.tabs.map(\.id), before, "\(kind): still moved once let go")
            XCTAssertNil(browser.editingTab)
            XCTAssertNil(browser.editingPin)
            for tab in browser.tabs where tab.pin != nil { browser.unpin(tab) }
        }
    }

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
        browser.prefs.splitView = false
        browser.prefs.listsPins = false
        browser.prefs.roomyTabs = false
        for word in ["one", "two", "three"] {
            if browser.tabs.last?.isBlank == false { browser.newTab() }
            browser.tabs.last?.restore(url: URL(string: "about:blank#\(word)")!, title: word)
        }
        return browser
    }

    private func makeWindow(_ browser: Browser) -> NSWindow {
        makeWindow(root: SideBar(browser: browser, prefs: browser.prefs), width: browser.prefs.sideWidth, height: 500)
    }

    private func makeWindow<V: View>(root: V, width: CGFloat = 250, height: CGFloat = 40) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: width, height: height),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: root)
        window.orderFrontRegardless()
        windows.append(window)
        return window
    }

    private func rowPoint(_ index: Int, in window: NSWindow) -> NSPoint {
        NSPoint(x: 70, y: window.frame.height - Metrics.strip - 14 - CGFloat(index) * 30)
    }

    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(250))
    }

    private func send(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow, clicks: Int = 1) async throws {
        window.sendEvent(try event(type, at: point, in: window, clicks: clicks))
        try await Task.sleep(for: .milliseconds(30))
    }

    private func event(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow, clicks: Int = 1) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks,
            pressure: type == .leftMouseUp ? 0 : 1
        ))
    }
}

private struct ControlsFixture: View {
    let select: () -> Void
    let mute: () -> Void
    let close: () -> Void
    @State private var selected = false

    var body: some View {
        HStack(spacing: 0) {
            Text("Tab").frame(width: 185, height: 40)
                .contentShape(Rectangle())
                .modifier(TabPress(enabled: true, active: false, selected: $selected, act: select))
            Button(action: mute) { Text("Mute").frame(width: 35, height: 40) }
                .buttonStyle(.plain)
            Color.clear.frame(width: 30, height: 40)
        }
        .overlay(alignment: .trailing) {
            Color.clear.frame(width: 30, height: 40).contentShape(Rectangle()).onTapGesture(perform: close)
        }
    }
}
