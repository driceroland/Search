import XCTest
@testable import Search

/// mailto: links read as RFC 6068 has them, and the webmail compose pages
/// made from them (Webmail.swift).
final class WebmailTests: XCTestCase {
    private func draft(_ text: String) -> MailDraft { MailDraft(string: text)! }
    private func query(_ url: URL?) -> [String: String] {
        var out: [String: String] = [:]
        for item in URLComponents(url: url!, resolvingAgainstBaseURL: false)?.queryItems ?? [] { out[item.name] = item.value ?? "" }
        return out
    }

    func testOnlyMailto() {
        XCTAssertNil(MailDraft(string: "https://example.com"))
        XCTAssertNil(MailDraft(string: "mail:a@b.c"))
        XCTAssertEqual(MailDraft(string: "MAILTO:a@example.com")?.to, ["a@example.com"])
        XCTAssertEqual(MailDraft(string: "mailto:"), MailDraft())
    }

    func testRecipients() {
        let d = draft("mailto:a@example.com,%20b@example.com?to=c@example.com&cc=d@example.com,e@example.com&bcc=f@example.com&CC=g@example.com")
        XCTAssertEqual(d.to, ["a@example.com", "b@example.com", "c@example.com"])
        XCTAssertEqual(d.cc, ["d@example.com", "e@example.com", "g@example.com"])
        XCTAssertEqual(d.bcc, ["f@example.com"])
    }

    func testPlusIsAPlus() {
        let d = draft("mailto:user+tag@example.com?subject=1+1%3D2")
        XCTAssertEqual(d.to, ["user+tag@example.com"])
        XCTAssertEqual(d.subject, "1+1=2")
    }

    func testEncodedAndUnicode() {
        let d = draft("mailto:%E5%BC%A0@example.com?subject=Caf%C3%A9%20%26%20cr%C3%A8me%20%F0%9F%8E%89&body=a%26b%3Dc%23d%3Fe%25")
        XCTAssertEqual(d.to, ["张@example.com"])
        XCTAssertEqual(d.subject, "Café & crème 🎉")
        XCTAssertEqual(d.body, "a&b=c#d?e%")
    }

    func testNewlines() {
        let d = draft("mailto:a@example.com?subject=one%0D%0Atwo&body=line%201%0D%0Aline%202%0Aline%203")
        XCTAssertEqual(d.subject, "one two")
        XCTAssertEqual(d.body, "line 1\nline 2\nline 3")
    }

    func testFirstSubjectAndBadEncoding() {
        let d = draft("mailto:a@example.com?subject=first&subject=second&body=100%&x-other=1")
        XCTAssertEqual(d.subject, "first")
        XCTAssertEqual(d.body, "100%")
    }

    func testFragmentAndEmptyAddresses() {
        let d = draft("mailto:,a@example.com,,?cc=#ignored")
        XCTAssertEqual(d.to, ["a@example.com"])
        XCTAssertEqual(d.cc, [])
    }

    func testControlCharactersDropAnAddress() {
        let d = draft("mailto:a@example.com%0D%0ABcc:evil@example.com")
        XCTAssertEqual(d.to, [])
    }

    func testRecipientCap() {
        let many = (0..<80).map { "p\($0)@example.com" }.joined(separator: ",")
        XCTAssertEqual(draft("mailto:" + many).to.count, MailDraft.maxRecipients)
    }

    func testGmail() {
        let url = Webmail.gmail.compose(draft("mailto:a@example.com,user+tag@example.com?cc=c@example.com&bcc=d@example.com&subject=Hi%20%26%20bye&body=x%3Dy%0D%0Anext%20line%20%2B%20%C3%A9"))
        XCTAssertTrue(url!.absoluteString.hasPrefix("https://mail.google.com/mail/?view=cm&fs=1&to="))
        let q = query(url)
        XCTAssertEqual(q["to"], "a@example.com,user+tag@example.com")
        XCTAssertEqual(q["cc"], "c@example.com")
        XCTAssertEqual(q["bcc"], "d@example.com")
        XCTAssertEqual(q["su"], "Hi & bye")
        XCTAssertEqual(q["body"], "x=y\nnext line + é")
        // A `+` in an address is %2B, so the server can't read it as a space.
        XCTAssertTrue(url!.absoluteString.contains("user%2Btag%40example.com"))
    }

    func testNoInjection() {
        // Values that try to end their parameter and start another.
        let url = Webmail.outlook.compose(MailDraft(to: ["a@example.com&cc=evil@example.com"], subject: "x&to=evil@example.com#frag", body: "?body=no"))
        let q = query(url)
        XCTAssertEqual(q.keys.sorted(), ["body", "subject", "to"])
        XCTAssertEqual(q["to"], "a@example.com&cc=evil@example.com")
        XCTAssertEqual(q["subject"], "x&to=evil@example.com#frag")
        XCTAssertEqual(q["body"], "?body=no")
        XCTAssertNil(url!.fragment)
    }

    func testOutlookAndFastmail() {
        let d = draft("mailto:a@example.com?subject=S&body=B")
        XCTAssertEqual(Webmail.outlook.compose(d)?.absoluteString, "https://outlook.live.com/mail/0/deeplink/compose?to=a%40example.com&subject=S&body=B")
        XCTAssertEqual(Webmail.fastmail.compose(d)?.absoluteString, "https://app.fastmail.com/mail/compose?to=a%40example.com&subject=S&body=B")
        XCTAssertEqual(Webmail.gmail.compose(MailDraft())?.absoluteString, "https://mail.google.com/mail/?view=cm&fs=1")
        XCTAssertNil(Webmail.none.compose(d))
    }

    func testProton() {
        let url = Webmail.proton.compose(draft("mailto:user+tag@example.com?cc=c@example.com&subject=Hi%20%26%20bye&body=a%0D%0Ab"))!
        XCTAssertTrue(url.absoluteString.hasPrefix("https://mail.proton.me/inbox#mailto=mailto%3A"))
        // Proton decodes the fragment once and reads a mailto: back.
        let inner = URLComponents(url: url, resolvingAgainstBaseURL: false)!.percentEncodedFragment!.dropFirst("mailto=".count).removingPercentEncoding!
        XCTAssertEqual(MailDraft(string: inner), MailDraft(to: ["user+tag@example.com"], cc: ["c@example.com"], subject: "Hi & bye", body: "a\nb"))
    }

    func testLengthCap() {
        let body = String(repeating: "é and more text ", count: 2000)
        for mail in [Webmail.gmail, .outlook, .fastmail, .proton] {
            let url = mail.compose(MailDraft(to: ["a@example.com"], subject: "S", body: body))!
            XCTAssertLessThanOrEqual(url.absoluteString.utf8.count, MailDraft.maxLength, mail.rawValue)
            XCTAssertGreaterThan(url.absoluteString.utf8.count, MailDraft.maxLength - 200, mail.rawValue)
        }
        // A short one is never cut.
        let short = Webmail.gmail.compose(MailDraft(body: "short"))!
        XCTAssertEqual(query(short)["body"], "short")
    }
}
