import XCTest
@testable import Search

/// Dim 3rd parties: which Main track entries are greyed.
final class DeveloperPerformanceThirdPartiesTests: XCTestCase {
    private typealias Timing = DeveloperToolsSession.Timing

    /// The page at www.example.com; ids in start order:
    /// 0 its own script (cdn.example.com is the same site), 1 a layout in it,
    /// 2 an analytics script, 3 a frame without a URL inside it,
    /// 4 a timer with no script at all, 5 a co.uk widget.
    private var profile: DeveloperPerformanceProfile {
        DeveloperPerformanceProfile([
            Timing(type: "PageInfo", start: 1, end: 1, data: ["url": "https://www.example.com/page"]),
            Timing(type: "EvaluateScript", start: 0, end: 0.010, data: ["url": "https://cdn.example.com/app.js"]),
            Timing(type: "Layout", start: 0.002, end: 0.004, depth: 1),
            Timing(type: "FunctionCall", start: 0.020, end: 0.040, data: ["scriptName": "https://www.google-analytics.com/a.js"]),
            Timing(type: "JavaScriptFrame", start: 0.022, end: 0.030, depth: 1, data: ["name": "track"]),
            Timing(type: "TimerFire", start: 0.050, end: 0.060),
            Timing(type: "EvaluateScript", start: 0.070, end: 0.080, data: ["url": "https://widgets.shop.co.uk/w.js"]),
        ])
    }

    func testThePagesSiteGroupsItsSubdomains() {
        XCTAssertEqual(DeveloperPerformanceThirdParties.firstPartySite(profile), "example.com")
        XCTAssertEqual(DeveloperPerformanceThirdParties.isThirdParty("https://static.example.com/x.js", firstParty: "example.com"), false)
        XCTAssertEqual(DeveloperPerformanceThirdParties.isThirdParty("https://evil.com/x.js", firstParty: "example.com"), true)
        XCTAssertNil(DeveloperPerformanceThirdParties.isThirdParty("inline", firstParty: "example.com"))
    }

    func testThirdPartyScriptsAndWhatRunsInsideThemAreDimmed() {
        let profile = profile
        XCTAssertEqual(profile.events.map(\.type),
                       ["EvaluateScript", "Layout", "FunctionCall", "JavaScriptFrame", "TimerFire", "EvaluateScript"])
        XCTAssertEqual(DeveloperPerformanceThirdParties.dimmed(profile), [2, 3, 5])
    }

    func testNothingIsDimmedWithoutThePagesAddress() {
        let profile = DeveloperPerformanceProfile([
            Timing(type: "FunctionCall", start: 0, end: 0.010, data: ["scriptName": "https://other.com/a.js"]),
        ])
        XCTAssertEqual(DeveloperPerformanceThirdParties.dimmed(profile), [])
        XCTAssertEqual(DeveloperPerformanceThirdParties.dimmed(profile, page: URL(string: "https://example.com/")), [0])
    }
}
