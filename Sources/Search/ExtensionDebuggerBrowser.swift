import AppKit
import WebKit

// What the browser knows that the page doesn't: its cookies, and the page as
// a stream of pictures.

@available(macOS 15.4, *)
extension ExtensionDebugger {
    // MARK: cookies

    private func store(_ tab: Tab) -> WKHTTPCookieStore { web(tab).configuration.websiteDataStore.httpCookieStore }

    /// The cookies a page at each of `urls` would send, or all there are.
    func cookies(_ tab: Tab, urls: [URL]?) async -> [String: Any] {
        let all = await store(tab).allCookies()
        let chosen = urls.map { urls in all.filter { cookie in urls.contains { Self.cookie(cookie, sentTo: $0) } } } ?? all
        return ["cookies": chosen.map(Self.json)]
    }

    nonisolated static func cookie(_ cookie: HTTPCookie, sentTo url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        let domain = cookie.domain.lowercased()
        let hostMatches = domain.hasPrefix(".") ? host == domain.dropFirst() || host.hasSuffix(domain) : host == domain
        let path = url.path.isEmpty ? "/" : url.path
        let pathMatches = path == cookie.path || path.hasPrefix(cookie.path.hasSuffix("/") ? cookie.path : cookie.path + "/")
        return hostMatches && pathMatches && (!cookie.isSecure || url.scheme == "https")
    }

    nonisolated static func json(_ cookie: HTTPCookie) -> [String: Any] {
        var out: [String: Any] = [
            "name": cookie.name, "value": cookie.value, "domain": cookie.domain, "path": cookie.path,
            "expires": cookie.expiresDate?.timeIntervalSince1970 ?? -1, "size": cookie.name.utf8.count + cookie.value.utf8.count,
            "httpOnly": cookie.isHTTPOnly, "secure": cookie.isSecure, "session": cookie.expiresDate == nil,
            "priority": "Medium", "sameParty": false, "sourceScheme": cookie.isSecure ? "Secure" : "NonSecure",
            "sourcePort": cookie.isSecure ? 443 : 80,
        ]
        switch cookie.sameSitePolicy {
        case HTTPCookieStringPolicy.sameSiteLax: out["sameSite"] = "Lax"
        case HTTPCookieStringPolicy.sameSiteStrict: out["sameSite"] = "Strict"
        default: break
        }
        return out
    }

    func setCookie(_ tab: Tab, _ params: [String: Any]) async throws -> [String: Any] {
        guard let name = params["name"] as? String, let value = params["value"] as? String else { throw Failure.invalid("name and value") }
        let address = (params["url"] as? String).flatMap(URL.init(string:))
        guard let domain = (params["domain"] as? String) ?? address?.host else { throw Failure.invalid("url or domain") }
        var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain,
                                                        .path: params["path"] as? String ?? "/"]
        if params["secure"] as? Bool == true || address?.scheme == "https" && params["secure"] == nil { properties[.secure] = "TRUE" }
        if let expires = params["expires"] as? Double, expires > 0 { properties[.expires] = Date(timeIntervalSince1970: expires) }
        if let site = params["sameSite"] as? String, site != "None" { properties[.sameSitePolicy] = site }
        guard let cookie = HTTPCookie(properties: properties) else { return ["success": false] }
        await store(tab).setCookie(cookie)
        return ["success": true]
    }

    func deleteCookies(_ tab: Tab, _ params: [String: Any]) async throws {
        guard let name = params["name"] as? String else { throw Failure.invalid("name") }
        let address = (params["url"] as? String).flatMap(URL.init(string:))
        let domain = params["domain"] as? String
        let path = params["path"] as? String
        guard address != nil || domain != nil else { throw Failure.invalid("url or domain") }
        let store = store(tab)
        for cookie in await store.allCookies() where cookie.name == name {
            let there = address.map { Self.cookie(cookie, sentTo: $0) } ?? (cookie.domain == domain)
            if there, path == nil || cookie.path == path { await store.deleteCookie(cookie) }
        }
    }

    // MARK: Page.startScreencast

    /// A picture each time the page looks different, one at a time: the
    /// next waits for the extension to say it has the last (or a second).
    func startScreencast(_ session: Session, _ tab: Tab, _ params: [String: Any]) {
        session.casting?.cancel()
        session.castAcked = 0
        var shot: [String: Any] = ["format": params["format"] as? String ?? "jpeg", "quality": params["quality"] as? Double ?? 80]
        let width = (params["maxWidth"] as? Double) ?? 0, height = (params["maxHeight"] as? Double) ?? 0
        session.casting = Task { [weak self, weak session] in
            var number = 0
            var last = ""
            while !Task.isCancelled, let self, let session, let tab = session.tab {
                let size = self.web(tab).bounds.size
                if size.width > 0, size.height > 0 {
                    var scale = 1.0
                    if width > 0 { scale = min(scale, width / Double(size.width)) }
                    if height > 0 { scale = min(scale, height / Double(size.height)) }
                    shot["clip"] = ["x": 0, "y": 0, "width": Double(size.width), "height": Double(size.height), "scale": scale]
                    if let picture = try? await self.screenshot(tab, shot), let data = picture["data"] as? String, data != last {
                        last = data
                        number += 1
                        let view = (try? await self.op(tab, .page, 1, "viewport", [:])) ?? [:]
                        self.emit(session, "Page.screencastFrame", [
                            "data": data, "sessionId": number,
                            "metadata": ["offsetTop": 0, "pageScaleFactor": 1, "deviceWidth": Double(size.width), "deviceHeight": Double(size.height),
                                         "scrollOffsetX": view["scrollX"] as? Double ?? 0, "scrollOffsetY": view["scrollY"] as? Double ?? 0,
                                         "timestamp": Date().timeIntervalSince1970]])
                        for _ in 0..<20 where session.castAcked < number && !Task.isCancelled {
                            try? await Task.sleep(for: .milliseconds(50))
                        }
                    }
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }
}
