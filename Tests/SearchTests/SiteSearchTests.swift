import XCTest
@testable import Search

@MainActor
final class SiteSearchTests: XCTestCase {
    func testKeywordSiteShortcutCanBeOfferedByItsKeyword() throws {
        let keyword = Keyword(keyword: "grk", template: "https://grok.com/?q=%s")

        let site = try XCTUnwrap(SiteSearch.match("gr", learnedToo: false, keywords: [keyword]))

        XCTAssertEqual(site.name, "Grok")
        XCTAssertEqual(site.host, "grok.com")
        XCTAssertEqual(site.template, keyword.template)
        XCTAssertEqual(site.aliases, ["grk"])
    }
}
