import Foundation

// The merge behind Sync (see Sync.swift): plain values in, plain values out,
// nothing read or written here, so every rule can be tested on its own.
//
// What is synced is a flat map of items, key → a small JSON text. Each Mac
// keeps, for every item, the value it last agreed on with a stamp (when it
// was set, in seconds) and the device that set it; a deletion is the same
// entry with no value, a tombstone, so "gone" travels as surely as "changed".
//
// A pass on one Mac:
//   1. stamp: the items as this Mac has them now, compared with what it last
//      agreed (its base). What differs is an edit made here since, stamped
//      later than anything it has seen (so a Mac whose clock runs behind
//      still wins over a value it already saw); what it agreed on and no
//      longer has is a tombstone. A first pass (no base: joining) stamps 0,
//      so what is already in the folder wins where both have the same item
//      and nothing here is lost where only this Mac has it.
//   2. merge: this map and every other Mac's file, item by item, the latest
//      stamp winning, then the device id, then a tombstone, then the larger
//      text — the same answer on every Mac whatever order it reads them in.
//   3. what changed is applied here, and the merged map is the new base and
//      this Mac's own file.
//
// Items this build can't read (a newer Search's, a damaged one) are carried
// along untouched and never turned into tombstones.

struct SyncEntry: Codable, Equatable {
    /// The item's JSON; nil for one deleted.
    var v: String?
    /// When it was set, seconds since 1970 — or later, see `SyncMerge.stamp`.
    var t: Double
    /// The device that set it.
    var d: String
}

/// One Mac's file in one scope's folder: only that Mac writes it.
struct SyncFile: Codable, Equatable {
    var format: Int
    var device: String
    /// The Mac's name, for Settings to say who was last seen.
    var name: String?
    /// "app", or "profile-<id>": a file in the wrong folder is not read.
    var scope: String
    var written: Double
    var items: [String: SyncEntry]
}

enum SyncMerge {
    /// The file format. A file of another is passed over, not misread.
    static let format = 1
    /// How long a deletion is remembered: a Mac away longer than this may
    /// bring back what was deleted meanwhile, and nothing worse.
    static let tombstoneLife: Double = 365 * 24 * 60 * 60

    /// Whether `a` beats `b` for the same item. Total and the same on every
    /// Mac: two Macs that read the same files agree.
    static func wins(_ a: SyncEntry, over b: SyncEntry) -> Bool {
        if a.t != b.t { return a.t > b.t }
        if a.d != b.d { return a.d > b.d }
        switch (a.v, b.v) {
        case (nil, nil): return false
        case (nil, _): return true
        case (_, nil): return false
        case let (x?, y?): return x > y
        }
    }

    /// Every map's items, the winner of each.
    static func merge(_ maps: [[String: SyncEntry]]) -> [String: SyncEntry] {
        var out: [String: SyncEntry] = [:]
        for map in maps {
            for (key, entry) in map {
                if let held = out[key], !wins(entry, over: held) { continue }
                out[key] = entry
            }
        }
        return out
    }

    /// The items as this Mac has them now (`current`), written over what it
    /// last agreed (`base`). `understood` says which of base's items this
    /// build can read: only those can be found missing and deleted.
    /// `joining`: this Mac's first pass with a folder other Macs already
    /// use — its items are stamped 0, so theirs win where both have one.
    static func stamp(current: [String: String], base: [String: SyncEntry], device: String, now: Double,
                      joining: Bool = false,
                      understood: (String, String) -> Bool = { _, _ in true }) -> [String: SyncEntry] {
        // Later than anything seen, whatever this Mac's clock says.
        let clock = joining ? 0 : max(now, (base.values.map(\.t).max() ?? 0) + 0.001)
        var out = base
        for (key, value) in current where base[key]?.v != value {
            out[key] = SyncEntry(v: value, t: clock, d: device)
        }
        // A whole kind gone at once — every bookmark, every pin — is a file
        // that didn't read or a browser reset, far likelier than a choice:
        // those are not deleted everywhere, they come back from the folder.
        var lost = Set(wholeKinds.filter { kind in
            !current.keys.contains { $0.hasPrefix(kind) }
                && base.filter { $0.key.hasPrefix(kind) && $0.value.v != nil }.count >= wholeKindFloor
        })
        for (kind, with) in lostWith where lost.contains(with) { lost.insert(kind) }
        for (key, entry) in base {
            guard let value = entry.v, current[key] == nil, understood(key, value),
                  !lost.contains(where: { key.hasPrefix($0) }) else { continue }
            out[key] = SyncEntry(v: nil, t: clock, d: device)
        }
        return out
    }

    /// One pass, as every Mac runs it: this Mac's items stamped over its
    /// base (nil before its first pass), merged with the other Macs' maps,
    /// old deletions forgotten. What comes back is the new base, this Mac's
    /// file, and — its live items — what this Mac should now have.
    static func pass(current: [String: String], base: [String: SyncEntry]?, theirs: [[String: SyncEntry]],
                     device: String, now: Double,
                     understood: (String, String) -> Bool = { _, _ in true }) -> [String: SyncEntry] {
        let mine = stamp(current: current, base: base ?? [:], device: device, now: now,
                         joining: base == nil && !theirs.isEmpty, understood: understood)
        return prune(merge([mine] + theirs), now: now)
    }

    /// The kinds of item whose vanishing all at once is not taken as their
    /// deletion (see `stamp`), and how many there must have been.
    static let wholeKinds = ["bm:", "kids:", "pin:", "order:pins:", "title:pin:", "space:", "pinfolder:"]
    static let wholeKindFloor = 5
    /// Kinds that go with another: when every pin vanishes at once, which
    /// folder each was in is not deleted either, nor the folders' order
    /// with the folders.
    static let lostWith = ["infolder:": "pin:", "pinfolders:": "pinfolder:"]

    /// The items that are there, without the tombstones.
    static func live(_ map: [String: SyncEntry]) -> [String: String] {
        map.compactMapValues(\.v)
    }

    /// Deletions older than `tombstoneLife` forgotten.
    static func prune(_ map: [String: SyncEntry], now: Double) -> [String: SyncEntry] {
        map.filter { $0.value.v != nil || $0.value.t >= now - tombstoneLife }
    }

    /// Another Mac's file, if it is one this build can read for this scope:
    /// damaged, foreign, other-format and wrong-folder files are nil, and an
    /// entry with a stamp that is not a number is left out.
    static func decode(_ data: Data, scope: String) -> SyncFile? {
        guard var file = try? JSONDecoder().decode(SyncFile.self, from: data),
              file.format == format, file.scope == scope, !file.device.isEmpty
        else { return nil }
        file.items = file.items.filter { $0.value.t.isFinite && $0.value.t >= 0 && !$0.value.d.isEmpty }
        return file
    }

    static func encode(_ file: SyncFile) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(file)
    }

    /// A value as an item's text: sorted keys, so the same value is always
    /// the same text and "changed" means changed.
    static func text<T: Encodable>(_ value: T) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) }
    }

    static func value<T: Decodable>(_ type: T.Type, _ text: String) -> T? {
        try? JSONDecoder().decode(type, from: Data(text.utf8))
    }

    /// A list's order applied to the ids that are there: the order's first,
    /// as it has them, then the rest in `fallback`'s order, then any left by
    /// id — so an item added on one Mac while another reordered is kept, at
    /// the end, and every Mac ends with the same list.
    static func ordered(_ ids: Set<String>, order: [String], fallback: [String] = []) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for id in order + fallback where ids.contains(id) && !seen.contains(id) {
            out.append(id)
            seen.insert(id)
        }
        return out + ids.subtracting(seen).sorted()
    }
}

// MARK: - what each kind of thing is, as items

/// The parts of a space that sync: what it is called and looks like, and
/// whether it has sign-ins of its own. Never its cookies, sign-ins, tabs
/// or downloads folder.
struct SyncedSpace: Codable, Equatable {
    var name: String
    var colour: Int
    var icon: String?
    var sharesSignIns: Bool?
}

/// The parts of a pin that sync. Its title is the page's, which changes as
/// you browse; it goes once, beside it, for a Mac that makes the pin anew.
struct SyncedPin: Codable, Equatable {
    var letter: String
    var home: String
    var name: String?
    var listed: Bool?
}

/// A folder among a space's pinned rows (PinFolders.swift): what it is
/// and where, never how this Mac shows it. Whether it is folded stays on
/// each Mac, and a live folder's posts are fetched by each Mac itself.
struct SyncedPinFolder: Codable, Equatable {
    var name: String
    var parent: UUID?
    var feed: URL?
}

/// A bookmark or a folder (no url), without its place: the folder that
/// holds it lists it.
struct SyncedBookmark: Codable, Equatable {
    var title: String
    var url: String?
}

enum SyncItems {
    // MARK: spaces

    static let spacesOrder = "order:spaces"

    static func spaceKey(_ id: UUID) -> String { "space:" + id.uuidString }

    /// A space's gradient, an item of its own beside the space's: a Search
    /// from before gradients doesn't read it, so it carries it along as it
    /// is and never writes the space back without it (see SyncMerge.stamp).
    /// Only a space with a gradient has one.
    static func gradientKey(_ id: UUID) -> String { "gradient:" + id.uuidString }

    /// How strongly a space's colour or gradient washes the chrome, an item
    /// of its own in the same way: a Search from before strengths carries
    /// it along untouched. Only a space that isn't Subtle has one.
    static func strengthKey(_ id: UUID) -> String { "strength:" + id.uuidString }

    /// One profile's spaces, as items. Whether a space has sign-ins of its
    /// own is what was agreed when it was first synced (`base`), never
    /// changed after: a store can't change under a space's open tabs.
    static func spaces(_ list: [Space], base: [String: String] = [:]) -> [String: String] {
        var out: [String: String] = [:]
        for space in list {
            let agreed = base[spaceKey(space.id)].flatMap { SyncMerge.value(SyncedSpace.self, $0) }
            let synced = SyncedSpace(name: space.name, colour: space.colour, icon: space.icon,
                                     sharesSignIns: agreed.map(\.sharesSignIns) ?? space.sharesSignIns)
            out[spaceKey(space.id)] = SyncMerge.text(synced)
            if let gradient = space.gradient, gradient.usable { out[gradientKey(space.id)] = SyncMerge.text(gradient) }
            if let strength = space.strength, strength != .subtle { out[strengthKey(space.id)] = SyncMerge.text(strength) }
        }
        if !list.isEmpty { out[spacesOrder] = SyncMerge.text(list.map(\.id.uuidString)) }
        return out
    }

    /// The spaces the merged items say there are: names, colours and icons
    /// as merged, in the merged order; what is only this Mac's — the
    /// downloads folder — kept; whether one has its own sign-ins is never
    /// changed once it is made. `home` is never taken away.
    static func applySpaces(_ live: [String: String], to local: [Space], profile: UUID, home: UUID) -> [Space] {
        var found: [String: SyncedSpace] = [:]
        for (key, text) in live where key.hasPrefix("space:") {
            guard UUID(uuidString: String(key.dropFirst(6))) != nil, let space = SyncMerge.value(SyncedSpace.self, text) else { continue }
            found[String(key.dropFirst(6))] = space
        }
        var ids = Set(found.keys)
        // A space this Mac has that the items don't read (never: the stamp
        // put each in) stays; the home always does.
        for space in local where space.id == home || live[spaceKey(space.id)].map({ SyncMerge.value(SyncedSpace.self, $0) == nil }) == true {
            ids.insert(space.id.uuidString)
        }
        let order = live[spacesOrder].flatMap { SyncMerge.value([String].self, $0) } ?? []
        let ordered = SyncMerge.ordered(ids, order: order, fallback: local.map(\.id.uuidString))
        return ordered.compactMap { text -> Space? in
            guard let id = UUID(uuidString: text) else { return nil }
            var space = local.first { $0.id == id }
                ?? Space(id: id, name: "", colour: 0, profile: profile == Profile.personalID ? nil : profile)
            if let synced = found[text] {
                space.name = synced.name
                space.colour = synced.colour
                space.icon = synced.icon
                if !local.contains(where: { $0.id == id }) { space.sharesSignIns = synced.sharesSignIns }
                space.gradient = live[gradientKey(id)].flatMap { SyncMerge.value(SpaceGradient.self, $0) }.flatMap { $0.usable ? $0 : nil }
                space.strength = live[strengthKey(id)].flatMap(SyncItems.strength).flatMap { $0 == .subtle ? nil : $0 }
            }
            if space.name.isEmpty { space.name = "Space" }
            return space
        }
    }

    /// A strength item's text as one this build knows; nil for one it
    /// doesn't (a newer Search's), which it then carries along untouched.
    static func strength(_ text: String) -> SpaceStrength? {
        SyncMerge.value(String.self, text).flatMap(SpaceStrength.init(rawValue:))
    }

    // MARK: pins

    static let sharedSpace = "shared"

    static func pinKey(_ space: String, _ id: UUID) -> String { "pin:\(space):\(id.uuidString)" }
    static func pinOrder(_ space: String) -> String { "order:pins:\(space)" }
    static func pinTitle(_ id: UUID) -> String { "title:pin:\(id.uuidString)" }

    /// Which folder among the pinned rows a pin is in: an item of its own
    /// beside the pin's, as a space's gradient is, and only for a pin in
    /// one. A Search from before (1.0.16) doesn't read it, so it carries it
    /// along untouched and never deletes it; and its pin items, which have
    /// no folder in them, never take a pin out of its folder. Taken out of
    /// its folder, the pin's item is deleted.
    static func inFolderKey(_ pin: UUID) -> String { "infolder:" + pin.uuidString }

    /// A profile's pins as items: each space's own, and the ones every space
    /// shows. A pin's title is the one already agreed, if there is one.
    static func pins(bySpace: [UUID: [PinDef]], shared: [PinDef], base: [String: String]) -> [String: String] {
        var out: [String: String] = [:]
        func add(_ defs: [PinDef], _ space: String, folders: Bool) {
            for def in defs {
                out[pinKey(space, def.id)] = SyncMerge.text(SyncedPin(letter: def.letter, home: def.home, name: def.name, listed: def.listed))
                out[pinTitle(def.id)] = base[pinTitle(def.id)] ?? SyncMerge.text(def.title)
                if folders, let folder = def.folder { out[inFolderKey(def.id)] = SyncMerge.text(folder.uuidString) }
            }
            if !defs.isEmpty { out[pinOrder(space)] = SyncMerge.text(defs.map(\.id.uuidString)) }
        }
        for (space, defs) in bySpace { add(defs, space.uuidString, folders: true) }
        // A pin every space shows is in no folder.
        add(shared, sharedSpace, folders: false)
        return out
    }

    /// The folder the items say a pin is in. This Mac's own pins are in the
    /// items it merged, so no item is a pin taken out of its folder, here
    /// or on another Mac. One this build can't read (a newer Search's)
    /// leaves the pin where it was here.
    static func folder(of id: UUID, _ live: [String: String], local: PinDef?) -> UUID? {
        guard let text = live[inFolderKey(id)] else { return nil }
        guard let folder = SyncMerge.value(String.self, text).flatMap(UUID.init(uuidString:)) else { return local?.folder }
        return folder
    }

    /// The pins the merged items say each of `spaces` has, and the shared
    /// ones. A pin in both the shared list and a space's (shared on one Mac
    /// while edited on another) is shared. Titles: the one agreed, else the
    /// one this Mac had, else the page's address.
    static func applyPins(_ live: [String: String], spaces: [UUID], local: [UUID: [PinDef]], localShared: [PinDef])
        -> (bySpace: [UUID: [PinDef]], shared: [PinDef]) {
        let known = (Array(local.values).flatMap { $0 } + localShared)
        func defs(_ space: String, fallback: [PinDef]) -> [PinDef] {
            let prefix = "pin:\(space):"
            var found: [String: SyncedPin] = [:]
            for (key, text) in live where key.hasPrefix(prefix) {
                let id = String(key.dropFirst(prefix.count))
                guard UUID(uuidString: id) != nil, let pin = SyncMerge.value(SyncedPin.self, text) else { continue }
                found[id] = pin
            }
            let order = live[pinOrder(space)].flatMap { SyncMerge.value([String].self, $0) } ?? []
            return SyncMerge.ordered(Set(found.keys), order: order, fallback: fallback.map(\.id.uuidString)).compactMap { text in
                guard let id = UUID(uuidString: text), let pin = found[text] else { return nil }
                let title = live[pinTitle(id)].flatMap { SyncMerge.value(String.self, $0) }
                    ?? known.first { $0.id == id }?.title ?? pin.home
                var def = PinDef(id: id, letter: pin.letter, home: pin.home, title: title, name: pin.name, listed: pin.listed)
                if space != sharedSpace { def.folder = folder(of: id, live, local: known.first { $0.id == id }) }
                // Its title the pin's own here, it stays so (see PinDef.titled).
                def.titled = known.first { $0.id == id }?.titled
                return def
            }
        }
        let shared = defs(sharedSpace, fallback: localShared)
        let sharedIDs = Set(shared.map(\.id))
        var bySpace: [UUID: [PinDef]] = [:]
        for space in spaces {
            let own = defs(space.uuidString, fallback: local[space] ?? []).filter { !sharedIDs.contains($0.id) }
            if !own.isEmpty { bySpace[space] = own }
        }
        return (bySpace, shared)
    }

    // MARK: pin folders

    /// A space's pin folder, and the folders' order in that space. New
    /// kinds, so a Search from before them (1.0.16) carries them along
    /// untouched and never deletes them (see `understood`).
    static func pinFolderKey(_ space: UUID, _ id: UUID) -> String { "pinfolder:\(space.uuidString):\(id.uuidString)" }
    static func pinFoldersOrder(_ space: UUID) -> String { "pinfolders:" + space.uuidString }

    /// Each space's pin folders as items, whether or not this Mac draws
    /// them: with Folders in pinned rows off they wait for the switch.
    static func pinFolders(_ bySpace: [UUID: [PinFolder]]) -> [String: String] {
        var out: [String: String] = [:]
        for (space, folders) in bySpace where !folders.isEmpty {
            for folder in folders {
                out[pinFolderKey(space, folder.id)] = SyncMerge.text(SyncedPinFolder(name: folder.name, parent: folder.parent, feed: folder.feed))
            }
            out[pinFoldersOrder(space)] = SyncMerge.text(folders.map(\.id.uuidString))
        }
        return out
    }

    /// A space's pin folders as the merged items say, in the merged order:
    /// each folded or open as it is on this Mac, and a live folder's posts
    /// kept while its feed is the same. A folder deleted elsewhere goes;
    /// what it held is then at the top of the rows until its own items say
    /// where it went.
    static func applyPinFolders(_ live: [String: String], space: UUID, local: [PinFolder]) -> [PinFolder] {
        let prefix = "pinfolder:\(space.uuidString):"
        var found: [String: SyncedPinFolder] = [:]
        for (key, text) in live where key.hasPrefix(prefix) {
            let id = String(key.dropFirst(prefix.count))
            guard UUID(uuidString: id) != nil, let folder = SyncMerge.value(SyncedPinFolder.self, text) else { continue }
            found[id] = folder
        }
        let order = live[pinFoldersOrder(space)].flatMap { SyncMerge.value([String].self, $0) } ?? []
        return SyncMerge.ordered(Set(found.keys), order: order, fallback: local.map(\.id.uuidString)).compactMap { text in
            guard let id = UUID(uuidString: text), let synced = found[text] else { return nil }
            let mine = local.first { $0.id == id }
            var folder = PinFolder(id: id, name: synced.name, parent: synced.parent, collapsed: mine?.collapsed ?? false, feed: synced.feed)
            folder.items = synced.feed != nil && mine?.feed == synced.feed ? mine?.items : nil
            return folder
        }
    }

    // MARK: bookmarks

    static let rootFolder = "root"

    static func bookmarkKey(_ id: UUID) -> String { "bm:" + id.uuidString }
    static func childrenKey(_ folder: String) -> String { "kids:" + folder }

    /// A bookmarks tree as items: each bookmark and folder, and each
    /// folder's list of what it holds, the top level under "root".
    static func bookmarks(_ roots: [Bookmark]) -> [String: String] {
        var out: [String: String] = [:]
        func walk(_ nodes: [Bookmark], in folder: String) {
            if !nodes.isEmpty { out[childrenKey(folder)] = SyncMerge.text(nodes.map(\.id.uuidString)) }
            for node in nodes {
                out[bookmarkKey(node.id)] = SyncMerge.text(SyncedBookmark(title: node.title, url: node.url))
                if node.isFolder { walk(node.children ?? [], in: node.id.uuidString) }
            }
        }
        walk(roots, in: rootFolder)
        return out
    }

    /// The tree the merged items say there is. A bookmark no folder lists
    /// any more — its folder deleted on one Mac while it was added there on
    /// another, or two folders moved into each other — goes at the end of
    /// the top level rather than being lost.
    static func applyBookmarks(_ live: [String: String]) -> [Bookmark] {
        var nodes: [String: SyncedBookmark] = [:]
        for (key, text) in live where key.hasPrefix("bm:") {
            let id = String(key.dropFirst(3))
            guard UUID(uuidString: id) != nil, let node = SyncMerge.value(SyncedBookmark.self, text) else { continue }
            nodes[id] = node
        }
        func kids(_ folder: String) -> [String] {
            live[childrenKey(folder)].flatMap { SyncMerge.value([String].self, $0) } ?? []
        }
        var placed = Set<String>()
        func build(_ folder: String) -> [Bookmark] {
            kids(folder).compactMap { id -> Bookmark? in
                guard let node = nodes[id], !placed.contains(id), let uuid = UUID(uuidString: id) else { return nil }
                placed.insert(id)
                let children = node.url == nil ? build(id) : nil
                return Bookmark(id: uuid, title: node.title, url: node.url, children: children)
            }
        }
        var roots = build(rootFolder)
        // What no folder reached: each, with what it holds, at the end.
        for id in nodes.keys.sorted() where !placed.contains(id) {
            guard let node = nodes[id], let uuid = UUID(uuidString: id) else { continue }
            placed.insert(id)
            roots.append(Bookmark(id: uuid, title: node.title, url: node.url, children: node.url == nil ? build(id) : nil))
        }
        return roots
    }

    /// Whether this build can read an item: only those can be found missing
    /// here and so deleted everywhere.
    static func understood(_ key: String, _ text: String) -> Bool {
        if key.hasPrefix("space:") { return SyncMerge.value(SyncedSpace.self, text) != nil }
        if key.hasPrefix("gradient:") { return SyncMerge.value(SpaceGradient.self, text)?.usable == true }
        if key.hasPrefix("strength:") { return strength(text) != nil }
        if key.hasPrefix("pin:") { return SyncMerge.value(SyncedPin.self, text) != nil }
        if key.hasPrefix("bm:") { return SyncMerge.value(SyncedBookmark.self, text) != nil }
        if key.hasPrefix("order:") || key.hasPrefix("kids:") { return SyncMerge.value([String].self, text) != nil }
        if key.hasPrefix("title:pin:") { return SyncMerge.value(String.self, text) != nil }
        if key.hasPrefix("pinfolder:") { return SyncMerge.value(SyncedPinFolder.self, text) != nil }
        if key.hasPrefix("pinfolders:") { return SyncMerge.value([String].self, text) != nil }
        if key.hasPrefix("infolder:") {
            return SyncMerge.value(String.self, text).flatMap(UUID.init(uuidString:)) != nil
        }
        if key.hasPrefix("set:") { return SyncSettings.known.contains(String(key.dropFirst(4))) }
        return false
    }
}
