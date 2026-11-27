import Foundation
import SQLite3
import CommonCrypto
import CryptoKit

// The spaces of three more Arc-like browsers, read into Arc's shape (see
// ImportArc.swift) so that Browser.takeArc brings them in as it brings
// Arc's: each space a space here, its favourites its pins, its pinned tabs
// rows (or tabs), its folders folders, a space with sign-ins of its own a
// profile of its own. Their bookmarks, history and passwords come the way
// every Chromium browser's do (Import.swift): each runs Chromium underneath.
//
//  - Ardia keeps its whole sidebar in one plain JSON file, session.json,
//    beside its Chromium folder. Its profiles are its spaces.
//  - Yab lists its spaces in spaces.json and keeps each one's tabs in a
//    file of its own, session.json for the first and session-<id>.json for
//    the others; the tiles every space shows in one more.
//  - Dia keeps its sidebar in tabs.db in each profile, a SQLCipher 4
//    database whose key is made from "Dia Safe Storage", the same keychain
//    item its passwords are behind. macOS asks before handing it over, so
//    Dia's spaces are read only when Bring them in is pressed, never to
//    count them.
//
// Formats learned from public, open-source readers of them (Cra, MIT); this
// is Search's own code. Read as damaged files are, as Arc's and Zen's: the
// checked read every import uses, a size cap, folders no deeper than 64,
// 5000 pinned things in all, only http and https addresses, a password in
// one dropped.

/// A pinned list built one page at a time, each with the folders it sits
/// in from the top down: folders made once, in the order first met.
struct PinnedTree {
    private final class Box {
        let title: String
        var entries: [Entry] = []
        init(title: String) { self.title = title }
    }
    private enum Entry { case item(ArcSidebar.Item), box(String) }

    private var boxes: [String: Box] = [:]
    private var top: [Entry] = []
    private(set) var count = 0

    mutating func insert(_ item: ArcSidebar.Item, path: [(id: String, name: String)]) {
        guard count < 5000 else { return }
        count += 1
        var parent: Box?
        for step in path.prefix(64) {
            if boxes[step.id] == nil {
                let made = Box(title: step.name)
                boxes[step.id] = made
                if let parent { parent.entries.append(.box(step.id)) } else { top.append(.box(step.id)) }
            }
            parent = boxes[step.id]
        }
        if let parent { parent.entries.append(.item(item)) } else { top.append(.item(item)) }
    }

    var nodes: [ArcSidebar.Node] {
        var seen = Set<String>()
        func nodes(_ entries: [Entry]) -> [ArcSidebar.Node] {
            entries.compactMap { entry in
                switch entry {
                case .item(let item): return .item(item)
                case .box(let id):
                    guard seen.insert(id).inserted, let box = boxes[id] else { return nil }
                    let inside = nodes(box.entries)
                    return inside.isEmpty ? nil : .folder(.init(title: box.title, items: inside))
                }
            }
        }
        return nodes(top)
    }
}

enum ImportSidebars {
    /// The nearest of Search's space colours (Spaces.colours) to a colour's
    /// name, as these browsers name theirs; 0, none, for any other.
    static func colour(named name: String?) -> Int {
        switch name?.lowercased() {
        case "blue", "sky", "cyan", "teal": 1
        case "green", "sage", "mint": 2
        case "orange", "yellow", "peach", "amber": 3
        case "red", "pink", "coral", "rose", "plum": 4
        case "purple", "violet", "lavender", "indigo": 5
        default: 0
        }
    }

    /// One of Search's space pictures for a browser's own: an SF Symbol
    /// Search offers, else the nearest to an emoji, else to the name.
    static func symbol(_ raw: String?, name: String) -> (emoji: String?, symbol: String) {
        guard var raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return (nil, Arc.symbol(emoji: nil, name: name))
        }
        if raw.hasPrefix("symbol:") { raw = String(raw.dropFirst("symbol:".count)) }
        if Spaces.icons.contains(raw) { return (nil, raw) }
        let isName = raw.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == ".") }
        return isName ? (nil, Arc.symbol(emoji: nil, name: name)) : (raw, Arc.symbol(emoji: raw, name: name))
    }

    /// A file of the browser's, read through the import's checked read.
    static func json(_ file: URL, inside root: URL) -> Any? {
        guard let data = try? ImportRead.data(file, inside: root.resolvingSymlinksInPath(), limit: 32 << 20) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    static func text(_ value: Any?) -> String? {
        (value as? String).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
    }
}

// MARK: - Ardia

enum Ardia {
    /// Its folder under Chromium.base (a test run's own Import folder).
    static var folder: URL { Chromium.base.appendingPathComponent("com.ardia.browser", isDirectory: true) }

    static func sidebar(profile wanted: String?) -> ArcSidebar? {
        guard let top = ImportSidebars.json(folder.appendingPathComponent("session.json"), inside: folder) as? [String: Any]
        else { return nil }
        return parse(top, profile: wanted)
    }

    static func parse(_ top: [String: Any], profile wanted: String?) -> ArcSidebar? {
        guard let profiles = top["profiles"] as? [String: Any] else { return nil }
        func byID(_ key: String) -> [String: [String: Any]] {
            var out: [String: [String: Any]] = [:]
            for case let entry as [String: Any] in (top[key] as? [Any]) ?? [] {
                if let id = entry["id"] as? String, out[id] == nil { out[id] = entry }
            }
            return out
        }
        let tabs = byID("tabs"), windows = byID("windows"), groups = byID("groups")
        let order = ((top["profileOrder"] as? [Any]) ?? []).compactMap { $0 as? String }.filter { profiles[$0] != nil }
        let ids = order + profiles.keys.filter { !order.contains($0) }.sorted()
        // The window last used first: its order is the one last seen.
        var windowIDs = ((top["windowOrder"] as? [Any]) ?? []).compactMap { $0 as? String }
        windowIDs += windows.keys.filter { !windowIDs.contains($0) }.sorted()
        if let focused = top["focusedWindowId"] as? String, windows[focused] != nil {
            windowIDs.removeAll { $0 == focused }
            windowIDs.insert(focused, at: 0)
        }

        func chain(_ id: String?, in groups: [String: [String: Any]]) -> [(id: String, name: String)] {
            var out: [(id: String, name: String)] = []
            var at = id
            while let current = at, out.count < 64, !out.contains(where: { $0.id == current }), let group = groups[current] {
                out.insert((current, ImportSidebars.text(group["name"]) ?? "Folder"), at: 0)
                at = group["parentId"] as? String
            }
            return out
        }
        // A tab's folder: the deepest pinned group listing it, as a group
        // lists its subfolders' tabs too.
        func folders(_ groups: [String: [String: Any]]) -> [String: String] {
            var of: [String: String] = [:]
            for (id, group) in groups.sorted(by: { $0.key < $1.key }) where group["pinned"] as? Bool != false {
                for case let tab as String in (group["tabIds"] as? [Any]) ?? [] {
                    if let other = of[tab], chain(other, in: groups).count >= chain(id, in: groups).count { continue }
                    of[tab] = id
                }
            }
            return of
        }
        let folderOf = folders(groups)
        let parked = top["parkedPins"] as? [String: Any] ?? [:]

        var spaces: [ArcSidebar.Space] = []
        var names: [String: String] = [:]
        for id in ids.prefix(200) {
            guard let profile = profiles[id] as? [String: Any] else { continue }
            let data = ImportSidebars.text(profile["dataId"]) ?? id
            let key = data.lowercased() == "default" ? "Default" : "Profile \(data)"
            guard wanted == nil || wanted == key else { continue }
            let name = ImportSidebars.text(profile["name"]) ?? "Space"
            if names[key] == nil {
                names[key] = ((profiles[data] as? [String: Any]).flatMap { ImportSidebars.text($0["name"]) }) ?? name
            }

            var seen = Set<String>()
            var favorites: [ArcSidebar.Item] = []
            var tree = PinnedTree()
            func take(_ tab: [String: Any], folder: String?, in groups: [String: [String: Any]]) {
                let pin = tab["pin"] as? [String: Any]
                let filed = folder.flatMap { groups[$0] } != nil
                guard pin != nil || filed else { return }
                let key = (tab["pinKey"] as? String) ?? (tab["id"] as? String) ?? UUID().uuidString
                guard seen.insert(key).inserted, let item = item(tab) else { return }
                if pin?["as"] as? String == "tile" {
                    if !favorites.contains(where: { $0.url == item.url }) { favorites.append(item) }
                } else {
                    tree.insert(item, path: chain(folder, in: groups))
                }
            }
            for window in windowIDs {
                for case let tabID as String in (windows[window]?["tabIds"] as? [Any]) ?? [] {
                    guard let tab = tabs[tabID], tab["profileId"] as? String == id else { continue }
                    take(tab, folder: folderOf[tabID], in: groups)
                }
            }
            // A profile no window is open in keeps its pins parked.
            if favorites.isEmpty && tree.count == 0, let park = parked[id] as? [String: Any] {
                var parkedGroups: [String: [String: Any]] = [:]
                for case let group as [String: Any] in (park["groups"] as? [Any]) ?? [] {
                    if let groupID = group["id"] as? String { parkedGroups[groupID] = group }
                }
                for case let tab as [String: Any] in (park["tabs"] as? [Any]) ?? [] {
                    take(tab, folder: tab["groupId"] as? String, in: parkedGroups)
                }
            }
            let look = ImportSidebars.symbol(profile["icon"] as? String, name: name)
            var space = ArcSidebar.Space(name: name, emoji: look.emoji, symbol: look.symbol, profile: key, pinned: tree.nodes,
                                         colour: ImportSidebars.colour(named: profile["color"] as? String))
            space.favorites = favorites
            spaces.append(space)
        }
        guard !spaces.isEmpty else { return nil }
        var sidebar = ArcSidebar(favorites: [], favoritesByProfile: [:], spaces: spaces)
        sidebar.profileNames = names
        return sidebar
    }

    /// A pinned tab at the page it was pinned with, else the one it shows.
    private static func item(_ tab: [String: Any]) -> ArcSidebar.Item? {
        guard let url = [tab["pinnedUrl"], tab["url"]].lazy.compactMap({ Arc.page($0 as? String) }).first else { return nil }
        let title = Arc.named(tab["customTitle"] as? String) ?? Arc.named(tab["title"] as? String) ?? url.hostCompat() ?? url.absoluteString
        return ArcSidebar.Item(title: title, url: url)
    }
}

// MARK: - Yab

enum Yab {
    static var folder: URL { Chromium.base.appendingPathComponent("Yab", isDirectory: true) }
    static let firstID = "00000000-0000-0000-0000-000000000001"
    static let sharedID = "00000000-0000-0000-0000-000000000A11"

    /// Yab's Settings › Spaces › Pins in every space. A test run's made-up
    /// Yab says so in a file of its own, never in the real preferences.
    static var pinsInEverySpace: Bool {
        if Store.testing {
            return (ImportSidebars.json(folder.appendingPathComponent("settings.json"), inside: folder) as? [String: Any])?["pins.everySpace"] as? Bool == true
        }
        return UserDefaults(suiteName: "dev.serafim.fast")?.bool(forKey: "pins.everySpace") == true
    }

    /// The Chromium folder the spaces signing in where the first one does
    /// use: the profile that is "Default" for the import.
    static var sharedFolder: String {
        let receipt = ImportSidebars.json(folder.appendingPathComponent("ChromiumProfiles/\(firstID)-shared.json"), inside: folder)
        let physical = ImportSidebars.text((receipt as? [String: Any])?["physical"])
        return "space-" + (physical ?? firstID).uppercased()
    }

    static func sidebar(profile wanted: String?) -> ArcSidebar? {
        let listed = ImportSidebars.json(folder.appendingPathComponent("spaces.json"), inside: folder) as? [Any]
        let hasFirst = FileManager.default.fileExists(atPath: folder.appendingPathComponent("session.json").path)
        guard listed != nil || hasFirst else { return nil }
        let spaces = listed?.compactMap { $0 as? [String: Any] } ?? []
        return parse(spaces.isEmpty ? [["id": firstID, "name": "Personal"]] : spaces, profile: wanted,
                     tabs: { entries(folder.appendingPathComponent($0)) }, everySpace: pinsInEverySpace,
                     sharedFolder: sharedFolder, ownFolder: ownFolder)
    }

    static func parse(_ spaces: [[String: Any]], profile wanted: String?, tabs: (String) -> [[String: Any]],
                      everySpace: Bool, sharedFolder: String, ownFolder: (String) -> String?) -> ArcSidebar? {
        let sharedTiles = everySpace ? tabs("session-\(sharedID).json").filter(isTile).compactMap(item) : []
        var out: [ArcSidebar.Space] = []
        var names: [String: String] = ["Default": "Shared"]
        for raw in spaces.prefix(200) {
            guard let id = (raw["id"] as? String)?.uppercased() else { continue }
            let name = ImportSidebars.text(raw["name"]) ?? "Space"
            let own = raw["ownSignIns"] as? Bool == true
            // Signed in on its own: the Chromium folder of the space it signs in with.
            let signsInWith = (ImportSidebars.text(raw["signInWith"]) ?? id).uppercased()
            let key = own ? (ownFolder(signsInWith) ?? "Default") : "Default"
            let matches = wanted == nil || wanted == key || (key == "Default" && wanted == sharedFolder)
            guard matches else { continue }
            if key != "Default", names[key] == nil {
                names[key] = spaces.first { ($0["id"] as? String)?.uppercased() == signsInWith }.flatMap { ImportSidebars.text($0["name"]) } ?? name
            }
            var favorites: [ArcSidebar.Item] = []
            var tree = PinnedTree()
            let rows = tabs(id == firstID ? "session.json" : "session-\(id).json")
            for entry in rows {
                if isTile(entry) {
                    // Every space signing in where the first does shows the
                    // shared tiles in place of its own.
                    guard !(everySpace && !own), let page = item(entry), !favorites.contains(where: { $0.url == page.url }) else { continue }
                    favorites.append(page)
                } else if entry["kept"] as? Bool == true, let page = item(entry) {
                    tree.insert(page, path: path(entry))
                }
            }
            if everySpace && !own { favorites = sharedTiles }
            let look = ImportSidebars.symbol(raw["icon"] as? String, name: name)
            let paint = raw["paint"] as? [String: Any]
            var space = ArcSidebar.Space(name: name, emoji: look.emoji, symbol: look.symbol, profile: key, pinned: tree.nodes,
                                         colour: ImportSidebars.colour(named: paint?["swatch"] as? String))
            space.favorites = favorites
            out.append(space)
        }
        guard !out.isEmpty else { return nil }
        var sidebar = ArcSidebar(favorites: [], favoritesByProfile: [:], spaces: out)
        sidebar.profileNames = names
        return sidebar
    }

    private static func entries(_ file: URL) -> [[String: Any]] {
        ((ImportSidebars.json(file, inside: folder) as? [String: Any])?["tabs"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
    }

    /// The Chromium folder a space with sign-ins of its own uses: the one
    /// its receipt names, else the one of its id, when it is there.
    private static func ownFolder(_ id: String) -> String? {
        let receipt = ImportSidebars.json(folder.appendingPathComponent("ChromiumProfiles/\(id)-named.json"), inside: folder)
        let physical = ImportSidebars.text((receipt as? [String: Any])?["physical"])
        let chromium = folder.appendingPathComponent("Chromium", isDirectory: true)
        return [physical, id].compactMap { $0.map { "space-" + $0.uppercased() } }
            .first { FileManager.default.fileExists(atPath: chromium.appendingPathComponent($0).path) }
    }

    private static func isTile(_ entry: [String: Any]) -> Bool { ImportSidebars.text(entry["pin"]) != nil }

    /// A kept tab or tile at the page it was kept with, else the one it shows.
    private static func item(_ entry: [String: Any]) -> ArcSidebar.Item? {
        let home = Arc.page(entry["home"] as? String)
        guard let url = home ?? Arc.page(entry["url"] as? String) else { return nil }
        let title = Arc.named(entry["name"] as? String)
            ?? Arc.named((home != nil ? entry["homeTitle"] : entry["title"]) as? String)
            ?? Arc.named(entry["title"] as? String) ?? url.hostCompat() ?? url.absoluteString
        return ArcSidebar.Item(title: title, url: url)
    }

    /// The folders a kept tab is in, from the top down.
    private static func path(_ entry: [String: Any]) -> [(id: String, name: String)] {
        guard let folder = ImportSidebars.text(entry["folder"]) else { return [] }
        let above = ((entry["folderPath"] as? [Any]) ?? []).compactMap { step -> (id: String, name: String)? in
            guard let step = step as? [String: Any], let id = ImportSidebars.text(step["id"]) else { return nil }
            return (id, ImportSidebars.text(step["name"]) ?? "Folder")
        }
        return above + [(folder, ImportSidebars.text(entry["folderName"]) ?? "Folder")]
    }
}

// MARK: - Dia

enum DiaTabs {
    /// SQLCipher 4's pages: 4096 bytes, the last 80 kept for a 16-byte IV
    /// and a 64-byte HMAC.
    static let page = 4096
    static let reserve = 80
    /// What Dia salts each database's key with (its key derivation's HMAC
    /// key, as published by readers of the format).
    static let saltKey = Data(base64Encoded: "iOe1Ue/XtonbieE/5m1nAgewvWQlePHRcKnoU10EyOM=")!

    /// The profiles holding a sidebar database, by folder name.
    static func databases(in source: Chromium.Source, profile: String?) -> [(profile: String, file: URL)] {
        source.profiles(only: profile).compactMap { folder in
            guard let file = source.file("tabs.db", in: folder), FileManager.default.fileExists(atPath: file.path) else { return nil }
            return (folder.lastPathComponent, file)
        }
    }

    /// A database's key: HKDF-SHA256 over Chromium's stretched Safe Storage
    /// key, salted with HMAC-SHA256 of the label under Dia's salt key; the
    /// label is "profile/<folder>/tabs".
    static func key(root: [UInt8], profile: String) -> Data {
        let label = Data("profile/\(profile)/tabs".utf8)
        let salt = Data(HMAC<SHA256>.authenticationCode(for: label, using: SymmetricKey(data: saltKey)))
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(root)), salt: salt, info: label, outputByteCount: 32)
        return key.withUnsafeBytes { Data($0) }
    }

    /// The database as plain SQLite, with the committed pages of its write-
    /// ahead log laid over it (Dia keeps it open, and what changed last is
    /// often only there). Nil for a wrong key or a damaged file.
    static func decrypt(_ file: URL, inside root: URL, key: Data) -> Data? {
        let limit = 256 << 20
        guard let main = try? ImportRead.data(file, inside: root, limit: limit),
              main.count >= page, main.count % page == 0 else { return nil }
        var pages: [Int: Data] = [:]
        var count = main.count / page
        for index in 0..<count { pages[index + 1] = main.subdata(in: index * page..<(index + 1) * page) }
        let walFile = URL(fileURLWithPath: file.path + "-wal")
        if let wal = try? ImportRead.data(walFile, inside: root, limit: limit), wal.count > 32, int(wal, 8) == page {
            let salt = wal.subdata(in: 16..<24)
            var pending: [Int: Data] = [:]
            var at = 32
            // A frame: its page's number, the database's size after it when
            // it ends a transaction, the log's salt, then the page. Frames of
            // an older log carry another salt; frames after the last commit
            // belong to a transaction never finished.
            while at + 24 + page <= wal.count, wal.subdata(in: at + 8..<at + 16) == salt {
                let number = int(wal, at)
                guard number >= 1, number <= 1 << 20 else { break }
                pending[number] = wal.subdata(in: at + 24..<at + 24 + page)
                let size = int(wal, at + 4)
                if size > 0 {
                    pages.merge(pending) { $1 }
                    pending = [:]
                    count = size
                }
                at += 24 + page
            }
        }
        guard count >= 1, count <= pages.count else { return nil }
        var out = Data(capacity: count * page)
        for number in 1...count {
            guard let encrypted = pages[number], let plain = decrypt(page: encrypted, first: number == 1, key: key) else { return nil }
            out.append(plain)
        }
        // The right key makes the first page SQLite's header: pages of 4096,
        // 80 bytes reserved, the payload fractions 64, 32, 32.
        guard out.count >= 100, out[16] == 0x10, out[17] == 0, out[20] == UInt8(reserve),
              out[21] == 64, out[22] == 32, out[23] == 32 else { return nil }
        return out
    }

    private static func decrypt(page data: Data, first: Bool, key: Data) -> Data? {
        // The first page starts with the key's salt where SQLite's own
        // header would be; the rest are encrypted whole.
        let start = first ? 16 : 0
        let body = data.subdata(in: start..<page - reserve)
        let iv = data.subdata(in: page - reserve..<page - reserve + 16)
        var plain = Data(count: body.count)
        var moved = 0
        let status = plain.withUnsafeMutableBytes { out in
            body.withUnsafeBytes { input in
                key.withUnsafeBytes { k in
                    iv.withUnsafeBytes { v in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), 0, k.baseAddress, key.count, v.baseAddress,
                                input.baseAddress, body.count, out.baseAddress, body.count, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess, moved == body.count else { return nil }
        return (first ? Data("SQLite format 3\0".utf8) : Data()) + plain + Data(count: reserve)
    }

    private static func int(_ data: Data, _ at: Int) -> Int {
        data.subdata(in: at..<at + 4).reduce(0) { $0 << 8 | Int($1) }
    }

    // MARK: reading it

    /// Dia's spaces in every profile chosen, read with the key macOS hands
    /// over (asked for here, so only ever from Bring them in). Nil when no
    /// database opens.
    static func sidebar(in source: Chromium.Source, profile: String?) -> ArcSidebar? {
        let databases = databases(in: source, profile: profile)
        guard !databases.isEmpty, let root = Chromium.storageKey(source) else { return nil }
        var spaces: [ArcSidebar.Space] = []
        var opened = false
        for database in databases {
            guard let plain = decrypt(database.file, inside: source.root.resolvingSymlinksInPath(),
                                      key: key(root: root, profile: database.profile)),
                  let found = read(plain, profile: database.profile)
            else { continue }
            opened = true
            spaces += found
        }
        guard opened else { return nil }
        var sidebar = ArcSidebar(favorites: [], favoritesByProfile: [:], spaces: spaces)
        sidebar.profileNames = source.localState.names
        return sidebar
    }

    /// The database's spaces: a tree of nodes, each space with a
    /// "favorites" node, a "pinned_container" and its windows; a "tab"
    /// holds a "content_pane" (two or more side by side), a "group" is a
    /// folder.
    static func read(_ plain: Data, profile: String) -> [ArcSidebar.Space]? {
        let folder = ImportFile.scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                         attributes: [.posixPermissions: 0o700])) != nil
        else { return nil }
        let file = folder.appendingPathComponent("tabs.db")
        // Only yours while it is there: it holds the tab list in the clear.
        guard FileManager.default.createFile(atPath: file.path, contents: plain, attributes: [.posixPermissions: 0o600]) else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }

        func rows(_ sql: String) -> [[String: Any]] {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(statement) }
            var out: [[String: Any]] = []
            while sqlite3_step(statement) == SQLITE_ROW, out.count < 200_000 {
                var row: [String: Any] = [:]
                for column in 0..<sqlite3_column_count(statement) {
                    let name = String(cString: sqlite3_column_name(statement, column))
                    switch sqlite3_column_type(statement, column) {
                    case SQLITE_INTEGER: row[name] = sqlite3_column_int64(statement, column)
                    case SQLITE_TEXT: row[name] = String(cString: sqlite3_column_text(statement, column))
                    default: break
                    }
                }
                out.append(row)
            }
            return out
        }

        let nodes = rows("SELECT id, kind, entity_id, parent_id, space_id FROM nodes WHERE deleted_at IS NULL ORDER BY \"order\", id")
        guard !nodes.isEmpty || !rows("SELECT id FROM spaces LIMIT 1").isEmpty else { return nil }
        var children: [Int64: [[String: Any]]] = [:]
        for node in nodes { if let parent = node["parent_id"] as? Int64 { children[parent, default: []].append(node) } }
        func byID(_ sql: String) -> [String: [String: Any]] {
            var out: [String: [String: Any]] = [:]
            for row in rows(sql) { if let id = row["id"] as? String, out[id] == nil { out[id] = row } }
            return out
        }
        let groups = byID("SELECT id, title FROM tab_groups")
        let panes = byID("SELECT p.id AS id, p.custom_title AS custom, w.url AS url, w.title AS title FROM content_panes p JOIN web_contents w ON w.content_pane_id = p.id")

        var total = 0
        func kids(_ node: [String: Any]) -> [[String: Any]] { (node["id"] as? Int64).flatMap { children[$0] } ?? [] }
        func tree(_ node: [String: Any], depth: Int) -> [ArcSidebar.Node] {
            guard depth < 64, total < 5000 else { return [] }
            let id = node["entity_id"] as? String ?? ""
            switch node["kind"] as? String {
            case "tab":
                return kids(node).flatMap { tree($0, depth: depth + 1) }
            case "content_pane":
                guard let pane = panes[id], let url = Arc.page(pane["url"] as? String) else { return [] }
                total += 1
                let title = Arc.named(pane["custom"] as? String) ?? Arc.named(pane["title"] as? String) ?? url.hostCompat() ?? url.absoluteString
                return [.item(.init(title: title, url: url))]
            case "group":
                let inside = kids(node).flatMap { tree($0, depth: depth + 1) }
                return inside.isEmpty ? [] : [.folder(.init(title: Arc.named(groups[id]?["title"] as? String) ?? "Folder", items: inside))]
            default:
                return []
            }
        }
        func contents(_ kind: String, in space: String) -> [ArcSidebar.Node] {
            nodes.filter { $0["kind"] as? String == kind && $0["space_id"] as? String == space }
                .flatMap { kids($0).flatMap { tree($0, depth: 0) } }
        }
        func flat(_ nodes: [ArcSidebar.Node]) -> [ArcSidebar.Item] {
            nodes.flatMap { node -> [ArcSidebar.Item] in
                switch node {
                case .item(let item): [item]
                case .folder(let folder): flat(folder.items)
                }
            }
        }
        return rows("SELECT id, title, theme FROM spaces ORDER BY creation_date, id").prefix(200).map { row in
            let id = row["id"] as? String ?? ""
            let name = Arc.named(row["title"] as? String) ?? "Space"
            var space = ArcSidebar.Space(name: name, emoji: nil, symbol: Arc.symbol(emoji: nil, name: name), profile: profile,
                                         pinned: contents("pinned_container", in: id),
                                         colour: ImportSidebars.colour(named: row["theme"] as? String))
            var favorites: [ArcSidebar.Item] = []
            for item in flat(contents("favorites", in: id)) where !favorites.contains(where: { $0.url == item.url }) {
                favorites.append(item)
            }
            space.favorites = favorites
            return space
        }
    }
}

extension Chromium {
    /// The browser's Safe Storage key, stretched as Chromium stretches it,
    /// for reading what else it keeps behind it (Dia's sidebar). Asks
    /// macOS, as the passwords do; kept a minute, so one Bring them in that
    /// takes both passwords and spaces asks once.
    static func storageKey(_ source: Source) -> [UInt8]? {
        // Held while macOS asks, so a second read waiting on the first
        // takes its answer rather than asking again.
        keyLock.lock()
        defer { keyLock.unlock() }
        let name = source.service + "\u{0}" + source.account
        if let kept = keptKeys[name], Date().timeIntervalSince(kept.at) < 60 { return kept.key }
        guard let passphrase = safeStoragePassphrase(source) else { return nil }
        let key = stretchedKey(passphrase)
        keptKeys[name] = (key, Date())
        return key
    }

    nonisolated(unsafe) private static var keptKeys: [String: (key: [UInt8], at: Date)] = [:]
    private static let keyLock = NSLock()
}

extension ImportSource {
    /// A browser whose spaces are behind its keychain key (Dia's): they are
    /// read only when brought in, so the sheet can't count them first.
    var sidebarAsksKey: Bool {
        if case .chromium(let source) = self { return source.name == "Dia" }
        return false
    }

    /// Ardia's, Yab's and Dia's spaces (see ImportSidebars.swift), nil for
    /// any other.
    func moreSidebar(profile: String?) -> ArcSidebar? {
        guard case .chromium(let source) = self else { return nil }
        switch source.name {
        case "Ardia": return Ardia.sidebar(profile: profile)
        case "Yab": return Yab.sidebar(profile: profile)
        case "Dia": return DiaTabs.sidebar(in: source, profile: profile)
        default: return nil
        }
    }

    /// Their counts for the sheet. Dia's can't be counted without its key:
    /// one space per profile with a sidebar, said as "its spaces".
    func moreCounts(profile: String?) -> (spaces: Int, pinned: Int)? {
        guard case .chromium(let source) = self else { return nil }
        switch source.name {
        case "Ardia", "Yab":
            return moreSidebar(profile: profile).map { ($0.spaces.count, $0.pinnedCount + $0.favorites.count) }
        case "Dia":
            let found = DiaTabs.databases(in: source, profile: profile).count
            return found > 0 ? (found, found) : nil
        default: return nil
        }
    }

    /// What Ardia and Yab call their Chromium profile folders, which are
    /// named by an id: the space whose sign-ins each holds.
    var sidebarProfileNames: [String: String] {
        guard case .chromium(let source) = self, ["Ardia", "Yab"].contains(source.name),
              var names = moreSidebar(profile: nil)?.profileNames else { return [:] }
        if source.name == "Yab", let shared = names.removeValue(forKey: "Default") { names[Yab.sharedFolder] = shared }
        return names
    }

    /// Whether it keeps spaces this can bring.
    var keepsMoreSpaces: Bool {
        guard case .chromium(let source) = self else { return false }
        return ["Ardia", "Yab", "Dia"].contains(source.name)
    }
}
