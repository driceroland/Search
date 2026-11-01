import SwiftUI

// The rows of tabs.
extension SideBar {
    /// The pins kept as rows, under the squares: Arc's pinned list. Each is
    /// a row like any other to look at, carried only among its own kind.
    var listed: some View {
        let pins = browser.listedPins
        let squares = browser.squarePins.count
        let ghost: Int? = if case .listed(let at)? = crossing?.target { at } else { nil }
        return VStack(spacing: SideBar.gap) {
            ForEach(Array(pins.enumerated()), id: \.element.id) { index, tab in
                if ghost == index, let carried = crossingTab {
                    RowGhost(tab: carried, height: rowHeight, size: prefs.sideTitle)
                }
                SideRow(browser: browser, prefs: prefs, tab: tab,
                        live: tab.id == browser.shownID, pill: pill,
                        close: { browser.close(tab) })
                    .modifier(Carried(index: index, count: pins.count,
                                      step: rowHeight + SideBar.gap, vertical: true,
                                      space: "listed",
                                      cross: { cross(tab, $0, from: .listed) },
                                      land: { land(tab, $0) }, faded: crossing?.tab == tab.id) {
                        browser.moveDisplayedTab(tab, to: $0 + squares)
                    })
            }
            if let ghost, ghost >= pins.count, let carried = crossingTab {
                RowGhost(tab: carried, height: rowHeight, size: prefs.sideTitle)
            }
        }
        .coordinateSpace(name: "listed")
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named("column")) }) { [frames] in frames.listed = $0 }
        .padding(.bottom, pins.isEmpty && ghost == nil ? 0 : SideBar.gap)
    }

    /// The folders and what is in them, between the pinned rows and the
    /// line: kept, as the rows are. A tab is carried into one, among its
    /// tabs, or out of it, through the column's crossing (see target); a
    /// folder by its own row, among the others or into one (see placing).
    @ViewBuilder
    var folderRows: some View {
        let lines = browser.folderLines
        let ghost = folderGhost(lines)
        let spot = placeGhost(lines)
        let carriedFolder = placing.flatMap { place in browser.folders.first { $0.id == place.folder } }
        if !lines.isEmpty {
            VStack(spacing: SideBar.gap) {
                ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                    if let ghost, ghost.index == index, let carried = crossingTab {
                        RowGhost(tab: carried, height: rowHeight, size: prefs.sideTitle)
                            .padding(.leading, CGFloat(ghost.depth) * Folders.indent)
                            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named("column")) }) { [frames] in frames.lines[ColumnFrames.ghost] = $0 }
                    }
                    if let spot, spot.index == index, let carriedFolder {
                        FolderGhost(name: carriedFolder.name, height: rowHeight, size: prefs.sideTitle)
                            .padding(.leading, CGFloat(spot.depth) * Folders.indent)
                            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named("column")) }) { [frames] in frames.lines[ColumnFrames.ghost] = $0 }
                    }
                    Group {
                        switch line {
                        case .folder(let folder, _):
                            let into = folder.folded && (crossingFolder == folder.id || placing?.parent == folder.id)
                            folderLine(line, activeID: browser.shownID, interactive: true, pill: pill, target: into)
                                // Carried by its row: among the folders, or
                                // into one (see PinDrop.folderPlace).
                                .modifier(Carried(index: 0, count: 1, step: rowHeight + SideBar.gap, vertical: true,
                                                  space: "folders",
                                                  cross: { carry(folder, $0) },
                                                  land: { place(folder, $0) }, faded: placing?.folder == folder.id) { _ in })
                        case .tab(let tab, _, _):
                            folderLine(line, activeID: browser.shownID, interactive: true, pill: pill)
                                // Moved only by the crossing: the hand over
                                // the folders always says where it would go.
                                .modifier(Carried(index: 0, count: 1, step: rowHeight + SideBar.gap, vertical: true,
                                                  space: "folders",
                                                  cross: { cross(tab, $0, from: .folders) },
                                                  land: { land(tab, $0) }, faded: crossing?.tab == tab.id) { _ in })
                        }
                    }
                    .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named("column")) }) { [frames] in frames.lines[line.id] = $0 }
                }
                if let ghost, ghost.index >= lines.count, let carried = crossingTab {
                    RowGhost(tab: carried, height: rowHeight, size: prefs.sideTitle)
                        .padding(.leading, CGFloat(ghost.depth) * Folders.indent)
                        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named("column")) }) { [frames] in frames.lines[ColumnFrames.ghost] = $0 }
                }
                if let spot, spot.index >= lines.count, let carriedFolder {
                    FolderGhost(name: carriedFolder.name, height: rowHeight, size: prefs.sideTitle)
                        .padding(.leading, CGFloat(spot.depth) * Folders.indent)
                        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named("column")) }) { [frames] in frames.lines[ColumnFrames.ghost] = $0 }
                }
            }
            .coordinateSpace(name: "folders")
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named("column")) }) { [frames] in frames.folders = $0 }
            .onDisappear { [frames] in frames.folders = nil }
            .padding(.bottom, SideBar.gap)
        }
    }

    /// Where among the folders' lines the place opened for a carried folder
    /// goes, and how far in: before the folder it would go before, or at
    /// the end of the folder it would go into. None for a folded one, whose
    /// own row lights up instead.
    private func placeGhost(_ lines: [FolderLine]) -> (index: Int, depth: Int)? {
        guard let place = placing else { return nil }
        let folders = browser.folders
        if let parent = place.parent, folders.first(where: { $0.id == parent })?.folded == true { return nil }
        let siblings = (place.parent == nil ? Folders.tops(folders) : folders.filter { $0.parent == place.parent })
            .map(\.id).filter { $0 != place.folder }
        let depth = place.parent == nil ? 0 : 1
        func line(_ id: UUID) -> Int? {
            lines.firstIndex { if case .folder(let folder, _) = $0 { folder.id == id } else { false } }
        }
        if siblings.indices.contains(place.at), let at = line(siblings[place.at]) { return (at, depth) }
        guard let parent = place.parent else { return (lines.count, 0) }
        guard let head = line(parent) else { return nil }
        var end = head + 1
        while end < lines.count, lines[end].depth > 0 { end += 1 }
        return (end, 1)
    }

    /// A folder carried by its row moved: the folders show where it would
    /// go, and say so once, by touch, as they start to. True while they do.
    private func carry(_ folder: Folder, _ point: CGPoint) -> Bool {
        let at = columnPoint(point, from: .folders)
        var now: PinDrop.Place?
        if let box = frames.folders, PinDrop.zone(at, width: prefs.sideWidth - 20, gridBottom: nil, listed: nil,
                                                   folders: box.insetBy(dx: 0, dy: -rowHeight)) != .none,
           at.y >= box.minY - rowHeight, at.y < box.maxY + rowHeight {
            // Over the place already opened for it: it stays.
            if let open = frames.lines[ColumnFrames.ghost], placing?.folder == folder.id,
               at.y >= open.minY, at.y < open.maxY {
                return true
            }
            let lines = browser.folderLines.compactMap { line in frames.lines[line.id].map { (line: line, frame: $0) } }
            now = PinDrop.folderPlace(y: at.y, lines: lines, carried: folder, folders: browser.folders)
        }
        if now != placing {
            if placing == nil, now != nil {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
            withAnimation(Motion.settle) { placing = now }
        }
        return now != nil
    }

    /// A carried folder let go (nil: called off): where it was shown it
    /// would go is where it goes.
    private func place(_ folder: Folder, _ point: CGPoint?) -> Bool {
        let shown = placing?.folder == folder.id ? placing : nil
        withAnimation(Motion.settle) {
            placing = nil
            if point != nil, let shown {
                browser.placeFolder(folder.id, in: shown.parent, at: shown.at)
            }
        }
        return shown != nil && point != nil
    }

    /// The folder a carried tab would go into, while it would.
    private var crossingFolder: UUID? {
        if case .folder(let id, _)? = crossing?.target { return id }
        return nil
    }

    /// Where among the folders' lines the place opened for a carried tab
    /// goes, and how far in: among the tabs of the folder it would go into,
    /// at its place there. None for a folded one, whose own row lights up
    /// instead.
    private func folderGhost(_ lines: [FolderLine]) -> (index: Int, depth: Int)? {
        guard case .folder(let id, let at)? = crossing?.target, let carried = crossing?.tab,
              let head = lines.firstIndex(where: { if case .folder(let folder, _) = $0 { folder.id == id } else { false } }),
              case .folder(let folder, let depth) = lines[head], !folder.folded else { return nil }
        let own = lines.indices.filter { index in
            if case .tab(let tab, _, let inside) = lines[index] { inside == id && tab.id != carried } else { false }
        }
        if let at, own.indices.contains(at) { return (own[at], depth + 1) }
        return ((own.last ?? head) + 1, depth + 1)
    }

    var loose: some View {
        VStack(spacing: SideBar.gap) {
            // See the grid: the drag is measured in the column's space, not
            // the row's, so a row that has just moved keeps its bearings.
            // Worked out once, not by every row: each look walks the whole
            // row, and 300 rows asking made redrawing the column quadratic.
            let loose = looseTabs
            // Under the folders: Clear keeps them, as it keeps the pins, so
            // everything above the line is what stays.
            let kept = browser.listedPins.count + browser.folderLines.count + browser.squarePins.count
            if showsLine(kept: kept, loose: loose.count) {
                KeepLine(clears: !loose.isEmpty, newFolder: { browser.newFolder() },
                         folded: kept > 0 ? browser.pinsHidden : nil, kept: kept,
                         fold: { withAnimation(Motion.settle) { browser.togglePins() } }) { browser.clearTabs() }
            }
            // Right under the line, so it stays where the hand expects it
            // however many tabs there are below.
            newTab
            let ghost: Int? = if case .loose(let at)? = crossing?.target { at } else { nil }
            // In a stack of their own, measured, for where a pin carried
            // among them would land.
            if !loose.isEmpty || ghost != nil {
                VStack(spacing: SideBar.gap) {
                    ForEach(Array(loose.enumerated()), id: \.element.id) { index, tab in
                        let step = rowHeight + SideBar.gap
                        if ghost == index, let carried = crossingTab {
                            RowGhost(tab: carried, height: rowHeight, size: prefs.sideTitle)
                        }
                        rowItem(tab, tabs: browser.tabs, splits: browser.splits,
                                activeID: browser.shownID, interactive: true, pill: pill,
                                close: { browser.close(tab) })
                        // Positions here are among the loose rows; the pinned block
                        // sits in front of them in the real list.
                        .modifier(Carried(index: index, count: loose.count, step: step, vertical: true,
                                          space: "rows",
                                          outside: { browser.dragOut(tab) }, browser: browser, tab: tab,
                                          cross: { cross(tab, $0, from: .rows) },
                                          land: { land(tab, $0) }, faded: crossing?.tab == tab.id) {
                            browser.moveDisplayedTab(tab, to: $0 + browser.pinnedCount)
                        })
                    }
                    if let ghost, ghost >= loose.count, let carried = crossingTab {
                        RowGhost(tab: carried, height: rowHeight, size: prefs.sideTitle)
                    }
                }
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named("column")) }) { [frames] in frames.loose = $0 }
            }
        }
        .coordinateSpace(name: "rows")
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named("column")) }) { [frames] in frames.rows = $0 }
    }
}
