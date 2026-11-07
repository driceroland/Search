import Foundation
import WebKit

// An extension's own fetch to a site it has been granted, sent as Chrome
// sends it: with the site's SameSite=Lax cookies.
//
// WebKit counts every request an extension's page or worker makes to
// another site as cross-site, so a site's SameSite=Lax cookies never go
// with it. Claude in Chrome's panel asks claude.ai/api/bootstrap with
// credentials, gets no session, and says "Log in" although its tabs are
// signed in (#837). Chrome counts a host the extension has been granted as
// same-site.
//
// So the shim sends such a fetch — credentials "include", from the
// extension's own page or worker, to another http(s) origin — here, over a
// native port. WebKit says which extension opened the port; no page or
// other extension can speak for it. Here, and only for an address that
// extension has been granted (checked again on every redirect: a hop to an
// address it isn't granted fails the fetch), it goes out with the cookies a
// top-level request would carry — Lax and Strict alike, as Chrome sends
// them for a granted host — from the store the tabs of the extension's
// window use, never a private tab's, and comes back in chunks as it
// arrives, so a stream of server-sent events stays a stream. What the site
// sets comes back into that store, held to the rules a browser holds a
// response to (accepts). Anything else is answered "pass", and WebKit's own
// fetch runs.
//
// A site that frames itself in the panel (ChatGPT's) is not helped: its
// frame's requests are WebKit's, and WebKit's own fix for them isn't in a
// shipping macOS yet.
//
// `extensions.credentialedFetch` (default on, not in Settings) turns it
// off, from the next request.

@available(macOS 15.4, *)
@MainActor
enum ExtensionFetch {
    static let name = ExtensionShims.application + ".fetch"
    static let key = "extensions.credentialedFetch"
    static var on: Bool { Store.settings.object(forKey: key) as? Bool ?? true }

    /// Test runs only: what went through here, for Tests/panel_lax.py —
    /// addresses, statuses and cookie names, never a value.
    static var trace: [[String: Any]] = []
    static func note(_ entry: [String: Any]) {
        guard Store.testing else { return }
        trace.append(entry)
        if trace.count > 200 { trace.removeFirst(trace.count - 200) }
    }

    private static var open: [ObjectIdentifier: Exchange] = [:]

    static func connect(_ port: WKWebExtension.MessagePort, from context: WKWebExtensionContext) {
        let exchange = Exchange(port: port, context: context)
        let key = ObjectIdentifier(exchange)
        open[key] = exchange
        exchange.onEnd = { open[key] = nil }
    }

    /// The extension's own grant for this address, as Chrome's same-site
    /// rule reads it: explicit, or by its manifest.
    static func granted(_ url: URL, to context: WKWebExtensionContext) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return false }
        let status = context.permissionStatus(for: url)
        return status == .grantedExplicitly || status == .grantedImplicitly
    }

    // MARK: - which store

    /// The store whose cookies go: that of the windows the request can
    /// belong to — the ones whose side panel shows the extension, else every
    /// window — only when they all share one. One controller serves every
    /// profile, and a worker or a popup doesn't say which window it is for:
    /// with windows of different profiles or spaces open, it isn't known
    /// whose sign-in to send, and nothing is ("pass"). Never a private
    /// tab's store: panelStore never returns one.
    static func store(for context: WKWebExtensionContext) -> WKWebsiteDataStore? {
        let showing = Browsers.all.filter { browser in
            if browser.sidePanelShown, case .page(let id, _, _)? = browser.sidePanel { return id == context.uniqueIdentifier }
            return false
        }
        let candidates = showing.isEmpty ? Browsers.all : showing
        return only(candidates.map { $0.panelStore($0.spaceID) })
    }

    /// The one store, if they are all that one.
    nonisolated static func only<T: AnyObject>(_ stores: [T]) -> T? {
        guard let first = stores.first, stores.allSatisfy({ $0 === first }) else { return nil }
        return first
    }

    // MARK: - which cookies go

    /// Whether a top-level request to `url` would carry `cookie`, SameSite
    /// aside. Never a partitioned one: its partition is another site's top
    /// level, never this request's.
    nonisolated static func sends(_ cookie: HTTPCookie, to url: URL, at now: Date) -> Bool {
        guard let host = url.host?.lowercased(), !host.isEmpty else { return false }
        if partitioned(cookie) { return false }
        if let expires = cookie.expiresDate, expires <= now { return false }
        if cookie.isSecure && url.scheme?.lowercased() != "https" { return false }
        guard domainMatches(host, cookie.domain) else { return false }
        return pathMatches(rawPath(url), cookie.path)
    }

    /// The request's path as sent, percent-encoded, its trailing slash kept.
    nonisolated static func rawPath(_ url: URL) -> String {
        let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? ""
        return path.isEmpty ? "/" : path
    }

    /// RFC 6265 domain-match: a host-only cookie (no leading dot) is its host
    /// alone; a domain cookie its domain and every name under it.
    nonisolated static func domainMatches(_ host: String, _ cookieDomain: String) -> Bool {
        let domain = cookieDomain.lowercased()
        guard domain.hasPrefix(".") else { return host == domain }
        let bare = String(domain.dropFirst())
        return !bare.isEmpty && (host == bare || host.hasSuffix(domain))
    }

    /// RFC 6265 path-match.
    nonisolated static func pathMatches(_ path: String, _ cookiePath: String) -> Bool {
        let prefix = cookiePath.isEmpty ? "/" : cookiePath
        return path == prefix || (path.hasPrefix(prefix) && (prefix.hasSuffix("/") || path.dropFirst(prefix.count).first == "/"))
    }

    /// A cookie kept for one top-level site (CHIPS, or WebKit's own
    /// partitioning): Foundation names its partition StoragePartition.
    nonisolated static func partitioned(_ cookie: HTTPCookie) -> Bool {
        for (key, value) in cookie.properties ?? [:] where key.rawValue.lowercased().contains("partition") {
            if let text = value as? String, text.isEmpty { continue }
            return true
        }
        return false
    }

    // MARK: - which cookies are kept

    /// One Set-Cookie line, read: the cookie, and whether it named a Domain
    /// (Foundation keeps that only as a leading dot it may also add itself).
    struct SetCookie {
        let cookie: HTTPCookie
        let namedDomain: Bool
    }

    /// The cookies a response sets, one Set-Cookie at a time; a
    /// `Partitioned` one is left out — Foundation would keep it unpartitioned.
    nonisolated static func setCookies(_ header: String, for url: URL) -> [SetCookie] {
        // URLSession joins several Set-Cookie headers with commas; an
        // Expires date has commas too, never followed by "name=".
        let pattern = try! NSRegularExpression(pattern: #",(?=\s*[^;,=\s]+=)"#)
        let range = NSRange(header.startIndex..., in: header)
        var pieces: [String] = []
        var start = header.startIndex
        for match in pattern.matches(in: header, range: range) {
            guard let comma = Range(match.range, in: header) else { continue }
            pieces.append(String(header[start..<comma.lowerBound]))
            start = comma.upperBound
        }
        pieces.append(String(header[start...]))
        return pieces.flatMap { piece -> [SetCookie] in
            let attributes = piece.split(separator: ";").dropFirst().map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            if attributes.contains(where: { $0 == "partitioned" || $0.hasPrefix("partitioned=") }) { return [] }
            let named = attributes.contains { $0.hasPrefix("domain=") && $0.count > "domain=".count }
            return HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": piece], for: url).map { SetCookie(cookie: $0, namedDomain: named) }
        }
    }

    /// Whether a browser would take this cookie from a response from `url`
    /// (RFC 6265bis): Foundation's parser checks none of it, and would let
    /// evil.example set a cookie for google.com, or for all of .com.
    /// `stored`: the cookies of that name already kept, for the rule that a
    /// response not over https never replaces nor removes a Secure one.
    /// `isSuffix`: the public suffix test (nil: none known, so a named
    /// Domain is taken only when it is the host itself).
    nonisolated static func accepts(_ set: SetCookie, from url: URL, stored: [HTTPCookie],
                                    isSuffix: ((String) -> Bool)?) -> Bool {
        let cookie = set.cookie
        guard let host = url.host?.lowercased(), !host.isEmpty else { return false }
        let secureResponse = url.scheme?.lowercased() == "https"
        let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let address = host.contains(":") || host.allSatisfy { $0.isNumber || $0 == "." }
        // Its domain is the host, or one the host is under.
        guard domain == host || host.hasSuffix("." + domain) else { return false }
        if set.namedDomain {
            // An address takes host-only cookies only.
            if address { return false }
            if domain != host {
                // Never a public suffix (com, co.uk, github.io), and never
                // without a list to tell.
                guard domain.contains("."), let isSuffix, !isSuffix(domain) else { return false }
            }
        }
        // Secure only from https.
        if cookie.isSecure && !secureResponse { return false }
        // Prefixes.
        if cookie.name.lowercased().hasPrefix("__secure-") && !(cookie.isSecure && secureResponse) { return false }
        if cookie.name.lowercased().hasPrefix("__host-") && !(cookie.isSecure && secureResponse && !set.namedDomain && cookie.path == "/") { return false }
        // Leave Secure cookies alone: not replaced, nor removed, by a
        // response that isn't https.
        if !secureResponse {
            for old in stored where old.isSecure && old.name == cookie.name {
                let oldDomain = old.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                let overlap = oldDomain == domain || oldDomain.hasSuffix("." + domain) || domain.hasSuffix("." + oldDomain)
                if overlap && (pathMatches(cookie.path, old.path) || pathMatches(old.path, cookie.path)) { return false }
            }
        }
        return true
    }

    static func cookies(for url: URL, in store: WKWebsiteDataStore) async -> [HTTPCookie] {
        let now = Date()
        return await store.httpCookieStore.allCookies().filter { sends($0, to: url, at: now) }
    }

    /// What a response from a granted address sets, into the store; each
    /// cookie, and each removal, only as `accepts` allows.
    static func keep(_ response: HTTPURLResponse, in store: WKWebsiteDataStore, for context: WKWebExtensionContext?) async {
        guard let url = response.url, let context, granted(url, to: context),
              let header = response.value(forHTTPHeaderField: "Set-Cookie") else { return }
        let sets = setCookies(header, for: url)
        guard !sets.isEmpty else { return }
        let jar = store.httpCookieStore
        let all = await jar.allCookies()
        let isSuffix = Passkeys.publicSuffix.map { test in { (name: String) in test(name as CFString) } }
        let now = Date()
        for set in sets {
            let cookie = set.cookie
            let named = all.filter { $0.name == cookie.name && !partitioned($0) }
            guard accepts(set, from: url, stored: named, isSuffix: isSuffix) else {
                note(["refused": cookie.name, "from": url.host ?? ""])
                continue
            }
            if let expires = cookie.expiresDate, expires <= now {
                for old in named where old.domain.lowercased() == cookie.domain.lowercased() && old.path == cookie.path {
                    await jar.deleteCookie(old)
                }
            } else {
                await jar.setCookie(cookie)
            }
        }
    }

    // MARK: - the request

    /// Headers the page may not set, as fetch forbids them; the browser
    /// sets its own.
    nonisolated static let forbidden: Set<String> = [
        "cookie", "cookie2", "host", "origin", "referer", "content-length", "connection", "keep-alive", "te", "trailer",
        "transfer-encoding", "upgrade", "via", "expect", "date", "dnt", "accept-encoding", "accept-charset",
        "access-control-request-headers", "access-control-request-method",
        "x-http-method", "x-http-method-override", "x-method-override",
    ]

    /// A method fetch may send: a token, and not one fetch forbids.
    nonisolated static func allowed(method: String) -> Bool {
        let token = method.range(of: #"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$"#, options: .regularExpression) != nil
        return token && !["CONNECT", "TRACE", "TRACK"].contains(method.uppercased())
    }

    /// The page's headers that may go: none fetch forbids.
    nonisolated static func sendable(_ name: String) -> Bool {
        // A token only: a name with a line break in it went out as two
        // header lines, an Origin or a Cookie of the extension's making.
        guard name.range(of: #"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$"#, options: .regularExpression) != nil else { return false }
        let lower = name.lowercased()
        return !forbidden.contains(lower) && !lower.hasPrefix("sec-") && !lower.hasPrefix("proxy-")
    }

    /// Headers that follow a redirect to another origin: the CORS-safelisted
    /// ones, and the browser's own. Authorization and the page's custom
    /// headers stay with the origin they were meant for, as in Chrome.
    nonisolated static let followsAcrossOrigins: Set<String> = [
        "accept", "accept-language", "content-language", "content-type", "user-agent", "origin",
    ]

    nonisolated static func sameOrigin(_ a: URL?, _ b: URL?) -> Bool {
        guard let a, let b else { return false }
        return a.scheme?.lowercased() == b.scheme?.lowercased() && a.host?.lowercased() == b.host?.lowercased()
            && (a.port ?? defaultPort(a)) == (b.port ?? defaultPort(b))
    }

    nonisolated private static func defaultPort(_ url: URL) -> Int { url.scheme?.lowercased() == "https" ? 443 : 80 }

    /// A redirect's next request: across origins, only what follows.
    nonisolated static func hop(_ next: URLRequest, from previous: URL?) -> URLRequest {
        guard !sameOrigin(previous, next.url) else { return next }
        var request = next
        for name in (next.allHTTPHeaderFields ?? [:]).keys where !followsAcrossOrigins.contains(name.lowercased()) {
            request.setValue(nil, forHTTPHeaderField: name)
        }
        // As in Chrome: once across origins, the request says it came from
        // no origin in particular.
        if next.value(forHTTPHeaderField: "Origin") != nil { request.setValue("null", forHTTPHeaderField: "Origin") }
        return request
    }

    @MainActor
    final class Exchange: NSObject, URLSessionDataDelegate {
        private let port: WKWebExtension.MessagePort
        private weak var context: WKWebExtensionContext?
        private let origin: String
        private var session: URLSession?
        private var task: URLSessionDataTask?
        private var store: WKWebsiteDataStore?
        private var id: String?
        private var mode = "follow"
        private var redirected = false
        private var stopped = false
        private var ended = false
        var onEnd: (() -> Void)?

        init(port: WKWebExtension.MessagePort, context: WKWebExtensionContext) {
            self.port = port
            self.context = context
            self.origin = "\(Extensions.scheme)://\(context.uniqueIdentifier)"
            super.init()
            port.messageHandler = { [weak self] message, _ in
                MainActor.assumeIsolated { self?.take(message) }
            }
            port.disconnectHandler = { [weak self] _ in
                MainActor.assumeIsolated { self?.end(tellingPort: false) }
            }
        }

        private func take(_ message: Any?) {
            guard let message = message as? [String: Any] else { return }
            // A worker's shim asks every port to an app whether it has
            // arrived (see ExtensionNative).
            if let word = message["__searchNative"] {
                if (word as? String) == "here?" { post(["__searchNative": "here"]) }
                return
            }
            guard let asked = message["fetch"] as? String else { return }
            // The shim says it again until it hears back: a repeat is only
            // acknowledged, never sent twice.
            post(["accepted": asked])
            guard id == nil else { return }
            id = asked
            mode = message["redirect"] as? String ?? "follow"
            let method = message["method"] as? String ?? "GET"
            guard allowed(method: method) else { return fail() }
            guard ExtensionFetch.on, let context,
                  let address = message["url"] as? String, let url = URL(string: address),
                  ExtensionFetch.granted(url, to: context),
                  ["follow", "manual", "error"].contains(mode),
                  let store = ExtensionFetch.store(for: context)
            else {
                ExtensionFetch.note(["pass": message["url"] as? String ?? "", "extension": context?.uniqueIdentifier ?? ""])
                return pass()
            }
            self.store = store
            var request = URLRequest(url: url)
            request.httpMethod = method
            for pair in message["headers"] as? [[String]] ?? [] where pair.count == 2 && sendable(pair[0])
                && !pair[1].contains(where: { $0 == "\r" || $0 == "\n" || $0 == "\0" }) {
                request.addValue(pair[1], forHTTPHeaderField: pair[0])
            }
            request.setValue(origin, forHTTPHeaderField: "Origin")
            if let agent = message["userAgent"] as? String { request.setValue(agent, forHTTPHeaderField: "User-Agent") }
            if let body = message["body"] as? String { request.httpBody = Data(base64Encoded: body) }
            let unsigned = request
            Task { @MainActor in
                var request = unsigned
                await self.sign(&request)
                guard !self.ended else { return }
                let configuration = URLSessionConfiguration.ephemeral
                configuration.httpShouldSetCookies = false
                configuration.httpCookieAcceptPolicy = .never
                configuration.httpCookieStorage = nil
                configuration.urlCache = nil
                // A stream of server-sent events can be quiet for long; the
                // page ends it (abort, or its reader let go) when it wants.
                configuration.timeoutIntervalForRequest = 24 * 3600
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
                self.session = session
                let task = session.dataTask(with: request)
                self.task = task
                task.resume()
            }
        }

        /// The cookies for the request's address (granted: sign is only
        /// reached for one).
        private func sign(_ request: inout URLRequest) async {
            request.setValue(nil, forHTTPHeaderField: "Cookie")
            guard let url = request.url, let context, let store, ExtensionFetch.granted(url, to: context) else { return }
            let cookies = await ExtensionFetch.cookies(for: url, in: store)
            for (k, v) in HTTPCookie.requestHeaderFields(with: cookies) { request.setValue(v, forHTTPHeaderField: k) }
            ExtensionFetch.note(["native": url.absoluteString, "method": request.httpMethod ?? "GET", "origin": origin,
                                 "extension": context.uniqueIdentifier, "cookies": cookies.map(\.name).sorted(),
                                 "store": Browsers.all.contains { $0.panelStore($0.spaceID) === store } ? "space" : "other"])
        }

        nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            nonisolated(unsafe) let handler = completionHandler
            Task { @MainActor in
                if let store = self.store { await ExtensionFetch.keep(response, in: store, for: self.context) }
                // "manual" and "error" stop here: the redirect itself is the
                // answer (an opaque one, as Chrome gives), or a failure.
                guard self.mode == "follow" else {
                    self.stopped = true
                    if self.mode == "manual" {
                        self.post(["head": ["opaqueRedirect": true, "url": response.url?.absoluteString ?? ""]])
                        self.end(tellingPort: false)
                    } else {
                        self.fail()
                    }
                    return handler(nil)
                }
                // Only on to an address the extension is granted too:
                // anything else fails the fetch, nothing of it read.
                guard let next = request.url, let context = self.context, ExtensionFetch.granted(next, to: context) else {
                    ExtensionFetch.note(["redirectRefused": request.url?.absoluteString ?? ""])
                    self.stopped = true
                    self.fail()
                    return handler(nil)
                }
                var hop = ExtensionFetch.hop(request, from: response.url)
                await self.sign(&hop)
                self.redirected = true
                handler(hop)
            }
        }

        nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
            nonisolated(unsafe) let handler = completionHandler
            Task { @MainActor in
                guard !self.stopped else { return handler(.cancel) }
                guard let http = response as? HTTPURLResponse else { self.fail(); return handler(.cancel) }
                if let store = self.store { await ExtensionFetch.keep(http, in: store, for: self.context) }
                ExtensionFetch.note(["answered": http.url?.absoluteString ?? "", "status": http.statusCode])
                var headers: [[String]] = []
                for (k, v) in http.allHeaderFields {
                    guard let k = k as? String, let v = v as? String else { continue }
                    // Set-Cookie is the browser's; the body arrives decoded.
                    if ["set-cookie", "set-cookie2", "content-encoding", "content-length"].contains(k.lowercased()) { continue }
                    headers.append([k, v])
                }
                self.post(["head": ["status": http.statusCode, "statusText": HTTPURLResponse.localizedString(forStatusCode: http.statusCode),
                                    "headers": headers, "url": http.url?.absoluteString ?? "", "redirected": self.redirected]])
                handler(.allow)
            }
        }

        nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            MainActor.assumeIsolated { self.post(["chunk": data.base64EncodedString()]) }
        }

        nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            MainActor.assumeIsolated {
                guard !self.ended else { return }
                if error == nil { self.post(["end": true]); self.end(tellingPort: false) } else { self.fail() }
            }
        }

        private func pass() {
            post(["pass": true])
            end(tellingPort: false)
        }

        private func post(_ message: [String: Any]) {
            guard !port.isDisconnected else { return }
            port.sendMessage(message, completionHandler: nil)
        }

        private func fail() {
            post(["failed": true])
            end(tellingPort: false)
        }

        private func end(tellingPort: Bool) {
            guard !ended else { return }
            ended = true
            task?.cancel()
            session?.invalidateAndCancel()
            session = nil
            if tellingPort, !port.isDisconnected { port.disconnect() }
            onEnd?()
        }
    }
}
