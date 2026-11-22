import AppKit
import WebKit
import XCTest
@testable import Search

@available(macOS 15.4, *)
@MainActor
final class ExtensionPopupSizingTests: XCTestCase {
    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    func testScrollbarDoesNotBecomeThePopupsExplicitWidth() async throws {
        try await eitherScrollBars { try await self.scrollbarDoesNotBecomeThePopupsExplicitWidth() }
    }

    private func scrollbarDoesNotBecomeThePopupsExplicitWidth() async throws {
        let (web, window) = try await page("""
            html { overflow-y: scroll; } ::-webkit-scrollbar { width: 15px; }
            footer { width: 400px; padding: 10px; }
            """, "<footer>Translation options</footer>")
        defer { window.close() }
        let viewport = try await web.evaluateJavaScript("[innerWidth, document.documentElement.clientWidth]") as? [Double]
        XCTAssertEqual(viewport, [25, 10], "the fixture must reserve space for a scrollbar")
        for _ in 0..<3 {
            let size = try await measure(web)
            XCTAssertEqual(size[0], 435, "the footer, not the scrollbar-reduced viewport, determines the width")
        }
        let fits = try await web.evaluateJavaScript("document.documentElement.scrollWidth <= document.documentElement.clientWidth && document.documentElement.scrollHeight <= document.documentElement.clientHeight") as? Bool
        XCTAssertEqual(fits, true, "the scrollbar must not hide the footer")
        let reach = try await web.evaluateJavaScript("\(ExtensionPopup.reach)('width')") as? Double
        XCTAssertEqual(reach, 435)
        let style = try await web.evaluateJavaScript("document.documentElement.style.cssText") as? String
        XCTAssertEqual(style, "", "measurement must restore the page's own styling")
    }

    func testExplicitWidthCanShrinkAndGrowWithScrollbars() async throws {
        try await eitherScrollBars { try await self.explicitWidthCanShrinkAndGrowWithScrollbars() }
    }

    private func explicitWidthCanShrinkAndGrowWithScrollbars() async throws {
        for doctype in [true, false] {
            let (web, window) = try await page("""
                html { width: 360px; overflow-y: scroll; } ::-webkit-scrollbar { width: 15px; }
                """, "<p>Vault</p>", doctype: doctype)
            defer { window.close() }
            for width in [360, 280, 480, 280] {
                _ = try await web.evaluateJavaScript("document.documentElement.style.width = '\(width)px'")
                for _ in 0..<2 {
                    let size = try await measure(web)
                    XCTAssertEqual(size[0], Double(width + 15))
                }
            }
        }
    }

    func testFlexibleDelayedAndOversizedContent() async throws {
        try await eitherScrollBars { try await self.flexibleDelayedAndOversizedContent() }
    }

    private func flexibleDelayedAndOversizedContent() async throws {
        let (web, window) = try await page("#content { display:flex; }", "<div id=content><div style='width:240px;flex:none;height:80px'>Loading</div></div>")
        defer { window.close() }
        var size = try await measure(web)
        XCTAssertEqual(size, [240, 80])
        _ = try await web.evaluateJavaScript("document.querySelector('#content').innerHTML = '<div style=\"width:460px;flex:none;height:200px\">Ready</div>'")
        size = try await measure(web)
        XCTAssertEqual(size, [460, 200])
        _ = try await web.evaluateJavaScript("document.querySelector('#content').innerHTML = '<div style=\"width:1000px;flex:none;height:900px\">Large</div>'")
        size = try await measure(web)
        XCTAssertEqual(size, [800, 600])
    }

    /// A popup too tall for 600 points scrolls: a scroll bar shown always
    /// takes its room across, so nothing is cut off at the side.
    func testTallContentLeavesRoomForAScrollBar() async throws {
        try await eitherScrollBars {
            let (web, window) = try await self.page("", "<div style='width:300px;height:1500px'>Long list</div>")
            defer { window.close() }
            let size = try await self.measure(web)
            let gap = try await web.evaluateJavaScript("innerWidth - document.documentElement.clientWidth")
            let bar = try XCTUnwrap(gap as? Double)
            XCTAssertEqual(size, [300 + bar, 600])
            let fits = try await web.evaluateJavaScript("document.documentElement.scrollWidth <= document.documentElement.clientWidth") as? Bool
            XCTAssertEqual(fits, true, "the scroll bar must not push the list sideways")
        }
    }

    /// Each case with System Settings › Appearance › Show scroll bars as
    /// both kinds, whatever this Mac is set to: overlay scroll bars, and
    /// the classic ones "Always" gives, which took room while the popup
    /// was measured at its starting square (#1311).
    private func eitherScrollBars(_ run: () async throws -> Void) async throws {
        for style in [NSScroller.Style.overlay, .legacy] {
            ScrollerStyleOverride.force(style)
            defer { ScrollerStyleOverride.restore() }
            try await run()
        }
    }

    private func page(_ css: String, _ body: String, doctype: Bool = true) async throws -> (WKWebView, NSWindow) {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 25, height: 25), configuration: config)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 25, height: 25),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = web
        window.orderFrontRegardless()
        web.loadHTMLString("\(doctype ? "<!doctype html>" : "")<style>body { margin:0 } \(css)</style>\(body)<script>window.ready=true</script>", baseURL: nil)
        for _ in 0..<200 {
            if (try? await web.evaluateJavaScript("window.ready")) as? Bool == true { return (web, window) }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        window.close()
        throw NSError(domain: "Popup fixture did not load", code: 1)
    }

    private func measure(_ web: WKWebView) async throws -> [Double] {
        let value = try await web.evaluateJavaScript("(\(ExtensionPopup.preferred))()")
        let size = try XCTUnwrap(value as? [Double])
        XCTAssertEqual(size.count, 2)
        web.setFrameSize(NSSize(width: size[0], height: size[1]))
        try await Task.sleep(nanoseconds: 30_000_000)
        return size
    }
}

@MainActor
private enum ScrollerStyleOverride {
    private final class Forced: NSObject {
        nonisolated(unsafe) static var style: NSScroller.Style = .overlay
        @objc class func forcedPreferredScrollerStyle() -> NSScroller.Style { style }
    }
    private static var original: IMP?

    static func force(_ style: NSScroller.Style) {
        Forced.style = style
        let method = class_getClassMethod(NSScroller.self, #selector(getter: NSScroller.preferredScrollerStyle))!
        let forced = class_getClassMethod(Forced.self, #selector(Forced.forcedPreferredScrollerStyle))!
        let previous = method_setImplementation(method, method_getImplementation(forced))
        if original == nil { original = previous }
        NotificationCenter.default.post(name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
    }

    static func restore() {
        guard let original else { return }
        method_setImplementation(class_getClassMethod(NSScroller.self, #selector(getter: NSScroller.preferredScrollerStyle))!, original)
        Self.original = nil
        NotificationCenter.default.post(name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
    }
}
