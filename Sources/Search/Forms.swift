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

    /// Fill in your contact details is on (Prefs.fillsContacts): the form
    /// script looks at boxes for your card. Off, it doesn't, and costs the
    /// pages nothing.
    @MainActor static var contacts = false
    /// Said to a page, before its own scripts, with that on; and to the
    /// pages up when it changes.
    static let contactsOn = "window.__officeContacts = true;"
    static func contacts(_ on: Bool) -> String { "window.__officeContacts = \(on);" }

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
                    // `code`: a box for a verification code, not a sign-in's;
                    // `wide` then means it says so, rather than a guess.
                    // A box for a detail of your own: what hangs from it is
                    // your card in Contacts, not an account.
                    tab?.fieldFocused(CGRect(x: x, y: y, width: w, height: h), passwords: body["passwords"] as? Bool ?? true,
                                      name: body["name"] as? Bool ?? false, wide: body["wide"] as? Bool ?? true,
                                      code: body["code"] as? Bool ?? false,
                                      fill: (body["contact"] as? String).map { .contact($0, box: body["box"] as? Int ?? 0) })
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
    ///
    /// Held here, not read from the store: a build of your own running beside
    /// a release shares the store, and its first run writes passkeys off into
    /// it, which would take them from the release's new pages while its
    /// switch still says on. Preferences sets it from the switch before the
    /// first page, and so does every flip of the switch.
    static var passkeysOffered = false

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

      // Which boxes a verification code from the Passwords app is offered
      // in: one that says so, a row of boxes of one character each, or one
      // whose words say so. A wrong guess costs little, since nothing comes
      // up on a site with no code kept for it; the words that rule a box out
      // still keep a discount, a card's or a postal code from asking at all.
      // Only a box that says so gets the codes of the site's other hosts: a
      // guess gets this host's alone. A box marked for passkeys stays theirs.
      //
      // The box's row: the nearest few boxes around it, all of one character.
      function cells(el) {
        if (!texty(el) || el.maxLength !== 1) return null;
        var up = el.parentElement;
        for (var i = 0; up && i < 4; i++, up = up.parentElement) {
          var row = Array.prototype.filter.call(up.querySelectorAll('input'), function (b) { return texty(b); });
          if (row.length < 4) continue;
          return row.length <= 8 && row.every(function (b) { return b.maxLength === 1; }) ? row : null;
        }
        return null;
      }
      var codeWords = /otp([^a-z]|$)|(^|[^a-z])[th]?otp(code|pin|token|input|field|value)|(^|[^a-z])otc([^a-z]|$)|one[\\s_\\-]?time|(^|[^a-z0-9])[2tm]fa|two[\\s_\\-]?(factor|step)|2[\\s_\\-]?step|second[\\s_\\-]?factor|passcode|authenticator|usage unique|verif[a-z]*[\\s_\\-]?code|security[\\s_\\-]?code|auth[a-z]*[\\s_\\-]?code|login[\\s_\\-]?code|code[\\s_\\-]+(de[\\s_\\-]+|d.)?(v[e\\u00e9]rif|valid|s[e\\u00e9]curit|authentif|authentic|confirm)/;
      var plainCode = /code([^a-z]|$)|c[o\\u00f3]digo/;
      var otherCode = /promo|coupon|voucher|discount|gift|cadeau|r[e\\u00e9]duc|postal|post[\\s_\\-]?code|area[\\s_\\-]?code|dial[\\s_\\-]?code|country|referr|parrain|invit|affili|sponsor|captcha|barcode|backup|recovery|secours|r[e\\u00e9]cup|card|carte|siret|siren|product|produit|source|embed|snippet|license|licence|activation|serial|(^|[^a-z])(zip|pays|qr|vat|tva|tax|sku|iban|cvv|cvc|csc)/;
      function digitsOnly(el) {
        var kind = (el.type || 'text').toLowerCase(), mode = (el.getAttribute('inputmode') || '').toLowerCase();
        return kind === 'tel' || kind === 'number' || mode === 'numeric' || mode === 'decimal'
          || /\\\\d|0-9/.test(el.getAttribute('pattern') || '') || (el.maxLength >= 4 && el.maxLength <= 10);
      }
      function saysCode(el) { return tokens(el).indexOf('one-time-code') >= 0; }
      function codeBox(el) {
        if (!texty(el) || forPasskeys(el)) return false;
        if (saysCode(el) || cells(el)) return true;
        if (elsewhere(el) || vouched(el) || (el.type || '').toLowerCase() === 'email') return false;
        var said = words(el);
        if (otherCode.test(said)) return false;
        var scope = el.form || (el.closest && el.closest('form')) || document;
        // Not what a form's address asks: that is often a long random token.
        if (otherForm.test(about(scope).split('?')[0]) || otherPage.test(location.pathname.toLowerCase())) return false;
        if (el.closest && el.closest('[role="search"], form[role="search"]')) return false;
        if (codeWords.test(said)) return true;
        if (!plainCode.test(said)) return false;
        // Only "code": the one thing its form asks for, and for digits or a sign-in.
        var all = scope.querySelectorAll('input');
        for (var i = 0; i < all.length; i++) {
          if (all[i] !== el && texty(all[i]) && !aside(all[i])) return false;
        }
        return digitsOnly(el) || looksLikeSignIn(el, scope);
      }
      // The box a code was last offered under: a click on the list can take
      // the caret out of it.
      var codeAt = null;

      // A box for something on your own card in Contacts (MeCard): a name,
      // an email, a phone number, a part of an address. What the page says
      // it is (autocomplete) counts first; a page that says "off", or
      // nothing, is read by its name and label. None of it runs unless
      // Fill in your contact details is on (__officeContacts, set by Tab).
      var contactToken = /^(name|given-name|additional-name|family-name|organization|email|tel|tel-national|street-address|address-line[12]|address-level[12]|postal-code|country|country-name)$/;
      // In order: "company name" is a company's, "e-mail address" an email.
      var contactGuesses = [
        ['email', /e-?mail|courriel|correo/],
        ['tel', /phone|mobile|(^|[^a-z])cell|portable|handy|telefon|t[e\\u00e9]l[e\\u00e9]fono|(^|[^a-z])t[e\\u00e9]l([^a-z]|$)/],
        ['given-name', /first.?name|given.?name|(^|[^a-z])fname|forename|pr[e\\u00e9]nom|vorname|(^|[^a-z])nombre/],
        ['family-name', /last.?name|family.?name|surname|(^|[^a-z])lname|nom.?de.?famille|nachname|apellido/],
        ['organization', /company|organi[sz]ation|business|firma|soci[e\\u00e9]t[e\\u00e9]|empresa|entreprise/],
        ['address-line2', /address.?(line)?.?2|addr2|apartment|(^|[^a-z])apt|suite|(^|[^a-z])unit|compl[e\\u00e9]ment|adresszusatz/],
        ['postal-code', /zip|postal|post.?code|postleitzahl|(^|[^a-z])plz|code.?postal|c[o\\u00f3]digo.?postal/],
        ['address-level2', /city|town|ville|stadt|ciudad|localit|suburb|commune|(^|[^a-z])ort([^a-z]|$)/],
        ['address-level1', /(^|[^a-z])state([^a-z]|$)|province|region|county|bundesland|provincia|prefecture/],
        ['country', /country|(^|[^a-z])pays|(^|[^a-z])pa[i\\u00ed]s([^a-z]|$)|(^|[^a-z])land([^a-z]|$)/],
        ['address-line1', /address|street|(^|[^a-z])addr|adresse|stra(ss|\\u00df)e|direcci[o\\u00f3]n|line.?1/],
        ['name', /full.?name|your.?name|nom.?complet|(^|[^a-z_])name([^a-z]|$)|^\\s*nom\\s*$/]
      ];
      // Rails' user[email] and a profile's profile_email are yours; a
      // username, a file's name, a card's holder, a friend's address and a
      // fax number are not.
      var notContact = /user.?name|user.?id|login|log-in|passw|search|query|captcha|coupon|promo|voucher|gift|comment|message|subject|title|descri|project|repositor|(^|[^a-z])file|(^|[^a-z])card|otp|one.?time|verif|passcode|2fa|mfa|recipient|friend|destinat|usuario|utilisateur|benutzer|display.?name|nick|wallet|(^|[^a-z])fax|pager/;
      // Not an email, though they end in one: voicemail, a mailing address.
      var notEmail = /voice.?mail|e-?mailing/g;
      // Kinds that say a form is about you, beside a name: a "Name" with a
      // "Region" is a cloud console's new server as often as a person.
      var strongKind = /^(email|tel|tel-national|street-address|address-line1|address-level2|postal-code)$/;
      // Which of a checkout's addresses a box is part of: shipping or
      // billing, and a section the page names. Boxes of one are never
      // filled from a pick in the other.
      function contactGroup(t, w) {
        var section = t.filter(function (x) { return /^section-/.test(x); })[0] || '';
        var mode = t.indexOf('shipping') >= 0 ? 'shipping' : t.indexOf('billing') >= 0 ? 'billing'
          : /(^|[^a-z])(shipping|ship.?to|delivery|livraison|lieferung)/.test(w) ? 'shipping'
          : /(^|[^a-z])(billing|bill.?to|invoice|facturation|rechnung)/.test(w) ? 'billing' : '';
        return section + (section && mode ? ' ' : '') + mode;
      }
      // A box you could type or choose a detail into, and that you can see.
      // Cheap: asked of every box of a form whenever the caret moves.
      function slot(el) {
        if (!el || el.disabled || el.readOnly) return false;
        var tag = (el.tagName || '').toLowerCase();
        if (tag === 'input') {
          if (['text', 'email', 'tel', ''].indexOf((el.getAttribute('type') || '').toLowerCase()) < 0) return false;
        } else if (tag !== 'select' && tag !== 'textarea') {
          return false;
        }
        var r = el.getBoundingClientRect();
        if (!(r.width > 1 && r.height > 1) || r.right + window.scrollX < 0 || r.bottom + window.scrollY < 0) return false;
        // Where it can't be told, it isn't seen.
        try {
          return !!el.checkVisibility && el.checkVisibility({ opacityProperty: true, visibilityProperty: true });
        } catch (e) { return false; }
      }
      // Whether a box is really there to see, asked of the boxes a pick is
      // about to fill: a form hides boxes away to catch robots, or keeps
      // them for a step you haven't reached, and your details don't go in
      // them. Out of the way of keys (tabindex -1), hidden from screen
      // readers, past the page's end, clipped away by a box around it,
      // faded to nothing, or under something else.
      function seen(el) {
        if (el.tabIndex < 0 || (el.closest && el.closest('[inert], [aria-hidden="true"]'))) return false;
        var r = el.getBoundingClientRect(), doc = document.documentElement;
        if (r.left + window.scrollX >= Math.max(doc.scrollWidth, doc.clientWidth)
            || r.top + window.scrollY >= Math.max(doc.scrollHeight, doc.clientHeight)) return false;
        var left = r.left, top = r.top, right = r.right, bottom = r.bottom, alpha = 1;
        for (var up = el; up && up.nodeType === 1 && up !== doc; up = up.parentElement) {
          var s = getComputedStyle(up);
          alpha *= parseFloat(s.opacity) || 0;
          if (alpha < 0.1) return false;
          if (/inset\\(\\s*(50|100)%|circle\\(\\s*0/.test(s.clipPath || '') || /^rect\\(\\s*0/.test(s.clip || '')) return false;
          if (up !== el && (s.overflowX !== 'visible' || s.overflowY !== 'visible')) {
            var b = up.getBoundingClientRect();
            left = Math.max(left, b.left); top = Math.max(top, b.top);
            right = Math.min(right, b.right); bottom = Math.min(bottom, b.bottom);
            if (right - left < 1 || bottom - top < 1) return false;
          }
          if (s.position === 'fixed') break;
        }
        // On screen: what is at its middle is the box, or something small
        // beside it, as a label drawn over it; not a sheet laid over all.
        var x = (left + right) / 2, y = (top + bottom) / 2;
        if (x >= 0 && y >= 0 && x < window.innerWidth && y < window.innerHeight) {
          var hit = document.elementFromPoint(x, y);
          if (hit && hit !== el && !el.contains(hit)) {
            var h = hit.getBoundingClientRect();
            var beside = el.parentElement && el.parentElement.contains(hit) && h.width * h.height <= r.width * r.height * 1.5;
            if (!beside && !(hit.closest && hit.closest('label'))) return false;
          }
        }
        return true;
      }
      // What a box takes from your card: { kind, sure, group }, or null.
      function contactKind(el) {
        if (!slot(el)) return null;
        var all = tokens(el);
        // A fax's or a pager's number is not your phone's.
        if (all.indexOf('fax') >= 0 || all.indexOf('pager') >= 0) return null;
        var t = all.filter(function (w) { return !/^(section-.*|shipping|billing|home|work|mobile)$/.test(w); });
        var last = t[t.length - 1];
        var w = words(el).replace(notEmail, ' ');
        if (last && contactToken.test(last)) return { kind: last, sure: true, group: contactGroup(all, w) };
        // A part of a number split over boxes (tel-area-code…) takes no
        // whole number.
        if (last && (foreign.test(last) || /^(username|current-password|new-password|webauthn|cc-.*|one-time-code|tel-.*)$/.test(last))) return null;
        if (/^(q|to|cc|bcc|subject)$/.test(((el.name || el.id || '') + '').toLowerCase())) return null;
        if (el.closest && el.closest('[role="search"], form[role="search"]')) return null;
        // One character a box: a digit of a code, never a detail of yours.
        if (notContact.test(w) || el.maxLength === 1) return null;
        var kind = (el.getAttribute('type') || '').toLowerCase(), group = contactGroup(all, w);
        if (kind === 'email') return { kind: 'email', sure: false, group: group };
        if (kind === 'tel') return { kind: 'tel', sure: false, group: group };
        for (var i = 0; i < contactGuesses.length; i++) {
          if (contactGuesses[i][1].test(w)) return { kind: contactGuesses[i][0], sure: false, group: group };
        }
        return null;
      }
      function formOf(el) { return el.form || (el.closest && el.closest('form')) || null; }
      // How many boxes are under a node, stopping once past `most`.
      function boxesUnder(node, most) {
        var n = 0;
        for (var i = 0, tags = ['input', 'select', 'textarea']; i < tags.length && n <= most; i++) {
          n += node.getElementsByTagName(tags[i]).length;
        }
        return n;
      }
      // The boxes that go with this one: its form's, or, with no form, those
      // of the widest box around it holding twenty or fewer.
      function contactScope(el) {
        var form = formOf(el);
        if (form) return form;
        var best = el.parentElement, up = el.parentElement;
        for (var level = 0; up && level < 8; level++, up = up.parentElement) {
          if (boxesUnder(up, 20) > 20) break;
          best = up;
        }
        return best || document;
      }
      // The boxes of a scope your card has something for, the one the caret
      // is in among them however far down a long form it is. Hidden boxes,
      // ticks and buttons aren't looked at, and other forms' boxes inside a
      // scope with no form of its own are left to them.
      var fillable = 'input:not([type=hidden]):not([type=checkbox]):not([type=radio]):not([type=submit]):not([type=button]):not([type=password]):not([type=file]), select, textarea';
      function contactBoxes(scope, el) {
        var all = scope.querySelectorAll(fillable), out = [], mine = false, form = el ? formOf(el) : null;
        for (var i = 0; i < all.length && out.length < 40; i++) {
          if (scope.tagName !== 'FORM' && formOf(all[i]) !== form) continue;
          var k = contactKind(all[i]);
          if (!k) continue;
          out.push({ box: all[i], kind: k.kind, group: k.group });
          if (all[i] === el) mine = true;
        }
        if (el && !mine) {
          var own = contactKind(el);
          if (own) out.push({ box: el, kind: own.kind, group: own.group });
        }
        return out;
      }
      // Whether your details are offered under a box, and as what. A box
      // the page marks is enough; a box read by its name only if its form
      // asks for an email, a phone or an address besides: "Name" alone is a
      // project's as often as yours.
      function contactBox(el) {
        if (!el || ['input', 'textarea'].indexOf((el.tagName || '').toLowerCase()) < 0) return null;
        var k = contactKind(el);
        if (!k) return null;
        if (k.sure) return k.kind;
        var kinds = {};
        contactBoxes(contactScope(el), el).forEach(function (b) { kinds[b.kind] = true; });
        var all = Object.keys(kinds);
        if (all.length < 2 || !all.some(function (x) { return strongKind.test(x); })) return null;
        return k.kind;
      }
      // Each box the caret has been in, by a number that goes with the list
      // hung from it: a pick fills the box it was offered under, or nothing.
      var boxIds = new WeakMap(), lastBoxId = 0;
      function boxId(el) {
        if (!boxIds.has(el)) boxIds.set(el, ++lastBoxId);
        return boxIds.get(el);
      }
      // Lists you have chosen from yourself, which a pick never changes back.
      var touched = new WeakSet();
      ['input', 'change'].forEach(function (kind) {
        document.addEventListener(kind, function (e) { if (e.isTrusted && e.target) touched.add(e.target); }, true);
      });
      // A list still showing what it came with, or asking you to choose.
      function unchosen(select) {
        if (touched.has(select)) return false;
        var o = select.options[select.selectedIndex];
        return !o || o.disabled || !o.value || o.defaultSelected || select.selectedIndex === 0;
      }
      function put(box, value) {
        if (!box) return;
        var tag = (box.tagName || '').toLowerCase();
        var proto = tag === 'textarea' ? window.HTMLTextAreaElement.prototype
          : tag === 'select' ? window.HTMLSelectElement.prototype : window.HTMLInputElement.prototype;
        var setter = Object.getOwnPropertyDescriptor(proto, 'value');
        if (setter && setter.set) { setter.set.call(box, value); } else { box.value = value; }
        box.dispatchEvent(new Event('input', { bubbles: true }));
        box.dispatchEvent(new Event('change', { bubbles: true }));
      }
      // The option of a list that says what the card says: by its value
      // or its words, the country by its code or its name.
      function choose(select, wanted) {
        var want = wanted.filter(Boolean).map(function (w) { return w.trim().toLowerCase(); });
        for (var i = 0; i < select.options.length; i++) {
          var o = select.options[i];
          if (want.indexOf((o.value || '').trim().toLowerCase()) >= 0 || want.indexOf((o.text || '').trim().toLowerCase()) >= 0) {
            put(select, o.value);
            return true;
          }
        }
        return false;
      }
      // What of a card goes into a box that takes `max` characters at most:
      // a ZIP+4 code's first five, and otherwise nothing cut short.
      function fits(value, kind, max) {
        if (!(max > 0) || value.length <= max) return value;
        var head = kind === 'postal-code' ? value.split(/[\\s-]/)[0] : '';
        return head && head.length <= max ? head : null;
      }

      // The boxes a pick filled flash in the Mac's accent colour and fade
      // back, box after box a beat apart, so it reads as running down the
      // form, as Safari marks what it filled. An animation of the box (the
      // Web Animations API), not a change to its style: nothing of it is
      // left on the box once it ends, and it fades back to whatever the
      // box's own colour is by then.
      function flash(box, tint, delay) {
        try {
          box.animate([{ backgroundColor: tint }, { backgroundColor: tint, offset: 0.08 }],
            { duration: 950, delay: delay, easing: 'ease-out' });
        } catch (e) {}
      }

      // A card's details into the boxes that go with the one the caret is
      // in. That one always; the others only if still empty, so nothing
      // typed is written over, only those of its own address (shipping or
      // billing), and only those you can see. `alone` (a shift-click): that
      // one only. `box`: the box the list was offered under, which has to be
      // the one the caret is still in. `tint`: the colour they flash, if.
      function fillContact(card, alone, box, tint) {
        var el = document.activeElement;
        if (box != null && (!el || boxId(el) !== box)) return 0;
        var kind = contactBox(el);
        if (!kind) return 0;
        var boxes = alone ? [{ box: el, kind: kind, group: '' }] : contactBoxes(contactScope(el), el);
        var mine = boxes.filter(function (b) { return b.box === el; })[0];
        var group = (mine && mine.group) || (boxes.filter(function (b) { return b.group; })[0] || {}).group || '';
        var filled = 0, took = [];
        boxes.forEach(function (b) {
          var box = b.box, kind = b.kind, tag = (box.tagName || '').toLowerCase();
          if (box !== el) {
            if (b.group && b.group !== group) return;
            if (tag === 'select' ? !unchosen(box) : (box.value || '').trim()) return;
            if (!seen(box)) return;
          }
          var value = kind === 'country' && tag !== 'select' ? card['country-name'] : card[kind];
          if (kind === 'street-address' && tag !== 'textarea' && value) value = value.replace(/\\s*\\n\\s*/g, ', ');
          if (tag === 'select') {
            var wanted = kind === 'country' || kind === 'country-name' ? [card['country'], card['country-name']] : [value];
            if (choose(box, wanted)) { filled++; took.push(box); }
            return;
          }
          value = value && fits(value, kind, box.maxLength);
          if (!value) return;
          put(box, value);
          filled++;
          took.push(box);
        });
        try { el.focus(); } catch (e) {}
        if (tint) took.forEach(function (box, i) { flash(box, tint, i * 30); });
        return filled;
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
        // A verification code, into the box it was offered under: digit by
        // digit across a row of boxes, and only if it fits.
        code: function (value) {
          var box = codeBox(document.activeElement) ? document.activeElement : codeAt;
          if (!box || !box.isConnected || !codeBox(box)) return false;
          var row = cells(box);
          if (!row) { put(box, value); return true; }
          if (row.length !== value.length) return false;
          row.forEach(function (b, i) { put(b, value.charAt(i)); });
          return true;
        },
        // Whether a box is offered codes, for the tests.
        coded: function (el) { return codeBox(el || document.activeElement); },
        // Whether there is still a sign-in on the page. Asked after a
        // password went out, to tell a sign-in that took from one refused.
        hasPassword: function () { return !!pair(); },
        // Your card's details, picked from under a box for one: how many
        // boxes took one.
        contact: function (card, alone, box, tint) { return fillContact(card || {}, !!alone, box, tint); },
        // What a box is offered from your card, for the tests: a kind
        // ("email", "postal-code"…) or null.
        contactVerdict: function (el) { return contactBox(el || document.activeElement); },
        // What a box would be offered, for the tests: null, or whether a
        // pick puts in the name alone and whether the site's other hosts'
        // accounts come too.
        verdict: function (el) { return judge(el || document.activeElement); },
        // A form the browser has just seen go out. Sent from the page's
        // script — form.submit() fires no submit event, and the link or
        // timer that called it is no button — nothing below heard it.
        // Unless something did a moment ago: a page that swaps the
        // password for a hash of it before sending would have the hash
        // saved instead.
        sent: function () { if (Date.now() - offered > 2000) offer(); }
      };

      // What is in the boxes when they are sent. Said every time — a click
      // on "show password" says it too — because the browser only listens
      // once the page has moved on, and keeps the last thing it heard.
      //
      // A first step says the name it is sending: the page after it asks
      // for the password alone, and the name is what the browser saves it
      // under.
      var offered = 0;
      function offer() {
        var both = pair();
        if (!both) {
          var box = named();
          var name = box ? box.value.trim() : '';
          if (name) {
            offered = Date.now();
            window.webkit.messageHandlers.officeForms.postMessage({ kind: 'name', user: name });
          }
          return;
        }
        if (!both.pass.value) return;
        offered = Date.now();
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
      // The box the last list hung from. The caret going straight from it
      // to a box of another form says it left first: a pick made in one
      // form keeps the list from coming back under the boxes it just
      // filled, not under every box after it on the page. Within one form,
      // from the name to the password, it stays away.
      var hungFrom = null;
      // A box the page says takes a passkey: autocomplete="username webauthn".
      function forPasskeys(el) {
        return !!(el && (el.tagName || '').toLowerCase() === 'input' &&
          /(^|\\s)webauthn(\\s|$)/i.test(el.getAttribute('autocomplete') || ''));
      }
      // What the box the caret is in was judged to be: judged again when the
      // caret moves, not on every frame of a scroll, which only moves it.
      var judged = { el: null, verdict: null, code: false, sure: false, contact: null };
      function caret(scrolled) {
        var el = document.activeElement;
        // The boxes are only looked for with the caret in one: this runs on
        // every frame of every scroll, and looking goes through the whole page.
        if (scrolled !== true || judged.el !== el) {
          var seen = judge(el);
          var coded = !seen && codeBox(el);
          judged = { el: el, verdict: seen, code: coded, sure: coded && saysCode(el),
                     contact: !seen && !coded && window.__officeContacts === true ? contactBox(el) : null };
          if (coded) codeAt = el;
        }
        var verdict = judged.verdict;
        var code = judged.code;
        // A box for your name, email, phone or address: your card's
        // details hang from it.
        var contact = judged.contact;
        var rect = null;
        // A first step's name box: the accounts hang from it as from a
        // name box beside a password, and a pick puts in the name alone.
        var passwords = !!verdict;
        var name = !!(verdict && verdict.name);
        var wide = code ? judged.sure : !verdict || verdict.wide;
        if (passwords || code || contact || forPasskeys(el)) {
          var r = el.getBoundingClientRect();
          if (r.width > 0 && r.height > 0) rect = { x: r.left, y: r.top, w: r.width, h: r.height };
        }
        var typing = editable(el);
        var now = typing + (rect ? ' ' + passwords + ' ' + name + ' ' + wide + ' ' + code + ' ' + contact + ' ' + rect.x + ' ' + rect.y + ' ' + rect.w + ' ' + rect.h : '');
        if (scrolled === true && now === said) return;
        said = now;
        if (rect && hungFrom && hungFrom !== el && contactScope(hungFrom) !== contactScope(el)) {
          window.webkit.messageHandlers.officeForms.postMessage({ kind: 'focus', typing: typing, rect: null });
        }
        hungFrom = rect ? el : null;
        window.webkit.messageHandlers.officeForms.postMessage({
          kind: 'focus',
          typing: typing,
          rect: rect,
          passwords: passwords,
          name: name,
          wide: wide,
          code: code,
          contact: contact,
          box: contact ? boxId(el) : null
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
