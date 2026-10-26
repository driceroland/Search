import WebKit

// What the page says about itself that a browser has to know: where the
// keyboard is, whether it is about to take the screen, and whether there is a
// sign-in on it — and when one has just been sent, so the password can be
// offered a place in the keychain.
//
// Filling goes through the field's own setter and fires the events a keystroke
// would. Assigning to .value behind a framework's back leaves it thinking the
// box is still empty, which is a sign-in button that stays grey.

final class FormRelay: NSObject, WKScriptMessageHandler {
    static let name = "officeForms"

    weak var tab: Tab?

    func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any],
              let kind = body["kind"] as? String
        else { return }
        MainActor.assumeIsolated {
            switch kind {
            case "form":
                tab?.foundSignIn()
            case "submit":
                tab?.sentSignIn(
                    user: body["user"] as? String ?? "",
                    password: body["password"] as? String ?? ""
                )
            case "name":
                tab?.gaveName(body["user"] as? String ?? "")
            case "settled":
                tab?.settleSignIn(navigated: false)
            case "focus":
                // Set only when it changes: every assignment to a published
                // value redraws whatever watches the tab, same value or not.
                let typing = body["typing"] as? Bool ?? false
                if tab?.typing != typing { tab?.typing = typing }
                // Which sign-in box the caret is in, and where it sits on the
                // page — so a list of accounts can hang from it.
                // A box of a name and password, or one the page marks for
                // passkeys alone ("webauthn"), which takes no password.
                tab?.fieldFrameHost = message.frameInfo.isMainFrame ? nil : message.frameInfo.securityOrigin.host
                if let rect = body["rect"] as? [String: Double],
                   let x = rect["x"], let y = rect["y"], let w = rect["w"], let h = rect["h"] {
                    // `wide`: a box that is clearly a sign-in's, offered the
                    // accounts of the site's other hosts too; otherwise only
                    // those kept for this very host.
                    tab?.fieldFocused(CGRect(x: x, y: y, width: w, height: h), passwords: body["passwords"] as? Bool ?? true,
                                      name: body["name"] as? Bool ?? false, wide: body["wide"] as? Bool ?? true)
                } else {
                    tab?.fieldFocused(nil)
                }
            case "fullscreen":
                // Late, the page's word (see immersed() below): WebKit's
                // state has said it already. A "going" still on its way when
                // WebKit started to give the page back is stale.
                let on = body["on"] as? Bool ?? false
                if on, tab?.built?.fullscreenState == .exitingFullscreen { break }
                if tab?.immersed != on { tab?.immersed = on }
            default:
                break
            }
        }
    }

    /// Whether sites are offered passkeys here (Settings › Passwords).
    ///
    /// A build without Apple's browser entitlement can't do them: WebKit then
    /// answers isUserVerifyingPlatformAuthenticatorAvailable() with false,
    /// yet the API object exists, so sites offer the passkey path and strand
    /// you there. Taken away, they go straight to the password. Signed with
    /// the entitlement, as releases are, this is on, and Search carries out
    /// the sites' requests itself (see Passkeys.swift).
    static var passkeysOffered: Bool {
        get { Store.settings.bool(forKey: "passkeys") }
        set { Store.settings.set(newValue, forKey: "passkeys") }
    }

    /// Only the passkey object goes. navigator.credentials itself stays: sites
    /// use it for stored passwords too, and that half still works.
    ///
    /// Unless an extension answers passkey requests itself — a password
    /// manager with your passkeys in it, as 1Password is. It puts its own get
    /// and create on navigator.credentials, and reaches for the passkey object
    /// from its own script as it does; from then on sites see the object, and
    /// the extension is the one they ask. Whatever it leaves to the browser is
    /// refused at once, as if you had said no, where WebKit would try and fail.
    static let withoutPasskeys = """
    (function () {
      var real = window.PublicKeyCredential;
      if (!real) return;
      var claimed = false;
      function answered() {
        if (claimed) return true;
        try {
          if (navigator.credentials && Object.getOwnPropertyDescriptor(navigator.credentials, 'get')) claimed = true;
          else if ((new Error().stack || '').indexOf('-extension://') >= 0) claimed = true;
        } catch (e) {}
        return claimed;
      }
      try {
        Object.defineProperty(window, 'PublicKeyCredential', {
          configurable: true,
          get: function () { return answered() ? real : undefined; },
          set: function (value) { real = value; }
        });
      } catch (e) {
        try { delete window.PublicKeyCredential; } catch (ignored) {}
        return;
      }
      var proto = CredentialsContainer.prototype;
      ['get', 'create'].forEach(function (name) {
        var native = proto[name];
        try {
          Object.defineProperty(proto, name, {
            configurable: true, writable: true,
            value: function (options) {
              if (!options || !options.publicKey) return native.apply(this, arguments);
              var signal = options.signal;
              // Under the name field: nothing to offer, so it waits, as it
              // would while nobody picks one, until the page lets it go.
              if (name === 'get' && options.mediation === 'conditional') {
                return new Promise(function (resolve, reject) {
                  if (!signal) return;
                  var aborted = function () { return signal.reason || new DOMException('The operation was aborted.', 'AbortError'); };
                  if (signal.aborted) return reject(aborted());
                  signal.addEventListener('abort', function () { reject(aborted()); }, { once: true });
                });
              }
              return Promise.reject(new DOMException('The operation either timed out or was not allowed.', 'NotAllowedError'));
            }
          });
        } catch (e) {}
      });
    })();
    """

    static let script = """
    (function () {
      if (window.__officeForms) return;

      // The password box, and the last box before it that could hold a name.
      function pair() {
        var boxes = document.querySelectorAll('input[type="password"]');
        var pass = null;
        for (var p = 0; p < boxes.length; p++) {
          var b = boxes[p];
          var r = b.getBoundingClientRect();
          if (r.width > 0 && r.height > 0) { pass = b; break; }
        }
        if (!pass) return null;
        var scope = pass.form || (pass.closest && pass.closest('form')) || document;
        var all = scope.querySelectorAll('input');
        var user = null;
        for (var i = 0; i < all.length; i++) {
          if (all[i] === pass) break;
          var kind = (all[i].type || 'text').toLowerCase();
          if (kind === 'text' || kind === 'email' || kind === 'tel') user = all[i];
        }
        return { user: user, pass: pass };
      }

      // Which boxes a saved account is offered in. Strict on purpose, as
      // Safari's and Chrome's are: an account list under a project's name
      // or a message is noise, and a pick there types a login into a page
      // that never asked for one (#631).
      //
      // A password box, unless it is for a new password. A name box beside
      // a password, in its form or saying it is one. Or, with no password
      // box in sight — impots.gouv.fr, Google, Microsoft, Okta, which ask
      // for the name first — a box that says it takes a name, an address
      // or a phone number, alone in its form or nearly, and never one for
      // a search, a code, a title, a message or a checkout. Its page then
      // has to look like a sign-in's (its address, its form's, a button
      // labelled Next or Sign in) for the site's other hosts' accounts to
      // come; otherwise only accounts kept for this very host do (wide:
      // false).
      function texty(el) {
        if (!el || (el.tagName || '').toLowerCase() !== 'input' || el.disabled || el.readOnly) return false;
        var kind = (el.type || 'text').toLowerCase();
        if (['text', 'email', 'tel', 'number'].indexOf(kind) < 0) return false;
        var r = el.getBoundingClientRect();
        return r.width > 0 && r.height > 0;
      }
      function tokens(el) {
        return (el.getAttribute('autocomplete') || '').toLowerCase().split(/\\s+/).filter(Boolean);
      }
      // autocomplete says it is something else: a person's name, an
      // organisation, an address, a card, a code, a delivery's email.
      var foreign = /^(name|honorific-prefix|given-name|additional-name|family-name|honorific-suffix|nickname|organization|organization-title|one-time-code|new-password|street-address|postal-code|country|country-name|bday(-.*)?|sex|url|photo|language|impp|transaction-.*|cc-.*|address-.*|shipping|billing)$/;
      function elsewhere(el) { return tokens(el).some(function (t) { return foreign.test(t); }); }
      function vouched(el) {
        return tokens(el).some(function (t) { return /^(username|email|webauthn)$/.test(t); });
      }
      function labels(el) {
        var out = [];
        try { (el.labels || []).forEach(function (l) { out.push(l.textContent || ''); }); } catch (e) {}
        var by = el.getAttribute('aria-labelledby');
        if (by) by.split(/\\s+/).forEach(function (id) {
          var l = document.getElementById(id);
          if (l) out.push(l.textContent || '');
        });
        return out.join(' ').slice(0, 200);
      }
      function words(el) {
        return [el.name, el.id, el.getAttribute('aria-label'), el.getAttribute('placeholder'), labels(el)]
          .join(' ').toLowerCase();
      }
      function aside(el) {
        if (/^(q|to|cc|bcc|subject)$/.test(((el.name || '') + '').toLowerCase()) || /^(q|to|cc|bcc|subject)$/.test((el.id || '').toLowerCase())) return true;
        if (/(^|[\\s_\\-\\[])title($|[\\s_\\-\\]])|query|search|recherche|suche|buscar|otp|otc|one-time|captcha|code|coupon|promo|voucher|gift|recipient|destinataire|comment|message|description|project|projet/.test(words(el))) return true;
        return !!(el.closest && el.closest('[role="search"], [role="combobox"] input, form[role="search"]'))
          || (el.getAttribute('role') || '') === 'combobox' && !vouched(el);
      }
      // What a box says it takes: a name to sign in with, in a few languages.
      var who = /user|login|log-in|logon|e-?mail|courriel|correo|identifi|account|compte|cuenta|konto|phone|mobile|portable|t[e\\u00e9]l[e\\u00e9]phone|benutzer|nutzer|anmelde|usuario|utente|utilizador|gebruiker|nom d.utilisateur|fiscal|(^|[\\s_\\-])spi($|[\\s_\\-])/;
      function claimsName(el) {
        return vouched(el) || (el.type || '').toLowerCase() === 'email' || who.test(words(el));
      }
      // A form, or a page, that is clearly about something else.
      var otherForm = /project|projet|title|titre|descri|comment|message|compose|reply|(?<!e-?mail[\\s_\\-]?)address|adresse|coupon|promo|newsletter|subscri|abonn|checkout|cart|basket|panier|shipping|billing|payment|paiement|search|contact|feedback|survey|invite|share/;
      var otherPage = /checkout|\\/cart|basket|panier|commande|payment|paiement|newsletter|subscribe|abonnement/;
      function about(scope) {
        if (!scope || scope === document || !scope.getAttribute) return '';
        return [scope.id, scope.getAttribute('name'), scope.getAttribute('class'), scope.getAttribute('aria-label'),
          scope.getAttribute('action')].join(' ').toLowerCase();
      }
      // The page looks like a sign-in: its address or its form's says so,
      // or a button near the box is a sign-in's.
      var signInPath = /log-?in|log-?on|sign-?in|sign_in|signon|auth(?!or)|account|identif|connexion|connect|session|sso|saml|idp/;
      var signInHost = /^(login|signin|auth|accounts?|sso|id|idp|identity|connexion|connect|secure|compte)\\./;
      var signInButton = /^(next|continue|continuer|suivant|sign ?in|log ?in|login|log on|se connecter|connexion|me connecter|s.identifier|weiter|anmelden|einloggen|siguiente|continuar|iniciar sesi[o\\u00f3]n|entrar|acceder|avanti|accedi|volgende|inloggen|doorgaan|dalej|zaloguj)(\\s|$)/;
      function looksLikeSignIn(el, scope) {
        if (signInHost.test(location.hostname) || signInPath.test(location.pathname.toLowerCase())) return true;
        var action = scope && scope.getAttribute ? scope.getAttribute('action') : '';
        if (action) {
          try { if (signInPath.test(new URL(action, location.href).pathname.toLowerCase())) return true; } catch (e) {}
        }
        // The nearest buttons: the form's, or those of the few boxes around
        // the field when there is no form (Google's Next is outside it).
        var near = el;
        for (var up = 0; near && up < 5; up++, near = near.parentElement) {
          var buttons = near.querySelectorAll('button, input[type="submit"], [role="button"]');
          for (var i = 0; i < buttons.length && i < 20; i++) {
            var b = buttons[i];
            var said = ((b.tagName || '').toLowerCase() === 'input' ? b.value : b.textContent) || b.getAttribute('aria-label') || '';
            said = said.replace(/[^\\p{L}\\s']/gu, ' ').replace(/\\s+/g, ' ').trim().toLowerCase();
            if (said.length <= 40 && signInButton.test(said)) return true;
          }
          if (near === scope) break;
        }
        return false;
      }
      // The name box of a sign-in that asks for the password on the next
      // page: "wide", "exact" (only this host's accounts), or nothing.
      function firstStep(el) {
        if (!texty(el) || aside(el) || elsewhere(el) || !claimsName(el)) return null;
        var scope = el.form || (el.closest && el.closest('form')) || document;
        if (otherForm.test(about(scope)) || otherPage.test(location.pathname.toLowerCase())) return null;
        var all = scope.querySelectorAll('input'), others = 0;
        for (var i = 0; i < all.length; i++) {
          if (all[i] !== el && texty(all[i]) && !aside(all[i])) others++;
        }
        if (others > (vouched(el) ? 1 : 0)) return null;
        if (!vouched(el) && !scope.querySelector('button, input[type="submit"], input[type="image"], [role="button"]')) return null;
        return looksLikeSignIn(el, scope) ? 'wide' : 'exact';
      }
      function nameBox(el) { return !!firstStep(el); }
      function newPassword(el) { return tokens(el).indexOf('new-password') >= 0; }
      // What a box the caret is in is offered: null for nothing.
      function judge(el) {
        if (!el || (el.tagName || '').toLowerCase() !== 'input') return null;
        var both = pair();
        if (both) {
          if (el === both.pass) return newPassword(el) ? null : { name: false, wide: true };
          if (el !== both.user || newPassword(both.pass)) return null;
          if (aside(el) || elsewhere(el)) return null;
          var together = !!el.form && el.form === both.pass.form;
          return together || claimsName(el) ? { name: false, wide: true } : null;
        }
        var step = firstStep(el);
        return step ? { name: true, wide: step === 'wide' } : null;
      }
      // The name box of a first step, if this page is one: the box the
      // caret is in, or else the one box on the page that is. A page with
      // more than a handful of boxes to type in is not a first step.
      function named() {
        if (pair()) return null;
        var el = document.activeElement;
        if (nameBox(el)) return el;
        var all = document.querySelectorAll('input'), seen = [];
        for (var i = 0; i < all.length; i++) {
          if (texty(all[i]) && !aside(all[i])) seen.push(all[i]);
          if (seen.length > 6) return null;
        }
        for (var j = 0; j < seen.length; j++) { if (nameBox(seen[j])) return seen[j]; }
        return null;
      }

      function put(box, value) {
        if (!box) return;
        var setter = Object.getOwnPropertyDescriptor(
          window.HTMLInputElement.prototype, 'value'
        );
        if (setter && setter.set) { setter.set.call(box, value); } else { box.value = value; }
        box.dispatchEvent(new Event('input', { bubbles: true }));
        box.dispatchEvent(new Event('change', { bubbles: true }));
      }

      // What was typed by hand and not yet sent, box by box. A page whose
      // boxes still hold it is not put to sleep: waking it couldn't bring
      // that back. A box emptied by sending — a chat's composer — no longer
      // counts, and neither does a search box.
      var typed = [];
      document.addEventListener('input', function (e) {
        if (!e.isTrusted) return;
        var el = e.target;
        if (!el || typed.indexOf(el) >= 0) return;
        typed.push(el);
        if (typed.length > 40) typed.shift();
      }, true);
      function unsaved() {
        for (var i = 0; i < typed.length; i++) {
          var el = typed[i];
          if (!el.isConnected) continue;
          var tag = (el.tagName || '').toLowerCase();
          if (tag === 'textarea') {
            if (el.value.trim() && el.value !== el.defaultValue) return true;
          } else if (tag === 'input') {
            var kind = (el.type || 'text').toLowerCase();
            if (['text', 'email', 'url', 'tel', 'number'].indexOf(kind) < 0) continue;
            if (el.value.trim() && el.value !== el.defaultValue) return true;
          } else if (el.isContentEditable) {
            if ((el.textContent || '').trim()) return true;
          }
        }
        return false;
      }

      window.__officeForms = {
        unsaved: unsaved,
        fill: function (user, password) {
          var both = pair();
          if (!both) return false;
          if (both.user && !both.user.value) put(both.user, user);
          put(both.pass, password);
          return true;
        },
        // The name alone, into a first step's box: there is no password
        // box yet, and none is filled anywhere.
        name: function (user) {
          var box = named();
          if (!box) return false;
          put(box, user);
          return true;
        },
        // Whether there is still a sign-in on the page. Asked after a
        // password went out, to tell a sign-in that took from one refused.
        hasPassword: function () { return !!pair(); },
        // What a box would be offered, for the tests: null, or whether a
        // pick puts in the name alone and whether the site's other hosts'
        // accounts come too.
        verdict: function (el) { return judge(el || document.activeElement); }
      };

      // What is in the boxes when they are sent. Said every time — a click
      // on "show password" says it too — because the browser only listens
      // once the page has moved on, and keeps the last thing it heard.
      //
      // A first step says the name it is sending: the page after it asks
      // for the password alone, and the name is what the browser saves it
      // under.
      function offer() {
        var both = pair();
        if (!both) {
          var box = named();
          var name = box ? box.value.trim() : '';
          if (name) window.webkit.messageHandlers.officeForms.postMessage({ kind: 'name', user: name });
          return;
        }
        if (!both.pass.value) return;
        window.webkit.messageHandlers.officeForms.postMessage({
          kind: 'submit',
          user: both.user ? both.user.value : '',
          password: both.pass.value
        });
      }

      document.addEventListener('submit', offer, true);
      document.addEventListener('keydown', function (e) {
        if (e.key !== 'Enter') return;
        var both = pair();
        if (both && (document.activeElement === both.pass || document.activeElement === both.user)) offer();
        else if (!both && nameBox(document.activeElement)) offer();
      }, true);
      // Plenty of sign-in buttons aren't in a form and never fire submit.
      document.addEventListener('click', function (e) {
        var el = e.target;
        if (!el || !el.closest) return;
        if (el.closest('button, input[type="submit"], [role="button"]')) {
          setTimeout(offer, 0);
        }
      }, true);

      var told = false;
      function tell() {
        if (told || !pair()) return;
        told = true;
        window.webkit.messageHandlers.officeForms.postMessage({ kind: 'form' });
      }
      if (document.readyState === 'complete') { tell(); }
      else { window.addEventListener('load', tell); }
      // A form the page builds for itself, a moment after it loads — or the
      // password step of a sign-in that asks for the name first.
      setTimeout(tell, 700);
      setTimeout(tell, 2200);
      // The boxes going away without a new page — a sign-in done in place —
      // is the other way a sign-in shows it took.
      //
      // Looked at a quarter of a second after the page changes, not at every
      // change: a chat writing out its answer changes the page on every word,
      // and looking for the boxes each time — through the whole page — made
      // a long conversation slower with every word it wrote (3,000 words:
      // 0.3 s without this, up to 3.7 s with it, and climbing).
      var settling = null, looking = null;
      function look() {
        looking = null;
        if (!told) { tell(); return; }
        if (pair()) return;
        told = false;
        clearTimeout(settling);
        settling = setTimeout(function () {
          if (pair()) return;
          window.webkit.messageHandlers.officeForms.postMessage({ kind: 'settled' });
        }, 400);
      }
      new MutationObserver(function () {
        if (!looking) looking = setTimeout(look, 250);
      }).observe(document.documentElement, { childList: true, subtree: true });

      // Whether the caret is somewhere on the page that takes typing.
      //
      // The browser gives Tab to its own row of tabs, which is right until you
      // are filling something in: plenty of fields offer a completion you take
      // with Tab, and stealing the key there would make them unusable.
      function editable(el) {
        if (!el) return false;
        var tag = (el.tagName || '').toLowerCase();
        if (tag === 'textarea') return true;
        if (el.isContentEditable === true) return true;
        if (el.getAttribute && el.getAttribute('role') === 'textbox') return true;
        // A document that types into a frame of its own — Google Docs keeps
        // the caret there. ⌘⇧V is that document's paste, so the frame counts.
        if (tag === 'iframe') {
          try { return editable(el.contentDocument && el.contentDocument.activeElement); }
          catch (e) { return false; }
        }
        if (tag !== 'input') return false;
        var kind = (el.type || 'text').toLowerCase();
        return ['text', 'search', 'email', 'url', 'tel', 'password', 'number',
                'date', 'datetime-local', 'month', 'week', 'time'].indexOf(kind) >= 0;
      }

      // What was last said, so a scroll can keep quiet when nothing moved
      // that anyone is listening for.
      var said = null;
      // A box the page says takes a passkey: autocomplete="username webauthn".
      function forPasskeys(el) {
        return !!(el && (el.tagName || '').toLowerCase() === 'input' &&
          /(^|\\s)webauthn(\\s|$)/i.test(el.getAttribute('autocomplete') || ''));
      }
      // What the box the caret is in was judged to be: judged again when the
      // caret moves, not on every frame of a scroll, which only moves it.
      var judged = { el: null, verdict: null };
      function caret(scrolled) {
        var el = document.activeElement;
        // The boxes are only looked for with the caret in one: this runs on
        // every frame of every scroll, and looking goes through the whole page.
        if (scrolled !== true || judged.el !== el) judged = { el: el, verdict: judge(el) };
        var verdict = judged.verdict;
        var rect = null;
        // A first step's name box: the accounts hang from it as from a
        // name box beside a password, and a pick puts in the name alone.
        var passwords = !!verdict;
        var name = !!(verdict && verdict.name);
        var wide = !verdict || verdict.wide;
        if (passwords || forPasskeys(el)) {
          var r = el.getBoundingClientRect();
          if (r.width > 0 && r.height > 0) rect = { x: r.left, y: r.top, w: r.width, h: r.height };
        }
        var typing = editable(el);
        var now = typing + (rect ? ' ' + passwords + ' ' + name + ' ' + wide + ' ' + rect.x + ' ' + rect.y + ' ' + rect.w + ' ' + rect.h : '');
        if (scrolled === true && now === said) return;
        said = now;
        window.webkit.messageHandlers.officeForms.postMessage({
          kind: 'focus',
          typing: typing,
          rect: rect,
          passwords: passwords,
          name: name,
          wide: wide
        });
      }

      // The box moves when the page scrolls or the window changes size, and
      // whatever hangs from it has to move too. Once a frame at most, and
      // only when something did change: with the caret nowhere near a sign-in,
      // every frame of every scroll used to send the same answer again.
      var moving = false;
      function moved() {
        if (moving) return;
        moving = true;
        requestAnimationFrame(function () { moving = false; caret(true); });
      }
      window.addEventListener('scroll', moved, true);
      window.addEventListener('resize', moved);

      // A page's full screen, in and out. WebKit's own state says it first
      // (Tab.immersed follows web.fullscreenState): in once WebKit has the
      // page in its window, back as it starts to give it back. This comes
      // after each and is only a fallback. It used to be said early, on the
      // request itself, which laid the page out at the whole window's size
      // in ours a moment before WebKit took it, and the way back then
      // started from that size.
      function immersed() {
        var on = !!(document.fullscreenElement || document.webkitFullscreenElement);
        window.webkit.messageHandlers.officeForms.postMessage({
          kind: 'fullscreen', on: on
        });
      }
      document.addEventListener('fullscreenchange', immersed, true);
      document.addEventListener('webkitfullscreenchange', immersed, true);

      document.addEventListener('focusin', caret, true);
      document.addEventListener('focusout', function () { setTimeout(caret, 0); }, true);
      document.addEventListener('mouseup', function () { setTimeout(caret, 0); }, true);
      caret();
    })();
    """
}
