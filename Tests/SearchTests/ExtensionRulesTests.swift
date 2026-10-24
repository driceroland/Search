import Foundation
import XCTest
@testable import Search

/// Request rules put the way WebKit reads them (ExtensionShims.mendRules).
@available(macOS 15.4, *)
final class ExtensionRulesTests: XCTestCase {
    private func condition(_ rule: [String: Any]) -> [String: Any] { rule["condition"] as? [String: Any] ?? [:] }

    func testPagePatternForSitesMovesThemToInitiators() throws {
        let strict: [String: Any] = [
            "id": 1, "priority": 29,
            "action": ["type": "redirect", "redirect": ["regexSubstitution": "chrome-extension://x/strictblock.html#\\0"]],
            "condition": ["regexFilter": "^https?://.*", "resourceTypes": ["main_frame"],
                          "requestDomains": ["badware.example"], "excludedRequestDomains": ["dropbox.com"]],
        ]
        let out = try XCTUnwrap(ExtensionShims.mendRules([strict]))
        XCTAssertEqual(out.count, 1)
        let c = condition(out[0])
        XCTAssertNil(c["requestDomains"])
        XCTAssertEqual(c["initiatorDomains"] as? [String], ["badware.example"])
        // WebKit drops unless-frame-url beside if-frame-url, so the
        // exceptions stay request domains, which it does honour.
        XCTAssertEqual(c["excludedRequestDomains"] as? [String], ["dropbox.com"])
    }

    func testRedirectThatWouldReachEverySiteIsLeftOut() throws {
        let rules: [[String: Any]] = [
            ["id": 1, "action": ["type": "redirect", "redirect": ["extensionPath": "/noop.js"]],
             "condition": ["regexFilter": "/ads/.*\\.js", "resourceTypes": ["script"], "requestDomains": ["a.example"]]],
            ["id": 2, "action": ["type": "block"],
             "condition": ["regexFilter": "/ads/.*\\.js", "resourceTypes": ["script"], "requestDomains": ["a.example"]]],
        ]
        let out = try XCTUnwrap(ExtensionShims.mendRules(rules))
        XCTAssertEqual(out.compactMap { $0["id"] as? Int }, [2])
    }

    func testClosingSeparatorGetsATwinOnceWithAFreshID() throws {
        let rules: [[String: Any]] = [
            ["id": 7, "priority": 16, "action": ["type": "redirect", "redirect": ["extensionPath": "/web_accessible_resources/amazon_apstag.js"]],
             "condition": ["urlFilter": "||amazon-adsystem.com/*apstag.js^"]],
            ["id": 9, "action": ["type": "block"], "condition": ["urlFilter": "||example.com^"]],
        ]
        let out = try XCTUnwrap(ExtensionShims.mendRules(rules))
        XCTAssertEqual(out.count, 3)
        XCTAssertEqual(out[1]["id"] as? Int, 10)
        XCTAssertEqual(condition(out[1])["urlFilter"] as? String, "||amazon-adsystem.com/*apstag.js|")
        XCTAssertEqual(out[1]["priority"] as? Int, 16)
        // Prepared again by a newer Search: nothing more to add.
        XCTAssertNil(ExtensionShims.mendRules(out))
    }

    func testSeparatorEndsOnlyAfterAPath() {
        XCTAssertTrue(ExtensionShims.endsAtSeparator("||amazon-adsystem.com/*apstag.js^"))
        XCTAssertTrue(ExtensionShims.endsAtSeparator("https://example.com/ad^"))
        XCTAssertFalse(ExtensionShims.endsAtSeparator("||example.com^"))
        XCTAssertFalse(ExtensionShims.endsAtSeparator("||example.com/ad|"))
    }
}
