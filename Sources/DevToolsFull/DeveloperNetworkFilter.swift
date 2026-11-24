import Foundation

/// The Network panel's filter box, parsed as Chromium's FilterParser does:
/// `key:value` filters, `/regex/`, plain text, each negated by a leading
/// `-`, with Invert flipping every one of them.
struct DeveloperNetworkFilter {
    static let keys = [
        "cookie-domain", "cookie-name", "cookie-path", "cookie-value", "domain", "has-overrides",
        "has-request-header", "has-response-header", "is", "larger-than", "method", "mime-type", "mixed-content",
        "priority", "resource-type", "scheme", "set-cookie-domain", "set-cookie-name", "set-cookie-value",
        "status-code", "url",
    ]

    struct Clause {
        var key: String?
        var text: String
        var regex: NSRegularExpression?
        var negative: Bool
    }

    let clauses: [Clause]
    let invert: Bool

    init(_ query: String, invert: Bool = false) {
        self.invert = invert
        clauses = Self.parse(query)
    }

    var isEmpty: Bool { clauses.isEmpty }

    static func parse(_ query: String) -> [Clause] {
        var clauses: [Clause] = []
        var rest = Substring(query)
        while true {
            rest = rest.drop { $0.isWhitespace }
            guard !rest.isEmpty else { break }
            var negative = false
            var body = rest
            if body.first == "-", body.count > 1 {
                negative = true
                body = body.dropFirst()
            }
            // /regex/ runs to the closing slash that ends a token.
            if body.first == "/", let close = Self.regexEnd(body) {
                let source = String(body[body.index(after: body.startIndex)..<close])
                rest = body[body.index(after: close)...]
                if let regex = try? NSRegularExpression(pattern: source, options: [.caseInsensitive, .anchorsMatchLines]) {
                    clauses.append(Clause(text: source, regex: regex, negative: negative))
                } else {
                    clauses.append(Clause(text: "/\(source)/", negative: negative))
                }
                continue
            }
            let token = body.prefix { !$0.isWhitespace }
            rest = body[token.endIndex...]
            if let colon = token.firstIndex(of: ":"), colon != token.startIndex {
                let key = String(token[..<colon])
                let value = String(token[token.index(after: colon)...])
                if keys.contains(key) {
                    clauses.append(Clause(key: key, text: value, negative: negative))
                    continue
                }
            }
            clauses.append(Clause(text: String(token), negative: negative))
        }
        return clauses
    }

    /// The first unescaped slash after the opening one, with something between.
    private static func regexEnd(_ text: Substring) -> Substring.Index? {
        var index = text.index(after: text.startIndex)
        var escaped = false
        var length = 0
        while index < text.endIndex {
            let character = text[index]
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "/" {
                return length > 0 ? index : nil
            } else if character.isWhitespace && length == 0 {
                return nil
            }
            length += 1
            index = text.index(after: index)
        }
        return nil
    }

    func matches(_ request: DeveloperToolsSession.Request, extra: DeveloperNetworkTools.Extra?) -> Bool {
        clauses.allSatisfy { clause in
            let result = Self.test(clause, request, extra ?? .init())
            return (clause.negative != invert) ? !result : result
        }
    }

    /// The address without its scheme, which plain text is matched against.
    static func withoutScheme(_ url: String) -> String {
        guard let range = url.range(of: "://") else { return url }
        return String(url[range.upperBound...])
    }

    static func domain(_ url: String) -> String { URLComponents(string: url)?.host ?? "" }

    /// An insecure resource on a secure page: http or ws from an https
    /// document, as Chrome's mixed-content: reads it.
    static func mixedContent(_ request: DeveloperToolsSession.Request) -> Bool {
        guard let document = request.documentURL, URL(string: document)?.scheme?.lowercased() == "https" else { return false }
        let scheme = URL(string: request.url)?.scheme?.lowercased()
        return scheme == "http" || scheme == "ws"
    }

    /// Optionally blockable mixed content, which the page shows rather
    /// than blocks: images, audio and video.
    static func displayable(_ request: DeveloperToolsSession.Request) -> Bool {
        ["image", "media"].contains(request.type.lowercased())
    }

    private static func test(_ clause: Clause, _ request: DeveloperToolsSession.Request,
                             _ extra: DeveloperNetworkTools.Extra) -> Bool {
        let value = clause.text
        func contains(_ haystack: String, _ needle: String) -> Bool {
            haystack.range(of: needle, options: .caseInsensitive) != nil
        }
        if let regex = clause.regex {
            let text = withoutScheme(request.url)
            return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }
        switch clause.key {
        case nil:
            if URL(string: value)?.scheme != nil, value.contains(":") { return contains(request.url, value) }
            return contains(withoutScheme(request.url), value)
        case "domain":
            let pattern = "^" + value.components(separatedBy: "*").map(NSRegularExpression.escapedPattern).joined(separator: ".*") + "$"
            return domain(request.url).range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        case "has-response-header": return extra.responseHeaders.contains(value.lowercased())
        case "has-request-header": return extra.requestHeaders.contains(value.lowercased())
        case "is":
            switch value.lowercased() {
            case "running": return request.ended == nil && request.failure == nil
            case "from-cache": return request.cached
            case "service-worker-intercepted": return extra.source == "service-worker"
            default: return contains(withoutScheme(request.url), "is:" + value)
            }
        case "larger-than":
            var text = value.lowercased()
            var multiplier = 1.0
            if text.hasSuffix("k") { multiplier = 1_000; text.removeLast() }
            else if text.hasSuffix("m") { multiplier = 1_000_000; text.removeLast() }
            guard let quantity = Double(text) else { return contains(withoutScheme(request.url), "larger-than:" + value) }
            return Double(request.bytes ?? 0) >= quantity * multiplier
        case "method": return request.method == value
        case "mime-type": return request.mimeType == value
        case "priority": return extra.priority?.caseInsensitiveCompare(value) == .orderedSame
        case "resource-type": return request.type.caseInsensitiveCompare(value) == .orderedSame
        case "scheme": return URL(string: request.url)?.scheme == value
        case "set-cookie-domain": return extra.setCookieDomains.contains(value)
        case "set-cookie-name": return extra.setCookies.contains(value)
        case "set-cookie-value": return extra.responseCookies.contains { $0.value == value }
        case "cookie-name": return extra.cookies.contains(value) || extra.requestCookies.contains { $0.name == value }
        case "cookie-domain": return extra.requestCookies.contains { $0.domain == value }
        case "cookie-path": return extra.requestCookies.contains { $0.path == value }
        case "cookie-value": return extra.requestCookies.contains { $0.value == value }
        case "has-overrides":
            switch value.lowercased() {
            case "yes": return extra.overriddenContent || extra.overriddenHeaders
            case "no": return !extra.overriddenContent && !extra.overriddenHeaders
            case "content": return extra.overriddenContent
            case "headers": return extra.overriddenHeaders
            default: return contains(withoutScheme(request.url), "has-overrides:" + value)
            }
        case "mixed-content":
            switch value.lowercased() {
            case "all": return mixedContent(request)
            case "displayed": return mixedContent(request) && displayable(request)
            default: return contains(withoutScheme(request.url), "mixed-content:" + value)
            }
        case "status-code": return request.status.map(String.init) == value
        case "url": return contains(request.url, value)
        default: return contains(withoutScheme(request.url), (clause.key ?? "") + ":" + value)
        }
    }
}

/// The columns Chrome's header context menu offers, in its order.
enum DeveloperNetworkColumn: String, CaseIterable, Identifiable, Codable {
    case name = "Name", path = "Path", url = "URL", method = "Method", status = "Status", networkProtocol = "Protocol"
    case scheme = "Scheme", domain = "Domain", remoteAddress = "Remote address", type = "Type"
    case initiator = "Initiator", cookies = "Cookies", setCookies = "Set cookies", size = "Size", time = "Time"
    case priority = "Priority", connection = "Connection ID", hasOverrides = "Has overrides"
    case renderBlocking = "Render blocking", requestNumber = "Request #", waterfall = "Waterfall"

    var id: Self { self }
    static let defaults: [Self] = [.name, .status, .type, .initiator, .size, .time, .waterfall]
    var numeric: Bool { [.status, .size, .time, .cookies, .setCookies, .requestNumber].contains(self) }
    /// What the header's tooltip adds where WebKit can't say for certain.
    var note: String? {
        self == .renderBlocking ? "Estimated: WebKit doesn't report render blocking, so stylesheets and scripts "
            + "the HTML parser requested count as blocking" : nil
    }

    /// The width a column asks for, or nil for the one that takes the rest.
    var width: CGFloat? {
        switch self {
        case .name: nil
        case .path, .url: 160
        case .connection, .hasOverrides: 90
        case .method, .scheme, .requestNumber: 64
        case .status, .networkProtocol, .time, .cookies, .priority: 70
        case .setCookies, .type: 84
        case .domain, .remoteAddress, .initiator, .renderBlocking: 120
        case .size: 80
        case .waterfall: 200
        }
    }

    static func value(_ column: Self, _ request: DeveloperToolsSession.Request,
                      _ extra: DeveloperNetworkTools.Extra?) -> String {
        switch column {
        case .name: return request.name
        case .path: return URLComponents(string: request.url).map {
            $0.percentEncodedPath + ($0.percentEncodedQuery.map { "?" + $0 } ?? "") } ?? request.url
        case .url: return request.url
        case .connection: return extra?.connection ?? ""
        case .method: return request.method
        case .status:
            if extra?.blocked == true { return "(blocked:devtools)" }
            return request.status.map(String.init) ?? (request.failure != nil ? "(failed)" : "(pending)")
        case .networkProtocol: return extra?.networkProtocol ?? ""
        case .scheme: return URL(string: request.url)?.scheme ?? ""
        case .domain: return DeveloperNetworkFilter.domain(request.url)
        case .remoteAddress: return extra?.remoteAddress ?? ""
        case .type: return request.type.lowercased()
        case .initiator: return request.initiator
        case .cookies: return String(extra?.cookies.count ?? 0)
        case .setCookies: return String(extra?.setCookies.count ?? 0)
        case .size, .time, .waterfall: return ""
        case .priority: return extra?.priority.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? ""
        case .hasOverrides: return hasOverrides(extra)
        case .renderBlocking: return renderBlocking(request)
        case .requestNumber: return request.number.map(String.init) ?? ""
        }
    }

    /// The Render blocking column, estimated as the Performance panel's
    /// insight reads it: stylesheets and scripts the parser asked for hold
    /// the first paint (a script may be async or deferred); ones a script
    /// added don't.
    static func renderBlocking(_ request: DeveloperToolsSession.Request) -> String {
        guard !["XHR", "Fetch"].contains(request.type),
              DeveloperPerformanceInsights.isRenderBlockingType(type: request.type, mimeType: request.mimeType) else { return "" }
        guard request.initiatorType == "parser" else { return "Non-blocking dynamic" }
        let style = request.type.lowercased() == "stylesheet" || (request.mimeType ?? "").lowercased().contains("css")
        return style ? "Blocking" : "Potentially blocking"
    }

    /// The Has overrides column, as Chrome writes it: what Local Overrides
    /// replaced, or nothing.
    static func hasOverrides(_ extra: DeveloperNetworkTools.Extra?) -> String {
        guard let extra else { return "" }
        switch (extra.overriddenContent, extra.overriddenHeaders) {
        case (true, true): return "content, headers"
        case (true, false): return "content"
        case (false, true): return "headers"
        case (false, false): return ""
        }
    }

    /// Sorted as Chrome sorts the column: numbers by value, text by text,
    /// the waterfall by the time its header menu's Waterfall chose.
    static func sort(_ rows: [DeveloperToolsSession.Request], by column: Self, ascending: Bool,
                     extras: [String: DeveloperNetworkTools.Extra],
                     waterfall: DeveloperNetworkWaterfallSort = .startTime) -> [DeveloperToolsSession.Request] {
        func number(_ request: DeveloperToolsSession.Request) -> Double {
            switch column {
            case .status: return Double(request.status ?? -1)
            case .size: return Double(request.bytes ?? -1)
            case .time: return request.time ?? -1
            case .cookies: return Double(extras[request.id]?.cookies.count ?? 0)
            case .setCookies: return Double(extras[request.id]?.setCookies.count ?? 0)
            case .requestNumber: return Double(request.number ?? 0)
            case .waterfall: return waterfall.value(request)
            default: return request.started ?? 0
            }
        }
        if column.numeric || column == .waterfall {
            return stableSort(rows, ascending: ascending) { left, right in
                let a = number(left), b = number(right)
                return a == b ? .orderedSame : (a < b ? .orderedAscending : .orderedDescending)
            }
        }
        return stableSort(rows, ascending: ascending) { left, right in
            value(column, left, extras[left.id]).localizedStandardCompare(value(column, right, extras[right.id]))
        }
    }

    /// Ties keep the order the requests were made in, either way round.
    static func stableSort(_ rows: [DeveloperToolsSession.Request], ascending: Bool,
                           by compare: (DeveloperToolsSession.Request, DeveloperToolsSession.Request) -> ComparisonResult)
        -> [DeveloperToolsSession.Request] {
        rows.enumerated().sorted { left, right in
            let order = compare(left.element, right.element)
            if order == .orderedSame { return left.offset < right.offset }
            return ascending ? order == .orderedAscending : order == .orderedDescending
        }
        .map(\.element)
    }

    /// Chrome's big-row subtitle under the name: the host and the folders
    /// the file sits in, as NetworkRequest.path() reads.
    static func folder(_ url: String) -> String {
        guard let parts = URLComponents(string: url), let host = parts.host else { return "" }
        var path = parts.percentEncodedPath
        if let slash = path.lastIndex(of: "/") { path = String(path[..<slash]) }
        return host + (parts.port.map { ":\($0)" } ?? "") + path
    }

    /// The time from the request's start to its response's first byte, as
    /// Chrome's big rows show it under the Time column.
    static func latency(_ request: DeveloperToolsSession.Request) -> Double? {
        guard let started = request.started, let received = request.received, received >= started else { return nil }
        return (received - started) * 1_000
    }
}

/// The Waterfall column's sort, chosen in the header menu's Waterfall
/// submenu, as in Chrome.
enum DeveloperNetworkWaterfallSort: String, CaseIterable, Identifiable {
    case startTime = "Start Time", responseTime = "Response Time", endTime = "End Time"
    case duration = "Total Duration", latency = "Latency"

    var id: Self { self }

    /// What the request sorts by; a time it doesn't have yet sorts last.
    func value(_ request: DeveloperToolsSession.Request) -> Double {
        let none = Double.infinity
        switch self {
        case .startTime: return request.started ?? none
        case .responseTime: return request.received ?? none
        case .endTime: return request.ended ?? none
        case .duration: return request.time ?? none
        case .latency: return DeveloperNetworkColumn.latency(request) ?? none
        }
    }
}

/// A column of the request list: one of Chrome's own, or a response
/// header's value, as the header menu's Response Headers adds them.
enum DeveloperNetworkListColumn: Hashable, Identifiable {
    case standard(DeveloperNetworkColumn)
    /// A response header, by its lowercased name.
    case header(String)
    /// A request header, by its lowercased name, from Request headers.
    case requestHeader(String)

    /// The response headers Chrome's header menu offers as columns.
    static let responseHeaders = [
        "cache-control", "connection", "content-encoding", "content-length", "etag", "keep-alive",
        "last-modified", "server", "vary",
    ]
    /// The request headers the header menu's Request headers always offers.
    static let requestHeaders = [
        "accept", "accept-encoding", "accept-language", "cache-control", "content-type", "origin", "referer",
        "user-agent",
    ]

    var id: String { key }

    /// What the column's width is saved under.
    var key: String {
        switch self {
        case .standard(let column): column.rawValue
        case .header(let name): "header:" + name
        case .requestHeader(let name): "request-header:" + name
        }
    }

    var title: String {
        switch self {
        case .standard(let column): column.rawValue
        case .header(let name), .requestHeader(let name): Self.title(forHeader: name)
        }
    }

    var numeric: Bool {
        if case .standard(let column) = self { return column.numeric }
        return false
    }

    var note: String? {
        if case .standard(let column) = self { return column.note }
        return nil
    }

    /// The width a column asks for, or nil for the one that takes the rest.
    var defaultWidth: CGFloat? {
        switch self {
        case .standard(let column): column.width
        case .header, .requestHeader: 120
        }
    }

    /// A header's name as Chrome's menu writes it: Cache-Control, ETag.
    static func title(forHeader name: String) -> String {
        if name.lowercased() == "etag" { return "ETag" }
        return name.split(separator: "-", omittingEmptySubsequences: false)
            .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
            .joined(separator: "-")
    }

    static func value(_ column: Self, _ request: DeveloperToolsSession.Request,
                      _ extra: DeveloperNetworkTools.Extra?) -> String {
        switch column {
        case .standard(let standard): DeveloperNetworkColumn.value(standard, request, extra)
        case .header(let name): extra?.responseHeaderValues[name] ?? ""
        case .requestHeader(let name): extra?.requestHeaderValues[name] ?? ""
        }
    }

    static func sort(_ rows: [DeveloperToolsSession.Request], by column: Self, ascending: Bool,
                     extras: [String: DeveloperNetworkTools.Extra],
                     waterfall: DeveloperNetworkWaterfallSort = .startTime) -> [DeveloperToolsSession.Request] {
        switch column {
        case .standard(let standard):
            return DeveloperNetworkColumn.sort(rows, by: standard, ascending: ascending, extras: extras, waterfall: waterfall)
        case .header, .requestHeader:
            return DeveloperNetworkColumn.stableSort(rows, ascending: ascending) { left, right in
                value(column, left, extras[left.id]).localizedStandardCompare(value(column, right, extras[right.id]))
            }
        }
    }

    /// A dragged column edge stays between these.
    static let widths: ClosedRange<CGFloat> = 36...900
}

// MARK: Suggestions

extension DeveloperNetworkFilter {
    /// The is: values this list can answer.
    static let isValues = ["from-cache", "running", "service-worker-intercepted"]
    /// Chrome's larger-than: examples.
    static let sizeValues = ["100", "10k", "1M"]
    /// Chrome's has-overrides: values.
    static let overrideValues = ["yes", "no", "content", "headers"]
    /// Chrome's mixed-content: values.
    static let mixedContentValues = ["all", "displayed"]

    /// What the filter box offers for the word being typed, as Chrome's
    /// FilterSuggestionBuilder does: keys while it has no colon, then the
    /// values seen in the log for that key. Each suggestion is the whole
    /// word, `-` kept, to replace the last one with (see `complete`).
    static func suggestions(for query: String, requests: [DeveloperToolsSession.Request],
                            extras: [String: DeveloperNetworkTools.Extra], limit: Int = 50) -> [String] {
        guard let range = lastWord(query) else { return [] }
        var word = query[range]
        var sign = ""
        if word.first == "-" {
            sign = "-"
            word = word.dropFirst()
        }
        guard !word.isEmpty, word.first != "/" else { return [] }
        guard let colon = word.firstIndex(of: ":") else {
            let prefix = word.lowercased()
            return keys.sorted().filter { $0.hasPrefix(prefix) }.map { sign + $0 + ":" }
        }
        let key = String(word[..<colon])
        guard keys.contains(key) else { return [] }
        let typed = String(word[word.index(after: colon)...])
        return values(for: key, requests: requests, extras: extras)
            .filter { $0.lowercased().hasPrefix(typed.lowercased()) && $0 != typed }
            .prefix(limit)
            .map { sign + key + ":" + $0 }
    }

    /// The query with its last word replaced by `suggestion`.
    static func complete(_ query: String, with suggestion: String) -> String {
        guard let range = lastWord(query) else { return query + suggestion }
        return String(query[..<range.lowerBound]) + suggestion
    }

    /// The word the caret is at the end of; nil after a space.
    private static func lastWord(_ query: String) -> Range<String.Index>? {
        guard let last = query.last, !last.isWhitespace else { return nil }
        let start = query.lastIndex(where: \.isWhitespace).map(query.index(after:)) ?? query.startIndex
        return start..<query.endIndex
    }

    /// The values seen in the log for `key`, sorted as Chrome lists them.
    static func values(for key: String, requests: [DeveloperToolsSession.Request],
                       extras: [String: DeveloperNetworkTools.Extra]) -> [String] {
        var found = Set<String>()
        func each(_ read: (DeveloperToolsSession.Request, DeveloperNetworkTools.Extra) -> [String]) {
            for request in requests {
                for value in read(request, extras[request.id] ?? .init()) where !value.isEmpty { found.insert(value) }
            }
        }
        switch key {
        case "domain":
            each { request, _ in
                let host = domain(request.url)
                let labels = host.split(separator: ".")
                // As Chrome: the host, and its site with a wildcard in front.
                return labels.count > 2 && Double(labels.last ?? "") == nil
                    ? [host, "*." + labels.suffix(2).joined(separator: ".")] : [host]
            }
        case "method": each { request, _ in [request.method] }
        case "mime-type": each { request, _ in [request.mimeType ?? ""] }
        case "scheme": each { request, _ in [URL(string: request.url)?.scheme ?? ""] }
        case "status-code": each { request, _ in [request.status.map(String.init) ?? ""] }
        case "resource-type": each { request, _ in [request.type.lowercased()] }
        case "priority": each { _, extra in [extra.priority ?? ""] }
        case "has-response-header": each { _, extra in extra.responseHeaders }
        case "has-request-header": each { _, extra in extra.requestHeaders }
        case "set-cookie-domain": each { _, extra in extra.setCookieDomains }
        case "set-cookie-name": each { _, extra in extra.setCookies }
        case "set-cookie-value": each { _, extra in extra.responseCookies.map(\.value) }
        case "cookie-name": each { _, extra in extra.cookies + extra.requestCookies.map(\.name) }
        case "cookie-domain": each { _, extra in extra.requestCookies.map(\.domain) }
        case "cookie-path": each { _, extra in extra.requestCookies.map(\.path) }
        case "cookie-value": each { _, extra in extra.requestCookies.map(\.value) }
        case "has-overrides": return overrideValues
        case "mixed-content": return mixedContentValues
        case "is": return isValues
        case "larger-than": return sizeValues
        default: return []
        }
        return found.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
