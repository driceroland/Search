import Foundation

// Pinned tabs are the same in every window: pinned, unpinned, moved,
// relettered or renamed in one, so they are in the others. Each window holds
// its own tab for each pin — its own page, wherever you took it — and only
// what makes the pin a pin is shared: its letter, its name, the page it was
// pinned at, its place among the pins. Per space, as the pins always were.
//
// pins.json holds them. The oldest window's session file keeps its pins as
// it always did, so 1.0.3 finds them there; the first launch of 1.0.4 takes
// them from there.
//
// There were once pins every space showed, kept under "shared": the first
// launch without them gives each space its own copy, so none goes missing.
//
// The spaces' folders (see Folders.swift) are kept beside it, in
// folders.json, by space, rather than in pins.json, which every version
// reads whole as lists of pins: a list of something else there would make
// an older version take the file for unreadable and write it again from
// its session, losing them. A pin says which folder it is in under
// "folder", which an older version passes over.

struct PinDef: Codable, Equatable {
    var id: UUID
    var letter: String
    /// The page it was pinned at (see Browser.goHome).
    var home: String
    var title: String
    var name: String?
    /// A row, not a square (see Tab.listed). Nil rather than false, so a
    /// pins file with no rows in it is written as it always was.
    var listed: Bool? = nil
    /// The folder it is in, a row in it (see Folders.swift). Nil for a pin
    /// in none, so it is written as it always was.
    var folder: UUID? = nil
}

@MainActor
enum Pins {
    /// Pins by space, in their order.
    private(set) static var bySpace: [UUID: [PinDef]] = [:]
    /// Each space's folders, in their order (see Folders.swift).
    private static var foldersBy: [UUID: [Folder]] = [:]
    private static var loaded = false

    /// A space's pins changed in one window; the others follow.
    static let changed = Notification.Name("ShyPinsChanged")

    /// Where pins.json kept the pins every space showed.
    nonisolated static let sharedKey = "shared"

    private static var file: URL { Store.file("pins.json") }
    private static var foldersFile: URL { Store.file("folders.json") }

    static func defs(_ space: UUID) -> [PinDef] {
        load()
        return bySpace[space] ?? []
    }

    /// Read once. Before there is a pins.json, the pins are the oldest
    /// window's, from its session files — every space's.
    static func load() {
        guard !loaded else { return }
        loaded = true
        if let data = try? Data(contentsOf: foldersFile) { foldersBy = decodeFolders(data) }
        if let data = try? Data(contentsOf: file), let saved = decode(data) {
            bySpace = saved.bySpace
            // Pins every space showed: each space's own now, ahead of the
            // rest, under the same id so the tab each row has keeps going.
            if !saved.shared.isEmpty {
                for space in Spaces.read() {
                    let own = bySpace[space.id] ?? []
                    bySpace[space.id] = saved.shared + own.filter { pin in !saved.shared.contains { $0.id == pin.id } }
                }
                save()
            }
            return
        }
        for space in Spaces.read() {
            let defs = Session.read(space: space.id).tabs.compactMap { entry -> PinDef? in
                guard let letter = entry.pin else { return nil }
                return PinDef(id: entry.pinID ?? UUID(), letter: letter, home: entry.home ?? entry.url,
                              title: entry.title, name: entry.name)
            }
            if !defs.isEmpty { bySpace[space.id] = defs }
        }
        save()
    }

    /// A window's pins for a space, as they now are: kept, written, and
    /// passed to the other windows when they differ from what was there.
    static func set(_ space: UUID, _ defs: [PinDef], from browser: Browser) {
        load()
        guard (bySpace[space] ?? []) != defs else { return }
        bySpace[space] = defs.isEmpty ? nil : defs
        save()
        NotificationCenter.default.post(name: changed, object: browser, userInfo: ["space": space])
    }

    /// A space's folders, in their order.
    static func folders(_ space: UUID) -> [Folder] {
        load()
        return foldersBy[space] ?? []
    }

    /// A window's folders for a space, as they now are: kept, written, and
    /// passed to the other windows, as the pins are.
    static func setFolders(_ space: UUID, _ folders: [Folder], from browser: Browser) {
        load()
        guard (foldersBy[space] ?? []) != folders else { return }
        foldersBy[space] = folders.isEmpty ? nil : folders
        saveFolders()
        NotificationCenter.default.post(name: changed, object: browser, userInfo: ["space": space])
    }

    /// A space deleted: its pins and folders go with it.
    static func forget(_ space: UUID) {
        if foldersBy.removeValue(forKey: space) != nil { saveFolders() }
        guard bySpace.removeValue(forKey: space) != nil else { return }
        save()
    }

    private static func saveFolders() {
        let all = foldersBy
        Disk.write(foldersFile) { encodeFolders(all) }
    }

    private static func save() {
        let bySpace = bySpace
        Disk.write(file) { encode(bySpace: bySpace) }
    }

    /// folders.json: each space's folders under its id. A space whose list
    /// won't read has none, rather than taking the others with it.
    nonisolated static func decodeFolders(_ data: Data) -> [UUID: [Folder]] {
        guard let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var out: [UUID: [Folder]] = [:]
        for (key, value) in saved {
            guard let space = UUID(uuidString: key),
                  let list = try? JSONSerialization.data(withJSONObject: value),
                  let folders = try? JSONDecoder().decode([Folder].self, from: list), !folders.isEmpty else { continue }
            out[space] = folders
        }
        return out
    }

    nonisolated static func encodeFolders(_ folders: [UUID: [Folder]]) -> Data? {
        var out: [String: [Folder]] = [:]
        for (space, list) in folders where !list.isEmpty { out[space.uuidString] = list }
        return try? JSONEncoder().encode(out)
    }

    nonisolated static func decode(_ data: Data) -> (bySpace: [UUID: [PinDef]], shared: [PinDef])? {
        guard let saved = try? JSONDecoder().decode([String: [PinDef]].self, from: data) else { return nil }
        var bySpace: [UUID: [PinDef]] = [:]
        for (key, defs) in saved {
            if let space = UUID(uuidString: key) { bySpace[space] = defs }
        }
        return (bySpace, saved[sharedKey] ?? [])
    }

    nonisolated static func encode(bySpace: [UUID: [PinDef]]) -> Data? {
        var out: [String: [PinDef]] = [:]
        for (space, defs) in bySpace { out[space.uuidString] = defs }
        return try? JSONEncoder().encode(out)
    }
}
