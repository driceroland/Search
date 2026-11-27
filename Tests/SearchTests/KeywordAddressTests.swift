import XCTest
@testable import Search

/// A site shortcut's address typed without https:// is taken as https (#1654).
@available(macOS 14, *)
final class KeywordAddressTests: XCTestCase {
    func testAnAddressWithoutItsSchemeIsTakenAsHTTPS() {
        let typed = "www.youtube.com/results?search_query=%s"
        XCTAssertEqual(Keyword.address(typed), "https://www.youtube.com/results?search_query=%s")
        XCTAssertNil(Keyword.problem(word: "yt", template: typed, among: []))
    }

    func testAnAddressWithASchemeIsLeftAsItIs() {
        XCTAssertEqual(Keyword.address(" http://example.com/?q=%s "), "http://example.com/?q=%s")
        XCTAssertEqual(Keyword.address(""), "")
    }

    func testStillRefusedWithoutTheWordsMark() {
        XCTAssertNotNil(Keyword.problem(word: "yt", template: "www.youtube.com/results?search_query=", among: []))
        XCTAssertNotNil(Keyword.problem(word: "yt", template: "%s.example.com", among: []))
        XCTAssertNotNil(Keyword.problem(word: "yt", template: "javascript:alert(%s)", among: []))
    }
}
