import XCTest
@testable import Search

/// Cookies' "Only show cookies with an issue": which cookies it keeps.
@MainActor
final class DeveloperApplicationCookieIssuesTests: XCTestCase {
    func testSameSiteNoneWithoutSecureIsAnIssue() {
        XCTAssertNotNil(DeveloperCookieIssues.issue(sameSite: "None", secure: false, origin: "https://example.com"))
        XCTAssertNotNil(DeveloperCookieIssues.issue(sameSite: "none", secure: false, origin: nil))
        XCTAssertNil(DeveloperCookieIssues.issue(sameSite: "None", secure: true, origin: "https://example.com"))
        XCTAssertNil(DeveloperCookieIssues.issue(sameSite: "lax", secure: false, origin: "https://example.com"))
        XCTAssertNil(DeveloperCookieIssues.issue(sameSite: "", secure: false, origin: "http://example.com"))
    }

    func testSecureOnAnOriginThatIsNotHTTPSIsAnIssueButLocalhostIsNot() {
        XCTAssertNotNil(DeveloperCookieIssues.issue(sameSite: "strict", secure: true, origin: "http://example.com"))
        XCTAssertNil(DeveloperCookieIssues.issue(sameSite: "strict", secure: true, origin: "https://example.com"))
        XCTAssertNil(DeveloperCookieIssues.issue(sameSite: "", secure: true, origin: "http://localhost:8080"))
        XCTAssertNil(DeveloperCookieIssues.issue(sameSite: "", secure: true, origin: "http://127.0.0.1:8080"))
        XCTAssertNil(DeveloperCookieIssues.issue(sameSite: "", secure: true, origin: nil))
    }

    func testTableRowsAreReadBySecureAndSameSiteColumns() {
        XCTAssertEqual(DeveloperApplication.cookieColumns[7], "Secure")
        XCTAssertEqual(DeveloperApplication.cookieColumns[8], "SameSite")
        func row(secure: Bool, sameSite: String) -> [String] {
            ["id", "1", "example.com", "/", "Session", "3", "", secure ? "✓" : "", sameSite, "", "—"]
        }
        XCTAssertNotNil(DeveloperCookieIssues.issue(row: row(secure: false, sameSite: "none"), origin: "https://example.com"))
        XCTAssertNil(DeveloperCookieIssues.issue(row: row(secure: true, sameSite: "none"), origin: "https://example.com"))
        XCTAssertNotNil(DeveloperCookieIssues.issue(row: row(secure: true, sameSite: "lax"), origin: "http://example.com"))
        // The document.cookie fallback's Name and Value rows have neither column.
        XCTAssertNil(DeveloperCookieIssues.issue(row: ["id", "1"], origin: "http://example.com"))
    }
}
