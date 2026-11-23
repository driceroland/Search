import XCTest
@testable import Search

/// The filter keys Chrome has for overrides, mixed content and cookies,
/// their suggestions, and the Has overrides column.
@MainActor
final class DeveloperNetworkFilterKeysTests: XCTestCase {
    private typealias Request = DeveloperToolsSession.Request
    private typealias Extra = DeveloperNetworkTools.Extra
    private typealias Cookie = DeveloperNetworkTools.Cookie

    private func request(_ id: String, _ url: String, type: String = "Script", document: String? = nil) -> Request {
        var request = Request(id: id, url: url, method: "GET", type: type, loader: nil, started: 1)
        request.documentURL = document
        return request
    }

    private func matches(_ query: String, _ request: Request, _ extra: Extra) -> Bool {
        DeveloperNetworkFilter(query).matches(request, extra: extra)
    }

    private var contentOverride: Extra {
        var extra = Extra()
        extra.source = "inspector-override"
        return extra
    }

    private var headersOverride: Extra {
        var extra = Extra()
        extra.source = "inspector-override"
        extra.overridden = true
        return extra
    }

    private var bothOverrides: Extra {
        var extra = headersOverride
        extra.contentFileOverridden = true
        return extra
    }

    func testTheNewKeysParseAsKeys() {
        for key in ["has-overrides", "mixed-content", "cookie-domain", "cookie-name", "cookie-path", "cookie-value",
                    "set-cookie-value"] {
            let clauses = DeveloperNetworkFilter.parse(key + ":x")
            XCTAssertEqual(clauses.first?.key, key, key)
            XCTAssertEqual(clauses.first?.text, "x", key)
        }
    }

    func testHasOverridesReadsWhatLocalOverridesReplaced() {
        let row = request("1", "https://example.test/app.js")
        let plain = Extra()
        XCTAssertTrue(matches("has-overrides:yes", row, contentOverride))
        XCTAssertTrue(matches("has-overrides:yes", row, headersOverride))
        XCTAssertFalse(matches("has-overrides:yes", row, plain))
        XCTAssertTrue(matches("has-overrides:no", row, plain))
        XCTAssertFalse(matches("has-overrides:no", row, headersOverride))
        XCTAssertTrue(matches("has-overrides:content", row, contentOverride))
        XCTAssertFalse(matches("has-overrides:content", row, headersOverride), "a headers override isn't content")
        XCTAssertTrue(matches("has-overrides:content", row, bothOverrides))
        XCTAssertTrue(matches("has-overrides:headers", row, headersOverride))
        XCTAssertFalse(matches("has-overrides:headers", row, contentOverride))
        XCTAssertTrue(matches("has-overrides:headers", row, bothOverrides))
        XCTAssertTrue(matches("-has-overrides:yes", row, plain), "negated")
        XCTAssertTrue(matches("has-overrides:YES", row, contentOverride), "values match without case")
    }

    func testMixedContentIsInsecureOnASecurePage() {
        let image = request("1", "http://cdn.test/a.png", type: "Image", document: "https://example.test/")
        let script = request("2", "http://cdn.test/a.js", type: "Script", document: "https://example.test/")
        let socket = request("3", "ws://cdn.test/live", type: "WebSocket", document: "https://example.test/")
        let secure = request("4", "https://cdn.test/a.png", type: "Image", document: "https://example.test/")
        let insecurePage = request("5", "http://cdn.test/a.png", type: "Image", document: "http://example.test/")
        let none = Extra()
        XCTAssertTrue(matches("mixed-content:all", image, none))
        XCTAssertTrue(matches("mixed-content:all", script, none))
        XCTAssertTrue(matches("mixed-content:all", socket, none))
        XCTAssertFalse(matches("mixed-content:all", secure, none))
        XCTAssertFalse(matches("mixed-content:all", insecurePage, none), "an http page has no mixed content")
        XCTAssertTrue(matches("mixed-content:displayed", image, none), "an image is shown, not blocked")
        XCTAssertFalse(matches("mixed-content:displayed", script, none))
        XCTAssertFalse(matches("mixed-content:displayed", secure, none))
    }

    func testCookieKeysMatchTheRequestsCookies() {
        let row = request("1", "https://www.example.test/app/data")
        var extra = Extra()
        extra.cookies = ["session"]
        extra.requestCookies = [Cookie(name: "session", value: "abc", domain: ".example.test", path: "/app")]
        extra.responseCookies = [Cookie(name: "theme", value: "dark", domain: "example.test", path: "/")]
        XCTAssertTrue(matches("cookie-name:session", row, extra))
        XCTAssertFalse(matches("cookie-name:theme", row, extra))
        XCTAssertTrue(matches("cookie-domain:.example.test", row, extra))
        XCTAssertFalse(matches("cookie-domain:example.test", row, extra), "the domain as the jar keeps it")
        XCTAssertTrue(matches("cookie-path:/app", row, extra))
        XCTAssertFalse(matches("cookie-path:/", row, extra))
        XCTAssertTrue(matches("cookie-value:abc", row, extra))
        XCTAssertFalse(matches("cookie-value:ab", row, extra), "values match whole")
        XCTAssertTrue(matches("set-cookie-value:dark", row, extra))
        XCTAssertFalse(matches("set-cookie-value:abc", row, extra), "a request cookie isn't set by the response")
        XCTAssertFalse(matches("cookie-value:dark", row, extra))
    }

    func testRequestCookiesTakeTheirDomainAndPathFromTheJar() {
        let cookies = [Cookie(name: "session", value: "abc"), Cookie(name: "other", value: "1")]
        let jar: [(name: String, domain: String, path: String)] = [
            (name: "session", domain: ".example.test", path: "/"),
            (name: "session", domain: "www.example.test", path: "/app"),
            (name: "session", domain: "elsewhere.test", path: "/"),
            (name: "other", domain: "example.test", path: "/admin"),
        ]
        let resolved = Cookie.resolve(cookies, url: "https://www.example.test/app/page", jar: jar)
        XCTAssertEqual(resolved[0].domain, "www.example.test", "the most specific path wins")
        XCTAssertEqual(resolved[0].path, "/app")
        XCTAssertEqual(resolved[0].value, "abc")
        XCTAssertEqual(resolved[1].domain, "", "a cookie whose path doesn't cover the address isn't matched")
        let root = Cookie.resolve(cookies, url: "https://example.test/", jar: jar)
        XCTAssertEqual(root[0].domain, ".example.test")
        XCTAssertEqual(root[0].path, "/")
    }

    func testTheNewKeysAreSuggestedWithTheValuesSeen() {
        let rows = [request("1", "https://example.test/")]
        var extra = Extra()
        extra.requestCookies = [Cookie(name: "session", value: "abc", domain: ".example.test", path: "/")]
        extra.responseCookies = [Cookie(name: "theme", value: "dark")]
        let extras = ["1": extra]
        func suggest(_ query: String) -> [String] {
            DeveloperNetworkFilter.suggestions(for: query, requests: rows, extras: extras)
        }
        XCTAssertEqual(suggest("has"), ["has-overrides:", "has-request-header:", "has-response-header:"])
        XCTAssertEqual(suggest("has-overrides:"),
                       ["has-overrides:yes", "has-overrides:no", "has-overrides:content", "has-overrides:headers"])
        XCTAssertEqual(suggest("mixed-content:"), ["mixed-content:all", "mixed-content:displayed"])
        XCTAssertEqual(suggest("cookie-"), ["cookie-domain:", "cookie-name:", "cookie-path:", "cookie-value:"])
        XCTAssertEqual(suggest("cookie-domain:"), ["cookie-domain:.example.test"])
        XCTAssertEqual(suggest("cookie-name:"), ["cookie-name:session"])
        XCTAssertEqual(suggest("cookie-path:"), ["cookie-path:/"])
        XCTAssertEqual(suggest("cookie-value:"), ["cookie-value:abc"])
        XCTAssertEqual(suggest("set-cookie-value:"), ["set-cookie-value:dark"])
    }

    func testHasOverridesColumnSaysWhatWasReplaced() {
        let row = request("1", "https://example.test/app.js")
        let column = DeveloperNetworkColumn.hasOverrides
        XCTAssertEqual(column.rawValue, "Has overrides")
        XCTAssertEqual(DeveloperNetworkColumn.value(column, row, contentOverride), "content")
        XCTAssertEqual(DeveloperNetworkColumn.value(column, row, headersOverride), "headers")
        XCTAssertEqual(DeveloperNetworkColumn.value(column, row, bothOverrides), "content, headers")
        XCTAssertEqual(DeveloperNetworkColumn.value(column, row, Extra()), "")
        XCTAssertEqual(DeveloperNetworkColumn.value(column, row, nil), "")
        XCTAssertFalse(DeveloperNetworkColumn.defaults.contains(column), "off until chosen, as in Chrome")
    }
}
