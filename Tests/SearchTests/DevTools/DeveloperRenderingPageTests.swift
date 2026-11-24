import AppKit
import JavaScriptCore
import WebKit
import XCTest
@testable import Search

/// Rendering's emulations done in the page: the media query rewrite, which
/// options go to the page rather than to WebKit, and the script as sent.
@MainActor
final class DeveloperRenderingPageTests: XCTestCase {
    private func rewrite(_ text: String, _ overrides: [String: String]) throws -> String {
        let context = try XCTUnwrap(JSContext())
        let function = context.evaluateScript("(" + DeveloperRenderingPage.mediaRewriter + "\n)")
        XCTAssertNil(context.exception, "\(context.exception?.toString() ?? "")")
        let result = function?.call(withArguments: [text, overrides])
        XCTAssertNil(context.exception, "\(context.exception?.toString() ?? "")")
        return try XCTUnwrap(result?.toString())
    }

    private let always = "(min-width: 0px)"
    private let never = "(not (min-width: 0px))"

    func testForcedColorsTestsBecomeConstants() throws {
        XCTAssertEqual(try rewrite("(forced-colors: active)", ["forced-colors": "active"]), always)
        XCTAssertEqual(try rewrite("(forced-colors: none)", ["forced-colors": "active"]), never)
        XCTAssertEqual(try rewrite("(forced-colors)", ["forced-colors": "active"]), always)
        XCTAssertEqual(try rewrite("(forced-colors)", ["forced-colors": "none"]), never)
        XCTAssertEqual(try rewrite("screen and ( Forced-Colors:ACTIVE )", ["forced-colors": "active"]),
                       "screen and " + always)
    }

    func testOtherFeaturesAndTextAreKept() throws {
        XCTAssertEqual(try rewrite("screen and (max-width: 600px), print", ["forced-colors": "active"]),
                       "screen and (max-width: 600px), print")
        XCTAssertEqual(try rewrite("(prefers-contrast: less) and (min-width: 40em)", ["prefers-contrast": "less"]),
                       always + " and (min-width: 40em)")
        XCTAssertEqual(try rewrite("not all and (prefers-reduced-data: reduce)", [:]),
                       "not all and (prefers-reduced-data: reduce)")
    }

    func testBooleanTestsMatchAnythingButNoPreference() throws {
        XCTAssertEqual(try rewrite("(prefers-contrast)", ["prefers-contrast": "custom"]), always)
        XCTAssertEqual(try rewrite("(prefers-contrast)", ["prefers-contrast": "no-preference"]), never)
        XCTAssertEqual(try rewrite("(prefers-contrast: more)", ["prefers-contrast": "less"]), never)
        XCTAssertEqual(try rewrite("(prefers-reduced-transparency)", ["prefers-reduced-transparency": "reduce"]), always)
        XCTAssertEqual(try rewrite("(prefers-reduced-data: reduce)", ["prefers-reduced-data": "reduce"]), always)
    }

    func testColorGamutIsARange() throws {
        let p3 = ["color-gamut": "p3"]
        XCTAssertEqual(try rewrite("(color-gamut: srgb)", p3), always)
        XCTAssertEqual(try rewrite("(color-gamut: p3)", p3), always)
        XCTAssertEqual(try rewrite("(color-gamut: rec2020)", p3), never)
        XCTAssertEqual(try rewrite("(color-gamut: rec2020)", ["color-gamut": "rec2020"]), always)
        XCTAssertEqual(try rewrite("(color-gamut: wide)", p3), never)
        XCTAssertEqual(try rewrite("(color-gamut)", ["color-gamut": "srgb"]), always)
    }

    func testOptionsSplitBetweenWebKitAndThePage() {
        var options = DeveloperRendering.Options()
        XCTAssertTrue(options.pageState(nativeContrast: true).isEmpty)

        options.frameStats = true
        options.focusedPage = true
        options.forcedColors = "active"
        options.colorGamut = "srgb"
        options.contrast = "more"
        let native = options.pageState(nativeContrast: true)
        XCTAssertTrue(native.frameStats)
        XCTAssertFalse(native.layoutShifts)
        XCTAssertTrue(native.focused)
        // WebKit emulates `more` itself where it can.
        XCTAssertEqual(native.media, ["forced-colors": "active", "color-gamut": "srgb"])
        XCTAssertEqual(options.pageState(nativeContrast: false).media["prefers-contrast"], "more")

        options.contrast = "less"
        XCTAssertEqual(options.pageState(nativeContrast: true).media["prefers-contrast"], "less")
    }

    func testStateIsSentAsSortedJSON() {
        let state = DeveloperRenderingPage.State(frameStats: true, layoutShifts: false, focused: false,
                                                 media: ["prefers-reduced-data": "reduce"])
        XCTAssertEqual(state.json,
                       #"{"ads":null,"autoDark":false,"focused":false,"frameStats":true,"highlightAds":false,"layoutShifts":false,"media":{"prefers-reduced-data":"reduce"},"noLocalFonts":false,"scrollIssues":false,"touch":false}"#)
        XCTAssertFalse(state.isEmpty)
        XCTAssertTrue(DeveloperRenderingPage.State().isEmpty)
    }

    /// The script, with the rewriter, estimator and state around it, compiles as sent.
    func testComposedScriptCompiles() {
        let source = DeveloperRenderingPage.source(DeveloperRenderingPage.State(frameStats: true))
        XCTAssertTrue(source.contains(DeveloperRenderingPage.mediaRewriter))
        XCTAssertTrue(source.contains(DeveloperLayoutShiftEstimator.source))
        let context = JSContext()!
        context.setObject(source, forKeyedSubscript: "source" as NSString)
        _ = context.evaluateScript("new Function(source)")
        XCTAssertNil(context.exception, "\(context.exception?.toString() ?? "")")
    }

    /// Disable local fonts on a real page: a face whose only source is
    /// `local()` falls back once the option is on, and comes back when off.
    func testDisableLocalFontsDropsLocalSources() async throws {
        _ = NSApplication.shared
        let server = try LocalPageServer([
            "/": .init(type: "text/html", body: """
                <!doctype html><title>Local fonts fixture</title>
                <style>
                @font-face { font-family: Probe; src: local("Courier New"), local("Courier"); }
                #probe { font: 40px Probe, serif; white-space: nowrap; }
                </style>
                <span id=probe>iiiiiiiiii</span>
                """),
        ])
        let page = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let window = NSWindow(contentRect: CGRect(x: -4_000, y: -4_000, width: 800, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = page
        window.orderFrontRegardless()
        defer { window.close() }
        page.load(URLRequest(url: server.url("/")))
        func width() async -> Double {
            let value = try? await page.callAsyncJavaScript(
                "await document.fonts.ready; return document.getElementById('probe').getBoundingClientRect().width;",
                contentWorld: .page)
            return (value as? NSNumber)?.doubleValue ?? -1
        }
        try await DeveloperTestSupport.wait("the page", seconds: 10, in: "DeveloperRenderingPageTests") {
            page.title == "Local fonts fixture"
        }
        try await Task.sleep(for: .milliseconds(300))
        let local = await width()
        XCTAssertGreaterThan(local, 0)

        let rendering = DeveloperRenderingPage()
        rendering.apply(.init(noLocalFonts: true), to: page)
        var fallback = local
        for _ in 0..<40 where abs(fallback - local) < 1 {
            try await Task.sleep(for: .milliseconds(100))
            fallback = await width()
        }
        XCTAssertGreaterThan(abs(fallback - local), 20, "monospace \(local), serif \(fallback)")
        let src = try await page.evaluateJavaScript("document.styleSheets[0].cssRules[0].style.getPropertyValue('src')") as? String
        XCTAssertFalse(src?.contains("local") ?? true, src ?? "")

        rendering.apply(.init(), to: page)
        var back = fallback
        for _ in 0..<40 where abs(back - local) >= 1 {
            try await Task.sleep(for: .milliseconds(100))
            back = await width()
        }
        XCTAssertEqual(back, local, accuracy: 1)
    }

    /// Scrolling performance issues on a real page, loaded after the
    /// option is on: blocking wheel and touch listeners, an onwheel handler
    /// and a fixed background are outlined; passive and removed listeners
    /// aren't; the window's own blocking handler covers the viewport.
    func testScrollingPerformanceIssuesFindBlockingHandlers() async throws {
        _ = NSApplication.shared
        let server = try LocalPageServer([
            "/": .init(type: "text/html", body: "<!doctype html><title>Before</title>"),
            "/fixture": .init(type: "text/html", body: """
                <!doctype html><title>Scroll issues fixture</title>
                <style>div { height: 40px; margin: 4px; }
                #fixed { background: linear-gradient(red, blue) fixed; }</style>
                <div id=wheel></div><div id=touch></div><div id=passive></div><div id=removed></div>
                <div id=prop></div><div id=fixed></div>
                <script>
                const f = () => {};
                wheel.addEventListener("wheel", f);
                touch.addEventListener("touchstart", f, {passive: false});
                passive.addEventListener("wheel", f, {passive: true});
                removed.addEventListener("touchmove", f, true);
                removed.removeEventListener("touchmove", f, true);
                prop.onwheel = f;
                document.addEventListener("touchstart", f);
                window.addEventListener("wheel", f, {passive: false});
                </script>
                """),
        ])
        let page = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let window = NSWindow(contentRect: CGRect(x: -4_000, y: -4_000, width: 800, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = page
        window.orderFrontRegardless()
        defer { window.close() }
        page.load(URLRequest(url: server.url("/")))
        try await DeveloperTestSupport.wait("the first page", seconds: 10, in: "DeveloperRenderingPageTests") {
            page.title == "Before"
        }
        let rendering = DeveloperRenderingPage()
        rendering.apply(.init(scrollIssues: true), to: page)
        page.load(URLRequest(url: server.url("/fixture")))
        try await DeveloperTestSupport.wait("the fixture", seconds: 10, in: "DeveloperRenderingPageTests") {
            page.title == "Scroll issues fixture"
        }
        let found = try await page.callAsyncJavaScript("""
            const api = window[Symbol.for("perch.devtools.rendering")];
            const issues = api.scrollIssues();
            const id = (issue) => {
                if (issue.page) return "page";
                const at = document.elementFromPoint(issue.rect.left + 2, issue.rect.top + 2);
                return at ? at.id : "?";
            };
            return issues.map((issue) => id(issue) + ": " + issue.label).sort().join("\\n");
            """, contentWorld: .page) as? String
        XCTAssertEqual(found, """
            fixed: Repaints on scroll
            page: Blocking wheel event handler
            prop: Blocking wheel event handler
            touch: Blocking touch event handler
            wheel: Blocking wheel event handler
            """)
        rendering.apply(.init(), to: page)
    }

    /// Highlight ads outlines frames from ad networks and Shield's ad slots,
    /// once each, and leaves a site's own frames and hidden slots alone.
    func testHighlightAdsMarksAdFramesAndSlots() async throws {
        _ = NSApplication.shared
        XCTAssertTrue(DeveloperRenderingPage.State(highlightAds: true).json.contains(#""domains":["doubleclick.net""#))
        let server = try LocalPageServer([
            "/": .init(type: "text/html", body: """
                <!doctype html><title>Ads fixture</title>
                <style>iframe, div { display: block; width: 300px; height: 50px; margin: 4px; border: 0; }</style>
                <iframe id=ad src="https://ad.doubleclick.net/x"></iframe>
                <iframe id=own src="about:blank"></iframe>
                <div id=slot class="ad-slot"><div class="adunit"></div></div>
                <div id=hidden class="ad-slot" style="display: none"></div>
                <div id=plain class="header"></div>
                """, headers: ["Content-Security-Policy: frame-src 'none'"]),
        ])
        let page = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let window = NSWindow(contentRect: CGRect(x: -4_000, y: -4_000, width: 800, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = page
        window.orderFrontRegardless()
        defer { window.close() }
        page.load(URLRequest(url: server.url("/")))
        try await DeveloperTestSupport.wait("the fixture", seconds: 10, in: "DeveloperRenderingPageTests") {
            page.title == "Ads fixture"
        }
        let rendering = DeveloperRenderingPage()
        rendering.apply(.init(highlightAds: true), to: page)
        let read = """
            const api = window[Symbol.for("perch.devtools.rendering")];
            const ids = api.adElements().map((ad) => {
                const at = document.elementFromPoint(ad.rect.left + 2, ad.rect.top + 2);
                return ad.tag + "#" + (at ? at.id : "?");
            });
            const layer = document.querySelector("perch-ad-highlights");
            return ids.sort().join(", ") + " | " + (layer ? "drawn" : "none");
            """
        var found = ""
        for _ in 0..<50 where !found.hasSuffix("drawn") {
            try await Task.sleep(nanoseconds: 100_000_000)
            found = try await page.callAsyncJavaScript(read, contentWorld: .page) as? String ?? ""
        }
        XCTAssertEqual(found, "div#slot, iframe#ad | drawn")
        rendering.apply(.init(), to: page)
        let off = try await page.callAsyncJavaScript(
            #"return document.querySelector("perch-ad-highlights") ? "drawn" : "none";"#,
            contentWorld: .page) as? String
        XCTAssertEqual(off, "none")
    }

    /// Device mode's touch emulation: the page sees a touch device (touch
    /// APIs, one touch point, coarse pointer, no hover, in matchMedia and the
    /// style sheets), and gets its own APIs back when it ends.
    func testTouchEmulationAnswersAsATouchDevice() async throws {
        _ = NSApplication.shared
        let server = try LocalPageServer([
            "/": .init(type: "text/html", body: """
                <!doctype html><title>Touch fixture</title>
                <style>#probe { width: 10px; } @media (hover: none) and (pointer: coarse) { #probe { width: 20px; } }</style>
                <div id=probe></div>
                """),
        ])
        let page = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let window = NSWindow(contentRect: CGRect(x: -4_000, y: -4_000, width: 400, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = page
        window.orderFrontRegardless()
        defer { window.close() }
        page.load(URLRequest(url: server.url("/")))
        try await DeveloperTestSupport.wait("the fixture", seconds: 10, in: "DeveloperRenderingPageTests") {
            page.title == "Touch fixture"
        }
        let read = """
            const seen = [];
            document.body.ontouchstart = (e) => seen.push(e.touches.length + "@" + e.touches[0].clientX);
            document.body.dispatchEvent(new TouchEvent("touchstart", {bubbles: true,
                touches: [new Touch({identifier: 1, target: document.body, clientX: 7})]}));
            return [typeof TouchEvent, "ontouchstart" in window, navigator.maxTouchPoints,
                matchMedia("(pointer: coarse)").matches, matchMedia("(any-hover: none)").matches,
                getComputedStyle(probe).width, seen.join()].join(" ");
            """
        let rendering = DeveloperRenderingPage()
        var state = DeveloperRenderingPage.State(touch: true)
        state.media = DeveloperRendering.touchMedia
        rendering.apply(state, to: page)
        let on = try await page.callAsyncJavaScript(read, contentWorld: .page) as? String
        XCTAssertEqual(on, "function true 1 true true 20px 1@7")
        rendering.apply(.init(), to: page)
        let off = try await page.callAsyncJavaScript("""
            return [typeof TouchEvent, "ontouchstart" in window, navigator.maxTouchPoints,
                matchMedia("(pointer: coarse)").matches, getComputedStyle(probe).width].join(" ");
            """, contentWorld: .page) as? String
        XCTAssertEqual(off, "undefined false 0 false 10px")
    }

    func testAutomaticDarkModeAsksWebKitForDark() {
        var options = DeveloperRendering.Options()
        options.autoDarkMode = true
        XCTAssertEqual(options.payload(nativeContrast: true)["colorScheme"] as? String, "Dark")
        XCTAssertTrue(options.pageState(nativeContrast: true).autoDark)
        options.autoDarkMode = false
        options.colorScheme = "Light"
        XCTAssertEqual(options.payload(nativeContrast: true)["colorScheme"] as? String, "Light")
    }

    /// Automatic dark mode on real pages: a light page is inverted, its
    /// image inverted back; a page that declares a dark theme, or is dark
    /// already, is left alone; off, the page is itself again.
    func testAutomaticDarkModeInvertsOnlyLightPages() async throws {
        _ = NSApplication.shared
        let server = try LocalPageServer([
            "/light": .init(type: "text/html", body: "<!doctype html><title>Light</title><p>light</p><img src=data:,>"),
            "/declared": .init(type: "text/html", body: """
                <!doctype html><title>Declared</title><meta name=color-scheme content="light dark"><p>x</p>
                """),
            "/dark": .init(type: "text/html", body: "<!doctype html><title>Dark</title><body style='background:#111;color:#eee'>x"),
        ])
        let page = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let window = NSWindow(contentRect: CGRect(x: -4_000, y: -4_000, width: 800, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = page
        window.orderFrontRegardless()
        defer { window.close() }
        func load(_ path: String, _ title: String) async throws {
            page.load(URLRequest(url: server.url(path)))
            try await DeveloperTestSupport.wait(title, seconds: 10, in: "DeveloperRenderingPageTests") { page.title == title }
        }
        func filters() async throws -> String {
            try await page.evaluateJavaScript("""
                getComputedStyle(document.documentElement).filter + " | " +
                (document.images[0] ? getComputedStyle(document.images[0]).filter : "-")
                """) as? String ?? ""
        }
        func waitFor(_ wanted: String) async throws -> String {
            var seen = ""
            for _ in 0..<30 {
                seen = try await filters()
                if seen == wanted { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            return seen
        }
        try await load("/light", "Light")
        let rendering = DeveloperRenderingPage()
        rendering.apply(.init(autoDark: true), to: page)
        let inverted = "invert(1) hue-rotate(180deg) | hue-rotate(180deg) invert(1)"
        let light = try await waitFor(inverted)
        XCTAssertEqual(light, inverted)

        try await load("/declared", "Declared")
        try await Task.sleep(for: .milliseconds(700))
        let declared = try await filters()
        XCTAssertEqual(declared, "none | -")

        try await load("/dark", "Dark")
        try await Task.sleep(for: .milliseconds(700))
        let dark = try await filters()
        XCTAssertEqual(dark, "none | -")

        try await load("/light", "Light")
        let again = try await waitFor(inverted)
        XCTAssertEqual(again, inverted)
        rendering.apply(.init(), to: page)
        let off = try await waitFor("none | none")
        XCTAssertEqual(off, "none | none")
    }
}
