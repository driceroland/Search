import XCTest
@testable import Search

/// The address an element's context menu offers to open, copy and reveal.
final class DeveloperElementLinkTests: XCTestCase {
    private let base = URL(string: "https://example.com/docs/page.html")

    func testHrefThenSrcResolvedAgainstThePage() {
        XCTAssertEqual(DeveloperElementLink.url(attributes: ["class", "x", "href", "../app.css"], base: base)?.absoluteString,
                       "https://example.com/app.css")
        XCTAssertEqual(DeveloperElementLink.url(attributes: ["src", "/js/app.js"], base: base)?.absoluteString,
                       "https://example.com/js/app.js")
        XCTAssertEqual(DeveloperElementLink.url(attributes: ["SRC", "https://cdn.test/a.png", "href", "b"], base: base)?.absoluteString,
                       "https://example.com/docs/b")
    }

    func testNoLinkForFragmentsScriptsOrNothing() {
        XCTAssertNil(DeveloperElementLink.url(attributes: ["href", "#top"], base: base))
        XCTAssertNil(DeveloperElementLink.url(attributes: ["href", "javascript:void(0)"], base: base))
        XCTAssertNil(DeveloperElementLink.url(attributes: ["href", "  "], base: base))
        XCTAssertNil(DeveloperElementLink.url(attributes: ["id", "a"], base: base))
        XCTAssertNil(DeveloperElementLink.url(attributes: ["href"], base: base))
    }
}
