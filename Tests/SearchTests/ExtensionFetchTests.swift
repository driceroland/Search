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
}
