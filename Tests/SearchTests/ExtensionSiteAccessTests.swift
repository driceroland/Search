import AppKit
import WebKit
import XCTest
@testable import Search

/// Settings › Extensions › Runs on (#698): what is kept, how a host and its
/// subdomains are matched, and what WebKit then injects where.
@available(macOS 14, *)
final class SiteAccessStorageTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "site-access-\(UUID())"
        let made = UserDefaults(suiteName: name)!
        addTeardownBlock { made.removePersistentDomain(forName: name) }
        return made
    }

    func testNothingKeptReadsAsEverySite() {
        let kept = defaults()
        // Settings written before there was a choice: other keys, none of ours.
        kept.set(true, forKey: "extensions.private.abc")
        kept.set(["tabs"], forKey: "extensions.granted.abc")
        XCTAssertEqual(SiteAccess.of("abc", in: kept), SiteAccess(mode: .all, hosts: []))
        XCTAssertFalse(SiteAccess.of("abc", in: kept).restricted)
    }

    func testRoundTripAndDefaultLeavesNoKey() {
        let kept = defaults()
        let some = SiteAccess(mode: .some, hosts: ["example.com", "news.site.org"])
        some.save("abc", in: kept)
        XCTAssertEqual(SiteAccess.of("abc", in: kept), some)
        SiteAccess(mode: .click, hosts: ["example.com"]).save("abc", in: kept)
        XCTAssertEqual(SiteAccess.of("abc", in: kept), SiteAccess(mode: .click, hosts: ["example.com"]), "hosts kept for later")
        SiteAccess().save("abc", in: kept)
        XCTAssertNil(kept.object(forKey: SiteAccess.key("abc")), "the default writes nothing")
        some.save("abc", in: kept)
        SiteAccess.forget("abc", in: kept)
        XCTAssertEqual(SiteAccess.of("abc", in: kept), SiteAccess())
    }

    func testOddDataReadsSafely() {
        let kept = defaults()
        kept.set(["mode": "sometimes", "hosts": [1, "Example.COM", "", "example.com", "bad host"]], forKey: SiteAccess.key("abc"))
        XCTAssertEqual(SiteAccess.of("abc", in: kept), SiteAccess(mode: .all, hosts: ["example.com"]))
        kept.set("click", forKey: SiteAccess.key("abc"))
        XCTAssertEqual(SiteAccess.of("abc", in: kept), SiteAccess(), "not a dictionary: the default")
    }

    func testHostsFromWhatIsTyped() {
        XCTAssertEqual(SiteAccess.host(from: "Example.com"), "example.com")
        XCTAssertEqual(SiteAccess.host(from: "  https://www.example.com/path?q=1 "), "example.com")
        XCTAssertEqual(SiteAccess.host(from: "*.example.com"), "example.com")
        XCTAssertEqual(SiteAccess.host(from: "news.example.com:8080"), "news.example.com")
        XCTAssertEqual(SiteAccess.host(from: "localhost"), "localhost")
        XCTAssertEqual(SiteAccess.host(from: "127.0.0.1:5000"), "127.0.0.1")
        XCTAssertEqual(SiteAccess.host(from: "www.com"), "www.com", "www. is only dropped before a real site")
        XCTAssertNil(SiteAccess.host(from: ""))
        XCTAssertNil(SiteAccess.host(from: "two words"))
        XCTAssertNil(SiteAccess.host(from: "https://"))
    }

    func testSubdomainsAreIncludedAndLookalikesAreNot() {
        let hosts = ["example.com"]
        XCTAssertTrue(SiteAccess.covers(hosts, "example.com"))
        XCTAssertTrue(SiteAccess.covers(hosts, "news.example.com"))
        XCTAssertTrue(SiteAccess.covers(hosts, "a.b.EXAMPLE.com"))
        XCTAssertFalse(SiteAccess.covers(hosts, "notexample.com"))
        XCTAssertFalse(SiteAccess.covers(hosts, "example.com.evil.test"))
        XCTAssertFalse(SiteAccess.covers(hosts, "com"))
        XCTAssertTrue(SiteAccess(mode: .all).covers("anything.test"))
        XCTAssertFalse(SiteAccess(mode: .click, hosts: hosts).covers("example.com"))
    }

    func testAddingAndRemoving() {
        let start = SiteAccess(mode: .click, hosts: ["news.example.com"])
        let added = start.adding("example.com")
        XCTAssertEqual(added, SiteAccess(mode: .some, hosts: ["news.example.com", "example.com"]))
        XCTAssertEqual(added.adding("example.com").hosts.count, 2)
        XCTAssertEqual(added.removing("example.com").hosts, [], "a site goes with what is under it")
        XCTAssertEqual(SiteAccess(mode: .some, hosts: ["example.com"]).removing("news.example.com").hosts, [],
                       "taking a subdomain off takes the site that covers it")
    }

    func testNarrowingWhatWasAskedFor() {
        func narrow(_ asked: String, _ host: String, _ subdomains: Bool = true) -> String? {
            let scheme = String(asked.prefix { $0 != ":" })
            let rest = asked.dropFirst(scheme.count + 3)
            let askedHost = String(rest.prefix { $0 != "/" })
            let path = String(rest.dropFirst(askedHost.count))
            return SiteAccess.narrow(scheme: scheme, host: askedHost, path: path, to: host, subdomains: subdomains)
        }
        XCTAssertEqual(narrow("*://*/*", "example.com"), "*://*.example.com/*")
        XCTAssertEqual(narrow("*://*/*", "example.com", false), "*://example.com/*")
        XCTAssertEqual(narrow("https://*/*", "127.0.0.1"), "https://127.0.0.1/*", "an address has no subdomains")
        XCTAssertEqual(narrow("*://*/*", "localhost"), "*://localhost/*")
        XCTAssertEqual(narrow("https://*.example.com/app/*", "news.example.com"), "https://*.news.example.com/app/*")
        XCTAssertEqual(narrow("https://*.example.com/*", "example.com", false), "https://example.com/*")
        XCTAssertEqual(narrow("https://*.news.example.com/*", "example.com"), "https://*.news.example.com/*")
        XCTAssertNil(narrow("https://*.news.example.com/*", "example.com", false))
        XCTAssertEqual(narrow("https://mail.example.com/*", "example.com"), "https://mail.example.com/*")
        XCTAssertNil(narrow("https://mail.example.com/*", "example.com", false))
        XCTAssertNil(narrow("https://example.com/*", "other.test"))
        XCTAssertNil(narrow("https://*.example.com/*", "notexample.com"))
    }

    func testPasswordManagersAreToldNotStopped() {
        XCTAssertTrue(SiteAccess.needsEverySite(name: "Bitwarden Password Manager", said: [:]))
        XCTAssertTrue(SiteAccess.needsEverySite(name: "1Password – Password Manager", said: [:]))
        XCTAssertTrue(SiteAccess.needsEverySite(name: "Vault", said: ["privacy.services.passwordSavingEnabled": false]))
        XCTAssertFalse(SiteAccess.needsEverySite(name: "Dark Reader", said: [:]))
    }
}

@available(macOS 15.4, *)
@MainActor
@available(macOS 14, *)
final class ExtensionSiteAccessTests: XCTestCase {
    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    private func fixture(_ patterns: [String], content: [String]? = nil) async throws -> (URL, WKWebExtension) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("site-access-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "manifest_version": 3, "name": "Site access", "version": "1",
            "host_permissions": patterns,
            "content_scripts": [["matches": content ?? patterns, "js": ["content.js"]]],
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("manifest.json"))
        try Data("document.documentElement.dataset.injected = String(Number(document.documentElement.dataset.injected || 0) + 1);".utf8)
            .write(to: folder.appendingPathComponent("content.js"))
        return (folder, try await WKWebExtension(resourceBaseURL: folder))
    }

    private func granted(_ context: WKWebExtensionContext) -> Set<String> {
        Set(context.grantedPermissionMatchPatterns.keys.map(\.string))
    }

    func testSomeSitesGrantsOnlyThoseWithTheirSubdomains() async throws {
        let (folder, ext) = try await fixture(["<all_urls>"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let context = WKWebExtensionContext(for: ext)
        Extensions.grantSites(context, as: SiteAccess(mode: .some, hosts: ["example.com", "127.0.0.1"]))
        Extensions.fence(context)
        XCTAssertEqual(granted(context), ["*://*.example.com/*", "*://127.0.0.1/*"])
        for (text, reached) in [("https://example.com/", true), ("https://news.example.com/a", true),
                                ("http://127.0.0.1:8000/", true), ("https://notexample.com/", false),
                                ("https://example.com.evil.test/", false), ("https://other.test/", false)] {
            XCTAssertEqual(context.hasAccess(to: URL(string: text)!), reached, text)
        }
        XCTAssertFalse(context.hasAccessToAllURLs)
    }

    func testOnClickGrantsNothingAndAllIsUnchanged() async throws {
        let (folder, ext) = try await fixture(["https://*.example.com/*", "https://other.test/*"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let click = WKWebExtensionContext(for: ext)
        Extensions.grantSites(click, as: SiteAccess(mode: .click, hosts: ["example.com"]))
        Extensions.fence(click)
        XCTAssertTrue(granted(click).isEmpty, "\(granted(click))")
        let all = WKWebExtensionContext(for: ext)
        Extensions.grantSites(all, as: SiteAccess())
        let before = WKWebExtensionContext(for: ext)
        Extensions.grantSites(before)
        XCTAssertEqual(granted(all), granted(before), "the default is what it always was")
        // A host it never asked for gives it nothing.
        let unasked = WKWebExtensionContext(for: ext)
        Extensions.grantSites(unasked, as: SiteAccess(mode: .some, hosts: ["unrelated.test"]))
        XCTAssertTrue(granted(unasked).isEmpty)
    }

    func testChangingRunsOnTouchesOnlyTheDifference() async throws {
        let (folder, ext) = try await fixture(["<all_urls>"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let context = WKWebExtensionContext(for: ext)
        context.uniqueIdentifier = "siteaccesstest"
        let own = try WKWebExtension.MatchPattern(string: "https://siteaccesstest.chromiumapp.org/*")
        Extensions.grantSites(context, as: SiteAccess())
        context.setPermissionStatus(.grantedExplicitly, for: own)
        Extensions.fence(context)
        XCTAssertTrue(context.hasAccess(to: URL(string: "https://anything.test/")!))

        Extensions.apply(SiteAccess(mode: .some, hosts: ["example.com"]), to: context)
        XCTAssertEqual(granted(context), ["*://*.example.com/*", own.string])
        XCTAssertFalse(context.hasAccess(to: URL(string: "https://anything.test/")!))

        let click = Extensions.ClickGrant(host: "tab.test", patterns: ["*://tab.test/*"])
        context.setPermissionStatus(.grantedExplicitly, for: try WKWebExtension.MatchPattern(string: "*://tab.test/*"))
        Extensions.apply(SiteAccess(mode: .click, hosts: ["example.com"]), to: context, keeping: [click])
        XCTAssertEqual(granted(context), ["*://tab.test/*", own.string], "a click's grant stays with its tab")

        Extensions.apply(SiteAccess(), to: context)
        XCTAssertTrue(context.hasAccess(to: URL(string: "https://anything.test/")!))
        XCTAssertTrue(granted(context).contains("<all_urls>"))
        XCTAssertTrue(granted(context).contains(own.string))
        // Extension pages and files stay refused whatever "Runs on" says.
        XCTAssertFalse(context.hasAccess(to: URL(string: "file:///tmp/x")!))
    }

    private func load(_ web: WKWebView, _ host: String) async throws {
        web.loadHTMLString("<html><body>fixture</body></html>", baseURL: URL(string: "https://\(host)/"))
        for _ in 0..<100 {
            if !web.isLoading, (try? await web.evaluateJavaScript("document.readyState")) as? String == "complete" { break }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func injected(_ web: WKWebView) async throws -> String {
        // Scripts given after the page loaded arrive a moment later.
        try await Task.sleep(for: .milliseconds(300))
        return try await web.evaluateJavaScript("document.documentElement.dataset.injected || ''") as? String ?? ""
    }

    /// What WebKit does with the grants: content scripts only where "Runs
    /// on" lets them, put into an open page when a click grants its site,
    /// and left out of the next load once taken back.
    func testWebKitInjectsOnlyWhereAllowed() async throws {
        _ = NSApplication.shared
        let (folder, ext) = try await fixture(["<all_urls>"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let controller = WKWebExtensionController(configuration: .nonPersistent())
        let context = WKWebExtensionContext(for: ext)
        context.uniqueIdentifier = "siteaccessweb"
        Extensions.grantSites(context, as: SiteAccess(mode: .some, hosts: ["example.com"]))
        Extensions.fence(context)
        // Its views use a store of their own, which WebKit counts as private.
        context.hasAccessToPrivateData = true
        try controller.load(context)
        defer { try? controller.unload(context) }
        func view() -> WKWebView {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            config.webExtensionController = controller
            return WKWebView(frame: .zero, configuration: config)
        }
        for (host, expected) in [("example.com", "1"), ("news.example.com", "1"), ("other.test", "")] {
            let web = view()
            try await load(web, host)
            let found = try await injected(web)
            XCTAssertEqual(found, expected, host)
        }

        // A click on other.test: its site, granted while the page is open.
        let open = view()
        try await load(open, "other.test")
        let before = try await injected(open)
        XCTAssertEqual(before, "")
        let patterns = SiteAccess.patterns(ext.allRequestedMatchPatterns, on: "other.test", subdomains: false)
        XCTAssertEqual(patterns.map(\.string), ["*://other.test/*"])
        for pattern in patterns { context.setPermissionStatus(.grantedExplicitly, for: pattern) }
        let after = try await injected(open)
        XCTAssertEqual(after, "1", "the click's site runs its scripts in the open page, once, without a reload")
        let sub = view()
        try await load(sub, "sub.other.test")
        let subFound = try await injected(sub)
        XCTAssertEqual(subFound, "", "a click grants the site, not what is under it")

        // Taken back (the tab left the site): the next load goes without.
        Extensions.apply(SiteAccess(mode: .some, hosts: ["example.com"]), to: context)
        XCTAssertFalse(context.hasAccess(to: URL(string: "https://other.test/")!))
        let next = view()
        try await load(next, "other.test")
        let nextFound = try await injected(next)
        XCTAssertEqual(nextFound, "")
        // And a site that stays allowed isn't injected twice in an open page.
        let kept = view()
        try await load(kept, "example.com")
        Extensions.apply(SiteAccess(mode: .some, hosts: ["example.com", "third.test"]), to: context)
        let keptFound = try await injected(kept)
        XCTAssertEqual(keptFound, "1")
    }

    /// Narrowed from every site while loaded: the next load elsewhere goes
    /// without its scripts. Taking <all_urls> out of the granted list alone
    /// left WebKit injecting them everywhere.
    func testNarrowingFromEverySiteStopsScriptsElsewhere() async throws {
        _ = NSApplication.shared
        let (folder, ext) = try await fixture(["<all_urls>"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let controller = WKWebExtensionController(configuration: .nonPersistent())
        let context = WKWebExtensionContext(for: ext)
        context.uniqueIdentifier = "siteaccessnarrow"
        Extensions.grantSites(context, as: SiteAccess())
        Extensions.fence(context)
        context.hasAccessToPrivateData = true
        try controller.load(context)
        defer { try? controller.unload(context) }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.webExtensionController = controller
        let denied = Set(context.deniedPermissionMatchPatterns.keys.map(\.string))
        for (access, expected) in [
            (SiteAccess(mode: .some, hosts: ["example.com"]), ["example.com": "1", "other.test": ""]),
            (SiteAccess(mode: .click), ["example.com": "", "other.test": ""]),
            (SiteAccess(), ["example.com": "1", "other.test": "1"]),
        ] {
            Extensions.apply(access, to: context)
            XCTAssertEqual(Set(context.deniedPermissionMatchPatterns.keys.map(\.string)), denied, "fence's refusals stand")
            for (host, want) in expected {
                let web = WKWebView(frame: .zero, configuration: config)
                try await load(web, host)
                let found = try await injected(web)
                XCTAssertEqual(found, want, "\(access.mode) \(host)")
            }
        }
    }
}

/// Permission changes leave the pages an extension's content scripts are
/// already in alone (#705): WebKit puts them back into every open page
/// they may run in on a refusal, on a grant made again, and on any grant
/// for every website, where they run once more.
@available(macOS 15.4, *)
@MainActor
@available(macOS 14, *)
final class ExtensionRerunTests: XCTestCase {
    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    func testPermissionChangesDontRunScriptsAgain() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("rerun-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let manifest: [String: Any] = [
            "manifest_version": 3, "name": "Rerun", "version": "1",
            "host_permissions": ["<all_urls>"], "optional_permissions": ["tabs"],
            "content_scripts": [["matches": ["<all_urls>"], "js": ["content.js"]]],
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("manifest.json"))
        // Wrapped, as bundled scripts are: a top-level const would make a
        // second run a SyntaxError, hiding it.
        try Data("(() => { const d = document.documentElement.dataset; d.ran = String(Number(d.ran || 0) + 1); })();".utf8)
            .write(to: folder.appendingPathComponent("content.js"))
        let ext = try await WKWebExtension(resourceBaseURL: folder)
        let controller = WKWebExtensionController(configuration: .nonPersistent())
        let context = WKWebExtensionContext(for: ext)
        context.uniqueIdentifier = "rerun"
        Extensions.grantSites(context, as: SiteAccess(mode: .some, hosts: ["a.test", "b.test"]))
        Extensions.fence(context)
        context.hasAccessToPrivateData = true
        try controller.load(context)
        defer { try? controller.unload(context) }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.webExtensionController = controller
        func open(_ host: String) async throws -> WKWebView {
            let web = WKWebView(frame: .zero, configuration: config)
            web.loadHTMLString("<html><body>fixture</body></html>", baseURL: URL(string: "https://\(host)/"))
            for _ in 0..<100 {
                if !web.isLoading, (try? await web.evaluateJavaScript("document.readyState")) as? String == "complete" { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            return web
        }
        func ran(_ web: WKWebView) async throws -> Int {
            try await Task.sleep(for: .milliseconds(400))
            return Int(try await web.evaluateJavaScript("document.documentElement.dataset.ran || '0'") as? String ?? "0") ?? 0
        }
        let a = try await open("a.test"), b = try await open("b.test")
        let startA = try await ran(a), startB = try await ran(b)
        XCTAssertEqual([startA, startB], [1, 1])

        // Fenced again after a permission is given: nothing to refuse anew.
        context.setPermissionStatus(.grantedExplicitly, for: .tabs)
        Extensions.fence(context)
        let fencedA = try await ran(a)
        XCTAssertEqual(fencedA, 1, "fence made again runs nothing again")
        // A site held already, granted again: no second copy.
        Extensions.grant(try .init(string: "*://*.a.test/*"), in: context)
        let regrantA = try await ran(a)
        let freshA = try await ran(try await open("a.test"))
        XCTAssertEqual([regrantA, freshA], [1, 1], "a held site granted again isn't injected twice")

        // Narrowed, then widened, among named sites: kept pages untouched.
        Extensions.apply(SiteAccess(mode: .some, hosts: ["a.test"]), to: context)
        let narrowA = try await ran(a), narrowB = try await ran(b)
        XCTAssertEqual([narrowA, narrowB], [1, 1])
        let lostB = try await ran(try await open("b.test"))
        XCTAssertEqual(lostB, 0, "the lost site's next page goes without")
        Extensions.apply(SiteAccess(mode: .some, hosts: ["a.test", "b.test"]), to: context)
        let widenA = try await ran(a)
        XCTAssertEqual(widenA, 1, "a kept site's page isn't run again")

        // Every site and back: WebKit's own swap, once at most, and never
        // a second copy in the next page.
        Extensions.apply(SiteAccess(), to: context)
        let allA = try await ran(a)
        XCTAssertLessThanOrEqual(allA, 2)
        let allC = try await ran(try await open("c.test"))
        XCTAssertEqual(allC, 1)
        let beforeA = try await ran(a)
        Extensions.apply(SiteAccess(mode: .some, hosts: ["a.test"]), to: context)
        let backA = try await ran(a)
        XCTAssertLessThanOrEqual(backA - beforeA, 1, "every website taken back: once more at most")
        let nextA = try await ran(try await open("a.test")), nextC = try await ran(try await open("c.test"))
        XCTAssertEqual([nextA, nextC], [1, 0], "built again from what is left: once on the kept site, none elsewhere")
    }
}
