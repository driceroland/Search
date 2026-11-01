import Combine
import ImageIO
import SwiftUI
import WebKit

// Sign-ins on the page: found, sent, filled (Forms.swift is the page's side).
extension Tab {
    func foundSignIn() { onSignIn?(self) }

    /// From the page, in CSS pixels; passed on in points. Page zoom is the
    /// only scale between the two that matters here.
    /// `passwords`: a box of a sign-in with a password, not one only for
    /// passkeys. `name`: the name box of a sign-in that asks for the
    /// password on the next page.
    func fieldFocused(_ rect: CGRect?, passwords: Bool = true, name: Bool = false) {
        guard let rect else {
            onField?(self, nil, false, false)
            return
        }
        let zoom = built?.pageZoom ?? 1
        onField?(self, CGRect(
            x: rect.minX * zoom, y: rect.minY * zoom,
            width: rect.width * zoom, height: rect.height * zoom
        ), passwords, name)
    }

    func gaveName(_ user: String) {
        guard !user.isEmpty, user.count <= 256,
              let host = pageAddress?.host()?.lowercased()
        else { return }
        named = (Vault.registrable(host), user, Date())
    }

    /// The name sent on the step before, if it was this site's and recent.
    func givenName() -> String? {
        guard let named, Date().timeIntervalSince(named.at) < 300,
              let host = pageAddress?.host()?.lowercased(),
              Vault.registrable(host) == named.site
        else { return nil }
        return named.user
    }

    func sentSignIn(user: String, password: String, from origin: String) {
        // The host now, while the page is still the sign-in page: a moment
        // later it may be somewhere else entirely, and that is not where
        // the password belongs. And only if the page that sent it is that
        // page: an old document's word arriving after the next site
        // arrived is not the next site's.
        guard let host = pageAddress?.host()?.lowercased(), host == origin else { return }
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        // A password page with no name on it: the name is the one the step
        // before was sent with.
        let user = user.isEmpty ? givenName() ?? "" : user
        sent = (bare, user, password, pageAddress?.scheme?.lowercased() == "http", Date())
    }

    /// The page has moved on — a new document has loaded, or the sign-in
    /// fields have gone. If a password went out recently and there is no
    /// longer a box for it, that is a sign-in that took.
    ///
    /// A new document is judged at once. Fields that a page removed by
    /// itself are given a moment first: a sign-in built into the page closes
    /// its form the instant you press the button and puts it back if the
    /// server says no — and offering in between is offering a password that
    /// may be wrong.
    func settleSignIn(navigated: Bool = true) {
        guard let sent else { return }
        guard Date().timeIntervalSince(sent.at) < 45 else {
            self.sent = nil
            return
        }
        guard navigated else {
            let stamp = sent.at
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                // Only if nothing newer went out in the meantime.
                guard let self, self.sent?.at == stamp else { return }
                self.settleSignIn(navigated: true)
            }
            return
        }
        web.evaluateInShy("!!(window.__officeForms && window.__officeForms.hasPassword())") { [weak self] still in
            MainActor.assumeIsolated {
                guard let self, let sent = self.sent else { return }
                // The box is still there: a refused sign-in, or the second
                // step of one. Kept for a moment longer, in case the page is
                // still on its way.
                if (still as? Bool) == true { return }
                self.sent = nil
                self.named = nil
                self.onCredentials?(self, sent.host, sent.user, sent.password, sent.clear)
            }
        }
    }

    /// Puts a remembered name and password where a person would have typed
    /// them. Nothing is echoed back and nothing is written down here.
    /// `done`, when given, hears back `false` for the one case worth saying
    /// something about: the sign-in fields that were there a moment ago,
    /// when this was offered, are gone by the time it actually runs.
    /// With `onlyOn`, the page checks for itself, when the script runs, that
    /// it is still that scheme and host: a document that changed after the
    /// last check on this side gets nothing.
    func fill(user: String, password: String, onlyOn page: URL? = nil, done: ((Bool) -> Void)? = nil) {
        var still = ""
        if let page {
            guard let scheme = page.scheme?.lowercased(), let host = page.host()?.lowercased() else { done?(false); return }
            still = "location.protocol === `\(escape(scheme)):` && location.hostname.toLowerCase() === `\(escape(host))` && "
        }
        web.evaluateInShy(
            "\(still)window.__officeForms && window.__officeForms.fill(`\(escape(user))`, `\(escape(password))`)"
        ) { result in
            done?((result as? Bool) ?? false)
        }
    }

    /// A first step's name alone, picked from the accounts under its box.
    /// With `onlyOn`, checked by the page itself, as `fill` does.
    func fillName(_ user: String, onlyOn page: URL? = nil, done: ((Bool) -> Void)? = nil) {
        var still = ""
        if let page {
            guard let scheme = page.scheme?.lowercased(), let host = page.host()?.lowercased() else { done?(false); return }
            still = "location.protocol === `\(escape(scheme)):` && location.hostname.toLowerCase() === `\(escape(host))` && "
        }
        web.evaluateInShy(
            "\(still)window.__officeForms && window.__officeForms.name(`\(escape(user))`)"
        ) { result in
            done?((result as? Bool) ?? false)
        }
    }

    func picked(selector: String, label: String, note: String) {
        onPick?(self, selector, label, note)
    }

    /// Show one hidden thing while the pointer rests on its row in the list.
    func peek(_ selector: String, keeping css: String) {
        web.evaluateInShy(
            "window.__officeVeil && window.__officeVeil.peek(`\(escape(css))`, `\(escape(selector))`)"
        )
    }

    func unpeek(_ css: String) {
        web.evaluateInShy("window.__officeVeil && window.__officeVeil.unpeek(`\(escape(css))`)")
    }

    private func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")
    }

    func pickingEnded() { onPickEnd?(self) }

    func pickingFailed(_ reason: String) { onPickTrouble?(self, reason) }
}
