import SwiftUI

// The spaces, as pages to swipe between.
extension SideBar {
    /// Where the space on screen sits among them: one past the last while
    /// the card for a new one is up.
    private var spaceAt: Int {
        browser.makingSpace ? browser.spaces.count : (browser.spaces.firstIndex { $0.id == browser.spaceID } ?? 0)
    }

    var pages: some View {
        let width = prefs.sideWidth
        let swipe = browser.spaceSwipe
        let at = spaceAt
        return ZStack(alignment: .topLeading) {
            page(at, pill: pill)
                .offset(x: swipe)
            // Only while the fingers are bringing one in: the one they are
            // bringing, a page's width away.
            if swipe > 0, at > 0 {
                page(at - 1, pill: before)
                    .offset(x: swipe - width)
            }
            if swipe < 0, at < browser.spaces.count {
                page(at + 1, pill: after)
                    .offset(x: swipe + width)
            }
        }
        // The pages are the column's whole width, each with its own margin.
        .padding(.horizontal, -10)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// One space's page: the rows on screen, another space's rows as they
    /// were left, or past the last the card for a new one.
    @ViewBuilder
    private func page(_ index: Int, pill: Namespace.ID) -> some View {
        Group {
            if index == browser.spaces.count {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    NewSpaceCard(browser: browser)
                    Spacer(minLength: 0)
                    Spacer(minLength: 0)
                }
                .frame(maxHeight: .infinity)
            } else if browser.spaces[index].id == browser.spaceID {
                VStack(alignment: .leading, spacing: 0) {
                    if !browser.pinsHidden, !browser.squarePins.isEmpty || ghostSquare != nil {
                        pinned
                            .padding(.bottom, 10)
                            // A square carried down over the rows passes
                            // over them, not under.
                            .zIndex(carriedPin ? 1 : 0)
                    }
                    AgentSection(browser: browser, prefs: prefs, agent: agent)
                    // A row too long for the window scrolls between the pins
                    // and the foot, rather than running under the lights at one
                    // end and the foot at the other. While it fits it stays a
                    // plain stack, and the space under it is still the
                    // window's to be dragged by. Inside the page: the swipe
                    // between spaces moves the page, scroll and all.
                    //
                    // One or the other, from the room measured beside what
                    // the rows add up to, rather than both kept for
                    // ViewThatFits to choose between: the one it didn't show
                    // was built again on every change of layout in the one it
                    // did, every row of it each time the pointer crossed a
                    // row (Bench "hoversweep": 22 rows a crossing, not 2).
                    let needed = rowsHeight
                    Group {
                        if fits {
                            rows
                        } else {
                            ScrollViewReader { proxy in
                                // The scroll view reaches into the margin on
                                // the right and the rows keep it inside, so the
                                // system's bar lands in the margin beside them
                                // rather than over the cross on the tab under the
                                // pointer. The column's edge lies over that margin
                                // and answers first, so the bar never fights the
                                // resize; the wheel and the trackpad still scroll.
                                ScrollView(.vertical) {
                                    rows.padding(.trailing, 10)
                                }
                                .padding(.trailing, -10)
                                // The tab you go to is the tab you see — ⌘1–⌘9,
                                // ⇧⌘], a link opening beside the one on screen.
                                .onChange(of: browser.activeID) { _, id in
                                    guard let id else { return }
                                    let representative = browser.activeSplit?.left ?? id
                                    withAnimation(Motion.glide) { proxy.scrollTo(representative) }
                                }
                                // A turn of the run loop later, as the row across
                                // the top does it (TabBar.reveal): the folded
                                // column comes out mid-animation, and asked at
                                // once, before the rows had their height, the
                                // scroll could be dropped and the tab you were on
                                // left out of sight.
                                .onAppear {
                                    guard let id = browser.activeID else { return }
                                    DispatchQueue.main.async {
                                        proxy.scrollTo(browser.activeSplit?.left ?? id, anchor: .center)
                                    }
                                }
                            }
                        }
                    }
                    // The whole room under the pins, to be measured. A
                    // window changing size, or a tab opened or closed,
                    // builds nothing until the rows stop fitting or start.
                    .frame(maxHeight: .infinity, alignment: .top)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                        room.height = $0
                        refit()
                    }
                    .onChange(of: needed, initial: true) { _, needed in
                        room.needed = needed
                        refit()
                    }
                }
                // Every block measured in one space, for a tab carried
                // from one to another (see PinDrop).
                .coordinateSpace(name: "column")
                .animation(Motion.settle, value: crossing)
            } else {
                preview(browser.parked[browser.spaces[index].id] ?? Parked(tabs: [], active: nil),
                        space: browser.spaces[index].id, pill: pill)
            }
        }
        .padding(.horizontal, 10)
        .frame(width: prefs.sideWidth, alignment: .topLeading)
    }

    private func refit() {
        let now = room.needed <= room.height
        if fits != now { fits = now }
    }

    /// Another space's rows, drawn with the same pieces as this one's so the
    /// two read as one column while they pass — and nothing to press until
    /// it is the one on screen. Its folders come from the same lines as the
    /// column on screen (Folders.lines), drawn by the same view, so nothing
    /// moves as the space lands.
    private func preview(_ row: Parked, space: UUID, pill: Namespace.ID) -> some View {
        let folders = Pins.folders(space)
        let known = Set(folders.map(\.id))
        // Folded in that space as it is when it lands: the same rows, so
        // nothing moves as it comes in.
        let hidden = browser.pinsFolded.contains(space)
        let free = row.tabs.filter { $0.pin != nil && $0.folder.map(known.contains) != true }
        let pins = free.filter { !$0.listed }
        let listed = free.filter(\.listed)
        let lines = Folders.lines(folders, pins: row.tabs.filter { $0.pin != nil }, front: row.front)
        let kept = listed.count + lines.count + pins.count
        let rest = row.loose
        let cells = pinCells(pins.count)
        return VStack(alignment: .leading, spacing: 0) {
            if !pins.isEmpty, !hidden {
                VStack(spacing: 0) {
                    PinGrid(cells: cells) {
                        ForEach(Array(pins.enumerated()), id: \.element.id) { index, tab in
                            PinSquare(browser: browser, prefs: prefs, tab: tab, live: tab.id == row.active,
                                      pill: pill, width: cells[index].width, height: cells[index].height)
                        }
                    }
                }
                .padding(.bottom, 10)
            }
            // The same session in every space, so it is already in place
            // as a space comes in, not drawn when it lands.
            AgentSection(browser: browser, prefs: prefs, agent: agent)
            VStack(spacing: SideBar.gap) {
                ForEach(hidden ? [] : listed) { tab in
                    SideRow(browser: browser, prefs: prefs, tab: tab, live: tab.id == row.active,
                            pill: pill, close: {}, interactive: false)
                }
            }
            .padding(.bottom, listed.isEmpty || hidden ? 0 : SideBar.gap)
            if !lines.isEmpty, !hidden {
                VStack(spacing: SideBar.gap) {
                    ForEach(lines) { line in
                        folderLine(line, activeID: row.active, interactive: false, pill: pill)
                    }
                }
                .padding(.bottom, SideBar.gap)
            }
            VStack(spacing: SideBar.gap) {
                // Under the folders, as on screen.
                if showsLine(kept: kept, loose: rest.count) {
                    KeepLine(clears: false, folded: kept > 0 ? hidden : nil, kept: kept) {}
                }
                newTab
                ForEach(rest) { tab in
                    rowItem(tab, tabs: row.tabs, splits: row.splits, activeID: row.active,
                            interactive: false, pill: pill, close: {})
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// One of the folders' lines, here or in another space passing by: a
    /// folder's own row, or a tab in one, a step in for each folder around.
    @ViewBuilder
    func folderLine(_ line: FolderLine, activeID: Tab.ID?, interactive: Bool, pill: Namespace.ID,

                            target: Bool = false) -> some View {
        switch line {
        case .folder(let folder, let depth):
            FolderRow(browser: browser, folder: folder, height: rowHeight, size: prefs.sideTitle,
                      interactive: interactive, target: target)
                .padding(.leading, CGFloat(depth) * Folders.indent)
        case .tab(let tab, let depth, _):
            SideRow(browser: browser, prefs: prefs, tab: tab, live: tab.id == activeID, pill: pill,
                    close: interactive ? { browser.close(tab) } : {}, interactive: interactive)
                .padding(.leading, CGFloat(depth) * Folders.indent)
        }
    }

    /// Where the rows stop and the window's own drag area starts. Added up
    /// from what was drawn rather than measured: a measurement would arrive a
    /// frame late, and for one frame the whole column would drag the window.
    var rowsEnd: CGFloat {
        let pins = browser.pinsHidden ? 0 : browser.squarePins.count
        let pinBlock = pins == 0 ? 0 : (pinCells(pins).map(\.maxY).max() ?? 0) + 10
        return Metrics.strip + pinBlock + AgentSection.height(agent, row: rowHeight) + rowsHeight
    }

    /// The pinned rows, the loose tabs and the row that makes another, added
    /// up the same way, with a few points to spare: what decides whether
    /// they scroll.
    private var rowsHeight: CGFloat {
        let kept = browser.listedPins.count
        let listed = browser.pinsHidden ? 0 : kept
        // A folder's own line is as tall as a tab's.
        let keptLines = browser.folderLines.count
        let lines = browser.pinsHidden ? 0 : keptLines
        let rows = looseTabs
        let listBlock = CGFloat(listed) * (rowHeight + SideBar.gap) + (listed > 0 ? SideBar.gap : 0)
            + CGFloat(lines) * (rowHeight + SideBar.gap) + (lines > 0 ? SideBar.gap : 0)
            + (showsLine(kept: kept + keptLines + browser.squarePins.count, loose: rows.count) ? KeepLine.height + SideBar.gap : 0)
        // A pair is two lines (see SplitTabItem).
        let pairs = rows.filter { browser.split(for: $0) != nil }.count
        let loose = CGFloat(rows.count) * (rowHeight + SideBar.gap) + CGFloat(pairs) * rowHeight
        return listBlock + loose + rowHeight + 8
    }

    @ViewBuilder
    func rowItem(

        _ tab: Tab,

        tabs: [Tab],

        splits: [TabSplit],

        activeID: Tab.ID?,

        interactive: Bool,

        pill: Namespace.ID,

        close: @escaping () -> Void
    ) -> some View {
        let pair = splits.first(where: { $0.left == tab.id })
        if let pair, let right = tabs.first(where: { $0.id == pair.right }) {
            SplitTabItem(browser: browser, prefs: prefs, left: tab, right: right,
                         width: nil, height: rowHeight,
                         live: activeID.map { pair.contains($0) } ?? false,
                         focusedID: activeID,
                         interactive: interactive, pill: pill)
                .frame(maxWidth: .infinity)
        } else {
            SideRow(browser: browser, prefs: prefs, tab: tab,
                    live: tab.id == activeID, pill: pill, close: close,
                    interactive: interactive)
        }
    }
}
