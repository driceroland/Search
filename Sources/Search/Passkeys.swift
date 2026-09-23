import AuthenticationServices
import WebKit

// Passkeys from the Mac's keychain, for a browser that isn't Safari.
//
// Apple's entitlement lets Search ask for them; it doesn't let it in. macOS
// keeps a permission of its own, the way it does for the camera — "Allow
// Search to use your passkeys?" — and until a browser has asked for it,
// every passkey request a site makes as its sign-in page loads, the one that
// offers your passkey under the name field, is refused on the spot: WebKit
// hands it to AuthenticationServices, which answers that the browser isn't
// authorised. Measured 24 Sep 2026: NotAllowedError at once, the system log
// saying "Could not perform authorization" (ASAuthorizationError 1004), and
// the permission never asked for, on the one Mac everybody had tested on —
// where only a site's own "use a passkey" button had been tried.
//
// So the first time a site asks for a passkey, macOS puts the question to
// you — on a sign-in page, where it makes sense — and the site's request
// goes on once you have answered. Asked once; after that the answer is
// macOS's to keep, in System Settings.
@MainActor
enum Passkeys {
    /// Whether this Mac lets Search use its passkeys at all.
    static var access: ASAuthorizationWebBrowserPublicKeyCredentialManager.AuthorizationState {
        ASAuthorizationWebBrowserPublicKeyCredentialManager().authorizationStateForPlatformCredentials
    }

    /// Nobody has been asked yet, and this build could ask.
    static var undecided: Bool {
        Preferences.entitledToPasskeys && access == .notDetermined
    }

    /// How many times a page has waited on the question — for the bench.
    private(set) static var asked = 0

    /// Everyone who asked while the question is on screen, answered together.
    private static var waiting: [() -> Void]?

    /// Asks macOS once, then lets whoever was waiting go on — at once when
    /// there is nothing to ask. A test run never puts the question on
    /// screen: it would land on the screen of whoever is working beside it.
    static func ensure(_ then: @escaping () -> Void) {
        guard undecided else { return then() }
        asked += 1
        if Store.testing { return then() }
        if waiting != nil {
            waiting?.append(then)
            return
        }
        waiting = [then]
        ASAuthorizationWebBrowserPublicKeyCredentialManager().requestAuthorizationForPublicKeyCredentials { _ in
            DispatchQueue.main.async {
                let everyone = waiting ?? []
                waiting = nil
                everyone.forEach { $0() }
            }
        }
    }

    /// In the page, before anything of the site's runs: a request for a
    /// passkey waits for the answer to the question above, then goes on as
    /// it was made. Anything else asked of navigator.credentials — a stored
    /// password — goes straight through. Only put in while the question is
    /// still to be asked; once it is answered, pages get nothing extra.
    static let gate = """
    (function () {
      if (window.__officePasskeyGate || !window.PublicKeyCredential || !navigator.credentials) return;
      var handler = window.webkit && webkit.messageHandlers && webkit.messageHandlers.\(PasskeyGate.name);
      if (!handler) return;
      Object.defineProperty(window, '__officePasskeyGate', { value: true });
      var answered = null;
      function ask() {
        if (!answered) answered = handler.postMessage('passkeys').catch(function () {});
        return answered;
      }
      // On the prototype, not on navigator.credentials: WebKit throws that
      // object away and makes a new one whenever nothing holds it, and
      // anything set on the old one goes with it — at document start, it
      // was gone by the time the site asked.
      var proto = window.CredentialsContainer && CredentialsContainer.prototype;
      if (!proto) return;
      ['get', 'create'].forEach(function (name) {
        var original = proto[name];
        if (typeof original !== 'function') return;
        var gated = function (options) {
          var self = this, args = arguments;
          if (!options || !options.publicKey) return original.apply(self, args);
          return ask().then(function () { return original.apply(self, args); });
        };
        try { Object.defineProperty(proto, name, { value: gated, configurable: true, writable: true }); } catch (e) {}
      });
    })();
    """
}

/// The page's side of the question: answered once macOS has had its answer.
final class PasskeyGate: NSObject, WKScriptMessageHandlerWithReply {
    static let name = "officePasskeys"

    func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
    ) {
        MainActor.assumeIsolated {
            Passkeys.ensure { replyHandler(true, nil) }
        }
    }
}
