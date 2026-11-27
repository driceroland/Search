import AppKit
import SwiftUI
import XCTest
@testable import Search

/// A tab carried over a page shows where letting go would split it, before
/// the hand reaches an edge or stops: TabDrag says which page it is over
/// (`over`), and the stage draws that page's two edge bands. Over the middle
/// nothing splits, and nothing used to say where would. The hand is told to
/// TabDrag as the drag gesture would tell it, through `testPointer`.
@MainActor
final class SplitZonesTests: XCTestCase {
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

    func testOverTheMiddleTheZonesShowAndNothingSplits() async throws {
        let (browser, t, window) = try await setUp()
        try await carry(t[2], to: 0.5, in: window, browser: browser)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(TabDrag.shared.over?.targetID, t[0].id, "over the page on screen")
        XCTAssertNil(TabDrag.shared.preview, "no split shown over the middle")
        let finished = TabDrag.shared.finish(browser: browser, tab: t[2])
        if case .stage = finished.drop { XCTFail("nothing splits over the middle") }
        XCTAssertNil(TabDrag.shared.over, "gone once let go")
    }

    func testAtAnEdgeTheSplitTakesOver() async throws {
        let (browser, t, window) = try await setUp()
        try await carry(t[2], to: 0.95, in: window, browser: browser)
        try await Task.sleep(for: .milliseconds(200))
        try await update(t[2], at: 0.95, in: window, browser: browser)
        XCTAssertEqual(TabDrag.shared.preview?.side, .right, "the split itself is shown")
        XCTAssertEqual(TabDrag.shared.over?.targetID, t[0].id, "still over that page")
        _ = TabDrag.shared.finish(browser: browser, tab: t[2])
        XCTAssertNil(TabDrag.shared.over)
    }

    func testAThirdInTheSplitShows() async throws {
        // A third of the way across: a quarter of the page's width split it
        // before, so the split showed only nearer the edge (idea 1392).
        let (browser, t, window) = try await setUp()
        try await carry(t[2], to: 0.33, in: window, browser: browser)
        try await Task.sleep(for: .milliseconds(200))
        try await update(t[2], at: 0.33, in: window, browser: browser)
        XCTAssertEqual(TabDrag.shared.preview?.side, .left, "the left half split, shown")
        let finished = TabDrag.shared.finish(browser: browser, tab: t[2])
        guard case .stage(let page, let onLeft) = finished.drop else { return XCTFail("splits where shown: \(finished.drop)") }
        XCTAssertEqual(page.id, t[0].id)
        XCTAssertTrue(onLeft)
    }

    /// The zones themselves, as drawn and as read (idea 1392): two fifths of
    /// the page either side, no narrower than `band` and never past half,
    /// the middle fifth splitting nothing, and the side shown kept `slack`
    /// further.
    func testZoneGeometry() {
        XCTAssertEqual(TabDrag.band(for: 1000), 400)
        XCTAssertEqual(TabDrag.band(for: 600), 240)
        XCTAssertEqual(TabDrag.band(for: 250), 120, "no narrower than the least band")
        XCTAssertEqual(TabDrag.band(for: 200), 100, "never more than half")
        XCTAssertGreaterThanOrEqual(TabDrag.band(for: 1400), 1400 / 3, "at least the outer third")
        // A page from 200 to 1200.
        func side(_ x: CGFloat, shown: TabDrag.Side? = nil) -> TabDrag.Side? { TabDrag.side(at: x, from: 200, to: 1200, shown: shown) }
        XCTAssertEqual(side(200), .left)
        XCTAssertEqual(side(533), .left, "a third in")
        XCTAssertEqual(side(600), .left, "two fifths in")
        XCTAssertNil(side(601))
        XCTAssertNil(side(700), "the middle")
        XCTAssertNil(side(799))
        XCTAssertEqual(side(800), .right)
        XCTAssertEqual(side(867), .right, "a third in from the right")
        XCTAssertEqual(side(1200), .right)
        XCTAssertNil(side(150), "off the page")
        XCTAssertNil(side(1250), "off the page")
        // Shown, a side holds on a little past its band before it lets go.
        XCTAssertEqual(side(615, shown: .left), .left)
        XCTAssertNil(side(621, shown: .left))
        XCTAssertEqual(side(785, shown: .right), .right)
        XCTAssertNil(side(785, shown: .left))
        // A page too narrow for a middle: every point a side.
        XCTAssertEqual(TabDrag.side(at: 99, from: 0, to: 200), .left)
        XCTAssertEqual(TabDrag.side(at: 101, from: 0, to: 200), .right)
    }

    func testOffThePageNoZones() async throws {
        let (browser, t, window) = try await setUp()
        try await carry(t[2], to: 0.5, in: window, browser: browser)
        XCTAssertNotNil(TabDrag.shared.over)
        // Back over the column's side of the window, off the page.
        TabDrag.testPointer = window.convertToScreen(NSRect(x: 40, y: 200, width: 0, height: 0)).origin
        _ = TabDrag.shared.update(browser: browser, tab: t[2], translation: .zero)
        XCTAssertNil(TabDrag.shared.over, "gone off the page")
        _ = TabDrag.shared.finish(browser: browser, tab: t[2])
    }

    func testThePageOfTheCarriedTabItselfShowsNone() async throws {
        let (browser, t, window) = try await setUp()
        try await carry(t[0], to: 0.5, in: window, browser: browser)
        XCTAssertNil(TabDrag.shared.over, "a page can't be split with itself")
        _ = TabDrag.shared.finish(browser: browser, tab: t[0])
    }

    // MARK: - helpers

    private func setUp() async throws -> (Browser, [Search.Tab], NSWindow) {
        _ = NSApplication.shared
        activationPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.prohibited)
        let prefs = Shared.prefs
        let previous = (prefs.usesTabGroups, prefs.splitView)
        restorePreferences = { (prefs.usesTabGroups, prefs.splitView) = previous }
        let browser = Browser(record: WindowRecord())
        browsers.append(browser)
        browser.prefs.usesTabGroups = false
        browser.prefs.splitView = true
        for word in ["one", "two", "three"] {
            if browser.tabs.last?.isBlank == false { browser.newTab() }
            browser.tabs.last?.restore(url: URL(string: "about:blank#\(word)")!, title: word)
        }
        let t = browser.tabs
        browser.select(t[0])
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 800, height: 400),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ZonesPage(browser: browser))
        window.orderFrontRegardless()
        XCTAssertFalse(NSScreen.screens.contains { $0.frame.intersects(window.frame) }, "never on a screen")
        windows.append(window)
        browser.window = window
        try await Task.sleep(for: .milliseconds(250))
        return (browser, t, window)
    }

    /// From the left of the window (off the page) to `share` of the page's
    /// width, 8 points a move.
    private func carry(_ tab: Search.Tab, to share: CGFloat, in window: NSWindow, browser: Browser) async throws {
        var x: CGFloat = 40
        let end = 200 + 600 * share
        while x < end {
            x = min(end, x + 8)
            TabDrag.testPointer = window.convertToScreen(NSRect(x: x, y: 200, width: 0, height: 0)).origin
            _ = TabDrag.shared.update(browser: browser, tab: tab, translation: CGSize(width: x - 40, height: 0))
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func update(_ tab: Search.Tab, at share: CGFloat, in window: NSWindow, browser: Browser) async throws {
        TabDrag.testPointer = window.convertToScreen(NSRect(x: 200 + 600 * share, y: 200, width: 0, height: 0)).origin
        _ = TabDrag.shared.update(browser: browser, tab: tab, translation: .zero)
        try await Task.sleep(for: .milliseconds(30))
    }
}

/// 200 points of nothing, then a stand-in for the page on screen carrying
/// the stage's marker, as SplitStage's PaneLayers does.
private struct ZonesPage: View {
    @ObservedObject var browser: Browser

    var body: some View {
        HStack(spacing: 0) {
            Color.gray.frame(width: 200)
            Color.white
                .background { SplitDropZone(browser: browser, tab: browser.active, kind: .stage) }
                .frame(width: 600)
        }
    }
}
