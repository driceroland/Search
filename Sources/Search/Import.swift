import Foundation
import Security
import SQLite3
import CommonCrypto

// Reading what another browser on this Mac already holds.
//
// Every Chromium browser — Chrome, Dia, Arc, Brave, Edge, the rest — keeps its
// passwords the same way: a SQLite file called "Login Data", each password
// encrypted with a key that the browser itself keeps in the macOS keychain
// under "<Name> Safe Storage". macOS asks you before handing that key to
// anyone else, which is the one thing here you have to say yes to. After
// that it is arithmetic: the key is stretched the way Chromium stretches it,
// and each password is unwrapped and put in the keychain under this app's
// name instead.
//
// The file is copied before it is read. The browser it belongs to is usually
// running, and reading its live database underneath it is how you get a lock
// error, or worse, its attention.

enum Chromium {
    struct Source: Identifiable, Hashable {
        let name: String
        /// Under ~/Library/Application Support.
        let folder: String
        let service: String
        let account: String

        var id: String { name }

        var root: URL {
            FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(folder, isDirectory: true)
        }

        /// every profile's file, each one directly inside its profile folder.
        var files: [URL] {
            ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [])
                .map { $0.appendingPathComponent("Login Data") }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
        }
    }

    static let known: [Source] = [
        Source(name: "Dia", folder: "Dia/User Data", service: "Dia Safe Storage", account: "Dia"),
        Source(name: "Chrome", folder: "Google/Chrome", service: "Chrome Safe Storage", account: "Chrome"),
        Source(name: "Arc", folder: "Arc/User Data", service: "Arc Safe Storage", account: "Arc"),
        Source(name: "Brave", folder: "BraveSoftware/Brave-Browser", service: "Brave Safe Storage", account: "Brave"),
        Source(name: "Edge", folder: "Microsoft Edge", service: "Microsoft Edge Safe Storage", account: "Microsoft Edge"),
        Source(name: "Vivaldi", folder: "Vivaldi", service: "Vivaldi Safe Storage", account: "Vivaldi"),
        Source(name: "Chromium", folder: "Chromium", service: "Chromium Safe Storage", account: "Chromium"),
    ]

    /// Only the browsers actually on this Mac, with something to read.
    static func installed() -> [Source] {
        known.filter { !$0.files.isEmpty }
    }

    enum Trouble: Error {
        case noPassphrase
        case unreadable
    }

    struct Found {
        var logins: [Login]
        /// Sites the other browser was told never to ask about.
        var never: [String]
    }

    static func read(_ source: Source) throws -> Found {
        guard let passphrase = safeStorage(source) else { throw Trouble.noPassphrase }
        let key = stretch(passphrase)

        var logins: [Login] = []
        var never: [String] = []
        var seen = Set<String>()
        var readAny = false

        for file in source.files {
            guard let rows = try? rows(in: file) else { continue }
            readAny = true
            for row in rows {
                let host = Vault.host(of: row.origin)
                guard !host.isEmpty else { continue }
                if row.never {
                    never.append(host)
                    continue
                }
                guard let password = unwrap(row.blob, key: key), !password.isEmpty else { continue }
                let login = Login(host: host, user: row.user, password: password, used: row.used)
                guard seen.insert(login.id).inserted else { continue }
                logins.append(login)
            }
        }
        guard readAny else { throw Trouble.unreadable }
        return Found(logins: logins, never: never)
    }

    // MARK: - what they kept

    /// The other browser's bookmarks: the bar first, then anything filed
    /// elsewhere, folders and all. Chromium keeps them as one JSON file.
    static func bookmarks(in source: Source) -> [Bookmark] {
        var out: [Bookmark] = []
        for file in source.files {
            let marks = file.deletingLastPathComponent().appendingPathComponent("Bookmarks")
            guard let data = try? Data(contentsOf: marks),
                  let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let roots = top["roots"] as? [String: Any]
            else { continue }
            if let bar = roots["bookmark_bar"] as? [String: Any] {
                out += nodes(in: bar["children"] as? [[String: Any]] ?? [])
            }
            for key in ["other", "synced"] {
                if let more = roots[key] as? [String: Any] {
                    let kids = nodes(in: more["children"] as? [[String: Any]] ?? [])
                    if !kids.isEmpty { out.append(.folder(key == "other" ? "Other" : "Mobile", kids)) }
                }
            }
        }
        return out
    }

    private static func nodes(in raw: [[String: Any]]) -> [Bookmark] {
        raw.compactMap { entry in
            let name = entry["name"] as? String ?? ""
            switch entry["type"] as? String {
            case "folder":
                return .folder(name, nodes(in: entry["children"] as? [[String: Any]] ?? []))
            case "url":
                guard let text = entry["url"] as? String, let url = URL(string: text),
                      url.scheme == "http" || url.scheme == "https"
                else { return nil }
                return .site(name, url)
            default:
                return nil
            }
        }
    }

    /// The other browser's icons for the given pages, host by host: the
    /// largest bitmap it kept for the page itself, or failing that for the
    /// site's front door. Read from a copy of its "Favicons" file.
    static func icons(in source: Source, for urls: [URL], limit: Int = 400) -> [String: Data] {
        var out: [String: Data] = [:]
        var wanted: [(host: String, url: URL)] = []
        var seen = Set<String>()
        for url in urls {
            guard let host = url.host()?.lowercased(), seen.insert(host).inserted else { continue }
            wanted.append((host, url))
            if wanted.count >= limit { break }
        }
        guard !wanted.isEmpty else { return out }

        for file in source.files {
            let icons = file.deletingLastPathComponent().appendingPathComponent("Favicons")
            guard FileManager.default.fileExists(atPath: icons.path) else { continue }
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent("office-import-\(UUID().uuidString).db")
            guard (try? FileManager.default.copyItem(at: icons, to: temp)) != nil else { continue }
            defer { try? FileManager.default.removeItem(at: temp) }

            var db: OpaquePointer?
            guard sqlite3_open_v2(temp.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { continue }
            defer { sqlite3_close(db) }
            let sql = """
            SELECT b.image_data FROM icon_mapping m
            JOIN favicon_bitmaps b ON b.icon_id = m.icon_id
            WHERE m.page_url = ? AND b.width BETWEEN 16 AND 256
            ORDER BY b.width DESC LIMIT 1
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { continue }
            defer { sqlite3_finalize(statement) }

            for (host, url) in wanted where out[host] == nil {
                var doors = [url.absoluteString]
                if let scheme = url.scheme, let home = url.host() {
                    doors.append("\(scheme)://\(home)/")
                }
                for door in doors {
                    sqlite3_reset(statement)
                    sqlite3_bind_text(statement, 1, door, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                    guard sqlite3_step(statement) == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else { continue }
                    let count = Int(sqlite3_column_bytes(statement, 0))
                    guard count > 60 else { continue }
                    out[host] = Data(bytes: bytes, count: count)
                    break
                }
            }
        }
        return out
    }

    // MARK: - where they have been

    struct Place {
        let url: URL
        let title: String
        let count: Int
        let last: Date
    }

    /// The other browser's history — what it takes to finish an address on
    /// the first day. Same file rules as the passwords: a copy, read once.
    static func places(in source: Source, limit: Int = 3000) -> [Place] {
        var out: [Place] = []
        for file in source.files {
            let history = file.deletingLastPathComponent().appendingPathComponent("History")
            guard FileManager.default.fileExists(atPath: history.path) else { continue }
            out += (try? placeRows(in: history, limit: limit)) ?? []
        }
        return Array(out.sorted { $0.last > $1.last }.prefix(limit))
    }

    private static func placeRows(in file: URL, limit: Int) throws -> [Place] {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("office-import-\(UUID().uuidString).db")
        try FileManager.default.copyItem(at: file, to: temp)
        defer { try? FileManager.default.removeItem(at: temp) }

        var db: OpaquePointer?
        guard sqlite3_open_v2(temp.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            throw Trouble.unreadable
        }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT url, title, visit_count, last_visit_time FROM urls
        WHERE hidden = 0 AND visit_count > 0
        ORDER BY last_visit_time DESC LIMIT \(limit)
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw Trouble.unreadable
        }
        defer { sqlite3_finalize(statement) }

        var out: [Place] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let raw = sqlite3_column_text(statement, 0), let url = URL(string: String(cString: raw)),
                  url.scheme == "http" || url.scheme == "https"
            else { continue }
            let title = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            let count = Int(sqlite3_column_int(statement, 2))
            let stamp = sqlite3_column_int64(statement, 3)
            let last = stamp > 0 ? Date(timeIntervalSince1970: Double(stamp) / 1_000_000 - 11_644_473_600) : Date()
            out.append(Place(url: url, title: title, count: max(1, count), last: last))
        }
        return out
    }

    // MARK: - the key

    private static func safeStorage(_ source: Source) -> String? {
        var out: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: source.service,
            kSecAttrAccount as String: source.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ] as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data,
              let text = String(data: data, encoding: .utf8), !text.isEmpty
        else { return nil }
        return text
    }

    /// Chromium's own recipe, unchanged for a decade: PBKDF2 over SHA-1, the
    /// salt "saltysalt", 1003 rounds, sixteen bytes out.
    private static func stretch(_ passphrase: String) -> [UInt8] {
        var key = [UInt8](repeating: 0, count: 16)
        let salt = Array("saltysalt".utf8)
        let pass = Array(passphrase.utf8)
        pass.withUnsafeBufferPointer { p in
            salt.withUnsafeBufferPointer { s in
                _ = CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    UnsafeRawPointer(p.baseAddress!).assumingMemoryBound(to: Int8.self), pass.count,
                    s.baseAddress!, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                    &key, key.count
                )
            }
        }
        return key
    }

    /// "v10" and then AES-128-CBC with an IV of sixteen spaces.
    private static func unwrap(_ blob: Data, key: [UInt8]) -> String? {
        guard blob.count > 3, blob.prefix(3) == Data("v10".utf8) else {
            // Not encrypted at all, on some very old profiles.
            return String(data: blob, encoding: .utf8)
        }
        let body = [UInt8](blob.dropFirst(3))
        let iv = [UInt8](repeating: 0x20, count: 16)
        var out = [UInt8](repeating: 0, count: body.count + kCCBlockSizeAES128)
        var moved = 0
        let status = CCCrypt(
            CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES128), CCOptions(kCCOptionPKCS7Padding),
            key, key.count, iv,
            body, body.count,
            &out, out.count, &moved
        )
        guard status == kCCSuccess else { return nil }
        let plain = Data(out.prefix(moved))
        if let text = String(data: plain, encoding: .utf8) { return text }
        // Newer builds prefix the password with a hash of the site. Past it,
        // the password is the same as ever.
        guard plain.count > 32 else { return nil }
        return String(data: plain.dropFirst(32), encoding: .utf8)
    }

    // MARK: - the file

    private struct Row {
        let origin: String
        let user: String
        let blob: Data
        let never: Bool
        let used: Date?
    }

    private static func rows(in file: URL) throws -> [Row] {
        // A copy, next to nothing the other browser is watching.
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("office-import-\(UUID().uuidString).db")
        try FileManager.default.copyItem(at: file, to: temp)
        defer { try? FileManager.default.removeItem(at: temp) }

        var db: OpaquePointer?
        guard sqlite3_open_v2(temp.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            throw Trouble.unreadable
        }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT origin_url, username_value, password_value, blacklisted_by_user, date_last_used
        FROM logins
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw Trouble.unreadable
        }
        defer { sqlite3_finalize(statement) }

        var out: [Row] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let origin = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? ""
            let user = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            var blob = Data()
            if let bytes = sqlite3_column_blob(statement, 2) {
                blob = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 2)))
            }
            let never = sqlite3_column_int(statement, 3) != 0
            // Microseconds since 1601, Chromium's idea of a date.
            let stamp = sqlite3_column_int64(statement, 4)
            let used = stamp > 0 ? Date(timeIntervalSince1970: Double(stamp) / 1_000_000 - 11_644_473_600) : nil
            out.append(Row(origin: origin, user: user, blob: blob, never: never, used: used))
        }
        return out
    }
}

// Reading from Mozilla / Gecko browsers (Firefox, Zen).
//
// Mozilla browsers store history and bookmarks in SQLite files called
// "places.sqlite" inside each profile folder under ~/Library/Application Support.
// The file is copied to a temporary location before reading with SQLite in
// read-only mode so open browsers with active database locks don't block
// or fail the read.

enum Mozilla {
    struct Source: Identifiable, Hashable {
        let name: String
        /// Profile search directories under ~/Library/Application Support.
        let folders: [String]

        var id: String { name }

        /// Every profile's places.sqlite file discovered on this Mac, newest first.
        var files: [URL] {
            let appSupport = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            var out: [URL] = []
            for folder in folders {
                let root = appSupport.appendingPathComponent(folder, isDirectory: true)
                guard FileManager.default.fileExists(atPath: root.path) else { continue }
                // Direct file if a profile folder was specified directly.
                let direct = root.appendingPathComponent("places.sqlite")
                if FileManager.default.fileExists(atPath: direct.path) {
                    out.append(direct)
                }
                // Profiles nested inside this folder (e.g. Profiles/*).
                if let subs = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles) {
                    for sub in subs {
                        let places = sub.appendingPathComponent("places.sqlite")
                        if FileManager.default.fileExists(atPath: places.path) {
                            out.append(places)
                        }
                    }
                }
            }
            var seen = Set<String>()
            let unique = out.filter { seen.insert($0.path).inserted }
            return unique.sorted { a, b in
                let aDate = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date.distantPast
                let bDate = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date.distantPast
                return aDate > bDate
            }
        }
    }

    static let known: [Source] = [
        Source(name: "Firefox", folders: ["Firefox/Profiles", "Firefox"]),
        Source(name: "Zen", folders: ["zen/Profiles", "Zen/Profiles", "zen", "Zen"]),
    ]

    /// Installed Mozilla browsers that have at least one readable profile.
    static func installed() -> [Source] {
        known.filter { !$0.files.isEmpty }
    }

    enum Trouble: Error {
        case unreadable
    }

    // MARK: - bookmarks

    /// Bookmarks reconstructed from moz_bookmarks and moz_places: toolbar
    /// items first, then menu items and folders like Other and Mobile.
    static func bookmarks(in source: Source) -> [Bookmark] {
        bookmarks(in: source.files)
    }

    static func bookmarks(in files: [URL]) -> [Bookmark] {
        var out: [Bookmark] = []
        var seenURLs = Set<String>()

        func deduplicate(_ list: [Bookmark]) -> [Bookmark] {
            var res: [Bookmark] = []
            for b in list {
                if let url = b.url {
                    if seenURLs.insert(url).inserted {
                        res.append(b)
                    }
                } else {
                    let children = deduplicate(b.children ?? [])
                    if !children.isEmpty {
                        var folder = b
                        folder.children = children
                        res.append(folder)
                    }
                }
            }
            return res
        }

        for file in files {
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            if let nodes = try? bookmarkNodes(in: file) {
                out += deduplicate(nodes)
            }
        }
        return out
    }

    /// Safely copy a SQLite database and its WAL/SHM sidecars to an isolated temporary folder.
    private static func copyDatabaseWithWAL(from source: URL, prefix: String) throws -> (file: URL, cleanup: () -> Void) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let dest = folder.appendingPathComponent(source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: dest)

        let wal = source.deletingLastPathComponent().appendingPathComponent("\(source.lastPathComponent)-wal")
        if FileManager.default.fileExists(atPath: wal.path) {
            let destWAL = folder.appendingPathComponent("\(source.lastPathComponent)-wal")
            try? FileManager.default.copyItem(at: wal, to: destWAL)
        }

        let shm = source.deletingLastPathComponent().appendingPathComponent("\(source.lastPathComponent)-shm")
        if FileManager.default.fileExists(atPath: shm.path) {
            let destSHM = folder.appendingPathComponent("\(source.lastPathComponent)-shm")
            try? FileManager.default.copyItem(at: shm, to: destSHM)
        }

        let cleanup: () -> Void = {
            _ = try? FileManager.default.removeItem(at: folder)
        }
        return (dest, cleanup)
    }

    private struct RawBookmark {
        let id: Int64
        let type: Int
        let parent: Int64
        let position: Int
        let title: String
        let url: String?
        let guid: String
    }

    private static func bookmarkNodes(in file: URL) throws -> [Bookmark] {
        let (temp, cleanup) = try copyDatabaseWithWAL(from: file, prefix: "office-import-moz-bm")
        defer { cleanup() }

        var db: OpaquePointer?
        guard sqlite3_open_v2(temp.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            throw Trouble.unreadable
        }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT b.id, b.type, b.parent, b.position, b.title, p.url, b.guid
        FROM moz_bookmarks b
        LEFT JOIN moz_places p ON b.fk = p.id
        WHERE b.type IN (1, 2)
        ORDER BY b.position ASC
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw Trouble.unreadable
        }
        defer { sqlite3_finalize(statement) }

        var items: [RawBookmark] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = sqlite3_column_int64(statement, 0)
            let type = Int(sqlite3_column_int(statement, 1))
            let parent = sqlite3_column_int64(statement, 2)
            let position = Int(sqlite3_column_int(statement, 3))
            let title = sqlite3_column_text(statement, 4).map { String(cString: $0) } ?? ""
            let url = sqlite3_column_text(statement, 5).map { String(cString: $0) }
            let guid = sqlite3_column_text(statement, 6).map { String(cString: $0) } ?? ""
            items.append(RawBookmark(id: id, type: type, parent: parent, position: position, title: title, url: url, guid: guid))
        }

        var byParent: [Int64: [RawBookmark]] = [:]
        var byGuid: [String: RawBookmark] = [:]
        for item in items {
            byParent[item.parent, default: []].append(item)
            if !item.guid.isEmpty {
                byGuid[item.guid] = item
            }
        }

        func buildChildren(of parentID: Int64) -> [Bookmark] {
            guard let kids = byParent[parentID] else { return [] }
            return kids.compactMap { item in
                if item.type == 1 {
                    guard let raw = item.url, let url = URL(string: raw),
                          url.scheme == "http" || url.scheme == "https"
                    else { return nil }
                    return .site(item.title, url)
                } else if item.type == 2 {
                    if item.guid == "tags________" { return nil }
                    let nested = buildChildren(of: item.id)
                    return .folder(item.title.isEmpty ? "Folder" : item.title, nested)
                }
                return nil
            }
        }

        var out: [Bookmark] = []

        // Bookmarks toolbar items come first at top level.
        if let tb = byGuid["toolbar_____"] {
            out += buildChildren(of: tb.id)
        }

        // Bookmarks menu items next.
        if let mn = byGuid["menu________"] {
            out += buildChildren(of: mn.id)
        }

        // Other / unfiled bookmarks.
        if let uf = byGuid["unfiled_____"] {
            let kids = buildChildren(of: uf.id)
            if !kids.isEmpty { out.append(.folder("Other", kids)) }
        }

        // Mobile bookmarks.
        if let mb = byGuid["mobile______"] {
            let kids = buildChildren(of: mb.id)
            if !kids.isEmpty { out.append(.folder("Mobile", kids)) }
        }

        // Any custom root items that are not standard containers or tags.
        let standardGuids: Set<String> = [
            "root________", "menu________", "toolbar_____", "tags________", "unfiled_____", "mobile______"
        ]
        let rootID = byGuid["root________"]?.id ?? (items.first(where: { $0.parent == 0 })?.id ?? 1)
        if let customRoots = byParent[rootID] {
            for item in customRoots where !standardGuids.contains(item.guid) {
                if item.type == 1 {
                    guard let raw = item.url, let url = URL(string: raw),
                          url.scheme == "http" || url.scheme == "https"
                    else { continue }
                    out.append(.site(item.title, url))
                } else if item.type == 2 {
                    let kids = buildChildren(of: item.id)
                    out.append(.folder(item.title.isEmpty ? "Folder" : item.title, kids))
                }
            }
        }

        return out
    }

    // MARK: - history

    /// The other browser's history from moz_places. Safely copied to a temporary
    /// file to read past running browser locks.
    static func places(in source: Source, limit: Int = 3000) -> [Chromium.Place] {
        places(in: source.files, limit: limit)
    }

    static func places(in files: [URL], limit: Int = 3000) -> [Chromium.Place] {
        var out: [Chromium.Place] = []
        for file in files {
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            out += (try? placeRows(in: file, limit: limit)) ?? []
        }
        return Array(out.sorted { $0.last > $1.last }.prefix(limit))
    }

    private static func placeRows(in file: URL, limit: Int) throws -> [Chromium.Place] {
        let (temp, cleanup) = try copyDatabaseWithWAL(from: file, prefix: "office-import-moz-hist")
        defer { cleanup() }

        var db: OpaquePointer?
        guard sqlite3_open_v2(temp.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            throw Trouble.unreadable
        }
        defer { sqlite3_close(db) }

        var statement: OpaquePointer?
        let sqlWithHidden = """
        SELECT url, title, visit_count, last_visit_date FROM moz_places
        WHERE hidden = 0 AND visit_count > 0 AND last_visit_date IS NOT NULL
        ORDER BY last_visit_date DESC LIMIT \(limit)
        """
        if sqlite3_prepare_v2(db, sqlWithHidden, -1, &statement, nil) != SQLITE_OK {
            let sqlSimple = """
            SELECT url, title, visit_count, last_visit_date FROM moz_places
            WHERE visit_count > 0 AND last_visit_date IS NOT NULL
            ORDER BY last_visit_date DESC LIMIT \(limit)
            """
            guard sqlite3_prepare_v2(db, sqlSimple, -1, &statement, nil) == SQLITE_OK, statement != nil else {
                throw Trouble.unreadable
            }
        }
        guard let statement else { throw Trouble.unreadable }
        defer { sqlite3_finalize(statement) }

        var out: [Chromium.Place] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let raw = sqlite3_column_text(statement, 0),
                  let url = URL(string: String(cString: raw)),
                  url.scheme == "http" || url.scheme == "https"
            else { continue }
            let title = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            let count = Int(sqlite3_column_int(statement, 2))
            let stamp = sqlite3_column_int64(statement, 3)
            // Microseconds since Unix epoch 1970.
            let last = stamp > 0 ? Date(timeIntervalSince1970: Double(stamp) / 1_000_000) : Date()
            out.append(Chromium.Place(url: url, title: title, count: max(1, count), last: last))
        }
        return out
    }

    // MARK: - icons

    /// Icons from favicons.sqlite next to places.sqlite.
    static func icons(in source: Source, for urls: [URL], limit: Int = 400) -> [String: Data] {
        var out: [String: Data] = [:]
        var wanted: [(host: String, url: URL)] = []
        var seen = Set<String>()
        for url in urls {
            guard let host = url.host()?.lowercased(), seen.insert(host).inserted else { continue }
            wanted.append((host, url))
            if wanted.count >= limit { break }
        }
        guard !wanted.isEmpty else { return out }

        for file in source.files {
            let favicons = file.deletingLastPathComponent().appendingPathComponent("favicons.sqlite")
            guard FileManager.default.fileExists(atPath: favicons.path) else { continue }
            guard let (temp, cleanup) = try? copyDatabaseWithWAL(from: favicons, prefix: "office-import-moz-fav") else { continue }
            defer { cleanup() }

            var db: OpaquePointer?
            guard sqlite3_open_v2(temp.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { continue }
            defer { sqlite3_close(db) }

            let sql = """
            SELECT i.data FROM moz_pages_w_icons p
            JOIN moz_icons_to_pages ip ON ip.page_id = p.id
            JOIN moz_icons i ON i.id = ip.icon_id
            WHERE p.page_url = ? AND i.data IS NOT NULL
            ORDER BY i.width DESC LIMIT 1
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { continue }
            defer { sqlite3_finalize(statement) }

            for (host, url) in wanted where out[host] == nil {
                var doors = [url.absoluteString]
                if let scheme = url.scheme, let home = url.host() {
                    doors.append("\(scheme)://\(home)/")
                }
                for door in doors {
                    sqlite3_reset(statement)
                    sqlite3_bind_text(statement, 1, door, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                    guard sqlite3_step(statement) == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else { continue }
                    let count = Int(sqlite3_column_bytes(statement, 0))
                    guard count > 60 else { continue }
                    out[host] = Data(bytes: bytes, count: count)
                    break
                }
            }
        }
        return out
    }
}

/// Unified source representation across Chromium and Mozilla browsers.
enum ImportSource: Identifiable, Hashable {
    case chromium(Chromium.Source)
    case mozilla(Mozilla.Source)

    var id: String {
        switch self {
        case .chromium(let s): return "chromium-\(s.id)"
        case .mozilla(let s): return "mozilla-\(s.id)"
        }
    }

    var name: String {
        switch self {
        case .chromium(let s): return s.name
        case .mozilla(let s): return s.name
        }
    }

    var hasPasswords: Bool {
        switch self {
        case .chromium: return true
        case .mozilla: return false
        }
    }

    static func installed() -> [ImportSource] {
        Chromium.installed().map(ImportSource.chromium) + Mozilla.installed().map(ImportSource.mozilla)
    }
}

