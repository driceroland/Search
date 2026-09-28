import CryptoKit
import Foundation

// Signing in with OpenRouter: the one provider that lets another app use
// your own account, through its documented flow (OAuth with PKCE, no secret
// of ours). You sign in on openrouter.ai, in a tab, and say yes; it sends
// the tab back to our callback address with a one-time code, which is
// traded here for a key of your own — billed to your credits, limited as
// you set it on openrouter.ai — and kept like one you pasted (AIKeys).
//
// The callback is never loaded. Search is the browser the flow runs in,
// so it takes the address as the tab is about to go there — in the tab it
// opened for the flow, while that flow is waiting, coming from openrouter.ai,
// and for ten minutes at most, as long as OpenRouter's code lasts. Anywhere
// else the address is an ordinary page. The verifier that makes the code
// worth anything lives only in memory, for the flow: a code slipped into a
// tab by someone else is worth nothing without it.

@MainActor
enum AISignIn {
    static let callback = URL(string: "https://officecommun.com/search/ai/callback")!

    /// openrouter.ai itself, where you sign in — in a test run, the stand-in.
    static var site: URL {
        if Store.testing, let mock = AIProvider.mock { return mock.appendingPathComponent("openRouter-site/") }
        return URL(string: "https://openrouter.ai/")!
    }

    private struct Flow {
        let tab: Tab.ID
        let verifier: String
        let started: Date
    }

    private static var flow: Flow?

    /// Said when a sign-in has ended: whether a key is now kept, and what
    /// went wrong if not.
    static var ended: ((Bool, String?) -> Void)?

    /// Whether one is under way, for Settings.
    static var waiting: Bool { flow.map { Date().timeIntervalSince($0.started) < 600 } ?? false }

    static func start(in browser: Browser) {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return }
        let verifier = Passkeys.text(Data(bytes))
        let challenge = Passkeys.text(Data(SHA256.hash(data: Data(verifier.utf8))))
        var parts = URLComponents(url: site.appendingPathComponent("auth"), resolvingAgainstBaseURL: false)
        parts?.queryItems = [
            URLQueryItem(name: "callback_url", value: callback.absoluteString),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "key_label", value: "Search"),
        ]
        guard let url = parts?.url else { return }
        let tab = browser.open(url, foreground: true)
        flow = Flow(tab: tab.id, verifier: verifier, started: Date())
    }

    /// The callback, about to load in `tab`: taken — true — when it is the
    /// flow's. The tab is closed once the key is kept.
    static func intercept(_ url: URL, mainFrame: Bool, in tab: Tab?, browser: Browser) -> Bool {
        guard url.scheme?.lowercased() == "https", url.host()?.lowercased() == callback.host(),
              url.path == callback.path, mainFrame,
              let flow, let tab, tab.id == flow.tab
        else { return false }
        self.flow = nil
        let code = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "code" }?.value ?? ""
        // Sent here by openrouter.ai, and not by a page the tab wandered to.
        let from = (tab.built?.url ?? tab.pageAddress)?.host()?.lowercased()
        guard Date().timeIntervalSince(flow.started) < 600 else { return finish(false, "The sign-in took too long — try again.", tab, browser) }
        guard from == site.host()?.lowercased(), !code.isEmpty, code.count < 1024 else {
            return finish(false, "The sign-in didn't come back from OpenRouter.", tab, browser)
        }
        Task { @MainActor in
            do {
                let key = try await AIClient.shared.exchange(code: code, verifier: flow.verifier)
                switch AIKeys.save(key, for: .openRouter) {
                case .kept: _ = finish(true, nil, tab, browser)
                case .unavailable: _ = finish(false, "This copy of Search can't keep keys (it isn't the signed release).", tab, browser)
                case .failed: _ = finish(false, "The keychain refused the key.", tab, browser)
                }
            } catch {
                _ = finish(false, error.localizedDescription, tab, browser)
            }
        }
        return true
    }

    @discardableResult
    private static func finish(_ kept: Bool, _ why: String?, _ tab: Tab, _ browser: Browser) -> Bool {
        if kept { browser.close(tab) }
        browser.announce(kept ? "Signed in with OpenRouter" : (why ?? "The sign-in didn't work"))
        ended?(kept, why)
        return true
    }
}
