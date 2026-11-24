import Foundation

// Several tabs picked in the column (⌘- or ⇧-click, see
// Browser.extendTabSelection) go into a pin folder or a tab group together,
// by a drag or by the tab menu, in the order the column shows them (idea
// 1092). One move of them is one step back: with Settings › Tabs › ⌘Z
// reopens a closed tab on, ⌘Z right after the move puts every one of them
// back where it was, folders and groups as they were, as it does a close.

extension Browser {
    /// What the row was just before a move: its order, each tab's group and
    /// folder, the space's groups and folders.
    struct MoveUndo {
        weak var browser: Browser?
        let space: UUID
        let row: [Tab.ID]
        let groupOf: [Tab.ID: UUID?]
        let folderOf: [Tab.ID: UUID?]
        let groups: [TabGroup]
        let folders: [PinFolder]
        /// The row as the move left it: ⌘Z undoes it only while nothing
        /// has changed since.
        var scene: [String] = []
    }

    /// The last move, while it is the last thing done: any key but ⌘Z, a
    /// click or a close forgets it, as they forget a close (lastClose).
    static var lastMove: MoveUndo?
    private static var moving = false

    /// The row as compared for ⌘Z: order, groups and folders.
    var moveScene: [String] {
        [spaceID.uuidString] + tabs.map { "\($0.id)/\($0.groupID?.uuidString ?? "")/\($0.pinFolder?.uuidString ?? "")" }
            + tabGroups.map { "\($0.id)/\($0.collapsed)" } + pinFolders.map { "\($0.id)/\($0.parent?.uuidString ?? "")" }
    }

    /// `change`, kept as one step for ⌘Z when it moved anything. A move
    /// made inside another is part of that one.
    func undoableMove(_ change: () -> Void) {
        guard !Browser.moving else { return change() }
        var before = MoveUndo(browser: self, space: spaceID, row: tabs.map(\.id),
                              groupOf: Dictionary(tabs.map { ($0.id, $0.groupID) }, uniquingKeysWith: { a, _ in a }),
                              folderOf: Dictionary(tabs.map { ($0.id, $0.pinFolder) }, uniquingKeysWith: { a, _ in a }),
                              groups: tabGroups, folders: pinFolders)
        let was = moveScene
        Browser.moving = true
        change()
        Browser.moving = false
        let now = moveScene
        guard now != was else { return }
        before.scene = now
        Browser.lastMove = before
        Browser.lastClose = nil
    }

    var canUndoMove: Bool {
        guard let last = Browser.lastMove, last.browser === self, last.space == spaceID else { return false }
        return last.scene == moveScene
    }

    /// ⌘Z, just after a move: every tab it moved back where it was.
    func undoMove() {
        guard canUndoMove, let last = Browser.lastMove else { return }
        Browser.lastMove = nil
        objectWillChange.send()
        PinFolders.set(spaceID, last.folders, from: self)
        tabGroups = last.groups
        for tab in tabs {
            if let group = last.groupOf[tab.id] { tab.groupID = group }
            if let folder = last.folderOf[tab.id] { tab.pinFolder = folder }
        }
        let place = Dictionary(last.row.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { a, _ in a })
        // A tab opened since the move (none while it can be undone) keeps
        // its place at the end.
        let row = tabs.enumerated().sorted { a, b in
            (place[a.element.id] ?? last.row.count + a.offset) < (place[b.element.id] ?? last.row.count + b.offset)
        }.map(\.element)
        rearrangeTabs(row)
        arrangePinFolders()
        writeSession(now: true)
        announce("Move undone")
    }

    /// Pinned rows into a folder (nil: the top) together, in the order the
    /// row has them: beside `anchor`, or at the end of that folder's pins.
    /// Those that can't go in a folder stay where they are.
    func movePins(_ pins: [Tab], into folder: UUID?, anchor: Tab.ID? = nil, after: Bool = false) {
        let ids = Set(pins.map(\.id))
        let moving = tabs.filter { ids.contains($0.id) && takesFolder($0) }
        guard !moving.isEmpty else { return }
        undoableMove {
            // Never into a live folder: what it holds is its feed's.
            let folder = folder.flatMap { id in pinFolders.contains { $0.id == id && !$0.isLive } ? id : nil }
            objectWillChange.send()
            for tab in moving { tab.pinFolder = folder }
            let carried = Set(moving.map(\.id))
            var row = tabs.filter { !carried.contains($0.id) }
            if let anchor, let at = row.firstIndex(where: { $0.id == anchor }) {
                row.insert(contentsOf: moving, at: after ? at + 1 : at)
            } else {
                let end = (row.lastIndex { $0.pin != nil && $0.listed && !$0.shy }).map { $0 + 1 }
                    ?? row.firstIndex { $0.pin == nil || $0.shy } ?? row.count
                row.insert(contentsOf: moving, at: end)
            }
            rearrangeTabs(row)
            arrangePinFolders()
            writeSession(now: true)
        }
    }

    /// Tabs into a group (nil: out of their groups) together, as the tab
    /// menu's Move to Group does: each keeps its place among the others.
    func move(_ several: [Tab], toGroup id: UUID?) {
        undoableMove {
            for tab in several { move(tab, toGroup: id) }
        }
    }

    /// The tab menu's Move to Group › New Group: a group holding these, in
    /// their order, named for its editing.
    @discardableResult
    func addTabGroup(containing several: [Tab]) -> UUID? {
        guard let first = several.first else { return nil }
        var made: UUID?
        undoableMove {
            let id = addTabGroup(containing: first)
            made = id
            for tab in several.dropFirst() { move(tab, toGroup: id) }
        }
        return made
    }
}
