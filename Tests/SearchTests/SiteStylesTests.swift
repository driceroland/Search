import AppKit
import JavaScriptCore
import XCTest
@testable import Search

@MainActor
final class SiteStylesTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "site-styles-\(getpid())", 1)
        super.setUp()
    }

    func testASiteIsItsHostWithoutWww() {
        XCTAssertEqual(SiteStyles.host(of: URL(string: "https://www.Example.com/a?b")), "example.com")
        XCTAssertEqual(SiteStyles.host(of: URL(string: "http://news.example.com/")), "news.example.com")
        XCTAssertEqual(SiteStyles.host(of: URL(string: "https://www2.example.com/")), "www2.example.com")
        XCTAssertNil(SiteStyles.host(of: URL(string: "about:blank")), "not a website")
        XCTAssertNil(SiteStyles.host(of: URL(string: "file:///Users/someone/page.html")))
        XCTAssertNil(SiteStyles.host(of: nil))
    }

    func testStylesAreKeptAndReadBack() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("site-styles-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("styles.json")

        let styles = SiteStyles(file: file)
        styles.on = true
        let css = "body { background: `pink` !important; }\n/* \"quoted\" ${x} */"
        styles.set(css, on: "example.com")
        styles.set("a { color: red }", on: "other.example")
        styles.set("   \n", on: "other.example")
        XCTAssertEqual(styles.hosts, ["example.com"], "nothing but whitespace is no style")
        styles.writeNow()

        let again = SiteStyles(file: file)
        XCTAssertEqual(again.written(on: "example.com"), css)
        XCTAssertEqual(again.hosts, ["example.com"])
        XCTAssertNil(again.css(on: "example.com"), "off until the setting says so")
        again.on = true
        XCTAssertEqual(again.css(on: "example.com"), css)
        XCTAssertNil(again.css(on: "elsewhere.example"))
        XCTAssertNil(again.css(on: nil))

        again.remove(on: "example.com")
        XCTAssertTrue(again.hosts.isEmpty)
    }

    func testTurningTheSettingOffKeepsTheStyles() {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        let prefs = browser.prefs
        let saved = prefs.sitesStyles
        let host = "styles-gate.example"
        defer {
            SiteStyles.shared.remove(on: host)
            prefs.sitesStyles = saved
            browser.closeAll()
        }
        var told: [String?] = []
        let watch = SiteStyles.shared.changed.sink { told.append($0) }
        defer { watch.cancel() }

        prefs.sitesStyles = true
        XCTAssertTrue(SiteStyles.shared.on)
        SiteStyles.shared.set("p { color: red }", on: host)
        XCTAssertEqual(SiteStyles.shared.css(on: host), "p { color: red }")

        prefs.sitesStyles = false
        XCTAssertFalse(SiteStyles.shared.on)
        XCTAssertNil(SiteStyles.shared.css(on: host), "off, no page wears it")
        XCTAssertEqual(SiteStyles.shared.written(on: host), "p { color: red }", "but it is kept")
        XCTAssertEqual(told, [nil, host, nil], "the switch tells every page, a style only its site's")
    }

    func testTheEditorAndItsCommandOnlyWithTheSettingOn() throws {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        let prefs = browser.prefs
        let saved = (prefs.sitesStyles, prefs.commandBar)
        defer {
            browser.styling = nil
            (prefs.sitesStyles, prefs.commandBar) = saved
            browser.closeAll()
        }
        prefs.commandBar = true
        let tab = try XCTUnwrap(browser.tabs.last)
        tab.restore(url: try XCTUnwrap(URL(string: "https://www.example.com/page")), title: "Example")
        browser.select(tab)
        XCTAssertEqual(browser.active?.isWeb, true)

        prefs.sitesStyles = false
        browser.editSiteStyle()
        XCTAssertNil(browser.styling)
        XCTAssertFalse(AddressCommand.listed("site style", in: browser).contains(.menu("view.style")), "setting off")

        prefs.sitesStyles = true
        XCTAssertTrue(AddressCommand.listed("site style", in: browser).contains(.menu("view.style")))
        XCTAssertTrue(AddressCommand.listed("boost", in: browser).contains(.menu("view.style")))
        browser.editSiteStyle()
        XCTAssertEqual(browser.styling, "example.com")
        browser.editSiteStyle()
        XCTAssertNil(browser.styling, "the same command puts it away")

        browser.editSiteStyle()
        prefs.sitesStyles = false
        XCTAssertNil(browser.styling, "turning it off closes the editor")
    }

    // MARK: - the string the CSS travels in

    /// Strings that would end a quoted, backticked or templated string, or
    /// an inline script, if they were pasted in as they are.
    private let hostile = [
        "body { color: red }",
        "a::after { content: \"`\"; } ` ; window.broken = 1; `",
        "a::after { content: '\\'' } '); window.broken = 1; ('",
        "a::after { content: \"\\\"\" } \"); window.broken = 1; (\"",
        "${window.broken = 1} p { color: blue }",
        "</style><script>window.broken = 1</script>",
        "</script><script>window.broken = 1</script>",
        "a { content: \"\\\\\" } \\u0022 \\` \\${x}",
        "line\u{2028}separator\u{2029}paragraph\r\nend\0",
        "",
    ]

    /// A document with nothing in it but what the script touches.
    private func page() throws -> JSContext {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("""
        var root = { kids: [], appendChild: function (el) {
          this.kids = this.kids.filter(function (k) { return k !== el; }); this.kids.push(el); } };
        var document = {
          readyState: 'complete', documentElement: root,
          getElementById: function (id) { return root.kids.filter(function (k) { return k.id === id; })[0] || null; },
          createElement: function (tag) { return { tag: tag, id: '', textContent: '' }; },
          addEventListener: function () {}
        };
        var window = this;
        """)
        return context
    }

    func testTheCSSCannotBreakOutOfTheScript() throws {
        for css in hostile {
            let context = try page()
            var trouble: String?
            context.exceptionHandler = { _, error in trouble = error?.toString() }
            context.evaluateScript(SiteStyles.script(css))
            XCTAssertNil(trouble, css)
            XCTAssertTrue(context.evaluateScript("typeof window.broken")?.toString() == "undefined", css)
            let sheet = context.evaluateScript("document.getElementById('office-style')")
            if css.isEmpty {
                XCTAssertTrue(sheet?.isNull ?? false, "no style, no element")
            } else {
                XCTAssertEqual(sheet?.forProperty("textContent")?.toString(), css, css)
                XCTAssertEqual(sheet?.forProperty("tag")?.toString(), "style")
            }
            let literal = SiteStyles.literal(css)
            XCTAssertFalse(literal.contains("</"), "never a closing tag, even in a string: \(literal)")
            XCTAssertFalse(literal.contains("\u{2028}") || literal.contains("\u{2029}"))
        }
    }

    func testTheLiveStyleReplacesAndEmptiesTheSheet() throws {
        let context = try page()
        context.evaluateScript(SiteStyles.script("p { color: red }"))
        // As Tab.callInSearch runs it: the body of a function of `css`.
        let live = try XCTUnwrap(context.evaluateScript("(function (css) { \(SiteStyles.live) })"))
        live.call(withArguments: ["p { color: blue }"])
        XCTAssertEqual(context.evaluateScript("root.kids.length")?.toInt32(), 1, "one sheet, written over")
        XCTAssertEqual(context.evaluateScript("root.kids[0].textContent")?.toString(), "p { color: blue }")
        live.call(withArguments: [""])
        XCTAssertEqual(context.evaluateScript("root.kids[0].textContent")?.toString(), "", "cleared")
    }
}
