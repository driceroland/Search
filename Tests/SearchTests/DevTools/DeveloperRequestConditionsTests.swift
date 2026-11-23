import Foundation
import XCTest
@testable import Search

/// Network's Request conditions (block or throttle by pattern), the Privacy
/// panel's third-party cookie report, and Developer resources' "Load
/// through website": the pure logic behind each.
@MainActor
final class DeveloperRequestConditionsTests: XCTestCase {
    private typealias Tools = DeveloperNetworkTools

    // MARK: Request conditions

    func testARowBlocksUnlessItNamesAThrottlingProfile() {
        let custom = Tools.ThrottlingProfile(name: "Slow API", download: 0, upload: 0, latency: 750)
        let flat = Tools.ThrottlingProfile(name: "Bandwidth only", download: 100, upload: 100, latency: 0)
        let profiles = [custom, flat]
        XCTAssertEqual(Tools.condition(of: .init(pattern: "*/ads/*"), profiles: profiles), .block)
        XCTAssertEqual(Tools.condition(of: .init(pattern: "*", throttling: "Offline"), profiles: profiles), .block)
        XCTAssertEqual(Tools.condition(of: .init(pattern: "*", throttling: "Slow 4G"), profiles: profiles),
                       .delay(DeveloperToolsSession.NetworkCondition.slow4G.latency))
        XCTAssertEqual(Tools.condition(of: .init(pattern: "*", throttling: custom.id.uuidString), profiles: profiles),
                       .delay(750))
        // A profile with no latency can't delay one request; a removed one does nothing.
        XCTAssertEqual(Tools.condition(of: .init(pattern: "*", throttling: flat.id.uuidString), profiles: profiles), .ignored)
        XCTAssertEqual(Tools.condition(of: .init(pattern: "*", throttling: UUID().uuidString), profiles: profiles), .ignored)

        XCTAssertEqual(Tools.conditionName(of: .init(pattern: "*"), profiles: profiles), "Block")
        XCTAssertEqual(Tools.conditionName(of: .init(pattern: "*", throttling: "3G"), profiles: profiles), "3G")
        XCTAssertEqual(Tools.conditionName(of: .init(pattern: "*", throttling: custom.id.uuidString), profiles: profiles),
                       "Slow API")
    }

    func testOptionsSplitEnabledRowsIntoBlockedAndDelayedPatterns() throws {
        let rows: [Tools.BlockPattern] = [
            .init(pattern: "*://ads.example.test"),
            .init(pattern: "*/api/*", throttling: "Fast 4G"),
            .init(pattern: "*/off/*", enabled: false),
            .init(pattern: "*/gone/*", throttling: UUID().uuidString),
        ]
        let options = Tools.blockingOptions(enabled: true, patterns: rows, profiles: [])
        XCTAssertEqual(options["enabled"] as? Bool, true)
        XCTAssertEqual(options["patterns"] as? [String], ["*://ads.example.test"])
        let throttled = try XCTUnwrap(options["throttled"] as? [[String: Any]])
        XCTAssertEqual(throttled.count, 1)
        XCTAssertEqual(throttled.first?["pattern"] as? String, "*/api/*")
        XCTAssertEqual(throttled.first?["latency"] as? Double, DeveloperToolsSession.NetworkCondition.fast4G.latency)
    }

    func testRowsSavedBeforeThrottlingStillDecodeAsBlocking() throws {
        let id = UUID()
        let saved = #"[{"id":"\#(id.uuidString)","pattern":"*/x.js","enabled":true}]"#
        let rows = try JSONDecoder().decode([Tools.BlockPattern].self, from: Data(saved.utf8))
        XCTAssertEqual(rows.first?.id, id)
        XCTAssertNil(rows.first?.throttling)
        let round = try JSONDecoder().decode([Tools.BlockPattern].self,
                                             from: JSONEncoder().encode([Tools.BlockPattern(pattern: "*", throttling: "3G")]))
        XCTAssertEqual(round.first?.throttling, "3G")
    }

    // MARK: Third-party cookies

    func testThirdPartyCookiesAreGroupedBySiteBlockedFirst() throws {
        typealias Report = DeveloperThirdPartyCookies
        let requests: [Report.Request] = [
            .init(id: "1", url: "https://www.news.example/", sent: ["session"], set: ["prefs"]),
            .init(id: "2", url: "https://cdn.news.example/app.js", sent: ["session"], set: []),
            .init(id: "3", url: "https://pixel.tracker.test/p.gif", sent: [], set: ["uid", "seen"]),
            .init(id: "4", url: "https://sync.tracker.test/s", sent: [], set: ["uid"]),
            .init(id: "5", url: "https://login.idp.test/frame", sent: ["sso"], set: []),
            .init(id: "6", url: "https://fonts.cdn.test/a.woff2", sent: [], set: []),
            .init(id: "7", url: "data:text/plain,hi", sent: ["x"], set: []),
        ]
        let sites = Report.report(requests, page: URL(string: "https://www.news.example/story"))
        XCTAssertEqual(sites.map(\.site), ["tracker.test", "idp.test"])
        let tracker = try XCTUnwrap(sites.first)
        XCTAssertEqual(tracker.status, .blocked)
        XCTAssertEqual(tracker.cookies, ["uid", "seen"])
        XCTAssertEqual(tracker.set, 3)
        XCTAssertEqual(tracker.sent, 0)
        XCTAssertEqual(tracker.requests, ["3", "4"])
        XCTAssertEqual(tracker.networkFilter, "domain:*tracker.test")
        let idp = try XCTUnwrap(sites.last)
        XCTAssertEqual(idp.status, .exempted)
        XCTAssertEqual(idp.status.rawValue, "Allowed by exception")
        XCTAssertEqual(idp.networkFilter, "domain:login.idp.test")
        XCTAssertEqual(Report.summary(sites), "2 sites: 1 blocked, 1 allowed by exception")
        XCTAssertTrue(Report.report(requests, page: nil).isEmpty)
    }

    // MARK: Load through website

    func testLoadThroughWebsiteSendsOnlyTheCookiesForTheAddress() throws {
        func cookie(_ name: String, domain: String, path: String = "/", secure: Bool = false) throws -> HTTPCookie {
            var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: name + "-value", .domain: domain, .path: path]
            if secure { properties[.secure] = "TRUE" }
            return try XCTUnwrap(HTTPCookie(properties: properties))
        }
        let cookies = try [
            cookie("site", domain: ".example.test"),
            cookie("maps", domain: "cdn.example.test", path: "/maps"),
            cookie("other", domain: "other.test"),
            cookie("admin", domain: "cdn.example.test", path: "/admin"),
        ]
        let url = try XCTUnwrap(URL(string: "https://cdn.example.test/maps/app.js.map"))
        let headers = DeveloperResourceLoading.headers(for: url, cookies: cookies, throughWebsite: true)
        let cookieHeader = try XCTUnwrap(headers["Cookie"])
        XCTAssertTrue(cookieHeader.contains("site=site-value"))
        XCTAssertTrue(cookieHeader.contains("maps=maps-value"))
        XCTAssertFalse(cookieHeader.contains("other"))
        XCTAssertFalse(cookieHeader.contains("admin"))
        XCTAssertTrue(DeveloperResourceLoading.headers(for: url, cookies: cookies, throughWebsite: false).isEmpty)
        let insecure = try XCTUnwrap(URL(string: "http://cdn.example.test/maps/a.map"))
        XCTAssertEqual(DeveloperResourceLoading.headers(for: insecure, cookies: [try cookie("s", domain: "cdn.example.test", secure: true)],
                                                        throughWebsite: true), [:])
    }
}
