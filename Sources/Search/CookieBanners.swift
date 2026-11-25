import WebKit

// Cookie banners, refused for you, off unless turned on.
//
// Hiding a banner leaves the site's question unanswered: it asks again on
// the next page, and some sites hold the page still (no scroll, a grey
// veil) until it is answered. So where Search knows the banner's maker, a
// small script in the page's world gives the site's own "no": through the
// maker's public API where it has one, as the site itself would call it,
// or else with a click on the banner's own refuse button. The answer is the
// site's to keep, in its own cookie, and the banner goes as it would after
// your click. Five makers for now, each a few lines below: OneTrust,
// Didomi, Cookiebot, iubenda and Usercentrics. A banner from anyone else is
// left as it is, and so is one with no way to say no on its first screen
// unless its maker's API has one.
//
// Only no, never yes: no path in the script names a function or a button
// that agrees to anything, and its tests check the source for them. A
// refusal that would cost money ("Reject and subscribe for 2 €", a
// Pur-Abo, the pay-or-agree walls of some newspapers) is a subscription,
// not a no: the banner is left for you.
//
// Most of these load after the page, so the script looks again whenever the
// document changes and every quarter of a second, for ten seconds from the
// document's start, then stops for good. It answers at most once in a
// document. Only the main frame gets it: all five draw their banner in the
// page itself, and an ad-heavy page's frames would each run it for nothing.
//
// Private tabs get it too while the switch is on, and nothing while it is
// off, like every other tab. It isn't one of the signals a private tab
// always sends (GPC, click IDs): those change what a request says, this one
// acts on the page, and a switch that is off does nothing anywhere. With it
// on, a private tab is where it helps most, since its cookies, and so its
// last answer, go when it closes.
//
// Pausing Shield for a site (its card: click the tab you're on) pauses this
// there too, so a site it confuses has the same one way back. Shield off
// everywhere doesn't turn it off: the two are separate switches.
//
// Written for Search from each maker's public documentation of its API and
// banner; no code is taken from another blocker.
//
// What the page-world script can reach, for Security: only the page's own
// document, read through querySelector, checkVisibility, the size of an
// element and its text; the open shadow root of Usercentrics' banner; a
// click on one refuse button, an untrusted one, as the page's own click
// would be; and the documented globals of the five makers (window.OneTrust,
// window.didomiOnReady and the Didomi it hands over, window.Cookiebot,
// window.UC_UI), each read only once its banner is in the document, all of
// which the page's own scripts call themselves. It sets nothing on the page
// but one callback in didomiOnReady (making that array if the page has
// none), and only on a page with an element #didomi-host. A page can still
// tell it is there by laying a bait banner, as with any blocker that acts.
// It carries no handler, no message, no Search name or global, sends nothing
// anywhere and runs nothing it is given (no eval, no Function). A
// WKUserScript is injected by WebKit, so a page's CSP doesn't apply to it.
// Nothing in it is hidden: what a page can reach of it (the didomiOnReady
// callback) shows its source through toString().

/// Settings › Privacy › Refuse cookie banners, off unless turned on.
enum CookieBanners {
    /// What Settings says. Read as each document's scripts are put in
    /// (Tab.arm), so a switch moved reaches every tab from its next load.
    @MainActor static var on = false

    /// The script for the next document of a tab on `site` (its main
    /// frame's host, without www): none while off, or while Shield is paused
    /// there.
    @MainActor
    static func scripts(for site: String?) -> [WKUserScript] {
        guard on, !Shield.shared.isPaused(on: site) else { return [] }
        return [Armed.script(page, .atDocumentStart, mainFrameOnly: true, in: .page)]
    }

    /// In the page's own world, before any of its scripts.
    static let page = """
    (function () {
      'use strict';
      try {
        // Taken now, before the page runs: a page that wraps it later never
        // sees this script's calls.
        var wait = setTimeout;
        var done = false, waiting = false, left = 40, watch = null, didomi = null, askedDidomi = false;
        // Anything that says a refusal here would be paid for, in the
        // languages these banners most often speak.
        var paid = /[€£$¥₹]|\\babo\\b|ab+on+|sub?scri|assin|contentpass/i;

        // Drawn on the page: a banner on its way out, or a button of a panel
        // still closed, is never pressed.
        function visible(selector, root) {
          var e = (root || document).querySelector(selector);
          if (!e) return null;
          if (typeof e.checkVisibility === 'function') {
            return e.checkVisibility({ visibilityProperty: true, opacityProperty: true }) ? e : null;
          }
          return e.offsetWidth || e.offsetHeight || e.getClientRects().length ? e : null;
        }
        function there(selector) { return document.querySelector(selector); }
        function costs(button) { return paid.test(String(button.textContent)); }
        function callable(o, name) { return !!o && typeof o[name] === 'function'; }

        // Each maker: false while there is nothing to answer yet, true once
        // it has answered, or decided the banner is to be left alone.

        function oneTrust() {
          if (!visible('#onetrust-banner-sdk')) return false;
          var api = window.OneTrust;
          var button = visible('#onetrust-reject-all-handler') || visible('.ot-pc-refuse-all-handler');
          if (button && costs(button)) return true;
          if (callable(api, 'IsAlertBoxClosed') && callable(api, 'RejectAll')) {
            // Already answered: the banner is on its way out.
            if (api.IsAlertBoxClosed() === false) api.RejectAll();
            return true;
          }
          if (!button) return false;
          button.click();
          return true;
        }

        // Didomi hands itself to the callbacks in didomiOnReady once it is
        // ready, or at once if it already is; asked only on a page with its
        // banner, so no other page gets the array.
        function didomiNotice() {
          if (!there('#didomi-host')) return false;
          if (!askedDidomi) {
            askedDidomi = true;
            (window.didomiOnReady = window.didomiOnReady || []).push(function (api) { didomi = api; soon(); });
          }
          // Its refuse button is what says whether no is free here: a
          // pay-or-agree wall puts a subscription in its place.
          var button = visible('#didomi-notice-disagree-button') || visible('.didomi-continue-without-agreeing');
          if (!button) return false;
          if (costs(button)) return true;
          if (callable(didomi, 'shouldConsentBeCollected') && callable(didomi, 'setUserDisagreeToAll')) {
            if (didomi.shouldConsentBeCollected()) didomi.setUserDisagreeToAll();
          } else {
            button.click();
          }
          return true;
        }

        function cookiebot() {
          if (!visible('#CybotCookiebotDialog')) return false;
          var api = window.Cookiebot;
          if (!api || api.hasResponse !== false) return false;
          var button = visible('#CybotCookiebotDialogBodyLevelButtonLevelOptinDeclineAll') ||
                       visible('#CybotCookiebotDialogBodyButtonDecline');
          if (button) {
            if (!costs(button)) button.click();
            return true;
          }
          // No button on its first screen: its API says the same no.
          if (callable(api, 'withdraw')) {
            api.withdraw();
            if (callable(api, 'hide')) api.hide();
          }
          return true;
        }

        function iubenda() {
          var banner = visible('#iubenda-cs-banner');
          // No refuse button on its first screen: left alone, rather than
          // a walk through its settings.
          var button = banner && visible('.iubenda-cs-reject-btn', banner);
          if (!button) return false;
          if (!costs(button)) button.click();
          return true;
        }

        function usercentrics() {
          var root = there('#usercentrics-root'), ui = there('#usercentrics-cmp-ui');
          if (!root && !ui) return false;
          function inside(host, selector) {
            return host && ((host.shadowRoot && visible(selector, host.shadowRoot)) || visible(selector, host));
          }
          var button = inside(root, '[data-testid=uc-deny-all-button]') || inside(ui, '[data-action-type=deny]');
          if (button) {
            if (!costs(button)) button.click();
            return true;
          }
          // A banner out of reach (a closed shadow root): its API, once it
          // has started and only while it says it is waiting for an answer.
          var api = window.UC_UI;
          if (!callable(api, 'isConsentRequired') || !callable(api, 'denyAllConsents') ||
              (callable(api, 'isInitialized') && api.isInitialized() !== true) ||
              api.isConsentRequired() !== true) return false;
          Promise.resolve(api.denyAllConsents()).then(function () {
            if (callable(api, 'closeCMP')) api.closeCMP();
          }).catch(function () {});
          return true;
        }

        var makers = [oneTrust, didomiNotice, cookiebot, usercentrics, iubenda];

        function stop() {
          done = true;
          try { watch.disconnect(); } catch (e) {}
        }
        function look() {
          waiting = false;
          for (var i = 0; i < makers.length && !done; i++) {
            try { if (makers[i]()) stop(); } catch (e) {}
          }
        }
        function soon() {
          if (done || waiting) return;
          waiting = true;
          wait(look, 50);
        }
        function every() {
          look();
          if (!done && --left > 0) wait(every, 250); else stop();
        }
        wait(every, 250);
        watch = new MutationObserver(soon);
        watch.observe(document, { childList: true, subtree: true, attributes: true, attributeFilter: ['style', 'class', 'hidden'] });
      } catch (e) {}
    })();
    """
}
