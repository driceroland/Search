import XCTest
@testable import Search

@available(macOS 14, *)
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

    func testPathSearchKeepsAnEncodedSlash() throws {
        let url = try XCTUnwrap(URL(string: "https://open.spotify.com/search/AC%2FDC"))
        XCTAssertEqual(SiteSearch.words(in: url, searchedOn: spotify), "AC/DC")
    }

    func testPathSearchDecodesAnEncodedSpace() throws {
        let url = try XCTUnwrap(URL(string: "https://open.spotify.com/search/daft%20punk"))
        XCTAssertEqual(SiteSearch.words(in: url, searchedOn: spotify), "daft punk")
    }

    func testPathSearchRejectsASubpage() throws {
        let url = try XCTUnwrap(URL(string: "https://open.spotify.com/search/a/b"))
        XCTAssertNil(SiteSearch.words(in: url, searchedOn: spotify))
    }

    private let spotify = SearchSite(name: "Spotify", host: "open.spotify.com",
                                     template: "https://open.spotify.com/search/%s")
}
