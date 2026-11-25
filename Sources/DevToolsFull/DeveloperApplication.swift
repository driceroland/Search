import Foundation
import WebKit

enum DeveloperApplicationSection: String, CaseIterable, Identifiable {
    case manifest = "Manifest"
    case workers = "Service workers"
    case storage = "Storage"
    case local = "Local storage"
    case session = "Session storage"
    case indexedDB = "IndexedDB"
    case cookies = "Cookies"
    case caches = "Cache storage"
    case fileSystem = "Origin private file system"
    case frames = "Frames"

    var id: Self { self }
    var icon: String {
        switch self {
        case .manifest: "doc.text"
        case .workers: "gearshape.2"
        case .storage: "chart.pie"
        case .local, .session: "tablecells"
        case .indexedDB: "externaldrive"
        case .cookies: "circle.grid.2x2"
        case .caches: "archivebox"
        case .fileSystem: "folder"
        case .frames: "macwindow"
        }
    }

    /// Drawn by a view of its own, not the table: none left since the
    /// back/forward cache test, Reporting API, Notifications and extension
    /// storage went (they needed hooks in the page's own world).
    var ownView: Bool { false }
}

struct DeveloperApplicationQuery: Hashable {
    var section: DeveloperApplicationSection = .local
    var database: String?
    var store: String?
    /// A Cache Storage cache whose entries are shown.
    var cache: String?
    /// An index of the object store, whose entries are listed in its order.
    var index: String?
    /// Chrome's "Start from key": JSON for the key the IndexedDB page starts at.
    var startKey: String?
    /// A frame of the page, by id, and one of its resources, by address.
    var frame: String?
    var resource: String?
    /// The first entry of an IndexedDB or Cache Storage page.
    var skip = 0
    /// A frame's origin whose Local storage, Session storage or Cookies are
    /// shown, when it is not the page's own; nil for the page's.
    var origin: String?

    static let pageSize = 50
}

/// A row that can be deleted, or a container that can be cleared.
struct DeveloperApplicationItem {
    let name: String
    fileprivate let document: DeveloperApplicationValue.Document
    fileprivate let kind: Kind

    fileprivate enum Kind {
        case storage(persistent: Bool, key: String)
        case cookie(DeveloperApplicationValue.Cookie)
        case record(database: String, store: String, key: String)
        case store(database: String, store: String)
        case database(String)
        case cacheEntry(cache: String, url: String)
        case cache(String)
        case allStorage(persistent: Bool)
        case fileSystemEntry(path: String)
    }

    /// Opens the key and value editor or the cookie editor.
    var editable: Bool {
        switch kind {
        case .storage, .cookie: true
        default: false
        }
    }

    /// The exact Web Storage key, which the table may show clipped.
    var storageKey: String? {
        if case .storage(_, let key) = kind { return key }
        return nil
    }

    var deleteTitle: String {
        switch kind {
        case .store: "Clear object store"
        case .database: "Delete database"
        case .cache: "Delete cache"
        case .allStorage: "Clear all"
        default: "Delete"
        }
    }
}

/// The fields of Chrome's cookie table that WebKit stores.
struct DeveloperCookieDraft: Equatable {
    var name = ""
    var value = ""
    /// Empty for a host-only cookie. A leading dot makes a domain cookie.
    var domain = ""
    var path = "/"
    var expires: Date?
    var httpOnly = false
    var secure = false
    /// "", "Lax", "Strict" or "None".
    var sameSite = ""
}

struct DeveloperStorageOverview {
    let usage: Double?
    let quota: Double?
    let persisted: Bool?
    let counts: [(String, Int?)]
    /// Each kind's share of what is stored, as measured on the page.
    var breakdown: DeveloperStorageBreakdown?
    /// Each kind's size in bytes, nil where it could not be measured.
    var sizes: [(name: String, bytes: Double?, approximate: Bool)] = []
}

enum DeveloperSiteData: String, CaseIterable, Identifiable {
    case workers = "Unregister service workers"
    case storage = "Local and session storage"
    case indexedDB = "IndexedDB"
    case cookies = "Cookies"
    case caches = "Cache storage"

    var id: Self { self }
    fileprivate var script: String? {
        switch self {
        case .workers: "workers"
        case .storage: "storage"
        case .indexedDB: "indexedDB"
        case .caches: "caches"
        case .cookies: nil
        }
    }
}

struct DeveloperApplicationValue {
    let name: String
    fileprivate let document: Document
    fileprivate let entry: Entry

    fileprivate struct Document {
        let session: ObjectIdentifier
        let address: URL
        let origin: URL
        let id: String
        /// A subframe's origin whose storage this names, read and written
        /// through WebKit's DOMStorage domain, and the frame's address,
        /// whose cookies stand for the origin's. Nil for the page's own.
        var frameOrigin: String? = nil
        var frameAddress: URL? = nil

        /// Where cookies are matched: the frame's address, or the page's.
        var cookieAddress: URL { frameAddress ?? address }
    }

    fileprivate enum Entry {
        case storage(persistent: Bool, key: String)
        case cookie(Cookie)
    }

    fileprivate struct Cookie: Hashable {
        let name: String
        let domain: String
        let path: String

        init(_ cookie: HTTPCookie) {
            name = cookie.name
            domain = cookie.domain.lowercased()
            path = cookie.path
        }
    }
}

struct DeveloperApplicationSnapshot {
    struct Row: Identifiable {
        let id: Int
        let values: [String]
        let editableValue: DeveloperApplicationValue?
        var item: DeveloperApplicationItem? = nil
        /// Extra label and value pairs for the selected row, such as a cached response's headers.
        var details: [[String]] = []
    }

    let columns: [String]
    let rows: [Row]
    let note: String?
    /// Paging for IndexedDB records and Cache Storage entries.
    var skip = 0
    var hasMore = false
    var total: Int?
    /// The cache, object store or database the rows belong to.
    var container: DeveloperApplicationItem?
    /// The Manifest view's checks and icons.
    var manifest: DeveloperManifestReport?
    /// A frame resource's text, or its picture.
    var preview: String?
    var previewImage: Data?

    init(columns: [String], values: [[String]], note: String? = nil,
         editableValues: [DeveloperApplicationValue?] = [], items: [DeveloperApplicationItem?] = [],
         details: [[[String]]] = []) {
        self.columns = columns
        self.rows = values.enumerated().map { index, values in
            Row(id: index, values: values, editableValue: editableValues.indices.contains(index) ? editableValues[index] : nil,
                item: items.indices.contains(index) ? items[index] : nil,
                details: details.indices.contains(index) ? details[index] : [])
        }
        self.note = note
    }

    var deletable: Bool { rows.contains { $0.item != nil } }
}

@MainActor
enum DeveloperApplication {
    private typealias Document = DeveloperApplicationValue.Document
    private typealias Cookie = DeveloperApplicationValue.Cookie
    private static let storageKeyLimit = 16 * 1024
    private static let storageValueLimit = 64 * 1024
    private static let cookieLimit = 4096

    private struct CookieWrite: Hashable {
        let store: ObjectIdentifier
        let cookie: Cookie
    }
    private static var cookieWrites: Set<CookieWrite> = []

    /// Probe the currently committed document only. No data survives navigation
    /// or leaves the window, and the native inspector remains hidden.
    static func read(_ query: DeveloperApplicationQuery, in session: DeveloperToolsSession,
                     address: URL) async throws -> DeveloperApplicationSnapshot {
        guard let web = session.web, web.url == address, !web.isLoading,
              let origin = origin(of: address) else { throw Issue.pageChanged }

        var snapshot: DeveloperApplicationSnapshot
        if query.section == .cookies {
            snapshot = try await cookieSnapshot(query, in: session, web: web, address: address, origin: origin)
        } else if query.section == .frames {
            snapshot = try await frameSnapshot(query, in: session, web: web, address: address, origin: origin)
        } else if query.section == .local || query.section == .session,
                  let scope = try await frameScope(query.origin, page: origin, in: session) {
            snapshot = try await frameStorageSnapshot(query, scope: scope, in: session, web: web, address: address,
                                                      origin: origin)
        } else {
            snapshot = try await scriptSnapshot(query, in: session, web: web, address: address, origin: origin)
        }
        try Task.checkCancellation()
        guard session.web === web, web.url == address, !web.isLoading else { throw Issue.pageChanged }
        snapshot.skip = query.skip
        return snapshot
    }

    private static func cookieSnapshot(_ query: DeveloperApplicationQuery, in session: DeveloperToolsSession,
                                       web: WKWebView, address: URL,
                                       origin: URL) async throws -> DeveloperApplicationSnapshot {
        let id: String = try await documentID(web, address: address, origin: origin)
        // A subframe's origin: the cookies its frame's address is sent.
        let scope: FrameScope? = try await frameScope(query.origin, page: origin, in: session)
        let target: URL = scope?.address ?? address
        let snapshot: DeveloperApplicationSnapshot
        if #available(macOS 27, *), let scoped = await cookies(for: target, in: web) {
            let now = Date()
            let cookies: [HTTPCookie] = scoped.filter { DeveloperCookieRules.sends($0, to: target, at: now) }
            let shown: ArraySlice<HTTPCookie> = cookies.prefix(100)
            let document = Document(session: ObjectIdentifier(session), address: address, origin: origin, id: id,
                                    frameOrigin: scope?.origin, frameAddress: scope?.address)
            let counts: [Cookie: Int] = Dictionary(grouping: scoped, by: Cookie.init).mapValues(\.count)
            let edits: [DeveloperApplicationValue?] = shown.map { (cookie: HTTPCookie) -> DeveloperApplicationValue? in
                let key = Cookie(cookie)
                guard counts[key] == 1, editable(cookie, on: target) else { return nil }
                return DeveloperApplicationValue(name: cookie.name, document: document, entry: .cookie(key))
            }
            let items: [DeveloperApplicationItem?] = shown.map { (cookie: HTTPCookie) -> DeveloperApplicationItem? in
                let key = Cookie(cookie)
                guard counts[key] == 1 else { return nil }
                return DeveloperApplicationItem(name: cookie.name, document: document, kind: .cookie(key))
            }
            let matching: String = scope.map { $0.address.absoluteString } ?? "this URL"
            let note: String = cookies.count > 100 ? "Showing the first 100 cookies matching \(matching)."
                : "Cookies matching \(matching)."
            snapshot = DeveloperApplicationSnapshot(columns: columns(for: query), values: shown.map(cookieRow),
                                                    note: note, editableValues: edits, items: items)
        } else if scope != nil {
            snapshot = DeveloperApplicationSnapshot(columns: ["Name", "Value"], values: [],
                                                    note: "WebKit lists another origin's cookies on macOS 27 and later.")
        } else {
            let values: [[String]] = (try await script(query, web: web, address: address, origin: origin)).rows
            snapshot = DeveloperApplicationSnapshot(columns: ["Name", "Value"], values: values,
                                                    note: "Showing cookies available to this document.")
        }
        _ = try await documentID(web, address: address, origin: origin, expected: id)
        return snapshot
    }

    private static func frameSnapshot(_ query: DeveloperApplicationQuery, in session: DeveloperToolsSession,
                                      web: WKWebView, address: URL,
                                      origin: URL) async throws -> DeveloperApplicationSnapshot {
        let id: String = try await documentID(web, address: address, origin: origin)
        let isolation: [String: Any] = try await evaluate(DeveloperApplicationScript.identity.replacingOccurrences(
            of: "return { documentID };",
            with: "return { documentID, secure: isSecureContext, isolated: !!globalThis.crossOriginIsolated };"),
            in: web, arguments: arguments(address: address, origin: origin, expected: id))
        let tree = try await session.command("Page.getResourceTree")["frameTree"] as? [String: Any]
        let root: DeveloperFrameNode? = tree.flatMap { DeveloperFrameNode.parse($0, topSecure: isolation["secure"] as? Bool) }
        guard let frame = query.frame, let node = root?.find(frame) else {
            var rows = [[String]]()
            if let tree {
                frameRows(tree, depth: 0, parentSecure: true, top: isolation, into: &rows)
            }
            return DeveloperApplicationSnapshot(columns: columns(for: query), values: rows,
                                                note: rows.isEmpty ? "WebKit did not report any frames." : nil)
        }
        // Chrome's frame view, or a resource of the frame.
        let headers = ["Property", "Value"]
        guard let url = query.resource else {
            return DeveloperApplicationSnapshot(
                columns: headers, values: node.properties(crossOriginIsolated: isolation["isolated"] as? Bool == true))
        }
        let resource = node.resources.first { $0.url == url }
        let values: [[String]] = [["URL", String(url.prefix(4096))], ["Type", resource?.type ?? "—"],
                                  ["MIME type", resource?.mimeType ?? "—"], ["Frame", node.title]]
        let content = await resourceContent(url, frame: node.id, mimeType: resource?.mimeType ?? "", in: session)
        let note: String? = content.text == nil && content.image == nil ? "WebKit has no preview of this resource." : nil
        var snapshot = DeveloperApplicationSnapshot(columns: headers, values: values, note: note)
        snapshot.preview = content.text
        snapshot.previewImage = content.image
        return snapshot
    }

    /// A subframe's origin, which page script in the main frame may not
    /// reach: WebKit's DOMStorage domain reads it by origin.
    private static func frameStorageSnapshot(_ query: DeveloperApplicationQuery, scope: FrameScope,
                                             in session: DeveloperToolsSession, web: WKWebView, address: URL,
                                             origin: URL) async throws -> DeveloperApplicationSnapshot {
        let id: String = try await documentID(web, address: address, origin: origin)
        let persistent: Bool = query.section == .local
        let entries = try await domStorageItems(scope.origin, persistent: persistent, in: session)
        let document = Document(session: ObjectIdentifier(session), address: address, origin: origin, id: id,
                                frameOrigin: scope.origin, frameAddress: scope.address)
        let shown = Array(entries.prefix(1000))
        let values: [[String]] = shown.map { [String($0.key.prefix(4096)), String($0.value.prefix(4096))] }
        let edits: [DeveloperApplicationValue?] = shown.map { entry in
            DeveloperApplicationValue(name: entry.key.isEmpty ? "Empty key" : String(entry.key.prefix(160)),
                                      document: document, entry: .storage(persistent: persistent, key: entry.key))
        }
        let items: [DeveloperApplicationItem?] = shown.map { entry in
            DeveloperApplicationItem(name: String(entry.key.prefix(160)), document: document,
                                     kind: .storage(persistent: persistent, key: entry.key))
        }
        let note: String? = entries.count > shown.count ? "Showing the first \(shown.count) items of \(scope.origin)." : nil
        var snapshot = DeveloperApplicationSnapshot(columns: columns(for: query), values: values, note: note,
                                                    editableValues: edits, items: items)
        snapshot.container = DeveloperApplicationItem(name: query.section.rawValue, document: document,
                                                      kind: .allStorage(persistent: persistent))
        _ = try await documentID(web, address: address, origin: origin, expected: id)
        return snapshot
    }

    /// Everything else, which the page's own script reads.
    private static func scriptSnapshot(_ query: DeveloperApplicationQuery, in session: DeveloperToolsSession,
                                       web: WKWebView, address: URL,
                                       origin: URL) async throws -> DeveloperApplicationSnapshot {
        let response = try await script(query, web: web, address: address, origin: origin)
        let values: [[String]] = response.rows
        var edits: [DeveloperApplicationValue?] = []
        var items: [DeveloperApplicationItem?] = []
        var details: [[[String]]] = []
        var container: DeveloperApplicationItem?
        let document = Document(session: ObjectIdentifier(session), address: address, origin: origin, id: response.id)
        let keys: [String?] = response.keys.count == values.count ? response.keys.map { $0 as? String } : []
        func make(label column: Int = 0, _ build: (String) -> DeveloperApplicationItem.Kind) -> [DeveloperApplicationItem?] {
            keys.enumerated().map { index, key in
                guard let key else { return nil }
                let label = values[index].indices.contains(column) ? values[index][column] : key
                return DeveloperApplicationItem(name: String(label.prefix(160)), document: document, kind: build(key))
            }
        }
        switch query.section {
        case .local, .session:
            let persistent = query.section == .local
            edits = keys.map { key in
                guard let key else { return nil }
                let name = key.isEmpty ? "Empty key" : String(key.prefix(160))
                return DeveloperApplicationValue(name: name, document: document,
                    entry: .storage(persistent: persistent, key: key))
            }
            items = make { .storage(persistent: persistent, key: $0) }
            container = DeveloperApplicationItem(name: query.section.rawValue, document: document,
                                                 kind: .allStorage(persistent: persistent))
        case .indexedDB:
            if let database = query.database, let store = query.store {
                items = make(label: 1) { .record(database: database, store: store, key: $0) }
                container = DeveloperApplicationItem(name: store, document: document,
                                                     kind: .store(database: database, store: store))
            } else if let database = query.database {
                items = values.map { row in
                    row.first.map { DeveloperApplicationItem(name: $0, document: document,
                                                             kind: .store(database: database, store: $0)) }
                }
                container = DeveloperApplicationItem(name: database, document: document, kind: .database(database))
            } else {
                items = values.map { row in
                    row.first.map { DeveloperApplicationItem(name: $0, document: document, kind: .database($0)) }
                }
            }
        case .fileSystem:
            items = make { .fileSystemEntry(path: $0) }
            details = response.details
        case .caches:
            if let cache = query.cache {
                items = make(label: 1) { .cacheEntry(cache: cache, url: $0) }
                details = response.details
                container = DeveloperApplicationItem(name: cache, document: document, kind: .cache(cache))
            } else {
                items = make { .cache($0) }
            }
        default: break
        }
        var snapshot = DeveloperApplicationSnapshot(columns: columns(for: query), values: values, note: response.note,
                                                    editableValues: edits, items: items, details: details)
        snapshot.hasMore = response.hasMore
        snapshot.total = response.total
        snapshot.container = container
        if query.section == .manifest, let raw = response.manifest { snapshot.manifest = DeveloperManifestReport.validate(raw) }
        return snapshot
    }

    // MARK: The sidebar's tree

    /// What Chrome's Application sidebar lists under Storage and Frames for
    /// this page: its databases with their object stores and indexes, its
    /// caches, and its frames with their resources.
    static func tree(in session: DeveloperToolsSession, address: URL) async -> DeveloperApplicationTree {
        var tree = DeveloperApplicationTree()
        guard let web = session.web, web.url == address, !web.isLoading,
              let origin = origin(of: address) else { return tree }
        tree.origin = originText(origin)
        if let reply = try? await script(.init(section: .indexedDB), web: web, address: address, origin: origin) {
            for name in reply.rows.prefix(30).compactMap(\.first) {
                var stores: [DeveloperApplicationTree.ObjectStore] = []
                if let inner = try? await script(.init(section: .indexedDB, database: name), web: web, address: address,
                                                 origin: origin) {
                    stores = inner.rows.enumerated().compactMap { offset, row in
                        row.first.map { DeveloperApplicationTree.ObjectStore(
                            name: $0, indexes: inner.indexes.indices.contains(offset) ? inner.indexes[offset] : []) }
                    }
                }
                tree.databases.append(DeveloperApplicationTree.Database(name: name, stores: stores))
            }
        }
        if let reply = try? await script(.init(section: .caches), web: web, address: address, origin: origin) {
            tree.caches = reply.keys.compactMap { $0 as? String }
        }
        if let raw = try? await session.command("Page.getResourceTree")["frameTree"] as? [String: Any] {
            tree.frame = DeveloperFrameNode.parse(raw)
        }
        tree.origins = DeveloperApplicationTree.storageOrigins(main: tree.origin, frame: tree.frame)
        guard session.web === web, web.url == address else { return DeveloperApplicationTree() }
        return tree
    }

    /// A frame resource's content from WebKit: text up to 64 KB, or an image.
    private static func resourceContent(_ url: String, frame: String, mimeType: String,
                                        in session: DeveloperToolsSession) async -> (text: String?, image: Data?) {
        guard let reply = try? await session.command("Page.getResourceContent", ["frameId": frame, "url": url]),
              let content = reply["content"] as? String else { return (nil, nil) }
        let encoded = reply["base64Encoded"] as? Bool == true
        if mimeType.lowercased().hasPrefix("image/") {
            if encoded, let data = Data(base64Encoded: content) { return (nil, data) }
            return (nil, Data(content.utf8))
        }
        if encoded {
            guard let data = Data(base64Encoded: content), let text = String(data: data.prefix(64 * 1024), encoding: .utf8)
            else { return ("Binary content (\(content.count * 3 / 4) bytes)", nil) }
            return (text, nil)
        }
        return (content.count > 64 * 1024 ? String(content.prefix(64 * 1024)) + "…" : content, nil)
    }

    // MARK: Frames

    private static func frameRows(_ tree: [String: Any], depth: Int, parentSecure: Bool, top: [String: Any],
                                  into rows: inout [[String]]) {
        guard let frame = tree["frame"] as? [String: Any], rows.count < 200 else { return }
        let url = frame["url"] as? String ?? ""
        let origin = frame["securityOrigin"] as? String ?? ""
        let name = (frame["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let title = depth == 0 ? "top" : (name ?? URL(string: url)?.host() ?? "iframe")
        let secure: Bool
        let isolated: String
        if depth == 0 {
            secure = top["secure"] as? Bool ?? potentiallyTrustworthy(origin)
            isolated = top["isolated"] as? Bool == true ? "Yes" : "No"
        } else {
            // A frame is a secure context when it and every ancestor have
            // potentially trustworthy origins.
            secure = parentSecure && potentiallyTrustworthy(origin)
            isolated = "—"
        }
        let resources = (tree["resources"] as? [Any])?.count ?? 0
        rows.append([String(repeating: "    ", count: depth) + title, String(url.prefix(4096)), origin,
                     secure ? "Yes" : "No", isolated, frame["mimeType"] as? String ?? "—", String(resources)])
        for child in (tree["childFrames"] as? [[String: Any]] ?? []).prefix(100) {
            frameRows(child, depth: depth + 1, parentSecure: secure, top: top, into: &rows)
        }
    }

    nonisolated static func potentiallyTrustworthy(_ origin: String) -> Bool {
        guard let url = URL(string: origin), let scheme = url.scheme?.lowercased() else { return false }
        if ["https", "wss", "file", "about", "data"].contains(scheme) { return true }
        let host = url.host()?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]")) ?? ""
        return host == "localhost" || host.hasSuffix(".localhost") || host == "::1" || host.hasPrefix("127.")
    }

    static func value(for reference: DeveloperApplicationValue, in session: DeveloperToolsSession) async throws -> String {
        let web = try inspectedWeb(for: reference.document, in: session)
        switch reference.entry {
        case .storage(let persistent, let key):
            if let frameOrigin = reference.document.frameOrigin {
                let stored = try await frameStorageValue(frameOrigin, persistent: persistent, key: key, in: session)
                try await requireDocument(reference.document, in: session, web: web)
                guard let stored else { throw Issue.valueChanged }
                guard stored.utf8.count <= storageValueLimit else { throw Issue.valueTooLarge }
                return stored
            }
            let result = try await storageValue(key, persistent: persistent, reference: reference, web: web)
            _ = try inspectedWeb(for: reference.document, in: session)
            guard let value = result["value"] as? String else { throw Issue.unavailable }
            return value
        case .cookie(let key):
            guard #available(macOS 27, *) else { throw Issue.unavailable }
            let cookie = try await editableCookie(key, address: reference.document.cookieAddress, in: web)
            try await requireDocument(reference.document, in: session, web: web)
            return cookie.value
        }
    }

    static func setValue(_ value: String, replacing original: String, for reference: DeveloperApplicationValue,
                         in session: DeveloperToolsSession) async throws {
        let web = try inspectedWeb(for: reference.document, in: session)
        switch reference.entry {
        case .storage(let persistent, let key):
            guard value.utf8.count <= storageValueLimit else { throw Issue.valueTooLarge }
            if let frameOrigin = reference.document.frameOrigin {
                let current = try await frameStorageValue(frameOrigin, persistent: persistent, key: key, in: session)
                guard current == original else { throw Issue.valueChanged }
                try await requireDocument(reference.document, in: session, web: web)
                _ = try await domStorage("setDOMStorageItem", origin: frameOrigin, persistent: persistent,
                                         with: ["key": key, "value": value], in: session)
                let saved = try await frameStorageValue(frameOrigin, persistent: persistent, key: key, in: session)
                guard saved == value else { throw Issue.saveFailed }
                return
            }
            let result = try await storageValue(key, persistent: persistent, reference: reference, web: web,
                                                replacement: value, original: original)
            guard result["saved"] as? Bool == true else { throw Issue.saveFailed }
        case .cookie(let key):
            guard #available(macOS 27, *) else { throw Issue.unavailable }
            try await setCookie(value, replacing: original, key: key, document: reference.document,
                                session: session, web: web)
        }
    }

    // MARK: Adding, deleting and clearing

    /// Deletes rows, or clears the container an item names.
    static func delete(_ items: [DeveloperApplicationItem], in session: DeveloperToolsSession) async throws {
        for item in items { try await delete(item, in: session) }
    }

    private static func delete(_ item: DeveloperApplicationItem, in session: DeveloperToolsSession) async throws {
        let document = item.document
        let web = try inspectedWeb(for: document, in: session)
        switch item.kind {
        case .storage(let persistent, let key):
            if let frameOrigin = document.frameOrigin {
                try await requireDocument(document, in: session, web: web)
                _ = try await domStorage("removeDOMStorageItem", origin: frameOrigin, persistent: persistent,
                                         with: ["key": key], in: session)
            } else {
                try await write(DeveloperApplicationScript.storageWrite, document, web,
                                storageInput(operation: "remove", persistent: persistent, keys: [key]))
            }
        case .allStorage(let persistent):
            if let frameOrigin = document.frameOrigin {
                try await requireDocument(document, in: session, web: web)
                do {
                    _ = try await domStorage("clearDOMStorageItems", origin: frameOrigin, persistent: persistent,
                                             in: session)
                } catch {
                    // WebKit without clearDOMStorageItems: each item in turn.
                    for entry in try await domStorageItems(frameOrigin, persistent: persistent, in: session) {
                        _ = try await domStorage("removeDOMStorageItem", origin: frameOrigin, persistent: persistent,
                                                 with: ["key": entry.key], in: session)
                    }
                }
            } else {
                try await write(DeveloperApplicationScript.storageWrite, document, web,
                                storageInput(operation: "clear", persistent: persistent))
            }
        case .cookie(let key):
            guard #available(macOS 27, *) else { throw Issue.unavailable }
            let cookie = try await matchingCookie(key, address: document.cookieAddress, in: web)
            try await requireDocument(document, in: session, web: web)
            await web.configuration.websiteDataStore.httpCookieStore.deleteCookie(cookie)
        case .record(let database, let store, let key):
            try await write(DeveloperApplicationScript.indexedDBWrite, document, web,
                            ["operation": "deleteRecords", "database": database, "store": store, "keys": [key]])
        case .store(let database, let store):
            try await write(DeveloperApplicationScript.indexedDBWrite, document, web,
                            ["operation": "clearStore", "database": database, "store": store, "keys": []])
        case .database(let database):
            let reply = try await evaluate(DeveloperApplicationScript.indexedDBWrite, in: web, arguments: merged(
                document, ["operation": "deleteDatabase", "database": database, "store": NSNull(), "keys": []]))
            if reply["blocked"] as? Bool == true { throw Issue.databaseBlocked }
            guard reply["saved"] as? Bool == true else { throw Issue.saveFailed }
        case .cacheEntry(let cache, let url):
            try await write(DeveloperApplicationScript.cacheWrite, document, web,
                            ["operation": "deleteEntries", "cache": cache, "keys": [url]])
        case .cache(let cache):
            try await write(DeveloperApplicationScript.cacheWrite, document, web,
                            ["operation": "deleteCache", "cache": cache, "keys": [cache]])
        case .fileSystemEntry(let path):
            try await write(DeveloperApplicationScript.fileSystemWrite, document, web, ["path": path])
        }
    }

    /// The full value of a Web Storage item, for the item editor.
    static func storageValue(of item: DeveloperApplicationItem, in session: DeveloperToolsSession) async throws -> String {
        guard case .storage(let persistent, let key) = item.kind else { throw Issue.unavailable }
        let reference = DeveloperApplicationValue(name: item.name, document: item.document,
                                                  entry: .storage(persistent: persistent, key: key))
        return try await value(for: reference, in: session)
    }

    /// Adds a Web Storage item, or renames and edits the item `previous` names.
    /// `origin` names a subframe's origin for a new item, as the query does.
    static func setStorageItem(key: String, value: String?, replacing previous: DeveloperApplicationItem?,
                               persistent: Bool, in session: DeveloperToolsSession, address: URL,
                               origin: String? = nil) async throws {
        guard key.utf8.count <= storageKeyLimit, (value?.utf8.count ?? 0) <= storageValueLimit
        else { throw Issue.valueTooLarge }
        let document = try await currentDocument(in: session, address: address, previous: previous, frame: origin)
        let web = try inspectedWeb(for: document, in: session)
        var previousKey: String?
        if let previous, case .storage(let wasPersistent, let old) = previous.kind {
            guard wasPersistent == persistent else { throw Issue.valueChanged }
            previousKey = old
        }
        guard value != nil || previousKey != nil else { throw Issue.unavailable }
        if let frameOrigin = document.frameOrigin {
            var stored = value
            if let previousKey {
                let old = try await frameStorageValue(frameOrigin, persistent: persistent, key: previousKey, in: session)
                guard let old else { throw Issue.valueChanged }
                if stored == nil { stored = old }
            }
            guard let stored else { throw Issue.unavailable }
            try await requireDocument(document, in: session, web: web)
            _ = try await domStorage("setDOMStorageItem", origin: frameOrigin, persistent: persistent,
                                     with: ["key": key, "value": stored], in: session)
            if let previousKey, previousKey != key {
                _ = try await domStorage("removeDOMStorageItem", origin: frameOrigin, persistent: persistent,
                                         with: ["key": previousKey], in: session)
            }
            return
        }
        try await write(DeveloperApplicationScript.storageWrite, document, web,
                        storageInput(operation: "set", persistent: persistent, key: key, value: value,
                                     previousKey: previousKey))
    }

    /// The cookie's fields for Chrome's cookie editor.
    static func cookieDraft(for item: DeveloperApplicationItem, in session: DeveloperToolsSession) async throws
        -> DeveloperCookieDraft {
        guard case .cookie(let key) = item.kind, #available(macOS 27, *) else { throw Issue.unavailable }
        let web = try inspectedWeb(for: item.document, in: session)
        let cookie = try await matchingCookie(key, address: item.document.cookieAddress, in: web)
        return DeveloperCookieDraft(
            name: cookie.name, value: cookie.value,
            domain: cookie.domain.hasPrefix(".") ? cookie.domain : "",
            path: cookie.path, expires: cookie.isSessionOnly ? nil : cookie.expiresDate,
            httpOnly: cookie.isHTTPOnly, secure: cookie.isSecure, sameSite: cookie.sameSitePolicy?.rawValue ?? "")
    }

    /// Adds a cookie for this page, or replaces the one `previous` names.
    /// `origin` names a subframe's origin for a new cookie, as the query does.
    static func saveCookie(_ draft: DeveloperCookieDraft, replacing previous: DeveloperApplicationItem?,
                           in session: DeveloperToolsSession, address: URL, origin: String? = nil) async throws {
        guard #available(macOS 27, *) else { throw Issue.unavailable }
        let document = try await currentDocument(in: session, address: address, previous: previous, frame: origin)
        let web = try inspectedWeb(for: document, in: session)
        let replacement = try cookie(from: draft, for: document.cookieAddress)
        let jar = web.configuration.websiteDataStore.httpCookieStore
        var old: HTTPCookie?
        if let previous {
            guard case .cookie(let key) = previous.kind else { throw Issue.unavailable }
            old = try await matchingCookie(key, address: document.cookieAddress, in: web)
        }
        try await requireDocument(document, in: session, web: web)
        try Task.checkCancellation()
        if let old, Cookie(old) != Cookie(replacement) { await jar.deleteCookie(old) }
        await jar.setCookie(replacement)
        let saved = await jar.allCookies().contains {
            Cookie($0) == Cookie(replacement) && $0.value == replacement.value
        }
        guard saved || replacement.expiresDate.map({ $0 <= Date() }) == true else { throw Issue.saveFailed }
    }

    /// Chrome's Storage view: usage and quota from `navigator.storage.estimate()`.
    static func overview(in session: DeveloperToolsSession, address: URL) async throws -> DeveloperStorageOverview {
        guard let web = session.web, web.url == address, !web.isLoading,
              let origin = origin(of: address) else { throw Issue.pageChanged }
        let reply = try await script(.init(section: .storage), web: web, address: address, origin: origin)
        let data = reply.overview ?? [:]
        var cookieCount: Int?
        if #available(macOS 27, *), let scoped = await cookies(for: address, in: web) {
            cookieCount = scoped.filter { DeveloperCookieRules.sends($0, to: address, at: Date()) }.count
        }
        var cookieBytes: Double?
        if #available(macOS 27, *), let scoped = await cookies(for: address, in: web) {
            cookieBytes = Double(scoped.filter { DeveloperCookieRules.sends($0, to: address, at: Date()) }
                .reduce(0) { $0 + $1.name.utf8.count + $1.value.utf8.count })
        }
        func count(_ key: String) -> Int? { (data[key] as? NSNumber)?.intValue }
        let sizes = data["sizes"] as? [String: Any] ?? [:]
        let approximate = Set(sizes["approximate"] as? [String] ?? [])
        func size(_ key: String) -> Double? { (sizes[key] as? NSNumber)?.doubleValue }
        // What WebKit counts against the quota: IndexedDB, Cache storage and
        // the file system. Web Storage and cookies it keeps apart.
        let parts: [(String, String, Double?, Bool)] = [
            ("Local storage", "local", size("local"), false), ("Session storage", "session", size("session"), false),
            ("IndexedDB", "indexedDB", size("indexedDB"), true), ("Cache storage", "caches", size("caches"), true),
            ("File system", "fileSystem", size("fileSystem"), true), ("Cookies", "cookies", cookieBytes, false),
            ("Service workers", "workers", nil, true),
        ]
        let usage = (data["usage"] as? NSNumber)?.doubleValue
        var overview = DeveloperStorageOverview(
            usage: usage, quota: (data["quota"] as? NSNumber)?.doubleValue,
            persisted: data["persisted"] as? Bool,
            counts: [("Local storage", count("local")), ("Session storage", count("session")),
                     ("IndexedDB databases", count("databases")), ("Cookies", cookieCount),
                     ("Caches", count("caches")), ("Service workers", count("workers")),
                     ("File system entries", count("files"))])
        overview.sizes = parts.map { (name: $0.0, bytes: $0.2, approximate: approximate.contains($0.1)) }
        overview.breakdown = DeveloperStorageBreakdown(
            usage: usage, parts: parts.map { .init(name: $0.0, bytes: $0.2, inQuota: $0.3) })
        return overview
    }

    /// Chrome's "Clear site data" for this origin. Returns the kinds that could not be cleared.
    static func clearSiteData(_ kinds: Set<DeveloperSiteData>, in session: DeveloperToolsSession,
                              address: URL) async throws -> [String] {
        let document = try await currentDocument(in: session, address: address, previous: nil)
        let web = try inspectedWeb(for: document, in: session)
        var failed = [String]()
        let types = DeveloperSiteData.allCases.filter(kinds.contains).compactMap(\.script)
        if !types.isEmpty {
            let reply = try await evaluate(DeveloperApplicationScript.clearSite, in: web,
                                           arguments: merged(document, ["types": types]))
            failed += reply["failed"] as? [String] ?? []
        }
        if kinds.contains(.cookies), #available(macOS 15.4, *) {
            let jar = web.configuration.websiteDataStore.httpCookieStore
            guard let host = document.address.host()?.lowercased() else { return failed + ["Cookies"] }
            for cookie in await jar.allCookies() where DeveloperCookieRules.domainMatches(host, cookie.domain) {
                await jar.deleteCookie(cookie)
            }
        }
        return failed
    }

    private static func currentDocument(in session: DeveloperToolsSession, address: URL,
                                        previous: DeveloperApplicationItem?,
                                        frame requested: String? = nil) async throws -> Document {
        if let previous { return previous.document }
        guard let web = session.web, web.url == address, !web.isLoading,
              let origin = origin(of: address) else { throw Issue.pageChanged }
        let id = try await documentID(web, address: address, origin: origin)
        var document = Document(session: ObjectIdentifier(session), address: address, origin: origin, id: id)
        if let scope = try await frameScope(requested, page: origin, in: session) {
            document.frameOrigin = scope.origin
            document.frameAddress = scope.address
        }
        return document
    }

    // MARK: Subframe origins

    private struct FrameScope {
        let origin: String
        let address: URL
    }

    /// An origin as the sidebar lists it: scheme, host and port, without the trailing slash.
    nonisolated static func originText(_ origin: URL) -> String {
        let text = origin.absoluteString
        return text.hasSuffix("/") ? String(text.dropLast()) : text
    }

    /// The subframe origin `requested` names, with the address of a frame
    /// from it; nil when it is the page's own. A frame since gone fails.
    private static func frameScope(_ requested: String?, page origin: URL,
                                   in session: DeveloperToolsSession) async throws -> FrameScope? {
        guard let requested, requested != originText(origin) else { return nil }
        let raw = try? await session.command("Page.getResourceTree")["frameTree"] as? [String: Any]
        let root = raw.flatMap { DeveloperFrameNode.parse($0) }
        guard DeveloperApplicationTree.storageOrigins(main: nil, frame: root).contains(requested),
              let address = DeveloperApplicationTree.address(of: requested, in: root) else { throw Issue.frameGone }
        return FrameScope(origin: requested, address: address)
    }

    /// A DOMStorage command for one origin's Local or Session storage.
    @discardableResult
    private static func domStorage(_ method: String, origin: String, persistent: Bool, with extra: [String: Any] = [:],
                                   in session: DeveloperToolsSession) async throws -> [String: Any] {
        try Task.checkCancellation()
        var params: [String: Any] = ["storageId": ["securityOrigin": origin, "isLocalStorage": persistent] as [String: Any]]
        params.merge(extra) { _, new in new }
        do {
            return try await session.command("DOMStorage." + method, params)
        } catch {
            // Some WebKit versions answer only once the domain is on.
            _ = try? await session.command("DOMStorage.enable")
            do {
                return try await session.command("DOMStorage." + method, params)
            } catch {
                throw Issue.unavailable
            }
        }
    }

    /// One origin's Local or Session storage, as key and value pairs.
    private static func domStorageItems(_ origin: String, persistent: Bool,
                                        in session: DeveloperToolsSession) async throws -> [(key: String, value: String)] {
        let reply = try await domStorage("getDOMStorageItems", origin: origin, persistent: persistent, in: session)
        let entries = reply["entries"] as? [Any] ?? []
        return entries.compactMap { entry -> (key: String, value: String)? in
            guard let pair = entry as? [Any], pair.count >= 2, let key = pair[0] as? String,
                  let value = pair[1] as? String else { return nil }
            return (key: key, value: value)
        }
    }

    private static func frameStorageValue(_ origin: String, persistent: Bool, key: String,
                                          in session: DeveloperToolsSession) async throws -> String? {
        try await domStorageItems(origin, persistent: persistent, in: session).first { $0.key == key }?.value
    }

    private static func merged(_ document: Document, _ input: [String: Any]) -> [String: Any] {
        arguments(address: document.address, origin: document.origin, expected: document.id)
            .merging(input) { _, new in new }
    }

    private static func write(_ source: String, _ document: Document, _ web: WKWebView,
                              _ input: [String: Any]) async throws {
        let reply = try await evaluate(source, in: web, arguments: merged(document, input))
        guard reply["saved"] as? Bool == true else { throw Issue.saveFailed }
    }

    private static func storageInput(operation: String, persistent: Bool, key: String? = nil, value: String? = nil,
                                     previousKey: String? = nil, keys: [String] = []) -> [String: Any] {
        ["operation": operation, "persistent": persistent, "key": key as Any? ?? NSNull(),
         "value": value as Any? ?? NSNull(), "previousKey": previousKey as Any? ?? NSNull(), "keys": keys,
         "maxKey": storageKeyLimit, "maxValue": storageValueLimit]
    }

    @available(macOS 27, *)
    private static func matchingCookie(_ key: Cookie, address: URL, in web: WKWebView) async throws -> HTTPCookie {
        guard let cookies = await cookies(for: address, in: web) else { throw Issue.unavailable }
        let matches = cookies.filter { Cookie($0) == key }
        guard matches.count == 1, let cookie = matches.first else { throw Issue.valueChanged }
        return cookie
    }

    /// Builds a cookie this page could have set itself: its own host or a parent domain.
    private static func cookie(from draft: DeveloperCookieDraft, for address: URL) throws -> HTTPCookie {
        guard let host = address.host()?.lowercased(), !host.isEmpty else { throw Issue.pageChanged }
        let name = draft.name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name.utf8.allSatisfy(isTokenOctet) else { throw Issue.invalidCookie("Enter a cookie name without spaces, separators or control characters.") }
        guard draft.value.utf8.allSatisfy(isCookieOctet), name.utf8.count + draft.value.utf8.count <= cookieLimit
        else { throw Issue.invalidCookieValue }
        var domain = draft.domain.trimmingCharacters(in: .whitespaces).lowercased()
        if !domain.isEmpty {
            let bare = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
            guard !bare.isEmpty, host == bare || (host.hasSuffix("." + bare) && bare.contains(".")) else {
                throw Issue.invalidCookie("The domain must be \(host) or one of its parent domains.")
            }
            if !domain.hasPrefix(".") && bare != host { domain = "." + bare }
        }
        let path = draft.path.isEmpty ? "/" : draft.path
        guard path.hasPrefix("/"), !path.contains(";"), path.utf8.allSatisfy({ $0 > 0x20 && $0 < 0x7F }) else {
            throw Issue.invalidCookie("The path must start with / and contain no spaces or semicolons.")
        }
        if draft.secure && address.scheme?.lowercased() != "https" && !potentiallyTrustworthy(address.absoluteString) {
            throw Issue.invalidCookie("Secure cookies need an HTTPS page.")
        }
        var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: draft.value, .path: path]
        if domain.isEmpty { properties[.originURL] = address; properties[.domain] = host }
        else { properties[.domain] = domain }
        if let expires = draft.expires { properties[.expires] = expires } else { properties[.discard] = "TRUE" }
        if draft.secure { properties[.secure] = "TRUE" }
        if draft.httpOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        switch draft.sameSite {
        case "Lax": properties[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteLax
        case "Strict": properties[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteStrict
        case "None": properties[.sameSitePolicy] = "none"
        default: break
        }
        guard let cookie = HTTPCookie(properties: properties) else {
            throw Issue.invalidCookie("WebKit rejected this cookie.")
        }
        return cookie
    }

    private static func isTokenOctet(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x21, 0x23...0x27, 0x2A, 0x2B, 0x2D, 0x2E, 0x30...0x39, 0x41...0x5A, 0x5E...0x7A, 0x7C, 0x7E: true
        default: false
        }
    }

    nonisolated static func origin(of address: URL) -> URL? {
        guard var parts = URLComponents(url: address, resolvingAgainstBaseURL: false),
              parts.scheme == "http" || parts.scheme == "https", parts.host?.isEmpty == false else { return nil }
        parts.path = ""
        parts.query = nil
        parts.fragment = nil
        parts.user = nil
        parts.password = nil
        return parts.url
    }

    /// Fetch only the cookies matching this URL without loading the profile's jar.
    private static func cookies(for address: URL, in web: WKWebView) async -> [HTTPCookie]? {
#if compiler(>=6.4)
        if #available(macOS 27, *) {
            return await web.configuration.websiteDataStore.httpCookieStore.cookies(for: address)
        }
#endif
        return nil
    }

    private static func inspectedWeb(for document: Document, in session: DeveloperToolsSession) throws -> WKWebView {
        try Task.checkCancellation()
        guard ObjectIdentifier(session) == document.session, session.ready, let web = session.web,
              web.url == document.address, !web.isLoading else { throw Issue.pageChanged }
        return web
    }

    private static func arguments(address: URL, origin: URL, expected: String? = nil) -> [String: Any] {
        ["address": address.absoluteString, "origin": origin.absoluteString,
         "expectedDocument": expected as Any? ?? NSNull()]
    }

    private static func documentID(_ web: WKWebView, address: URL, origin: URL, expected: String? = nil) async throws -> String {
        let reply = try await evaluate(DeveloperApplicationScript.identity, in: web,
                                       arguments: arguments(address: address, origin: origin, expected: expected))
        guard let id = reply["documentID"] as? String else { throw Issue.pageChanged }
        return id
    }

    private static func requireDocument(_ document: Document, in session: DeveloperToolsSession, web: WKWebView) async throws {
        _ = try await documentID(web, address: document.address, origin: document.origin, expected: document.id)
        _ = try inspectedWeb(for: document, in: session)
    }

    private static func script(_ query: DeveloperApplicationQuery, web: WKWebView,
                               address: URL, origin: URL) async throws -> ScriptReply {
        var input = arguments(address: address, origin: origin)
        input["section"] = query.section.rawValue
        input["database"] = query.database as Any? ?? NSNull()
        input["store"] = query.store as Any? ?? NSNull()
        input["cache"] = query.cache as Any? ?? NSNull()
        input["index"] = query.index as Any? ?? NSNull()
        input["startKey"] = query.startKey as Any? ?? NSNull()
        input["skip"] = max(0, query.skip)
        input["pageSize"] = DeveloperApplicationQuery.pageSize
        input["maxKey"] = storageKeyLimit
        let reply = try await evaluate(DeveloperApplicationScript.read, in: web, arguments: input)
        guard let id = reply["documentID"] as? String else { throw Issue.unavailable }
        return ScriptReply(id: id, rows: reply["rows"] as? [[String]] ?? [], keys: reply["keys"] as? [Any] ?? [],
                           note: reply["note"] as? String, hasMore: reply["hasMore"] as? Bool == true,
                           total: reply["total"] as? Int, details: reply["details"] as? [[[String]]] ?? [],
                           overview: reply["overview"] as? [String: Any], indexes: reply["indexes"] as? [[String]] ?? [],
                           manifest: reply["manifest"] as? [String: Any])
    }

    private struct ScriptReply {
        let id: String
        let rows: [[String]]
        let keys: [Any]
        let note: String?
        let hasMore: Bool
        let total: Int?
        let details: [[[String]]]
        let overview: [String: Any]?
        let indexes: [[String]]
        let manifest: [String: Any]?
    }

    private static func storageValue(_ key: String, persistent: Bool, reference: DeveloperApplicationValue, web: WKWebView,
                                     replacement: String? = nil, original: String? = nil) async throws -> [String: Any] {
        let document = reference.document
        var input = arguments(address: document.address, origin: document.origin, expected: document.id)
        input["key"] = key
        input["persistent"] = persistent
        input["replacement"] = replacement as Any? ?? NSNull()
        input["expectedValue"] = original as Any? ?? NSNull()
        input["maxKey"] = storageKeyLimit
        input["maxValue"] = storageValueLimit
        return try await evaluate(DeveloperApplicationScript.storageValue, in: web, arguments: input)
    }

    private static func evaluate(_ source: String, in web: WKWebView, arguments: [String: Any]) async throws -> [String: Any] {
        try Task.checkCancellation()
        let result: Any?
        do {
            result = try await web.callAsyncJavaScript(source, arguments: arguments, in: nil, contentWorld: DevHost.world)
        } catch {
            try Task.checkCancellation()
            throw Issue.unavailable
        }
        try Task.checkCancellation()
        guard let reply = result as? [String: Any] else { throw Issue.unavailable }
        if reply["changed"] as? Bool == true { throw Issue.pageChanged }
        if let issue = reply["issue"] as? String {
            switch issue {
            case "stale": throw Issue.valueChanged
            case "tooLarge": throw Issue.valueTooLarge
            default: throw Issue.unavailable
            }
        }
        return reply
    }

    @available(macOS 27, *)
    private static func editable(_ cookie: HTTPCookie, on address: URL) -> Bool {
        guard DeveloperCookieRules.sends(cookie, to: address, at: Date()) else { return false }
        return replacingValue(of: cookie, with: cookie.value) != nil
    }

    @available(macOS 27, *)
    private static func editableCookie(_ key: Cookie, address: URL, in web: WKWebView) async throws -> HTTPCookie {
        guard let cookies = await cookies(for: address, in: web) else { throw Issue.unavailable }
        let matches = cookies.filter { Cookie($0) == key }
        guard matches.count == 1, let cookie = matches.first,
              editable(cookie, on: address)
        else { throw Issue.valueChanged }
        return cookie
    }

    @available(macOS 27, *)
    private static func setCookie(_ value: String, replacing original: String, key: Cookie,
                                  document: Document, session: DeveloperToolsSession, web: WKWebView) async throws {
        guard value.utf8.count + key.name.utf8.count <= cookieLimit, value.utf8.allSatisfy(isCookieOctet)
        else { throw Issue.invalidCookieValue }
        let jar = web.configuration.websiteDataStore.httpCookieStore
        let write = CookieWrite(store: ObjectIdentifier(jar), cookie: key)
        guard cookieWrites.insert(write).inserted else { throw Issue.cookieBusy }
        defer { cookieWrites.remove(write) }

        let current = try await editableCookie(key, address: document.cookieAddress, in: web)
        guard current.value.utf8.elementsEqual(original.utf8) else { throw Issue.valueChanged }
        guard let replacement = replacingValue(of: current, with: value) else { throw Issue.saveFailed }
        try await requireDocument(document, in: session, web: web)
        try Task.checkCancellation()
        await jar.setCookie(replacement)

        let saved = try await editableCookie(key, address: document.cookieAddress, in: web)
        guard saved.value == value, sameAttributes(current, saved) else { throw Issue.saveFailed }
    }

    @available(macOS 27, *)
    private static func replacingValue(of cookie: HTTPCookie, with value: String) -> HTTPCookie? {
        guard var properties = cookie.properties else { return nil }
        properties[.value] = value
        guard let copy = HTTPCookie(properties: properties), copy.value == value,
              sameAttributes(cookie, copy) else { return nil }
        return copy
    }

    @available(macOS 27, *)
    private static func sameAttributes(_ current: HTTPCookie, _ replacement: HTTPCookie) -> Bool {
        Cookie(current) == Cookie(replacement) && current.isSecure == replacement.isSecure
            && current.isHTTPOnly == replacement.isHTTPOnly && current.isSessionOnly == replacement.isSessionOnly
            && current.sameSitePolicy == replacement.sameSitePolicy && current.expiresDate == replacement.expiresDate
            && current.version == replacement.version && current.portList == replacement.portList
            && !DeveloperCookieRules.partitioned(replacement)
    }

    private static func isCookieOctet(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x21, 0x23...0x2B, 0x2D...0x3A, 0x3C...0x5B, 0x5D...0x7E: true
        default: false
        }
    }

    private static func columns(for query: DeveloperApplicationQuery) -> [String] {
        switch query.section {
        case .manifest: ["Property", "Value"]
        case .workers: ["Scope", "State", "Script URL", "Controls this page"]
        case .local, .session: ["Key", "Value"]
        case .indexedDB:
            if query.store != nil, query.index != nil { ["#", "Key", "Primary key", "Value"] }
            else if query.store != nil { ["#", "Key", "Value"] }
            else if query.database != nil { ["Object store", "Key path", "Auto increment", "Indexes"] }
            else { ["Database", "Version"] }
        case .cookies: cookieColumns
        case .caches:
            if query.cache != nil { ["#", "Name", "Response-Type", "Content-Type", "Content-Length", "Date", "Vary Header"] }
            else { ["Cache"] }
        case .storage: ["Property", "Value"]
        case .fileSystem: ["Name", "Kind", "Size", "Last modified"]
        case .frames: ["Frame", "URL", "Origin", "Secure context", "Cross-origin isolated", "MIME type", "Resources"]
        }
    }

    /// Chrome's cookie table. WebKit does not store cookie priority.
    static let cookieColumns = ["Name", "Value", "Domain", "Path", "Expires / Max-Age", "Size", "HttpOnly", "Secure",
                                "SameSite", "Partition Key", "Priority"]

    private static func cookieRow(_ cookie: HTTPCookie) -> [String] {
        let expiration = cookie.expiresDate?.formatted(.iso8601)
        let partition = cookie.properties?.first { $0.key.rawValue.lowercased().contains("partition") }
            .flatMap { $0.value as? String }.flatMap { $0.isEmpty ? nil : $0 }
        return [
            cookie.name, String(cookie.value.prefix(4096)), cookie.domain, cookie.path,
            expiration ?? (cookie.isSessionOnly ? "Session" : "—"),
            String(cookie.name.utf8.count + cookie.value.utf8.count),
            cookie.isHTTPOnly ? "✓" : "", cookie.isSecure ? "✓" : "",
            cookie.sameSitePolicy?.rawValue ?? "", partition ?? "", "—",
        ]
    }

    enum Issue: LocalizedError {
        case pageChanged, unavailable, valueChanged, valueTooLarge, invalidCookieValue, cookieBusy, saveFailed
        case databaseBlocked, frameGone
        case invalidCookie(String)

        var errorDescription: String? {
            switch self {
            case .databaseBlocked: "The page still has this database open. WebKit deletes it once the page closes it."
            case .frameGone: "No frame on the page has this origin any more. Refresh to see the frames' origins."
            case .invalidCookie(let reason): reason
            case .pageChanged: "Wait for the current website to finish loading, then refresh."
            case .unavailable: "The inspected page could not provide this information."
            case .valueChanged: "This entry changed since it was opened. Refresh and reopen it."
            case .valueTooLarge: "The value exceeds the 64 KB editing limit."
            case .invalidCookieValue: "Use cookie-safe ASCII without spaces, quotes, commas, semicolons, or backslashes. The cookie must fit in 4 KB."
            case .cookieBusy: "Another edit to this cookie is in progress. Refresh and try again."
            case .saveFailed: "Search could not verify the saved value. Refresh and check the entry."
            }
        }
    }
}
