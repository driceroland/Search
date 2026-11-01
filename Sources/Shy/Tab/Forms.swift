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
        // The forms script runs in the top page only; anything else is not it.
        guard message.frameInfo.isMainFrame,
              let body = message.body as? [String: Any],
              let kind = body["kind"] as? String
        else { return }
        // Where the message came from, as WebKit knows it: the tab's address
        // may already be the next site's by the time it is read.
        let from = message.frameInfo.securityOrigin.host.lowercased()
        // A name or password longer than any real one is not a sign-in.
        let user = String((body["user"] as? String ?? "").prefix(512))
        let password = body["password"] as? String ?? ""
        MainActor.assumeIsolated {
            switch kind {
            case "form":
                tab?.foundSignIn()
            case "submit":
                guard password.utf8.count <= 1024 else { return }
                tab?.sentSignIn(user: user, password: password, from: from)
            case "name":
                tab?.gaveName(user)
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
                if let rect = body["rect"] as? [String: Double],
                   let x = rect["x"], let y = rect["y"], let w = rect["w"], let h = rect["h"] {
                    tab?.fieldFocused(CGRect(x: x, y: y, width: w, height: h), passwords: body["passwords"] as? Bool ?? true,
                                      name: body["name"] as? Bool ?? false)
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
    /// the entitlement, as releases are, this is on, and Shy carries out
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
    static let withoutPasskeys = Scripts.load("forms-without-passkeys")

    static let script = Scripts.load("forms")
}
