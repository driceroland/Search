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
            case "settled":
                tab?.settleSignIn(navigated: false)
            case "focus":
                tab?.typing = body["typing"] as? Bool ?? false
                // Which sign-in box the caret is in, and where it sits on the
                // page — so a list of accounts can hang from it.
                if let rect = body["rect"] as? [String: Double],
                   let x = rect["x"], let y = rect["y"], let w = rect["w"], let h = rect["h"] {
                    tab?.fieldFocused(CGRect(x: x, y: y, width: w, height: h))
                } else {
                    tab?.fieldFocused(nil)
                }
            case "fullscreen":
                tab?.immersed = body["on"] as? Bool ?? false
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
        // Whether there is still a sign-in on the page. Asked after a
        // password went out, to tell a sign-in that took from one refused.
        hasPassword: function () { return !!pair(); }
      };

      // What is in the boxes when they are sent. Said every time — a click
      // on "show password" says it too — because the browser only listens
      // once the page has moved on, and keeps the last thing it heard.
      function offer() {
        var both = pair();
        if (!both || !both.pass.value) return;
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
      var settling = null;
      new MutationObserver(function () {
        if (!told) { tell(); return; }
        if (pair()) return;
        told = false;
        clearTimeout(settling);
        settling = setTimeout(function () {
          if (pair()) return;
          window.webkit.messageHandlers.officeForms.postMessage({ kind: 'settled' });
        }, 400);
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
        if (tag !== 'input') return false;
        var kind = (el.type || 'text').toLowerCase();
        return ['text', 'search', 'email', 'url', 'tel', 'password', 'number',
                'date', 'datetime-local', 'month', 'week', 'time'].indexOf(kind) >= 0;
      }

      function caret() {
        var el = document.activeElement;
        var both = pair();
        var rect = null;
        if (both && el && (el === both.user || el === both.pass)) {
          var r = el.getBoundingClientRect();
          if (r.width > 0 && r.height > 0) rect = { x: r.left, y: r.top, w: r.width, h: r.height };
        }
        window.webkit.messageHandlers.officeForms.postMessage({
          kind: 'focus',
          typing: editable(el),
          rect: rect
        });
      }

      // The box moves when the page scrolls or the window changes size, and
      // whatever hangs from it has to move too. Once a frame at most.
      var moving = false;
      function moved() {
        if (moving) return;
        moving = true;
        requestAnimationFrame(function () { moving = false; caret(); });
      }
      window.addEventListener('scroll', moved, true);
      window.addEventListener('resize', moved);

      // Going full screen, announced before it happens rather than after.
      //
      // WebKit puts the video in a window of its own and slides ours away
      // behind it. For a frame or two ours is still on screen, and everything
      // this browser draws is white — which is the pale band across the top of
      // the animation. Knowing a moment early is enough to paint it black.
      function immersed() {
        var on = !!(document.fullscreenElement || document.webkitFullscreenElement);
        window.webkit.messageHandlers.officeForms.postMessage({
          kind: 'fullscreen', on: on
        });
      }
      document.addEventListener('fullscreenchange', immersed, true);
      document.addEventListener('webkitfullscreenchange', immersed, true);

      // The asking, caught before the animation starts.
      ['requestFullscreen', 'webkitRequestFullscreen', 'webkitRequestFullScreen']
        .forEach(function (name) {
          var was = Element.prototype[name];
          if (!was) return;
          Element.prototype[name] = function () {
            window.webkit.messageHandlers.officeForms.postMessage({
              kind: 'fullscreen', on: true
            });
            return was.apply(this, arguments);
          };
        });

      document.addEventListener('focusin', caret, true);
      document.addEventListener('focusout', function () { setTimeout(caret, 0); }, true);
      document.addEventListener('mouseup', function () { setTimeout(caret, 0); }, true);
      caret();
    })();
    """
}
