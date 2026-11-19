import AppKit
import Foundation
import WebKit
import XCTest
@testable import Search

/// Which boxes saved accounts are offered in (#631), on real-world forms kept
/// in Tests/FieldFixtures: Forms.script's judge, run in Search's own world as
/// a tab runs it, on each fixture at the address it was taken from. No
/// keychain, no window.
@MainActor
final class FormFieldCorpusTests: XCTestCase {
    private static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("FieldFixtures")

    private struct Fixture {
        let file: String
        let url: URL
        let expect: String
        let name: Bool?
        /// Offered verification codes: false unless its first line says so.
        let code: Bool
        let html: String
    }

    private var holding: [NSObject] = []
    /// What the page last loaded has told the browser.
    private var listening: Quiet?

    override func setUp() async throws {
        try await super.setUp()
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
    }

    override func tearDown() async throws {
        holding = []
        try await super.tearDown()
    }

    func testEveryFixtureIsOfferedWhatItShouldBe() async throws {
        let all = try Self.corpus()
        XCTAssertGreaterThanOrEqual(all.count, 13, "the corpus is there")
        for fixture in all {
            let answer = try await judge(fixture)
            let verdict = answer?["verdict"] as? [String: Any]
            XCTAssertEqual(answer?["code"] as? Bool, fixture.code, "\(fixture.file): offered codes?")
            let got = verdict == nil ? "none" : (verdict?["wide"] as? Bool == true ? "wide" : "exact")
            XCTAssertEqual(got, fixture.expect, "\(fixture.file): offered \(got), expected \(fixture.expect)")
            if let name = fixture.name, verdict != nil {
                XCTAssertEqual(verdict?["name"] as? Bool, name, "\(fixture.file): a pick puts in the name alone?")
            }
        }
    }

    func testTheCorpusCoversCodeBoxesAndWhatOnlyLooksLikeThem() throws {
        let all = try Self.corpus()
        let files = Set(all.map(\.file))
        for needed in ["code-keycloak", "code-github", "code-google", "code-microsoft", "code-aws", "code-cells",
                       "code-french", "code-plain-signin", "notcode-promo", "notcode-postal", "notcode-recovery",
                       "notcode-card", "notcode-dial", "notcode-product", "notcode-footprint", "notcode-passkey-row"] {
            XCTAssertTrue(files.contains(needed), "\(needed).html is in the corpus")
        }
        for fixture in all where fixture.file.hasPrefix("code-") { XCTAssertTrue(fixture.code, fixture.file) }
        for fixture in all where fixture.file.hasPrefix("notcode-") { XCTAssertFalse(fixture.code, fixture.file) }
    }

    /// What the browser hears with the caret in a box: the box, and that it
    /// takes a code, whose list then hangs from it.
    func testTheCaretInACodeBoxSaysSo() async throws {
        func said(_ file: String) async throws -> [String: Any]? {
            let web = try await load(file)
            _ = try await call(web, """
            document.querySelector('[data-probe]').focus();
            document.dispatchEvent(new Event('focusin'));
            return true;
            """)
            _ = try await call(web, "return true;")
            return listening?.heard.last { $0["kind"] as? String == "focus" }
        }
        let code = try await said("code-keycloak")
        XCTAssertEqual(code?["code"] as? Bool, true)
        XCTAssertEqual(code?["passwords"] as? Bool, false, "no account goes in it")
        XCTAssertNotNil(code?["rect"] as? [String: Any])
        XCTAssertEqual(code?["wide"] as? Bool, false, "a guess: this host's codes alone")
        let sure = try await said("code-github")
        XCTAssertEqual(sure?["code"] as? Bool, true)
        XCTAssertEqual(sure?["wide"] as? Bool, true, "it says so: the site's other hosts' codes too")
        let row = try await said("code-cells")
        XCTAssertEqual(row?["code"] as? Bool, true)
        XCTAssertEqual(row?["wide"] as? Bool, false, "a row of boxes is a guess too")
        let signIn = try await said("urssaf-login")
        XCTAssertEqual(signIn?["code"] as? Bool, false)
        XCTAssertEqual(signIn?["passwords"] as? Bool, true)
        let promo = try await said("notcode-promo")
        XCTAssertEqual(promo?["code"] as? Bool, false)
        XCTAssertTrue(promo?["rect"] is NSNull, "nothing hangs from it")
        // A box marked for passkeys stays theirs: its list hangs from it.
        let passkey = try await said("notcode-passkey-row")
        XCTAssertEqual(passkey?["code"] as? Bool, false)
        XCTAssertEqual(passkey?["passwords"] as? Bool, false)
        XCTAssertNotNil(passkey?["rect"] as? [String: Any])
    }

    /// A code goes in as a keystroke would put it: through the field's own
    /// setter, with the events a framework listens for.
    func testACodeGoesIntoItsBox() async throws {
        let web = try await load("code-github")
        let answer = try await call(web, """
        var el = document.querySelector('[data-probe]'), heard = 0;
        el.addEventListener('input', function () { heard++; });
        el.focus();
        var done = window.__officeForms.code('135790');
        return { done: done, value: el.value, heard: heard };
        """) as? [String: Any]
        XCTAssertEqual(answer?["done"] as? Bool, true)
        XCTAssertEqual(answer?["value"] as? String, "135790")
        XCTAssertEqual(answer?["heard"] as? Int, 1)
    }

    func testACodeGoesDigitByDigitAcrossARowOfBoxes() async throws {
        let web = try await load("code-cells")
        let answer = try await call(web, """
        var el = document.querySelector('[data-probe]');
        el.focus();
        var done = window.__officeForms.code('135790');
        var boxes = Array.prototype.map.call(document.querySelectorAll('input[maxlength="1"]'), function (b) { return b.value; });
        return { done: done, boxes: boxes.join('') };
        """) as? [String: Any]
        XCTAssertEqual(answer?["done"] as? Bool, true)
        XCTAssertEqual(answer?["boxes"] as? String, "135790")

        let wrong = try await call(web, """
        document.querySelectorAll('input[maxlength="1"]').forEach(function (b) { b.value = ''; });
        document.querySelector('[data-probe]').focus();
        var done = window.__officeForms.code('12345678');
        return { done: done, first: document.querySelector('[data-probe]').value };
        """) as? [String: Any]
        XCTAssertEqual(wrong?["done"] as? Bool, false, "a code that doesn't fit the row goes nowhere")
        XCTAssertEqual(wrong?["first"] as? String, "")
    }

    func testACodeGoesNowhereButABoxForOne() async throws {
        let web = try await load("notcode-promo")
        let answer = try await call(web, """
        var el = document.querySelector('[data-probe]');
        el.focus();
        var done = window.__officeForms.code('135790');
        return { done: done, value: el.value };
        """) as? [String: Any]
        XCTAssertEqual(answer?["done"] as? Bool, false)
        XCTAssertEqual(answer?["value"] as? String, "")
    }

    /// The fixtures the brief names are all there, so the corpus can't
    /// quietly shrink.
    func testTheCorpusCoversTheNamedSites() throws {
        let files = Set(try Self.corpus().map(\.file))
        for needed in ["gcloud-new-project", "github-new-repo", "notion-page-title", "slack-message",
                       "gmail-compose-to", "amazon-search", "urssaf-login", "google-identifier",
                       "impots-identifier", "norma-password-only", "okta-username", "newsletter-signup",
                       "checkout-email"] {
            XCTAssertTrue(files.contains(needed), "\(needed).html is in the corpus")
        }
    }

    /// The scope: a real sign-in box gets the site's accounts, its other
    /// hosts' too; a box that only might be one, this host's alone. Gmail's
    /// account, kept for accounts.google.com, never reaches a box on
    /// console.cloud.google.com that isn't clearly a sign-in's.
    func testOnlyARealSignInReachesTheSitesOtherHosts() {
        let console = "console.cloud.google.com"
        XCTAssertTrue(Vault.belongs("accounts.google.com", to: console, wide: true))
        XCTAssertFalse(Vault.belongs("accounts.google.com", to: console, wide: false))
        XCTAssertTrue(Vault.belongs(console, to: console, wide: false))
        XCTAssertFalse(Vault.belongs("google.co.uk", to: console, wide: true), "another site is never offered")
        XCTAssertTrue(ApplePasswords.belongs(["https://accounts.google.com"], to: console, wide: true))
        XCTAssertFalse(ApplePasswords.belongs(["https://accounts.google.com"], to: console, wide: false))
        XCTAssertTrue(ApplePasswords.belongs(["https://www.console.cloud.google.com/"], to: console, wide: false))
    }

    // MARK: -

    private static func corpus() throws -> [Fixture] {
        let names = try FileManager.default.contentsOfDirectory(atPath: fixtures.path)
            .filter { $0.hasSuffix(".html") }.sorted()
        return try names.map { name in
            let html = try String(contentsOf: fixtures.appendingPathComponent(name), encoding: .utf8)
            let head = html.prefix(while: { $0 != "\n" })
            func field(_ key: String) -> String? {
                guard let range = head.range(of: key + ": ") else { return nil }
                return head[range.upperBound...].split(separator: " ").first.map(String.init)
            }
            guard let address = field("url"), let url = URL(string: address), let expect = field("expect") else {
                throw NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(name): no url/expect line"])
            }
            return Fixture(file: String(name.dropLast(5)), url: url, expect: expect,
                           name: field("name").map { $0 == "true" }, code: field("code") == "true", html: html)
        }
    }

    private func load(_ file: String) async throws -> WKWebView {
        let fixture = try XCTUnwrap(try Self.corpus().first { $0.file == file })
        return try await load(fixture)
    }

    private func load(_ fixture: Fixture) async throws -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let quiet = Quiet()
        listening = quiet
        configuration.userContentController.add(quiet, contentWorld: Web.world, name: FormRelay.name)
        configuration.userContentController.addUserScript(
            WKUserScript(source: FormRelay.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: Web.world))
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1200, height: 900), configuration: configuration)
        let loaded = Loaded()
        holding += [loaded, quiet, web]
        web.navigationDelegate = loaded
        // Nothing leaves the Mac: the fixture's address is only its base, and
        // every load but the fixture itself is refused.
        web.loadHTMLString(fixture.html, baseURL: fixture.url)
        try await loaded.wait()
        return web
    }

    private func judge(_ fixture: Fixture) async throws -> [String: Any]? {
        let web = try await load(fixture)
        let answer = try await call(web, """
        var el = document.querySelector('[data-probe]');
        if (!el) return 'missing';
        try { el.focus(); } catch (e) {}
        if (!window.__officeForms) return 'no script';
        return { verdict: window.__officeForms.verdict(el), code: window.__officeForms.coded(el) };
        """)
        if let text = answer as? String { XCTFail("\(fixture.file): \(text)") }
        return answer as? [String: Any]
    }

    private func call(_ web: WKWebView, _ body: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            web.callAsyncJavaScript(body, arguments: [:], in: nil, in: Web.world) { (result: Result<Any, Error>) in
                continuation.resume(with: result.map { $0 is NSNull ? nil : $0 })
            }
        }
    }

    private final class Quiet: NSObject, WKScriptMessageHandler {
        private(set) var heard: [[String: Any]] = []

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            if let body = message.body as? [String: Any] { heard.append(body) }
        }
    }

    private final class Loaded: NSObject, WKNavigationDelegate {
        private var continuation: CheckedContinuation<Void, Error>?
        private var done = false

        func wait() async throws {
            if done { return }
            try await withCheckedThrowingContinuation { self.continuation = $0 }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(action.request.url?.scheme == "about" || !done ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            done = true
            continuation?.resume()
            continuation = nil
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            done = true
            continuation?.resume(throwing: error)
            continuation = nil
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            done = true
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }
}
