import Foundation

/// Which of the store's cookies a request to an address carries (RFC 6265),
/// as Search's extensions decide it (ExtensionFetch), for the cookies the
/// Application panel lists for the page.
enum DeveloperCookieRules {

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
}
