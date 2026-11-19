import Foundation
import XCTest
@testable import Search

/// Which of a store's cookies an extension's credentialed fetch carries
/// (ExtensionFetch.sends), and what of a response it keeps.
@available(macOS 15.4, *)
final class ExtensionFetchTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func cookie(_ name: String = "s", domain: String, path: String = "/", secure: Bool = false,
                        expires: Date? = nil, extra: [HTTPCookiePropertyKey: Any] = [:]) -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: "1", .domain: domain, .path: path]
        if secure { properties[.secure] = "TRUE" }
        if let expires { properties[.expires] = expires }
        properties.merge(extra) { _, new in new }
        return HTTPCookie(properties: properties)!
    }

    private func sends(_ cookie: HTTPCookie, _ address: String) -> Bool {
        ExtensionFetch.sends(cookie, to: URL(string: address)!, at: now)
    }

    func testHostOnlyCookieGoesToItsHostAlone() {
        let c = cookie(domain: "claude.ai")
        XCTAssertTrue(sends(c, "https://claude.ai/api/bootstrap"))
        XCTAssertFalse(sends(c, "https://www.claude.ai/"), "a host-only cookie isn't a subdomain's")
        XCTAssertFalse(sends(c, "https://ai/"))
    }

    func testDomainCookieGoesToTheDomainAndItsSubdomains() {
        let c = cookie(domain: ".chatgpt.com")
        XCTAssertTrue(sends(c, "https://chatgpt.com/api/auth/session"))
        XCTAssertTrue(sends(c, "https://ab.chatgpt.com/"))
        XCTAssertTrue(sends(c, "https://a.b.chatgpt.com/"))
    }

    func testLookalikeDomainsGetNothing() {
        XCTAssertFalse(sends(cookie(domain: ".chatgpt.com"), "https://notchatgpt.com/"))
        XCTAssertFalse(sends(cookie(domain: ".chatgpt.com"), "https://chatgpt.com.evil.example/"))
        XCTAssertFalse(sends(cookie(domain: "claude.ai"), "https://evilclaude.ai/"))
        XCTAssertFalse(sends(cookie(domain: "claude.ai"), "https://claude.ai.evil.example/"))
    }

    func testHostCaseDoesNotMatter() {
        XCTAssertTrue(sends(cookie(domain: "Claude.AI"), "https://CLAUDE.ai/"))
    }

    func testPath() {
        let c = cookie(domain: "claude.ai", path: "/api")
        XCTAssertTrue(sends(c, "https://claude.ai/api"))
        XCTAssertTrue(sends(c, "https://claude.ai/api/bootstrap"))
        XCTAssertFalse(sends(c, "https://claude.ai/apiary"), "a path prefix ends at a slash")
        XCTAssertFalse(sends(c, "https://claude.ai/"))
        let slash = cookie(domain: "claude.ai", path: "/api/")
        XCTAssertTrue(sends(slash, "https://claude.ai/api/bootstrap"))
        XCTAssertFalse(sends(slash, "https://claude.ai/api"))
        XCTAssertTrue(sends(cookie(domain: "claude.ai"), "https://claude.ai"), "no path is the root")
    }

    func testSecureOnlyOverHTTPS() {
        let c = cookie(domain: "claude.ai", secure: true)
        XCTAssertTrue(sends(c, "https://claude.ai/"))
        XCTAssertFalse(sends(c, "http://claude.ai/"))
        XCTAssertTrue(sends(cookie(domain: "localhost"), "http://localhost:8080/api"))
    }

    func testExpiry() {
        XCTAssertFalse(sends(cookie(domain: "claude.ai", expires: now.addingTimeInterval(-1)), "https://claude.ai/"))
        XCTAssertFalse(sends(cookie(domain: "claude.ai", expires: now), "https://claude.ai/"))
        XCTAssertTrue(sends(cookie(domain: "claude.ai", expires: now.addingTimeInterval(60)), "https://claude.ai/"))
        XCTAssertTrue(sends(cookie(domain: "claude.ai"), "https://claude.ai/"), "a session cookie has no expiry")
    }

    func testPartitionedCookiesAreNeverSent() {
        let partitioned = cookie(domain: "claude.ai", secure: true, extra: [HTTPCookiePropertyKey("StoragePartition"): "other.example"])
        XCTAssertTrue(ExtensionFetch.partitioned(partitioned))
        XCTAssertFalse(sends(partitioned, "https://claude.ai/"))
        let empty = cookie(domain: "claude.ai", extra: [HTTPCookiePropertyKey("StoragePartition"): ""])
        XCTAssertFalse(ExtensionFetch.partitioned(empty), "an empty partition is none")
        XCTAssertTrue(sends(empty, "https://claude.ai/"))
    }

    func testResponsesSplitAtCookiesNotAtDates() {
        let url = URL(string: "https://claude.ai/api/bootstrap")!
        let joined = "a=1; Path=/; Expires=Wed, 21 Oct 2037 07:28:00 GMT; SameSite=Lax, b=2; Path=/api; Secure"
        let cookies = ExtensionFetch.setCookies(joined, for: url).map(\.cookie)
        XCTAssertEqual(cookies.map(\.name), ["a", "b"])
        XCTAssertEqual(cookies.first?.sameSitePolicy, .sameSiteLax, "the SameSite the site gave is kept")
        XCTAssertEqual(cookies.last?.path, "/api")
    }

    func testPartitionedSetCookieIsNotKept() {
        let url = URL(string: "https://claude.ai/")!
        let cookies = ExtensionFetch.setCookies("p=1; Path=/; Secure; SameSite=None; Partitioned, q=2; Path=/; Secure", for: url).map(\.cookie)
        XCTAssertEqual(cookies.map(\.name), ["q"], "Foundation would keep a Partitioned cookie unpartitioned")
        XCTAssertTrue(ExtensionFetch.setCookies("p=1; partitioned", for: url).isEmpty)
    }

    func testRawPathKeepsTrailingSlashAndPercentEncoding() {
        XCTAssertEqual(ExtensionFetch.rawPath(URL(string: "https://claude.ai/api/")!), "/api/")
        XCTAssertEqual(ExtensionFetch.rawPath(URL(string: "https://claude.ai/a%2Fb")!), "/a%2Fb")
        XCTAssertEqual(ExtensionFetch.rawPath(URL(string: "https://claude.ai")!), "/")
        let slash = cookie(domain: "claude.ai", path: "/api/")
        XCTAssertTrue(sends(slash, "https://claude.ai/api/"), "the trailing slash is the path's")
        let encoded = cookie(domain: "claude.ai", path: "/a%2Fb")
        XCTAssertTrue(sends(encoded, "https://claude.ai/a%2Fb/c"))
        XCTAssertFalse(sends(encoded, "https://claude.ai/a/b/c"), "an encoded slash isn't a slash")
    }

    // MARK: - what a response may set (accepts)

    private let suffixes: Set<String> = ["com", "ai", "co.uk", "uk", "github.io", "io"]
    private func accepts(_ line: String, from address: String, stored: [HTTPCookie] = [], list: Bool = true) -> Bool {
        let url = URL(string: address)!
        let sets = ExtensionFetch.setCookies(line, for: url)
        guard let set = sets.first else { return false }
        return ExtensionFetch.accepts(set, from: url, stored: stored, isSuffix: list ? { self.suffixes.contains($0) } : nil)
    }

    func testAResponseSetsOnlyItsOwnDomain() {
        XCTAssertTrue(accepts("s=1; Path=/", from: "https://claude.ai/api"), "host-only, its own host")
        XCTAssertTrue(accepts("s=1; Path=/; Domain=claude.ai", from: "https://claude.ai/"))
        XCTAssertTrue(accepts("s=1; Path=/; Domain=.claude.ai", from: "https://www.claude.ai/"), "a domain the host is under")
        XCTAssertFalse(accepts("s=1; Path=/; Domain=google.com", from: "https://evil.example/"), "never another site's")
        XCTAssertFalse(accepts("s=1; Path=/; Domain=www.claude.ai", from: "https://claude.ai/"), "never a name under the host")
        XCTAssertFalse(accepts("s=1; Path=/; Domain=evilclaude.ai", from: "https://claude.ai/"))
    }

    func testNeverAPublicSuffix() {
        XCTAssertFalse(accepts("s=1; Path=/; Domain=com", from: "https://evil.com/"))
        XCTAssertFalse(accepts("s=1; Path=/; Domain=.com", from: "https://evil.com/"))
        XCTAssertFalse(accepts("s=1; Path=/; Domain=co.uk", from: "https://evil.co.uk/"))
        XCTAssertFalse(accepts("s=1; Path=/; Domain=github.io", from: "https://evil.github.io/"))
        XCTAssertTrue(accepts("s=1; Path=/; Domain=evil.github.io", from: "https://a.evil.github.io/"))
        XCTAssertFalse(accepts("s=1; Path=/; Domain=claude.ai", from: "https://www.claude.ai/", list: false),
                       "with no list to tell, a named domain is taken only when it is the host")
        XCTAssertTrue(accepts("s=1; Path=/; Domain=claude.ai", from: "https://claude.ai/", list: false))
    }

    func testTheMacsOwnListKnowsTheSuffixes() throws {
        let test = try XCTUnwrap(Passkeys.publicSuffix, "CFNetwork's public suffix test")
        for suffix in ["com", "co.uk", "github.io"] { XCTAssertTrue(test(suffix as CFString), suffix) }
        XCTAssertFalse(test("claude.ai" as CFString))
    }

    func testAnAddressTakesHostOnlyCookies() {
        XCTAssertTrue(accepts("s=1; Path=/", from: "http://127.0.0.1:8080/"))
        XCTAssertFalse(accepts("s=1; Path=/; Domain=127.0.0.1", from: "http://127.0.0.1/"))
        XCTAssertFalse(accepts("s=1; Path=/; Domain=0.0.1", from: "http://127.0.0.1/"), "never an address's suffix")
        XCTAssertFalse(accepts("s=1; Path=/; Domain=1", from: "http://10.0.0.1/"))
    }

    func testSecureOnlyFromHTTPS() {
        XCTAssertTrue(accepts("s=1; Path=/; Secure", from: "https://claude.ai/"))
        XCTAssertFalse(accepts("s=1; Path=/; Secure", from: "http://claude.ai/"))
    }

    func testPrefixes() {
        XCTAssertTrue(accepts("__Host-s=1; Path=/; Secure", from: "https://claude.ai/"))
        XCTAssertFalse(accepts("__Host-s=1; Path=/", from: "https://claude.ai/"), "__Host- needs Secure")
        XCTAssertFalse(accepts("__Host-s=1; Path=/; Secure; Domain=claude.ai", from: "https://claude.ai/"), "__Host- names no Domain")
        XCTAssertFalse(accepts("__Host-s=1; Path=/api; Secure", from: "https://claude.ai/api"), "__Host- is Path=/")
        XCTAssertTrue(accepts("__Secure-s=1; Path=/; Secure", from: "https://claude.ai/"))
        XCTAssertFalse(accepts("__Secure-s=1; Path=/", from: "https://claude.ai/"), "__Secure- needs Secure")
        XCTAssertFalse(accepts("__Secure-s=1; Path=/; Secure", from: "http://claude.ai/"), "and https")
    }

    func testPlainHTTPLeavesSecureCookiesAlone() {
        let stored = cookie("s", domain: "claude.ai", secure: true)
        XCTAssertFalse(accepts("s=2; Path=/", from: "http://claude.ai/", stored: [stored]), "not replaced over http")
        XCTAssertFalse(accepts("s=; Path=/; Max-Age=0", from: "http://claude.ai/", stored: [stored]), "nor removed")
        XCTAssertFalse(accepts("s=2; Path=/; Domain=.claude.ai", from: "http://www.claude.ai/", stored: [stored]), "from under it either")
        XCTAssertTrue(accepts("s=2; Path=/", from: "https://claude.ai/", stored: [stored]), "https may")
        XCTAssertTrue(accepts("t=2; Path=/", from: "http://claude.ai/", stored: [stored]), "another name may")
        XCTAssertTrue(accepts("s=2; Path=/", from: "http://other.example/", stored: [stored]), "another site's may")
    }

    func testRemovalsFollowTheSameRules() {
        XCTAssertFalse(accepts("s=; Path=/; Domain=google.com; Max-Age=0", from: "https://evil.example/"), "no removing another site's")
        XCTAssertFalse(accepts("s=; Path=/; Domain=com; Max-Age=0", from: "https://evil.com/"))
        XCTAssertTrue(accepts("s=; Path=/; Max-Age=0", from: "https://claude.ai/"))
    }

    // MARK: - the request

    func testMethods() {
        for method in ["GET", "POST", "PUT", "DELETE", "PATCH", "OPTIONS", "HEAD", "PROPFIND"] {
            XCTAssertTrue(ExtensionFetch.allowed(method: method), method)
        }
        for method in ["CONNECT", "TRACE", "TRACK", "connect", "GE T", "GET\r\nX: 1", "", "G(ET"] {
            XCTAssertFalse(ExtensionFetch.allowed(method: method), method)
        }
    }

    func testForbiddenHeaders() {
        for name in ["Cookie", "Host", "Origin", "Accept-Charset", "X-HTTP-Method", "X-HTTP-Method-Override",
                     "X-Method-Override", "Sec-Fetch-Site", "Proxy-Authorization", "Content-Length"] {
            XCTAssertFalse(ExtensionFetch.sendable(name), name)
        }
        for name in ["Content-Type", "Authorization", "X-Custom", "Accept"] { XCTAssertTrue(ExtensionFetch.sendable(name), name) }
    }

    func testHeaderNamesAreTokensOnly() {
        XCTAssertFalse(ExtensionFetch.sendable("X\r\nOrigin"))
        XCTAssertFalse(ExtensionFetch.sendable("Cookie "))
        XCTAssertFalse(ExtensionFetch.sendable(""))
        XCTAssertTrue(ExtensionFetch.sendable("X-Custom"))
        XCTAssertFalse(ExtensionFetch.sendable("cookie"))
    }

    func testARedirectToAnotherOriginDropsAuthorizationAndCustomHeaders() {
        var next = URLRequest(url: URL(string: "https://other.example/x")!)
        for (k, v) in ["Authorization": "Bearer t", "X-Custom": "1", "Content-Type": "application/json", "Accept": "*/*",
                       "Origin": "chrome-extension://a", "User-Agent": "UA"] { next.setValue(v, forHTTPHeaderField: k) }
        let across = ExtensionFetch.hop(next, from: URL(string: "https://claude.ai/api")!)
        XCTAssertNil(across.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(across.value(forHTTPHeaderField: "X-Custom"))
        XCTAssertEqual(across.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(across.value(forHTTPHeaderField: "Accept"), "*/*")
        XCTAssertEqual(across.value(forHTTPHeaderField: "Origin"), "null", "across origins, as in Chrome")
        let same = ExtensionFetch.hop(next, from: URL(string: "https://other.example:443/start")!)
        XCTAssertEqual(same.value(forHTTPHeaderField: "Authorization"), "Bearer t", "same origin keeps them")
        XCTAssertFalse(ExtensionFetch.sameOrigin(URL(string: "http://other.example/"), URL(string: "https://other.example/")))
        XCTAssertFalse(ExtensionFetch.sameOrigin(URL(string: "https://other.example:8443/"), URL(string: "https://other.example/")))
    }

    // MARK: - whose store

    func testOneStoreOrNone() {
        let a = NSObject(), b = NSObject()
        XCTAssertTrue(ExtensionFetch.only([a, a]) === a)
        XCTAssertNil(ExtensionFetch.only([a, b]), "windows of different profiles or spaces: no telling whose sign-in")
        XCTAssertNil(ExtensionFetch.only([NSObject]()))
    }

    /// An app on this Mac named with a port (WebKit drops such a pattern):
    /// only loopback, only the scheme, host and port named.
    func testLoopbackNamedWithAPort() {
        let manifest: [String: Any] = ["host_permissions": ["http://localhost:41595/*", "*://*.example.com/*"],
                                       "optional_host_permissions": ["http://127.0.0.1:9000/*"]]
        let declares = { (address: String) in ExtensionFetch.declares(URL(string: address)!, in: manifest) }
        XCTAssertTrue(declares("http://localhost:41595/api/item/addFromURL"))
        XCTAssertFalse(declares("http://localhost:41596/"), "another port")
        XCTAssertFalse(declares("https://localhost:41595/"), "another scheme")
        XCTAssertFalse(declares("http://127.0.0.1:41595/"), "another host")
        XCTAssertFalse(declares("http://127.0.0.1:9000/"), "optional, not granted")
        XCTAssertFalse(ExtensionFetch.declares(URL(string: "http://example.com:8080/")!,
                                               in: ["host_permissions": ["http://example.com:8080/*"]]), "loopback only")
        XCTAssertTrue(ExtensionFetch.declares(URL(string: "http://[::1]:5000/")!, in: ["permissions": ["*://[::1]:*/*"]]))
        XCTAssertTrue(ExtensionFetch.loopback(URL(string: "http://127.0.0.1:1/")!))
        XCTAssertFalse(ExtensionFetch.loopback(URL(string: "http://localhost.example.com/")!))
    }

    /// Chrome's urlFilter, as VOT's rules write it.
    func testURLFilter() {
        let m = { (f: String, a: String) in ExtensionFetch.urlFilterMatches(f, a, caseSensitive: false) == true }
        XCTAssertTrue(m("|https://api.browser.yandex.ru/", "https://api.browser.yandex.ru/video-translation/translate"))
        XCTAssertFalse(m("|https://api.browser.yandex.ru/", "https://evil.example/https://api.browser.yandex.ru/"), "anchored at the start")
        XCTAssertTrue(m("||googlevideo.com/", "https://rr3---sn-x.googlevideo.com/videoplayback"))
        XCTAssertTrue(m("||googlevideo.com/", "https://googlevideo.com/x"))
        XCTAssertFalse(m("||googlevideo.com/", "https://notgooglevideo.com/x"), "a domain label, not any suffix")
        XCTAssertTrue(m("example.com^", "https://example.com/"))
        XCTAssertTrue(m("example.com^", "https://example.com"))
        XCTAssertFalse(m("example.com^", "https://example.community/"))
        XCTAssertTrue(m("/api/*/x|", "https://a.b/api/v1/x"))
        XCTAssertFalse(m("/api/*/x|", "https://a.b/api/v1/xy"))
    }

    /// An extension's own header rules: what matches, by priority, and
    /// never the headers that are the browser's, nor a line break.
    func testHeaderRules() {
        let url = URL(string: "https://api.browser.yandex.ru/video-translation/translate")!
        let vot: [String: Any] = ["id": 9001, "priority": 1,
            "action": ["type": "modifyHeaders", "requestHeaders": [
                ["header": "Origin", "operation": "remove"],
                ["header": "Sec-Vtrans-Sk", "operation": "set", "value": "k"],
                ["header": "User-Agent", "operation": "set", "value": "YaBrowser"],
                ["header": "Cookie", "operation": "set", "value": "stolen=1"],
                ["header": "Host", "operation": "set", "value": "other.example"],
                ["header": "Proxy-Authorization", "operation": "set", "value": "x"],
                ["header": "X-Bad\r\nInjected", "operation": "set", "value": "1"],
                ["header": "X-Val", "operation": "set", "value": "a\r\nB: c"],
                ["header": "X-Lf", "operation": "set", "value": "a\nB: c"],
            ]],
            "condition": ["urlFilter": "|https://api.browser.yandex.ru/", "resourceTypes": ["xmlhttprequest"]]]
        let changes = (ExtensionFetch.headerChanges([vot], url: url, method: "POST") ?? [])
        XCTAssertEqual(changes.map(\.name), ["Origin", "Sec-Vtrans-Sk", "User-Agent"], "never Cookie, Host, Proxy-*, or a line break")
        XCTAssertEqual(ExtensionFetch.headerChanges([vot], url: URL(string: "https://example.com/")!, method: "POST")?.isEmpty, true, "another address")

        var request = URLRequest(url: url)
        request.setValue("chrome-extension://x", forHTTPHeaderField: "Origin")
        ExtensionFetch.apply(changes, to: &request)
        XCTAssertNil(request.value(forHTTPHeaderField: "Origin"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Sec-Vtrans-Sk"), "k")

        // Higher priority decides a header; a condition this can't judge,
        // or a resource type that isn't a fetch, doesn't match.
        let high: [String: Any] = ["id": 2, "priority": 5, "action": ["type": "modifyHeaders", "requestHeaders": [["header": "User-Agent", "operation": "set", "value": "high"]]], "condition": ["requestDomains": ["yandex.ru"]]]
        XCTAssertEqual(ExtensionFetch.headerChanges([vot, high], url: url, method: "POST")?.first { $0.name == "User-Agent" }?.value, "high")
        let initiator: [String: Any] = ["id": 3, "action": ["type": "modifyHeaders", "requestHeaders": [["header": "X-A", "operation": "set", "value": "1"]]], "condition": ["initiatorDomains": ["youtube.com"]]]
        let frames: [String: Any] = ["id": 4, "action": ["type": "modifyHeaders", "requestHeaders": [["header": "X-B", "operation": "set", "value": "1"]]], "condition": ["resourceTypes": ["main_frame"]]]
        XCTAssertEqual(ExtensionFetch.headerChanges([initiator, frames], url: url, method: "GET")?.isEmpty, true)
    }

    /// A header value with a line break in it, however written.
    func testBreaksLine() {
        XCTAssertTrue(ExtensionFetch.breaksLine("a\r\nb"), "CRLF is one Character to Swift")
        XCTAssertTrue(ExtensionFetch.breaksLine("a\nb"))
        XCTAssertTrue(ExtensionFetch.breaksLine("a\u{0}b"))
        XCTAssertFalse(ExtensionFetch.breaksLine("plain value"))
    }

    private func rule(_ id: Int, _ priority: Int, _ type: String = "modifyHeaders", _ headers: [[String: Any]] = [],
                      _ condition: [String: Any] = [:]) -> [String: Any] {
        var action: [String: Any] = ["type": type]
        if !headers.isEmpty { action["requestHeaders"] = headers }
        return ["id": id, "priority": priority, "action": action, "condition": condition]
    }

    /// Chrome's order: an allow rule at the same or a higher priority
    /// cancels a header rule; per header the first rule decides, and after
    /// an append only appends.
    func testHeaderRulePrecedence() {
        let url = URL(string: "https://api.example.com/x")!
        let set: [[String: Any]] = [["header": "X-A", "operation": "set", "value": "set"]]
        let append: [[String: Any]] = [["header": "X-A", "operation": "append", "value": "more"]]
        let names = { (rules: [[String: Any]]) in (ExtensionFetch.headerChanges(rules, url: url, method: "GET") ?? []).map { "\($0.operation) \($0.value ?? "")" } }
        XCTAssertEqual(names([rule(1, 2, "modifyHeaders", set), rule(2, 2, "allow")]), [], "an allow rule as high cancels it")
        XCTAssertEqual(names([rule(1, 3, "modifyHeaders", set), rule(2, 2, "allow")]), ["set set"], "a lower allow rule doesn't")
        XCTAssertEqual(names([rule(1, 3, "modifyHeaders", append), rule(2, 2, "modifyHeaders", set)]), ["append more"], "after an append, no set")
        XCTAssertEqual(names([rule(1, 3, "modifyHeaders", append), rule(2, 2, "modifyHeaders", append)]), ["append more", "append more"])
        XCTAssertEqual(names([rule(1, 3, "modifyHeaders", set), rule(2, 2, "modifyHeaders", append)]), ["set set"])
    }

    /// A request to an app on this Mac keeps its Origin and Sec-* headers:
    /// local apps go by Origin.
    func testLoopbackKeepsOrigin() {
        let headers: [[String: Any]] = [["header": "Origin", "operation": "set", "value": "https://evil.example"],
                                        ["header": "Sec-Fetch-Site", "operation": "set", "value": "same-origin"],
                                        ["header": "X-Fine", "operation": "set", "value": "1"]]
        for address in ["http://localhost:41595/api", "http://127.0.0.1:41595/api", "http://[::1]:41595/api"] {
            let changes = ExtensionFetch.headerChanges([rule(1, 1, "modifyHeaders", headers)], url: URL(string: address)!, method: "GET")
            XCTAssertEqual(changes?.map(\.name), ["X-Fine"], address)
        }
        XCTAssertEqual(ExtensionFetch.headerChanges([rule(1, 1, "modifyHeaders", headers)], url: URL(string: "https://example.com/")!, method: "GET")?.count, 3)
    }

    /// regexFilter as Chrome takes it, and never a match without end.
    func testRegexFilterLimits() {
        XCTAssertTrue(ExtensionFetch.regexAllowed("^https://api\\.example\\.com/(v1|v2)/.*$"))
        XCTAssertTrue(ExtensionFetch.regexAllowed("a{2,3}b+"))
        XCTAssertFalse(ExtensionFetch.regexAllowed("(a+)+$"), "a quantifier on a group with one")
        XCTAssertFalse(ExtensionFetch.regexAllowed("((ab)*)*"))
        XCTAssertFalse(ExtensionFetch.regexAllowed("(a|b)\\1"), "a backreference")
        XCTAssertFalse(ExtensionFetch.regexAllowed("a(?=b)"), "lookaround")
        XCTAssertFalse(ExtensionFetch.regexAllowed(String(repeating: "a", count: 2049)), "over 2 KB")
        XCTAssertTrue(ExtensionFetch.regexAllowed("[(a+)+]"), "inside a class, only characters")

        XCTAssertFalse(ExtensionFetch.regexAllowed("^(a|aa)*c$"), "a quantifier on a group with an alternation")
        XCTAssertFalse(ExtensionFetch.regexAllowed("^.*.*.*b"), "three unbounded quantifiers")
        XCTAssertFalse(ExtensionFetch.regexAllowed(".*a.*b"), "two, unanchored")
        XCTAssertFalse(ExtensionFetch.regexAllowed("a{1,5000}b.*"), "a large bound counts as none")
        XCTAssertTrue(ExtensionFetch.regexAllowed("^https://.*\\.example\\.com/.*?x"))
        XCTAssertTrue(ExtensionFetch.regexAllowed("example\\.com/v[0-9]{1,3}/.*"))

        let long = "https://x.example/" + String(repeating: "a", count: 20000)
        XCTAssertEqual(ExtensionFetch.headerChanges([rule(1, 1, "modifyHeaders", [["header": "X-A", "operation": "set", "value": "1"]], ["regexFilter": "a"])],
                                                    url: URL(string: long)!, method: "GET")?.isEmpty, true, "over 2 KB of address: not tried")
    }

    /// The worst a pattern within the limits can be on the longest address
    /// tried stays well under the budget; and one found slow isn't tried
    /// again.
    func testRegexWorstCaseAndSlow() {
        let url = URL(string: "https://x.example/" + String(repeating: "a", count: 2000))!
        for source in ["^.*a.*b", ".*b", "^(ab|a)+b?.*c"] where ExtensionFetch.regexAllowed(source) {
            let rules: [[String: Any]] = [rule(1, 1, "modifyHeaders", [["header": "X-A", "operation": "set", "value": "1"]], ["regexFilter": source])]
            let started = Date()
            _ = ExtensionFetch.headerChanges(rules, url: url, method: "GET")
            XCTAssertLessThan(Date().timeIntervalSince(started), 0.5, source)
        }
        let source = "^https://slow\\.example/.*x"
        let rules: [[String: Any]] = [rule(1, 1, "modifyHeaders", [["header": "X-A", "operation": "set", "value": "1"]], ["regexFilter": source])]
        let matching = URL(string: "https://slow.example/ax")!
        XCTAssertFalse(ExtensionFetch.tooSlow(source))
        XCTAssertEqual(ExtensionFetch.headerChanges(rules, url: matching, method: "GET")?.count, 1)
        ExtensionFetch.markTooSlow(source)
        XCTAssertEqual(ExtensionFetch.headerChanges(rules, url: matching, method: "GET")?.isEmpty, true, "not tried again")
    }

    /// Whatever the work, the request waits no longer than it was given.
    func testWithin() async {
        let started = Date()
        let late = await ExtensionFetch.within(0.1, lane: "test-within") { Thread.sleep(forTimeInterval: 1); return 1 }
        XCTAssertNil(late)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.8)
        let quick = await ExtensionFetch.within(2, lane: "test-within-quick") { 2 }
        XCTAssertEqual(quick, 2)
    }

    /// urlFilter without a regular expression: long addresses and many
    /// wildcards stay quick.
    func testURLFilterIsLinear() {
        let address = "https://a.example/" + String(repeating: "a", count: 20000)
        let started = Date()
        XCTAssertEqual(ExtensionFetch.urlFilterMatches(String(repeating: "*a", count: 200) + "b", address, caseSensitive: false), false)
        XCTAssertEqual(ExtensionFetch.urlFilterMatches("||example^*aaa", address, caseSensitive: false), true)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertEqual(ExtensionFetch.urlFilterMatches("||ÉXAMPLE.com^", "https://www.éxample.com/", caseSensitive: false), true)
    }

    /// Every way an address can name this Mac.
    func testLoopbackHosts() {
        for host in ["localhost", "LOCALHOST.", "app.localhost", "127.0.0.1", "127.0.0.1.", "127.1", "127.255.255.254", "2130706433",
                     "0.0.0.0", "0", "::1", "[::1]", "::", "[::]", "::ffff:127.0.0.1", "[::ffff:7f00:1]", "0:0:0:0:0:0:0:1"] {
            XCTAssertTrue(ExtensionFetch.loopbackHost(host), host)
        }
        for host in ["example.com", "localhost.example.com", "128.0.0.1", "10.0.0.1", "::2", "::ffff:10.0.0.1", "2001:db8::1", "notlocalhost"] {
            XCTAssertFalse(ExtensionFetch.loopbackHost(host), host)
        }
        XCTAssertTrue(ExtensionFetch.loopback(URL(string: "http://127.0.0.2:8080/")!))
        XCTAssertFalse(ExtensionFetch.loopback(URL(string: "file://localhost/x")!))
    }

    /// urlFilter over a huge address isn't tried; a slow one stops at the
    /// deadline and isn't tried again.
    func testURLFilterBounds() {
        let huge = URL(string: "https://x.example/" + String(repeating: "a", count: 1_000_000))!
        let rules = (1...500).map { rule($0, 1, "modifyHeaders", [["header": "X-A", "operation": "set", "value": "1"]],
                                         ["urlFilter": String(repeating: "*a", count: 2000) + "b"]) }
        var started = Date()
        XCTAssertEqual(ExtensionFetch.headerChanges(rules, url: huge, method: "GET")?.isEmpty, true)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1, "over 8 KB: not tried")

        // The matcher's worst: one `*`, then a long literal run that almost
        // matches everywhere — address × pattern steps.
        let filter = "*" + String(repeating: "a", count: 4000) + "b"
        let address = "https://x.example/" + String(repeating: "a", count: 8000)
        _ = ExtensionFetch.urlFilterMatches("a", "https://x.example/a", caseSensitive: false)   // warm up
        started = Date()
        XCTAssertNil(ExtensionFetch.urlFilterMatches(filter, address, caseSensitive: false, deadline: Date().addingTimeInterval(0.02)))
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.3, "stopped at the deadline")
        let one = [rule(1, 1, "modifyHeaders", [["header": "X-A", "operation": "set", "value": "1"]], ["urlFilter": filter])]
        XCTAssertNil(ExtensionFetch.headerChanges(one, url: URL(string: address)!, method: "GET", deadline: Date().addingTimeInterval(0.05)))
        XCTAssertTrue(ExtensionFetch.tooSlow("url:" + filter))
        started = Date()
        XCTAssertEqual(ExtensionFetch.headerChanges(one, url: URL(string: address)!, method: "GET")?.isEmpty, true)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.05, "not tried again")
    }

    /// One extension's matching runs one at a time: work given up on holds
    /// a single thread, and past a few waiting nothing more is queued.
    func testOneLanePerExtension() async {
        let id = "test-lane"
        nonisolated(unsafe) var running = 0, most = 0
        let lock = NSLock()
        let work: @Sendable () -> Int = {
            lock.lock(); running += 1; most = max(most, running); lock.unlock()
            Thread.sleep(forTimeInterval: 0.3)
            lock.lock(); running -= 1; lock.unlock()
            return 1
        }
        let started = Date()
        async let a = ExtensionFetch.within(0.05, lane: id, work)
        async let b = ExtensionFetch.within(0.05, lane: id, work)
        async let c = ExtensionFetch.within(0.05, lane: id, work)
        let results = await [a, b, c]
        XCTAssertEqual(results.compactMap { $0 }.count, 0, "all given up at the budget")
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
        XCTAssertLessThanOrEqual(ExtensionFetch.waiting(for: id), 4)
        for _ in 0..<40 where ExtensionFetch.waiting(for: id) > 0 { try? await Task.sleep(for: .milliseconds(100)) }
        lock.lock(); let peak = most; lock.unlock()
        XCTAssertEqual(peak, 1, "never two at once")
        // A full lane takes nothing more.
        for _ in 0..<4 { Task { _ = await ExtensionFetch.within(0.01, lane: id) { Thread.sleep(forTimeInterval: 0.5); return 0 } } }
        try? await Task.sleep(for: .milliseconds(50))
        let refused = Date()
        let extra = await ExtensionFetch.within(5, lane: id) { 9 }
        XCTAssertNil(extra)
        XCTAssertLessThan(Date().timeIntervalSince(refused), 0.1, "refused at once")
    }

    func testRegexQuantifierCount() {
        XCTAssertFalse(ExtensionFetch.regexAllowed(String(repeating: "a?", count: 20) + String(repeating: "a", count: 20)), "a?ⁿaⁿ")
        XCTAssertTrue(ExtensionFetch.regexAllowed("^https?://(www\\.)?example\\.com/v[0-9]{1,3}/"))
    }
}
