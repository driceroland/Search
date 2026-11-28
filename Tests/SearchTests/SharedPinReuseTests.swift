import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import Search

/// Settings › Spaces & Pins › Advanced › Use the same tab across spaces, in a
/// window off screen: a pin every space shows, playing a video, taken from
/// one space to the next. Its page is the same document all the way: nothing
/// loaded again, where it was scrolled to, still playing. What each space
/// keeps in front, and what stays apart, is in Tests/pin_same_tab.py.
@MainActor
final class SharedPinReuseTests: ColumnPressCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "shared-pin-reuse-\(getpid())", 1)
        super.setUp()
    }

    func testSharedPlayerPlaysOnThroughASwipeInTheSidebar() async throws {
        try await checkSwipe(sidebar: true)
    }

    func testSharedPlayerPlaysOnThroughASwipeInTheStrip() async throws {
        try await checkSwipe(sidebar: false)
    }

    /// Two fingers to the next space and back, the pin in front in both: the
    /// page never leaves the stage, fades, pauses or loads again.
    private func checkSwipe(sidebar: Bool) async throws {
        try await withSharedPlayer(sidebar: sidebar) { scene in
            let (browser, window, pin, web) = (scene.browser, scene.window, scene.pin, scene.web)
            try await stroke(browser, -180)
            XCTAssertEqual(browser.spaceID, scene.second)
            XCTAssertEqual(browser.activeID, scene.other, "The second space keeps its own tab in front")
            try await settle()
            try await press(pinPoint(sidebar: sidebar, listed: false, in: window), in: window)
            XCTAssertEqual(browser.activeID, pin.id)
            try await settle()
            XCTAssertNil(browser.floating)
            try await uncovered(pin)

            let stage = try XCTUnwrap(web.superview as? StageView)
            let panes = try XCTUnwrap(PaneStage.stages.object(forKey: window))
            _ = try await web.evaluateJavaScript("window.pauses = 0; v.addEventListener('pause', () => window.pauses++); true")
            let time = try await web.evaluateJavaScript("v.currentTime") as? Double
            XCTAssertGreaterThan(try XCTUnwrap(time), 0)
            browser.prefs.floatsOnLeave = true
            var wrongHost = false
            var faded = false
            var samples = 0
            let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.allActivities.rawValue,
                                                              true, 0) { _, _ in
                MainActor.assumeIsolated {
                    samples += 1
                    if let layer = panes.layer, layer.animationKeys()?.contains(where: {
                        (layer.animation(forKey: $0) as? CATransition)?.type == .fade
                    }) == true { faded = true }
                    if web.superview !== stage || web.window !== window || web.isHiddenOrHasHiddenAncestor
                        || web.alphaValue < 1 || pin.cover != nil || browser.active !== pin
                        || (browser.pageAhead != nil && browser.pageAhead !== pin) {
                        wrongHost = true
                    }
                }
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            defer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
            try await stroke(browser, 180, cancelled: true)
            XCTAssertEqual(browser.spaceID, scene.second)
            try await stroke(browser, 180)
            XCTAssertEqual(browser.spaceID, scene.first)
            XCTAssertGreaterThan(samples, 0)
            XCTAssertFalse(scene.loadedAgain(), "Nothing loads again when the space is switched or the pin clicked")
            XCTAssertFalse(faded, "The page doesn't fade during the swipe")
            let pauses = try await web.evaluateJavaScript("window.pauses") as? Int
            XCTAssertEqual(pauses, 0)
            XCTAssertFalse(wrongHost, "The shared player stays on its stage through the swipe")
            XCTAssertNil(browser.floating)
            XCTAssertNil(browser.pictured)
            let intact = try await web.evaluateJavaScript("marker === 73 && location.pathname === '/watch' && scrollY === 180 && !v.paused")
            XCTAssertEqual(intact as? Bool, true)
            let after = try await web.evaluateJavaScript("v.currentTime") as? Double
            XCTAssertGreaterThan(try XCTUnwrap(after), try XCTUnwrap(time))
        }
    }

    /// Left playing for a space with another tab in front, the video floats;
    /// the pin's row clicked there, it lands in the same page.
    func testSharedPlayerFloatsAndReturnsToListedPin() async throws {
        try await withSharedPlayer(sidebar: true, listed: true, floats: true) { scene in
            let (browser, window, pin, web) = (scene.browser, scene.window, scene.pin, scene.web)
            try await stroke(browser, -180)
            XCTAssertEqual(browser.spaceID, scene.second)
            XCTAssertEqual(browser.activeID, scene.other)
            try await waitFor { browser.floating == pin.id }
            XCTAssertEqual(browser.floating, pin.id, "The player floats while another tab is in front")
            try await settle()
            try await press(pinPoint(sidebar: true, listed: true, in: window), in: window)
            XCTAssertEqual(browser.activeID, pin.id)
            try await settle()
            XCTAssertNil(browser.floating)
            // Returning from the floater keeps a picture over the page until WebKit settles.
            try await uncovered(pin)
            XCTAssertFalse(scene.loadedAgain())
            let playing = try await web.evaluateJavaScript("marker === 73 && !v.paused")
            XCTAssertEqual(playing as? Bool, true)
        }
    }

    /// The same with macOS's picture in picture: the video goes into it as
    /// its space is left, its page goes along to the next space, and back in
    /// the first, where the pin is in front, it is in its page again.
    func testPicturedPlayerComesBackWithItsSpace() async throws {
        try await withSharedPlayer(sidebar: true, floats: true, style: .system) { scene in
            let (browser, pin, web) = (scene.browser, scene.pin, scene.web)
            // macOS's own picture in picture window stays shut: the video's
            // presentation changes as WebKit's would, and nothing more (as
            // FloatUnseenTests has it).
            _ = try await inPage(web, """
                Object.defineProperties(document.querySelector('video'), {
                    webkitPresentationMode: {value: 'inline', writable: true},
                    webkitSupportsPresentationMode: {value: function () { return true; }},
                    webkitSetPresentationMode: {value: function (mode) { this.webkitPresentationMode = mode; }}
                }); true;
                """)
            browser.switchSpace(to: scene.second)
            XCTAssertEqual(browser.activeID, scene.other)
            try await waitFor { browser.pictured == pin.id }
            XCTAssertEqual(browser.pictured, pin.id, "Leaving its space sends the video into picture in picture")
            XCTAssertTrue(browser.tabs.contains { $0 === pin }, "The page came along to the second space")

            browser.switchSpace(to: scene.first)
            XCTAssertTrue(browser.active === pin, "The first space still has the pin in front, with its page")
            XCTAssertNil(browser.pictured)
            try await waitFor { try await self.presentation(web) == "inline" }
            let mode = try await presentation(web)
            XCTAssertEqual(mode, "inline", "The video is back in its page")
            XCTAssertFalse(scene.loadedAgain())
            let intact = try await web.evaluateJavaScript("marker === 73 && location.pathname === '/watch' && !v.paused")
            XCTAssertEqual(intact as? Bool, true)
        }
    }

    // MARK: - the scene

    private struct Scene {
        let browser: Browser
        let window: NSWindow
        /// The pin every space shows, in front in the first space.
        let pin: Search.Tab
        let web: PageView
        let first: UUID
        let second: UUID
        /// The tab the second space has in front.
        let other: Search.Tab.ID
        /// Whether the pin's view began loading a document since it was pinned.
        let loadedAgain: () -> Bool
    }

    /// Two spaces signed in together, and in the first a pin every space
    /// shows, in front, playing a video, taken to /watch and scrolled down.
    /// `floats`: Settings › General › Float a video when you leave its tab.
    private func withSharedPlayer(sidebar: Bool, listed: Bool = false, floats: Bool = false, style: FloatStyle = .search,
                                  _ body: (Scene) async throws -> Void) async throws {
        let browser = makeBrowser(privateRows: true)
        let prefs = browser.prefs
        let saved = (prefs.usesSpaces, prefs.pinsSameTab, prefs.floatsOnLeave)
        let floatStyle = prefs.floatStyle
        let floatPosition = Float.benchAway
        let hosts = Players.benchHosts
        let second = Space(id: UUID(), name: "Second", colour: 1, sharesSignIns: true)
        defer {
            Spaces.known[second.id] = nil
            if browser.floating != nil { browser.land(covering: false) }
            browser.unpicture()
            Float.benchAway = floatPosition
            prefs.floatStyle = floatStyle
            Players.benchHosts = hosts
            (prefs.usesSpaces, prefs.pinsSameTab, prefs.floatsOnLeave) = saved
        }
        prefs.sidebar = sidebar
        prefs.usesSpaces = true
        prefs.pinsSameTab = true
        prefs.floatsOnLeave = floats
        prefs.listsPins = listed
        prefs.floatStyle = style
        Float.benchAway = NSPoint(x: -30000, y: -30000)
        browser.spaces = [browser.space, second]
        Spaces.known[second.id] = second
        let first = browser.spaceID
        browser.switchSpace(to: second.id)
        let other = try XCTUnwrap(browser.activeID)
        browser.switchSpace(to: first)
        browser.newTab()
        let pin = try XCTUnwrap(browser.active)
        let web = pin.web
        let home = try XCTUnwrap(URL(string: "https://shared-pin-reuse.invalid/home"))
        Players.benchHosts.insert("shared-pin-reuse.invalid")
        let window: NSWindow
        if sidebar {
            window = makeWindow(root: HStack(spacing: 0) {
                SideBar(browser: browser, prefs: prefs).frame(width: prefs.sideWidth)
                SplitStage(browser: browser)
            }, width: 1000, height: 550)
        } else {
            window = makeWindow(root: VStack(spacing: 0) {
                TabBar(browser: browser).frame(height: Metrics.strip)
                SplitStage(browser: browser)
            }, width: 1000, height: 550)
        }
        browser.window = window
        web.loadHTMLString("""
            <style>body{height:4000px}video{width:640px;height:360px}</style><video muted playsinline></video>
            <script>
            const v = document.querySelector('video'), c = document.createElement('canvas');
            let n = 0;
            setInterval(() => { const g = c.getContext('2d'); g.fillStyle = n++ % 2 ? 'red' : 'blue';
                               g.fillRect(0, 0, 100, 100); }, 40);
            v.srcObject = c.captureStream(25); v.play();
            </script>
            """, baseURL: home)
        try await waitFor { try await web.evaluateJavaScript("v.currentTime > 0") as? Bool == true }
        try await hearThenMute(web)
        browser.pin(pin, listed: listed)
        browser.shareEverywhere(pin)
        defer { browser.unpin(pin) }
        XCTAssertEqual(pin.home, home)
        _ = try await web.evaluateJavaScript("history.pushState({}, '', '/watch'); window.marker = 73; scrollTo(0,180); true")
        var loadedAgain = false
        let navigation = web.observe(\.isLoading, options: [.new]) { _, change in
            if change.newValue == true { loadedAgain = true }
        }
        defer { navigation.invalidate() }
        try await body(Scene(browser: browser, window: window, pin: pin, web: web, first: first, second: second.id,
                             other: other, loadedAgain: { loadedAgain }))
    }

    /// Two fingers along the trackpad, and the wait for the rows to stand still.
    private func stroke(_ browser: Browser, _ travel: CGFloat, cancelled: Bool = false) async throws {
        let swipe = SpaceSwipe.shared
        swipe.start(for: browser)
        swipe.began()
        for _ in 0..<8 {
            _ = swipe.moved(along: travel / 8)
            try await Task.sleep(for: .milliseconds(10))
        }
        swipe.ended(cancelled: cancelled)
        for _ in 0..<100 where browser.spaceComing != nil || abs(browser.spaceSwipe) > 0.1 {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Where the pin is drawn: its row or its square in the column, or its
    /// square in the strip across the top.
    private func pinPoint(sidebar: Bool, listed: Bool, in window: NSWindow) -> NSPoint {
        guard sidebar else {
            return NSPoint(x: Metrics.lights + SpaceDot.width + Metrics.tabGap + Metrics.pinWidth / 2,
                           y: window.frame.height - Metrics.strip / 2)
        }
        return listed ? rowPoint(0, in: window) : NSPoint(x: 40, y: window.frame.height - Metrics.strip - 17)
    }

    private func press(_ point: NSPoint, in window: NSWindow) async throws {
        try await send(.leftMouseDown, at: point, in: window)
        try await send(.leftMouseUp, at: point, in: window)
    }

    /// Up to a few seconds for something a page or WebKit answers in its own
    /// time. Asked again on an error too: a page still loading drops what it
    /// was asked.
    private func waitFor(_ condition: () async throws -> Bool) async throws {
        for _ in 0..<100 {
            if (try? await condition()) == true { return }
            try await Task.sleep(for: .milliseconds(30))
        }
    }

    /// The picture a page wears while it comes back, gone.
    private func uncovered(_ pin: Search.Tab) async throws {
        try await waitFor { pin.cover == nil }
        XCTAssertNil(pin.cover)
    }

    /// In Search's own world, where its scripts for the video run.
    private func inPage(_ web: WKWebView, _ script: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Any?, Error>) in
            web.evaluateJavaScript(script, in: nil, in: Web.world) { result in
                done.resume(with: result.map { $0 as Any? })
            }
        }
    }

    /// Heard, then muted by hand, as somebody watching does: a video floats
    /// out on its own only once it was heard and is big enough to watch
    /// (Isolate.real, idea 923), and one never heard stays in its tab. Its
    /// sound turned on while it plays (a script Search runs counts as the
    /// click a page needs), then off again once the page has noted it.
    private func hearThenMute(_ web: WKWebView) async throws {
        _ = try await inPage(web, "document.querySelector('video').muted = false; true;")
        try await waitFor {
            try await self.inPage(web, "var v = document.querySelector('video'); !v.paused && !v.muted") as? Bool == true
        }
        try await Task.sleep(for: .milliseconds(200))
        _ = try await inPage(web, "document.querySelector('video').muted = true; true;")
        try await waitFor {
            try await self.inPage(web, "var v = document.querySelector('video'); !v.paused && v.muted") as? Bool == true
        }
        let heard = try await inPage(web, "var v = document.querySelector('video'); v.muted && window.__officeFloatHeard(v)") as? Bool
        XCTAssertEqual(heard, true, "The video was heard before it was muted")
    }

    private func presentation(_ web: WKWebView) async throws -> String? {
        try await inPage(web, "document.querySelector('video').webkitPresentationMode") as? String
    }
}
