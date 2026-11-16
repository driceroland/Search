import XCTest
@testable import Search

/// What of a site's own CSS is kept: a sheet or a web address would be
/// fetched, and Search doesn't fetch on a page's behalf.
@MainActor
final class SiteStylesTests: XCTestCase {
    func testKeepsOrdinaryCSS() {
        let cleaned = SiteStyles.clean("a { color: red }\n.x { margin: 0 }")
        XCTAssertEqual(cleaned.css, "a { color: red }\n.x { margin: 0 }")
        XCTAssertFalse(cleaned.fetched)
        XCTAssertFalse(cleaned.shortened)
    }

    func testDropsImports() {
        let cleaned = SiteStyles.clean("@import \"https://evil.example/a.css\";\na { color: red }")
        XCTAssertFalse(cleaned.css.contains("@import"))
        XCTAssertFalse(cleaned.css.contains("evil"))
        XCTAssertTrue(cleaned.css.contains("color: red"))
        XCTAssertTrue(cleaned.fetched)
    }

    func testDropsRemoteURLsAndKeepsLocalOnes() {
        let cleaned = SiteStyles.clean("""
        .a { background: url(https://evil.example/a.png) }
        .b { background: url("//evil.example/b.png") }
        .c { background: url(javascript:alert(1)) }
        .d { background: url(photo.png) }
        .e { background: url("data:image/gif;base64,abc") }
        .f { mask: url(#glyph) }
        """)
        XCTAssertFalse(cleaned.css.contains("evil"))
        XCTAssertFalse(cleaned.css.contains("javascript"))
        XCTAssertTrue(cleaned.css.contains("url(photo.png)"))
        XCTAssertTrue(cleaned.css.contains("data:image"))
        XCTAssertTrue(cleaned.css.contains("url(#glyph)"))
        XCTAssertTrue(cleaned.fetched)
    }

    func testAQuoteCanHoldAParen() {
        let cleaned = SiteStyles.clean(".a { background: url(\"not)a.png\") }")
        XCTAssertEqual(cleaned.css, ".a { background: url(\"not)a.png\") }")
        XCTAssertFalse(cleaned.fetched)
    }

    func testShortensALibrary() {
        let cleaned = SiteStyles.clean(String(repeating: "a", count: SiteStyles.limit + 20))
        XCTAssertEqual(cleaned.css.count, SiteStyles.limit)
        XCTAssertTrue(cleaned.shortened)
    }

    func testArrangesARule() {
        XCTAssertEqual(
            SiteStyles.arranged("body { background: #fff; color: #111; }"),
            "body {\n  background: #fff;\n  color: #111;\n}"
        )
        let nested = "@media (max-width: 600px) { body { color: red; } }"
        XCTAssertEqual(SiteStyles.arranged(SiteStyles.arranged(nested)), SiteStyles.arranged(nested))
        let quoted = SiteStyles.arranged(".a { background: url(\"not)a.png\"); color: red }")
        XCTAssertTrue(quoted.contains("url(\"not)a.png\")"))
        XCTAssertEqual(SiteStyles.arranged(quoted), quoted)
        let escaped = SiteStyles.arranged("a { content: \"a\\\"b;c\"; }")
        XCTAssertEqual(escaped, "a {\n  content: \"a\\\"b;c\";\n}")
        XCTAssertEqual(SiteStyles.arranged(escaped), escaped)
    }

    func testALineSeparatorDoesNotBreakTheSheet() {
        let js = Veiling.style("a { color: red\u{2028} }")
        XCTAssertFalse(js.contains("\u{2028}"))
        XCTAssertTrue(js.contains("\\u2028"))
    }

    func testAColorCodeWearsItsColorAndASelectorDoesNot() {
        let marks = CodeTint.marks("#header { color: #fc0; background: rgb(0, 128, 255); }", script: false)
        let colors = marks.compactMap { mark -> (UInt8, UInt8, UInt8, UInt8)? in
            if case .color(let r, let g, let b, let a) = mark.kind { return (r, g, b, a) }
            return nil
        }
        XCTAssertEqual(colors, [(255, 204, 0, 255), (0, 128, 255, 255)] as [(UInt8, UInt8, UInt8, UInt8)])
        let red = CodeTint.marks("a { color: hsl(0, 100%, 50%) }", script: false).compactMap { mark -> (UInt8, UInt8, UInt8, UInt8)? in
            if case .color(let r, let g, let b, let a) = mark.kind { return (r, g, b, a) }
            return nil
        }
        XCTAssertEqual(red, [(255, 0, 0, 255)] as [(UInt8, UInt8, UInt8, UInt8)])
        let size = CodeTint.marks("a { font-size: 16px }", script: false).first { $0.kind == .number }
        XCTAssertEqual(size?.length, 4)
        XCTAssertFalse(CodeTint.marks("/* #fff */", script: false).contains { if case .color = $0.kind { return true }; return false })
    }

    func testAKeywordIsColoredOnlyInJavaScript() {
        XCTAssertTrue(CodeTint.marks("let a = 1\nlet b = 2", script: true).contains { $0.kind == .keyword })
        XCTAssertFalse(CodeTint.marks("let a = 1", script: false).contains { $0.kind == .keyword })
        XCTAssertEqual(CodeTint.pair(in: "{ a }", caret: 1, script: false), (0, 4))
        XCTAssertNil(CodeTint.pair(in: "\"{}\"", caret: 2, script: true))
    }

    func testKeepsAScriptAsTyped() {
        XCTAssertEqual(SiteStyles.keptScript("let a = 1\nlet b = 2"), "let a = 1\nlet b = 2")
        XCTAssertEqual(SiteStyles.keptScript("return /a/"), "return /a/")
        XCTAssertEqual(SiteStyles.keptScript("  \n let a = 1 \n"), "let a = 1")
    }

    func testComposedKeepsAColorAndDropsAWebAddress() {
        var look = SiteLook()
        look.text = "#112233"
        look.css = "a { background: url(https://evil.example/a.png) }"
        let sheet = SiteStyles.composed(look)
        XCTAssertTrue(sheet.contains("color: #112233"))
        XCTAssertFalse(sheet.contains("evil"))
        look.on = false
        XCTAssertTrue(SiteStyles.composed(look).isEmpty)
    }
}
