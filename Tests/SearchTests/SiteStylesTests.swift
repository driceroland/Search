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
}
