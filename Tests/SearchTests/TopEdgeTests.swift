import AppKit
import WebKit
import XCTest
@testable import Search

/// The top of the window: what the menu bar's reveal in full screen pushes
/// the bars down by (idea 926), and the band along the top of a page leaving
/// what the page has to press there to the page (idea 928).
@MainActor
final class TopEdgeTests: XCTestCase {
    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    // MARK: FullScreenReveal.inset

    func testNothingOutsideFullScreen() {
        XCTAssertEqual(FullScreenReveal.inset(fullScreen: false, shown: true, revealAmount: 1, contentTop: 1000, barBottom: 937), 0)
    }

    func testNothingWhileTheTitleBarIsAway() {
        XCTAssertEqual(FullScreenReveal.inset(fullScreen: true, shown: false, revealAmount: 1, contentTop: 1000, barBottom: 937), 0)
        XCTAssertEqual(FullScreenReveal.inset(fullScreen: true, shown: true, revealAmount: 0, contentTop: 1000, barBottom: 937), 0)
        // Parked above the screen's top, out of sight.
        XCTAssertEqual(FullScreenReveal.inset(fullScreen: true, shown: true, revealAmount: nil, contentTop: 1000, barBottom: 1000), 0)
        XCTAssertEqual(FullScreenReveal.inset(fullScreen: true, shown: true, revealAmount: nil, contentTop: 1000, barBottom: 1060), 0)
    }

    /// The menu bar and the buttons' bar together, 37 and 26 points: the
    /// bars move down by all of it, not by the title bar's part alone.
    func testExactlyWhatCameDown() {
        XCTAssertEqual(FullScreenReveal.inset(fullScreen: true, shown: true, revealAmount: 1, contentTop: 1000, barBottom: 937), 63)
    }

    /// Half way through the slide, half way down.
    func testFollowsTheSlide() {
        XCTAssertEqual(FullScreenReveal.inset(fullScreen: true, shown: true, revealAmount: 0.5, contentTop: 1000, barBottom: 968.4), 32)
    }

    /// Room macOS already left at the top (the content moved down with the
    /// reveal) is not counted again: the gap the 1.0.17 strip showed.
    func testNeverTwice() {
        XCTAssertEqual(FullScreenReveal.inset(fullScreen: true, shown: true, revealAmount: 1, contentTop: 937, barBottom: 937), 0)
        XCTAssertEqual(FullScreenReveal.inset(fullScreen: true, shown: true, revealAmount: 1, contentTop: 950, barBottom: 937), 13)
    }

    // MARK: The title bar in full screen (idea 934)

    /// AppKit's own number for the most the full-screen title bar shows,
    /// where it answers: the height of what comes down with the menu bar.
    private func fullScreenMost(_ window: NSWindow) -> CGFloat? {
        guard let frame = window.contentView?.superview else { return nil }
        let sel = NSSelectorFromString("fullScreenTitlebarMaxHeight")
        guard frame.responds(to: sel) else { return nil }
        typealias Get = @convention(c) (AnyObject, Selector) -> CGFloat
        return unsafeBitCast(frame.method(for: sel), to: Get.self)(frame, sel)
    }

    /// A window dressed as Search's (Windows.swift, ContentView.dress), with
    /// the title bar's container grown to the strip as Lights does. Never
    /// ordered in.
    private final class TestWindow: NSWindow {
        private(set) var closes = 0
        private(set) var fullScreenToggles = 0

        override func performClose(_ sender: Any?) { closes += 1 }
        override func toggleFullScreen(_ sender: Any?) { fullScreenToggles += 1 }
    }

    private func searchWindow() -> TestWindow {
        _ = NSApplication.shared
        let window = TestWindow(contentRect: NSRect(x: -20000, y: -20000, width: 900, height: 600),
                                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        if let container = window.standardWindowButton(.closeButton)?.superview?.superview {
            var frame = container.frame
            frame.size.height = 52
            frame.origin.y = window.frame.height - 52
            container.frame = frame
        }
        return window
    }

    /// Going full screen adds nothing to the title bar: no toolbar, the
    /// same style, and the one accessory, the reveal's, takes no height,
    /// so what comes down is the menu bar and macOS's own title bar, as in
    /// Safari. A bottom accessory, as in 1.0.18, took 36 points more.
    func testFullScreenAddsNoHeightToTheTitleBar() {
        let window = searchWindow()
        let room = window.frame.height - window.contentLayoutRect.height
        let most = fullScreenMost(window)
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        let reveal = FullScreenReveal(window: window, browser: browser)
        reveal.entering()
        window.contentView?.superview?.layoutSubtreeIfNeeded()

        XCTAssertNil(window.toolbar, "no toolbar, not even an empty one")
        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
        XCTAssertTrue(window.titlebarAppearsTransparent)
        XCTAssertEqual(window.titleVisibility, .hidden)
        XCTAssertEqual(window.titlebarAccessoryViewControllers.count, 1)
        let bar = window.titlebarAccessoryViewControllers.first
        XCTAssertEqual(bar?.layoutAttribute, .trailing, "beside the buttons, not a row of its own under them")
        XCTAssertEqual(bar?.fullScreenMinHeight, 0, "away with the menu bar")
        XCTAssertEqual(window.frame.height - window.contentLayoutRect.height, room, "the title bar no taller")
        if let most { XCTAssertEqual(fullScreenMost(window), most, "what comes down in full screen no taller") }

        reveal.leaving()
        XCTAssertTrue(window.titlebarAccessoryViewControllers.isEmpty)
        XCTAssertEqual(window.frame.height - window.contentLayoutRect.height, room)
        window.close()
    }

    /// What 1.0.18 did, kept as the measure of the fix: a bottom accessory,
    /// however small its view, made the title bar taller.
    func testABottomAccessoryWouldAddARow() {
        let window = searchWindow()
        let room = window.frame.height - window.contentLayoutRect.height
        let bar = NSTitlebarAccessoryViewController()
        bar.view = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 1))
        bar.layoutAttribute = .bottom
        bar.fullScreenMinHeight = 0
        window.addTitlebarAccessoryViewController(bar)
        XCTAssertGreaterThan(window.frame.height - window.contentLayoutRect.height, room)
        window.close()
    }

    func testFloatingLightsHoverAndTouchExpansion() throws {
        let window = searchWindow()
        let bar = searchWindow()
        let browser = Browser(record: WindowRecord())
        browser.window = window
        browser.welcoming = false
        defer {
            browser.window = nil
            browser.closeAll()
            bar.close()
            window.close()
        }
        let content = try XCTUnwrap(window.contentView)
        let frame = try XCTUnwrap(content.superview)
        let originals = FullScreenLights.buttonTypes.compactMap { bar.standardWindowButton($0) }
        let lights = try XCTUnwrap(FullScreenLights(window: window, bar: bar, layer: CALayer(),
                                                   originals: originals) {})
        browser.fullScreenLights = lights
        frame.addSubview(lights, positioned: .above, relativeTo: nil)
        defer { lights.restore() }
        _ = lights.show(amount: 1, menuInset: 36, over: content, floating: true)
        let buttons = lights.subviews.compactMap { $0 as? NSButton }
        let close = try XCTUnwrap(buttons.first)
        let zoom = try XCTUnwrap(buttons.last)
        let width = lights.convert(close.frame, to: frame).width
        func centre(of button: NSButton) -> NSPoint {
            button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        }
        let over = centre(of: close)
        let outside = NSPoint(x: over.x + 150, y: over.y)
        XCTAssertTrue(browser.covers(content, at: over))
        XCTAssertFalse(browser.covers(content, at: outside))
        XCTAssertTrue(buttons.allSatisfy { $0.toolTip == nil })

        func move(to point: NSPoint) throws {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [],
                                                        timestamp: 0, windowNumber: window.windowNumber,
                                                        context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
            lights.mouseMoved(with: event)
        }
        let glyphs = lights.layer?.sublayers?.filter { $0.zPosition == 1 } ?? []
        XCTAssertEqual(glyphs.count, 3)
        XCTAssertTrue(glyphs.allSatisfy { $0.contents != nil })
        try move(to: over)
        XCTAssertEqual(glyphs.map(\.isHidden), [false, true, false])
        try move(to: outside)
        XCTAssertTrue(glyphs.allSatisfy(\.isHidden))

        lights.handleTouch(at: over)
        XCTAssertTrue(lights.touchExpanded)
        XCTAssertEqual(window.closes, 0)
        XCTAssertEqual(window.fullScreenToggles, 0)
        XCTAssertGreaterThan(lights.convert(close.frame, to: frame).width, width)
        let expanded = lights.frame
        for original in originals {
            original.isEnabled = false
            original.action = nil
        }
        bar.ignoresMouseEvents = false
        lights.hideNativeBar()
        XCTAssertTrue(bar.ignoresMouseEvents)
        _ = lights.show(amount: 0, menuInset: 0, over: content, floating: true)
        XCTAssertEqual(lights.frame, expanded)
        XCTAssertEqual(buttons.map(\.isEnabled), [true, false, true])
        XCTAssertEqual(glyphs.map(\.isHidden), [false, true, false])

        let exit = centre(of: zoom)
        XCTAssertIdentical(frame.hitTest(frame.convert(exit, from: nil)), zoom)
        lights.handleTouch(at: exit)
        XCTAssertEqual(window.fullScreenToggles, 1)
        XCTAssertEqual(window.closes, 0)
        XCTAssertFalse(lights.touchExpanded)

        _ = lights.show(amount: 1, menuInset: 0, over: content, floating: true)
        lights.handleTouch(at: centre(of: close))
        lights.handleTouch(at: centre(of: close))
        XCTAssertEqual(window.closes, 1)
        XCTAssertFalse(lights.touchExpanded)

        _ = lights.show(amount: 1, menuInset: 0, over: content, floating: true)
        lights.handleTouch(at: centre(of: close))
        let click = centre(of: close)
        XCTAssertIdentical(frame.hitTest(frame.convert(click, from: nil)), close)
        func mouseEvent(_ type: NSEvent.EventType) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: click, modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil,
                                             eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
        }
        // A standard button tracks the pointer synchronously until release.
        window.orderFrontRegardless()
        NSApp.postEvent(try mouseEvent(.leftMouseUp), atStart: true)
        window.sendEvent(try mouseEvent(.leftMouseDown))
        XCTAssertEqual(window.closes, 2)
        lights.endTouchExpansion()

        _ = lights.show(amount: 1, menuInset: 0, over: content, floating: false)
        XCTAssertFalse(browser.covers(content, at: centre(of: close)))
    }

    // MARK: DragStrip over a page

    private func band() -> (NSView, DragStrip.Strip) {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let strip = DragStrip.Strip(frame: NSRect(x: 0, y: 588, width: 800, height: 12))
        strip.overPage = true
        root.addSubview(strip)
        return (root, strip)
    }

    func testTheBandIsTheWindowsOverEmptyPage() {
        let (root, strip) = band()
        XCTAssertTrue(root.hitTest(NSPoint(x: 600, y: 594)) === strip)
    }

    /// Where the page said it has a field, the press goes to the page.
    func testTheBandLeavesTheFieldToThePage() {
        let (root, strip) = band()
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 592))
        root.addSubview(web, positioned: .below, relativeTo: strip)
        strip.passing = [NSRect(x: 0, y: 560, width: 360, height: 40)]
        XCTAssertTrue(root.hitTest(NSPoint(x: 120, y: 594)) === strip, "without the page's answer kept, still the window's")
        strip.page = web
        let over = root.hitTest(NSPoint(x: 120, y: 590))
        XCTAssertTrue(over.map { $0 === web || $0.isDescendant(of: web) } ?? false, "over the field the press is the page's")
        XCTAssertTrue(root.hitTest(NSPoint(x: 600, y: 594)) === strip, "beside it, still the window's")
        web.isHidden = true
        XCTAssertTrue(root.hitTest(NSPoint(x: 120, y: 590)) === strip, "a page no longer shown takes nothing")
    }

    /// A band that isn't over a page (the column's, the strip's) never
    /// keeps a page's answer.
    func testOnlyOverAPage() {
        let (_, strip) = band()
        strip.passing = [NSRect(x: 0, y: 560, width: 360, height: 40)]
        strip.overPage = false
        XCTAssertTrue(strip.passing.isEmpty)
    }

    func testThePagesScriptParses() throws {
        let script = PageUnder.script(x: 10, y: 5)
        XCTAssertTrue(script.contains("elementFromPoint(x, y)"))
        XCTAssertTrue(script.contains("/\\S/.test"), "the text test's pattern reaches the page unescaped")
        XCTAssertTrue(script.hasSuffix("})(10.0, 5.0)"))
    }
}
