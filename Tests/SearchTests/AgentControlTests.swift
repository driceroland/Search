import AppKit
import WebKit
import XCTest
@testable import Search

/// Coding agents (AgentControl): the question's rules, what may be read and
/// where an agent may go, what a page's secret fields give back, and the
/// socket's permissions. Pages are laid out in the bench's room, off every
/// screen; nothing is shown.
@MainActor
final class AgentControlTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "agent-control-\(getpid())", 1)
        super.setUp()
    }

    /// The room the pages were laid out in goes back off the window list:
    /// later tests count every window ordered in as one shown.
    override func tearDown() {
        PageRoom.shared.window?.orderOut(nil)
        super.tearDown()
    }

    // MARK: - consent

    func testNothingBeforeHelloAndNothingWhileAsking() {
        var consent = AgentConsent()
        XCTAssertEqual(consent.verdict(for: "hello"), .go)
        XCTAssertEqual(consent.verdict(for: "open"), .refuse("hello_first"))
        XCTAssertTrue(consent.hello())
        XCTAssertFalse(consent.hello(), "the question goes up once")
        XCTAssertEqual(consent.state, .asking)
        for verb in ["open", "tabs", "read", "click", "shot"] {
            XCTAssertEqual(consent.verdict(for: verb), .wait, verb)
        }
        XCTAssertFalse(consent.may(.read, own: true))
    }

    func testAllowedWithoutTabs() {
        var consent = AgentConsent()
        consent.hello()
        consent.answer(allow: true, seesTabs: false)
        XCTAssertEqual(consent.state, .allowed)
        XCTAssertEqual(consent.verdict(for: "open"), .go)
        XCTAssertEqual(consent.verdict(for: "hello"), .refuse("said_hello"))
        XCTAssertTrue(consent.may(.read, own: true))
        XCTAssertTrue(consent.may(.drive, own: true))
        XCTAssertFalse(consent.may(.read, own: false), "your tabs only if you said so")
        XCTAssertFalse(consent.may(.drive, own: false))
    }

    func testSeeingYourTabsIsNeverUsingThem() {
        var consent = AgentConsent()
        consent.hello()
        consent.answer(allow: true, seesTabs: true)
        XCTAssertTrue(consent.may(.read, own: false))
        XCTAssertFalse(consent.may(.drive, own: false))
    }

    func testRefusedAndEndedAreFinal() {
        var refused = AgentConsent()
        refused.hello()
        refused.answer(allow: false, seesTabs: true)
        XCTAssertEqual(refused.state, .refused)
        XCTAssertFalse(refused.seesTabs)
        XCTAssertEqual(refused.verdict(for: "open"), .refuse("not_allowed"))
        refused.answer(allow: true, seesTabs: true)
        XCTAssertEqual(refused.state, .refused, "no second answer")

        var ended = AgentConsent()
        ended.hello()
        ended.answer(allow: true, seesTabs: true)
        ended.end()
        XCTAssertEqual(ended.state, .ended)
        XCTAssertEqual(ended.verdict(for: "tabs"), .refuse("stopped"))
        XCTAssertFalse(ended.may(.read, own: true))
        ended.answer(allow: true, seesTabs: true)
        XCTAssertEqual(ended.state, .ended)

        var early = AgentConsent()
        early.answer(allow: true, seesTabs: false)
        XCTAssertEqual(early.state, .connected, "no answer to a question that isn't up")
    }

    // MARK: - addresses

    func testOnlyTheWeb() {
        XCTAssertEqual(AgentRules.address("https://example.com/a?b=1")?.absoluteString, "https://example.com/a?b=1")
        XCTAssertEqual(AgentRules.address("http://127.0.0.1:8080/")?.host, "127.0.0.1")
        XCTAssertEqual(AgentRules.address("example.com")?.absoluteString, "https://example.com")
        for refused in ["file:///etc/passwd", "search://settings", "search://passwords", "javascript:alert(1)",
                        "data:text/html,hi", "about:blank", "webkit-extension://abc/popup.html",
                        "chrome-extension://abc/x", "mailto:a@b.c", "tel:123", "ftp://example.com/",
                        "https://user:pass@example.com/", "https://", "", "two words", "FILE:///tmp"] {
            XCTAssertNil(AgentRules.address(refused), refused)
        }
        XCTAssertNil(AgentRules.address(InternalPage.scheme + "://settings"))
    }

    func testWhereItsPagesMayGoByThemselves() {
        for allowed in ["https://a.com", "http://a.com", "about:blank", "blob:https://a.com/x", "data:text/plain,x"] {
            XCTAssertTrue(AgentRules.mayLoad(URL(string: allowed)!), allowed)
        }
        for refused in ["file:///tmp/x", "search://settings", "mailto:a@b.c", "tel:1", "zoommtg://x", "x-apple.systempreferences:x"] {
            XCTAssertFalse(AgentRules.mayLoad(URL(string: refused)!), refused)
        }
    }

    // MARK: - tabs

    func testPrivateTabsAreNeverThere() {
        var consent = AgentConsent()
        consent.hello()
        consent.answer(allow: true, seesTabs: true)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let shy = Tab(shy: true, configuration: configuration)
        let yours = Tab(configuration: configuration)
        XCTAssertEqual(AgentRules.refusal(for: shy, own: false, consent: consent, use: .read), "stale_page")
        XCTAssertEqual(AgentRules.refusal(for: shy, own: true, consent: consent, use: .read), "stale_page")
        XCTAssertNil(AgentRules.refusal(for: yours, own: false, consent: consent, use: .read))
        XCTAssertEqual(AgentRules.refusal(for: yours, own: false, consent: consent, use: .drive), "not_yours")
    }

    // MARK: - keys, conditions, names, pace

    func testKeysNeverCommands() {
        XCTAssertEqual(AgentRules.key("Enter")?.code, 36)
        XCTAssertEqual(AgentRules.key("shift+Tab")?.flags.contains(.shift), true)
        XCTAssertEqual(AgentRules.key("a")?.characters, "a")
        XCTAssertEqual(AgentRules.key("shift++")?.characters, "+")
        for refused in ["cmd+v", "cmd+a", "command+w", "meta+c", "shift+cmd+n", "", "ab", "hyper+x"] {
            XCTAssertNil(AgentRules.key(refused), refused)
        }
    }

    func testNoGuessingAtValuesThroughSelectors() {
        XCTAssertNil(AgentRules.condition(["selector": "input[value^='a']"]))
        XCTAssertNil(AgentRules.condition(["selector": "input[VALUE='hunter2']"]))
        XCTAssertNotNil(AgentRules.condition(["selector": "#done", "text": "Hello"]))
    }

    func testClientNames() {
        XCTAssertEqual(AgentRules.clientName("Claude Code"), "Claude Code")
        XCTAssertEqual(AgentRules.clientName("“Search” wants\nto"), "Search wantsto")
        XCTAssertEqual(AgentRules.clientName(""), "A program")
        XCTAssertEqual(AgentRules.clientName(nil), "A program")
        XCTAssertEqual(AgentRules.clientName(String(repeating: "x", count: 200)).count, 40)
    }

    func testPace() {
        var pace = AgentPace()
        for n in 0..<8 { XCTAssertEqual(pace.delay(at: 100), 0, "burst \(n)") }
        XCTAssertEqual(pace.delay(at: 100), 0.2, accuracy: 0.001)
        // Run as told: a second later, five more are free.
        var later = AgentPace()
        for _ in 0..<9 { _ = later.delay(at: 0) }
        XCTAssertEqual(later.delay(at: 1.2), 0, accuracy: 0.001)
    }

    // MARK: - what a page gives back

    private func page(_ html: String) async throws -> WKWebView {
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: {
            let c = WKWebViewConfiguration()
            c.websiteDataStore = .nonPersistent()
            return c
        }())
        PageRoom.shared.made().contentView?.addSubview(web)
        web.loadHTMLString(html, baseURL: URL(string: "https://agent-test.invalid/"))
        for _ in 0..<100 where web.isLoading || web.url == nil {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        return web
    }

    private func run(_ web: WKWebView, _ script: String) async throws -> [String: Any] {
        let value = try await web.evaluateJavaScript(script, contentWorld: Web.world)
        let text = try XCTUnwrap(value as? String)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    func testSecretValuesNeverLeaveThePage() async throws {
        let web = try await page("""
            <!doctype html><title>secrets</title>
            <label>Name <input id=name value="Ada"></label>
            <label>Password <input type=password id=pw value="hunter2"></label>
            <label>Card <input id=cc autocomplete="cc-number" value="4242424242424242"></label>
            <label>Security code <input id=cvc value="123"></label>
            <label>Code <input id=otp autocomplete="one-time-code" value="987654"></label>
            <label>Shown <input type=password id=shown value="opensesame"></label>
            <button id=show onclick="document.getElementById('shown').type='text'">Show</button>
            """)
        defer { web.removeFromSuperview() }
        let first = try await run(web, PageScripts.read(key: "__test", snap: 1, most: 50, longest: 5000, text: true))
        // The field shown as text after it was read as a password.
        _ = try await web.evaluateJavaScript("document.getElementById('shown').type = 'text'; true")
        let second = try await run(web, PageScripts.read(key: "__test", snap: 2, most: 50, longest: 5000, text: true))
        for out in [first, second] {
            let all = String(data: try JSONSerialization.data(withJSONObject: out), encoding: .utf8) ?? ""
            for secret in ["hunter2", "4242424242424242", "987654", "opensesame"] {
                XCTAssertFalse(all.contains(secret), "\(secret) left the page")
            }
            XCTAssertFalse(all.contains("\"value\":\"123\""), "the card's code left the page")
            XCTAssertTrue(all.contains("Ada"), "an ordinary field's value is read")
            let nodes = out["nodes"] as? [[String: Any]] ?? []
            XCTAssertEqual(nodes.filter { $0["redacted"] as? Bool == true }.count, 5)
        }
        // Typing into a secret field says whether it took, never what it held.
        let index = (second["nodes"] as? [[String: Any]] ?? []).firstIndex { $0["name"] as? String == "Password" } ?? -1
        let focused = try await run(web, PageScripts.touch(key: "__test", snap: 2, index: index, how: "focus", text: "x", replace: false))
        XCTAssertTrue(focused["want"] is NSNull || focused["want"] == nil, "what it held stays in the page")
        let wrong = try await run(web, PageScripts.touch(key: "__test", snap: 2, index: index, how: "verify", text: "guess", replace: true))
        XCTAssertEqual(wrong["verified"] as? Bool, false)
        XCTAssertNil(wrong["holds"])
        // And where a picture must be blacked out: the five fields.
        let boxes = try await run(web, PageScripts.secrets)
        XCTAssertEqual((boxes["boxes"] as? [[Double]])?.count, 5)
    }

    func testFileFieldsAreLeftToYou() async throws {
        let web = try await page("<!doctype html><input type=file id=f><button>Go</button>")
        defer { web.removeFromSuperview() }
        let read = try await run(web, PageScripts.read(key: "__test", snap: 1, most: 50, longest: 100, text: false))
        let index = (read["nodes"] as? [[String: Any]] ?? []).firstIndex { $0["role"] as? String == "button" && $0["name"] as? String != "Go" } ?? 0
        let touched = try await run(web, PageScripts.touch(key: "__test", snap: 1, index: index, how: "click", text: nil, replace: true, strict: true))
        XCTAssertEqual(touched["error"] as? String, "file_input")
    }

    // MARK: - the socket

    func testSocketIsThisUsersOnly() throws {
        let control = AgentControl.shared
        let path = AgentControl.socket.path
        try FileManager.default.createDirectory(at: AgentControl.socket.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Something left there before, open to everyone, is not reused.
        FileManager.default.createFile(atPath: path, contents: Data(), attributes: [.posixPermissions: 0o666])
        control.start()
        defer {
            control.stop()
            try? FileManager.default.removeItem(at: AgentControl.socket.deletingLastPathComponent())
        }
        XCTAssertTrue(control.running)
        var info = stat()
        XCTAssertEqual(lstat(path, &info), 0)
        XCTAssertEqual(info.st_mode & S_IFMT, S_IFSOCK)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
        XCTAssertEqual(info.st_uid, getuid())
        XCTAssertTrue(path.hasPrefix(Store.folder.path), "in Search's own folder")
        control.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "gone when turned off")
    }
}
