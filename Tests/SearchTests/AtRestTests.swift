import Foundation
import XCTest
@testable import Search

/// The address at rest on the tab you're on (AtRest.swift): the site it
/// names, and how a look-alike name is shown.
final class AtRestTests: XCTestCase {
    private func rest(_ address: String) -> AtRest? {
        AtRest.make(URL(string: address)!)
    }

    func testRegistrableDomainInInkSubdomainDim() throws {
        let gist = try XCTUnwrap(rest("https://gist.github.com/someone/abc"))
        XCTAssertEqual(gist.kind, .secure)
        XCTAssertEqual(gist.lead, "gist.")
        XCTAssertEqual(gist.name, "github.com")
        XCTAssertEqual(gist.tail, "")
        XCTAssertEqual(gist.text, "gist.github.com")

        try XCTSkipIf(AtRest.systemSuffix == nil, "The Mac's public suffix list isn't reachable here")
        let bbc = try XCTUnwrap(rest("https://www.bbc.co.uk/news"))
        XCTAssertEqual(bbc.lead, "")
        XCTAssertEqual(bbc.name, "bbc.co.uk")
        let deep = try XCTUnwrap(rest("https://a.b.someone.github.io/"))
        XCTAssertEqual(deep.name, "someone.github.io", "github.io is a suffix anyone registers under")
        XCTAssertEqual(deep.lead, "a.b.")
    }

    func testWwwIsLeftOff() throws {
        XCTAssertEqual(rest("https://www.apple.com/")?.text, "apple.com")
        XCTAssertEqual(rest("https://WWW.Apple.COM./mac")?.text, "apple.com", "case and a trailing dot don't change the site")
    }

    func testUserinfoNeverPassesForTheSite() throws {
        let trick = try XCTUnwrap(rest("https://apple.com@evil.example/"))
        XCTAssertEqual(trick.text, "evil.example")
        let trick2 = try XCTUnwrap(rest("https://accounts.google.com.evil.example/login"))
        XCTAssertEqual(trick2.name, "evil.example")
        XCTAssertEqual(trick2.lead, "accounts.google.com.")
    }

    func testPlainHttpIsMarked() throws {
        let plain = try XCTUnwrap(rest("http://neverssl.com/"))
        XCTAssertEqual(plain.kind, .notSecure)
        XCTAssertEqual(plain.text, "Not secure — neverssl.com")
        // This Mac is not a risk over http.
        XCTAssertEqual(rest("http://localhost:3000/")?.kind, .secure)
        XCTAssertEqual(rest("http://localhost:3000/")?.text, "localhost:3000")
        XCTAssertEqual(rest("http://127.0.0.1:8080/x")?.kind, .secure)
        XCTAssertEqual(rest("http://[::1]:5173/")?.text, "[::1]:5173")
        XCTAssertEqual(rest("http://192.168.1.10/")?.kind, .notSecure)
    }

    func testPortsOnlyWhenNotTheSchemesOwn() throws {
        XCTAssertEqual(rest("https://example.com:443/")?.tail, "")
        XCTAssertEqual(rest("https://example.com:8443/")?.tail, ":8443")
        XCTAssertEqual(rest("http://example.com:80/")?.tail, "")
    }

    func testAddressesStayWhole() throws {
        XCTAssertEqual(rest("https://8.8.8.8/")?.name, "8.8.8.8")
        XCTAssertEqual(rest("https://8.8.8.8/")?.lead, "")
    }

    func testFilesByName() throws {
        let file = try XCTUnwrap(AtRest.make(URL(fileURLWithPath: "/Users/someone/Desktop/My report.pdf")))
        XCTAssertEqual(file.kind, .file)
        XCTAssertEqual(file.text, "My report.pdf")
    }

    func testNotWebsites() throws {
        XCTAssertNil(rest("about:blank"))
        XCTAssertNil(AtRest.of(nil))
        XCTAssertEqual(rest("data:text/html,hi")?.text, "Not a website")
        XCTAssertEqual(rest("data:text/html,hi")?.kind, .other)
        XCTAssertEqual(rest("webkit-extension://abc/popup.html")?.text, "Extension page")
    }

    // MARK: - look-alikes

    func testCyrillicLookalikeShowsPunycode() throws {
        // "аррӏе.com", every letter Cyrillic: Xudong Zheng's 2017 example.
        let fake = try XCTUnwrap(rest("https://xn--80ak6aa92e.com/"))
        XCTAssertEqual(fake.text, "xn--80ak6aa92e.com")
        // Written in its own letters, it is still shown as punycode.
        let typed = try XCTUnwrap(AtRest.make(URL(string: "https://xn--80ak6aa92e.com")!))
        XCTAssertEqual(typed.name, "xn--80ak6aa92e.com")
        XCTAssertEqual(Hosts.ascii("аррӏе.com"), "xn--80ak6aa92e.com")
    }

    func testMixedScriptLookalikeShowsPunycode() throws {
        // "аpple.com" with only the first letter Cyrillic.
        let ascii = Hosts.ascii("аpple.com")
        XCTAssertTrue(ascii.hasPrefix("xn--"), ascii)
        XCTAssertEqual(Hosts.display(ascii), ascii)
        // Greek omicron in "gοοgle".
        let greek = Hosts.ascii("gοοgle.com")
        XCTAssertEqual(Hosts.display(greek), greek)
        // Latin with a dot below, "ạpple".
        let dotted = Hosts.ascii("ạpple.com")
        XCTAssertEqual(Hosts.display(dotted), dotted)
        // A punycode subdomain on a real domain is shown as punycode too.
        let sub = Hosts.ascii("аррӏе.github.io")
        XCTAssertEqual(Hosts.display(sub), sub)
    }

    func testScriptsThatCantPassForLatinShowAsThemselves() throws {
        XCTAssertEqual(Hosts.display(Hosts.ascii("münchen.de")), "münchen.de")
        XCTAssertEqual(Hosts.display(Hosts.ascii("例え.jp")), "例え.jp")
        XCTAssertEqual(Hosts.display(Hosts.ascii("한국.kr")), "한국.kr")
        XCTAssertEqual(Hosts.display(Hosts.ascii("bücher.example")), "bücher.example")
        let japanese = try XCTUnwrap(AtRest.make(URL(string: "https://www." + Hosts.ascii("例え.jp") + "/")!))
        XCTAssertEqual(japanese.text, "例え.jp")
        // Arabic beside Latin is a mix that is shown as punycode.
        let mixed = Hosts.ascii("aمثال.example")
        XCTAssertEqual(Hosts.display(mixed), mixed)
    }

    func testLatinLookalikesAndCJKStrokesShowPunycode() throws {
        for name in ["gıthub.com", "þaypal.com", "ĸoogle.com", "app丨e.com", "goo一gle.com", "faceノbook.com", "appᅵe.com"] {
            let ascii = Hosts.ascii(name)
            XCTAssertEqual(Hosts.display(ascii), ascii, name)
        }
        XCTAssertEqual(Hosts.display(Hosts.ascii("一番.jp")), "一番.jp", "a stroke among ideographs alone is a word")
    }

    func testLoopbackOnlyAsAnAddress() throws {
        XCTAssertEqual(rest("http://127.0.0.1.example.com/")?.kind, .notSecure)
        XCTAssertEqual(rest("http://127.0.0.1/")?.kind, .secure)
    }

    func testAnXnLabelThatDecodesToAsciiStaysAsWritten() throws {
        XCTAssertEqual(Hosts.display("xn--google-.com"), "xn--google-.com")
        XCTAssertEqual(Hosts.display("xn--!!!.com"), "xn--!!!.com")
    }

    func testPunycodeRoundTrips() throws {
        // RFC 3492's own sample strings and a few more.
        for (text, code) in [("münchen", "mnchen-3ya"), ("bücher", "bcher-kva"), ("例え", "r8jz45g"),
                             ("аррӏе", "80ak6aa92e"), ("한국", "3e0b707e")] {
            XCTAssertEqual(Punycode.encode(text), code, text)
            XCTAssertEqual(Punycode.decode(code), text, code)
        }
        XCTAssertNil(Punycode.decode("ü"))
        XCTAssertNil(Punycode.decode("99999999999999999"))
    }

    func testCachedAndSameAsMade() throws {
        let url = URL(string: "https://docs.github.com/en")!
        XCTAssertEqual(AtRest.of(url), AtRest.make(url))
        XCTAssertEqual(AtRest.of(url), AtRest.of(url))
    }

    /// Drice's middle ground: with the setting off, only a warning is said.
    func testWarningsAreSaidWithTheSettingOff() throws {
        XCTAssertTrue(try XCTUnwrap(rest("http://example.com/")).warns, "plain http")
        XCTAssertTrue(try XCTUnwrap(rest("https://xn--80ak6aa92e.com/")).warns, "a Cyrillic look-alike shown as punycode")
        XCTAssertTrue(try XCTUnwrap(rest("https://xn--80ak6aa92e.example.com/")).warns, "a look-alike subdomain")
        XCTAssertFalse(try XCTUnwrap(rest("https://github.com/")).warns)
        XCTAssertFalse(try XCTUnwrap(rest("http://localhost:3000/")).warns, "this Mac")
        XCTAssertFalse(try XCTUnwrap(rest("https://xn--wgv71a119e.jp/")).warns, "日本語.jp is safe to show as itself")
        XCTAssertNil(AtRest.said(URL(string: "https://github.com/"), always: false))
        XCTAssertNotNil(AtRest.said(URL(string: "https://github.com/"), always: true))
        XCTAssertNotNil(AtRest.said(URL(string: "http://example.com/"), always: false))
        XCTAssertNil(AtRest.said(URL(string: "about:blank"), always: true))
    }
}
