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
        /// The app itself, to say so when it is on this Mac but its data
        /// isn't where it should be.
        let app: String

        var id: String { name }

        var root: URL { Chromium.base.appendingPathComponent(folder, isDirectory: true) }

        /// Every profile: a folder holding passwords, bookmarks or history.
        /// Most browsers keep one folder per profile ("Default", "Profile 1");
        /// Opera keeps its only profile in the browser's folder itself.
        var profiles: [URL] {
            let inside = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
            return ([root] + inside).filter { folder in
                ["Login Data", "Bookmarks", "History"].contains {
                    FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
                }
            }
        }

        /// The profiles to read: the one whose folder is named, or every
        /// one when nil, which is "All profiles".
        func profiles(only: String?) -> [URL] {
            guard let only else { return profiles }
            return profiles.filter { $0.lastPathComponent == only }
        }

        /// Every profile's passwords file, or the one profile's.
        func files(only: String? = nil) -> [URL] {
            profiles(only: only).map { $0.appendingPathComponent("Login Data") }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
        }

        /// What the browser says of its profiles in "Local State", beside
        /// them: the name each folder goes by ("Work", "Person 1"), and the
        /// folder used last — "last_used", or failing that the first of
        /// "last_active_profiles".
        var localState: (names: [String: String], last: [String]) {
            let file = root.appendingPathComponent("Local State")
            guard let data = try? Data(contentsOf: file),
                  let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let profile = top["profile"] as? [String: Any]
            else { return ([:], []) }
            var names: [String: String] = [:]
            for (folder, info) in profile["info_cache"] as? [String: Any] ?? [:] {
                if let name = (info as? [String: Any])?["name"] as? String, !name.isEmpty { names[folder] = name }
            }
            let last = [profile["last_used"] as? String].compactMap { $0 } + (profile["last_active_profiles"] as? [String] ?? [])
            return (names, last)
        }

        /// Whether the app is in /Applications or ~/Applications.
        var appInstalled: Bool {
            let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
            return [URL(fileURLWithPath: "/Applications"), home].contains {
                FileManager.default.fileExists(atPath: $0.appendingPathComponent(app).path)
            }
        }
    }

    static let known: [Source] = [
        Source(name: "Dia", folder: "Dia/User Data", service: "Dia Safe Storage", account: "Dia", app: "Dia.app"),
        Source(name: "Chrome", folder: "Google/Chrome", service: "Chrome Safe Storage", account: "Chrome", app: "Google Chrome.app"),
        Source(name: "Arc", folder: "Arc/User Data", service: "Arc Safe Storage", account: "Arc", app: "Arc.app"),
        Source(name: "Brave", folder: "BraveSoftware/Brave-Browser", service: "Brave Safe Storage", account: "Brave", app: "Brave Browser.app"),
        Source(name: "Edge", folder: "Microsoft Edge", service: "Microsoft Edge Safe Storage", account: "Microsoft Edge", app: "Microsoft Edge.app"),
        Source(name: "Vivaldi", folder: "Vivaldi", service: "Vivaldi Safe Storage", account: "Vivaldi", app: "Vivaldi.app"),
        Source(name: "Chromium", folder: "Chromium", service: "Chromium Safe Storage", account: "Chromium", app: "Chromium.app"),
        // Chrome's other channels keep their own data, and share Chrome's key.
        Source(name: "Chrome Beta", folder: "Google/Chrome Beta", service: "Chrome Safe Storage", account: "Chrome", app: "Google Chrome Beta.app"),
        Source(name: "Chrome Dev", folder: "Google/Chrome Dev", service: "Chrome Safe Storage", account: "Chrome", app: "Google Chrome Dev.app"),
        Source(name: "Chrome Canary", folder: "Google/Chrome Canary", service: "Chrome Safe Storage", account: "Chrome", app: "Google Chrome Canary.app"),
        // Opera keeps its one profile in its own folder, not in one inside it.
        Source(name: "Opera", folder: "com.operasoftware.Opera", service: "Opera Safe Storage", account: "Opera", app: "Opera.app"),
        Source(name: "Opera GX", folder: "com.operasoftware.OperaGX", service: "Opera Safe Storage", account: "Opera", app: "Opera GX.app"),
        Source(name: "Helium", folder: "net.imput.helium", service: "Helium Storage Key", account: "Helium", app: "Helium.app"),
        Source(name: "Comet", folder: "Comet", service: "Comet Safe Storage", account: "Comet", app: "Comet.app"),
    ]

    /// Where browsers keep their data: ~/Library/Application Support. A test
    /// run reads made-up profiles from its own folder instead, never a real
    /// browser's.
    static var base: URL {
        if Store.testing { return Store.folder.appendingPathComponent("Import", isDirectory: true) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    /// Only the browsers actually on this Mac, with something to read.
    static func installed() -> [Source] {
        known.filter { !$0.profiles.isEmpty }
    }

    /// Browsers that are on this Mac with nothing found where their data
    /// should be — said by name, with where Search looked, rather than
    /// "no other browser found".
    static func unreadable() -> [(source: Source, looked: String)] {
        guard !Store.testing else { return [] }
        return known.filter { $0.appInstalled && $0.profiles.isEmpty }.map {
            ($0, $0.root.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
        }
    }

    enum Trouble: Error {
        case noPassphrase
        case unreadable
    }

    struct Found {
        var logins: [Login]
        /// Sites the other browser was told never to ask about.
        var never: [String]
        /// Passwords left behind for having no site to go with.
        var skipped = 0
    }

    /// The passwords of one profile, or of all of them when `profile` is
    /// nil. The key is asked for once, here, whichever it is.
    static func read(_ source: Source, profile: String? = nil) throws -> Found {
        guard let passphrase = safeStorage(source) else { throw Trouble.noPassphrase }
        let key = stretch(passphrase)

        var logins: [Login] = []
        var never: [String] = []
        var skipped = 0
        var seen = Set<String>()
        var readAny = false

        for file in source.files(only: profile) {
            guard let rows = try? rows(in: file) else { continue }
            readAny = true
            for row in rows {
                let host = Vault.host(of: row.origin)
                guard !host.isEmpty else {
                    if !row.never, !row.blob.isEmpty { skipped += 1 }
                    continue
                }
                if row.never {
                    never.append(host)
                    continue
                }
                guard let password = unwrap(row.blob, key: key), !password.isEmpty else { continue }
                let clear = row.origin.lowercased().hasPrefix("http://")
                let login = Login(host: host, user: row.user, password: password, used: row.used, clear: clear)
                guard seen.insert(login.id).inserted else { continue }
                logins.append(login)
            }
        }
        guard readAny else { throw Trouble.unreadable }
        return Found(logins: logins, never: never, skipped: skipped)
    }

    // MARK: - what they kept

    /// The other browser's bookmarks: the bar first, then anything filed
    /// elsewhere, folders and all. Chromium keeps them as one JSON file.
    static func bookmarks(in source: Source, profile: String? = nil) -> [Bookmark] {
        bookmarkRead(in: source, profile: profile).nodes
    }

    /// The same, and whether every profile asked for read cleanly: false
    /// when there was no profile to read, or a Bookmarks file there didn't
    /// read. A profile with no Bookmarks file has none — Chromium writes it
    /// with the first — and reads cleanly. Replace takes nothing out unless
    /// this is true (#375).
    static func bookmarkRead(in source: Source, profile: String? = nil) -> (nodes: [Bookmark], complete: Bool) {
        var out: [Bookmark] = []
        let profiles = source.profiles(only: profile)
        var complete = !profiles.isEmpty
        for profile in profiles {
            let marks = profile.appendingPathComponent("Bookmarks")
            guard FileManager.default.fileExists(atPath: marks.path) else { continue }
            guard let data = try? Data(contentsOf: marks),
                  let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let roots = top["roots"] as? [String: Any]
            else {
                complete = false
                continue
            }
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
        return (out, complete)
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
    static func icons(in source: Source, profile: String? = nil, for urls: [URL], limit: Int = 400) -> [String: Data] {
        var out: [String: Data] = [:]
        var wanted: [(host: String, url: URL)] = []
        var seen = Set<String>()
        for url in urls {
            guard let host = Favicons.site(url), seen.insert(host).inserted else { continue }
            wanted.append((host, url))
            if wanted.count >= limit { break }
        }
        guard !wanted.isEmpty else { return out }

        for profile in source.profiles(only: profile) {
            let icons = profile.appendingPathComponent("Favicons")
            guard FileManager.default.fileExists(atPath: icons.path),
                  let copy = try? Snapshot(of: icons)
            else { continue }
            let temp = copy.file
            defer { withExtendedLifetime(copy) {} }

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
                if let scheme = url.scheme, let home = Favicons.site(url) {
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
    static func places(in source: Source, profile: String? = nil, limit: Int = 3000) -> [Place] {
        var out: [Place] = []
        for profile in source.profiles(only: profile) {
            let history = profile.appendingPathComponent("History")
            guard FileManager.default.fileExists(atPath: history.path) else { continue }
            out += (try? placeRows(in: history, limit: limit)) ?? []
        }
        return Array(out.sorted { $0.last > $1.last }.prefix(limit))
    }

    private static func placeRows(in file: URL, limit: Int) throws -> [Place] {
        let copy = try Snapshot(of: file)
        let temp = copy.file
        // Kept to the end: the copy goes with it, and SQLite is reading it.
        defer { withExtendedLifetime(copy) {} }

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

    // MARK: - counting, before anything is brought

    /// How much there is to bring from one profile, or all of them, read
    /// from the files alone: bookmarks counted from the file, places up to
    /// the limit, and passwords as rows with something in them that aren't
    /// a site marked never. No key is asked for and nothing is decrypted,
    /// so it never prompts — safeStorage is not called from here.
    static func preview(of source: Source, profile: String?, limit: Int = 3000) -> ImportSource.Preview {
        let files = source.profiles(only: profile)
        let places = files.reduce(0) { sum, folder in
            sum + count("""
            SELECT COUNT(*) FROM urls WHERE hidden = 0 AND visit_count > 0
            AND (url LIKE 'http:%' OR url LIKE 'https:%')
            """, in: folder.appendingPathComponent("History"))
        }
        let passwords = source.files(only: profile).reduce(0) { sum, file in
            sum + count("SELECT COUNT(*) FROM logins WHERE blacklisted_by_user = 0 AND length(password_value) > 0", in: file)
        }
        return ImportSource.Preview(
            bookmarks: Bookmarks.count(bookmarks(in: source, profile: profile)),
            places: min(limit, places),
            passwords: passwords,
            extensions: extensions(in: source, profile: profile)
        )
    }

    /// One number from a copy of a SQLite file; nothing for a file that
    /// isn't there or won't answer.
    static func count(_ sql: String, in file: URL) -> Int {
        guard FileManager.default.fileExists(atPath: file.path), let copy = try? Snapshot(of: file) else { return 0 }
        defer { withExtendedLifetime(copy) {} }
        var db: OpaquePointer?
        guard sqlite3_open_v2(copy.file.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { return 0 }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return 0 }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int64(statement, 0)) : 0
    }

    /// The extensions a profile has from the Chrome Web Store, by id, to be
    /// installed fresh from the store — never copied from here. Its
    /// Preferences and Secure Preferences say where each came from: only
    /// ones the person added from the store count, not ones built in,
    /// loaded unpacked, put there by a policy or by the browser itself, nor
    /// themes. A profile without either file has only its Extensions/
    /// folders to go by.
    static func extensions(in source: Source, profile: String?) -> [String] {
        var out: [String] = []
        for folder in source.profiles(only: profile) {
            var settings: [String: [String: Any]] = [:]
            for name in ["Preferences", "Secure Preferences"] {
                guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)),
                      let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let all = (top["extensions"] as? [String: Any])?["settings"] as? [String: Any]
                else { continue }
                for (id, entry) in all {
                    guard let entry = entry as? [String: Any] else { continue }
                    settings[id, default: [:]].merge(entry) { kept, _ in kept }
                }
            }
            var ids: [String]
            if settings.isEmpty {
                ids = (try? FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("Extensions").path)) ?? []
            } else {
                ids = settings.compactMap { id, entry in
                    // Location 1 is Chromium's "internal": added by the person.
                    guard entry["location"] as? Int == 1 || entry["from_webstore"] as? Bool == true,
                          entry["was_installed_by_default"] as? Bool != true,
                          entry["was_installed_by_oem"] as? Bool != true
                    else { return nil }
                    let manifest = entry["manifest"] as? [String: Any] ?? [:]
                    guard manifest["theme"] == nil else { return nil }
                    // From another store, Edge's say: not the Chrome Web Store's to give.
                    if let update = manifest["update_url"] as? String {
                        let host = URL(string: update)?.host()?.lowercased() ?? ""
                        guard host == "google.com" || host.hasSuffix(".google.com") else { return nil }
                    }
                    return id
                }
            }
            for id in ids.sorted() where isStoreID(id) && !out.contains(id) { out.append(id) }
        }
        return out
    }

    /// Thirty-two letters from a to p: the shape of a store extension's id.
    private static func isStoreID(_ text: String) -> Bool {
        text.count == 32 && text.allSatisfy { ("a"..."p").contains($0) }
    }

    // MARK: - the key

    /// How many times the key was asked for, for the bench to see that
    /// counting never does.
    static private(set) var keyAsks = 0

    private static func safeStorage(_ source: Source) -> String? {
        keyAsks += 1
        // A test run's made-up browser keeps its key beside its profiles,
        // not in the keychain.
        if Store.testing {
            let file = source.root.appendingPathComponent("Safe Storage")
            return (try? String(contentsOf: file, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
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
        // No passphrase, no key: the logins then just don't decrypt.
        guard !pass.isEmpty else { return key }
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
        // Encrypted, as every Chromium browser on the Mac has done since
        // 2014, or not taken at all. A profile's files can be written by
        // anything running as you; a password lying there in the clear is
        // one only such a program would have put, to have Search keep it.
        guard blob.count > 3, blob.prefix(3) == Data("v10".utf8) else { return nil }
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
        let copy = try Snapshot(of: file)
        let temp = copy.file
        // Kept to the end: the copy goes with it, and SQLite is reading it.
        defer { withExtendedLifetime(copy) {} }

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

// Reading what a Mozilla browser on this Mac holds: Firefox and Zen, and
// anything else built on Gecko keeps the same shape. History and bookmarks
// live together in one SQLite file, "places.sqlite", inside each profile
// folder; the icons are in "favicons.sqlite" beside it. There are no
// passwords here yet — those come in a later change. The files are read the
// same way as a Chromium browser's: through a Snapshot, so the -wal is read
// too and the browser's own copy is left alone.

enum Mozilla {
    struct Source: Identifiable, Hashable {
        let name: String
        /// Where profiles are looked for, under the same base as Chromium's,
        /// so a test run reads made-up profiles from its own Import/ folder.
        /// Firefox keeps them under "Firefox/Profiles"; Zen's folder has been
        /// spelled a few ways over its life, so every one it has used is here.
        let folders: [String]

        var id: String { name }

        /// Every profile's places.sqlite found on this Mac, newest first, so
        /// the profile in use leads. A folder may point straight at a profile
        /// or at a directory of them.
        var files: [URL] {
            var out: [URL] = []
            for folder in folders {
                let root = Chromium.base.appendingPathComponent(folder, isDirectory: true)
                let direct = root.appendingPathComponent("places.sqlite")
                if FileManager.default.fileExists(atPath: direct.path) { out.append(direct) }
                let inside = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles)) ?? []
                for sub in inside {
                    let places = sub.appendingPathComponent("places.sqlite")
                    if FileManager.default.fileExists(atPath: places.path) { out.append(places) }
                }
            }
            var seen = Set<String>()
            return out.filter { seen.insert($0.path).inserted }.sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return da > db
            }
        }

        /// The one profile's places.sqlite, by its folder's name, or every
        /// one when nil.
        func files(only: String?) -> [URL] {
            guard let only else { return files }
            return files.filter { $0.deletingLastPathComponent().lastPathComponent == only }
        }

        /// What profiles.ini says, beside the profiles or one folder up:
        /// the name each profile folder goes by, and the one in use — the
        /// Install section's Default, which is the one the browser itself
        /// opens, or else the profile marked Default=1.
        var ini: (names: [String: String], usual: String?) {
            var names: [String: String] = [:]
            var install: String?
            var marked: String?
            for folder in folders {
                let root = Chromium.base.appendingPathComponent(folder, isDirectory: true)
                for file in [root, root.deletingLastPathComponent()].map({ $0.appendingPathComponent("profiles.ini") }) {
                    guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                    var section = ""
                    var fields: [String: String] = [:]
                    func close() {
                        let path = fields["Path"].map { URL(fileURLWithPath: $0).lastPathComponent }
                        if section.hasPrefix("Install"), let at = fields["Default"] {
                            install = install ?? URL(fileURLWithPath: at).lastPathComponent
                        } else if section.hasPrefix("Profile"), let path {
                            if let name = fields["Name"], !name.isEmpty { names[path] = name }
                            if fields["Default"] == "1" { marked = marked ?? path }
                        }
                        fields = [:]
                    }
                    for raw in text.components(separatedBy: .newlines) {
                        let line = raw.trimmingCharacters(in: .whitespaces)
                        if line.hasPrefix("["), line.hasSuffix("]") {
                            close()
                            section = String(line.dropFirst().dropLast())
                        } else if let equals = line.firstIndex(of: "=") {
                            fields[String(line[..<equals])] = String(line[line.index(after: equals)...])
                        }
                    }
                    close()
                }
            }
            return (names, install ?? marked)
        }
    }

    static let known: [Source] = [
        Source(name: "Firefox", folders: ["Firefox/Profiles", "Firefox"]),
        Source(name: "Zen", folders: ["zen/Profiles", "Zen/Profiles", "zen", "Zen"]),
    ]

    /// Only the Mozilla browsers with a profile to read.
    static func installed() -> [Source] {
        known.filter { !$0.files.isEmpty }
    }

    enum Trouble: Error {
        case unreadable
        /// A primary password is set, so the key can't be read here — the
        /// person is told to export instead.
        case primaryPassword
    }

    // MARK: - what they kept

    /// The other browser's bookmarks, every profile's run together; the merge
    /// on the way in leaves out anything already here, so profiles that share
    /// a page don't make two of it.
    static func bookmarks(in source: Source, profile: String? = nil) -> [Bookmark] {
        bookmarkRead(in: source, profile: profile).nodes
    }

    /// The same, and whether every profile's places.sqlite read (see
    /// Chromium.bookmarkRead).
    static func bookmarkRead(in source: Source, profile: String? = nil) -> (nodes: [Bookmark], complete: Bool) {
        var out: [Bookmark] = []
        let files = source.files(only: profile)
        var complete = !files.isEmpty
        for file in files {
            do { out += try bookmarkNodes(in: file) } catch { complete = false }
        }
        return (out, complete)
    }

    private struct Raw {
        let id: Int64
        let type: Int
        let parent: Int64
        let title: String
        let url: String?
        let guid: String
    }

    /// Firefox keeps bookmarks as rows in moz_bookmarks pointing at pages in
    /// moz_places, each with a parent, so the tree is rebuilt from the flat
    /// list. The toolbar's pages come first at the top, then the menu's, then
    /// Other and Mobile as folders — the same order Chromium's come in.
    private static func bookmarkNodes(in file: URL) throws -> [Bookmark] {
        let copy = try Snapshot(of: file)
        let temp = copy.file
        defer { withExtendedLifetime(copy) {} }

        var db: OpaquePointer?
        guard sqlite3_open_v2(temp.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            throw Trouble.unreadable
        }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT b.id, b.type, b.parent, b.title, p.url, b.guid
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

        var items: [Raw] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = sqlite3_column_int64(statement, 0)
            let type = Int(sqlite3_column_int(statement, 1))
            let parent = sqlite3_column_int64(statement, 2)
            let title = sqlite3_column_text(statement, 3).map { String(cString: $0) } ?? ""
            let url = sqlite3_column_text(statement, 4).map { String(cString: $0) }
            let guid = sqlite3_column_text(statement, 5).map { String(cString: $0) } ?? ""
            items.append(Raw(id: id, type: type, parent: parent, title: title, url: url, guid: guid))
        }

        var byParent: [Int64: [Raw]] = [:]
        var byGuid: [String: Raw] = [:]
        for item in items {
            byParent[item.parent, default: []].append(item)
            if !item.guid.isEmpty { byGuid[item.guid] = item }
        }

        // A page is type 1, a folder type 2. The tags folder is Firefox's own
        // bookkeeping, not bookmarks, so it is left out. A damaged file can
        // make a folder its own ancestor: each folder is taken once, and no
        // deeper than a person ever files one.
        var taken = Set<Int64>()
        func children(of parent: Int64, depth: Int = 0) -> [Bookmark] {
            guard depth < 64 else { return [] }
            return (byParent[parent] ?? []).compactMap { item in
                if item.type == 1 {
                    guard let raw = item.url, let url = URL(string: raw),
                          url.scheme == "http" || url.scheme == "https"
                    else { return nil }
                    return .site(item.title, url)
                }
                guard item.type == 2, item.guid != "tags________", taken.insert(item.id).inserted else { return nil }
                return .folder(item.title.isEmpty ? "Folder" : item.title, children(of: item.id, depth: depth + 1))
            }
        }

        var out: [Bookmark] = []
        if let toolbar = byGuid["toolbar_____"] { out += children(of: toolbar.id) }
        if let menu = byGuid["menu________"] { out += children(of: menu.id) }
        if let unfiled = byGuid["unfiled_____"] {
            let kids = children(of: unfiled.id)
            if !kids.isEmpty { out.append(.folder("Other", kids)) }
        }
        if let mobile = byGuid["mobile______"] {
            let kids = children(of: mobile.id)
            if !kids.isEmpty { out.append(.folder("Mobile", kids)) }
        }
        return out
    }

    /// The other browser's icons for the given pages, host by host, from
    /// favicons.sqlite beside places.sqlite: the largest bitmap it kept for
    /// the page, or failing that for the site's front door.
    static func icons(in source: Source, profile: String? = nil, for urls: [URL], limit: Int = 400) -> [String: Data] {
        var out: [String: Data] = [:]
        var wanted: [(host: String, url: URL)] = []
        var seen = Set<String>()
        for url in urls {
            guard let host = Favicons.site(url), seen.insert(host).inserted else { continue }
            wanted.append((host, url))
            if wanted.count >= limit { break }
        }
        guard !wanted.isEmpty else { return out }

        for file in source.files(only: profile) {
            let favicons = file.deletingLastPathComponent().appendingPathComponent("favicons.sqlite")
            guard FileManager.default.fileExists(atPath: favicons.path),
                  let copy = try? Snapshot(of: favicons)
            else { continue }
            let temp = copy.file
            defer { withExtendedLifetime(copy) {} }

            var db: OpaquePointer?
            guard sqlite3_open_v2(temp.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { continue }
            defer { sqlite3_close(db) }
            let sql = """
            SELECT i.data FROM moz_pages_w_icons p
            JOIN moz_icons_to_pages m ON m.page_id = p.id
            JOIN moz_icons i ON i.id = m.icon_id
            WHERE p.page_url = ? AND i.data IS NOT NULL
            ORDER BY i.width DESC LIMIT 1
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { continue }
            defer { sqlite3_finalize(statement) }

            for (host, url) in wanted where out[host] == nil {
                var doors = [url.absoluteString]
                if let scheme = url.scheme, let home = Favicons.site(url) {
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

    /// The other browser's history — the same Place a Chromium browser gives,
    /// so the rest of the app can't tell them apart.
    static func places(in source: Source, profile: String? = nil, limit: Int = 3000) -> [Chromium.Place] {
        var out: [Chromium.Place] = []
        for file in source.files(only: profile) {
            out += (try? placeRows(in: file, limit: limit)) ?? []
        }
        return Array(out.sorted { $0.last > $1.last }.prefix(limit))
    }

    private static func placeRows(in file: URL, limit: Int) throws -> [Chromium.Place] {
        let copy = try Snapshot(of: file)
        let temp = copy.file
        defer { withExtendedLifetime(copy) {} }

        var db: OpaquePointer?
        guard sqlite3_open_v2(temp.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            throw Trouble.unreadable
        }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT url, title, visit_count, last_visit_date FROM moz_places
        WHERE hidden = 0 AND visit_count > 0 AND last_visit_date IS NOT NULL
        ORDER BY last_visit_date DESC LIMIT \(limit)
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw Trouble.unreadable
        }
        defer { sqlite3_finalize(statement) }

        var out: [Chromium.Place] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let raw = sqlite3_column_text(statement, 0), let url = URL(string: String(cString: raw)),
                  url.scheme == "http" || url.scheme == "https"
            else { continue }
            let title = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            let count = Int(sqlite3_column_int(statement, 2))
            // Microseconds since 1970, Firefox's idea of a date — no 1601
            // offset, unlike Chromium's.
            let stamp = sqlite3_column_int64(statement, 3)
            let last = stamp > 0 ? Date(timeIntervalSince1970: Double(stamp) / 1_000_000) : Date()
            out.append(Chromium.Place(url: url, title: title, count: max(1, count), last: last))
        }
        return out
    }

    // MARK: - passwords

    // Firefox keeps its saved logins in logins.json, each field base64 DER
    // around a ciphertext, and the key that unlocks them wrapped in key4.db.
    // Most people never set a primary password, and this reads that case: the
    // empty password is checked against key4.db's own record, the key is
    // unwrapped, and each login is decrypted. When a primary password is set
    // the check fails, and rather than ask for it the panel says to export
    // from Firefox and bring in the CSV. The same Login and disabledHosts a
    // Chromium browser gives come back, so the keychain path is shared.

    /// The saved logins, and the sites the browser was told never to ask
    /// about, across every profile on this Mac.
    static func read(_ source: Source, profile: String? = nil) throws -> Chromium.Found {
        var logins: [Login] = []
        var never: [String] = []
        var skipped = 0
        var seen = Set<String>()
        var readAny = false
        var locked = false

        for file in source.files(only: profile) {
            let profile = file.deletingLastPathComponent()
            let key4 = profile.appendingPathComponent("key4.db")
            let store = profile.appendingPathComponent("logins.json")
            guard FileManager.default.fileExists(atPath: key4.path),
                  FileManager.default.fileExists(atPath: store.path)
            else { continue }
            let key: [UInt8]
            do { key = try masterKey(in: key4) }
            catch Trouble.primaryPassword { locked = true; continue }
            catch { continue }
            readAny = true
            guard let data = try? Data(contentsOf: store),
                  let doc = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            for host in (doc["disabledHosts"] as? [String]) ?? [] {
                let clean = Vault.host(of: host)
                if !clean.isEmpty { never.append(clean) }
            }
            for entry in (doc["logins"] as? [[String: Any]]) ?? [] {
                guard let origin = entry["hostname"] as? String else { continue }
                let host = Vault.host(of: origin)
                guard !host.isEmpty else {
                    skipped += 1
                    continue
                }
                guard let userB64 = entry["encryptedUsername"] as? String,
                      let passB64 = entry["encryptedPassword"] as? String,
                      let user = decryptLogin(userB64, master: key),
                      let password = decryptLogin(passB64, master: key), !password.isEmpty
                else { continue }
                let clear = origin.lowercased().hasPrefix("http://")
                let login = Login(host: host, user: user, password: password, used: nil, clear: clear)
                guard seen.insert(login.id).inserted else { continue }
                logins.append(login)
            }
        }
        // The primary-password error is only worth raising when there was
        // nothing else to bring: a second, open profile still gives its own.
        if !readAny && locked { throw Trouble.primaryPassword }
        guard readAny else { throw Trouble.unreadable }
        return Chromium.Found(logins: logins, never: never, skipped: skipped)
    }

    /// How much there is to bring, from the files alone, as Chromium's
    /// preview counts it: bookmarks from the file, places up to the limit,
    /// and the logins logins.json lists. key4.db is not opened, so a
    /// primary password is only found out at the click.
    static func preview(of source: Source, profile: String?, limit: Int = 3000) -> ImportSource.Preview {
        var places = 0, passwords = 0
        for file in source.files(only: profile) {
            places += Chromium.count("""
            SELECT COUNT(*) FROM moz_places WHERE hidden = 0 AND visit_count > 0 AND last_visit_date IS NOT NULL
            AND (url LIKE 'http:%' OR url LIKE 'https:%')
            """, in: file)
            let folder = file.deletingLastPathComponent()
            guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("key4.db").path),
                  let data = try? Data(contentsOf: folder.appendingPathComponent("logins.json")),
                  let doc = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            passwords += ((doc["logins"] as? [[String: Any]]) ?? []).filter {
                $0["hostname"] is String && ($0["encryptedPassword"] as? String)?.isEmpty == false
            }.count
        }
        return ImportSource.Preview(
            bookmarks: Bookmarks.count(bookmarks(in: source, profile: profile)),
            places: min(limit, places),
            passwords: passwords
        )
    }

    /// The key that unlocks the logins, from key4.db: the empty primary
    /// password checked against the browser's own record first, then the key
    /// itself unwrapped from nssPrivate. Throws primaryPassword when the check
    /// fails, so the caller can say to export rather than ask for one.
    private static func masterKey(in key4: URL) throws -> [UInt8] {
        let copy = try Snapshot(of: key4)
        let temp = copy.file
        defer { withExtendedLifetime(copy) {} }

        var db: OpaquePointer?
        guard sqlite3_open_v2(temp.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            throw Trouble.unreadable
        }
        defer { sqlite3_close(db) }

        // The global salt, and the check the empty password has to pass.
        var globalSalt: [UInt8] = []
        var item2: [UInt8] = []
        var meta: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT item1, item2 FROM metaData WHERE id = 'password'", -1, &meta, nil) == SQLITE_OK,
           sqlite3_step(meta) == SQLITE_ROW {
            globalSalt = blob(meta, 0)
            item2 = blob(meta, 1)
        }
        sqlite3_finalize(meta)
        guard !globalSalt.isEmpty, !item2.isEmpty else { throw Trouble.unreadable }
        let password: [UInt8] = []
        guard let check = unwrap(item2, globalSalt: globalSalt, password: password),
              check.starts(with: Array("password-check".utf8))
        else { throw Trouble.primaryPassword }

        // The wrapped key, in the nssPrivate row NSS marks with a fixed id.
        let wantedID = [0xf8] + [UInt8](repeating: 0, count: 14) + [0x01]
        var a11: [UInt8] = []
        var priv: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT a11, a102 FROM nssPrivate", -1, &priv, nil) == SQLITE_OK {
            while sqlite3_step(priv) == SQLITE_ROW {
                if blob(priv, 1) == wantedID { a11 = blob(priv, 0); break }
            }
        }
        sqlite3_finalize(priv)
        guard !a11.isEmpty, let key = unwrap(a11, globalSalt: globalSalt, password: password) else {
            throw Trouble.unreadable
        }
        return key
    }

    /// One encrypted login field: base64 around a DER SEQUENCE of the key's
    /// id, the cipher with its IV, and the ciphertext. Newer profiles use
    /// AES-256-CBC, older ones 3DES-CBC; the DER says which.
    private static func decryptLogin(_ b64: String, master: [UInt8]) -> String? {
        guard let data = Data(base64Encoded: b64) else { return nil }
        let blob = [UInt8](data)
        guard let outer = tlv(blob, 0) else { return nil }
        let parts = items(outer.body)
        guard parts.count == 3 else { return nil }
        let cipher = items(parts[1].body)
        guard cipher.count == 2 else { return nil }
        let iv = cipher[1].body
        let ct = parts[2].body
        let plain: [UInt8]?
        if oid(cipher[0].body) == "2.16.840.1.101.3.4.1.42" {
            let realIV = iv.count == 14 ? [0x04, 0x0e] + iv : iv
            plain = decryptCBC(ct, algorithm: kCCAlgorithmAES128, key: master, iv: realIV, blockSize: kCCBlockSizeAES128)
        } else {
            plain = decryptCBC(ct, algorithm: kCCAlgorithm3DES, key: Array(master.prefix(24)), iv: iv, blockSize: kCCBlockSize3DES)
        }
        return plain.flatMap { String(bytes: $0, encoding: .utf8) }
    }

    /// A key4.db entry — the check or the wrapped key — unwrapped with the
    /// empty password. Two ways it can be protected: PBES2 (PBKDF2-HMAC-SHA256
    /// then AES-256-CBC) in current Firefox, and PBE-SHA1-3DES before that.
    /// The DER around the ciphertext says which and carries the salts.
    private static func unwrap(_ blob: [UInt8], globalSalt: [UInt8], password: [UInt8]) -> [UInt8]? {
        guard let outer = tlv(blob, 0) else { return nil }
        let top = items(outer.body)
        guard top.count == 2 else { return nil }
        let algo = items(top[0].body)
        guard let algoOid = algo.first.map({ oid($0.body) }), algo.count == 2 else { return nil }
        let ciphertext = top[1].body

        if algoOid == "1.2.840.113549.1.5.13" {
            // PBES2. NSS feeds PBKDF2 the SHA-256 of the salt and the
            // password, and the real IV is the fourteen bytes it kept behind a
            // DER octet-string header.
            let params = items(algo[1].body)
            guard params.count == 2 else { return nil }
            let kdf = items(params[0].body)
            guard kdf.count == 2 else { return nil }
            let kp = items(kdf[1].body)
            guard kp.count >= 2 else { return nil }
            let entrySalt = kp[0].body
            // A corrupt file's count could be anything; NSS writes 10,000.
            guard kp[1].body.count <= 4 else { return nil }
            let rounds = integer(kp[1].body)
            guard (1...10_000_000).contains(rounds), !entrySalt.isEmpty else { return nil }
            let enc = items(params[1].body)
            guard enc.count == 2 else { return nil }
            let ck = sha256(globalSalt + password)
            guard let key = pbkdf2SHA256(ck, salt: entrySalt, rounds: rounds, length: 32) else { return nil }
            let iv = [0x04, 0x0e] + enc[1].body
            return decryptCBC(ciphertext, algorithm: kCCAlgorithmAES128, key: key, iv: iv, blockSize: kCCBlockSizeAES128)
        }
        if algoOid == "1.2.840.113549.1.12.5.1.3" {
            // PBE-SHA1-3DES. A chain of SHA-1 and HMAC-SHA-1 over the salts
            // ends in the 3DES key and its IV.
            let params = items(algo[1].body)
            guard let entrySalt = params.first?.body else { return nil }
            let hp = sha1(globalSalt + password)
            let chp = sha1(hp + entrySalt)
            var pes = entrySalt
            if pes.count < 20 { pes += [UInt8](repeating: 0, count: 20 - pes.count) } else { pes = Array(pes.prefix(20)) }
            let k1 = hmacSHA1(chp, pes + entrySalt)
            let tk = hmacSHA1(chp, pes)
            let k2 = hmacSHA1(chp, tk + entrySalt)
            let k = k1 + k2
            return decryptCBC(ciphertext, algorithm: kCCAlgorithm3DES, key: Array(k.prefix(24)), iv: Array(k.suffix(8)), blockSize: kCCBlockSize3DES)
        }
        return nil
    }

    // MARK: - the little that reads DER, and CommonCrypto

    /// One DER element at an offset: its tag, its content, and where the next
    /// begins. Enough to walk NSS's key and login structures, no more.
    private static func tlv(_ b: [UInt8], _ i: Int) -> (tag: UInt8, body: [UInt8], next: Int)? {
        guard i + 1 < b.count else { return nil }
        let tag = b[i]
        var j = i + 1
        var len = Int(b[j]); j += 1
        if len & 0x80 != 0 {
            // At most four bytes of length: nothing in key4.db is longer,
            // and more would overflow what they add up to.
            let n = len & 0x7f
            guard n > 0, n <= 4, j + n <= b.count else { return nil }
            len = 0
            for _ in 0..<n { len = (len << 8) | Int(b[j]); j += 1 }
        }
        guard len >= 0, j + len <= b.count else { return nil }
        return (tag, Array(b[j..<j + len]), j + len)
    }

    /// The elements of a constructed value, in order.
    private static func items(_ body: [UInt8]) -> [(tag: UInt8, body: [UInt8])] {
        var out: [(UInt8, [UInt8])] = []
        var i = 0
        while let one = tlv(body, i) { out.append((one.tag, one.body)); i = one.next }
        return out
    }

    /// An object identifier as its dotted string.
    private static func oid(_ body: [UInt8]) -> String {
        guard let first = body.first else { return "" }
        var parts = [Int(first) / 40, Int(first) % 40]
        var value = 0
        for byte in body.dropFirst() {
            value = (value << 7) | Int(byte & 0x7f)
            if byte & 0x80 == 0 { parts.append(value); value = 0 }
        }
        return parts.map(String.init).joined(separator: ".")
    }

    /// An unsigned integer, as key4.db's are small.
    private static func integer(_ body: [UInt8]) -> Int {
        body.reduce(0) { ($0 << 8) | Int($1) }
    }

    private static func sha256(_ b: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        CC_SHA256(b, CC_LONG(b.count), &out)
        return out
    }

    private static func sha1(_ b: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        CC_SHA1(b, CC_LONG(b.count), &out)
        return out
    }

    private static func hmacSHA1(_ key: [UInt8], _ message: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA1), key, key.count, message, message.count, &out)
        return out
    }

    private static func pbkdf2SHA256(_ pass: [UInt8], salt: [UInt8], rounds: Int, length: Int) -> [UInt8]? {
        guard !pass.isEmpty, !salt.isEmpty, rounds > 0, rounds <= Int(UInt32.max) else { return nil }
        var out = [UInt8](repeating: 0, count: length)
        let status = pass.withUnsafeBufferPointer { p in
            salt.withUnsafeBufferPointer { s in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    UnsafeRawPointer(p.baseAddress!).assumingMemoryBound(to: Int8.self), pass.count,
                    s.baseAddress!, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(rounds),
                    &out, length
                )
            }
        }
        return status == kCCSuccess ? out : nil
    }

    /// CBC decryption with PKCS#7 padding stripped, for AES-256 or 3DES.
    private static func decryptCBC(_ data: [UInt8], algorithm: Int, key: [UInt8], iv: [UInt8], blockSize: Int) -> [UInt8]? {
        // CommonCrypto reads a whole block of IV, whatever the array holds.
        guard !data.isEmpty, iv.count == blockSize else { return nil }
        var out = [UInt8](repeating: 0, count: data.count + blockSize)
        var moved = 0
        let status = CCCrypt(
            CCOperation(kCCDecrypt), CCAlgorithm(algorithm), CCOptions(kCCOptionPKCS7Padding),
            key, key.count, iv,
            data, data.count,
            &out, out.count, &moved
        )
        guard status == kCCSuccess else { return nil }
        return Array(out.prefix(moved))
    }

    private static func blob(_ statement: OpaquePointer?, _ column: Int32) -> [UInt8] {
        guard let bytes = sqlite3_column_blob(statement, column) else { return [] }
        return [UInt8](Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column))))
    }
}

/// One browser to bring things over from, whichever family it belongs to, so
/// the welcome, the panels and the bench verb work in one vocabulary and
/// Chrome and Firefox sit side by side without either knowing about the
/// other. Everything that reads takes a profile: its folder's name, or nil
/// for every profile at once.
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

    func bookmarks(profile: String? = nil) -> [Bookmark] {
        bookmarkRead(profile: profile).nodes
    }

    /// The bookmarks, and whether every profile read cleanly.
    func bookmarkRead(profile: String? = nil) -> (nodes: [Bookmark], complete: Bool) {
        switch self {
        case .chromium(let s): return Chromium.bookmarkRead(in: s, profile: profile)
        case .mozilla(let s): return Mozilla.bookmarkRead(in: s, profile: profile)
        }
    }

    func places(profile: String? = nil, limit: Int = 3000) -> [Chromium.Place] {
        switch self {
        case .chromium(let s): return Chromium.places(in: s, profile: profile, limit: limit)
        case .mozilla(let s): return Mozilla.places(in: s, profile: profile, limit: limit)
        }
    }

    func icons(profile: String? = nil, for urls: [URL]) -> [String: Data] {
        switch self {
        case .chromium(let s): return Chromium.icons(in: s, profile: profile, for: urls)
        case .mozilla(let s): return Mozilla.icons(in: s, profile: profile, for: urls)
        }
    }

    func read(profile: String? = nil) throws -> Chromium.Found {
        switch self {
        case .chromium(let s): return try Chromium.read(s, profile: profile)
        case .mozilla(let s): return try Mozilla.read(s, profile: profile)
        }
    }

    /// Whether its passwords are behind a key macOS asks about.
    var asksForKey: Bool {
        if case .chromium = self { return true }
        return false
    }

    // MARK: - profiles

    struct Profile: Identifiable, Hashable {
        /// The folder's name, which is what the readers go by.
        let id: String
        /// What the browser calls it: "Work", "Person 1", or the folder's
        /// own name when it says nothing.
        let name: String
    }

    /// Every profile, by the name the browser gives it. A browser's own
    /// Guest and System profiles aren't anybody's, and aren't offered.
    var profiles: [Profile] {
        switch self {
        case .chromium(let s):
            let names = s.localState.names
            return s.profiles.map(\.lastPathComponent)
                .filter { !["Guest Profile", "System Profile"].contains($0) }
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                .map { Profile(id: $0, name: names[$0] ?? ($0 == s.root.lastPathComponent ? s.name : $0)) }
        case .mozilla(let s):
            let names = s.ini.names
            var seen = Set<String>()
            return s.files.map { $0.deletingLastPathComponent().lastPathComponent }
                .filter { seen.insert($0).inserted }
                .map { Profile(id: $0, name: names[$0] ?? $0) }
        }
    }

    /// The profile used most recently, which is the one brought in unless
    /// another is chosen: what the browser itself says it used last, or
    /// else the profile whose files changed last.
    var usual: String? {
        let ids = profiles.map(\.id)
        switch self {
        case .chromium(let s):
            if let last = s.localState.last.first(where: ids.contains) { return last }
            func touched(_ folder: URL) -> Date {
                ["History", "Bookmarks", "Login Data"].compactMap {
                    (try? folder.appendingPathComponent($0).resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                }.max() ?? .distantPast
            }
            return s.profiles.filter { ids.contains($0.lastPathComponent) }
                .max { touched($0) < touched($1) }?.lastPathComponent
        case .mozilla(let s):
            if let usual = s.ini.usual, ids.contains(usual) { return usual }
            // The files come newest first.
            return ids.first
        }
    }

    // MARK: - counting

    /// What there is to bring, counted before anything is: never a key
    /// asked for, never a password decrypted.
    struct Preview: Equatable {
        var bookmarks = 0
        var places = 0
        var passwords = 0
        /// Chrome Web Store ids, for a Chromium browser.
        var extensions: [String] = []
    }

    func preview(profile: String?) -> Preview {
        switch self {
        case .chromium(let s): return Chromium.preview(of: s, profile: profile)
        case .mozilla(let s): return Mozilla.preview(of: s, profile: profile)
        }
    }

    static func installed() -> [ImportSource] {
        Chromium.installed().map(ImportSource.chromium) + Mozilla.installed().map(ImportSource.mozilla)
    }

    /// Whether Safari is on this Mac: its data is kept from other apps, so
    /// the sheet says how to export it instead.
    static var safari: Bool {
        FileManager.default.fileExists(atPath: "/Applications/Safari.app")
    }
}

/// A copy of one of another browser's SQLite files to read from, with the
/// two files SQLite keeps beside it while the browser runs: what was
/// written last is often still in "-wal", and a copy without it misses the
/// newest history and passwords. Gone with the copy.
final class Snapshot {
    let file: URL
    private let folder: URL

    init(of source: URL) throws {
        folder = ImportFile.scratchFolder()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        file = folder.appendingPathComponent(source.lastPathComponent)
        do {
            try FileManager.default.copyItem(at: source, to: file)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        for side in ["-wal", "-shm"] {
            let beside = URL(fileURLWithPath: source.path + side)
            guard FileManager.default.fileExists(atPath: beside.path) else { continue }
            try? FileManager.default.copyItem(at: beside, to: URL(fileURLWithPath: file.path + side))
        }
    }

    deinit { try? FileManager.default.removeItem(at: folder) }
}
