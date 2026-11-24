import AppKit
import SwiftUI
import XCTest
@testable import Search

/// The column folded away and slid out over the page (idea 1025): a tab
/// carried up or down the column to reorder it passes over the page's left
/// edge band, which lies under the column, and resting there showed a split
/// that letting go then made. Over the column only the column counts; with
/// the column away again, the page's edge splits as before. Hosted as
/// SidebarSplitDragTests is, far off every screen, with the real Fold over
/// a stand-in for the page that carries the stage's marker.
@MainActor
final class FoldedColumnDragTests: XCTestCase {
    private var browsers: [Browser] = []
    private var windows: [NSWindow] = []
    private var restorePreferences: (() -> Void)?
    private var activationPolicy: NSApplication.ActivationPolicy?

    override class func setUp() {
        TestWorld.enter()
        super.setUp()
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

    func testReorderingInTheColumnOutOverThePageSplitsNothing() async throws {
        let (browser, t, window) = try await setUp()
        browser.peeking = true
        try await settle()
        let start = rowPoint(2, in: window)
        try await send(.leftMouseDown, at: start, in: window)
        for distance in stride(from: CGFloat(4), through: 28, by: 4) {
            try await send(.leftMouseDragged, at: NSPoint(x: start.x, y: start.y - distance), in: window)
        }
        try await rest()
        XCTAssertNil(TabDrag.shared.preview, "no split shown over the column")
        XCTAssertNil(TabDrag.shared.over, "nor the page's edges")
        try await send(.leftMouseUp, at: NSPoint(x: start.x, y: start.y - 28), in: window)
        try await settle()
        XCTAssertTrue(browser.splits.isEmpty, "no pair")
        XCTAssertEqual(browser.tabs.map(\.id), [t[0].id, t[1].id, t[3].id, t[2].id], "moved down the column")
    }

    /// Away, the column's marker is off the window, so the page's left edge
    /// splits as it always did; out, it lies over the rows.
    func testTheColumnsMarkerIsOnlyOverThePageWhileItIsOut() async throws {
        let (browser, _, window) = try await setUp()
        let row = rowPoint(2, in: window)
        func columnMarkers() -> [NSRect] {
            var found: [NSRect] = []
            func walk(_ view: NSView) {
                if let marker = view as? SplitDropZone.Marker, marker.kind == .strip, marker.tab == nil,
                   !marker.isHiddenOrHasHiddenAncestor {
                    found.append(marker.convert(marker.bounds, to: nil))
                }
                view.subviews.forEach(walk)
            }
            window.contentView.map(walk)
            return found
        }
        let bounds = window.contentView?.bounds ?? .zero
        print("away:", columnMarkers())
        XCTAssertFalse(columnMarkers().contains { $0.intersects(bounds) && $0.contains(NSPoint(x: 40, y: row.y)) },
                       "away, nothing of the column is over the page's left edge")
        browser.peeking = true
        try await settle()
        print("out:", columnMarkers())
        XCTAssertTrue(columnMarkers().contains { $0.contains(row) }, "out, the column's marker is under its rows")
    }

    // MARK: - helpers

    private func setUp() async throws -> (Browser, [Search.Tab], NSWindow) {
        _ = NSApplication.shared
        activationPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.prohibited)
        let prefs = Shared.prefs
        let previous = (prefs.sidebar, prefs.usesTabGroups, prefs.splitView, prefs.listsPins, prefs.roomyTabs, prefs.sidePosition)
        restorePreferences = {
            (prefs.sidebar, prefs.usesTabGroups, prefs.splitView, prefs.listsPins, prefs.roomyTabs, prefs.sidePosition) = previous
        }
        let browser = Browser(record: WindowRecord())
        browsers.append(browser)
        browser.prefs.sidebar = true
        browser.prefs.sidePosition = .left
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
        browser.folded = true
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 1000, height: 400),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: PageUnderFold(browser: browser))
        window.orderFrontRegardless()
        XCTAssertFalse(NSScreen.screens.contains { $0.frame.intersects(window.frame) }, "never on a screen")
        windows.append(window)
        browser.window = window
        try await settle()
        return (browser, t, window)
    }

    private func rest() async throws {
        try await Task.sleep(for: .milliseconds(300))
    }

    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(400))
    }

    private func rowPoint(_ index: Int, in window: NSWindow) -> NSPoint {
        NSPoint(x: 70, y: window.frame.height - Metrics.strip - 14 - CGFloat(index) * 28)
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

/// The page the whole window wide, as with the column folded away, with the
/// stage's marker for the tab on screen, and the real Fold over it.
private struct PageUnderFold: View {
    @ObservedObject var browser: Browser

    var body: some View {
        ZStack {
            Rectangle().fill(Color.white)
            Text(browser.active?.label ?? "").font(.system(size: 22, weight: .semibold)).foregroundStyle(.black)
        }
        .background { SplitDropZone(browser: browser, tab: browser.active, kind: .stage) }
        .overlay(alignment: .leading) { Fold(browser: browser, prefs: browser.prefs) }
    }
}
