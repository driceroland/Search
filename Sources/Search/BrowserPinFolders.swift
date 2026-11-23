import Foundation

// Folders among the pinned rows, as the column and the menus use them (see
// PinFolders.swift for what they are and where they are kept). Only rows go
// in one; the row's order on disk is the order drawn.

/// One line of the pinned rows as the column draws it.
enum PinRowLine: Identifiable {
    case folder(PinFolder, depth: Int)
    case pin(Tab, depth: Int)

    var id: UUID {
        switch self {
        case .folder(let folder, _): folder.id
        case .pin(let tab, _): tab.id
        }
    }

    /// For the bench: what it is, how far in, and what it says.
    @MainActor var described: [Any] {
        switch self {
        case .folder(let folder, let depth): ["folder", depth, folder.name, folder.collapsed]
        case .pin(let tab, let depth): ["pin", depth, tab.name ?? tab.title, false]
        }
    }
}

extension Browser {
    /// The pin folders.
    var pinFolders: [PinFolder] { PinFolders.folders() }

    /// The tabs the column draws loose, out of any group (SideBar.looseTabs).
    var looseRow: [Tab] {
        displayedTabs.filter { $0.pin == nil && (!prefs.usesTabGroups || group(of: $0) == nil) }
    }

    /// Whether the pinned rows are drawn in folders now: the switch on, the
    /// rows shown, and a folder to draw. With none, the rows are drawn as
    /// they always were.
    var showsPinFolderRows: Bool { prefs.showsPinFolders && !pinFolders.isEmpty }

    /// The pinned rows as drawn, folders and all.
    func pinRowLines() -> [PinRowLine] {
        Browser.pinRowLines(listedPins, folders: pinFolders, showing: activeID)
    }

    /// `showing`: the tab in front, drawn even inside a folded folder.
    static func pinRowLines(_ rows: [Tab], folders: [PinFolder], showing: Tab.ID?) -> [PinRowLine] {
        let byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return PinTree.lines(pins: rows.map { ($0.id, $0.pinFolder) },
                             folders: folders, showing: showing)
            .compactMap { line -> PinRowLine? in
                switch line {
                case .folder(let folder, let depth): return .folder(folder, depth: depth)
                case .pin(let id, let depth): return byID[id].map { .pin($0, depth: depth) }
                }
            }
    }

    /// A row's pins with the rows in the order their folders draw them:
    /// the squares as they are, then the rows in folder order, then the rest.
    static func arrangedPins(_ row: [Tab], folders: [PinFolder]) -> [Tab] {
        let pinned = row.filter { $0.pin != nil && !$0.shy }
        let loose = row.filter { $0.pin == nil || $0.shy }
        let rows = pinned.filter(\.listed)
        let byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let ordered = PinTree.orderedIDs(rows.map { ($0.id, $0.pinFolder) }, folders: folders).compactMap { byID[$0] }
        return pinned.filter { !$0.listed } + ordered + loose
    }

    /// The row put in folder order, when it isn't.
    func arrangePinFolders() {
        guard prefs.pinFolders else { return }
        let row = Browser.arrangedPins(tabs, folders: pinFolders)
        rearrangeTabs(row)
    }

    private func savePinFolders(_ folders: [PinFolder]) {
        objectWillChange.send()
        PinFolders.set(folders, from: self)
    }

    /// Whether a pin can go in a folder: a row.
    func takesFolder(_ tab: Tab) -> Bool {
        // A split pinned whole stays at the top of the rows: a folder's
        // lines hold one page each.
        tab.pin != nil && tab.listed && !tab.shy && pinnedPair(of: tab) == nil
    }

    /// New Folder: inside `parent`, or beside `tab` in the folder it is in,
    /// holding it. Its name arrives selected, as a new group's does, unless
    /// `rename` is false. Nil when no folder may be made there.
    @discardableResult
    func newPinFolder(named name: String = "New Folder", in parent: UUID? = nil, holding tab: Tab? = nil,
                      rename: Bool = true) -> UUID? {
        var folders = pinFolders
        if let tab, !takesFolder(tab) { return nil }
        let asked = parent != nil
        var parent = parent ?? tab?.pinFolder
        if let at = parent, !folders.contains(where: { $0.id == at }) { parent = nil }
        // Beside a pin in the deepest folder there is: one level up. Asked
        // for inside that folder: none.
        if let at = parent, !PinTree.canMake(in: at, in: folders) {
            if asked { return nil }
            parent = folders.first { $0.id == at }?.parent
        }
        guard PinTree.canMake(in: parent, in: folders) else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let made = PinFolder(id: UUID(), name: trimmed.isEmpty ? "New Folder" : trimmed, parent: parent)
        folders.append(made)
        savePinFolders(folders)
        if let tab {
            movePin(tab, into: made.id)
        } else {
            arrangePinFolders()
            writeSession(now: true)
        }
        if rename { editingPinFolder = made.id }
        return made.id
    }

    func renamePinFolder(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var folders = pinFolders
        guard !trimmed.isEmpty, let index = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[index].name = String(trimmed.prefix(200))
        savePinFolders(folders)
    }

    /// Folded or opened, here and in every window.
    func setPinFolderFolded(_ id: UUID, _ folded: Bool) {
        var folders = pinFolders
        guard let index = folders.firstIndex(where: { $0.id == id }), folders[index].collapsed != folded else { return }
        folders[index].collapsed = folded
        savePinFolders(folders)
    }

    func togglePinFolder(_ id: UUID) {
        guard let folder = pinFolders.first(where: { $0.id == id }) else { return }
        setPinFolderFolded(id, !folder.collapsed)
    }

    /// Delete Folder: what it held, folders and pins, goes up into the
    /// folder that held it. No pin is closed.
    func deletePinFolder(_ id: UUID) {
        let folders = pinFolders
        guard let gone = folders.first(where: { $0.id == id }) else { return }
        if editingPinFolder == id { editingPinFolder = nil }
        savePinFolders(PinTree.removing(id, folders: folders, pins: []).folders)
        for tab in tabs where tab.pinFolder == id { tab.pinFolder = gone.parent }
        arrangePinFolders()
        writeSession(now: true)
    }

    /// A folder into another (nil: the top), if it fits there.
    func movePinFolder(_ id: UUID, into parent: UUID?) {
        var folders = pinFolders
        guard let index = folders.firstIndex(where: { $0.id == id }), folders[index].parent != parent,
              PinTree.canMove(id, into: parent, in: folders) else { return }
        folders[index].parent = parent
        savePinFolders(folders)
        arrangePinFolders()
        writeSession(now: true)
    }

    /// A folder carried by its heading and let go (PinTree.folderPlace):
    /// into another, out to the top, or before another folder, if it fits.
    func movePinFolder(_ id: UUID, to place: PinTree.FolderPlace) {
        let folders = pinFolders
        guard PinTree.canMove(id, into: place.parent, in: folders) else { return }
        let moved = PinTree.moving(id, to: place, in: folders)
        guard moved != folders else { return }
        savePinFolders(moved)
        arrangePinFolders()
        writeSession(now: true)
    }

    /// A pinned row into a folder (nil: the top), beside `anchor`, or at the
    /// end of that folder's pins.
    func movePin(_ tab: Tab, into folder: UUID?, anchor: Tab.ID? = nil, after: Bool = false) {
        guard takesFolder(tab), let here = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        // Never into a live folder: what it holds is its feed's.
        let folder = folder.flatMap { id in pinFolders.contains { $0.id == id } ? id : nil }
        objectWillChange.send()
        tab.pinFolder = folder
        var row = tabs
        row.remove(at: here)
        if let anchor, anchor != tab.id, let at = row.firstIndex(where: { $0.id == anchor }) {
            row.insert(tab, at: after ? at + 1 : at)
        } else {
            let end = (row.lastIndex { $0.pin != nil && $0.listed && !$0.shy }).map { $0 + 1 }
                ?? row.firstIndex { $0.pin == nil || $0.shy } ?? row.count
            row.insert(tab, at: end)
        }
        rearrangeTabs(row)
        arrangePinFolders()
        writeSession(now: true)
    }

    /// A pin let go at a place the column worked out (PinTree.place).
    func movePin(_ tab: Tab, to place: PinTree.Place) {
        movePin(tab, into: place.folder, anchor: place.anchor, after: place.after)
    }
}
