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

struct DeveloperReportingEndpoint: Equatable {
    let name: String
    let url: String
    /// "Reporting-Endpoints", "Report-To" or "CSP report-uri".
    let source: String
}

enum DeveloperReportingHeaders {
    /// Endpoints from `Reporting-Endpoints` (`default="https://…", csp="/r"`),
    /// `Report-To` (JSON objects separated by commas) and the CSP's own
    /// `report-uri`, with relative addresses resolved against the document.
    static func endpoints(_ headers: DeveloperResponseHeaders, document: URL?) -> [DeveloperReportingEndpoint] {
        var found: [DeveloperReportingEndpoint] = []
        func resolve(_ text: String) -> String {
            guard let document, let url = URL(string: text, relativeTo: document) else { return text }
            return url.absoluteURL.absoluteString
        }
        if let header = headers.value("Reporting-Endpoints") {
            for member in DeveloperHeaderParsing.split(header, at: ",") {
                let pair = member.split(separator: "=", maxSplits: 1).map(String.init)
                guard pair.count == 2 else { continue }
                let name = pair[0].trimmingCharacters(in: .whitespaces)
                let address = DeveloperHeaderParsing.unquoted(pair[1].split(separator: ";").first.map(String.init) ?? "")
                guard !name.isEmpty, !address.isEmpty else { continue }
                found.append(.init(name: name, url: resolve(address), source: "Reporting-Endpoints"))
            }
        }
        if let header = headers.value("Report-To"),
           let data = ("[" + header + "]").data(using: .utf8),
           let groups = try? JSONSerialization.jsonObject(with: data) as? [Any] {
            for case let group as [String: Any] in groups {
                let name = group["group"] as? String ?? "default"
                for case let endpoint as [String: Any] in group["endpoints"] as? [Any] ?? [] {
                    guard let address = endpoint["url"] as? String, !address.isEmpty else { continue }
                    found.append(.init(name: name, url: resolve(address), source: "Report-To"))
                }
            }
        }
        for policy in DeveloperHeaderParsing.contentSecurityPolicy(headers.value("Content-Security-Policy"))
            + DeveloperHeaderParsing.contentSecurityPolicy(headers.value("Content-Security-Policy-Report-Only")) {
            for directive in policy where directive.name == "report-uri" {
                for address in directive.value.split(separator: " ") {
                    found.append(.init(name: "report-uri", url: resolve(String(address)), source: "CSP report-uri"))
                }
            }
        }
        var seen = Set<[String]>()
        return found.filter { seen.insert([$0.name, $0.url, $0.source]).inserted }
    }
}

// MARK: Reports

/// A report the page's ReportingObserver (or a securitypolicyviolation
/// event) saw.
struct DeveloperReport: Equatable, Identifiable {
    let id: Int
    let type: String
    let url: String
    /// Milliseconds since 1970.
    let time: Double
    let source: String
    /// The report body, flattened: label and value pairs.
    let body: [[String]]

    var blockedURL: String? { body.first { $0[0] == "blockedURL" }?[1] }
    var directive: String? { body.first { $0[0] == "effectiveDirective" }?[1] }

    /// Reports in the order seen. A CSP violation both the observer and the
    /// event saw within two seconds is listed once, as the observer's.
    static func parse(_ raw: [Any]) -> [DeveloperReport] {
        var reports: [DeveloperReport] = []
        for case let item as [String: Any] in raw.prefix(1000) {
            var body: [[String]] = []
            func flatten(_ value: Any?, prefix: String) {
                if let object = value as? [String: Any] {
                    for key in object.keys.sorted() { flatten(object[key], prefix: prefix.isEmpty ? key : prefix + "." + key) }
                } else if let value, !(value is NSNull), !prefix.isEmpty {
                    let text = (value as? String) ?? "\(value)"
                    body.append([prefix, String(text.prefix(2048))])
                }
            }
            flatten(item["body"], prefix: "")
            reports.append(DeveloperReport(id: reports.count, type: item["type"] as? String ?? "unknown",
                                           url: String((item["url"] as? String ?? "").prefix(4096)),
                                           time: (item["time"] as? NSNumber)?.doubleValue ?? 0,
                                           source: item["source"] as? String ?? "ReportingObserver", body: body))
        }
        let observed = reports.filter { $0.source == "ReportingObserver" && $0.type == "csp-violation" }
        return reports.filter { report in
            guard report.source != "ReportingObserver", report.type == "csp-violation" else { return true }
            return !observed.contains { other in
                other.url == report.url && other.blockedURL == report.blockedURL
                    && other.directive == report.directive && abs(other.time - report.time) <= 2000
            }
        }
    }
}

// MARK: Back/forward cache

/// What the page showed before the test left it: what its early script
/// counted, what Network recorded of its document, and what is on the page.
struct DeveloperBackForwardCacheSignals: Equatable {
    /// The counting script ran before the page's own scripts. When it came
    /// late, listeners added before it are not counted.
    var early = false
    var probed = false
    var unloadListeners = 0
    var unloadHandler = false
    var beforeUnloadListeners = 0
    var openSockets = 0
    var openPeerConnections = 0
    var liveCaptureTracks = 0
    var openBroadcastChannels = 0
    var activeTransactions = 0
    var playingMedia = 0
    var hasOpener = false
    /// Nil when Network has no record of the main document.
    var cacheControl: String?
    var method: String?
    var status: Int?
    var documentRecorded = false

    /// The page's snapshot (see DeveloperApplication-probe.js), or nil when it had none.
    init(probe: [String: Any]?, page: [String: Any]?, document: DeveloperRequestDetails?) {
        func count(_ key: String, _ from: [String: Any]?) -> Int { (from?[key] as? NSNumber)?.intValue ?? 0 }
        if let probe {
            probed = true
            early = probe["early"] as? Bool == true
            unloadListeners = count("unload", probe)
            beforeUnloadListeners = count("beforeunload", probe)
            openSockets = count("sockets", probe)
            openPeerConnections = count("peers", probe)
            liveCaptureTracks = count("capture", probe)
            openBroadcastChannels = count("channels", probe)
            activeTransactions = count("transactions", probe)
        }
        unloadHandler = page?["onunload"] as? Bool == true
        playingMedia = count("media", page)
        hasOpener = page?["opener"] as? Bool == true
        if let document {
            documentRecorded = true
            cacheControl = DeveloperResponseHeaders(document.responseHeaders).value("Cache-Control")
            method = document.method
            status = document.status
        }
    }

    init() {}
}

struct DeveloperBackForwardCacheReason: Equatable {
    enum Kind: String { case likely = "Likely", possible = "Possible" }
    let kind: Kind
    let title: String
    let detail: String
}

enum DeveloperBackForwardCacheAdvisor {
    /// What might have kept WebKit from caching the page. WebKit does not
    /// say why it didn't; these are what the page did that WebKit has
    /// treated as blockers, the likeliest first.
    static func reasons(_ signals: DeveloperBackForwardCacheSignals) -> [DeveloperBackForwardCacheReason] {
        var reasons: [DeveloperBackForwardCacheReason] = []
        func add(_ kind: DeveloperBackForwardCacheReason.Kind, _ title: String, _ detail: String) {
            reasons.append(.init(kind: kind, title: title, detail: detail))
        }
        let directives = DeveloperHeaderParsing.cacheDirectives(signals.cacheControl)
        if directives.contains("no-store") {
            add(.likely, "The main document has Cache-Control: no-store",
                "WebKit may not keep pages whose document must not be stored. Header: " + (signals.cacheControl ?? ""))
        }
        if let method = signals.method, method.uppercased() != "GET" {
            add(.likely, "The main document was the response to a \(method.uppercased()) request",
                "Pages loaded from a form submission are reloaded rather than restored.")
        }
        if let status = signals.status, !(200..<400).contains(status) {
            add(.possible, "The main document's status was \(status)", "Error pages are not always kept for Back.")
        }
        if signals.liveCaptureTracks > 0 {
            add(.likely, "The page is using the camera, microphone or screen (\(signals.liveCaptureTracks) live tracks)",
                "Pages capturing media are not kept.")
        }
        if signals.openPeerConnections > 0 {
            add(.likely, "\(signals.openPeerConnections) open WebRTC connection\(plural(signals.openPeerConnections))",
                "RTCPeerConnections that are not closed can keep a page out of the cache.")
        }
        if signals.openSockets > 0 {
            add(.possible, "\(signals.openSockets) open WebSocket\(plural(signals.openSockets))",
                "Close sockets on pagehide and reopen them on pageshow.")
        }
        if signals.activeTransactions > 0 {
            add(.possible, "\(signals.activeTransactions) IndexedDB transaction\(plural(signals.activeTransactions)) in progress",
                "A page that leaves while a transaction is running may not be kept.")
        }
        if signals.unloadListeners > 0 || signals.unloadHandler {
            let count = signals.unloadListeners + (signals.unloadHandler ? 1 : 0)
            add(.possible, "\(count) unload handler\(plural(count))",
                "Use pagehide instead: unload handlers make pages ineligible in other browsers and can in WebKit.")
        }
        if signals.beforeUnloadListeners > 0 {
            add(.possible, "\(signals.beforeUnloadListeners) beforeunload handler\(plural(signals.beforeUnloadListeners))",
                "Add beforeunload handlers only while there are unsaved changes.")
        }
        if signals.openBroadcastChannels > 0 {
            add(.possible, "\(signals.openBroadcastChannels) open BroadcastChannel\(plural(signals.openBroadcastChannels))",
                "Close channels on pagehide.")
        }
        if signals.playingMedia > 0 {
            add(.possible, "\(signals.playingMedia) audio or video element\(plural(signals.playingMedia)) playing",
                "Media playing as the page is left can keep it out of the cache.")
        }
        if signals.hasOpener {
            add(.possible, "The page has an opener", "A page another window holds a reference to may not be kept.")
        }
        return reasons
    }

    /// What the reasons can't see, said alongside them.
    static func caveats(_ signals: DeveloperBackForwardCacheSignals) -> [String] {
        var notes = ["WebKit does not report why a page was not cached. These are possible reasons found on the page, not WebKit's own."]
        if !signals.probed {
            notes.append("The page’s listeners, sockets and channels were not counted: the counting script could not run in it.")
        } else if !signals.early {
            notes.append("The counting script started after the page did, so handlers and sockets made before it are missed. Reload and test again.")
        }
        if !signals.documentRecorded {
            notes.append("Network has no record of the main document, so its headers were not checked. Reload with DevTools open.")
        }
        return notes
    }

    private static func plural(_ count: Int) -> String { count == 1 ? "" : "s" }
}

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

/// An event Background services › Notifications logged while recording
/// (DeveloperApplicationScript-notifications.js).
struct DeveloperNotificationEvent: Equatable, Identifiable {
    let id: Int
    /// Milliseconds since 1970.
    let time: Double
    let name: String
    let origin: String
    let title: String
    /// The event's metadata: the notification's options, and where it came from.
    let details: [[String]]

    /// The page's events, numbered from `first`. Ones without a name are dropped.
    static func parse(_ raw: [Any], first: Int = 0) -> [DeveloperNotificationEvent] {
        var events: [DeveloperNotificationEvent] = []
        for case let item as [String: Any] in raw.prefix(1000) {
            guard let name = item["event"] as? String, !name.isEmpty else { continue }
            let details = (item["details"] as? [Any] ?? []).compactMap { pair -> [String]? in
                guard let pair = pair as? [Any], pair.count == 2, let label = pair[0] as? String,
                      let value = pair[1] as? String else { return nil }
                return [label, String(value.prefix(2048))]
            }
            events.append(DeveloperNotificationEvent(
                id: first + events.count, time: (item["time"] as? NSNumber)?.doubleValue ?? 0, name: name,
                origin: String((item["origin"] as? String ?? "").prefix(1024)),
                title: String((item["title"] as? String ?? "").prefix(2048)), details: details))
        }
        return events
    }

    /// Chrome's "Save events": the log as JSON.
    static func export(_ events: [DeveloperNotificationEvent]) -> Data {
        let items: [[String: Any]] = events.map { event in
            var metadata: [[String: String]] = []
            for pair in event.details where pair.count == 2 { metadata.append(["key": pair[0], "value": pair[1]]) }
            return ["timestamp": event.time / 1000, "eventName": event.name, "origin": event.origin,
                    "title": event.title, "service": "Notifications", "eventMetadata": metadata]
        }
        return (try? JSONSerialization.data(withJSONObject: items, options: [.prettyPrinted, .sortedKeys])) ?? Data("[]".utf8)
    }
}

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

enum DeveloperExtensionStorage {
    static let areas = ["local", "sync", "session"]

    /// The extension a chrome-extension:// page belongs to. The scheme is
    /// spelled out: Extensions.scheme is main-actor and needs macOS 15.4.
    static func extensionID(of page: URL?) -> String? {
        guard let page, page.scheme?.lowercased() == "chrome-extension", let host = page.host(), !host.isEmpty else { return nil }
        return host
    }
}
