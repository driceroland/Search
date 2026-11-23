import Foundation

// Chrome DevTools' Developer resources (More tools › Developer resources):
// the files DevTools itself loaded for the page rather than the page for
// itself, in Search the source maps (DeveloperSourceMaps) and the authored
// files read from a map's address when it carries no content. This file is
// the record of each load, the list kept, and the URL filter.

/// One load DevTools made.
struct DeveloperResourceRecord: Identifiable, Equatable {
    enum Status: String {
        case pending, success, failure
    }

    enum Kind: String {
        case sourceMap = "Source map"
        case authored = "Authored file"
    }

    let id: Int
    /// What was loaded: the map's or file's address, or a data: URL.
    let url: String
    /// The script or stylesheet it was loaded for.
    let initiator: String
    let kind: Kind
    var status: Status = .pending
    /// The bytes read, once loaded.
    var bytes: Int?
    var error: String?

    /// A data: URL can be megabytes: the list shows its start.
    static let urlLimit = 2048

    /// The address as the table shows it: a data: URL cut short.
    var displayURL: String { Self.display(url) }

    static func display(_ url: String) -> String {
        guard url.lowercased().hasPrefix("data:"), url.count > 80 else { return url }
        return String(url.prefix(80)) + "…"
    }
}

/// The records of a page, newest last.
struct DeveloperResourceList: Equatable {
    /// The most kept; the oldest go first.
    static let limit = 2000

    private(set) var records: [DeveloperResourceRecord] = []
    /// Never reused, even after the list is cleared, so a load that ends
    /// after a navigation finds nothing to update.
    private var nextID = 1

    /// A load starting: its record, pending; returns its id.
    @discardableResult
    mutating func begin(url: String, initiator: String, kind: DeveloperResourceRecord.Kind) -> Int {
        let id = nextID
        nextID += 1
        let kept = url.count > DeveloperResourceRecord.urlLimit ? String(url.prefix(DeveloperResourceRecord.urlLimit)) : url
        records.append(DeveloperResourceRecord(id: id, url: kept, initiator: initiator, kind: kind))
        if records.count > Self.limit { records.removeFirst(records.count - Self.limit) }
        return id
    }

    mutating func finish(_ id: Int, bytes: Int) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].status = .success
        records[index].bytes = max(0, bytes)
        records[index].error = nil
    }

    /// Failed: why, and the bytes if it loaded but was no use.
    mutating func fail(_ id: Int, error: String, bytes: Int? = nil) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].status = .failure
        records[index].error = error.isEmpty ? "Failed to load." : error
        if let bytes { records[index].bytes = max(0, bytes) }
    }

    mutating func removeAll() { records.removeAll() }

    /// The status bar: "3 resources, 1 failed, 12.4 kB loaded".
    static func summary(_ records: [DeveloperResourceRecord]) -> String {
        let failed = records.filter { $0.status == .failure }.count
        let pending = records.filter { $0.status == .pending }.count
        let bytes = records.filter { $0.status == .success }.compactMap(\.bytes).reduce(0, +)
        var parts = [records.count == 1 ? "1 resource" : "\(records.count) resources"]
        if failed > 0 { parts.append("\(failed) failed") }
        if pending > 0 { parts.append("\(pending) pending") }
        parts.append(DeveloperFormat.bytes(Double(bytes)) + " loaded")
        return parts.joined(separator: ", ")
    }
}

/// The toolbar's filter: words separated by spaces, each in the address
/// (any case); a word starting with - is one the address must not have.
enum DeveloperResourceFilter {
    static func matches(_ record: DeveloperResourceRecord, query: String) -> Bool {
        let url = record.url.lowercased()
        for word in query.lowercased().split(whereSeparator: \.isWhitespace) {
            if word.hasPrefix("-"), word.count > 1 {
                if url.contains(word.dropFirst()) { return false }
            } else if !url.contains(word) {
                return false
            }
        }
        return true
    }

    static func filter(_ records: [DeveloperResourceRecord], query: String) -> [DeveloperResourceRecord] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return records }
        return records.filter { matches($0, query: trimmed) }
    }

    /// The Total bytes column: blank while pending or for a failure that read nothing.
    static func bytesText(_ record: DeveloperResourceRecord) -> String {
        guard let bytes = record.bytes else { return "" }
        return DeveloperFormat.integer(Double(bytes))
    }
}

/// The package's own requests (source maps, authored files, a localhost
/// server's devtools.json): the host's ephemeral session, through Search's
/// proxy, with no cookie jar and no credentials. A redirect goes on only to
/// http(s), never with a Cookie or Authorization header, and, when asked,
/// only within the first address's origin.
enum DeveloperResourceRequest {
    @MainActor
    static func data(for request: URLRequest, sameOriginRedirects: Bool = false) async throws -> (Data, URLResponse) {
        guard let session = DevHost.host?.ephemeralSession() else { throw URLError(.cancelled) }
        var request = request
        request.httpShouldHandleCookies = false
        request.setValue(nil, forHTTPHeaderField: "Cookie")
        request.setValue(nil, forHTTPHeaderField: "Authorization")
        let redirects = Redirects(origin: sameOriginRedirects ? origin(of: request.url) : nil)
        return try await session.data(for: request, delegate: redirects)
    }

    /// scheme://host[:port], the port left out where it is the scheme's own.
    nonisolated static func origin(of url: URL?) -> String? {
        guard let url, let scheme = url.scheme?.lowercased(), let host = url.host(percentEncoded: true)?.lowercased(),
              !host.isEmpty else { return nil }
        let bracketed = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        let port = url.port.flatMap { (scheme == "https" && $0 == 443) || (scheme == "http" && $0 == 80) ? nil : $0 }
        return "\(scheme)://\(bracketed)" + (port.map { ":\($0)" } ?? "")
    }

    private final class Redirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        let origin: String?

        init(origin: String?) { self.origin = origin }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            guard let url = request.url, let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
                  url.user == nil, url.password == nil, origin == nil || DeveloperResourceRequest.origin(of: url) == origin else {
                completionHandler(nil)
                return
            }
            var forwarded = request
            forwarded.httpShouldHandleCookies = false
            forwarded.setValue(nil, forHTTPHeaderField: "Cookie")
            forwarded.setValue(nil, forHTTPHeaderField: "Authorization")
            completionHandler(forwarded)
        }
    }
}

/// A session's list, for the drawer to watch.
@MainActor
final class DeveloperResourceLog: ObservableObject {
    @Published private(set) var list = DeveloperResourceList()

    @discardableResult
    func begin(url: String, initiator: String, kind: DeveloperResourceRecord.Kind) -> Int {
        list.begin(url: url, initiator: initiator, kind: kind)
    }

    func finish(_ id: Int, bytes: Int) { list.finish(id, bytes: bytes) }
    func fail(_ id: Int, error: String, bytes: Int? = nil) { list.fail(id, error: error, bytes: bytes) }
    func removeAll() { list.removeAll() }
}
