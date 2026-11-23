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
    static func milliseconds(_ milliseconds: Double) -> String { DeveloperFormat.span(milliseconds) }

    /// The Timing tab's "Queued at" and "Started at" lines: when the
    /// request was queued, and when it left the queue, from the start of
    /// the log (the earliest request's start).
    static func header(started: Double?, queueing: Double, origin: Double) -> (queued: String, started: String)? {
        guard let started, started.isFinite, origin.isFinite else { return nil }
        let queued = max(0, (started - origin) * 1_000)
        return ("Queued at " + milliseconds(queued), "Started at " + milliseconds(queued + max(0, queueing)))
    }
}
