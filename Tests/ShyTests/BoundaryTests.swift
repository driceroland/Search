import WebKit
import XCTest
@testable import Shy

/// One sting into each place a page, an extension, an agent or a file can
/// try to reach further than it should: the checks at those boundaries, fed
/// what an attacker would send. Pure functions where there are any; a real
/// page only for what only a page can tell.
@MainActor
final class BoundaryTests: XCTestCase {
    // MARK: - test runs

    func testATestRunNeverUsesTheRealBrowsersSettings() {
        // Whatever SHY_PROBE says: xctest is no installed app.
        XCTAssertTrue(Store.testing)
        XCTAssertNotNil(Store.world)
        XCTAssertNotEqual(Store.settings, UserDefaults.standard)
    }

    // MARK: - extensions from the store

    private func crx(header: [UInt8], version: UInt32 = 3, claimedSize: UInt32? = nil) -> Data {
        var bytes = Array("Cr24".utf8)
        for value in [version, claimedSize ?? UInt32(header.count)] {
            bytes += [UInt8(value & 0xff), UInt8(value >> 8 & 0xff), UInt8(value >> 16 & 0xff), UInt8(value >> 24)]
        }
        return Data(bytes + header + Array("PK not really a zip".utf8))
    }

    private func refusal(_ crx: Data, id: String = String(repeating: "a", count: 32)) -> Crx.Refused? {
        do {
            _ = try Crx.verifiedZip(crx, id: id)
            return nil
        } catch let refused as Crx.Refused {
            return refused
        } catch {
            XCTFail("an error that isn't a refusal: \(error)")
            return nil
        }
    }

    func testAPackageThatIsNotACRX3IsRefused() {
        guard case .notCrx = refusal(Data("PK\u{3}\u{4}".utf8 + Array(repeating: 0, count: 20))) else { return XCTFail() }
        guard case .notCrx = refusal(crx(header: [], version: 2)) else { return XCTFail("CRX2 is not taken") }
        guard case .notCrx = refusal(crx(header: [], claimedSize: 1 << 30)) else { return XCTFail("a header past the end") }
    }

    func testAHeaderNamingTheRightIDWithoutAProofIsRefused() {
        let key: [UInt8] = Array(repeating: 7, count: 16)
        let id = Crx.letters(key)
        // signed_header_data (field 10000) holding crx_id (field 1), and no
        // sha256_with_rsa proof at all.
        let signed: [UInt8] = [0x0A, 16] + key
        let header: [UInt8] = [0x82, 0xE2, 0x04, UInt8(signed.count)] + signed
        guard case .unsignedOrWrong = refusal(crx(header: header), id: id) else { return XCTFail() }
    }

    func testAHostileLengthInTheHeaderIsRefusedNotACrash() {
        // A length whose varint runs to the sign bit: before the fix,
        // `i + length` trapped on bytes read before any signature check.
        let header: [UInt8] = [0x0A] + Array(repeating: 0xFF, count: 8) + [0x7F]
        guard case .unsignedOrWrong = refusal(crx(header: header)) else { return XCTFail() }
        let huge: [UInt8] = [0x0A] + Array(repeating: 0xFF, count: 7) + [0x3F]
        guard case .unsignedOrWrong = refusal(crx(header: huge)) else { return XCTFail() }
    }

    func testAPackageWithALinkInItIsNotUnpacked() throws {
        let files = FileManager.default
        let scratch = files.temporaryDirectory.appendingPathComponent("shy-link-\(UUID().uuidString)")
        defer { try? files.removeItem(at: scratch) }
        let source = scratch.appendingPathComponent("source")
        try files.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: source.appendingPathComponent("manifest.json"))
        try files.createSymbolicLink(at: source.appendingPathComponent("page.html"), withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        let zip = scratch.appendingPathComponent("x.zip")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", source.path, zip.path]
        try ditto.run()
        ditto.waitUntilExit()
        let target = scratch.appendingPathComponent("installed")
        XCTAssertThrowsError(try Crx.unpack(Data(contentsOf: zip), into: target))
        XCTAssertFalse(files.fileExists(atPath: target.path), "nothing is left where the extension would go")
    }

    func testTheStoreIDComesOnlyFromTheStore() {
        let id = String(repeating: "abcdefghijklmnop", count: 2)
        XCTAssertEqual(Crx.storeID(of: URL(string: "https://chromewebstore.google.com/detail/name/\(id)")!), id)
        XCTAssertNil(Crx.storeID(of: URL(string: "http://chromewebstore.google.com/detail/name/\(id)")!), "not over http")
        XCTAssertNil(Crx.storeID(of: URL(string: "https://chromewebstore.google.com.evil.com/detail/name/\(id)")!))
        XCTAssertNil(Crx.storeID(of: URL(string: "https://evil.com/detail/name/\(id)?chromewebstore.google.com")!))
        XCTAssertNil(Crx.storeID(of: URL(string: "https://evil@chromewebstore.google.com/detail/name/\(id)")!), "no one's name in front")
        XCTAssertNil(Crx.id(in: id + "a"), "33 letters")
        XCTAssertNil(Crx.id(in: String(repeating: "z", count: 32)), "letters past p")
    }

    func testAnUpdateOnlyEverGoesUp() {
        XCTAssertTrue(Extensions.newer("1.2.10", than: "1.2.9"))
        XCTAssertTrue(Extensions.newer("2", than: "1.9.9.9"))
        XCTAssertFalse(Extensions.newer("1.2.9", than: "1.2.10"), "a signed older version is still a rollback")
        XCTAssertFalse(Extensions.newer("1.2", than: "1.2.0"), "the same version, written shorter")
        XCTAssertFalse(Extensions.newer("1.2.x", than: "1.2"), "not a version")
        XCTAssertFalse(Extensions.newer("1.2.3.4.5", than: "1.2"), "five parts is not a Chrome version")
    }

    func testAYesToAnExtensionInOneProfileIsNotAYesInAnother() {
        let other = UUID()
        let id = String(repeating: "b", count: 32)
        XCTAssertEqual(Extensions.grantKey("private", id, Profile.personalID), "extensions.private.\(id)",
                       "Personal keeps the key there always was")
        XCTAssertNotEqual(Extensions.grantKey("private", id, other), Extensions.grantKey("private", id, Profile.personalID))
        XCTAssertNotEqual(Extensions.grantKey("granted", id, other), Extensions.grantKey("private", id, other))
    }

    func testOnlyNarrowSitePatternsMayTalkToAnExtension() {
        for refused in ["*://*/*", "https://*.com/*", "https://*.*.example.com/*", "ftp://a.com/*", "https://a.com"] {
            XCTAssertFalse(ExtensionExternal.allowed(refused), refused)
        }
        XCTAssertTrue(ExtensionExternal.allowed("https://*.example.com/*"))
    }

    // MARK: - the address field

    func testAKeywordsWordsNeverDecideTheSite() {
        XCTAssertTrue(Keyword.accepts("https://www.youtube.com/results?search_query=%s"))
        for refused in ["https://%s.evil.com/", "https://%s@x.com/", "javascript:%s", "https://x.com/?a=%s&b=%s", "https://x.com/"] {
            XCTAssertFalse(Keyword.accepts(refused), refused)
        }
        let keywords = [Keyword(keyword: "yt", template: "https://www.youtube.com/results?search_query=%s"),
                        Keyword(keyword: "bad", template: "https://%s.evil.com/")]
        XCTAssertEqual(Keyword.match("YT cats", in: keywords)?.1, "cats")
        XCTAssertNil(Keyword.match("bad words", in: keywords), "a template that could move the host is never used")
    }

    func testSearchWordsStayInTheQuery() throws {
        let url = try XCTUnwrap(Engine.url(for: "a&b#c/d?@evil.com", template: "https://search.example/?q=%s"))
        XCTAssertEqual(url.host(), "search.example")
        XCTAssertNil(url.fragment)
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "a&b#c/d?@evil.com")
    }

    func testATypedSiteIsNeverFinishedAsALongerOne() {
        XCTAssertTrue(History.typedInFull("paypal.com"), "paypal.com.evil.io must not be Return's answer")
        XCTAssertFalse(History.typedInFull("paypal"), "a name still being typed is finished as before")
        XCTAssertFalse(History.typedInFull("news.ycombinator"))
        XCTAssertFalse(History.typedInFull("paypal.com/"), "a path is past the host")
    }

    func testTypedScriptIsNeverAnAddress() {
        XCTAssertNil(Address.url(from: "javascript:alert(1)"))
        XCTAssertEqual(Address.url(from: "example.com")?.scheme, "https")
    }

    func testOnlyWebsitesAndFilesMayBeDroppedOnTheTabs() {
        for allowed in ["https://example.com/", "http://example.com/", "file:///Users/x/a.html"] {
            XCTAssertTrue(Browser.mayDrop(URL(string: allowed)!), allowed)
        }
        for refused in ["javascript:alert(1)", "data:text/html,<script>1</script>", "shy://passwords",
                        "chrome-extension://abc/page.html", "facetime:123", "x-apple.systempreferences:"] {
            XCTAssertFalse(Browser.mayDrop(URL(string: refused)!), refused)
        }
    }

    // MARK: - what a page hands over

    func testADownloadsNameIsOnlyAName() {
        XCTAssertEqual(Browser.fileName("../../x.sh"), "x.sh")
        XCTAssertEqual(Browser.fileName(".."), "download")
        XCTAssertEqual(Browser.fileName(".bashrc"), "bashrc", "never a hidden file")
        XCTAssertEqual(Browser.fileName("invoice\u{202E}fdp.app"), "invoicefdp.app", "nothing that turns the writing around")
        XCTAssertEqual(Browser.fileName("a\u{0}b\nc.txt"), "abc.txt")
        XCTAssertEqual(Browser.fileName("report.pdf"), "report.pdf")
    }

    func testADownloadNeverWritesOverAFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("shy-free-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data().write(to: folder.appendingPathComponent("a.pdf"))
        try Data().write(to: folder.appendingPathComponent("a"))
        XCTAssertEqual(Browser.free("a.pdf", in: folder).lastPathComponent, "a 2.pdf")
        XCTAssertEqual(Browser.free("a", in: folder).lastPathComponent, "a 2")
        XCTAssertEqual(Browser.free("b.pdf", in: folder).lastPathComponent, "b.pdf")
    }

    func testOnlyThisMacIsTakenOnTrust() {
        for mine in ["localhost", "127.0.0.1", "127.255.0.1", "::1", "[::1]"] { XCTAssertTrue(Dialogs.isLoopback(mine), mine) }
        for other in ["127.0.0.1.example.com", "localhost.evil.com", "127.1", "0x7f.0.0.1", "10.0.0.1"] {
            XCTAssertFalse(Dialogs.isLoopback(other), other)
        }
    }

    func testAPasskeyIsOnlyForItsOwnSite() throws {
        try XCTSkipIf(Passkeys.publicSuffix == nil, "no public suffix list on this Mac")
        XCTAssertTrue(Passkeys.fits("example.com", "login.example.com"))
        XCTAssertTrue(Passkeys.fits("login.example.com", "login.example.com"))
        for (rp, host) in [("com", "example.com"), ("github.io", "a.github.io"), ("co.uk", "bbc.co.uk"),
                           ("ample.com", "example.com"), ("0.1", "10.0.0.1"), ("example.com", "example.com.evil.net")] {
            XCTAssertFalse(Passkeys.fits(rp, host), "\(rp) for \(host)")
        }
    }

    // MARK: - the agent

    func testTheAgentOpensOnlyWebsites() {
        XCTAssertNotNil(Agent.web("https://example.com/"))
        for refused in ["file:///etc/hosts", "shy://passwords", "data:text/html,1", "javascript:1", "http://", "ftp://example.com/"] {
            XCTAssertNil(Agent.web(refused), refused)
        }
        XCTAssertNil(Agent.web("https://example.com/" + String(repeating: "a", count: 9000)), "nothing longer than an address")
        XCTAssertNil(Agent.web(42), "a number is not an address")
    }

    func testAHandedOverCookieGoesOnlyToItsSite() throws {
        func cookie(_ domain: String, expires: Date? = nil) throws -> HTTPCookie {
            var properties: [HTTPCookiePropertyKey: Any] = [.name: "s", .value: "1", .domain: domain, .path: "/"]
            if let expires { properties[.expires] = expires }
            return try XCTUnwrap(HTTPCookie(properties: properties))
        }
        let wide = try cookie(".example.com")
        XCTAssertTrue(Agent.sent(wide, to: "a.example.com"))
        XCTAssertTrue(Agent.sent(wide, to: "example.com"))
        XCTAssertFalse(Agent.sent(wide, to: "badexample.com"))
        XCTAssertFalse(Agent.sent(try cookie("example.com"), to: "sub.example.com"), "a host's own cookie stays with it")
        XCTAssertFalse(Agent.sent(try cookie(".example.com", expires: Date(timeIntervalSinceNow: -60)), to: "example.com"))
    }

    // MARK: - scripts Shy runs in a page

    /// Shy looks at pages all the time — their icon, their sound, whether a
    /// sign-in went through. Run WebKit's public way, each look counted as a
    /// click, and a page waiting for one could take the clipboard or the
    /// screen. Run Shy's way, the page is never handed a click.
    func testShysOwnScriptsHandThePageNoClick() async throws {
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 200, height: 200), configuration: {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            return configuration
        }())
        web.loadHTMLString("<p>page</p>", baseURL: URL(string: "https://boundary.invalid/"))
        for _ in 0..<100 where (try? await web.quietly("document.readyState", in: nil, in: .page)) as? String != "complete" {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let before = try await web.quietly("navigator.userActivation.hasBeenActive", in: nil, in: .page) as? Bool
        XCTAssertEqual(before, false, "a look of Shy's is no click")
        _ = try await web.quietly("return 1", asFunction: true, in: nil, in: Web.world)
        let after = try await web.quietly("navigator.userActivation.hasBeenActive", in: nil, in: .page) as? Bool
        XCTAssertEqual(after, false, "nor is a script run in Shy's own world")
        // The control: WebKit's public call does hand one over.
        _ = try await web.evaluateJavaScript("1")
        let control = try await web.quietly("navigator.userActivation.hasBeenActive", in: nil, in: .page) as? Bool
        XCTAssertEqual(control, true, "the public call counts as a click, which is why it isn't used")
    }
}
