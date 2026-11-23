import Foundation

// Pinned tabs are the same in every window: pinned, unpinned, moved,
// relettered or renamed in one, so they are in the others. Each window holds
// its own tab for each pin — its own page, wherever you took it — and only
// what makes the pin a pin is shared: its letter, its name, the page it was
// pinned at, its place among the pins.
//
// pins.json holds them, under the key the one row has always had there
// (Session.legacyFirstRow), so an older Search reads them as before. The
// oldest window's session file keeps its pins as it always did, so 1.0.3
// finds them there; the first launch of 1.0.4 takes them from there.

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
    /// The folder among the pinned rows that holds it (see PinFolders.swift),
    /// nil at the top of them. Written only when it is in one, so the file
    /// is unchanged for anyone with no folders.
    var folder: UUID? = nil
    /// The Split View it was pinned in, with the other pins that share it
    /// (see Browser.pin). Written only for those, so the file is
    /// unchanged for anyone who never pins one.
    var pair: UUID? = nil
}

@MainActor
enum Pins {
    /// The pins, in their order.
    private static var list: [PinDef] = []
    private static var loaded = false

    /// The pins changed in one window; the others follow.
    static let changed = Notification.Name("SearchPinsChanged")

    /// Where pins.json kept the pins once shown above every row; read once
    /// and put first, then no more.
    nonisolated static let sharedKey = "shared"

    private static var file: URL { Store.file("pins.json") }

    static func defs() -> [PinDef] {
        load()
        return list
    }

    /// Read once. Before there is a pins.json, the pins are the oldest
    /// window's, from its session file.
    static func load() {
        guard !loaded else { return }
        loaded = true
        if let data = try? Data(contentsOf: file), let saved = decode(data) {
            list = saved
            return
        }
        list = Session.read().tabs.compactMap { entry -> PinDef? in
            guard let letter = entry.pin else { return nil }
            return PinDef(id: entry.pinID ?? UUID(), letter: letter, home: entry.home ?? entry.url,
                          title: entry.title, name: entry.name)
        }
        save()
    }

    /// A window's pins, as they now are: kept, written, and passed to the
    /// other windows when they differ from what was there.
    static func set(_ defs: [PinDef], from browser: Browser) {
        load()
        guard list != defs else { return }
        list = defs
        save()
        NotificationCenter.default.post(name: changed, object: browser)
    }

    /// Pins as another Mac left them (see Sync.swift), and every window
    /// told, as when another window changes them.
    static func adopt(_ defs: [PinDef]) {
        load()
        guard list != defs else { return }
        list = defs
        save()
        NotificationCenter.default.post(name: Pins.changed, object: nil)
    }

    private static func save() {
        let list = list
        Disk.write(file) { encode(list) }
    }

    /// The pins in pins.json: the one row's, after any once shown above
    /// every row, which are its own now.
    nonisolated static func decode(_ data: Data) -> [PinDef]? {
        guard let saved = try? JSONDecoder().decode([String: [PinDef]].self, from: data) else { return nil }
        let own = saved[Session.legacyFirstRow] ?? []
        let shared = (saved[sharedKey] ?? []).filter { pin in !own.contains { $0.id == pin.id } }
        return shared + own
    }

    nonisolated static func encode(_ defs: [PinDef]) -> Data? {
        try? JSONEncoder().encode(defs.isEmpty ? [:] : [Session.legacyFirstRow: defs])
    }
}
