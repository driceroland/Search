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
        /// The app itself, to say so when it is on this Mac but its data
        /// isn't where it should be.
        let app: String
        var rootOverride: URL? = nil

        var id: String { name }

        var root: URL {
            if let rootOverride { return rootOverride }
            if !Store.testing, let selected = Chromium.chosenRoot(for: name) {
                return selected
            }
            return Chromium.base.appendingPathComponent(folder, isDirectory: true)
        }

        /// Every profile: a folder holding bookmarks, history or
        /// extensions. A browser used only for extensions still has something
        /// to bring over.
        /// Most browsers keep one folder per profile ("Default", "Profile 1");
        /// Opera keeps its only profile in the browser's folder itself.
        var profiles: [URL] { discovery.profiles }

        /// Keep directory errors separate from an empty, readable folder.
        var discovery: (profiles: [URL], error: Error?) {
            let root = root.resolvingSymlinksInPath()
            var inside: [URL] = []
            var error: Error?
            do {
                inside = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
            } catch let failure {
                error = failure
            }
            let found = ([root] + inside).filter { folder in
                guard contains(folder, in: root) else { return false }
                if folder != root {
                    guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return false }
                    do {
                        _ = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                    } catch let failure {
                        if error == nil { error = failure }
                    }
                }
                return ["Bookmarks", "History", "Extensions"].contains {
                    file($0, in: folder).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
                }
            }
            return (found, error)
        }

        /// Resolve before reading: a profile or file link cannot leave the
        /// browser root, whether it was picked or found in the normal place.
        func file(_ name: String, in folder: URL? = nil) -> URL? {
            let root = root.resolvingSymlinksInPath()
            let url = (folder ?? root).appendingPathComponent(name)
            return contains(url, in: root) ? url.resolvingSymlinksInPath() : nil
        }

        /// Check the opened file, then read at most 64 MB of JSON from it.
        func data(_ name: String, in folder: URL? = nil) throws -> Data {
            guard let url = file(name, in: folder) else { throw Trouble.unreadable }
            return try ImportRead.data(url, inside: root.resolvingSymlinksInPath())
        }

        private func contains(_ url: URL, in root: URL) -> Bool {
            let path = url.resolvingSymlinksInPath().standardizedFileURL.path
            let base = root.standardizedFileURL.path
            return path == base || path.hasPrefix(base + "/")
        }

        /// The profiles to read: the one whose folder is named, or every
        /// one when nil, which is "All profiles".
        func profiles(only: String?) -> [URL] {
            guard let only else { return profiles }
            return profiles.filter { $0.lastPathComponent == only }
        }

        /// What the browser says of its profiles in "Local State", beside
        /// them: the name each folder goes by ("Work", "Person 1"), and the
        /// folder used last — "last_used", or failing that the first of
        /// "last_active_profiles".
        var localState: (names: [String: String], last: [String]) {
            guard let data = try? data("Local State"),
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
        Source(name: "Dia", folder: "Dia/User Data", app: "Dia.app"),
        Source(name: "Chrome", folder: "Google/Chrome", app: "Google Chrome.app"),
        Source(name: "ego lite", folder: "Citro Labs/ego lite", app: "ego lite.app"),
        Source(name: "Arc", folder: "Arc/User Data", app: "Arc.app"),
        Source(name: "Brave", folder: "BraveSoftware/Brave-Browser", app: "Brave Browser.app"),
        Source(name: "Edge", folder: "Microsoft Edge", app: "Microsoft Edge.app"),
        Source(name: "Vivaldi", folder: "Vivaldi", app: "Vivaldi.app"),
        Source(name: "Chromium", folder: "Chromium", app: "Chromium.app"),
        // Chrome's other channels keep their own data.
        Source(name: "Chrome Beta", folder: "Google/Chrome Beta", app: "Google Chrome Beta.app"),
        Source(name: "Chrome Dev", folder: "Google/Chrome Dev", app: "Google Chrome Dev.app"),
        Source(name: "Chrome Canary", folder: "Google/Chrome Canary", app: "Google Chrome Canary.app"),
        // Opera keeps its one profile in its own folder, not in one inside it.
        Source(name: "Opera", folder: "com.operasoftware.Opera", app: "Opera.app"),
        Source(name: "Opera GX", folder: "com.operasoftware.OperaGX", app: "Opera GX.app"),
        Source(name: "Helium", folder: "net.imput.helium", app: "Helium.app"),
        Source(name: "Comet", folder: "Comet", app: "Comet.app"),
        Source(name: "Thorium", folder: "Thorium", app: "Thorium.app"),
        Source(name: "Naver Whale", folder: "Naver/Whale", app: "Whale.app"),
        Source(name: "Island", folder: "Island", app: "Island.app"),
        Source(name: "Sidekick", folder: "Sidekick", app: "Sidekick.app"),
        // ChatGPT Atlas's profiles are "user-…" folders.
        Source(name: "Yandex", folder: "Yandex/YandexBrowser", app: "Yandex.app"),
        Source(name: "ChatGPT Atlas", folder: "com.openai.atlas/browser-data/host", app: "ChatGPT Atlas.app"),
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

    /// A picked folder is trusted only while this process is running. A saved
    /// path could be changed by another process and silently redirect imports.
    private static let selectionLock = NSLock()
    private static var selectedRoots: [String: URL] = [:]

    static func chosenRoot(for name: String) -> URL? {
        selectionLock.lock()
        defer { selectionLock.unlock() }
        return selectedRoots[name]
    }

    static func useForSession(_ folder: URL, for source: Source) {
        guard !Store.testing else { return }
        selectionLock.lock()
        defer { selectionLock.unlock() }
        selectedRoots[source.name] = folder.resolvingSymlinksInPath()
    }

    struct Unavailable {
        let source: Source
        let error: Error?
        var partial = false

        var message: String {
            let looked = source.root.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
            guard let error else {
                return "\(source.name) is on this Mac, but no browser profile was found in \(looked)."
            }
            let failure = error as NSError
            if failure.domain == NSCocoaErrorDomain && failure.code == NSFileReadNoSuchFileError {
                return "\(source.name) is on this Mac, but its data folder was not found at \(looked)."
            }
            if partial {
                let reason = Self.permissionDenied(failure)
                    ? "macOS hasn't allowed Search to read all of them."
                    : failure.localizedDescription
                return "Some of \(source.name)'s profiles in \(looked) couldn't be read: \(reason) Choose its data folder in File › Bring Things Over… to allow access for this session."
            }
            if Self.permissionDenied(failure) {
                return "macOS hasn't allowed Search to read \(source.name)'s data in \(looked). Choose its data folder in File › Bring Things Over… to allow access for this session."
            }
            return "Search couldn't read \(source.name)'s data in \(looked): \(failure.localizedDescription)"
        }

        private static func permissionDenied(_ error: NSError) -> Bool {
            if error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoPermissionError { return true }
            if error.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EPERM)].contains(error.code) { return true }
            if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
                return permissionDenied(underlying)
            }
            return false
        }
    }

    /// Keep read failures visible even when another profile can be imported.
    static func unreadable() -> [Unavailable] {
        guard !Store.testing else { return [] }
        return known.filter(\.appInstalled).compactMap { source in
            let discovery = source.discovery
            guard discovery.profiles.isEmpty || discovery.error != nil else { return nil }
            return Unavailable(source: source, error: discovery.error, partial: !discovery.profiles.isEmpty)
        }
    }

    enum Trouble: Error {
        case unreadable
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
            guard let marks = source.file("Bookmarks", in: profile) else { complete = false; continue }
            guard FileManager.default.fileExists(atPath: marks.path) else { continue }
            guard let data = try? source.data("Bookmarks", in: profile),
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
            guard let icons = source.file("Favicons", in: profile), FileManager.default.fileExists(atPath: icons.path),
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
            guard let history = source.file("History", in: profile), FileManager.default.fileExists(atPath: history.path) else { continue }
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
    /// the limit.
    static func preview(of source: Source, profile: String?, limit: Int = 3000) -> ImportSource.Preview {
        let files = source.profiles(only: profile)
        let places = files.reduce(0) { sum, folder in
            guard let history = source.file("History", in: folder) else { return sum }
            return sum + count("""
            SELECT COUNT(*) FROM urls WHERE hidden = 0 AND visit_count > 0
            AND (url LIKE 'http:%' OR url LIKE 'https:%')
            """, in: history)
        }
        return ImportSource.Preview(
            bookmarks: Bookmarks.count(bookmarks(in: source, profile: profile)),
            places: min(limit, places),
            extensions: extensions(in: source, profile: profile),
            session: sessions(in: source, profile: profile)
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
                guard let data = try? source.data(name, in: folder),
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
                guard let extensions = source.file("Extensions", in: folder) else { continue }
                ids = (try? FileManager.default.contentsOfDirectory(atPath: extensions.path)) ?? []
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

}

// Reading what a Mozilla browser on this Mac holds: Firefox and Zen, and
// anything else built on Gecko keeps the same shape. History and bookmarks
// live together in one SQLite file, "places.sqlite", inside each profile
// folder; the icons are in "favicons.sqlite" beside it. The files are read the
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

        /// Zen keeps spaces, pins and Essentials of its own (see
        /// ImportZen.swift); its open tabs then leave its pins behind.
        var keepsSpaces: Bool { name == "Zen" }

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
            // One file once, however its folder was spelled: "zen" and "Zen"
            // are the same folder on a Mac's usual disk.
            var seen = Set<String>()
            return out.filter { file in
                var info = stat()
                let key = stat(file.path, &info) == 0 ? "\(info.st_dev):\(info.st_ino)" : file.path
                return seen.insert(key).inserted
            }.sorted { a, b in
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
        Source(name: "Floorp", folders: ["Floorp/Profiles", "Floorp"]),
        Source(name: "LibreWolf", folders: ["librewolf/Profiles", "LibreWolf/Profiles", "librewolf", "LibreWolf"]),
        Source(name: "Waterfox", folders: ["Waterfox/Profiles", "Waterfox"]),
        Source(name: "Mullvad Browser", folders: ["MullvadBrowser/Profiles", "MullvadBrowser"]),
    ]

    /// Only the Mozilla browsers with a profile to read.
    static func installed() -> [Source] {
        known.filter { !$0.files.isEmpty }
    }

    enum Trouble: Error {
        case unreadable
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

    /// How much there is to bring, from the files alone, as Chromium's
    /// preview counts it: bookmarks from the file, places up to the limit.
    static func preview(of source: Source, profile: String?, limit: Int = 3000) -> ImportSource.Preview {
        var places = 0
        for file in source.files(only: profile) {
            places += Chromium.count("""
            SELECT COUNT(*) FROM moz_places WHERE hidden = 0 AND visit_count > 0 AND last_visit_date IS NOT NULL
            AND (url LIKE 'http:%' OR url LIKE 'https:%')
            """, in: file)
        }
        return ImportSource.Preview(
            bookmarks: Bookmarks.count(bookmarks(in: source, profile: profile)),
            places: min(limit, places),
            session: sessions(in: source, profile: profile)
        )
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
    /// Orion and Safari: bookmarks and history (see ImportWebKit.swift).
    case webkit(WebKitBrowser.Source)

    var id: String {
        switch self {
        case .chromium(let s): return "chromium-\(s.id)"
        case .mozilla(let s): return "mozilla-\(s.id)"
        case .webkit(let s): return "webkit-\(s.id)"
        }
    }

    var name: String {
        switch self {
        case .chromium(let s): return s.name
        case .mozilla(let s): return s.name
        case .webkit(let s): return s.name
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
        case .webkit(let s): return WebKitBrowser.bookmarkRead(in: s, profile: profile)
        }
    }

    func places(profile: String? = nil, limit: Int = 3000) -> [Chromium.Place] {
        switch self {
        case .chromium(let s): return Chromium.places(in: s, profile: profile, limit: limit)
        case .mozilla(let s): return Mozilla.places(in: s, profile: profile, limit: limit)
        case .webkit(let s): return WebKitBrowser.places(in: s, profile: profile, limit: limit)
        }
    }

    func icons(profile: String? = nil, for urls: [URL]) -> [String: Data] {
        switch self {
        case .chromium(let s): return Chromium.icons(in: s, profile: profile, for: urls)
        case .mozilla(let s): return Mozilla.icons(in: s, profile: profile, for: urls)
        case .webkit: return [:]
        }
    }

    /// Whether its open tabs can be read: not a WebKit browser's.
    var readsOpenTabs: Bool {
        if case .webkit = self { return false }
        return true
    }

    /// What can come over from it at all, whatever it holds now, in the
    /// order the sheet lists them: the sheet and the Welcome say so beside it.
    var canBring: [String] {
        var out = ["bookmarks", "history"]
        switch self {
        case .chromium(let s) where s.name == "Arc": out.append("spaces & pins")
        case .mozilla(let s) where s.keepsSpaces: out.append("spaces & pins")
        default: break
        }
        if readsOpenTabs { out.append("open tabs") }
        return out
    }

    /// The same, as a line: "Bookmarks, history and open tabs".
    var canBringLine: String {
        let line = ListFormatter.localizedString(byJoining: canBring)
        return line.prefix(1).uppercased() + line.dropFirst()
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
        case .webkit(let s):
            let names = s.names
            return s.profiles.map(\.lastPathComponent)
                .map { Profile(id: $0, name: names[$0] ?? ($0 == "Defaults" ? "Default" : $0)) }
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
        case .webkit:
            return ids.first
        }
    }

    // MARK: - counting

    /// What there is to bring, counted before anything is.
    struct Preview: Equatable {
        var bookmarks = 0
        var places = 0
        /// Chrome Web Store ids, for a Chromium browser.
        var extensions: [String] = []
        /// The open tabs and tab groups, for a Chromium or Gecko browser: read here,
        /// off the main thread, and brought in from this as it is.
        var session = SessionImport.Snapshot()
    }

    func preview(profile: String?) -> Preview {
        switch self {
        case .chromium(let s): return Chromium.preview(of: s, profile: profile)
        case .mozilla(let s): return Mozilla.preview(of: s, profile: profile)
        case .webkit(let s): return WebKitBrowser.preview(of: s, profile: profile)
        }
    }

    static func installed() -> [ImportSource] {
        Chromium.installed().map(ImportSource.chromium) + Mozilla.installed().map(ImportSource.mozilla)
            + WebKitBrowser.installed().map(ImportSource.webkit)
    }

    /// Whether Safari is on this Mac and its files can't be read here (no
    /// Full Disk Access, which Search never asks for): then the sheet says
    /// how to export from it. When they can, it is in the list like any other.
    static var safari: Bool {
        FileManager.default.fileExists(atPath: "/Applications/Safari.app")
            && !WebKitBrowser.installed().contains { $0.kind == .safari }
    }
}

/// Import reads validate the opened descriptor, not just a path checked earlier.
/// JSON has a byte limit both before and during reading, including file growth.
enum ImportRead {
    static let jsonLimit = 64 * 1024 * 1024

    static func openRegular(_ url: URL, inside root: URL? = nil, limit: Int? = nil) throws -> Int32 {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        do {
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_size >= 0 else { throw Chromium.Trouble.unreadable }
            if let limit, info.st_size > limit { throw Chromium.Trouble.unreadable }
            if let root {
                var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
                let result = path.withUnsafeMutableBufferPointer { fcntl(fd, F_GETPATH, $0.baseAddress!) }
                guard result == 0 else { throw Chromium.Trouble.unreadable }
                let opened = URL(fileURLWithPath: String(cString: path)).standardizedFileURL.path
                let base = root.standardizedFileURL.path
                guard opened.hasPrefix(base + "/") else { throw Chromium.Trouble.unreadable }
            }
            return fd
        } catch {
            close(fd)
            throw error
        }
    }

    static func data(_ url: URL, inside root: URL, limit: Int = jsonLimit) throws -> Data {
        let fd = try openRegular(url, inside: root, limit: limit)
        defer { close(fd) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        var data = Data()
        while let chunk = try handle.read(upToCount: min(64 * 1024, limit - data.count + 1)), !chunk.isEmpty {
            guard chunk.count <= limit - data.count else { throw Chromium.Trouble.unreadable }
            data.append(chunk)
        }
        return data
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
            try Self.copyRegular(source, to: file)
            for side in ["-wal", "-shm"] {
                let beside = URL(fileURLWithPath: source.path + side)
                try Self.copyRegular(beside, to: URL(fileURLWithPath: file.path + side), optional: true)
            }
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    /// Open without following a final link, then copy from that descriptor.
    /// Checking a path and opening it later could copy a replacement link.
    private static func copyRegular(_ source: URL, to target: URL, optional: Bool = false) throws {
        let input: Int32
        do { input = try ImportRead.openRegular(source) }
        catch let error as POSIXError where optional && error.code == .ENOENT { return }
        defer { close(input) }
        let output = open(target.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard output >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(output) }
        guard fcopyfile(input, output, nil, copyfile_flags_t(COPYFILE_DATA)) == 0
        else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    deinit { try? FileManager.default.removeItem(at: folder) }
}
