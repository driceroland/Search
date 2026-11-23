import XCTest
@testable import Search

/// Styles' CSS documentation tooltip: the bundled descriptions and links.
final class DeveloperCSSDocsTests: XCTestCase {
    func testCommonPropertiesHaveADescription() {
        XCTAssertGreaterThanOrEqual(DeveloperCSSDocs.descriptions.count, 150)
        for name in ["display", "flex-wrap", "grid-template-columns", "color", "margin", "z-index"] {
            let text = DeveloperCSSDocs.description(for: name)
            XCTAssertNotNil(text, name)
            XCTAssertFalse(text?.isEmpty ?? true, name)
        }
        XCTAssertEqual(DeveloperCSSDocs.description(for: " Display "), DeveloperCSSDocs.description(for: "display"))
    }

    func testUnknownAndCustomPropertiesHaveNone() {
        XCTAssertNil(DeveloperCSSDocs.description(for: "--brand-color"))
        XCTAssertNil(DeveloperCSSDocs.description(for: "not-a-property"))
        XCTAssertNil(DeveloperCSSDocs.description(for: ""))
    }

    func testLearnMoreLeadsToTheMDNPage() {
        XCTAssertEqual(DeveloperCSSDocs.learnMore("flex-wrap")?.absoluteString,
                       "https://developer.mozilla.org/en-US/docs/Web/CSS/flex-wrap")
        XCTAssertNil(DeveloperCSSDocs.learnMore("a b"))
    }

    func testEveryDescriptionIsOneShortLine() {
        for (name, text) in DeveloperCSSDocs.descriptions {
            XCTAssertEqual(name, name.lowercased(), name)
            XCTAssertFalse(text.contains("\n"), name)
            XCTAssertLessThan(text.count, 140, name)
        }
    }
}
