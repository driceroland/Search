import AppKit
import Combine
import WebKit

// Handing over: one of your tabs' sign-ins, copied into an agent's page for a while.
extension Agent {
    /// The cookies a page of `host` is sent: those set for it, and for a
    /// domain it is under. Nothing for a sibling or a parent's other
    /// children, and nothing past its date.
    static func sent(_ cookie: HTTPCookie, to host: String) -> Bool {
        if let expires = cookie.expiresDate, expires <= Date() { return false }
        let domain = cookie.domain.lowercased()
        if domain.hasPrefix(".") {
            let bare = String(domain.dropFirst())
            return host == bare || host.hasSuffix("." + bare)
        }
        return host == domain
    }

    /// What a page keeps for itself besides cookies, where many sites keep
    /// their sign-in: its origin's localStorage and sessionStorage.
    struct Storage {
        var origin = ""
        var local: [String: String] = [:]
        var session: [String: String] = [:]
        var count: Int { local.count + session.count }

        /// A page address's origin as `location.origin` says it.
        static func origin(of url: URL?) -> String? {
            guard let url, let scheme = url.scheme?.lowercased(), let host = url.host(percentEncoded: false)?.lowercased() else { return nil }
            let port = url.port.flatMap { (scheme, $0) == ("http", 80) || (scheme, $0) == ("https", 443) ? nil : ":\($0)" } ?? ""
            return "\(scheme)://\(host.contains(":") ? "[\(host)]" : host)\(port)"
        }
    }

    /// Read in a world of Shy's own, where the page's scripts can't stand
    /// in for localStorage and hand over something else.
    private static let handoverWorld = WKContentWorld.world(name: "shy-handover")

    /// What a handover of this tab would copy: its address, the cookies its
    /// page is sent, and its main frame's storage.
    static func offer(_ tab: Tab, _ found: @escaping (URL, [HTTPCookie], Storage) -> Void) {
        // Never a private tab's, whatever asked.
        guard !tab.shy, tab.store.isPersistent,
              let url = Agent.web(tab.address?.absoluteString), let host = url.host()?.lowercased() else { return }
        let read = """
            (() => {
              const all = s => { const o = {}; for (let i = 0; i < s.length; i++) { const k = s.key(i); o[k] = s.getItem(k); } return o; };
              try { return JSON.stringify({ origin: location.origin, local: all(localStorage), session: all(sessionStorage) }); }
              catch (e) { return JSON.stringify({ origin: location.origin, local: {}, session: {} }); }
            })()
            """
        tab.web.evaluateJavaScript(read, in: nil, in: handoverWorld) { result in
            MainActor.assumeIsolated {
                var storage = Storage()
                if case .success(let json as String) = result,
                   let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
                   let origin = object["origin"] as? String,
                   // The page the tab shows, not one it has since left.
                   Storage.origin(of: url) == origin {
                    storage = Storage(origin: origin,
                                      local: object["local"] as? [String: String] ?? [:],
                                      session: object["session"] as? [String: String] ?? [:])
                }
                tab.store.httpCookieStore.getAllCookies { all in
                    MainActor.assumeIsolated { found(url, all.filter { sent($0, to: host) }, storage) }
                }
            }
        }
    }

    /// A page of the session's own, with a copy of `cookies` and `storage`
    /// and nothing else of yours, at `url`. Nil, with why, when there's no
    /// room.
    @discardableResult
    func handOver(_ url: URL, cookies: [HTTPCookie], storage: Storage = Storage(), acts: Bool, asks: Bool, minutes: Int) -> String? {
        guard running else { return "Agents are off in Settings › Agents" }
        guard pages.count < Agent.most else { return "The agent has \(Agent.most) pages open — close one first" }
        guard let host = url.host()?.lowercased() else { return "Not a page on the web" }
        let page = make()
        page.handover = Handover(site: Vault.registrable(host), host: host, cookies: cookies.count,
                                 stored: storage.count, acts: acts, asks: asks,
                                 ends: Date().addingTimeInterval(TimeInterval(minutes * 60)))
        if storage.count > 0 { seed(page, storage) }
        page.note("You handed over \(host): \(cookies.count) cookies, \(storage.count) stored items, \(acts ? (asks ? "asking before each click" : "clicks allowed") : "read only"), \(minutes) min")
        let store = page.web.configuration.websiteDataStore.httpCookieStore
        let group = DispatchGroup()
        for cookie in cookies {
            group.enter()
            store.setCookie(cookie) { group.leave() }
        }
        group.notify(queue: .main) {
            page.web.load(URLRequest(url: url))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + TimeInterval(minutes * 60)) { [weak self, weak page] in
            guard let self, let page, page.live != nil else { return }
            self.end(page, "its time was up")
        }
        return nil
    }

    /// The copied storage written into the page's origin before any of
    /// its scripts run, in its main frame only: a frame from elsewhere, or
    /// the page once it has left for another origin, gets none of it.
    private func seed(_ page: Page, _ storage: Storage) {
        // Each value a JSON string inside a JSON string, parsed by the page's
        // engine: nothing stored can close the literal and become script,
        // and a key like "__proto__" stays a key.
        func literal(_ value: Any) -> String {
            let json = String(data: (try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])) ?? Data("null".utf8), encoding: .utf8) ?? "null"
            return String(data: (try? JSONSerialization.data(withJSONObject: json, options: [.fragmentsAllowed])) ?? Data("\"null\"".utf8), encoding: .utf8) ?? "\"null\""
        }
        let source = """
            (() => {
              if (location.origin !== JSON.parse(\(literal(storage.origin)))) return;
              const put = (s, items) => { for (const [k, v] of Object.entries(items)) { try { s.setItem(k, v); } catch (e) {} } };
              put(localStorage, JSON.parse(\(literal(storage.local))));
              put(sessionStorage, JSON.parse(\(literal(storage.session))));
            })();
            """
        page.seeding = storage.origin
        page.web.configuration.userContentController.addUserScript(
            WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: Agent.world))
    }

    /// Seeded once: the copy is the page's own from its first load there.
    func seeded(_ page: Page) {
        guard let origin = page.seeding, Storage.origin(of: page.web.url) == origin else { return }
        page.seeding = nil
        page.web.configuration.userContentController.removeAllUserScripts()
    }

    /// The copied sign-in deleted: the page stays, signed out. A page
    /// staying where it is is loaded again once the copy is gone: one that
    /// read a token from storage holds it in memory, and would go on using
    /// it until it did.
    func end(_ page: Page, _ why: String, then: (() -> Void)? = nil) {
        guard page.live != nil else { then?(); return }
        page.handover?.over = why
        page.seeding = nil
        page.web.configuration.userContentController.removeAllUserScripts()
        page.note("Sign-in removed: \(why)")
        pending.filter { $0.page == page.id }.forEach { $0.reply(false) }
        let store = page.web.configuration.websiteDataStore
        store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {
            MainActor.assumeIsolated {
                if let then { then() } else { page.web.reloadFromOrigin() }
            }
        }
    }
}
