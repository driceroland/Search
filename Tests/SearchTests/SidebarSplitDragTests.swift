import AppKit
import SwiftUI
import XCTest
@testable import Search

/// A tab carried from the column onto the page splits it again (#625 left
/// it doing nothing): the press opens the tab, so the page under the hand
/// was the tab itself. The page that was on screen before the press comes
/// back once the hand is over the page, and the split is shown and made
/// with it. Hosted as PairSeparateTests does, far off every screen, the
/// column beside a stand-in for the page that carries the stage's marker.
@MainActor
final class SidebarSplitDragTests: XCTestCase {
    private var browsers: [Browser] = []
    private var windows: [NSWindow] = []
    private var restorePreferences: (() -> Void)?
    private var activationPolicy: NSApplication.ActivationPolicy?

    override class func setUp() {
        setenv("SEARCH_PROBE", "sidebar-split-drag-\(getpid())", 1)
        super.setUp()
    }

    override class func tearDown() {
        if let world = Store.world, world.hasPrefix("sidebar-split-drag-") {
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

    // The rows: one 0–28, two 28–56, three 56–84, four 84–112. "one" is on
    // screen; "three" is pressed and carried onto the page.

    func testCarriedOntoThePageSplitsWithThePageThatWasThere() async throws {
        let (browser, t, window) = try await setUp()
        try await carry(row: 2, toPage: 0.95, in: window)
        XCTAssertEqual(browser.activeID, t[0].id, "the page from before the press is back under the hand")
        try await rest()
        XCTAssertEqual(TabDrag.shared.preview?.targetID, t[0].id, "the split is shown, with that page")
        XCTAssertEqual(TabDrag.shared.preview?.side, .right)
        try await send(.leftMouseUp, at: pagePoint(0.95, in: window), in: window)
        try await settle()
        let pair = try XCTUnwrap(browser.split(for: t[2]), "a pair")
        XCTAssertEqual(pair.tabs, [t[0].id, t[2].id], "the carried tab on the right")
        XCTAssertEqual(browser.activeID, t[2].id, "the carried tab has the keys, as with any drop onto a page")
    }

    func testCarriedOntoTheMiddleChangesOnlyThePage() async throws {
        let (browser, t, window) = try await setUp()
        try await carry(row: 2, toPage: 0.5, in: window)
        try await rest()
        XCTAssertNil(TabDrag.shared.preview, "no split shown over the middle")
        try await send(.leftMouseUp, at: pagePoint(0.5, in: window), in: window)
        try await settle()
        XCTAssertTrue(browser.splits.isEmpty, "no pair")
        XCTAssertEqual(browser.activeID, t[0].id, "the page from before stays, as when tabs opened on letting go")
    }

    func testCarriedAlongTheColumnStillOpensAndReorders() async throws {
        let (browser, t, window) = try await setUp()
        let start = rowPoint(2, in: window)
        try await send(.leftMouseDown, at: start, in: window)
        XCTAssertEqual(browser.activeID, t[2].id, "opened as the button goes down")
        for distance in stride(from: CGFloat(4), through: 40, by: 4) {
            try await send(.leftMouseDragged, at: NSPoint(x: start.x, y: start.y - distance), in: window)
        }
        try await send(.leftMouseUp, at: NSPoint(x: start.x, y: start.y - 40), in: window)
        try await settle()
        XCTAssertEqual(browser.activeID, t[2].id, "never over the page: still the one on screen")
        XCTAssertTrue(browser.splits.isEmpty)
        XCTAssertEqual(browser.tabs.last?.id, t[2].id, "moved down the column")
    }

    func testTheTabAlreadyOnScreenCarriedOntoItsPageSplitsNothing() async throws {
        let (browser, t, window) = try await setUp()
        try await carry(row: 0, toPage: 0.95, in: window)
        try await rest()
        XCTAssertNil(TabDrag.shared.preview, "nothing to split with: the press opened nothing")
        try await send(.leftMouseUp, at: pagePoint(0.95, in: window), in: window)
        try await settle()
        XCTAssertTrue(browser.splits.isEmpty)
        XCTAssertEqual(browser.activeID, t[0].id)
    }

    /// The column and the page mid-carry, for looking at by eye: only when
    /// SIDEBAR_SPLIT_SHOTS names a folder.
    func testLooks() async throws {
        guard let folder = ProcessInfo.processInfo.environment["SIDEBAR_SPLIT_SHOTS"] else { return }
        let (_, _, window) = try await setUp()
        func shoot(_ name: String) throws {
            guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(folder)/\(name).png"))
        }
        try await carry(row: 2, toPage: 0.95, in: window)
        try await rest()
        try shoot("shown")
        try await send(.leftMouseUp, at: pagePoint(0.95, in: window), in: window)
        try await settle()
        try shoot("after")
    }

    // MARK: - helpers

    private func setUp() async throws -> (Browser, [Search.Tab], NSWindow) {
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
        browser.select(t[0])
        let side = browser.prefs.sideWidth
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: side + 600, height: 400),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ColumnAndPage(browser: browser, side: side))
        window.orderFrontRegardless()
        XCTAssertFalse(NSScreen.screens.contains { $0.frame.intersects(window.frame) }, "never on a screen")
        windows.append(window)
        browser.window = window
        try await settle()
        return (browser, t, window)
    }

    /// Down on a row, then a hand's pace out of the column and across the
    /// page to `share` of its width, 6 points a move, so it never reads as
    /// at rest on the way.
    private func carry(row: Int, toPage share: CGFloat, in window: NSWindow) async throws {
        let start = rowPoint(row, in: window)
        let end = pagePoint(share, in: window)
        try await send(.leftMouseDown, at: start, in: window)
        var x = start.x
        while x < end.x {
            x = min(end.x, x + 6)
            try await send(.leftMouseDragged, at: NSPoint(x: x, y: start.y), in: window)
        }
    }

    /// Still for longer than the split waits for.
    private func rest() async throws {
        try await Task.sleep(for: .milliseconds(300))
    }

    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(250))
    }

    private func rowPoint(_ index: Int, in window: NSWindow) -> NSPoint {
        NSPoint(x: 70, y: window.frame.height - Metrics.strip - 14 - CGFloat(index) * 28)
    }

    private func pagePoint(_ share: CGFloat, in window: NSWindow) -> NSPoint {
        let side = window.frame.width - 600
        return NSPoint(x: side + 600 * share, y: window.frame.height - Metrics.strip - 70)
    }

    private func send(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) async throws {
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

/// The column, and beside it a stand-in for the page: the stage's marker for
/// the tab on screen, which is what a carried tab asks about (see
/// SplitStage's PaneLayers), with its title so a picture says which it is.
private struct ColumnAndPage: View {
    @ObservedObject var browser: Browser
    let side: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            SideBar(browser: browser, prefs: browser.prefs)
                .frame(width: side)
            ZStack {
                Rectangle().fill(Color.white)
                Text(browser.active?.label ?? "").font(.system(size: 22, weight: .semibold)).foregroundStyle(.black)
            }
            .background { SplitDropZone(browser: browser, tab: browser.active, kind: .stage) }
            .frame(width: 600)
        }
    }
}
