import AppKit
import WebKit
import XCTest
@testable import Search

@MainActor
final class FloatPageTests: XCTestCase {
    private final class OtherDesktop: NSWindow {
        var onDesktop = false
        var hasKeys = false
        override var isOnActiveSpace: Bool { onDesktop }
        override var isKeyWindow: Bool { hasKeys }
    }

    override class func setUp() {
        setenv("SEARCH_PROBE", "float-pages-\(getpid())", 1)
        super.setUp()
    }

    func testDesktopFloatingRequiresPagesButAppFloatingKeepsItsOwnSetting() async throws {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        let tab = try XCTUnwrap(browser.active)
        let window = OtherDesktop(contentRect: NSRect(x: -20000, y: -20000, width: 980, height: 660),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.canHide = false
        browser.window = window
        window.contentView = tab.web
        window.orderBack(nil)
        Float.benchAway = NSPoint(x: -20000, y: -21000)
        let pages = browser.prefs.floatsPages, away = browser.prefs.floatsAway
        defer {
            browser.land()
            browser.prefs.floatsPages = pages
            browser.prefs.floatsAway = away
            Float.benchAway = nil
            window.orderOut(nil)
        }
        // A local document with a recognized video address; no network or devices.
        tab.web.loadHTMLString("""
        <video muted playsinline style="width:600px;height:338px"></video>
        <canvas width=600 height=338></canvas><script>
        const c=document.querySelector('canvas'),g=c.getContext('2d');
        setInterval(()=>{g.fillStyle='blue';g.fillRect(0,0,600,338)},40);
        document.querySelector('video').srcObject=c.captureStream(25);
        </script>
        """, baseURL: URL(string: "https://www.youtube.com/watch?v=local-fixture"))
        for _ in 0..<100 {
            if !tab.web.isLoading, tab.web.url != nil { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let ready = try await tab.web.callAsyncJavaScript("await document.querySelector('video').play(); return true;",
                                                        arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(ready as? Bool, true)
        browser.prefs.floatsAway = true
        browser.prefs.floatsPages = false
        browser.desktopChanged()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNil(browser.floating, "changing desktops must not borrow the app-switch setting")
        XCTAssertFalse(browser.floater.showing)
        browser.land()

        browser.prefs.floatsPages = true
        browser.desktopChanged()
        // During a desktop transition the app can activate before the source
        // window has focus. Neither a pending lift nor an open PiP should land.
        window.onDesktop = true
        browser.appBack()
        try await waitForFloat(browser)
        XCTAssertEqual(browser.floating, tab.id, "desktop floating remains available when opted in")
        browser.land()

        browser.prefs.floatsPages = false
        browser.appLeft()
        try await waitForFloat(browser)
        XCTAssertEqual(browser.floating, tab.id, "the existing app-switch video setting still works")
        browser.appBack()
        XCTAssertEqual(browser.floating, tab.id, "activation without source-window focus must keep PiP open")
        XCTAssertTrue(browser.floater.showing)

        window.hasKeys = true
        browser.appBack()
        XCTAssertNil(browser.floating, "returning to the source window still returns the video")
        XCTAssertFalse(browser.floater.showing)
    }

    private func waitForFloat(_ browser: Browser) async throws {
        for _ in 0..<100 {
            if browser.floating != nil { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("the playing video did not float")
    }
}
