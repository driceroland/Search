import SwiftUI

// Folders, as Arc has them: named, foldable places among the pinned rows,
// above the line Clear works under. What is in one is kept the way a pinned
// row is — Clear passes it by, ⌘W puts it down and takes it back to the
// page it was put there at — because it is a pinned row, one that says
// which folder it is in (PinDef.folder, Tab.folder).
//
// A folder holds tabs and folders; a folder in a folder holds tabs only.
// One level is the whole of Arc's nesting most people use, and every level
// more is another way for a tab to be out of sight.
//
// The folders are the space's, the same in every window, as its pins are:
// folders.json beside pins.json (see Pins.folders). pins.json itself keeps
// the shape older versions read, which pass over the new "folder" key and
// show a folder's tabs as pinned rows.
//
// They took the place of tab groups, which were a window's own and held
// tabs that Clear and ⌘W closed. A session still holding groups has each
// turned into a folder of the same name, its tabs pinned rows in it, the
// first time the row is read (see Browser.foldGroups).

struct Folder: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    /// Folded: its name alone, and the tab on screen if that is in it.
    var folded = false
    /// The folder it is in; nil at the top, among the pinned rows.
    var parent: UUID? = nil
}

extension Folder {
    private enum Keys: String, CodingKey { case id, name, folded, parent }

    /// Leniently, as the session reads its groups: a part that doesn't make
    /// sense is taken for its plain value, never for a file that won't read.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = (try? c.decode(String.self, forKey: .name)) ?? "Folder"
        folded = (try? c.decodeIfPresent(Bool.self, forKey: .folded)) ?? false
        parent = try? c.decodeIfPresent(UUID.self, forKey: .parent)
    }

    /// The number an extension knows the folder by, as Chrome numbers its
    /// tab groups. Taken from the identifier, so it stays the same for as
    /// long as the folder lasts, across launches too, with nothing to keep.
    /// A group turned into a folder keeps its identifier, and so its number.
    static func number(_ id: UUID) -> Int {
        let u = id.uuid
        let n = Int(u.0 & 0x7F) << 24 | Int(u.1) << 16 | Int(u.2) << 8 | Int(u.3)
        return n == 0 ? 1 : n
    }
}

/// One line of the folders as the column draws them: a folder's own row,
/// or a tab in one, each a step further in for each folder around it.
enum FolderLine: Identifiable {
    case folder(Folder, depth: Int)
    case tab(Tab, depth: Int, folder: UUID)

    var id: UUID {
        switch self {
        case .folder(let folder, _): folder.id
        case .tab(let tab, _, _): tab.id
        }
    }

    var depth: Int {
        switch self {
        case .folder(_, let depth), .tab(_, let depth, _): depth
        }
    }
}

enum Folders {
    /// How far in each level is drawn.
    static let indent: CGFloat = 14

    /// The folders at the top: those in no folder, and any whose folder
    /// has gone or is itself in one, so that nothing is ever out of reach.
    static func tops(_ folders: [Folder]) -> [Folder] {
        let top = Set(folders.filter { $0.parent == nil }.map(\.id))
        return folders.filter { $0.parent.map { !top.contains($0) } ?? true }
    }

    /// The folders in `id`, when it is a folder at the top.
    static func inside(_ id: UUID, _ folders: [Folder]) -> [Folder] {
        guard tops(folders).contains(where: { $0.id == id }) else { return [] }
        return folders.filter { $0.parent == id }
    }

    /// Every line of the folders, top to bottom, from the row's pins in
    /// their order: each folder, its tabs, then the folders in it and
    /// theirs. A folded one shows its name, and under it the tab in front
    /// (`front`) if that is anywhere inside it, so the page on screen always
    /// has its place in the column. The column on screen and another space
    /// passing in a swipe both draw from this, so the two never differ —
    /// drawn apart, a folder's tabs stood a step out for the swipe and
    /// jumped in as the space landed.
    @MainActor
    static func lines(_ folders: [Folder], pins: [Tab], front: Tab.ID?) -> [FolderLine] {
        let members = Dictionary(grouping: pins.filter { $0.folder != nil }, by: { $0.folder ?? UUID() })
        var out: [FolderLine] = []
        for top in tops(folders) {
            out.append(.folder(top, depth: 0))
            let own = members[top.id] ?? []
            let subs = folders.filter { $0.parent == top.id }
            if top.folded {
                let all = own + subs.flatMap { members[$0.id] ?? [] }
                if let shown = all.first(where: { $0.id == front }) {
                    out.append(.tab(shown, depth: 1, folder: shown.folder ?? top.id))
                }
                continue
            }
            out += own.map { .tab($0, depth: 1, folder: top.id) }
            for sub in subs {
                out.append(.folder(sub, depth: 1))
                let theirs = members[sub.id] ?? []
                let shown = sub.folded ? theirs.filter { $0.id == front } : theirs
                out += shown.map { .tab($0, depth: 2, folder: sub.id) }
            }
        }
        return out
    }

    /// The row in the order the column shows it: the pins in no folder as
    /// they are, then each folder's tabs in the folders' order, then every
    /// tab that isn't a pin. ⌘1–9, ⌃Tab and the extensions' indexes read
    /// the row, so it and the column never disagree.
    @MainActor
    static func ordered(_ row: [Tab], folders: [Folder]) -> [Tab] {
        let known = Set(folders.map(\.id))
        let pins = row.filter { $0.pin != nil }
        let free = pins.filter { $0.folder.map { !known.contains($0) } ?? true }
        var filed: [Tab] = []
        for top in tops(folders) {
            filed += pins.filter { $0.folder == top.id }
            for sub in folders where sub.parent == top.id {
                filed += pins.filter { $0.folder == sub.id }
            }
        }
        return free + filed + row.filter { $0.pin == nil }
    }
}

extension Browser {
    /// The space's folders, in their order: the same in every window.
    var folders: [Folder] { Pins.folders(spaceID) }

    /// The folder a tab is in, when it is one this space has.
    func folder(of tab: Tab) -> Folder? {
        guard tab.pin != nil, let id = tab.folder else { return nil }
        return folders.first { $0.id == id }
    }

    /// Whether a tab may go into a folder: anything a pin can be made of.
    func filable(_ tab: Tab) -> Bool {
        !tab.shy && !tab.bench && tabs.contains { $0.id == tab.id }
    }

    /// The folders' lines for the column on screen.
    var folderLines: [FolderLine] {
        Folders.lines(folders, pins: tabs.filter { $0.pin != nil }, front: activeSplit?.left ?? activeID)
    }

    func setFolders(_ list: [Folder]) {
        objectWillChange.send()
        Pins.setFolders(spaceID, list, from: self)
    }

    /// A new folder, at the end of the top level or of the one it is made
    /// in, named "Folder" and ready for its own name to be typed.
    @discardableResult
    func newFolder(in parent: UUID? = nil, named name: String = "Folder", editing: Bool = true) -> UUID? {
        var list = folders
        // One level down, no more.
        if let parent, !Folders.tops(list).contains(where: { $0.id == parent }) { return nil }
        let made = Folder(id: UUID(), name: name, parent: parent)
        if let parent, let at = list.firstIndex(where: { $0.id == parent }) { list[at].folded = false }
        list.append(made)
        setFolders(list)
        if editing { editingFolderID = made.id }
        return made.id
    }

    func renameFolder(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var list = folders
        guard !trimmed.isEmpty, let at = list.firstIndex(where: { $0.id == id }), list[at].name != trimmed else { return }
        list[at].name = trimmed
        setFolders(list)
    }

    func toggleFolder(_ id: UUID) {
        guard let folder = folders.first(where: { $0.id == id }) else { return }
        setFolded(id, !folder.folded)
    }

    func setFolded(_ id: UUID, _ folded: Bool) {
        var list = folders
        guard let at = list.firstIndex(where: { $0.id == id }), list[at].folded != folded else { return }
        list[at].folded = folded
        setFolders(list)
    }

    /// Delete Folder: the folder and those in it go, and every tab in them
    /// comes out as an ordinary tab under the line, open as it was. Nothing
    /// is closed.
    func deleteFolder(_ id: UUID) {
        let going = Set([id] + Folders.inside(id, folders).map(\.id))
        let freed = tabs.filter { $0.folder.map(going.contains) ?? false }
        for tab in freed { unpin(tab) }
        if let editing = editingFolderID, going.contains(editing) { editingFolderID = nil }
        // The pins first, the folders after: another window between the two
        // sees tabs in no folder, never a folder's tabs with none to be in.
        setFolders(folders.filter { !going.contains($0.id) })
        writeSession(now: true)
    }

    /// The tabs in a folder and in the folders in it, in the row's order.
    func tabs(inFolder id: UUID) -> [Tab] {
        let ids = Set([id] + Folders.inside(id, folders).map(\.id))
        return tabs.filter { $0.pin != nil && $0.folder.map(ids.contains) == true }
    }

    /// Move to Folder, or a tab carried onto one: into the folder `id` at
    /// `index` among its tabs (nil, at the end), pinned as a row if it
    /// wasn't — Pin as Row's pin, page and history kept. `id` nil takes it
    /// out of its folder, to the end of the pinned rows: still kept.
    @discardableResult
    func move(_ tab: Tab, toFolder id: UUID?, at index: Int? = nil) -> Bool {
        guard filable(tab) else { return false }
        let list = folders
        if let id, !list.contains(where: { $0.id == id }) { return false }
        if tab.pin == nil {
            guard tab.page == nil else { return false }
            pin(tab, listed: true)
            guard tab.pin != nil else { return false }
        }
        objectWillChange.send()
        tab.listed = true
        tab.folder = id
        var row = tabs.filter { $0.id != tab.id }
        let place: Int
        if let id {
            let peers = row.filter { $0.pin != nil && $0.folder == id }
            if let index, peers.indices.contains(index), let at = row.firstIndex(where: { $0 === peers[index] }) {
                place = at
            } else if let last = peers.last, let at = row.firstIndex(where: { $0 === last }) {
                place = at + 1
            } else {
                place = row.firstIndex { $0.pin == nil } ?? row.count
            }
        } else {
            // After the rows in no folder, which the row keeps ahead of the
            // folders' (see Folders.ordered).
            place = row.firstIndex { $0.pin == nil || $0.folder != nil } ?? row.count
        }
        row.insert(tab, at: place)
        // The folder it went into opens, and the one around that.
        if let id, let folder = list.first(where: { $0.id == id }) {
            setFolded(id, false)
            if let parent = folder.parent { setFolded(parent, false) }
        }
        reorder(row)
        writeSession(now: true)
        return true
    }

    /// A folder carried by its row: among the folders in `parent` (nil, the
    /// top) at `index`, counted without it. Into a folder only when it holds
    /// no folder of its own and `parent` is at the top, so nothing is ever
    /// more than one level down. Its id, and so the number an extension
    /// knows it by, stays; its tabs go with it.
    func placeFolder(_ id: UUID, in parent: UUID?, at index: Int) {
        var list = folders
        guard let from = list.firstIndex(where: { $0.id == id }) else { return }
        if let parent {
            guard parent != id, Folders.tops(list).contains(where: { $0.id == parent }),
                  !list.contains(where: { $0.parent == id }) else { return }
        }
        var folder = list.remove(at: from)
        folder.parent = parent
        let top = Set(Folders.tops(list).map(\.id))
        let siblings = list.indices.filter { parent == nil ? top.contains(list[$0].id) : list[$0].parent == parent }
        let place = siblings.indices.contains(index) ? siblings[index] : (siblings.last.map { $0 + 1 } ?? list.count)
        list.insert(folder, at: place)
        if let parent, let at = list.firstIndex(where: { $0.id == parent }) { list[at].folded = false }
        guard list != folders else { return }
        setFolders(list)
        // The row follows the folders' new order, and so does pins.json.
        reorder(Folders.ordered(tabs, folders: list))
        writeSession(now: true)
    }

    /// A folder an extension's tabs left empty: gone, as Chrome lets go of
    /// a tab group with no tab in it. The ones you made stay, empty or not.
    func dropIfEmpty(_ ids: Set<UUID>) {
        let empty = ids.filter { id in
            folders.contains { $0.id == id } && tabs(inFolder: id).isEmpty && Folders.inside(id, folders).isEmpty
        }
        guard !empty.isEmpty else { return }
        setFolders(folders.filter { !empty.contains($0.id) })
    }

    // MARK: - tab groups, once

    /// A row as a session from before folders left it, its groups made
    /// folders (see the top of this file): each group with a tab in it a
    /// folder of the space's, of the same name and identifier, folded as
    /// it was, and each of its tabs a pin kept as a row in it, its home
    /// the page it is on. Nothing is closed or lost; the row goes back to
    /// its file without its groups as soon as it is read, and doing it a
    /// second time, should the file not have been written, finds the pins
    /// already made and makes no more.
    func foldGroups(_ saved: Session.Shape, space: UUID) -> Session.Shape {
        guard let groups = saved.groups, !groups.isEmpty else { return saved }
        var shape = saved
        shape.groups = nil
        var list = Pins.folders(space)
        var defs = Pins.defs(space)
        var changed = false
        for group in groups {
            let members = shape.tabs.indices.filter { shape.tabs[$0].pin == nil && shape.tabs[$0].groupID == group.id }
            guard !members.isEmpty else { continue }
            if !list.contains(where: { $0.id == group.id }) {
                list.append(Folder(id: group.id, name: group.name, folded: group.collapsed))
            }
            for at in members {
                var entry = shape.tabs[at]
                let host = URL(string: entry.url)?.host()?.replacingOccurrences(of: "www.", with: "") ?? ""
                let def = defs.first { $0.folder == group.id && $0.home == entry.url }
                    ?? PinDef(id: UUID(), letter: host.first.map { String($0).uppercased() } ?? "•",
                              home: entry.url, title: entry.title, name: entry.name, listed: true, folder: group.id)
                if !defs.contains(where: { $0.id == def.id }) { defs.append(def) }
                entry.pin = def.letter
                entry.pinID = def.id
                entry.home = def.home
                entry.listed = true
                entry.groupID = nil
                entry.letGo = nil
                shape.tabs[at] = entry
                changed = true
            }
        }
        for at in shape.tabs.indices { shape.tabs[at].groupID = nil }
        guard changed else { return shape }
        // The folders first, so that no window sees a pin in a folder it
        // doesn't know of yet.
        Pins.setFolders(space, list, from: self)
        Pins.set(space, defs, from: self)
        writeRow(space, shape, now: true)
        return shape
    }
}

/// A folder's own line in the column: a chevron and its name, as tall as a
/// tab's, set in by the column for its depth. A click folds or opens it; its
/// menu renames it, makes a folder in it, or deletes it.
struct FolderRow: View {
    @Environment(\.greys) private var greys
    @ObservedObject var browser: Browser
    let folder: Folder
    var height: CGFloat = 28
    var size: CGFloat = 12.5
    /// Drawn in another space passing by: nothing to press.
    var interactive = true
    /// A tab carried over it would go in.
    var target = false

    @State private var draft = ""
    @State private var hovering = false
    @FocusState private var focused: Bool

    private var editing: Bool { interactive && browser.editingFolderID == folder.id }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .rotationEffect(.degrees(folder.folded ? 0 : 90))
                .frame(width: 15)
            if editing {
                TextField("Folder name", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: size, weight: .medium))
                    .focused($focused)
                    .onSubmit(commit)
                    .onExitCommand { browser.editingFolderID = nil }
            } else {
                Text(folder.name)
                    .font(.system(size: size, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(hovering || target ? Palette.ink.opacity(0.7) : Palette.muted)
        .padding(.leading, 10)
        .frame(height: height)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(target ? greys.wash : (hovering ? greys.hover : .clear)))
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .onTapGesture { if interactive && !editing { withAnimation(Motion.settle) { browser.toggleFolder(folder.id) } } }
        .onHover { hovering = interactive && $0 }
        .onChange(of: editing, initial: true) { _, now in
            guard now else { return }
            draft = folder.name
            DispatchQueue.main.async { focused = true }
        }
        .onChange(of: focused) { _, now in if !now && editing { commit() } }
        .contextMenu { if interactive { menu } }
        .animation(Motion.quick, value: hovering)
        .animation(Motion.quick, value: target)
    }

    @ViewBuilder
    private var menu: some View {
        Button(folder.folded ? "Open Folder" : "Fold Folder") { browser.toggleFolder(folder.id) }
        Divider()
        Button("Rename…") { browser.editingFolderID = folder.id }
        if Folders.tops(browser.folders).contains(where: { $0.id == folder.id }) {
            Button("New Folder Inside") { browser.newFolder(in: folder.id) }
        }
        Divider()
        Button("Delete Folder…") {
            let count = browser.tabs(inFolder: folder.id).count
            let tabs = count == 1 ? "Its tab stays open" : count == 0 ? "Nothing in it is closed" : "Its \(count) tabs stay open"
            Ask.sure("Delete “\(folder.name)”?",
                     detail: "\(tabs), unpinned, under the line with your other tabs.",
                     confirm: "Delete Folder") {
                withAnimation(Motion.settle) { browser.deleteFolder(folder.id) }
            }
        }
    }

    private func commit() {
        browser.renameFolder(folder.id, to: draft)
        browser.editingFolderID = nil
    }
}
