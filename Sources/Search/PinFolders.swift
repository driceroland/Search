import Foundation

// Folders among the pinned rows, as in Arc's pinned list: a folder holds
// pinned rows and other folders, folds and opens, and is the space's own.
// Only rows go in one (a square never does, nor a pin every space shows),
// and only while Settings › Spaces & Pins › Pinned rows and Folders in pinned rows are both on
// are they drawn; turned off, the rows come back flat, and their folders
// wait for the switch, as tab groups do.
//
// Which folder a pin is in is the pin's own (PinDef.folder, in pins.json);
// the folders themselves, their names, which one holds which and whether
// they are folded, are kept in pin-folders.json, by space. pins.json stays
// what an older version can read: one that rewrites it drops the folder of
// each pin and keeps the pins.
//
// Inside a folder, or at the top of the rows, the folders come first, in
// their order, then the pins, in theirs.
//
// A live folder (LiveFolders.swift) is one filled from a web feed rather
// than by hand: it holds the feed's latest posts, never a pin or a folder.

struct PinFolder: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    /// The folder that holds this one; nil at the top of the rows.
    var parent: UUID? = nil
    var collapsed: Bool = false
    /// A live folder's feed. Left out of the file for any other folder; a
    /// version that doesn't know it reads a live folder as an empty one.
    var feed: URL? = nil
    /// A live folder's posts as last fetched, kept so a launch without the
    /// network still has them.
    var items: [FeedItem]? = nil

    var isLive: Bool { feed != nil }
}

/// One post of a live folder's feed: opened as a bookmark is, never a pin.
struct FeedItem: Codable, Equatable, Identifiable {
    var id: UUID
    var title: String
    var link: URL
}

extension PinFolder {
    private enum Keys: String, CodingKey { case id, name, parent, collapsed, feed, items }

    /// Leniently, as TabGroup: a folder saved without its folded state is
    /// an open one, and a parent that doesn't read is the top.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        parent = try? c.decodeIfPresent(UUID.self, forKey: .parent)
        collapsed = (try? c.decodeIfPresent(Bool.self, forKey: .collapsed)) ?? false
        feed = try? c.decodeIfPresent(URL.self, forKey: .feed)
        items = feed == nil ? nil : (try? c.decodeIfPresent([FeedItem].self, forKey: .items)) ?? nil
    }
}

/// The shape of the folders, worked out: what is drawn, what may go where.
/// Pure, so the tests can hold it.
enum PinTree {
    /// A folder, in a folder, in a folder: no deeper. Arc lets them go on;
    /// a column 260 points wide does not have the room.
    static let maxDepth = 3

    /// One line of the pinned rows: a folder's heading or a pin, with how
    /// far in it is set (0 at the top).
    enum Line: Equatable {
        case folder(PinFolder, depth: Int)
        case pin(UUID, depth: Int)
        /// A live folder's post.
        case item(FeedItem, folder: UUID, depth: Int)
    }

    /// The folders as they can be trusted: a parent that is gone, or a
    /// folder that would hold itself, puts the folder at the top; one deeper
    /// than maxDepth goes into the deepest folder above it that may hold it.
    static func sanitized(_ folders: [PinFolder]) -> [PinFolder] {
        var out = folders
        var seen = Set<UUID>()
        out = out.filter { seen.insert($0.id).inserted }
        let ids = Set(out.map(\.id))
        let live = Set(out.filter(\.isLive).map(\.id))
        for index in out.indices {
            if let parent = out[index].parent, !ids.contains(parent) || parent == out[index].id || live.contains(parent) {
                out[index].parent = nil
            }
        }
        // Cycles: walk up from each; a folder met twice is cut loose there.
        for index in out.indices {
            var visited: Set<UUID> = [out[index].id]
            var current = out[index].parent
            while let id = current, let at = out.firstIndex(where: { $0.id == id }) {
                guard visited.insert(id).inserted else { out[index].parent = nil; break }
                current = out[at].parent
            }
        }
        // Too deep: up to the ancestor at maxDepth - 1.
        for index in out.indices {
            var chain = ancestors(of: out[index].id, in: out)
            while chain.count >= maxDepth {
                chain.removeFirst()
                out[index].parent = chain.first
            }
        }
        return out
    }

    /// The folders above one, nearest first.
    static func ancestors(of id: UUID, in folders: [PinFolder]) -> [UUID] {
        var chain: [UUID] = []
        var current = folders.first { $0.id == id }?.parent
        while let parent = current, !chain.contains(parent), let found = folders.first(where: { $0.id == parent }) {
            chain.append(parent)
            current = found.parent
        }
        return chain
    }

    /// 1 for a folder at the top, 2 for one inside it, and so on.
    static func depth(of id: UUID, in folders: [PinFolder]) -> Int {
        ancestors(of: id, in: folders).count + 1
    }

    /// How many levels a folder and what it holds take: 1 for one holding
    /// no folder.
    static func height(of id: UUID, in folders: [PinFolder]) -> Int {
        var best = 1
        var stack: [(UUID, Int)] = [(id, 1)]
        var seen = Set<UUID>()
        while let (current, level) = stack.popLast() {
            guard seen.insert(current).inserted else { continue }
            best = max(best, level)
            for child in folders where child.parent == current { stack.append((child.id, level + 1)) }
        }
        return best
    }

    /// Whether a folder may go into another (nil: the top), staying within
    /// maxDepth and never inside itself.
    static func canMove(_ id: UUID, into parent: UUID?, in folders: [PinFolder]) -> Bool {
        guard let parent else { return true }
        if isLive(parent, in: folders) { return false }
        if parent == id || ancestors(of: parent, in: folders).contains(id) { return false }
        return depth(of: parent, in: folders) + height(of: id, in: folders) <= maxDepth
    }

    /// Whether a new folder may be made inside `parent`.
    static func canMake(in parent: UUID?, in folders: [PinFolder]) -> Bool {
        guard let parent else { return true }
        return folders.contains { $0.id == parent } && !isLive(parent, in: folders)
            && depth(of: parent, in: folders) < maxDepth
    }

    /// Whether a folder is a live one: no pin and no folder goes in it.
    static func isLive(_ id: UUID?, in folders: [PinFolder]) -> Bool {
        guard let id else { return false }
        return folders.contains { $0.id == id && $0.isLive }
    }

    /// A folder taken away: what it held, folders and pins, goes up into
    /// the folder that held it.
    static func removing(_ id: UUID, folders: [PinFolder], pins: [PinDef]) -> (folders: [PinFolder], pins: [PinDef]) {
        guard let gone = folders.first(where: { $0.id == id }) else { return (folders, pins) }
        let kept = folders.filter { $0.id != id }.map { folder -> PinFolder in
            var folder = folder
            if folder.parent == id { folder.parent = gone.parent }
            return folder
        }
        let moved = pins.map { pin -> PinDef in
            var pin = pin
            if pin.folder == id { pin.folder = gone.parent }
            return pin
        }
        return (kept, moved)
    }

    /// The pinned rows as drawn: from the top, each level's folders, each
    /// followed by what it holds unless it is folded, then that level's
    /// pins. A pin whose folder is gone is at the top. `pins` are the rows
    /// only, in their order; `showing`, a pin drawn even inside a folded
    /// folder, as Arc keeps the page you are on in sight.
    static func lines(pins: [(id: UUID, folder: UUID?)], folders: [PinFolder], showing: UUID? = nil) -> [Line] {
        let folders = sanitized(folders)
        // A pin can't be in a live folder: one that says it is, is at the top.
        let ids = Set(folders.filter { !$0.isLive }.map(\.id))
        let home = { (folder: UUID?) -> UUID? in folder.flatMap { ids.contains($0) ? $0 : nil } }
        var out: [Line] = []
        func walk(_ parent: UUID?, depth: Int, folded: Bool) {
            for folder in folders where folder.parent == parent {
                if !folded { out.append(.folder(folder, depth: depth)) }
                if folder.isLive {
                    if !folded && !folder.collapsed {
                        for item in folder.items ?? [] { out.append(.item(item, folder: folder.id, depth: depth + 1)) }
                    }
                    continue
                }
                walk(folder.id, depth: depth + 1, folded: folded || folder.collapsed)
            }
            for pin in pins where home(pin.folder) == parent && (!folded || pin.id == showing) {
                out.append(.pin(pin.id, depth: depth))
            }
        }
        walk(nil, depth: 0, folded: false)
        return out
    }

    /// The pins in the order the lines draw them, for a row whose order on
    /// disk should match what is seen.
    static func ordered(_ pins: [PinDef], folders: [PinFolder]) -> [PinDef] {
        let byID = Dictionary(pins.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return orderedIDs(pins.map { ($0.id, $0.folder) }, folders: folders).compactMap { byID[$0] }
    }

    /// The same, by id: every pin, each once, folded folders opened.
    static func orderedIDs(_ pins: [(id: UUID, folder: UUID?)], folders: [PinFolder]) -> [UUID] {
        let open = folders.map { folder -> PinFolder in
            var folder = folder
            folder.collapsed = false
            return folder
        }
        return lines(pins: pins, folders: open).compactMap { line in
            if case .pin(let id, _) = line { return id }
            return nil
        }
    }

    // MARK: - a pin let go among the rows

    /// Where a pinned row carried among the folders goes: into `folder`
    /// (nil: the top), beside `anchor` — before it, or after it — or, with
    /// no anchor, at the end of that folder's pins.
    struct Place: Equatable {
        var folder: UUID?
        var anchor: UUID? = nil
        var after = false
    }

    /// The place for a pin let go at `y`, given each line drawn and where
    /// (in the same space), and the folder each pin is in. Over a folder's
    /// heading: into it. Over another pin: beside it, in its folder, before
    /// it in its upper half, after it in its lower. Over the pin carried, a
    /// live folder or one of its posts, or between lines: nil, nothing moves. Above every line: first at the
    /// top; below them all: last at the top.
    static func place(y: CGFloat, lines: [(line: Line, frame: CGRect)], folders pinFolder: [UUID: UUID?],
                      carrying: UUID) -> Place? {
        guard let first = lines.first, let last = lines.last else { return nil }
        if y < first.frame.minY {
            let top = lines.first { if case .pin(let id, 0) = $0.line { return id != carrying }; return false }
            if case .pin(let id, _)? = top?.line { return Place(folder: nil, anchor: id) }
            return Place(folder: nil)
        }
        if y > last.frame.maxY { return Place(folder: nil) }
        guard let hit = lines.first(where: { y >= $0.frame.minY && y <= $0.frame.maxY }) else { return nil }
        switch hit.line {
        case .folder(let folder, _):
            return folder.isLive ? nil : Place(folder: folder.id)
        case .pin(let id, _):
            guard id != carrying else { return nil }
            return Place(folder: pinFolder[id] ?? nil, anchor: id, after: y > hit.frame.midY)
        case .item:
            return nil
        }
    }

    // MARK: - a folder let go among the rows

    /// Where a folder carried by its heading goes: into `parent` (nil: the
    /// top), before the folder `before` there, or with none after that
    /// level's other folders (a level's folders come before its pins).
    struct FolderPlace: Equatable {
        var parent: UUID?
        var before: UUID? = nil
    }

    /// The place for the folder `carrying` let go at `y`, as `place` works
    /// one out for a pin. Over another folder's heading: before it in the
    /// heading's upper third, into it below (a live folder: before it
    /// only). Over a pin: in that pin's folder, after its folders. Above
    /// every line: first at the top; below them all: last at the top. Over
    /// itself, anything inside it, between lines, or where it would go too
    /// deep (canMove): nil, nothing moves. The carried heading's own line
    /// is left out: it goes along under the hand, over the lines it passes.
    static func folderPlace(y: CGFloat, lines: [(line: Line, frame: CGRect)], folders: [PinFolder],
                            pinFolder: [UUID: UUID?], carrying: UUID) -> FolderPlace? {
        let folders = sanitized(folders)
        let lines = lines.filter { if case .folder(let folder, _) = $0.line { return folder.id != carrying }; return true }
        guard folders.contains(where: { $0.id == carrying }), let first = lines.first, let last = lines.last else { return nil }
        func inside(_ id: UUID?) -> Bool {
            guard let id else { return false }
            return id == carrying || ancestors(of: id, in: folders).contains(carrying)
        }
        func fits(_ place: FolderPlace) -> FolderPlace? {
            canMove(carrying, into: place.parent, in: folders) ? place : nil
        }
        if y < first.frame.minY {
            return fits(FolderPlace(parent: nil, before: folders.first { $0.parent == nil && $0.id != carrying }?.id))
        }
        if y > last.frame.maxY { return fits(FolderPlace(parent: nil)) }
        guard let hit = lines.first(where: { y >= $0.frame.minY && y <= $0.frame.maxY }) else { return nil }
        switch hit.line {
        case .folder(let folder, _):
            guard !inside(folder.id) else { return nil }
            if folder.isLive || y < hit.frame.minY + hit.frame.height / 3 {
                return fits(FolderPlace(parent: folder.parent, before: folder.id))
            }
            return fits(FolderPlace(parent: folder.id))
        case .pin(let id, _):
            let parent = pinFolder[id] ?? nil
            guard !inside(parent) else { return nil }
            return fits(FolderPlace(parent: parent))
        case .item:
            return nil
        }
    }

    /// The folders with `id` moved to `place`: its parent changed, and put
    /// before `place.before` or after the other folders of that level.
    static func moving(_ id: UUID, to place: FolderPlace, in folders: [PinFolder]) -> [PinFolder] {
        var folders = folders
        guard let index = folders.firstIndex(where: { $0.id == id }), place.before != id else { return folders }
        var folder = folders.remove(at: index)
        folder.parent = place.parent
        if let before = place.before, let at = folders.firstIndex(where: { $0.id == before }) {
            folders.insert(folder, at: at)
        } else {
            let at = folders.lastIndex { $0.parent == place.parent }.map { $0 + 1 } ?? folders.count
            folders.insert(folder, at: at)
        }
        return folders
    }

    /// The folders less any not in `keeping` that hold no pin, directly or
    /// in a folder inside: an import that found every page of a folder
    /// already pinned makes no empty folder for it.
    static func withoutEmpty(_ folders: [PinFolder], keeping: Set<UUID>, pins: [PinDef]) -> [PinFolder] {
        let holding = Set(pins.compactMap(\.folder))
        var full = Set<UUID>()
        for id in holding where folders.contains(where: { $0.id == id }) {
            full.insert(id)
            full.formUnion(ancestors(of: id, in: folders))
        }
        return folders.filter { keeping.contains($0.id) || full.contains($0.id) || $0.isLive }
    }

    // MARK: - Arc's pinned list

    /// Arc's pinned list as pinned rows in folders: each of its folders a
    /// folder here, made inside `parent` unless one of the same name is
    /// already there, which is filled instead; deeper than maxDepth, a
    /// folder's pages go into the deepest one that may hold them. Returns
    /// the folders as they now are and each page with the folder it goes in.
    static func fromArc(_ nodes: [ArcSidebar.Node], into folders: [PinFolder], parent: UUID? = nil)
        -> (folders: [PinFolder], pages: [(item: ArcSidebar.Item, folder: UUID?)]) {
        var folders = folders
        var pages: [(item: ArcSidebar.Item, folder: UUID?)] = []
        func take(_ nodes: [ArcSidebar.Node], parent: UUID?, depth: Int) {
            for node in nodes {
                switch node {
                case .item(let item):
                    pages.append((item, parent))
                case .folder(let inner):
                    guard depth < maxDepth else {
                        take(inner.items, parent: parent, depth: depth)
                        continue
                    }
                    let id: UUID
                    if let same = folders.first(where: { $0.parent == parent && !$0.isLive && $0.name.localizedCaseInsensitiveCompare(inner.title) == .orderedSame }) {
                        id = same.id
                    } else {
                        id = UUID()
                        folders.append(PinFolder(id: id, name: inner.title, parent: parent))
                    }
                    take(inner.items, parent: id, depth: depth + 1)
                }
            }
        }
        take(nodes, parent: parent, depth: parent.map { depth(of: $0, in: folders) } ?? 0)
        return (folders, pages)
    }
}

/// pin-folders.json: each space's folders, shared by every window as the
/// pins are (see Pins.swift), and passed on with Pins.changed.
@MainActor
enum PinFolders {
    private(set) static var bySpace: [UUID: [PinFolder]] = [:]
    private static var loaded = false

    private static var file: URL { Store.file("pin-folders.json") }

    static func folders(_ space: UUID) -> [PinFolder] {
        load()
        return bySpace[space] ?? []
    }

    static func load() {
        guard !loaded else { return }
        loaded = true
        if let data = try? Data(contentsOf: file) { bySpace = decode(data) }
    }

    /// A space's folders as they now are, kept and passed to the other
    /// windows when they changed. `always`: passed on even unchanged, for
    /// a live folder whose fetch failed, to say so in its tooltip.
    static func set(_ space: UUID, _ folders: [PinFolder], from browser: Browser?, always: Bool = false) {
        load()
        let folders = PinTree.sanitized(folders)
        if (bySpace[space] ?? []) != folders {
            bySpace[space] = folders.isEmpty ? nil : folders
            save()
        } else if !always {
            return
        }
        NotificationCenter.default.post(name: Pins.changed, object: browser, userInfo: ["space": space])
    }

    /// A space deleted: its folders go with it.
    static func forget(_ space: UUID) {
        load()
        guard bySpace.removeValue(forKey: space) != nil else { return }
        save()
    }

    private static func save() {
        let all = bySpace
        Disk.write(file) { encode(all) }
    }

    /// Leniently: a space whose list won't read is a space with no folders,
    /// never a file that loses every other space's.
    nonisolated static func decode(_ data: Data) -> [UUID: [PinFolder]] {
        guard let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var out: [UUID: [PinFolder]] = [:]
        for (key, value) in top {
            guard let space = UUID(uuidString: key),
                  let raw = try? JSONSerialization.data(withJSONObject: value),
                  let folders = try? JSONDecoder().decode([PinFolder].self, from: raw), !folders.isEmpty
            else { continue }
            out[space] = folders
        }
        return out
    }

    nonisolated static func encode(_ bySpace: [UUID: [PinFolder]]) -> Data? {
        var out: [String: [PinFolder]] = [:]
        for (space, folders) in bySpace where !folders.isEmpty { out[space.uuidString] = folders }
        return try? JSONEncoder().encode(out)
    }
}
