import Foundation

// One-click profile migration, part A: the current profile as files.
//
// Part B takes these back in on another Mac. What's here is the leaving
// half: the profile's own files copied byte for byte, the shared ones
// alongside for import to remap, and the settings cut to what another copy
// may honour. Passwords, cookies and anything signed stay where they are —
// the keychain and WebKit's stores never enter a file.

struct SearchProfileManifest: Codable {
    var format: Int
    var appVersion: String
    var scope: String
    var exportedAt: Date
    var counts: [String: Int]
}

// A UserDefaults value that survives a round trip through JSON. Data keeps a
// marker so it doesn't come back as the string its base64 happens to read as;
// dates the same, since JSON has no date of its own.
struct AnyCodable: Codable {
    var value: Any

    init?(_ value: Any) {
        switch value {
        case is Bool:
            self.value = value
        case is Int:
            self.value = value
        case let kept as Double:
            self.value = kept
        case let kept as String:
            self.value = kept
        case let kept as Data:
            self.value = kept
        case let kept as Date:
            self.value = kept
        case let kept as [Any]:
            var out: [Any] = []
            out.reserveCapacity(kept.count)
            for item in kept {
                guard let wrapped = AnyCodable(item) else { return nil }
                out.append(wrapped.value)
            }
            self.value = out
        case let kept as [String: Any]:
            var out: [String: Any] = [:]
            for (key, item) in kept {
                guard let wrapped = AnyCodable(item) else { return nil }
                out[key] = wrapped.value
            }
            self.value = out
        default:
            return nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var into = encoder.singleValueContainer()
        switch value {
        case let kept as Bool:
            try into.encode(kept)
        case let kept as Int:
            try into.encode(kept)
        case let kept as Double:
            try into.encode(kept)
        case let kept as String:
            try into.encode(kept)
        case let kept as Data:
            try into.encode(["$data": kept.base64EncodedString()])
        case let kept as Date:
            try into.encode(["$date": kept.timeIntervalSince1970])
        case let kept as [Any]:
            var wrapped: [AnyCodable] = []
            wrapped.reserveCapacity(kept.count)
            for item in kept {
                guard let one = AnyCodable(item) else {
                    throw EncodingError.invalidValue(item, EncodingError.Context(codingPath: into.codingPath, debugDescription: "unsupported pref value"))
                }
                wrapped.append(one)
            }
            try into.encode(wrapped)
        case let kept as [String: Any]:
            var wrapped: [String: AnyCodable] = [:]
            for (key, item) in kept {
                guard let one = AnyCodable(item) else {
                    throw EncodingError.invalidValue(item, EncodingError.Context(codingPath: into.codingPath, debugDescription: "unsupported pref value"))
                }
                wrapped[key] = one
            }
            try into.encode(wrapped)
        default:
            throw EncodingError.invalidValue(value, EncodingError.Context(codingPath: into.codingPath, debugDescription: "unsupported pref value"))
        }
    }

    init(from decoder: Decoder) throws {
        let from = try decoder.singleValueContainer()
        if from.decodeNil() {
            value = NSNull()
            return
        }
        if let kept = try? from.decode(Bool.self) {
            value = kept
            return
        }
        if let kept = try? from.decode(Int.self) {
            value = kept
            return
        }
        if let kept = try? from.decode(Double.self) {
            value = kept
            return
        }
        if let kept = try? from.decode(String.self) {
            value = kept
            return
        }
        if let kept = try? from.decode([AnyCodable].self) {
            value = kept.map { $0.value }
            return
        }
        if let kept = try? from.decode([String: AnyCodable].self) {
            if kept.count == 1 {
                if let encoded = kept["$data"]?.value as? String, let data = Data(base64Encoded: encoded) {
                    value = data
                    return
                }
                if let stamp = kept["$date"]?.value as? Double {
                    value = Date(timeIntervalSince1970: stamp)
                    return
                }
            }
            value = kept.mapValues { $0.value }
            return
        }
        throw DecodingError.dataCorruptedError(in: from, debugDescription: "unsupported pref value")
    }
}

extension History {
    // The history file's rows, named for the bundle. History keeps them
    // privately as Visit; the file is what migration reads, so the shape is
    // repeated here rather than reaching into it. Only the address has to be
    // there — a hand-edited file still reads.
    struct Entry: Codable {
        var url: String
        var key: String = ""
        var title: String = ""
        var count: Int = 1
        var last: Date = Date()
    }
}

// The profile in memory, for part B to take in. The staging folder carries
// the same thing as files; this is the shape they agree on.
struct SearchProfileBundle {
    let manifest: SearchProfileManifest
    let profiles: [Profile]
    let spaces: [Space]
    let pinsRaw: Data
    let sessions: [String: Session.Shape]
    let bookmarks: [String: [Bookmark]]
    let histories: [String: [History.Entry]]?
    let prefs: [String: AnyCodable]
    let searchSites: Data
    let hidden: Data
    let shieldPaused: [String]
    let extensionIDs: [String]
}

enum SearchProfileError: Error {
    case packFailed
    case unpackFailed
}

enum SearchProfile {
    // What part B refuses to read: anything written by a newer Search.
    static let format = 1

    // The current profile as a folder of files, for zip() to pack. Best
    // effort throughout: a missing file is a profile that never made one,
    // not a failure.
    nonisolated static func collectCurrentProfile() -> URL {
        let staging = ImportFile.scratchFolder()
        try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        // The profile on screen is the oldest window's space; with no window
        // (a headless export) the last space written down stands in.
        let allSpaces = Spaces.read()
        let currentSpace = Store.settings.string(forKey: "space.current").flatMap(UUID.init) ?? Space.firstID
        let profile = allSpaces.first { $0.id == currentSpace }?.profileID ?? Profile.personalID
        let mine = allSpaces.filter { $0.profileID == profile }

        var counts: [String: Int] = [:]

        // No file while Personal stands alone (see Profiles.write) — still
        // one profile.
        var profileCount = 1
        if copy("profiles.json", to: staging),
           let data = try? Data(contentsOf: staging.appendingPathComponent("profiles.json")),
           let saved = try? JSONDecoder().decode([Profile].self, from: data) {
            profileCount = max(1, saved.count)
        }
        counts["profiles"] = profileCount

        // The whole list: its order spans profiles, so import remaps it.
        _ = copy("spaces.json", to: staging)
        counts["spaces"] = mine.count

        // Each of this profile's spaces keeps its session beside the store's.
        var sessions = 0
        for space in mine {
            let name = space.id == Space.firstID ? "session.json" : "session-\(space.id.uuidString).json"
            if copy(name, to: staging) { sessions += 1 }
        }
        counts["sessions"] = sessions

        // History and bookmarks live per profile (see Profiles.history).
        let historyName = profile == Profile.personalID ? "history.json" : "history-\(profile.uuidString).json"
        let bookmarksName = profile == Profile.personalID ? "bookmarks.json" : "bookmarks-\(profile.uuidString).json"
        counts["history"] = copy(historyName, to: staging) ? 1 : 0
        counts["bookmarks"] = copy(bookmarksName, to: staging) ? 1 : 0

        // Shared by every profile (see Profiles.swift): whole, for import to
        // remap alongside spaces.
        _ = copy("pins.json", to: staging)
        _ = copy("hidden.json", to: staging)
        _ = copy("search-sites.json", to: staging)

        // Extensions live under their store ids; only the ids travel. Paths
        // and versions are this Mac's, and import installs them fresh.
        let ids = extensionIDs()
        if let data = try? JSONEncoder().encode(ids) {
            try? data.write(to: staging.appendingPathComponent("installed.json"), options: .atomic)
        }
        counts["extensions"] = ids.count

        // Settings, cut to what another copy may honour: nothing that signs
        // in, nothing secret, nothing about this run's windows.
        let prefs = collectPrefs(allowlist: allowedPrefs)
        if let data = try? JSONEncoder().encode(prefs) {
            try? data.write(to: staging.appendingPathComponent("prefs.json"), options: .atomic)
        }
        counts["prefs"] = prefs.count

        let manifest = SearchProfileManifest(
            format: format,
            appVersion: (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev",
            scope: "profile",
            exportedAt: Date(),
            counts: counts
        )
        if let data = try? JSONEncoder().encode(manifest) {
            try? data.write(to: staging.appendingPathComponent("manifest.json"), options: .atomic)
        }
        return staging
    }

    // The folder as one file, by the Mac's own archiver — the same tool
    // ImportFile trusts with Safari's exports.
    nonisolated static func zip(staging: URL, to dest: URL) throws {
        try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        task.arguments = ["-c", "-k", "--sequesterRsrc", staging.path, dest.path]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try task.run()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { throw SearchProfileError.packFailed }
    }

    // The reverse, into a scratch folder of its own like ImportFile.unzip;
    // the caller clears it away.
    nonisolated static func unzip(_ url: URL) throws -> URL {
        let folder = ImportFile.scratchFolder()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        task.arguments = ["-x", "-k", url.path, folder.path]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        guard task.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: folder)
            throw SearchProfileError.unpackFailed
        }
        return folder
    }

    // One file's bytes, unchanged: decode nothing, so nothing is lost to a
    // version that writes more than this one knows.
    @discardableResult
    private static func copy(_ name: String, to staging: URL) -> Bool {
        guard let data = try? Data(contentsOf: Store.file(name)) else { return false }
        guard (try? data.write(to: staging.appendingPathComponent(name), options: .atomic)) != nil else { return false }
        return true
    }

    // The store ids of what's installed, whatever else its list carries.
    private static func extensionIDs() -> [String] {
        let list = Store.folder.appendingPathComponent("Extensions", isDirectory: true).appendingPathComponent("installed.json")
        guard let data = try? Data(contentsOf: list),
              let top = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return top.compactMap { $0["id"] as? String }.filter { !$0.isEmpty }.sorted()
    }

    // What another copy may honour: the rows Settings shows, so a setting
    // can't travel that Settings doesn't. Per-site shield pauses ride along —
    // Settings lists no row for them, but they belong to the profile.
    private static var allowedPrefs: Set<String> {
        let indexed = Set(SettingsIndex.items.flatMap { $0.keys })
        guard !indexed.isEmpty else { return curatedPrefs }
        return indexed.union(["shield.paused"])
    }

    // Stand-in when the index isn't there to ask: the keys this migration
    // was scoped to.
    private static let curatedPrefs: Set<String> = [
        "search.engine", "search.custom", "search.keywords", "search.suggest",
        "tabs.newPlace", "tabs.newAfterLast", "tabs.closeGoesBack", "tabs.lazy",
        "tabs.popupWindows", "tabs.sleep", "tabs.sleep.pace", "tabs.close.after",
        "tabs.shortcuts", "tabs.address", "tabs.reading", "tabs.give", "tabs.awakeSites",
        "sidebar", "sidebar.position", "sidebar.icons", "sidebar.hides", "sidebar.roomy", "sidebar.width",
        "layout.cards",
        "shield", "shield.paused",
        "privacy.gpc", "privacy.clickIDs", "privacy.popupSites",
        "commandbar", "newtab.floating",
    ]

    private static func collectPrefs(allowlist: Set<String>) -> [String: AnyCodable] {
        var out: [String: AnyCodable] = [:]
        for key in allowlist.sorted() {
            guard let object = Store.settings.object(forKey: key),
                  let wrapped = AnyCodable(object)
            else { continue }
            out[key] = wrapped
        }
        return out
    }
}
