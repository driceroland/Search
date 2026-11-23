import Foundation
import Compression
import SQLite3

// Zen's sidebar, read: its spaces (Zen calls them workspaces), what is
// pinned in each, its folders, and the Essentials above them all. They come
// in the way Arc's do (see ImportArc.swift and Browser.takeArc): each space a
// space here, its pins that space's, the Essentials the pins every space
// shares, folders kept as folders where pinned rows can hold them.
//
// Zen has kept them three ways over its life, and each is read:
//
//  - Since its window sync (Zen 1.18, December 2025): "zen-sessions.jsonlz4"
//    in the profile, one object of spaces, tabs, folders and groups, with
//    copies in zen-sessions-backup/ for when the file is torn.
//  - Before that: the tables zen_workspaces and zen_pins in places.sqlite,
//    beside the bookmarks, a pin a row, a folder a row marked is_group.
//  - Before those: the session store's own window, its pinned tabs marked
//    with their workspace, and the spaces in "zen-workspaces.json".
//
// The .jsonlz4 files are Mozilla's: "mozLz40\0", the size unpacked as four
// bytes, then one raw LZ4 block, unpacked here by Apple's Compression.
//
// Read as damaged files are: through the same checked read every import
// uses (a regular file, no link followed, inside the profile), capped in
// size before and after unpacking, a folder no deeper than 64, 5000 pins in
// all, only http and https addresses, a password in one dropped.

enum MozLz4 {
    static let magic = Array("mozLz40\0".utf8)
    /// No session is anywhere near this unpacked; a header claiming more is
    /// a damaged one.
    static let limit = 160 << 20

    /// What a .jsonlz4 holds, or nil when it isn't one or doesn't unpack to
    /// the size it says.
    static func decode(_ data: Data, limit: Int = limit) -> Data? {
        guard data.count > 12, Array(data.prefix(8)) == magic else { return nil }
        let size = data.dropFirst(8).prefix(4).enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
        guard size > 0, size <= limit else { return nil }
        var out = Data(count: size)
        let written = out.withUnsafeMutableBytes { target -> Int in
            data.withUnsafeBytes { source -> Int in
                guard let to = target.bindMemory(to: UInt8.self).baseAddress,
                      let from = source.bindMemory(to: UInt8.self).baseAddress
                else { return 0 }
                return compression_decode_buffer(to, size, from + 12, data.count - 12, nil, COMPRESSION_LZ4_RAW)
            }
        }
        return written == size ? out : nil
    }

    /// A .jsonlz4 file inside `root`, read and unpacked as JSON.
    static func json(_ file: URL, inside root: URL) -> [String: Any]? {
        guard let packed = try? ImportRead.data(file, inside: root),
              let data = decode(packed)
        else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

enum Zen {
    /// The profile folders of a Mozilla browser: the one chosen, or every
    /// one, newest first.
    static func folders(of source: Mozilla.Source, profile: String?) -> [URL] {
        source.files(only: profile).map { $0.deletingLastPathComponent().resolvingSymlinksInPath() }
    }

    /// Zen's spaces and pins for one profile, or every one when nil; nil
    /// when none of them has a space to bring.
    static func sidebar(in source: Mozilla.Source, profile: String?) -> ArcSidebar? {
        var spaces: [ArcSidebar.Space] = []
        var essentials: [ArcSidebar.Item] = []
        for folder in folders(of: source, profile: profile) {
            guard let found = sidebar(inProfile: folder) else { continue }
            spaces += found.spaces
            for item in found.favorites where !essentials.contains(where: { $0.url == item.url }) {
                essentials.append(item)
            }
        }
        guard !spaces.isEmpty else { return nil }
        return ArcSidebar(favorites: essentials, favoritesByProfile: ["Default": essentials], spaces: spaces)
    }

    static func counts(in source: Mozilla.Source, profile: String?) -> (spaces: Int, pinned: Int)? {
        sidebar(in: source, profile: profile).map { ($0.spaces.count, $0.pinnedCount + $0.favorites.count) }
    }

    /// One profile's, the newest way Zen has kept them first.
    static func sidebar(inProfile folder: URL) -> ArcSidebar? {
        // Since window sync: the file, else its newest good copy.
        let backups = folder.appendingPathComponent("zen-sessions-backup")
        let dated = ((try? FileManager.default.contentsOfDirectory(atPath: backups.path)) ?? [])
            .filter { $0.hasPrefix("zen-sessions-") && $0.hasSuffix(".jsonlz4") }
            .sorted(by: >)
            .prefix(5)
            .map { backups.appendingPathComponent($0) }
        for file in [folder.appendingPathComponent("zen-sessions.jsonlz4"),
                     backups.appendingPathComponent("clean.jsonlz4"),
                     backups.appendingPathComponent("recovery.baklz4")] + dated {
            if let top = MozLz4.json(file, inside: folder), let found = parse(top), !found.spaces.isEmpty { return found }
        }
        // Before it: the tables in places.sqlite.
        if let found = fromPlaces(folder.appendingPathComponent("places.sqlite")), !found.spaces.isEmpty { return found }
        // Before those: the session store's window, and zen-workspaces.json.
        if let window = MozillaSession.window(in: folder) {
            var top = window
            if (top["spaces"] as? [Any])?.isEmpty ?? true,
               let data = try? ImportRead.data(folder.appendingPathComponent("zen-workspaces.json"), inside: folder),
               let old = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                top["spaces"] = old["workspaces"]
            }
            if let found = parse(top), !found.spaces.isEmpty { return found }
        }
        return nil
    }

    // MARK: - the session file's shape

    /// Zen's sidebar object — or a session window, which has the same
    /// fields: spaces, tabs (each pinned tab with the space it is in), and
    /// folders (a folder with the one it is in).
    static func parse(_ top: [String: Any]) -> ArcSidebar? {
        let rawSpaces = (top["spaces"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
        guard !rawSpaces.isEmpty else { return nil }
        var order: [String] = []
        var spaces: [String: ArcSidebar.Space] = [:]
        for raw in rawSpaces.prefix(200) {
            guard let id = raw["uuid"] as? String, spaces[id] == nil else { continue }
            order.append(id)
            spaces[id] = space(name: raw["name"] as? String)
        }
        guard let first = order.first else { return nil }

        var folders: [String: Folder] = [:]
        for case let raw as [String: Any] in (top["folders"] as? [Any]) ?? [] {
            guard let id = raw["id"] as? String else { continue }
            folders[id] = Folder(name: raw["name"] as? String, parent: raw["parentId"] as? String,
                                 split: raw["splitViewGroup"] as? Bool == true, live: raw["isLiveFolder"] as? Bool == true)
        }

        var tree = Tree()
        var essentials: [ArcSidebar.Item] = []
        for case let tab as [String: Any] in (top["tabs"] as? [Any]) ?? [] {
            let essential = truthy(tab["zenEssential"])
            guard tab["pinned"] as? Bool == true || essential,
                  !truthy(tab["zenIsGlance"]), !truthy(tab["zenIsEmpty"]),
                  (tab["zenLiveFolderItemId"] as? String).map({ $0.isEmpty }) ?? true,
                  let item = pinnedItem(tab)
            else { continue }
            if essential {
                if !essentials.contains(where: { $0.url == item.url }) && tree.count < 5000 {
                    essentials.append(item)
                    tree.count += 1
                }
                continue
            }
            let workspace = (tab["zenWorkspace"] as? String) ?? ((tab["attributes"] as? [String: Any])?["zen-workspace-id"] as? String)
            let space = workspace.flatMap { spaces[$0] != nil ? $0 : nil } ?? first
            // The folder it is in, and the ones around that: a split view
            // inside a folder is the folder's, a live folder isn't brought.
            var chain: [String] = []
            var at = tab["groupId"] as? String
            var live = false
            while let id = at, let folder = folders[id], chain.count < 64, !chain.contains(id) {
                if folder.live { live = true }
                if !folder.split { chain.append(id) }
                at = folder.parent
            }
            guard !live else { continue }
            tree.place(.item(item), in: chain, space: space, names: folders.mapValues { $0.name })
        }
        return ArcSidebar(favorites: essentials, favoritesByProfile: ["Default": essentials],
                          spaces: order.compactMap { id in
                              spaces[id].map { var space = $0; space.pinned = tree.nodes(in: id); return space }
                          })
    }

    private struct Folder {
        var name: String?
        var parent: String?
        var split = false
        var live = false
    }

    /// Pins in the order they come, each folder where its first page is,
    /// nested as the browser nests them.
    private struct Tree {
        enum Entry { case item(ArcSidebar.Item), folder(String) }
        var roots: [String: [Entry]] = [:]
        var children: [String: [Entry]] = [:]
        var names: [String: String] = [:]
        var placed = Set<String>()
        var count = 0

        /// `chain` runs from the folder the page is in out to the top one.
        mutating func place(_ entry: Entry, in chain: [String], space: String, names: [String: String?]) {
            guard count < 5000 else { return }
            if case .item = entry { count += 1 }
            var child = entry
            for id in chain {
                children[id, default: []].append(child)
                if let name = names[id] ?? nil { self.names[id] = name }
                guard placed.insert(id).inserted else { return }
                child = .folder(id)
            }
            roots[space, default: []].append(child)
        }

        func nodes(in space: String) -> [ArcSidebar.Node] { build(roots[space] ?? [], depth: 0) }

        private func build(_ entries: [Entry], depth: Int) -> [ArcSidebar.Node] {
            guard depth < 64 else { return [] }
            return entries.compactMap { entry in
                switch entry {
                case .item(let item): return .item(item)
                case .folder(let id):
                    let inside = build(children[id] ?? [], depth: depth + 1)
                    return inside.isEmpty ? nil : .folder(.init(title: Arc.named(names[id]) ?? "Folder", items: inside))
                }
            }
        }
    }

    /// A pinned tab's page: the one it was pinned at, which Zen keeps apart
    /// from wherever the tab has since gone, else where it is now.
    private static func pinnedItem(_ tab: [String: Any]) -> ArcSidebar.Item? {
        let entries = (tab["entries"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
        let index = (tab["index"] as? Int).map { min(max($0, 1), max(entries.count, 1)) - 1 } ?? (entries.count - 1)
        let current = entries.indices.contains(index) ? entries[index] : nil
        let initial = (tab["_zenPinnedInitialState"] as? [String: Any])?["entry"] as? [String: Any]
        guard let url = Arc.page(initial?["url"] as? String) ?? Arc.page(current?["url"] as? String) else { return nil }
        let title = Arc.named(tab["zenStaticLabel"] as? String) ?? Arc.named(initial?["title"] as? String)
            ?? Arc.named(current?["title"] as? String) ?? url.host() ?? url.absoluteString
        return .init(title: title, url: url)
    }

    /// Zen has written its flags as booleans and, earlier, as "true".
    private static func truthy(_ value: Any?) -> Bool {
        if let flag = value as? Bool { return flag }
        if let text = value as? String { return text == "true" }
        if let number = value as? NSNumber { return number.intValue != 0 }
        return false
    }

    // MARK: - a space

    /// A space with Zen's name: its pinned pages come in a group of it.
    static func space(name: String?) -> ArcSidebar.Space {
        ArcSidebar.Space(name: Arc.named(name) ?? "Space", profile: "Default", pinned: [])
    }

    // MARK: - places.sqlite, before window sync

    /// zen_workspaces and zen_pins, as Zen 1.x kept them until December
    /// 2025. Columns are read by name: they came one release at a time.
    static func fromPlaces(_ file: URL) -> ArcSidebar? {
        guard FileManager.default.fileExists(atPath: file.path), let copy = try? Snapshot(of: file) else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(copy.file.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }

        func rows(_ sql: String) -> [[String: Any]] {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(statement) }
            var out: [[String: Any]] = []
            while sqlite3_step(statement) == SQLITE_ROW, out.count < 10000 {
                var row: [String: Any] = [:]
                for column in 0 ..< sqlite3_column_count(statement) {
                    guard let name = sqlite3_column_name(statement, column).map({ String(cString: $0) }) else { continue }
                    switch sqlite3_column_type(statement, column) {
                    case SQLITE_INTEGER: row[name] = Int(sqlite3_column_int64(statement, column))
                    case SQLITE_FLOAT: row[name] = sqlite3_column_double(statement, column)
                    case SQLITE_TEXT: row[name] = sqlite3_column_text(statement, column).map { String(cString: $0) }
                    default: break
                    }
                }
                out.append(row)
            }
            return out
        }

        let rawSpaces = rows("SELECT * FROM zen_workspaces ORDER BY position ASC, created_at ASC")
        guard !rawSpaces.isEmpty else { return nil }
        var order: [String] = []
        var spaces: [String: ArcSidebar.Space] = [:]
        for raw in rawSpaces.prefix(200) {
            guard let id = raw["uuid"] as? String, spaces[id] == nil else { continue }
            order.append(id)
            spaces[id] = space(name: raw["name"] as? String)
        }
        guard let first = order.first else { return nil }

        let pins = rows("SELECT * FROM zen_pins ORDER BY position ASC")
        var names: [String: String?] = [:]
        var parents: [String: String] = [:]
        for pin in pins where (pin["is_group"] as? Int ?? 0) != 0 {
            guard let id = pin["uuid"] as? String else { continue }
            names[id] = pin["title"] as? String
            if let parent = pin["folder_parent_uuid"] as? String { parents[id] = parent }
        }
        var tree = Tree()
        var essentials: [ArcSidebar.Item] = []
        for pin in pins where (pin["is_group"] as? Int ?? 0) == 0 {
            guard let url = Arc.page(pin["url"] as? String) else { continue }
            let item = ArcSidebar.Item(title: Arc.named(pin["title"] as? String) ?? url.host() ?? url.absoluteString, url: url)
            if (pin["is_essential"] as? Int ?? 0) != 0 {
                if !essentials.contains(where: { $0.url == url }) && tree.count < 5000 {
                    essentials.append(item)
                    tree.count += 1
                }
                continue
            }
            let space = (pin["workspace_uuid"] as? String).flatMap { spaces[$0] != nil ? $0 : nil } ?? first
            var chain: [String] = []
            var at = pin["folder_parent_uuid"] as? String
            while let id = at, names[id] != nil, chain.count < 64, !chain.contains(id) {
                chain.append(id)
                at = parents[id]
            }
            tree.place(.item(item), in: chain, space: space, names: names)
        }
        return ArcSidebar(favorites: essentials, favoritesByProfile: ["Default": essentials],
                          spaces: order.compactMap { id in
                              spaces[id].map { var space = $0; space.pinned = tree.nodes(in: id); return space }
                          })
    }
}

// MARK: - the session store

// A Gecko browser's session store: sessionstore-backups/recovery.jsonlz4
// while it runs, sessionstore.jsonlz4 once it has quit — whichever is newer.
// Zen's oldest spaces are read from it here; its open tabs in
// ImportGeckoTabs.swift.

enum MozillaSession {
    /// The newest session store in a profile, read; nil when there is none.
    static func store(in folder: URL) -> [String: Any]? {
        let candidates = [folder.appendingPathComponent("sessionstore-backups/recovery.jsonlz4"),
                          folder.appendingPathComponent("sessionstore.jsonlz4"),
                          folder.appendingPathComponent("sessionstore-backups/recovery.baklz4")]
            .compactMap { file -> (URL, Date)? in
                guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                      values.isRegularFile == true else { return nil }
                return (file, values.contentModificationDate ?? .distantPast)
            }
            .sorted { $0.1 > $1.1 }
        for (file, _) in candidates {
            if let top = MozLz4.json(file, inside: folder) { return top }
        }
        return nil
    }

    /// Its first normal window, for Zen's oldest way of keeping its spaces.
    static func window(in folder: URL) -> [String: Any]? {
        guard let top = store(in: folder) else { return nil }
        return (top["windows"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }.first { normal($0) }
    }

    static func normal(_ window: [String: Any]) -> Bool {
        !(window["isPopup"] as? Bool ?? false) && !(window["isPrivate"] as? Bool ?? false)
            && !(window["isTaskbarTab"] as? Bool ?? false)
    }
}
