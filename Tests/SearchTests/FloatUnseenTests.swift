import AppKit
import WebKit
import XCTest
@testable import Search

/// A muted video whose window goes out of sight — another desktop comes
/// forward — is paused by WebKit, as every silent video nobody can see is.
/// Leaving the app still floats it, as it floats one with sound, and WebKit
/// plays it again once it can be seen there. One paused by hand stays put.
@MainActor
final class FloatUnseenTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "float-unseen-\(getpid())", 1)
        super.setUp()
    }

    override func setUp() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
    }

    func testMutedVideoStoppedOutOfSightFloats() async throws {
        try await withPlayer(style: .search) { browser, owner, tab, floating in
            owner.orderOut(nil)
            try await waitForStop(tab)
            let stopped = try await paused(tab)
            XCTAssertEqual(stopped, true, "WebKit pauses a muted video nobody can see")

            browser.appLeft()
            try await waitFor { floating() }
            XCTAssertTrue(floating(), "leaving the app floats the video WebKit paused")
            try await waitFor { try await self.paused(tab) == false }
            let playing = try await paused(tab) == false
            XCTAssertTrue(playing, "and WebKit plays it again in the little window")
        }
    }

    func testMutedVideoStoppedOutOfSightGoesIntoPictureInPicture() async throws {
        try await withPlayer(style: .system) { browser, owner, tab, floating in
            owner.orderOut(nil)
            try await waitForStop(tab)
            browser.appLeft()
            try await waitFor { floating() }
            XCTAssertTrue(floating(), "leaving the app sends the video WebKit paused into picture in picture")
        }
    }

    func testVideoPausedByHandStaysInItsTab() async throws {
        try await withPlayer(style: .search) { browser, owner, tab, floating in
            _ = try await inPage(tab, "document.querySelector('video').pause(); true;")
            owner.orderOut(nil)
            try await waitFor { try await self.visibility(tab) == "hidden" }
            browser.appLeft()
            try await waitFor { floating() }
            XCTAssertFalse(floating(), "a video paused by hand doesn't float")
        }
    }

    func testVideoPausedByHandOutOfSightStaysOnceSeen() async throws {
        try await withPlayer(style: .search, audible: true) { browser, owner, tab, floating in
            owner.orderOut(nil)
            try await waitFor { try await self.visibility(tab) == "hidden" }
            let playing = try await paused(tab) == false
            XCTAssertTrue(playing, "WebKit leaves a video with sound playing out of sight")
            // Paused while out of sight, as the media keys do, then seen
            // again, and left again.
            _ = try await inPage(tab, "document.querySelector('video').pause(); true;")
            owner.orderFrontRegardless()
            try await waitFor { try await self.visibility(tab) == "visible" }
            owner.orderOut(nil)
            try await waitFor { try await self.visibility(tab) == "hidden" }
            browser.appLeft()
            try await waitFor { floating() }
            XCTAssertFalse(floating(), "a video paused by hand out of sight doesn't float once it has been seen")
        }
    }

    /// A browser whose window shows a page with a video playing, a canvas's
    /// stream, floated as `style` floats one, for `body`; `floating` says
    /// whether it is out. Muted unless `audible`, when the stream carries a
    /// sound track too (a silent one). The window is off every screen and
    /// WebKit is told not to mind (as the bench's stand is), so the page can
    /// be seen while the window is ordered in and not once it is ordered out.
    private func withPlayer(
        style: FloatStyle,
        audible: Bool = false,
        _ body: (Browser, NSWindow, Tab, @escaping () -> Bool) async throws -> Void
    ) async throws {
        let browser = Browser(record: WindowRecord())
        // Leaving the app floats only the front browser's video, and a test
        // run before this one may have left its own browser in front.
        let front = Front.shared.browser
        Front.shared.set(browser)
        let previous = (browser.prefs.floatStyle, browser.prefs.floatsAway)
        let away = Float.benchAway
        let hosts = Players.benchHosts
        Players.benchHosts.insert("float-unseen.invalid")
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
        let owner = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 640, height: 360),
                             styleMask: [.borderless], backing: .buffered, defer: false)
        owner.isReleasedWhenClosed = false
        browser.window = owner
        defer { owner.close() }
        let tab = browser.benchOpen(try XCTUnwrap(URL(string: "about:blank")))
        defer {
            browser.land(covering: false)
            browser.unpicture()
            tab.close()
        }
        browser.activeID = tab.id
        let occlusion = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        if tab.web.responds(to: occlusion) {
            typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
            unsafeBitCast(tab.web.method(for: occlusion), to: Setter.self)(tab.web, occlusion, false)
        }
        owner.contentView = tab.web
        owner.orderFrontRegardless()
        tab.web.loadHTMLString("""
            <canvas width=64 height=36></canvas>
            <video muted playsinline style='width:320px;height:180px'></video>
            <script>
              var canvas = document.querySelector('canvas'), paint = canvas.getContext('2d'), n = 0;
              setInterval(function () {
                paint.fillStyle = 'hsl(' + (n++ * 7 % 360) + ', 80%, 50%)';
                paint.fillRect(0, 0, 64, 36);
              }, 33);
              var video = document.querySelector('video');
              video.srcObject = canvas.captureStream(30);
              video.play();
            </script>
            """, baseURL: URL(string: "https://float-unseen.invalid/"))
        try await waitFor { try await self.paused(tab) == false }
        // The sound track from here, a script Search runs counting as the
        // click a page needs for sound.
        if audible {
            _ = try await inPage(tab, """
                var sound = new AudioContext(), tone = sound.createOscillator(), none = sound.createGain();
                var out = sound.createMediaStreamDestination(), video = document.querySelector('video');
                none.gain.value = 0;
                tone.connect(none).connect(out);
                tone.start();
                video.srcObject.addTrack(out.stream.getAudioTracks()[0]);
                video.muted = false;
                true;
                """)
            // Until WebKit says the page is making sound, it takes the video
            // for a silent one, and pauses it out of sight.
            for _ in 0..<250 where !tab.noisy { try await Task.sleep(nanoseconds: 20_000_000) }
            XCTAssertTrue(tab.noisy, "the video plays with sound")
        }
        let playing = try await paused(tab) == false
        XCTAssertTrue(playing, "the video plays while its window can be seen")
        XCTAssertEqual(tab.address?.host(), "float-unseen.invalid")
        // macOS's own picture in picture window stays shut: the video's
        // presentation changes as WebKit's would, and nothing more.
        if style == .system {
            _ = try await inPage(tab, """
                Object.defineProperties(document.querySelector('video'), {
                    webkitPresentationMode: {value: 'inline', writable: true},
                    webkitSupportsPresentationMode: {value: function () { return true; }},
                    webkitSetPresentationMode: {value: function (mode) { this.webkitPresentationMode = mode; }}
                }); true;
                """)
        }
        let id = tab.id
        try await body(browser, owner, tab) {
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

    private func paused(_ tab: Tab) async throws -> Bool? {
        try await inPage(tab, "document.querySelector('video').paused") as? Bool
    }

    private func visibility(_ tab: Tab) async throws -> String? {
        try await inPage(tab, "document.visibilityState") as? String
    }

    /// Paused by WebKit, and with a picture again: a canvas's stream has
    /// none for a moment as its page goes out of sight, and a video with
    /// nothing to show isn't floated. A film's stays.
    private func waitForStop(_ tab: Tab) async throws {
        try await waitFor {
            try await self.inPage(tab, "var v = document.querySelector('video'); v.paused && v.readyState >= 2") as? Bool == true
        }
    }

    /// Asked again on an error too: a page still loading drops what it was asked.
    private func waitFor(_ condition: () async throws -> Bool) async throws {
        for _ in 0..<100 {
            if (try? await condition()) == true { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
