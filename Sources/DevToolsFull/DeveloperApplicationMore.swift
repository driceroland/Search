import Foundation

// The pure parts of the Application panel's Back/forward cache, Reporting
// API, Frames and Storage additions: reading response headers, guessing why
// a page was not kept for Back, and splitting storage usage by type.
// DeveloperApplicationMoreTests covers them.

// MARK: Response headers

/// The headers of a document's response, as Network recorded them.
struct DeveloperResponseHeaders: Equatable {
    typealias Header = DeveloperRequestDetails.Header
    let pairs: [[String]]

    init(_ headers: [Header]) { pairs = headers.map { [$0.name, $0.value] } }
    init(pairs: [[String]]) { self.pairs = pairs.filter { $0.count == 2 } }

    /// Every value of a header, case-insensitively, joined as one would
    /// fold repeated fields: with ", ".
    func value(_ name: String) -> String? {
        let values = pairs.filter { $0[0].caseInsensitiveCompare(name) == .orderedSame }.map { $0[1] }
        return values.isEmpty ? nil : values.joined(separator: ", ")
    }
}

enum DeveloperHeaderParsing {
    /// Splits `text` at `separator` where it is not inside quotes, (), [] or {}.
    static func split(_ text: String, at separator: Character) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        var quoted = false
        var escaped = false
        for character in text {
            if quoted {
                current.append(character)
                if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { quoted = false }
                continue
            }
            switch character {
            case "\"": quoted = true
            case "(", "[", "{": depth += 1
            case ")", "]", "}": depth = max(0, depth - 1)
            default: break
            }
            if character == separator, depth == 0 {
                parts.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        parts.append(current)
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func unquoted(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2, trimmed.hasPrefix("\""), trimmed.hasSuffix("\"") else { return trimmed }
        var result = ""
        var escaped = false
        for character in trimmed.dropFirst().dropLast() {
            if escaped { result.append(character); escaped = false } else if character == "\\" { escaped = true } else { result.append(character) }
        }
        return result
    }

    /// A Cache-Control header's directives, lower-cased, without their values.
    static func cacheDirectives(_ header: String?) -> Set<String> {
        guard let header else { return [] }
        return Set(split(header, at: ",").map { directive in
            String(directive.split(separator: "=", maxSplits: 1).first ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        }.filter { !$0.isEmpty })
    }

    /// COOP or COEP: the policy and its report-to endpoint, if any.
    /// `same-origin; report-to="coop"` is ("same-origin", "coop").
    static func isolationPolicy(_ header: String?) -> (value: String, reportTo: String?)? {
        guard let header, let first = split(header, at: ",").first else { return nil }
        let parts = split(first, at: ";")
        guard let value = parts.first.map(unquoted), !value.isEmpty else { return nil }
        var reportTo: String?
        for parameter in parts.dropFirst() {
            let pair = parameter.split(separator: "=", maxSplits: 1).map(String.init)
            if pair.count == 2, pair[0].trimmingCharacters(in: .whitespaces).lowercased() == "report-to" {
                reportTo = unquoted(pair[1])
            }
        }
        return (value.lowercased(), reportTo)
    }

    /// A Content-Security-Policy header's directives, policy by policy.
    static func contentSecurityPolicy(_ header: String?) -> [[(name: String, value: String)]] {
        guard let header else { return [] }
        return header.split(separator: ",").map { policy in
            policy.split(separator: ";").compactMap { directive -> (name: String, value: String)? in
                let words = directive.trimmingCharacters(in: .whitespaces)
                    .split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
                guard let name = words.first?.lowercased(), !name.isEmpty else { return nil }
                return (name, words.count > 1 ? words[1].trimmingCharacters(in: .whitespaces) : "")
            }
        }.filter { !$0.isEmpty }
    }

    /// Permissions-Policy (`camera=(), geolocation=(self "https://a.example")`)
    /// or the older Feature-Policy (`camera 'none'; geolocation 'self'`), as
    /// feature and allowlist pairs in the order the header lists them.
    static func permissionsPolicy(_ header: String?, legacy: Bool = false) -> [(feature: String, allowlist: String)] {
        guard let header else { return [] }
        if legacy {
            return header.split(separator: ";").compactMap { item in
                let words = item.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1).map(String.init)
                guard let feature = words.first, !feature.isEmpty else { return nil }
                return (feature.lowercased(), words.count > 1 ? words[1] : "'self'")
            }
        }
        return split(header, at: ",").compactMap { item in
            let pair = item.split(separator: "=", maxSplits: 1).map(String.init)
            guard let feature = pair.first?.trimmingCharacters(in: .whitespaces), !feature.isEmpty else { return nil }
            var list = pair.count > 1 ? pair[1].trimmingCharacters(in: .whitespaces) : "*"
            if list.hasPrefix("("), list.hasSuffix(")") { list = String(list.dropFirst().dropLast()) }
            let members = list.split(separator: " ").map { unquoted(String($0)) }
            return (feature.lowercased(), members.isEmpty ? "none" : members.joined(separator: " "))
        }
    }
}

// MARK: Reporting API endpoints



// MARK: Reports


// MARK: Back/forward cache




// MARK: Storage usage

/// Chrome's usage pie, as a bar: each kind of storage's share.
struct DeveloperStorageBreakdown: Equatable {
    struct Part: Equatable {
        let name: String
        /// Nil when the size could not be measured.
        let bytes: Double?
        /// Whether WebKit counts this kind in navigator.storage.estimate().
        let inQuota: Bool
    }

    struct Segment: Equatable {
        let name: String
        let bytes: Double
        let fraction: Double
    }

    static let unattributed = "Other"

    let segments: [Segment]
    let total: Double

    /// `usage` is the estimate's total. What it holds beyond the measured
    /// kinds it counts is shown as Other.
    init(usage: Double?, parts: [Part]) {
        let measured = parts.compactMap { part in part.bytes.map { (part.name, max(0, $0), part.inQuota) } }
        let quotaParts = measured.filter { $0.2 }.reduce(0) { $0 + $1.1 }
        let other = max(0, (usage ?? 0) - quotaParts)
        var items = measured.filter { $0.1 > 0 }.map { ($0.0, $0.1) }
        if other > 0 { items.append((Self.unattributed, other)) }
        let total = items.reduce(0) { $0 + $1.1 }
        self.total = total
        segments = total > 0 ? items.map { Segment(name: $0.0, bytes: $0.1, fraction: $0.1 / total) } : []
    }
}

// MARK: Frames

/// The frame view's sections, as Chrome draws them: Document, Security &
/// Isolation and Permissions Policy, each label and value rows.
enum DeveloperFrameDetails {
    struct Section: Equatable {
        let title: String
        let rows: [[String]]
    }

    struct Context: Equatable {
        var secure: Bool?
        var crossOriginIsolated: Bool?
        /// The features document.featurePolicy (or permissionsPolicy) allows, when WebKit has one.
        var allowedFeatures: [String]?
        var owner: String?
    }

    static func sections(_ node: DeveloperFrameNode, context: Context, headers: DeveloperResponseHeaders?) -> [Section] {
        var document = [["URL", String(node.url.prefix(4096))], ["Origin", node.origin.isEmpty ? "—" : node.origin]]
        if let name = node.name { document.append(["Name", name]) }
        if node.depth > 0 { document.append(["Owner element", context.owner ?? "—"]) }
        document.append(["MIME type", node.mimeType.isEmpty ? "—" : node.mimeType])
        document.append(["Child frames", String(node.children.count)])
        document.append(["Resources", String(node.resources.count)])

        func yesNo(_ value: Bool?) -> String { value.map { $0 ? "Yes" : "No" } ?? "—" }
        var security = [["Secure context", yesNo(context.secure ?? node.secure)],
                        ["Cross-origin isolated", yesNo(context.crossOriginIsolated)]]
        let missing = headers == nil ? "Not recorded" : "None"
        func policy(_ name: String) -> String {
            guard let parsed = DeveloperHeaderParsing.isolationPolicy(headers?.value(name)) else { return missing }
            return parsed.value + (parsed.reportTo.map { " (report-to: \($0))" } ?? "")
        }
        security.append(["Cross-Origin-Opener-Policy", policy("Cross-Origin-Opener-Policy")])
        if headers?.value("Cross-Origin-Opener-Policy-Report-Only") != nil {
            security.append(["COOP (report only)", policy("Cross-Origin-Opener-Policy-Report-Only")])
        }
        security.append(["Cross-Origin-Embedder-Policy", policy("Cross-Origin-Embedder-Policy")])
        if headers?.value("Cross-Origin-Embedder-Policy-Report-Only") != nil {
            security.append(["COEP (report only)", policy("Cross-Origin-Embedder-Policy-Report-Only")])
        }
        if let resource = headers?.value("Cross-Origin-Resource-Policy") { security.append(["Cross-Origin-Resource-Policy", resource]) }
        let csp = headers?.value("Content-Security-Policy")
        security.append(["Content-Security-Policy", csp.map { String($0.prefix(4096)) } ?? missing])
        if let reportOnly = headers?.value("Content-Security-Policy-Report-Only") {
            security.append(["CSP (report only)", String(reportOnly.prefix(4096))])
        }

        var permissions: [[String]] = []
        if let allowed = context.allowedFeatures {
            permissions.append(["Allowed features", allowed.isEmpty ? "None" : allowed.sorted().joined(separator: ", ")])
        }
        let header = headers?.value("Permissions-Policy")
        let legacy = headers?.value("Feature-Policy")
        let declared = header != nil ? DeveloperHeaderParsing.permissionsPolicy(header)
            : DeveloperHeaderParsing.permissionsPolicy(legacy, legacy: true)
        for item in declared { permissions.append([item.feature, item.allowlist]) }
        if permissions.isEmpty {
            permissions.append(["Permissions-Policy", headers == nil ? "Not recorded" : "None set"])
        }
        return [Section(title: "Document", rows: document),
                Section(title: "Security & Isolation", rows: security),
                Section(title: "Permissions Policy", rows: permissions)]
    }

    /// Where a subframe sits beneath the top frame: its index among its
    /// parent's frames at each level, as window.frames numbers them.
    static func path(to id: String, in root: DeveloperFrameNode) -> [Int]? {
        if root.id == id { return [] }
        for (index, child) in root.children.enumerated() {
            if let rest = path(to: id, in: child) { return [index] + rest }
        }
        return nil
    }

    /// The resource folders the frame view lists, in Chrome's order.
    static let folderOrder = ["Documents", "Scripts", "Stylesheets", "Images", "Fonts", "Fetch and XHR", "Other"]

    static func orderedGroups(_ node: DeveloperFrameNode) -> [DeveloperFrameNode.ResourceGroup] {
        node.groups.sorted { (folderOrder.firstIndex(of: $0.title) ?? 99) < (folderOrder.firstIndex(of: $1.title) ?? 99) }
    }

    /// Scripts, stylesheets and documents open in Sources; the rest in Network.
    static func opensInSources(_ type: String) -> Bool { ["Script", "StyleSheet", "Document"].contains(type) }
}

// MARK: Notifications


// MARK: Cookie issues

/// The cookie problems Chrome's "Only show cookies with an issue" keeps:
/// SameSite=None without Secure, which browsers following the current
/// cookie standard reject, and a Secure cookie on an origin that isn't
/// HTTPS (nor localhost), which it is never sent to.
enum DeveloperCookieIssues {
    static func issue(sameSite: String, secure: Bool, origin: String?) -> String? {
        if sameSite.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare("none") == .orderedSame, !secure {
            return "This cookie has SameSite=None but not Secure, so browsers that follow the current standard reject it. Add Secure and serve it over HTTPS."
        }
        if secure, let origin, URL(string: origin)?.scheme?.lowercased() == "http",
           !DeveloperApplication.potentiallyTrustworthy(origin) {
            return "This cookie is Secure, so it is not sent to \(origin), which isn't HTTPS."
        }
        return nil
    }

    /// A row of the cookie table (DeveloperApplication.cookieColumns):
    /// Secure is column 7, ticked or empty, and SameSite column 8.
    static func issue(row values: [String], origin: String?) -> String? {
        guard values.count > 8 else { return nil }
        return issue(sameSite: values[8], secure: !values[7].trimmingCharacters(in: .whitespaces).isEmpty,
                     origin: origin)
    }
}

// MARK: Extension storage

