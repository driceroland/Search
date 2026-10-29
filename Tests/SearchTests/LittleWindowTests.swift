import AppKit
import WebKit
import XCTest
@testable import Search

@MainActor
final class LittleWindowTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "little-window-\(getpid())", 1)
        super.setUp()
    }

    override func setUp() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
    }

    private func preview(for browser: Browser) throws -> (LittleWindow, NSWindow) {
        LittleWindow.show(try XCTUnwrap(URL(string: "about:blank")), for: browser, front: false)
        let little = try XCTUnwrap(LittleWindow.all.last)
        let window = try XCTUnwrap(NSApp.window(withWindowNumber: little.windowNumber))
        return (little, window)
    }

    func testPreviewActivationKeepsAutomaticPictureInPicture() async throws {
        try await checkPreviewActivation(style: .system)
    }

    func testPreviewActivationKeepsSearchsFloatingWindow() async throws {
        try await checkPreviewActivation(style: .search)
    }

    private func checkPreviewActivation(style: FloatStyle) async throws {
        try await withPlayer(style: style) { browser, owner, floating in
            browser.appLeft()
            try await waitFor(floating)
            XCTAssertTrue(floating(), "leaving the app floats the video")

            let (little, previewWindow) = try preview(for: browser)
            defer { little.close() }
            // Opening the external-link window activates the app, even though
            // the browser window and the video's tab are still behind it.
            browser.appBack(in: previewWindow)
            XCTAssertTrue(floating(), "opening the preview keeps the video floating")
            browser.appBack(in: nil)
            XCTAssertTrue(floating(), "activation before a window has the keys keeps PiP")
            browser.appLeft()
            browser.appBack(in: previewWindow)
            XCTAssertTrue(floating(), "repeated app switches from the preview keep PiP")
            browser.appBack(in: owner)
            XCTAssertFalse(floating(), "returning to the video's own window brings it back")
        }
    }

    func testPictureInPictureEndedByMacOSComesBackOnLeaving() async throws {
        try await withPlayer(style: .system) { browser, owner, floating in
            browser.toggleFloat()
            try await waitFor(floating)
            // macOS's own button puts the video back in its page, and Search
            // hears nothing of it.
            let tab = try XCTUnwrap(browser.active)
            _ = try await inPage(tab, "document.querySelector('video').webkitPresentationMode = 'inline'; true;")
            browser.appLeft()
            for _ in 0..<100 {
                if try await presentation(tab) == "picture-in-picture" { break }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            let mode = try await presentation(tab)
            XCTAssertEqual(mode, "picture-in-picture", "leaving the app floats the video again")
            // Out because of the app switch this time, not by hand.
            browser.appBack(in: owner)
            XCTAssertFalse(floating(), "the video the app switch floated comes back with its window")
        }
    }

    func testPictureInPictureByHandStaysOutAcrossAppSwitch() async throws {
        try await withPlayer(style: .system) { browser, owner, floating in
            browser.toggleFloat()
            try await waitFor(floating)
            let tab = try XCTUnwrap(browser.active)
            browser.appLeft()
            // The page is asked again, and answers that it is out already.
            _ = try await presentation(tab)
            browser.appBack(in: owner)
            XCTAssertTrue(floating(), "a video floated by hand stays out when its window comes forward")
        }
    }

    func testVideoFloatedByHandAfterPreviewStaysOut() async throws {
        try await withPlayer(style: .search) { browser, owner, floating in
            browser.appLeft()
            try await waitFor(floating)
            let (little, previewWindow) = try preview(for: browser)
            defer { little.close() }
            browser.appBack(in: previewWindow)
            XCTAssertTrue(floating())

            // ⌘⇧P from the small window: home by hand, then out by hand.
            browser.toggleFloat()
            XCTAssertFalse(floating())
            browser.toggleFloat()
            try await waitFor(floating)
            XCTAssertTrue(floating())
            browser.appBack(in: owner)
            XCTAssertTrue(floating(), "a video floated by hand stays out when its window comes forward")
        }
    }

    /// A browser whose window shows a page with a playing video, floated
    /// as `style` floats one, for `body`; `floating` says whether it is out.
    private func withPlayer(
        style: FloatStyle,
        _ body: (Browser, NSWindow, @escaping () -> Bool) async throws -> Void
    ) async throws {
        let browser = Browser(record: WindowRecord())
        // Leaving the app floats only the front browser's video, and a test
        // run before this one may have left its own browser in front.
        let front = Front.shared.browser
        Front.shared.set(browser)
        let previous = (browser.prefs.floatStyle, browser.prefs.floatsAway)
        let away = Float.benchAway
        let hosts = Players.benchHosts
        Players.benchHosts.insert("little-window.invalid")
        Float.benchAway = NSPoint(x: -30000, y: -30000)
        defer {
            Float.benchAway = away
            Players.benchHosts = hosts
            browser.prefs.floatStyle = previous.0
            browser.prefs.floatsAway = previous.1
            Front.shared.set(front)
        }
        browser.prefs.floatStyle = style
        browser.prefs.floatsAway = true
        let owner = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 900, height: 640),
                             styleMask: [.titled], backing: .buffered, defer: false)
        owner.isReleasedWhenClosed = false
        browser.window = owner
        defer { owner.close() }
        let tab = browser.benchOpen(try XCTUnwrap(URL(string: "about:blank")))
        defer {
            // Home first, while the tab and its window are still there to
            // take the page back.
            browser.land(covering: false)
            browser.unpicture()
            tab.close()
        }
        browser.activeID = tab.id
        owner.contentView = tab.web
        tab.web.loadHTMLString("<video style='width:320px;height:180px'></video><script>window.fixtureReady = true;</script>",
                               baseURL: URL(string: "https://little-window.invalid/"))
        for _ in 0..<100 {
            if (try? await tab.web.evaluateJavaScript("window.fixtureReady")) as? Bool == true { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(tab.address?.host(), "little-window.invalid")
        // Exercise the browser's PiP lifecycle without opening macOS's own
        // video window. The page reports a player whose presentation mode
        // changes exactly as WebKit's does.
        let ready = try await inPage(tab, """
            var video = document.querySelector('video');
            Object.defineProperties(video, {
                paused: {value: false}, ended: {value: false}, readyState: {value: 4},
                webkitPresentationMode: {value: 'inline', writable: true},
                webkitSupportsPresentationMode: {value: function() { return true; }},
                webkitSetPresentationMode: {value: function(mode) { this.webkitPresentationMode = mode; }}
            }); true;
            """)
        XCTAssertEqual(ready as? Bool, true)
        let id = tab.id
        try await body(browser, owner) {
            style == .system ? browser.pictured == id : browser.floating == id && browser.floater.showing
        }
    }

    private func inPage(_ tab: Tab, _ script: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Any?, Error>) in
            tab.web.evaluateJavaScript(script, in: nil, in: Web.world) { result in
                done.resume(with: result.map { $0 as Any? })
            }
        }
    }

    private func presentation(_ tab: Tab) async throws -> String? {
        try await inPage(tab, "document.querySelector('video').webkitPresentationMode") as? String
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
