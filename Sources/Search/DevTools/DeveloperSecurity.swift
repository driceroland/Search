import Foundation
import Security

/// The Security panel's model, as Chrome DevTools' Security panel builds it:
/// the origins the Network panel recorded, grouped into the main origin,
/// secure, non-secure and unknown ones; each origin's connection and
/// certificate; and the page's mixed content. The view is
/// DeveloperSecurityView.swift.
enum DeveloperSecurity {
    /// The sidebar's sections, in Chrome's order.
    enum Group: String, CaseIterable, Identifiable {
        case main = "Main origin"
        case secure = "Secure origins"
        case nonSecure = "Non-secure origins"
        case unknown = "Unknown / canceled"
        var id: String { rawValue }
    }

    /// WebKit's `Security.Security` from a response: the connection's
    /// protocol and cipher, and a summary of the server's certificate.
    struct ResponseSecurity: Equatable {
        var networkProtocol: String?
        var cipher: String?
        var certificate: ResponseCertificate?

        init(networkProtocol: String? = nil, cipher: String? = nil, certificate: ResponseCertificate? = nil) {
            self.networkProtocol = networkProtocol
            self.cipher = cipher
            self.certificate = certificate
        }

        /// The bridge's `security` object (DeveloperToolsBridgeScript-source.js); nil when it has nothing.
        init?(_ raw: [String: Any]?) {
            guard let raw else { return nil }
            networkProtocol = (raw["protocol"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            cipher = (raw["cipher"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            certificate = ResponseCertificate(raw["certificate"] as? [String: Any])
            if networkProtocol == nil, cipher == nil, certificate == nil { return nil }
        }
    }

    /// WebKit's `Security.Certificate`: its dates are seconds since 1970.
    struct ResponseCertificate: Equatable {
        var subject: String?
        var validFrom: Date?
        var validUntil: Date?
        var names: [String]

        init(subject: String?, validFrom: Date?, validUntil: Date?, names: [String]) {
            self.subject = subject
            self.validFrom = validFrom
            self.validUntil = validUntil
            self.names = names
        }

        init?(_ raw: [String: Any]?) {
            guard let raw else { return nil }
            subject = raw["subject"] as? String
            validFrom = (raw["validFrom"] as? Double).map { Date(timeIntervalSince1970: $0) }
            validUntil = (raw["validUntil"] as? Double).map { Date(timeIntervalSince1970: $0) }
            names = (raw["dnsNames"] as? [String] ?? []) + (raw["ipAddresses"] as? [String] ?? [])
            if subject == nil, validFrom == nil, validUntil == nil, names.isEmpty { return nil }
        }
    }

    /// One origin the page loaded from, as a sidebar row.
    struct Origin: Identifiable, Equatable {
        /// `scheme://host[:port]`, as Chrome titles it.
        let origin: String
        let scheme: String
        let host: String
        var group: Group
        var requestIDs: [String]
        /// The first connection details a response from this origin carried.
        var security: ResponseSecurity?
        var id: String { origin }
    }

    // MARK: Origins

    /// `scheme://host[:port]` of a URL, with the port only when it isn't the
    /// scheme's default. Nil for URLs without a network origin (data:, blob:, about:…).
    static func origin(of url: String) -> (origin: String, scheme: String, host: String)? {
        guard let components = URLComponents(string: url), let scheme = components.scheme?.lowercased(),
              ["http", "https", "ws", "wss"].contains(scheme),
              let host = components.host?.lowercased(), !host.isEmpty else { return nil }
        let defaults = ["http": 80, "https": 443, "ws": 80, "wss": 443]
        let shownHost = host.contains(":") && !host.hasPrefix("[") ? "[" + host + "]" : host
        var text = scheme + "://" + shownHost
        if let port = components.port, port != defaults[scheme] { text += ":\(port)" }
        return (text, scheme, host)
    }

    static func isSecureScheme(_ scheme: String) -> Bool { scheme == "https" || scheme == "wss" }

    /// The origins of the recorded requests, the page's own first, the rest
    /// by name. An origin is secure or not by its scheme once any of its
    /// requests got a response; one whose requests all failed or were
    /// canceled before that is unknown.
    static func origins(_ requests: [DeveloperToolsSession.Request], page: URL?) -> [Origin] {
        let main = page.flatMap { origin(of: $0.absoluteString)?.origin }
        var order: [String] = []
        var byOrigin: [String: Origin] = [:]
        var answered: Set<String> = []
        var failed: Set<String> = []
        for request in requests {
            guard let parts = origin(of: request.url) else { continue }
            if byOrigin[parts.origin] == nil {
                order.append(parts.origin)
                byOrigin[parts.origin] = Origin(origin: parts.origin, scheme: parts.scheme, host: parts.host,
                                                group: .unknown, requestIDs: [], security: nil)
            }
            byOrigin[parts.origin]?.requestIDs.append(request.id)
            if byOrigin[parts.origin]?.security == nil, let security = request.security {
                byOrigin[parts.origin]?.security = security
            }
            if request.status != nil || request.security != nil { answered.insert(parts.origin) }
            else if request.failure != nil { failed.insert(parts.origin) }
        }
        if let main, byOrigin[main] == nil, let page, let parts = origin(of: page.absoluteString) {
            order.insert(main, at: 0)
            byOrigin[main] = Origin(origin: main, scheme: parts.scheme, host: parts.host, group: .main,
                                    requestIDs: [], security: nil)
        }
        var result: [Origin] = []
        for key in order {
            guard var item = byOrigin[key] else { continue }
            if key == main {
                item.group = .main
            } else if failed.contains(key) && !answered.contains(key) {
                item.group = .unknown
            } else {
                item.group = isSecureScheme(item.scheme) ? .secure : .nonSecure
            }
            result.append(item)
        }
        return result.sorted { left, right in
            if (left.group == .main) != (right.group == .main) { return left.group == .main }
            return left.origin < right.origin
        }
    }

    /// One sidebar heading and its origins.
    struct Section: Identifiable {
        let group: Group
        let origins: [Origin]
        var id: Group { group }
    }

    /// The origins under each sidebar heading that has any, in Chrome's order.
    static func grouped(_ origins: [Origin]) -> [Section] {
        Group.allCases.compactMap { group in
            let members = origins.filter { $0.group == group }
            return members.isEmpty ? nil : Section(group: group, origins: members)
        }
    }

    /// Network's filter for an origin's requests, as Chrome's link sets it.
    static func networkFilter(for origin: Origin) -> String { "domain:" + origin.host }

    // MARK: Mixed content

    /// The requests an https page made over plain http or ws. http://localhost
    /// and loopback addresses are trustworthy, as in Chrome, and don't count.
    static func mixedContent(_ requests: [DeveloperToolsSession.Request], page: URL?) -> [DeveloperToolsSession.Request] {
        guard let scheme = page?.scheme?.lowercased(), isSecureScheme(scheme) else { return [] }
        return requests.filter { request in
            guard let parts = origin(of: request.url), !isSecureScheme(parts.scheme) else { return false }
            return !isLoopback(parts.host)
        }
    }

    static func isLoopback(_ host: String) -> Bool {
        let host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return host == "localhost" || host.hasSuffix(".localhost") || host.hasPrefix("127.") || host == "::1"
    }

    // MARK: Summary

    /// The lock at the top of Chrome's overview.
    enum Summary: Equatable {
        case secure, notSecure, brokenHTTPS, mixedContent

        var title: String {
            switch self {
            case .secure: "This page is secure (valid HTTPS)"
            case .notSecure, .mixedContent: "This page is not secure"
            case .brokenHTTPS: "This page is not secure (broken HTTPS)"
            }
        }

        var isSecure: Bool { self == .secure }
    }

    /// `trusted` is the system's verdict on the page's certificate, nil while
    /// it is still being asked; `mixed` is whether the page loaded anything over plain http.
    static func summary(page: URL?, trusted: Bool?, mixed: Bool) -> Summary {
        guard let scheme = page?.scheme?.lowercased(), isSecureScheme(scheme) else { return .notSecure }
        if trusted == false { return .brokenHTTPS }
        return mixed ? .mixedContent : .secure
    }

    // MARK: Connection

    /// Chrome's Connection section: Protocol, Key exchange, Cipher.
    struct Connection: Equatable {
        var networkProtocol: String?
        var keyExchange: String?
        var cipher: String?

        /// "The connection to this site is encrypted and authenticated using …", as Chrome lists them.
        var settings: String {
            let parts = [networkProtocol, keyExchange, cipher].compactMap { $0 }
            switch parts.count {
            case 0: return ""
            case 1: return parts[0]
            case 2: return parts[0] + " and " + parts[1]
            default: return parts.dropLast().joined(separator: ", ") + ", and " + parts[parts.count - 1]
            }
        }
    }

    /// WebKit's protocol ("TLS 1.3", "TLSv1.2") and IANA cipher suite name
    /// ("TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256", "TLS_AES_128_GCM_SHA256"),
    /// split as Chrome shows them: TLS 1.2, ECDHE_RSA, AES_128_GCM. A TLS 1.3
    /// suite names no key exchange.
    static func connection(protocol networkProtocol: String?, cipher: String?) -> Connection {
        var result = Connection()
        if let raw = networkProtocol?.trimmingCharacters(in: .whitespaces), !raw.isEmpty {
            var text = raw
            for prefix in ["TLSv", "TLS"] where text.hasPrefix(prefix) {
                text = "TLS " + text.dropFirst(prefix.count).trimmingCharacters(in: CharacterSet(charactersIn: " _"))
                break
            }
            text = text.replacingOccurrences(of: "_", with: ".")
            result.networkProtocol = text
        }
        guard var suite = cipher?.trimmingCharacters(in: .whitespaces).uppercased(), !suite.isEmpty else { return result }
        if suite.hasPrefix("TLS_") { suite.removeFirst(4) }
        var bulk = suite
        if let with = suite.range(of: "_WITH_") {
            result.keyExchange = String(suite[..<with.lowerBound])
            bulk = String(suite[with.upperBound...])
        }
        // AEAD ciphers name their handshake hash last; the rest their MAC.
        for hash in ["_SHA384", "_SHA256", "_SHA"] where bulk.hasSuffix(hash) {
            let stem = String(bulk.dropLast(hash.count))
            if stem.contains("GCM") || stem.contains("POLY1305") || stem.contains("CCM") {
                bulk = stem
            } else {
                bulk = stem + " with HMAC-" + (hash == "_SHA" ? "SHA1" : String(hash.dropFirst()))
            }
            break
        }
        result.cipher = bulk
        return result
    }

    // MARK: Certificate

    /// Chrome's Certificate section.
    struct CertificateFields: Equatable {
        var subject: String?
        var alternativeNames: [String]
        var validFrom: Date?
        var validUntil: Date?
        var issuer: String?
    }

    /// The fields Chrome shows, read with SecCertificateCopyValues from the
    /// certificate WKWebView's serverTrust holds.
    static func fields(_ certificate: SecCertificate) -> CertificateFields {
        let keys = [kSecOIDX509V1SubjectName, kSecOIDX509V1IssuerName, kSecOIDX509V1ValidityNotBefore,
                    kSecOIDX509V1ValidityNotAfter, kSecOIDSubjectAltName] as CFArray
        let values = SecCertificateCopyValues(certificate, keys, nil) as? [String: Any] ?? [:]
        func value(_ key: CFString) -> Any? {
            (values[key as String] as? [String: Any])?[kSecPropertyKeyValue as String]
        }
        func entries(_ key: CFString) -> [(label: String, value: String)] {
            (value(key) as? [[String: Any]] ?? []).compactMap { entry in
                guard let label = entry[kSecPropertyKeyLabel as String] as? String,
                      let text = entry[kSecPropertyKeyValue as String] as? String else { return nil }
                return (label, text)
            }
        }
        func name(_ key: CFString) -> String? {
            let parts = entries(key)
            // Common name, else organization, else organizational unit.
            for oid in [kSecOIDCommonName as String, kSecOIDOrganizationName as String, kSecOIDOrganizationalUnitName as String] {
                if let match = parts.first(where: { $0.label == oid }) { return match.value }
            }
            return parts.first?.value
        }
        func date(_ key: CFString) -> Date? {
            switch value(key) {
            case let date as Date: return date
            case let number as NSNumber: return Date(timeIntervalSinceReferenceDate: number.doubleValue)
            case let text as String: return Double(text).map { Date(timeIntervalSinceReferenceDate: $0) }
            default: return nil
            }
        }
        var common: CFString?
        SecCertificateCopyCommonName(certificate, &common)
        let names = entries(kSecOIDSubjectAltName).filter { $0.label != "Critical" }.map(\.value)
        return CertificateFields(subject: (common as String?) ?? name(kSecOIDX509V1SubjectName),
                                 alternativeNames: names,
                                 validFrom: date(kSecOIDX509V1ValidityNotBefore),
                                 validUntil: date(kSecOIDX509V1ValidityNotAfter),
                                 issuer: name(kSecOIDX509V1IssuerName))
    }

    /// The fields WebKit's response summary has: no issuer.
    static func fields(_ certificate: ResponseCertificate) -> CertificateFields {
        CertificateFields(subject: certificate.subject, alternativeNames: certificate.names,
                          validFrom: certificate.validFrom, validUntil: certificate.validUntil, issuer: nil)
    }

    /// Dates as Chrome writes them: "Mon, 22 Nov 2026 19:20:21 GMT".
    static func formatted(_ date: Date?) -> String {
        guard let date else { return "—" }
        return chromeDate.string(from: date)
    }

    private static let chromeDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter
    }()
}
