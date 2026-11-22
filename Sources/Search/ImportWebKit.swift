import Foundation
import SQLite3

// Browsers built on WebKit, as Search is, whose files can be read: their
// bookmarks and history.
//
// Orion (Kagi) keeps each profile in a folder of ~/Library/Application
// Support/Orion — "Defaults" for the first, the profile's identifier for
// the others — with its bookmarks in favourites.plist (a flat dictionary of
// items, each with its parent's id, its type, title, address and place
// among its siblings) and its history in "history", a SQLite file of
// history_items, whose LAST_VISIT_TIME has been seconds since 2001 and, in
// some versions, a date written out.
//
// Safari keeps its bookmarks in ~/Library/Safari/Bookmarks.plist — a tree
// of lists (folders) and leaves (pages), the bar, the menu and the Reading
// List at the top — and its history in History.db beside it: history_items,
// and history_visits with each visit's title and time in seconds since
// 2001. macOS keeps that folder from every app without Full Disk Access.
// Search never asks for it: the files are read only if macOS already lets
// them be, and otherwise Safari isn't offered here and the sheet says how to
// export from it instead (ImportPanel.notes).
//
// Read as every import is: a regular file, no link followed, inside the
// browser's folder, at most 64 MB; databases through a Snapshot.

enum WebKitBrowser {
    struct Source: Identifiable, Hashable {
        enum Kind: Hashable { case orion, safari }
        let name: String
        let kind: Kind
        /// Under Chromium.base, so a test run reads made-up ones.
        let folder: String

        var id: String { name }
        var root: URL {
            if kind == .safari, !Store.testing {
                return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Safari", isDirectory: true)
            }
            return Chromium.base.appendingPathComponent(folder, isDirectory: true).resolvingSymlinksInPath()
        }

        /// Each profile's folder, the first one first. Safari's one is its
        /// folder itself, when macOS lets its files be opened at all.
        var profiles: [URL] {
            if kind == .safari {
                return ["Bookmarks.plist", "History.db"].contains { WebKitBrowser.opens(root.appendingPathComponent($0)) } ? [root] : []
            }
            let inside = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                                         options: .skipsHiddenFiles)) ?? []
            return inside.filter { folder in
                (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                    && !folder.lastPathComponent.hasPrefix("bk_")
                    && ["favourites.plist", "history"].contains { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
            }
            .sorted { a, b in
                a.lastPathComponent == "Defaults" ? true : b.lastPathComponent == "Defaults" ? false
                    : a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending
            }
        }

        func profiles(only: String?) -> [URL] {
            guard let only else { return profiles }
            return profiles.filter { $0.lastPathComponent == only }
        }

        /// What Orion calls its profiles, from its "profiles" list: the
        /// first one's name, and each other's by its identifier.
        var names: [String: String] {
            guard kind == .orion, let data = try? ImportRead.data(root.appendingPathComponent("profiles"), inside: root),
                  let list = try? PropertyListSerialization.propertyList(from: data, format: nil)
            else { return [:] }
            let top = (list as? [Any])?.first as? [String: Any] ?? list as? [String: Any] ?? [:]
            var out: [String: String] = [:]
            if let name = (top["defaults"] as? [String: Any])?["name"] as? String, !name.isEmpty { out["Defaults"] = name }
            for case let profile as [String: Any] in (top["profiles"] as? [Any]) ?? [] {
                if let id = profile["identifier"] as? String, let name = profile["name"] as? String, !name.isEmpty { out[id] = name }
            }
            return out
        }
    }

    static let known: [Source] = [
        Source(name: "Orion", kind: .orion, folder: "Orion"),
        Source(name: "Orion RC", kind: .orion, folder: "Orion RC"),
        Source(name: "Safari", kind: .safari, folder: "Safari"),
    ]

    /// Whether a file opens for reading: macOS refuses Safari's without
    /// Full Disk Access, and asks nobody about it.
    static func opens(_ file: URL) -> Bool {
        guard let fd = try? ImportRead.openRegular(file, limit: ImportRead.jsonLimit) else { return false }
        close(fd)
        return true
    }

    static func installed() -> [Source] {
        known.filter { !$0.profiles.isEmpty }
    }

    // MARK: - bookmarks

    static func bookmarkRead(in source: Source, profile: String? = nil) -> (nodes: [Bookmark], complete: Bool) {
        var out: [Bookmark] = []
        let folders = source.profiles(only: profile)
        var complete = !folders.isEmpty
        for folder in folders {
            if source.kind == .safari {
                let file = folder.appendingPathComponent("Bookmarks.plist")
                guard FileManager.default.fileExists(atPath: file.path) else { continue }
                guard let data = try? ImportRead.data(file, inside: source.root),
                      let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
                else {
                    complete = false
                    continue
                }
                out += safariTree(list)
                continue
            }
            let file = folder.appendingPathComponent("favourites.plist")
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            guard let data = try? ImportRead.data(file, inside: source.root),
                  let list = try? PropertyListSerialization.propertyList(from: data, format: nil),
                  let items = orionItems(list)
            else {
                complete = false
                continue
            }
            out += orionTree(items)
        }
        return (out, complete)
    }

    struct OrionItem {
        var id: String
        var parent: String?
        var folder: Bool
        var title: String
        var url: String?
        var index: Int
    }

    /// The items of a favourites.plist: a dictionary of them by id, or, in
    /// case Orion ever writes it so, a list.
    static func orionItems(_ list: Any) -> [OrionItem]? {
        let raw: [(String?, [String: Any])]
        if let dict = list as? [String: Any] {
            raw = dict.compactMap { key, value in (value as? [String: Any]).map { (key, $0) } }
        } else if let array = list as? [Any] {
            raw = array.compactMap { ($0 as? [String: Any]).map { (nil, $0) } }
        } else {
            return nil
        }
        return raw.prefix(50_000).compactMap { key, item in
            guard let id = (item["id"] as? String) ?? key else { return nil }
            let type = (item["type"] as? String)?.lowercased()
            return OrionItem(id: id, parent: item["parentId"] as? String, folder: type == "folder",
                             title: (item["title"] as? String) ?? "", url: item["url"] as? String,
                             index: (item["index"] as? NSNumber)?.intValue ?? 0)
        }
    }

    /// Folders rebuilt from each item's parent, in each folder's order; an
    /// item whose parent isn't there is at the top. No deeper than 64.
    static func orionTree(_ items: [OrionItem]) -> [Bookmark] {
        let ids = Set(items.map(\.id))
        var children: [String: [OrionItem]] = [:]
        var top: [OrionItem] = []
        for item in items {
            if let parent = item.parent, parent != item.id, ids.contains(parent) { children[parent, default: []].append(item) }
            else { top.append(item) }
        }
        func ordered(_ list: [OrionItem]) -> [OrionItem] {
            list.sorted { $0.index != $1.index ? $0.index < $1.index : $0.id < $1.id }
        }
        var seen = Set<String>()
        func nodes(_ list: [OrionItem], depth: Int) -> [Bookmark] {
            guard depth < 64 else { return [] }
            return ordered(list).compactMap { item in
                guard seen.insert(item.id).inserted else { return nil }
                if item.folder {
                    let inside = nodes(children[item.id] ?? [], depth: depth + 1)
                    return inside.isEmpty ? nil : .folder(item.title.isEmpty ? "Folder" : item.title, inside)
                }
                guard let url = Arc.page(item.url) else { return nil }
                return .site(item.title, url)
            }
        }
        return nodes(top, depth: 0)
    }

    /// Safari's tree: the bar's pages at the top, the menu and the Reading
    /// List as folders, and any other folder by its name. History's proxy
    /// isn't a page. No deeper than 64.
    static func safariTree(_ root: [String: Any]) -> [Bookmark] {
        var total = 0
        func nodes(_ list: [Any], depth: Int) -> [Bookmark] {
            guard depth < 64 else { return [] }
            return list.compactMap { raw -> Bookmark? in
                guard total < 50_000, let node = raw as? [String: Any] else { return nil }
                switch node["WebBookmarkType"] as? String {
                case "WebBookmarkTypeList":
                    let inside = nodes(node["Children"] as? [Any] ?? [], depth: depth + 1)
                    let title = (node["Title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Folder"
                    return inside.isEmpty ? nil : .folder(title, inside)
                case "WebBookmarkTypeLeaf":
                    guard let url = Arc.page(node["URLString"] as? String) else { return nil }
                    total += 1
                    let title = ((node["URIDictionary"] as? [String: Any])?["title"] as? String) ?? (node["Title"] as? String) ?? ""
                    return .site(title, url)
                default:
                    return nil
                }
            }
        }
        var out: [Bookmark] = []
        for raw in root["Children"] as? [Any] ?? [] {
            guard let node = raw as? [String: Any] else { continue }
            let kids = node["Children"] as? [Any] ?? []
            switch node["Title"] as? String {
            case "BookmarksBar": out += nodes(kids, depth: 1)
            case "BookmarksMenu": if case let inside = nodes(kids, depth: 1), !inside.isEmpty { out.append(.folder("Bookmarks Menu", inside)) }
            case "com.apple.ReadingList": if case let inside = nodes(kids, depth: 1), !inside.isEmpty { out.append(.folder("Reading List", inside)) }
            default: out += nodes([raw], depth: 0)
            }
        }
        return out
    }

    // MARK: - history

    static func places(in source: Source, profile: String? = nil, limit: Int = 3000) -> [Chromium.Place] {
        var out: [Chromium.Place] = []
        for folder in source.profiles(only: profile) {
            if source.kind == .safari {
                out += safariPlaces(folder.appendingPathComponent("History.db"), limit: limit)
                continue
            }
            let file = folder.appendingPathComponent("history")
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            out += orionPlaces(file, limit: limit)
        }
        return Array(out.sorted { $0.last > $1.last }.prefix(limit))
    }

    /// Seconds since 2001, Apple's reference date, to a date.
    static let appleEpoch: TimeInterval = 978_307_200

    static func orionPlaces(_ file: URL, limit: Int) -> [Chromium.Place] {
        rows(in: file, sql: "SELECT URL, TITLE, VISIT_COUNT, LAST_VISIT_TIME FROM history_items ORDER BY ID DESC LIMIT \(max(limit, 1) * 4)") { statement in
            guard let raw = sqlite3_column_text(statement, 0), let url = Arc.page(String(cString: raw)) else { return nil }
            let title = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            let count = Int(sqlite3_column_int(statement, 2))
            var last: Date?
            switch sqlite3_column_type(statement, 3) {
            case SQLITE_INTEGER, SQLITE_FLOAT:
                let seconds = sqlite3_column_double(statement, 3)
                if seconds > 0 { last = Date(timeIntervalSince1970: seconds + appleEpoch) }
            case SQLITE_TEXT:
                last = sqlite3_column_text(statement, 3).flatMap { written(String(cString: $0)) }
            default: break
            }
            return Chromium.Place(url: url, title: title, count: max(1, count), last: last ?? .distantPast)
        }
    }

    /// Safari's places, each with its latest visit's title and time.
    static func safariPlaces(_ file: URL, limit: Int) -> [Chromium.Place] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return rows(in: file, sql: """
        SELECT i.url, v.title, i.visit_count, MAX(v.visit_time) FROM history_items i
        JOIN history_visits v ON v.history_item = i.id GROUP BY i.id ORDER BY 4 DESC LIMIT \(max(limit, 1))
        """) { statement in
            guard let raw = sqlite3_column_text(statement, 0), let url = Arc.page(String(cString: raw)) else { return nil }
            let title = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            let seconds = sqlite3_column_double(statement, 3)
            return Chromium.Place(url: url, title: title, count: max(1, Int(sqlite3_column_int(statement, 2))),
                                  last: seconds > 0 ? Date(timeIntervalSince1970: seconds + appleEpoch) : .distantPast)
        }
    }

    /// A date Orion wrote out: ISO 8601, or "yyyy-MM-dd HH:mm:ss".
    static func written(_ text: String) -> Date? {
        if let date = ISO8601DateFormatter().date(from: text) { return date }
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        for pattern in ["yyyy-MM-dd HH:mm:ss.SSS", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss"] {
            format.dateFormat = pattern
            if let date = format.date(from: text) { return date }
        }
        if let seconds = Double(text), seconds > 0 { return Date(timeIntervalSince1970: seconds + appleEpoch) }
        return nil
    }

    /// Every row a query gives on a copy of `file`, made into something by
    /// `take`; none when it can't be read.
    static func rows<T>(in file: URL, sql: String, take: (OpaquePointer) -> T?) -> [T] {
        guard let copy = try? Snapshot(of: file) else { return [] }
        var db: OpaquePointer?
        defer { sqlite3_close(db); withExtendedLifetime(copy) {} }
        guard sqlite3_open_v2(copy.file.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        var out: [T] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let row = take(statement) { out.append(row) }
        }
        return out
    }

    static func preview(of source: Source, profile: String?, limit: Int = 3000) -> ImportSource.Preview {
        ImportSource.Preview(bookmarks: Bookmarks.count(bookmarkRead(in: source, profile: profile).nodes),
                             places: places(in: source, profile: profile, limit: limit).count)
    }
}
