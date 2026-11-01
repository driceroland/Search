import SwiftUI

// Carried between the pins and the tabs.
extension SideBar {
    /// The block a carried tab's point is measured in.
    enum From { case pins, listed, folders, rows }

    /// The place open in the grid, while a tab is carried over it.
    var ghostSquare: Int? {
        if case .squares(let at)? = crossing?.target { return at }
        return nil
    }

    /// The tab being carried across, while it is.
    var crossingTab: Tab? {
        crossing.flatMap { crossing in browser.tabs.first { $0.id == crossing.tab } }
    }

    /// A square being carried out over the rows.
    var carriedPin: Bool {
        guard let crossing, ghostSquare == nil else { return false }
        return browser.tabs.first { $0.id == crossing.tab }.map {
            $0.pin != nil && !$0.listed
        } ?? false
    }

    func columnPoint(_ point: CGPoint, from: From) -> CGPoint {
        let origin: CGPoint
        switch from {
        case .pins: origin = frames.grid?.origin ?? .zero
        case .listed: origin = frames.listed?.origin ?? .zero
        case .folders: origin = frames.folders?.origin ?? .zero
        case .rows: origin = frames.rows.origin
        }
        return CGPoint(x: point.x + origin.x, y: point.y + origin.y)
    }

    /// Where `tab` would land with the hand at `point` (the column's
    /// space): nil over its own block, where it moves as it always did, or
    /// over one that won't take it — a pair, a private tab.
    private func target(for tab: Tab, at point: CGPoint) -> PinDrop.Target? {
        let squares = browser.squarePins.filter { $0.id != tab.id }
        let gridShown = !squares.isEmpty || ghostSquare != nil
        let listedShown = !browser.listedPins.isEmpty || isListedGhost
        let foldersShown = !browser.folders.isEmpty
        let zone = PinDrop.zone(point, width: prefs.sideWidth - 20,
                                gridBottom: gridShown ? frames.grid?.maxY : nil,
                                listed: listedShown ? frames.listed : nil,
                                folders: foldersShown ? frames.folders : nil)
        // A row in a folder is a row of its own kind: out of the folder,
        // among the rows or the squares, it is moved as a pin of the kind
        // it lands among.
        let filed = browser.folder(of: tab) != nil
        switch zone {
        case .none:
            return nil
        case .squares:
            let takes = tab.pin == nil ? browser.pinsByDrag(tab) : tab.listed
            guard takes else { return nil }
            let origin = gridShown ? frames.grid?.origin ?? .zero : .zero
            let slot = PinDrop.gridSlot(CGPoint(x: point.x - origin.x, y: point.y - origin.y),
                                        cells: pinCells(squares.count + 1))
            return .squares(browser.pinSlot(tab, listed: false, proposed: slot))
        case .listed:
            let takes = tab.pin == nil ? browser.pinsByDrag(tab) : (!tab.listed || filed)
            guard takes, let listed = frames.listed else { return nil }
            let rows = browser.listedPins.filter { $0.id != tab.id }
            let ghost: (Int, CGFloat)? = if case .listed(let at)? = crossing?.target { (at, rowHeight) } else { nil }
            let slot = PinDrop.rowSlot(y: point.y - listed.minY, heights: rows.map { _ in rowHeight },
                                       gap: SideBar.gap, ghost: ghost)
            return .listed(browser.pinSlot(tab, listed: true, proposed: slot))
        case .folders:
            guard tab.pin != nil || browser.pinsByDrag(tab), !tab.shy else { return nil }
            // Over the place already opened for it: it stays.
            if case .folder? = crossing?.target, crossing?.tab == tab.id,
               let open = frames.lines[ColumnFrames.ghost], point.y >= open.minY, point.y < open.maxY {
                return crossing?.target
            }
            let lines = browser.folderLines.compactMap { line in frames.lines[line.id].map { (line: line, frame: $0) } }
            let row = browser.tabs
            return PinDrop.folderSlot(y: point.y, lines: lines, carried: tab.id) { id in
                row.filter { $0.pin != nil && $0.folder == id }.map(\.id)
            }
        case .loose:
            guard tab.pin != nil else { return nil }
            let loose = looseTabs
            guard !loose.isEmpty, let top = frames.loose?.minY else { return .loose(0) }
            let ghost: (Int, CGFloat)? = if case .loose(let at)? = crossing?.target { (at, rowHeight) } else { nil }
            let heights = loose.map { browser.split(for: $0) != nil ? rowHeight * 2 : rowHeight }
            return .loose(PinDrop.rowSlot(y: point.y - top, heights: heights, gap: SideBar.gap, ghost: ghost))
        }
    }

    private var isListedGhost: Bool {
        if case .listed? = crossing?.target { return true }
        return false
    }

    /// The hand moved: the block it is over shows where the tab would
    /// land, and says so once, by touch, as it starts to. True while it does.
    func cross(_ tab: Tab, _ point: CGPoint, from: From) -> Bool {
        let now = target(for: tab, at: columnPoint(point, from: from))
            .map { PinDrop.Crossing(tab: tab.id, target: $0) }
        if now != crossing {
            if crossing == nil, now != nil {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
            withAnimation(Motion.settle) { crossing = now }
        }
        return now != nil
    }

    /// Let go (nil: called off). Where it was shown it would land is where
    /// it lands; true when that was across the line.
    func land(_ tab: Tab, _ point: CGPoint?) -> Bool {
        let shown = crossing?.tab == tab.id ? crossing?.target : nil
        guard point != nil, let shown else {
            if crossing != nil { withAnimation(Motion.settle) { crossing = nil } }
            return false
        }
        withAnimation(Motion.settle) {
            crossing = nil
            switch shown {
            case .squares(let at): browser.pinDropped(tab, listed: false, at: at)
            case .listed(let at): browser.pinDropped(tab, listed: true, at: at)
            case .loose(let at): browser.unpinDropped(tab, at: at)
            case .folder(let id, let at): browser.move(tab, toFolder: id, at: at)
            }
        }
        return true
    }

    /// The pinned rows, the loose tabs and the row that makes another,
    /// which scroll as one.
    var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !browser.pinsHidden {
                listed
                folderRows
            }
            loose
        }
    }

    /// The foot's door and its margin beneath.
    static let footHeight: CGFloat = 26 + 10

    var newTab: some View {
        Quiet(icon: "plus", title: "New tab", height: rowHeight, size: prefs.sideTitle) { browser.launch() }
    }

    /// One small door at the bottom: the settings.
    var foot: some View {
        SideFoot(browser: browser, prefs: prefs, fetches: browser.fetches)
    }
}
