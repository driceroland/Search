import AppKit
import SwiftUI

/// One cookie as the Network panel's Cookies tab lists it, parsed the way
/// Chrome's CookieParser reads a Cookie or Set-Cookie header.
struct DeveloperRequestCookie: Identifiable, Equatable {
    enum Kind: Equatable {
        case request
        case response
    }

    var id: Int
    var kind: Kind
    var name: String
    var value: String
    var domain = ""
    var path = ""
    /// The Expires attribute as written.
    var expires: String?
    var maxAge: Int?
    /// Chrome's Size: the cookie's text in the header (name=value for a
    /// request cookie, the whole Set-Cookie line for a response cookie).
    var size: Int
    var httpOnly = false
    var secure = false
    var sameSite = ""
    var priority = "Medium"
    var partitioned = false

    // MARK: Parsing

    /// The cookies in a request's Cookie headers.
    static func requestCookies(_ headers: [DeveloperRequestDetails.Header]) -> [DeveloperRequestCookie] {
        var cookies: [DeveloperRequestCookie] = []
        for header in headers where header.name.caseInsensitiveCompare("cookie") == .orderedSame {
            for piece in header.value.split(separator: ";") {
                let text = piece.trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { continue }
                let pair = split(text)
                cookies.append(DeveloperRequestCookie(id: cookies.count, kind: .request, name: pair.name, value: pair.value,
                                                      size: text.utf16.count))
            }
        }
        return cookies
    }

    /// The cookies a response's Set-Cookie headers set, with their
    /// attributes.
    static func responseCookies(_ headers: [DeveloperRequestDetails.Header]) -> [DeveloperRequestCookie] {
        var cookies: [DeveloperRequestCookie] = []
        for header in headers where header.name.caseInsensitiveCompare("set-cookie") == .orderedSame {
            for line in setCookieLines(header.value) {
                guard var cookie = setCookie(line) else { continue }
                cookie.id = cookies.count
                cookies.append(cookie)
            }
        }
        return cookies
    }

    /// One Set-Cookie header's cookies. WebKit joins repeated Set-Cookie
    /// headers with new lines, some servers fold them with commas; a comma
    /// inside an Expires date ("Wed, 21 Oct 2015") does not start a cookie.
    static func setCookieLines(_ value: String) -> [String] {
        var lines: [String] = []
        for line in value.split(whereSeparator: \.isNewline) {
            var current = ""
            var rest = Substring(line)
            while let comma = rest.firstIndex(of: ",") {
                let after = rest[rest.index(after: comma)...]
                if startsCookie(after) {
                    current += rest[..<comma]
                    lines.append(current)
                    current = ""
                } else {
                    current += rest[...comma]
                }
                rest = after
            }
            current += rest
            lines.append(current)
        }
        return lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Whether text after a comma reads `name=`, as a new cookie does.
    private static func startsCookie(_ text: Substring) -> Bool {
        let trimmed = text.drop { $0 == " " || $0 == "\t" }
        guard let equals = trimmed.firstIndex(of: "=") else { return false }
        let name = trimmed[..<equals]
        return !name.isEmpty && !name.contains { $0 == ";" || $0 == "," || $0.isWhitespace }
    }

    static func setCookie(_ line: String) -> DeveloperRequestCookie? {
        let parts = line.split(separator: ";", omittingEmptySubsequences: false)
        guard let first = parts.first else { return nil }
        let pair = split(first.trimmingCharacters(in: .whitespaces))
        guard !pair.name.isEmpty || !pair.value.isEmpty else { return nil }
        var cookie = DeveloperRequestCookie(id: 0, kind: .response, name: pair.name, value: pair.value, size: line.utf16.count)
        for part in parts.dropFirst() {
            let attribute = split(part.trimmingCharacters(in: .whitespaces))
            switch attribute.name.lowercased() {
            case "domain": cookie.domain = attribute.value
            case "path": cookie.path = attribute.value
            case "expires": cookie.expires = attribute.value
            case "max-age": cookie.maxAge = Int(attribute.value)
            case "httponly": cookie.httpOnly = true
            case "secure": cookie.secure = true
            case "samesite": cookie.sameSite = normalizedSameSite(attribute.value)
            case "priority": cookie.priority = attribute.value.prefix(1).uppercased() + attribute.value.dropFirst().lowercased()
            case "partitioned": cookie.partitioned = true
            default: break
            }
        }
        return cookie
    }

    private static func split(_ text: String) -> (name: String, value: String) {
        guard let equals = text.firstIndex(of: "=") else { return (text, "") }
        return (text[..<equals].trimmingCharacters(in: .whitespaces),
                text[text.index(after: equals)...].trimmingCharacters(in: .whitespaces))
    }

    private static func normalizedSameSite(_ value: String) -> String {
        switch value.lowercased() {
        case "lax": "Lax"
        case "strict": "Strict"
        case "none": "None"
        default: value
        }
    }

    // MARK: Columns

    /// Chrome's Expires / Max-Age cell: the Max-Age as a duration, else the
    /// expiry as an ISO date, else "Session" (or "N/A" for a cookie the
    /// request sent, whose expiry the header doesn't carry).
    var expiresText: String {
        if let maxAge, maxAge != 0 { return Self.duration(seconds: Double(maxAge)) }
        if let expires {
            if let date = Self.httpDate(expires) { return Self.iso.string(from: date) }
            return expires
        }
        return kind == .request ? "N/A" : "Session"
    }

    var httpOnlyText: String { httpOnly ? "\u{2713}" : "" }
    var secureText: String { secure ? "\u{2713}" : "" }

    /// i18n.TimeUtilities.secondsToString, as Chrome writes a Max-Age.
    static func duration(seconds: Double) -> String {
        DeveloperRequestTimingText.milliseconds(seconds * 1_000)
    }

    private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let httpDates: [DateFormatter] = [
        "EEE, dd MMM yyyy HH:mm:ss zzz", "EEE, dd-MMM-yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz",
        "EEE, dd-MMM-yy HH:mm:ss zzz", "EEE MMM d HH:mm:ss yyyy", "dd MMM yyyy HH:mm:ss zzz",
    ].map { format in
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = format
        return formatter
    }

    /// An HTTP date in any of the forms servers send in Expires.
    static func httpDate(_ text: String) -> Date? {
        let text = text.trimmingCharacters(in: .whitespaces)
        for formatter in httpDates {
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}

/// The Privacy and security panel's Third-party cookies report: the
/// cookies of requests to sites other than the page's, grouped by site, as
/// Chrome's cookie report lists them. WebKit's tracking prevention blocks
/// third-party cookies outright, so a site whose responses set cookies is
/// Blocked; one whose requests carried cookies all the same (the Storage
/// Access API, or a cookie the site set while it was first party and
/// WebKit let through) is Allowed by exception. WebKit doesn't report why
/// a cookie was blocked.
enum DeveloperThirdPartyCookies {
    enum Status: String, Comparable {
        case blocked = "Blocked"
        case exempted = "Allowed by exception"

        static func < (lhs: Self, rhs: Self) -> Bool { lhs == .blocked && rhs == .exempted }
    }

    /// One request's cookies, as the report reads them.
    struct Request: Equatable {
        var id: String
        var url: String
        /// Names in its Cookie header.
        var sent: [String]
        /// Names its response's Set-Cookie headers set.
        var set: [String]
    }

    /// One third-party site.
    struct Site: Identifiable, Equatable {
        var site: String
        var status: Status
        /// Distinct cookie names, in the order first seen.
        var cookies: [String] = []
        /// How many cookies requests to the site carried, and its responses set.
        var sent = 0
        var set = 0
        /// The requests with cookies, newest last.
        var requests: [String] = []
        /// The hosts the cookies went to or came from.
        var hosts: [String] = []
        var id: String { site }

        /// Network's filter for the site's requests.
        var networkFilter: String {
            hosts.count == 1 ? "domain:" + hosts[0] : "domain:*" + site
        }
    }

    /// The third-party sites with cookies, blocked first, then by name.
    static func report(_ requests: [Request], page: URL?) -> [Site] {
        guard let pageHost = page?.host()?.lowercased(), !pageHost.isEmpty else { return [] }
        let first = DeveloperIssueRules.site(of: pageHost)
        var order: [String] = []
        var sites: [String: Site] = [:]
        for request in requests where !request.sent.isEmpty || !request.set.isEmpty {
            guard let address = URL(string: request.url), let scheme = address.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" || scheme == "ws" || scheme == "wss",
                  let host = address.host()?.lowercased(), !host.isEmpty else { continue }
            let site = DeveloperIssueRules.site(of: host)
            guard site != first else { continue }
            if sites[site] == nil {
                order.append(site)
                sites[site] = Site(site: site, status: .blocked)
            }
            guard var entry = sites[site] else { continue }
            for name in request.sent + request.set where !entry.cookies.contains(name) { entry.cookies.append(name) }
            entry.sent += request.sent.count
            entry.set += request.set.count
            if !entry.requests.contains(request.id) { entry.requests.append(request.id) }
            if !entry.hosts.contains(host) { entry.hosts.append(host) }
            if entry.sent > 0 { entry.status = .exempted }
            sites[site] = entry
        }
        return order.compactMap { sites[$0] }.sorted { left, right in
            left.status != right.status ? left.status < right.status : left.site < right.site
        }
    }

    /// The report's line under the table: "3 sites: 2 blocked, 1 allowed by exception".
    static func summary(_ sites: [Site]) -> String {
        let blocked = sites.filter { $0.status == .blocked }.count
        let exempted = sites.count - blocked
        var text = sites.count == 1 ? "1 site" : "\(sites.count) sites"
        var parts: [String] = []
        if blocked > 0 { parts.append("\(blocked) blocked") }
        if exempted > 0 { parts.append("\(exempted) allowed by exception") }
        if !parts.isEmpty { text += ": " + parts.joined(separator: ", ") }
        return text
    }
}

/// Chrome's cookie table: Name, Value, Domain, Path, Expires / Max-Age,
/// Size, HttpOnly, Secure, SameSite and Priority, sortable by any column,
/// rows selectable and copyable.
struct DeveloperCookieTable: View {
    let cookies: [DeveloperRequestCookie]
    @State private var order: [KeyPathComparator<DeveloperRequestCookie>] = []
    @State private var selection: Set<DeveloperRequestCookie.ID> = []

    private static let rowHeight: CGFloat = 24

    var body: some View {
        let rows: [DeveloperRequestCookie] = order.isEmpty ? cookies : cookies.sorted(using: order)
        Table(rows, selection: $selection, sortOrder: $order) {
            TableColumn("Name", value: \DeveloperRequestCookie.name) { cell($0.name) }.width(min: 60, ideal: 120)
            TableColumn("Value", value: \DeveloperRequestCookie.value) { cell($0.value) }.width(min: 60, ideal: 160)
            TableColumn("Domain", value: \DeveloperRequestCookie.domain) { cell($0.domain) }.width(min: 40, ideal: 100)
            TableColumn("Path", value: \DeveloperRequestCookie.path) { cell($0.path) }.width(min: 30, ideal: 50)
            TableColumn("Expires / Max-Age", value: \DeveloperRequestCookie.expiresText) { cell($0.expiresText) }.width(min: 60, ideal: 150)
            TableColumn("Size", value: \DeveloperRequestCookie.size) { cell("\($0.size)").frame(maxWidth: .infinity, alignment: .trailing) }
                .width(min: 30, ideal: 40)
            TableColumn("HttpOnly", value: \DeveloperRequestCookie.httpOnlyText) { cell($0.httpOnlyText) }.width(min: 30, ideal: 55)
            TableColumn("Secure", value: \DeveloperRequestCookie.secureText) { cell($0.secureText) }.width(min: 30, ideal: 50)
            TableColumn("SameSite", value: \DeveloperRequestCookie.sameSite) { cell($0.sameSite) }.width(min: 30, ideal: 60)
            TableColumn("Priority", value: \DeveloperRequestCookie.priority) { cell($0.priority) }.width(min: 30, ideal: 55)
        }
        .contextMenu(forSelectionType: DeveloperRequestCookie.ID.self) { ids in menu(ids) }
        .font(.system(size: 11))
        .tableStyle(.bordered(alternatesRowBackgrounds: true))
        // No taller than its rows; when both tables can't fit, each
        // shrinks and scrolls on its own.
        .frame(minHeight: min(contentHeight, Self.rowHeight * 4), maxHeight: contentHeight)
    }

    private var contentHeight: CGFloat {
        Self.rowHeight * CGFloat(cookies.count + 1) + 6
    }

    @ViewBuilder
    private func menu(_ ids: Set<DeveloperRequestCookie.ID>) -> some View {
        let chosen: [DeveloperRequestCookie] = cookies.filter { ids.contains($0.id) }
        if !chosen.isEmpty {
            Button("Copy") { copy(chosen.map { $0.name + "=" + $0.value }.joined(separator: "; ")) }
            if chosen.count == 1, let cookie = chosen.first {
                Button("Copy value") { copy(cookie.value) }
            }
        }
    }

    private func cell(_ text: String) -> some View {
        Text(text).lineLimit(1).truncationMode(.middle).help(text)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Times as Chrome's i18n.TimeUtilities.millisToString writes them: "0",
/// "125 ms", "1.23 s", "2.5 min", "1.0 hrs", "3.0 days".
enum DeveloperRequestTimingText {
    static func milliseconds(_ milliseconds: Double) -> String {
        guard milliseconds.isFinite else { return "-" }
        if milliseconds == 0 { return "0" }
        if milliseconds < 1_000 { return String(format: "%.0f ms", milliseconds) }
        let seconds = milliseconds / 1_000
        if seconds < 60 { return String(format: "%.2f s", seconds) }
        let minutes = seconds / 60
        if minutes < 60 { return String(format: "%.1f min", minutes) }
        let hours = minutes / 60
        if hours < 24 { return String(format: "%.1f hrs", hours) }
        return String(format: "%.1f days", hours / 24)
    }

    /// The Timing tab's "Queued at" and "Started at" lines: when the
    /// request was queued, and when it left the queue, from the start of
    /// the log (the earliest request's start).
    static func header(started: Double?, queueing: Double, origin: Double) -> (queued: String, started: String)? {
        guard let started, started.isFinite, origin.isFinite else { return nil }
        let queued = max(0, (started - origin) * 1_000)
        return ("Queued at " + milliseconds(queued), "Started at " + milliseconds(queued + max(0, queueing)))
    }
}
