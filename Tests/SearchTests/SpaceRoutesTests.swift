import XCTest
@testable import Search

/// Send links to a space (SpaceRoutes.swift): what a rule's site is, which
/// rule an address meets, and that nothing is sent while it is off, with
/// spaces off, or to a space that has gone.
@MainActor
final class SpaceRoutesTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "space-routes-\(getpid())", 1)
        super.setUp()
    }

    private let work = Space(id: UUID(), name: "Work", colour: 0)
    private let home = Space(id: UUID(), name: "Home", colour: 0)
    private var spaces: [UUID: Space] { [work.id: work, home.id: home] }

    private func url(_ text: String) -> URL { URL(string: text)! }

    func testSitesAsTyped() {
        XCTAssertEqual(SpaceRoutes.site("notion.so"), "notion.so")
        XCTAssertEqual(SpaceRoutes.site("  https://www.Notion.so/page?x=1 "), "notion.so")
        XCTAssertEqual(SpaceRoutes.site("*.notion.so"), "notion.so")
        XCTAssertEqual(SpaceRoutes.site("Docs.Google.com."), "docs.google.com")
        XCTAssertEqual(SpaceRoutes.site("localhost:3000"), "localhost")
        XCTAssertEqual(SpaceRoutes.site("127.0.0.1"), "127.0.0.1")
        XCTAssertEqual(SpaceRoutes.site("www.com"), "www.com", "www. is only dropped before a domain")
        for nothing in ["", "   ", "notion", "a..b", "not a site", "https://"] {
            XCTAssertNil(SpaceRoutes.site(nothing), nothing)
        }
    }

    func testSiteOfAnAddressIsWebOnly() {
        XCTAssertEqual(SpaceRoutes.site(of: url("https://www.figma.com/file/1")), "figma.com")
        XCTAssertNil(SpaceRoutes.site(of: url("mailto:me@figma.com")))
        XCTAssertNil(SpaceRoutes.site(of: url("file:///tmp/a.html")))
        XCTAssertNil(SpaceRoutes.site(of: url("search://settings")))
    }

    func testSubdomainsMatchAndTheMostSpecificWins() {
        let routes = [SpaceRoute(site: "google.com", space: home.id), SpaceRoute(site: "docs.google.com", space: work.id)]
        XCTAssertEqual(SpaceRoutes.match(url("https://google.com/"), in: routes)?.space, home.id)
        XCTAssertEqual(SpaceRoutes.match(url("https://mail.google.com/x"), in: routes)?.space, home.id)
        XCTAssertEqual(SpaceRoutes.match(url("https://docs.google.com/d/1"), in: routes)?.space, work.id)
        XCTAssertEqual(SpaceRoutes.match(url("http://a.docs.google.com:8080/"), in: routes)?.space, work.id)
        XCTAssertEqual(SpaceRoutes.match(url("https://www.google.com/"), in: routes)?.space, home.id)
        XCTAssertNil(SpaceRoutes.match(url("https://notgoogle.com/"), in: routes), "a suffix is not a subdomain")
        XCTAssertNil(SpaceRoutes.match(url("https://google.com.evil.example/"), in: routes))
        XCTAssertNil(SpaceRoutes.match(url("ftp://google.com/"), in: routes))
    }

    func testLocalHostsMatchExactly() {
        let routes = [SpaceRoute(site: "localhost", space: work.id), SpaceRoute(site: "127.0.0.1", space: home.id)]
        XCTAssertEqual(SpaceRoutes.match(url("http://localhost:5173/"), in: routes)?.space, work.id)
        XCTAssertEqual(SpaceRoutes.match(url("http://127.0.0.1:8000/"), in: routes)?.space, home.id)
        XCTAssertNil(SpaceRoutes.match(url("http://[::1]:8000/"), in: routes))
    }

    func testOffSpacesOffAndGoneSpacesSendNothing() {
        let routes = [SpaceRoute(site: "figma.com", space: work.id), SpaceRoute(site: "gone.example", space: UUID())]
        let link = url("https://www.figma.com/file/1")
        XCTAssertEqual(SpaceRoutes.space(for: link, routes: routes, on: true, spaces: spaces), work)
        XCTAssertNil(SpaceRoutes.space(for: link, routes: routes, on: false, spaces: spaces))
        XCTAssertNil(SpaceRoutes.space(for: url("https://gone.example/"), routes: routes, on: true, spaces: spaces),
                     "a rule whose space has gone is passed over")
        XCTAssertNil(SpaceRoutes.space(for: url("https://other.example/"), routes: routes, on: true, spaces: spaces))
    }

    func testKeptAsPlainSettings() {
        let route = SpaceRoute(site: "figma.com", space: work.id)
        XCTAssertEqual(SpaceRoute(plist: route.plist), route)
        XCTAssertNil(SpaceRoute(plist: ["site": "figma.com"]))
        XCTAssertNil(SpaceRoute(plist: ["site": "not a site", "space": work.id.uuidString]))
        XCTAssertNil(SpaceRoute(plist: "figma.com"))
    }

    func testOffByDefaultFindableAndKeptBetweenRuns() {
        let keys = [SpaceRoutes.key, SpaceRoutes.rulesKey]
        let saved = keys.map { ($0, Store.settings.object(forKey: $0)) }
        defer { for (key, value) in saved { Store.settings.set(value, forKey: key) } }
        keys.forEach(Store.settings.removeObject(forKey:))
        let prefs = Preferences()
        XCTAssertFalse(prefs.sendsLinksToSpaces)
        XCTAssertTrue(prefs.spaceRoutes.isEmpty)
        prefs.spaceRoutes = [SpaceRoute(site: "figma.com", space: work.id)]
        XCTAssertEqual(Preferences().spaceRoutes, prefs.spaceRoutes)
        for words in ["send links", "air traffic control", "open in space", "routing"] {
            XCTAssertTrue(SettingsIndex.find(words).contains { $0.id == "spaces.links" }, words)
        }
        XCTAssertEqual(SettingsIndex.item("spaces.links")?.page, .spaces)
        XCTAssertEqual(SettingsIndex.item("spaces.links")?.parent, "spaces")
    }
}
