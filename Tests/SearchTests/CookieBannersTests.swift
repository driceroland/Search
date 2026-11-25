import JavaScriptCore
import WebKit
import XCTest
@testable import Search

/// CookieBanners' page script run in JavaScriptCore over a stand-in page:
/// a document whose elements are looked up by the selector asked for, each
/// inside the one it was put in, a MutationObserver and timers run by hand,
/// and each maker's API as a stand-in that counts its calls. No page, no
/// network, nothing started.
@MainActor
final class CookieBannersTests: XCTestCase {
    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    /// The stand-in page before the script. `put(selector, text, inside)` puts a
    /// drawn element there, `hide(selector)` keeps it in the document undrawn,
    /// `pass(ms)` runs the timers due by then, and `changed()` tells the
    /// observers the document moved. Every element counts its clicks.
    private func context() -> JSContext {
        let context = JSContext()!
        context.exceptionHandler = { _, error in XCTFail("JS: \(error?.toString() ?? "?")") }
        context.evaluateScript("""
        var window = this;
        var now = 0, timers = [], observers = [];
        function setTimeout(f, ms) { timers.push({ f: f, at: now + (ms || 0) }); return timers.length; }
        function pass(ms) {
          var until = now + ms;
          for (;;) {
            timers.sort(function (a, b) { return a.at - b.at; });
            if (!timers.length || timers[0].at > until) break;
            var t = timers.shift(); now = t.at; t.f();
          }
          now = until;
        }
        function MutationObserver(f) { this.f = f; this.on = false; observers.push(this); }
        MutationObserver.prototype.observe = function () { this.on = true; };
        MutationObserver.prototype.disconnect = function () { this.on = false; };
        function changed() { observers.forEach(function (o) { if (o.on) o.f([]); }); }
        function watching() { return observers.some(function (o) { return o.on; }); }
        function El(text) { this.textContent = text || ''; this.offsetWidth = 100; this.offsetHeight = 20; this.clicks = 0; this.kids = {}; }
        El.prototype.click = function () { this.clicks++; if (this.onclick) this.onclick(); };
        El.prototype.getClientRects = function () { return this.offsetWidth ? [1] : []; };
        El.prototype.querySelector = function (s) { return this.kids[s] || null; };
        var page = {}, document = new El();
        function put(s, text, inside) {
          var e = new El(text);
          page[s] = e;
          (inside ? page[inside] : document).kids[s] = e;
          if (inside) document.kids[s] = e;
          return e;
        }
        function hide(s) { page[s].offsetWidth = 0; page[s].offsetHeight = 0; }
        function clicks(s) { return page[s] ? page[s].clicks : 0; }
        var calls = {};
        function spy(name, f) { return function () { calls[name] = (calls[name] || 0) + 1; return f ? f.apply(this, arguments) : undefined; }; }
        function count(name) { return calls[name] || 0; }
        """)
        return context
    }

    /// The page set up by `setup`, the script started, and `ms` gone by.
    private func page(_ setup: String, after ms: Int = 300) -> JSContext {
        let c = context()
        c.evaluateScript(setup)
        c.evaluateScript(CookieBanners.page)
        c.evaluateScript("pass(\(ms))")
        return c
    }

    private func number(_ c: JSContext, _ js: String) -> Int32 { c.evaluateScript(js)!.toInt32() }
    private func text(_ c: JSContext, _ js: String) -> String { c.evaluateScript(js)!.toString() }

    // What agreeing would take: never called, never clicked, in any test.
    private let yes = """
    count('AllowAll') + count('setUserAgreeToAll') + count('submitCustomConsent') + count('acceptAllConsents') +
    clicks('#onetrust-accept-btn-handler') + clicks('#didomi-notice-agree-button') +
    clicks('#CybotCookiebotDialogBodyLevelButtonLevelOptinAllowAll') + clicks('.iubenda-cs-accept-btn') +
    clicks('[data-testid=uc-accept-all-button]')
    """

    func testOneTrustIsRefusedThroughItsAPIOnce() {
        let c = page("""
        put('#onetrust-banner-sdk'); put('#onetrust-accept-btn-handler', 'Accept all'); put('#onetrust-reject-all-handler', 'Reject all');
        var closed = false;
        window.OneTrust = { IsAlertBoxClosed: function () { return closed; },
                            RejectAll: spy('RejectAll', function () { closed = true; hide('#onetrust-banner-sdk'); }),
                            AllowAll: spy('AllowAll') };
        """)
        XCTAssertEqual(number(c, "count('RejectAll')"), 1)
        XCTAssertEqual(number(c, "clicks('#onetrust-reject-all-handler')"), 0, "the API, not a click as well")
        c.evaluateScript("put('#onetrust-banner-sdk'); changed(); pass(20000)")
        XCTAssertEqual(number(c, "count('RejectAll')"), 1, "once in a document")
        XCTAssertEqual(number(c, yes), 0)
        XCTAssertFalse(c.evaluateScript("watching()")!.toBool())
    }

    func testOneTrustWithoutItsAPIGetsItsRefuseButtonClicked() {
        let c = page("put('#onetrust-banner-sdk'); put('#onetrust-accept-btn-handler', 'Accept'); put('#onetrust-reject-all-handler', 'Reject all');")
        XCTAssertEqual(number(c, "clicks('#onetrust-reject-all-handler')"), 1)
        let panel = page("put('#onetrust-banner-sdk'); put('.ot-pc-refuse-all-handler', 'Reject all');")
        XCTAssertEqual(number(panel, "clicks('.ot-pc-refuse-all-handler')"), 1)
        XCTAssertEqual(number(c, yes) + number(panel, yes), 0)
    }

    func testOneTrustAlreadyAnsweredIsLeftAlone() {
        let c = page("""
        put('#onetrust-banner-sdk'); put('#onetrust-reject-all-handler', 'Reject all');
        window.OneTrust = { IsAlertBoxClosed: function () { return true; }, RejectAll: spy('RejectAll') };
        """, after: 11000)
        XCTAssertEqual(number(c, "count('RejectAll') + clicks('#onetrust-reject-all-handler')"), 0)
    }

    func testDidomiIsRefusedThroughItsAPIOnceItIsReady() {
        // As Didomi's SDK does once it is ready: a push is called at once.
        let c = page("""
        put('#didomi-host'); put('#didomi-notice-agree-button', 'Accetta'); put('#didomi-notice-disagree-button', 'Rifiuta');
        var api = { shouldConsentBeCollected: function () { return true; },
                    setUserDisagreeToAll: spy('setUserDisagreeToAll'), setUserAgreeToAll: spy('setUserAgreeToAll') };
        window.didomiOnReady = { push: function (f) { f(api); } };
        """, after: 20000)
        XCTAssertEqual(number(c, "count('setUserDisagreeToAll')"), 1)
        XCTAssertEqual(number(c, "clicks('#didomi-notice-disagree-button')"), 0)
        XCTAssertEqual(number(c, yes), 0)
    }

    func testDidomiBeforeItIsReadyGetsItsButtonClicked() {
        let c = page("put('#didomi-host'); put('#didomi-notice-agree-button', 'Accetta'); put('.didomi-continue-without-agreeing', 'Continua senza accettare');")
        XCTAssertEqual(number(c, "clicks('.didomi-continue-without-agreeing')"), 1)
        XCTAssertEqual(number(c, yes), 0)
    }

    func testDidomiAskedOnceAndLeftAloneWhenNothingIsToBeCollected() {
        let waiting = page("put('#didomi-host');", after: 11000)
        XCTAssertEqual(number(waiting, "Array.isArray(window.didomiOnReady) && window.didomiOnReady.length"), 1,
                       "one callback queued, however often it looked")
        let answered = page("""
        put('#didomi-host'); put('#didomi-notice-disagree-button', 'Rifiuta');
        var api = { shouldConsentBeCollected: function () { return false; }, setUserDisagreeToAll: spy('setUserDisagreeToAll') };
        window.didomiOnReady = { push: function (f) { f(api); } };
        """, after: 11000)
        XCTAssertEqual(number(answered, "count('setUserDisagreeToAll') + clicks('#didomi-notice-disagree-button')"), 0)
    }

    func testAPaidRefusalIsNeverAnsweredByAnyMaker() {
        let banners = [
            "put('#didomi-host'); var b = put('#didomi-notice-disagree-button', T); window.didomiOnReady = { push: function (f) { f({ shouldConsentBeCollected: function () { return true; }, setUserDisagreeToAll: spy('no') }); } };",
            "put('#iubenda-cs-banner'); var b = put('.iubenda-cs-reject-btn', T, '#iubenda-cs-banner');",
            "put('#onetrust-banner-sdk'); var b = put('#onetrust-reject-all-handler', T); window.OneTrust = { IsAlertBoxClosed: function () { return false; }, RejectAll: spy('no') };",
            "put('#CybotCookiebotDialog'); var b = put('#CybotCookiebotDialogBodyButtonDecline', T); window.Cookiebot = { hasResponse: false, withdraw: spy('no') };",
            "var r = put('#usercentrics-root'), b = new El(T); r.shadowRoot = { querySelector: function () { return b; } }; window.UC_UI = { isConsentRequired: function () { return true; }, denyAllConsents: spy('no') };",
        ]
        let texts = ["Rifiuta e abbonati a 1 €", "Reject and subscribe", "Ablehnen mit Pur-Abo", "Refuser et s'abonner",
                     "Rechazar y suscribirse", "Decline: £1 a month", "Weiter mit contentpass"]
        for banner in banners {
            for t in texts {
                let c = context()
                c.setObject(t, forKeyedSubscript: "T" as NSString)
                c.evaluateScript(banner)
                c.evaluateScript(CookieBanners.page)
                c.evaluateScript("pass(11000)")
                XCTAssertEqual(number(c, "count('no') + b.clicks"), 0, "\(t) — \(banner.prefix(40))")
            }
        }
    }

    func testCookiebotClicksItsDeclineButtonAndNothingMore() {
        for id in ["#CybotCookiebotDialogBodyLevelButtonLevelOptinDeclineAll", "#CybotCookiebotDialogBodyButtonDecline"] {
            let c = page("""
            put('#CybotCookiebotDialog'); put('#CybotCookiebotDialogBodyLevelButtonLevelOptinAllowAll', 'Allow all');
            put('\(id)', 'Deny');
            window.Cookiebot = { hasResponse: false, declined: false, withdraw: spy('withdraw'), hide: spy('hide') };
            """)
            XCTAssertEqual(number(c, "clicks('\(id)')"), 1, id)
            XCTAssertEqual(number(c, "count('withdraw')"), 0, "a click, not the API as well")
            XCTAssertEqual(number(c, yes), 0)
        }
    }

    func testCookiebotWithoutAButtonSaysNoThroughItsAPI() {
        let c = page("put('#CybotCookiebotDialog'); window.Cookiebot = { hasResponse: false, withdraw: spy('withdraw'), hide: spy('hide') };")
        XCTAssertEqual(text(c, "count('withdraw') + ',' + count('hide')"), "1,1")
    }

    func testCookiebotAlreadyAnsweredOrWithoutItsDialogIsLeftAlone() {
        let answered = page("""
        put('#CybotCookiebotDialog'); put('#CybotCookiebotDialogBodyButtonDecline', 'Deny');
        window.Cookiebot = { hasResponse: true, withdraw: spy('withdraw') };
        """, after: 11000)
        XCTAssertEqual(number(answered, "count('withdraw') + clicks('#CybotCookiebotDialogBodyButtonDecline')"), 0)
        // Its global alone isn't read: no dialog, no look at it.
        let quiet = page("""
        var reads = 0;
        Object.defineProperty(window, 'Cookiebot', { get: function () { reads++; return { hasResponse: false, withdraw: spy('withdraw') }; } });
        """, after: 11000)
        XCTAssertEqual(number(quiet, "reads + count('withdraw')"), 0)
    }

    func testIubendaOnlyWithARefuseButtonInItsBanner() {
        let c = page("put('#iubenda-cs-banner'); put('.iubenda-cs-accept-btn', 'Accetta', '#iubenda-cs-banner'); put('.iubenda-cs-reject-btn', 'Rifiuta', '#iubenda-cs-banner');")
        XCTAssertEqual(number(c, "clicks('.iubenda-cs-reject-btn')"), 1)
        XCTAssertEqual(number(c, yes), 0)

        let without = page("put('#iubenda-cs-banner'); put('.iubenda-cs-accept-btn', 'Accetta', '#iubenda-cs-banner'); put('.iubenda-cs-customize-btn', 'Personalizza', '#iubenda-cs-banner');", after: 11000)
        XCTAssertEqual(number(without, "clicks('.iubenda-cs-customize-btn')") + number(without, yes), 0)
        // A button of that class elsewhere on the page isn't the banner's.
        let elsewhere = page("put('#iubenda-cs-banner'); put('.iubenda-cs-reject-btn', 'Rifiuta');", after: 11000)
        XCTAssertEqual(number(elsewhere, "clicks('.iubenda-cs-reject-btn')"), 0)
    }

    func testUsercentricsButtonsInItsShadowRootAndInItsNewBanner() {
        let c = page("""
        var root = put('#usercentrics-root'), deny = new El('Deny');
        root.shadowRoot = { querySelector: function (s) { return s === '[data-testid=uc-deny-all-button]' ? deny : null; } };
        window.UC_UI = { isConsentRequired: function () { return true; }, denyAllConsents: spy('denyAllConsents'), acceptAllConsents: spy('acceptAllConsents') };
        """)
        XCTAssertEqual(number(c, "deny.clicks"), 1)
        XCTAssertEqual(number(c, "count('denyAllConsents')"), 0, "the click, not the API as well")
        let v3 = page("put('#usercentrics-cmp-ui'); put('[data-action-type=deny]', 'Deny', '#usercentrics-cmp-ui');")
        XCTAssertEqual(number(v3, "clicks('[data-action-type=deny]')"), 1)
        XCTAssertEqual(number(c, yes) + number(v3, yes), 0)
    }

    func testUsercentricsOutOfReachThroughItsAPIOnlyWhileItWaits() {
        let c = page("""
        put('#usercentrics-cmp-ui');
        var accepted = null;
        window.UC_UI = { isInitialized: function () { return true; }, isConsentRequired: function () { return accepted === null; },
                         denyAllConsents: spy('denyAllConsents', function () { accepted = false; return Promise.resolve(); }),
                         closeCMP: spy('closeCMP'), areAllConsentsAccepted: function () { return accepted === true; },
                         acceptAllConsents: spy('acceptAllConsents') };
        """)
        XCTAssertEqual(text(c, "count('denyAllConsents') + ',' + count('closeCMP')"), "1,1")
        XCTAssertTrue(c.evaluateScript("UC_UI.areAllConsentsAccepted() === false")!.toBool())
        XCTAssertEqual(number(c, yes), 0)

        let plain = page("put('#usercentrics-root'); window.UC_UI = { isConsentRequired: function () { return true; }, denyAllConsents: spy('denyAllConsents'), closeCMP: spy('closeCMP') };")
        XCTAssertEqual(text(plain, "count('denyAllConsents') + ',' + count('closeCMP')"), "1,1", "an answer that isn't a promise")

        let starting = page("put('#usercentrics-root'); window.UC_UI = { isInitialized: function () { return false; }, isConsentRequired: function () { return true; }, denyAllConsents: spy('denyAllConsents') };", after: 11000)
        let answered = page("put('#usercentrics-root'); window.UC_UI = { isConsentRequired: function () { return false; }, denyAllConsents: spy('denyAllConsents') };", after: 11000)
        XCTAssertEqual(number(starting, "count('denyAllConsents')") + number(answered, "count('denyAllConsents')"), 0)
    }

    func testABannerThatComesLaterIsWaitedForTenSecondsAndNoMore() {
        let c = page("", after: 3000)
        c.evaluateScript("put('#iubenda-cs-banner'); put('.iubenda-cs-reject-btn', 'Rifiuta', '#iubenda-cs-banner'); changed(); pass(100)")
        XCTAssertEqual(number(c, "clicks('.iubenda-cs-reject-btn')"), 1, "seen as the document changed")

        let late = page("", after: 10500)
        late.evaluateScript("put('#iubenda-cs-banner'); put('.iubenda-cs-reject-btn', 'Rifiuta', '#iubenda-cs-banner'); changed(); pass(5000)")
        XCTAssertEqual(number(late, "clicks('.iubenda-cs-reject-btn')"), 0)
        XCTAssertEqual(number(late, "timers.length"), 0, "nothing left running")
        XCTAssertFalse(late.evaluateScript("watching()")!.toBool())
    }

    func testAnUndrawnBannerOrButtonIsNeverPressed() {
        let banner = page("put('#onetrust-banner-sdk'); put('#onetrust-reject-all-handler', 'Reject all'); hide('#onetrust-banner-sdk');", after: 11000)
        XCTAssertEqual(number(banner, "clicks('#onetrust-reject-all-handler')"), 0)
        let button = page("put('#didomi-host'); put('#didomi-notice-disagree-button', 'Rifiuta'); hide('#didomi-notice-disagree-button');", after: 11000)
        XCTAssertEqual(number(button, "clicks('#didomi-notice-disagree-button')"), 0)
        // Where WebKit can say so, one still there but fading out isn't drawn.
        let fading = page("""
        put('#iubenda-cs-banner').checkVisibility = function () { return false; };
        put('.iubenda-cs-reject-btn', 'Rifiuta', '#iubenda-cs-banner');
        """, after: 11000)
        XCTAssertEqual(number(fading, "clicks('.iubenda-cs-reject-btn')"), 0)
    }

    func testAMakerThatChangedLeavesThePageAsItWas() {
        // An API that throws: no error reaches the page, and the next maker
        // is still looked at.
        let c = page("""
        put('#onetrust-banner-sdk');
        window.OneTrust = { IsAlertBoxClosed: function () { throw new Error('changed'); }, RejectAll: spy('RejectAll') };
        put('#iubenda-cs-banner'); put('.iubenda-cs-reject-btn', 'Rifiuta', '#iubenda-cs-banner');
        """)
        XCTAssertEqual(number(c, "count('RejectAll')"), 0)
        XCTAssertEqual(number(c, "clicks('.iubenda-cs-reject-btn')"), 1)
    }

    func testNoBannerNothingTouchedAndNoNameLeftBehind() {
        let c = context()
        let names = "Object.getOwnPropertyNames(this)"
        let before = Set(c.evaluateScript(names)!.toArray().compactMap { $0 as? String })
        c.evaluateScript(CookieBanners.page)
        c.evaluateScript("pass(11000)")
        let after = Set(c.evaluateScript(names)!.toArray().compactMap { $0 as? String })
        XCTAssertEqual(after, before, "not even didomiOnReady, on a page without Didomi")
        XCTAssertEqual(number(c, "timers.length"), 0)
        XCTAssertFalse(c.evaluateScript("watching()")!.toBool())
    }

    func testTheSourceNamesNoWayToAgreeAndReachesNothingElse() {
        let source = CookieBanners.page.lowercased()
        for name in ["allowall", "setuseragreetoall", "acceptall", "accept-btn", "accept-all", "notice-agree-button",
                     "submitcustomconsent", "optinallow", "webkit", "search"] {
            XCTAssertFalse(source.contains(name), name)
        }
        for bad in [#"\bFunction\s*\("#, #"\beval\s*\("#, "postMessage", "addEventListener", "fetch", "XMLHttpRequest",
                    "sendBeacon", "document.cookie", "localStorage", "sessionStorage", "indexedDB"] {
            XCTAssertNil(CookieBanners.page.range(of: bad, options: .regularExpression), bad)
        }
    }

    func testScriptFollowsTheSwitchAndShieldsPause() {
        let shield = Shield.shared
        let was = CookieBanners.on, paused = shield.isPaused(on: "example.com")
        defer { CookieBanners.on = was; shield.pause("example.com", paused) }
        shield.pause("example.com", false)
        CookieBanners.on = false
        XCTAssertEqual(CookieBanners.scripts(for: "example.com").count, 0)
        CookieBanners.on = true
        XCTAssertEqual(CookieBanners.scripts(for: "example.com").count, 1)
        XCTAssertEqual(CookieBanners.scripts(for: "example.com").first?.isForMainFrameOnly, true)
        XCTAssertEqual(CookieBanners.scripts(for: nil).count, 1)
        shield.pause("example.com", true)
        XCTAssertEqual(CookieBanners.scripts(for: "example.com").count, 0)
        XCTAssertEqual(CookieBanners.scripts(for: "example.org").count, 1)
    }

    func testSettingIsListed() {
        XCTAssertNotNil(SettingsIndex.item("privacy.cookieBanners"))
    }
}
