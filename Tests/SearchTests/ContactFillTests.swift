import AppKit
import Contacts
import Foundation
import WebKit
import XCTest
@testable import Search

/// Your card in Contacts under a form's boxes: which boxes are offered it
/// and as what, what a pick puts where, and the rows a card makes.
/// Forms.script in Search's own world, as a tab runs it; no window, no
/// network, and a made-up card, never the Mac's own.
@MainActor
final class ContactFillTests: XCTestCase {
    private var holding: [NSObject] = []

    override class func setUp() {
        setenv("SEARCH_PROBE", "contact-fill-\(getpid())", 1)
        super.setUp()
    }

    override func setUp() async throws {
        try await super.setUp()
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
    }

    override func tearDown() async throws {
        holding = []
        try await super.tearDown()
    }

    private static let card: [String: String] = [
        "name": "Ada Lovelace", "given-name": "Ada", "family-name": "Lovelace", "organization": "Engines Ltd",
        "email": "ada@example.test", "tel": "+44 20 7946 0000",
        "street-address": "12 St James's Square\nFlat 3", "address-line1": "12 St James's Square", "address-line2": "Flat 3",
        "address-level2": "London", "address-level1": "Greater London", "postal-code": "SW1Y 4JH",
        "country": "GB", "country-name": "United Kingdom",
    ]

    private static let checkout = """
    <form id="ship">
      <input id="full" autocomplete="shipping name">
      <input id="mail" type="email" autocomplete="email">
      <input id="phone" autocomplete="shipping tel">
      <input id="line1" autocomplete="shipping address-line1">
      <input id="line2" autocomplete="shipping address-line2">
      <input id="city" autocomplete="shipping address-level2">
      <input id="zip" autocomplete="shipping postal-code">
      <select id="country" autocomplete="shipping country">
        <option value="">Choose…</option><option value="FR">France</option><option value="GB">United Kingdom</option>
      </select>
      <input id="hidden" name="email_confirm" autocomplete="email" style="opacity:0">
      <input id="gone" autocomplete="tel" style="position:absolute;left:-9999px">
    </form>
    """

    func testABoxTheCheckoutMarksIsOfferedTheCard() async throws {
        let web = try await page(Self.checkout)
        for (id, kind) in [("full", "name"), ("mail", "email"), ("phone", "tel"), ("line1", "address-line1"), ("zip", "postal-code")] {
            let got = try await call(web, "return window.__officeForms.contactVerdict(document.getElementById('\(id)'));") as? String
            XCTAssertEqual(got, kind, "#\(id)")
        }
        let hidden = try await call(web, "return window.__officeForms.contactVerdict(document.getElementById('hidden'));")
        XCTAssertNil(hidden, "a box you can't see is never offered")
    }

    func testAPickFillsTheFormsEmptyBoxesYouCanSee() async throws {
        let web = try await page(Self.checkout)
        _ = try await call(web, "document.getElementById('zip').value = 'typed'; document.getElementById('full').focus(); return true;")
        let filled = try await call(web, "return window.__officeForms.contact(\(Self.json(Self.card)));") as? Int
        XCTAssertEqual(filled, 7)
        let got = try await call(web, """
        var out = {};
        ['full', 'mail', 'phone', 'line1', 'line2', 'city', 'zip', 'country', 'hidden', 'gone'].forEach(function (id) {
          out[id] = document.getElementById(id).value;
        });
        return out;
        """) as? [String: String]
        XCTAssertEqual(got?["full"], "Ada Lovelace")
        XCTAssertEqual(got?["mail"], "ada@example.test")
        XCTAssertEqual(got?["phone"], "+44 20 7946 0000")
        XCTAssertEqual(got?["line1"], "12 St James's Square")
        XCTAssertEqual(got?["line2"], "Flat 3")
        XCTAssertEqual(got?["city"], "London")
        XCTAssertEqual(got?["zip"], "typed", "what you typed is kept")
        XCTAssertEqual(got?["country"], "GB", "the list's option for the card's country")
        XCTAssertEqual(got?["hidden"], "", "an invisible box gets nothing")
        XCTAssertEqual(got?["gone"], "", "a box off the page gets nothing")
    }

    /// No autocomplete, or "off": the labels say what each box is.
    func testAFormReadByItsLabels() async throws {
        let web = try await page("""
        <form>
          <label for="a">First name</label><input id="a" name="fname" autocomplete="off">
          <label for="b">Last name</label><input id="b" name="lname" autocomplete="off">
          <label for="c">E-mail address</label><input id="c" name="user[email]">
          <label for="d">Street address</label><textarea id="d" name="street"></textarea>
          <label for="e">Code postal</label><input id="e" name="cp">
          <label for="f">Ville</label><input id="f" name="v">
          <label for="g">Country</label><input id="g" name="pays">
        </form>
        """)
        var kinds: [String: String] = [:]
        for id in ["a", "b", "c", "d", "e", "f", "g"] {
            kinds[id] = try await call(web, "return window.__officeForms.contactVerdict(document.getElementById('\(id)'));") as? String
        }
        XCTAssertEqual(kinds, ["a": "given-name", "b": "family-name", "c": "email", "d": "address-line1",
                               "e": "postal-code", "f": "address-level2", "g": "country"])
        _ = try await call(web, "document.getElementById('a').focus(); return true;")
        _ = try await call(web, "return window.__officeForms.contact(\(Self.json(Self.card)));")
        let street = try await call(web, "return document.getElementById('d').value;") as? String
        XCTAssertEqual(street, "12 St James's Square")
        let country = try await call(web, "return document.getElementById('g').value;") as? String
        XCTAssertEqual(country, "United Kingdom", "a box to type in gets the country's name")
    }

    /// "Name" alone is a project's or a repository's as often as yours.
    func testBoxesThatAreNotYoursAreLeftAlone() async throws {
        let web = try await page("""
        <form><label for="p">Project name</label><input id="p" name="name"><textarea name="description"></textarea></form>
        <form><label for="n">Name</label><input id="n" name="name"><label for="o">Organization</label><input id="o" name="org"></form>
        <form><input id="u" name="username" placeholder="Username"><input type="password"></form>
        <form role="search"><input id="s" name="q" placeholder="Search"></form>
        <form><input id="cc" autocomplete="cc-name" placeholder="Name on card"><input autocomplete="cc-number"></form>
        <form><label for="t">Title</label><input id="t" name="title"><label for="m">Message</label><textarea id="m" name="message"></textarea></form>
        """)
        for id in ["p", "n", "u", "s", "cc", "t", "m"] {
            let got = try await call(web, "return window.__officeForms.contactVerdict(document.getElementById('\(id)'));")
            XCTAssertNil(got, "#\(id) is not offered your card")
        }
    }

    /// The caret going straight from one form's box to the next form's says
    /// it left the first: a pick in one form held the list back from every
    /// form after it on the page.
    func testGoingToAnotherFormSaysTheFirstBoxWasLeft() async throws {
        let heard = Heard()
        let web = try await page("""
        <form><input id="a" autocomplete="name"><input autocomplete="email"></form>
        <form><input id="b" autocomplete="name"><input autocomplete="email"></form>
        """, relay: heard)
        _ = try await call(web, "document.getElementById('a').focus(); return true;")
        try await Task.sleep(for: .milliseconds(100))
        heard.focus = []
        _ = try await call(web, "document.getElementById('b').focus(); return true;")
        try await Task.sleep(for: .milliseconds(200))
        let said = heard.focus.map { $0["rect"] is [String: Any] ? "box" : "left" }
        XCTAssertEqual(Array(said.prefix(2)), ["left", "box"], "left, then the new box: \(said)")
        XCTAssertEqual(heard.focus.dropFirst().first?["contact"] as? String, "name")
    }

    /// A shift-click: the box with the caret alone, the rest of the form
    /// left as it is.
    func testAShiftClickFillsTheBoxAlone() async throws {
        let web = try await page(Self.checkout)
        _ = try await call(web, "document.getElementById('city').focus(); return true;")
        let filled = try await call(web, "return window.__officeForms.contact(\(Self.json(Self.card)), true);") as? Int
        XCTAssertEqual(filled, 1)
        let got = try await call(web, "return ['full', 'mail', 'city', 'zip', 'country'].map(function (id) { return document.getElementById(id).value; });") as? [String]
        XCTAssertEqual(got, ["", "", "London", "", ""])
    }

    /// With Fill in your contact details off, the page's boxes aren't
    /// looked at for your card, and nothing hangs from them.
    func testWithTheSettingOffNoBoxIsLookedAt() async throws {
        let heard = Heard()
        let web = try await page(#"<form><input id="a" autocomplete="name"><input autocomplete="email"></form>"#,
                                 relay: heard, contacts: false)
        _ = try await call(web, "document.getElementById('a').focus(); return true;")
        try await Task.sleep(for: .milliseconds(150))
        let last = try XCTUnwrap(heard.focus.last)
        XCTAssertTrue(last["contact"] is NSNull || last["contact"] == nil, "no kind: \(last)")
        XCTAssertFalse(last["rect"] is [String: Any], "nothing hangs from it")
    }

    /// From one box to the next of the same form, a sign-in's name to its
    /// password or a name to an email, the list isn't said to have left: a
    /// pick in that form keeps it away from the boxes it just filled.
    func testWithinOneFormTheListIsNotSaidToHaveLeft() async throws {
        let heard = Heard()
        let web = try await page("""
        <form><input id="u" name="username" autocomplete="username"><input id="p" type="password"></form>
        <form><input id="a" autocomplete="name"><input id="b" autocomplete="email"></form>
        """, relay: heard)
        for (from, to) in [("u", "p"), ("a", "b")] {
            _ = try await call(web, "document.getElementById('\(from)').focus(); return true;")
            try await Task.sleep(for: .milliseconds(100))
            heard.focus = []
            _ = try await call(web, "document.getElementById('\(to)').focus(); return true;")
            try await Task.sleep(for: .milliseconds(200))
            let said = heard.focus.map { $0["rect"] is [String: Any] ? "box" : "left" }
            XCTAssertEqual(said.first, "box", "\(from) to \(to): straight to the next box, \(said)")
        }
    }

    /// A pick fills the box it was offered under, or nothing: the caret
    /// moved to another box since, the list's number for it no longer fits.
    func testAPickForAnotherBoxFillsNothing() async throws {
        let heard = Heard()
        let web = try await page(#"<form><input id="a" autocomplete="name"><input id="b" autocomplete="email"></form>"#, relay: heard)
        _ = try await call(web, "document.getElementById('a').focus(); return true;")
        try await Task.sleep(for: .milliseconds(150))
        let box = try XCTUnwrap(heard.focus.last?["box"] as? Int)
        _ = try await call(web, "document.getElementById('b').focus(); return true;")
        let stale = try await call(web, "return window.__officeForms.contact(\(Self.json(Self.card)), false, \(box));") as? Int
        XCTAssertEqual(stale, 0)
        _ = try await call(web, "document.getElementById('a').focus(); return true;")
        let fresh = try await call(web, "return window.__officeForms.contact(\(Self.json(Self.card)), false, \(box));") as? Int
        XCTAssertEqual(fresh, 2)
    }

    /// Boxes a form hides to catch robots, or keeps for a later step, get
    /// none of your details: clipped away, faded out, out of the way of
    /// keys, hidden from screen readers, or under something else.
    func testHiddenBoxesAreNotFilled() async throws {
        let web = try await page("""
        <form style="position:relative">
          <input id="mail" type="email" autocomplete="email">
          <div style="height:0;overflow:hidden"><input id="tel" autocomplete="tel"></div>
          <input id="line1" autocomplete="address-line1" tabindex="-1">
          <div aria-hidden="true"><input id="zip" autocomplete="postal-code"></div>
          <input id="city" autocomplete="address-level2" style="opacity:0.01">
          <input id="full" autocomplete="name" style="clip-path:inset(50%)">
          <input id="org" autocomplete="organization">
          <div style="position:absolute;inset:0;background:white"></div>
        </form>
        """)
        _ = try await call(web, "document.getElementById('mail').focus(); return true;")
        let filled = try await call(web, "return window.__officeForms.contact(\(Self.json(Self.card)));") as? Int
        XCTAssertEqual(filled, 1, "the box with the caret only")
        let got = try await call(web, "return ['mail', 'tel', 'line1', 'zip', 'city', 'full', 'org'].map(function (id) { return document.getElementById(id).value; });") as? [String]
        XCTAssertEqual(got, ["ada@example.test", "", "", "", "", "", ""])
    }

    /// Far down a long form, after its hidden boxes and its ticks, the box
    /// the caret is in is filled, and the boxes around it.
    func testTheBoxPickedUnderIsFilledInALongForm() async throws {
        let filler = (0..<120).map { "<input type=\"hidden\" name=\"h\($0)\">" }.joined()
            + (0..<30).map { "<input type=\"radio\" name=\"r\" value=\"\($0)\">" }.joined()
        let web = try await page("""
        <form>\(filler)<input id="full" name="full_name"><input id="mail" type="email" name="email"></form>
        """)
        _ = try await call(web, "document.getElementById('mail').focus(); return true;")
        let filled = try await call(web, "return window.__officeForms.contact(\(Self.json(Self.card)));") as? Int
        XCTAssertEqual(filled, 2)
        let got = try await call(web, "return [document.getElementById('full').value, document.getElementById('mail').value];") as? [String]
        XCTAssertEqual(got, ["Ada Lovelace", "ada@example.test"])
    }

    /// A checkout with an address to ship to and one to bill: a pick in one
    /// fills that one, and the boxes of neither (the email).
    func testShippingAndBillingAreFilledApart() async throws {
        let web = try await page("""
        <form>
          <input id="mail" type="email" autocomplete="email">
          <input id="s-name" autocomplete="shipping name"><input id="s-city" autocomplete="shipping address-level2">
          <input id="b-name" name="billing_name" placeholder="Billing name"><input id="b-city" name="billing_city" placeholder="Billing city">
        </form>
        """)
        _ = try await call(web, "document.getElementById('s-name').focus(); return true;")
        _ = try await call(web, "return window.__officeForms.contact(\(Self.json(Self.card)));")
        let got = try await call(web, "return ['mail', 's-name', 's-city', 'b-name', 'b-city'].map(function (id) { return document.getElementById(id).value; });") as? [String]
        XCTAssertEqual(got, ["ada@example.test", "Ada Lovelace", "London", "", ""])
    }

    /// A number split over boxes, a fax's, and boxes too short for what
    /// the card holds.
    func testPartsOfANumberAndShortBoxes() async throws {
        let web = try await page("""
        <form>
          <input id="area" autocomplete="tel-area-code" maxlength="3"><input id="fax" autocomplete="fax tel">
          <input id="national" autocomplete="tel-national"><input id="zip" autocomplete="postal-code" maxlength="5">
          <input id="full" autocomplete="name" maxlength="3"><input id="mail" type="email" autocomplete="email">
        </form>
        """)
        for id in ["area", "fax"] {
            let got = try await call(web, "return window.__officeForms.contactVerdict(document.getElementById('\(id)'));")
            XCTAssertNil(got, "#\(id) takes no whole phone number")
        }
        var card = Self.card
        card["tel-national"] = "20 7946 0000"
        card["postal-code"] = "94103-1234"
        _ = try await call(web, "document.getElementById('mail').focus(); return true;")
        _ = try await call(web, "return window.__officeForms.contact(\(Self.json(card)));")
        let got = try await call(web, "return ['area', 'fax', 'national', 'zip', 'full', 'mail'].map(function (id) { return document.getElementById(id).value; });") as? [String]
        XCTAssertEqual(got, ["", "", "20 7946 0000", "94103", "", "ada@example.test"], "a ZIP+4 cut to its five, a name never cut")
    }

    /// A list showing its first option, a real country and not a "Choose…",
    /// is still waiting for an answer; so is one whose empty choice isn't
    /// first.
    func testListsWithoutAPlaceholderFirstAreFilled() async throws {
        let web = try await page("""
        <form>
          <input id="mail" type="email" autocomplete="email">
          <select id="first" autocomplete="country"><option value="FR">France</option><option value="GB">United Kingdom</option></select>
          <select id="later" autocomplete="address-level1"><option value="Kent">Kent</option><option value="" selected>Choose</option><option value="Greater London">Greater London</option></select>
        </form>
        """)
        _ = try await call(web, "document.getElementById('mail').focus(); return true;")
        _ = try await call(web, "return window.__officeForms.contact(\(Self.json(Self.card)));")
        let got = try await call(web, "return [document.getElementById('first').value, document.getElementById('later').value];") as? [String]
        XCTAssertEqual(got, ["GB", "Greater London"])
    }

    /// Words that look like yours and aren't: a voicemail box isn't an
    /// email's, and a "Name" beside a "Region" is a new server's.
    func testLookAlikesAreNotOffered() async throws {
        let web = try await page("""
        <form><label for="v">Voicemail PIN</label><input id="v" name="voicemail"><input id="vn" name="full_name"></form>
        <form><label for="s">Name</label><input id="s" name="name"><label for="r">Region</label><select id="r" name="region"><option>eu-west-1</option></select></form>
        <form><label for="f">Your friend's email</label><input id="f" name="friend_email"><input name="your_name"></form>
        """)
        let voicemail = try await call(web, "return window.__officeForms.contactVerdict(document.getElementById('v'));") as? String
        XCTAssertNotEqual(voicemail, "email")
        for id in ["s", "f"] {
            let got = try await call(web, "return window.__officeForms.contactVerdict(document.getElementById('\(id)'));")
            XCTAssertNil(got, "#\(id) is not offered your card")
        }
    }

    /// What a pick hands a real tab goes over as arguments, quotes and all,
    /// and only to the origin it was offered on: another port gets nothing.
    func testAPickGoesToItsOwnOriginAlone() async throws {
        let browser = Browser(record: WindowRecord())
        browser.newTab()
        let tab = try XCTUnwrap(browser.tabs.last)
        tab.web.frame = NSRect(x: 0, y: 0, width: 1200, height: 900)
        tab.web.loadHTMLString(#"<!doctype html><form><input id="a" autocomplete="name"></form>"#,
                               baseURL: URL(string: "https://shop.example.test:8443/checkout"))
        for _ in 0..<500 {
            if (try? await call(tab.web, "return !!window.__officeForms")) as? Bool == true { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        _ = try await call(tab.web, "document.getElementById('a').focus(); return true;")
        func pick(_ name: String, on page: String) async -> Bool {
            await withCheckedContinuation { done in
                tab.fillContact(["name": name], onlyOn: URL(string: page)) { done.resume(returning: $0) }
            }
        }
        let value = "return document.getElementById('a').value;"

        let elsewhere = await pick("Ada", on: "https://shop.example.test:9443/checkout")
        XCTAssertFalse(elsewhere, "another port is another origin")
        let untouched = try await call(tab.web, value) as? String
        XCTAssertEqual(untouched, "")

        let name = #"Ada "`${1+1}`" \ Lovelace"#
        let here = await pick(name, on: "https://shop.example.test:8443/checkout")
        XCTAssertTrue(here)
        let filled = try await call(tab.web, value) as? String
        XCTAssertEqual(filled, name, "taken as it is, not as script")
    }

    /// A flash is an animation of each box, a beat after the one before,
    /// and writes nothing into the box's own style. Without a colour, none.
    func testTheFlashRunsDownTheFormAndLeavesNoStyle() async throws {
        let form = #"<form><input id="a" autocomplete="name" style="background-color: rgb(1, 2, 3)"><input id="b" type="email" autocomplete="email"></form>"#
        let delays = """
        return ['a', 'b'].map(function (id) {
          var all = document.getElementById(id).getAnimations();
          return all.length ? all[0].effect.getTiming().delay : -1;
        });
        """
        let web = try await page(form)
        _ = try await call(web, "document.getElementById('a').focus(); return true;")
        _ = try await call(web, "return window.__officeForms.contact(\(Self.json(Self.card)), false, null, 'rgba(10, 20, 30, 0.5)');")
        let flashed = try await call(web, delays) as? [Double]
        XCTAssertEqual(flashed, [0, 30], "each box a beat after the one before")
        let style = try await call(web, "return [document.getElementById('a').getAttribute('style'), document.getElementById('b').getAttribute('style')];") as? [Any]
        XCTAssertEqual(style?.first as? String, "background-color: rgb(1, 2, 3)", "the box's own style untouched")
        XCTAssertTrue(style?.last is NSNull, "nothing written into a box that had no style")

        let plain = try await page(form)
        _ = try await call(plain, "document.getElementById('a').focus(); return true;")
        _ = try await call(plain, "return window.__officeForms.contact(\(Self.json(Self.card)));")
        let still = try await call(plain, delays) as? [Double]
        XCTAssertEqual(still, [-1, -1], "no colour, no flash")
    }

    /// A pick is checked against the page's origin as the page gives it.
    func testAnOriginIsTheOneThePageGives() {
        XCTAssertEqual(Tab.origin(of: URL(string: "https://Shop.Example.test/checkout?x=1")), "https://shop.example.test")
        XCTAssertEqual(Tab.origin(of: URL(string: "https://shop.example.test:443/")), "https://shop.example.test")
        XCTAssertEqual(Tab.origin(of: URL(string: "https://shop.example.test:8443/")), "https://shop.example.test:8443")
        XCTAssertEqual(Tab.origin(of: URL(string: "http://127.0.0.1:8765/")), "http://127.0.0.1:8765")
        XCTAssertNotEqual(Tab.origin(of: URL(string: "https://www.example.test/")), Tab.origin(of: URL(string: "https://example.test/")))
        XCTAssertNil(Tab.origin(of: URL(string: "about:blank")))
    }

    func testTheRowsFollowTheBox() {
        let card = CNMutableContact()
        card.givenName = "Ada"
        card.familyName = "Lovelace"
        card.emailAddresses = [CNLabeledValue(label: CNLabelHome, value: "ada@example.test"),
                               CNLabeledValue(label: CNLabelWork, value: "ada@engines.test")]
        card.phoneNumbers = [CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: "+44 20 7946 0000"))]
        let home = CNMutablePostalAddress()
        home.street = "12 St James's Square\nFlat 3"
        home.city = "London"
        home.postalCode = "SW1Y 4JH"
        home.country = "United Kingdom"
        home.isoCountryCode = "gb"
        card.postalAddresses = [CNLabeledValue(label: CNLabelHome, value: home)]

        let emails = MeCard.offers(from: card, for: "email")
        XCTAssertEqual(emails.map(\.title), ["ada@example.test", "ada@engines.test"], "a row per email")
        XCTAssertEqual(emails.first?.fields["postal-code"], "SW1Y 4JH", "the rest of the card comes with it")

        let street = MeCard.offers(from: card, for: "address-line1")
        XCTAssertEqual(street.map(\.title), ["12 St James's Square"])
        XCTAssertEqual(street.first?.fields["address-line2"], "Flat 3")
        XCTAssertEqual(street.first?.fields["country"], "GB")

        let names = MeCard.offers(from: card, for: "name")
        XCTAssertEqual(names.first?.title, "Ada Lovelace")
        XCTAssertNil(names.first?.fields["organization"], "nothing empty is sent")

        XCTAssertTrue(MeCard.offers(from: CNMutableContact(), for: "email").isEmpty, "no email, no row")

        let phones = MeCard.offers(from: card, for: "tel")
        XCTAssertEqual(phones.map(\.title), ["+44 20 7946 0000"])
        XCTAssertEqual(phones.first?.detail, "Ada Lovelace · Mobile")
        XCTAssertEqual(MeCard.offers(from: card, for: "tel-national").first?.title, "20 7946 0000", "without the country's code")
        XCTAssertEqual(MeCard.offers(from: card, for: "country").first?.title, "United Kingdom", "a country by its name")
        XCTAssertEqual(MeCard.offers(from: card, for: "street-address").first?.title, "12 St James's Square, Flat 3")

        let nowhere = CNMutableContact()
        nowhere.givenName = "Ada"
        nowhere.emailAddresses = [CNLabeledValue(label: CNLabelHome, value: "ada@example.test")]
        let lone = MeCard.offers(from: nowhere, for: "name")
        XCTAssertEqual(lone.map(\.title), ["Ada"], "a name with no address: one row")
        XCTAssertEqual(lone.first?.detail, "ada@example.test")
    }

    // MARK: -

    private static func json(_ object: [String: String]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// `contacts`: Fill in your contact details on, as Tab says it to a page.
    private func page(_ body: String, relay: (NSObject & WKScriptMessageHandler)? = nil,
                      contacts: Bool = true) async throws -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let quiet = relay ?? Quiet()
        configuration.userContentController.add(quiet, contentWorld: Web.world, name: FormRelay.name)
        configuration.userContentController.addUserScript(
            WKUserScript(source: FormRelay.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: Web.world))
        if contacts {
            configuration.userContentController.addUserScript(
                WKUserScript(source: FormRelay.contactsOn, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: Web.world))
        }
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1200, height: 900), configuration: configuration)
        let loaded = Loaded()
        holding += [loaded, quiet, web]
        web.navigationDelegate = loaded
        web.loadHTMLString("<!doctype html><meta charset=utf-8><body>\(body)</body>", baseURL: URL(string: "https://shop.example.test/checkout"))
        try await loaded.wait()
        return web
    }

    private func call(_ web: WKWebView, _ body: String, inPage: Bool = false) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            web.callAsyncJavaScript(body, arguments: [:], in: nil, in: inPage ? .page : Web.world) { (result: Result<Any, Error>) in
                continuation.resume(with: result.map { $0 is NSNull ? nil : $0 })
            }
        }
    }

    private final class Quiet: NSObject, WKScriptMessageHandler {
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {}
    }

    /// What the page said about the caret, in order.
    private final class Heard: NSObject, WKScriptMessageHandler {
        var focus: [[String: Any]] = []
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], body["kind"] as? String == "focus" else { return }
            focus.append(body)
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
