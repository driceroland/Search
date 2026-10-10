import SwiftUI

/// The tabs, down either side instead of across the top.
///
/// The same pieces as the strip — the grey that slides to the tab you picked,
/// the pinned squares, the cross that appears under the pointer — laid out the
/// other way. The traffic lights keep their corner; the column starts under
/// them and the page takes the whole height beside it.
struct SideBar: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences

    @Namespace private var pill

    @State private var landing = false
    /// The width the column had when the edge was picked up.
    @State private var grabbed: CGFloat?
    @State private var onEdge = false

    /// A pin, picked up out of the grid — a separate state from the loose
    /// rows above, since the two gestures never happen at once but move on
    /// two different axes.
    /// The neighbouring spaces' own grey, apart from this one's.
    @Namespace private var before
    @Namespace private var after

    @State private var groupFrames: [UUID: CGRect] = [:]

    private static let row: CGFloat = 28
    private static let gap: CGFloat = 2
    private static let square: CGFloat = 34
    private static let pinGap: CGFloat = 4

    private var onRight: Bool { prefs.sidePosition == .right }
    private var innerEdge: Alignment { onRight ? .leading : .trailing }

    /// The window's buttons' corner: gone in full screen, where macOS takes
    /// them away, and back, forward and reload move up to the edge (idea 184).
    private var lights: CGFloat { browser.fullScreen ? 0 : Metrics.sideLights }

    var body: some View {
        ZStack(alignment: .top) {
            // Not under the card for a new space: it isn't made of views that
            // would take the click first.
            DragStrip(reserved: 0, below: browser.makingSpace ? .greatestFiniteMagnitude : rowsEnd, onDoubleClick: browser.newTab)

            // The band the lights sit in is this mode's title bar: the window
            // is dragged by it and a double-click fills the screen with it,
            // everywhere but over the three doors, which take their own
            // clicks. The lights are the title bar's own and answer first.
            HStack(spacing: 0) {
                DragStrip()
                    .frame(width: 10 + lights)
                Color.clear
                    .frame(width: Metrics.helm)
                    .allowsHitTesting(false)
                DragStrip()
            }
            .frame(height: Metrics.strip)

            VStack(alignment: .leading, spacing: 0) {
                // The traffic lights' corner, with back, forward and reload
                // sitting right of them — the same three doors as the top
                // bar, moved beside the lights since there's no far end of a
                // row to put them at in this mode.
                HStack(spacing: 0) {
                    Color.clear.frame(width: lights)
                    Helm(browser: browser)
                    Spacer(minLength: 0)
                }
                .frame(height: Metrics.strip)

                // The spaces side by side, as pages: two fingers sideways move
                // the one on screen and the next one together, the next one
                // coming in as this one goes, with nothing between them.
                pages

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            // Clear of the foot, which sits over the column's bottom edge.
            .padding(.bottom, SideBar.footHeight)

            VStack {
                Spacer()
                foot
            }
        }
        .frame(width: prefs.sideWidth)
        .frame(maxHeight: .infinity)
        // Rows on their way to or from another space stay in the column.
        .clipped()
        .onAppear { SpaceSwipe.shared.start(for: browser) }
        .background {
            ZStack {
                landing ? Palette.hover : Palette.ground
                if prefs.splitView {
                    SplitDropZone(browser: browser, tab: nil, kind: .strip)
                }
            }
        }
        .overlay(alignment: innerEdge) {
            Rectangle().fill(Palette.hairline).frame(width: 1)
        }
        .overlay(alignment: innerEdge) { edge }
        .onDrop(of: [.url, .text], isTargeted: $landing) { providers in
            browser.take(providers)
        }
        .animation(Motion.quick, value: landing)
        .animation(Motion.glide, value: browser.activeID)
        .animation(Motion.glide, value: browser.editingTab)
        .animation(Motion.settle, value: browser.tabs.map(\.id))
        .animation(Motion.settle, value: browser.pinnedCount)
        // The last square made the first row changes nothing in the row's
        // order; only how many of each there are.
        .animation(Motion.settle, value: browser.listedPins.count)
    }

    /// The column's edge: pull it to make the column wider or narrower,
    /// double-click it to put it back. The hairline darkens under the pointer
    /// so the edge says it can be taken before it is.
    private var edge: some View {
        Rectangle()
            .fill(Palette.ink.opacity(onEdge || grabbed != nil ? 0.18 : 0))
            .frame(width: onEdge || grabbed != nil ? 2 : 1)
            .frame(width: 9)
            .contentShape(Rectangle())
            .onHover { over in
                onEdge = over
                if over { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        if grabbed == nil { grabbed = prefs.sideWidth }
                        let delta = onRight ? -value.translation.width : value.translation.width
                        let wanted = (grabbed ?? prefs.sideWidth) + delta
                        prefs.sideWidth = min(Metrics.sideMax, max(Metrics.sideMin, wanted))
                    }
                    .onEnded { _ in grabbed = nil }
            )
            .modifier(OneClick(double: true) {
                withAnimation(Motion.settle) { prefs.sideWidth = Metrics.side }
            })
            .animation(Motion.quick, value: onEdge)
    }

    // MARK: - the spaces, as pages

    /// Where the space on screen sits among them: one past the last while
    /// the card for a new one is up.
    private var spaceAt: Int {
        browser.makingSpace ? browser.spaces.count : (browser.spaces.firstIndex { $0.id == browser.spaceID } ?? 0)
    }

    private var pages: some View {
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
                    if browser.pinnedCount > 0 {
                        pinned
                            .padding(.bottom, 10)
                    }
                    // A row too long for the window scrolls between the pins
                    // and the foot, rather than running under the lights at one
                    // end and the foot at the other. While it fits it stays a
                    // plain stack, and the space under it is still the
                    // window's to be dragged by. Inside the page: the swipe
                    // between spaces moves the page, scroll and all.
                    ViewThatFits(in: .vertical) {
                        rows
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
                            .onAppear {
                                if let id = browser.activeID {
                                    proxy.scrollTo(browser.activeSplit?.left ?? id, anchor: .center)
                                }
                            }
                        }
                    }
                }
            } else {
                preview(browser.parked[browser.spaces[index].id] ?? Parked(tabs: [], active: nil), pill: pill)
            }
        }
        .padding(.horizontal, 10)
        .frame(width: prefs.sideWidth, alignment: .topLeading)
    }

    /// Another space's rows, drawn with the same pieces as this one's so the
    /// two read as one column while they pass — and nothing to press until
    /// it is the one on screen.
    private func preview(_ row: Parked, pill: Namespace.ID) -> some View {
        let pins = row.tabs.filter { $0.pin != nil && !($0.listed && prefs.showsPinRows) }
        let listed = prefs.showsPinRows ? row.tabs.filter { $0.pin != nil && $0.listed } : []
        let rest = row.tabs.filter { tab in
            tab.pin == nil && (!prefs.splitView || !row.splits.contains(where: { $0.right == tab.id }))
        }
        let cells = pinCells(pins.count)
        return VStack(alignment: .leading, spacing: 0) {
            if !pins.isEmpty {
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
            VStack(spacing: SideBar.gap) {
                ForEach(listed) { tab in
                    SideRow(browser: browser, prefs: prefs, tab: tab, live: tab.id == row.active,
                            pill: pill, close: {}, interactive: false)
                }
                // Groups aren't drawn here, so the line goes over all the rest.
                if showsLine(listed: listed.count, loose: rest.count) {
                    KeepLine(clears: false) {}
                }
                ForEach(rest) { tab in
                    rowItem(tab, tabs: row.tabs, splits: row.splits, activeID: row.active,
                            interactive: false, pill: pill, close: {})
                }
            }
            newTab
        }
        .allowsHitTesting(false)
    }

    /// Where the rows stop and the window's own drag area starts. Added up
    /// from what was drawn rather than measured: a measurement would arrive a
    /// frame late, and for one frame the whole column would drag the window.
    private var rowsEnd: CGFloat {
        let displayed = browser.displayedTabs
        let pins = browser.squarePins.count
        let pinBlock = pins == 0 ? 0 : (pinCells(pins).map(\.maxY).max() ?? 0) + 10
        let listed = browser.listedPins.count
        let ungrouped = displayed.filter { $0.pin == nil && (!prefs.usesTabGroups || browser.group(of: $0) == nil) }.count
        let listBlock = CGFloat(listed) * (SideBar.row + SideBar.gap) + (listed > 0 ? SideBar.gap : 0)
            + (showsLine(listed: listed, loose: ungrouped) ? KeepLine.height + SideBar.gap : 0)
        let rows = prefs.usesTabGroups
            ? displayed.filter { $0.pin == nil && browser.group(of: $0) == nil }
                + browser.tabGroups.flatMap { browser.visibleTabs(in: $0) }
            : displayed.filter { $0.pin == nil }
        // A pair is two lines (see SplitTabItem).
        let pairs = rows.filter { browser.split(for: $0) != nil }.count
        let headings = prefs.usesTabGroups ? CGFloat(browser.tabGroups.count) * (GroupHeading.height + SideBar.gap) : 0
        let loose = CGFloat(rows.count) * (SideBar.row + SideBar.gap) + CGFloat(pairs) * SideBar.row + headings
        return Metrics.strip + pinBlock + listBlock + loose + SideBar.row + 8
    }

    @ViewBuilder
    private func rowItem(
        _ tab: Tab,
        tabs: [Tab],
        splits: [TabSplit],
        activeID: Tab.ID?,
        interactive: Bool,
        pill: Namespace.ID,
        close: @escaping () -> Void
    ) -> some View {
        let pair = prefs.splitView ? splits.first(where: { $0.left == tab.id }) : nil
        if let pair, let right = tabs.first(where: { $0.id == pair.right }) {
            SplitTabItem(browser: browser, prefs: prefs, left: tab, right: right,
                         width: nil, height: SideBar.row,
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

    // MARK: - the pinned squares

    private var pinnedTabs: [Tab] { browser.squarePins }
    private var looseTabs: [Tab] {
        browser.displayedTabs.filter { $0.pin == nil && (!prefs.usesTabGroups || browser.group(of: $0) == nil) }
    }

    /// The line between what is kept and what comes and goes, with the
    /// pinned rows on: over the tabs Clear would close, or under rows with
    /// nothing below them yet. Not with the rows off, nor with nothing on
    /// either side of it.
    private func showsLine(listed: Int, loose: Int) -> Bool {
        prefs.showsPinRows && listed + loose > 0
    }

    /// How many squares go in each row: at most four — fewer only when the
    /// column is too narrow for four of the classic width — and as even as
    /// they go, the fuller rows first. Five are three and two, seven four
    /// and three, nine three, three and three, ten four, three and three.
    /// Up to three stay the one row of three places they always were, with
    /// a place or two empty rather than a lonely button the column's width.
    static func pinRows(_ count: Int, most: Int) -> [Int] {
        guard count > 0 else { return [] }
        let most = max(1, most)
        let rows = (count + most - 1) / most
        let base = count / rows
        let extra = count % rows
        return (0..<rows).map { $0 < extra ? base + 1 : base }
    }

    /// Where each square goes, in the order of the row. Each row splits the
    /// column's width between its own squares — the row fills edge to edge,
    /// not each cell on its own — and every row is as tall as the narrowest
    /// cell allows, never taller than the classic square: past that a cell
    /// turns into a wide, short button rather than a bigger icon.
    private func pinCells(_ count: Int) -> [CGRect] {
        let room = prefs.sideWidth - 20
        let gap = SideBar.pinGap
        let fits = Int((room + gap) / (SideBar.square + gap))
        let rows = SideBar.pinRows(count, most: min(4, max(1, fits)))
        // A row of fewer than three keeps three places.
        let slots = rows.map { rows.count == 1 ? max($0, min(3, fits)) : $0 }
        let widths = slots.map { max(20, (room - CGFloat($0 - 1) * gap) / CGFloat($0)) }
        let height = min(SideBar.square, widths.min() ?? SideBar.square)
        var cells: [CGRect] = []
        for (row, n) in rows.enumerated() {
            for col in 0..<n {
                cells.append(CGRect(x: CGFloat(col) * (widths[row] + gap),
                                    y: CGFloat(row) * (height + gap),
                                    width: widths[row], height: height))
            }
        }
        return cells
    }

    /// The grid itself: fixed-size cells, left-aligned, so a half-empty last
    /// row holds its ground rather than stretching to fill it.
    private var pinned: some View {
        let tabs = pinnedTabs
        let cells = pinCells(tabs.count)
        // Measured in the grid's own space, not the square's: a square that
        // has just been moved to a new cell would otherwise report the drag
        // from where it now is, the target would jump back, and the square
        // would shuttle between two cells for as long as the finger stayed.
        return VStack(spacing: 0) { PinGrid(cells: cells) {
            ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                PinSquare(
                    browser: browser,
                    prefs: prefs,
                    tab: tab,
                    live: tab.id == browser.activeID,
                    pill: pill,
                    width: cells[index].width,
                    height: cells[index].height
                )
                // The hand's travel is the square's own, as a row's is
                // (Carried): a move redraws the one square being carried,
                // not the column (idea 31).
                .modifier(PinCarried(index: index, cells: cells) { browser.move(tab, to: $0) })
            }
        } }
        .coordinateSpace(name: "pins")
    }

    // MARK: - the rows

    /// The pins kept as rows, under the squares: Arc's pinned list. Each is
    /// a row like any other to look at, carried only among its own kind.
    private var listed: some View {
        let pins = browser.listedPins
        let squares = browser.squarePins.count
        return VStack(spacing: SideBar.gap) {
            ForEach(Array(pins.enumerated()), id: \.element.id) { index, tab in
                SideRow(browser: browser, prefs: prefs, tab: tab,
                        live: tab.id == browser.activeID, pill: pill,
                        close: { browser.close(tab) })
                    .modifier(Carried(index: index, count: pins.count,
                                      step: SideBar.row + SideBar.gap, vertical: true,
                                      space: "listed") {
                        browser.moveDisplayedTab(tab, to: $0 + squares)
                    })
            }
        }
        .coordinateSpace(name: "listed")
        .padding(.bottom, pins.isEmpty ? 0 : SideBar.gap)
    }

    private var loose: some View {
        VStack(spacing: SideBar.gap) {
            if prefs.usesTabGroups {
                ForEach(browser.tabGroups) { group in
                    GroupHeading(browser: browser, group: group, dragSpace: "rows")
                    groupRows(group)
                }
            }
            // See the grid: the drag is measured in the column's space, not
            // the row's, so a row that has just moved keeps its bearings.
            // Worked out once, not by every row: each look walks the whole
            // row, and 300 rows asking made redrawing the column quadratic.
            let loose = looseTabs
            // Under the groups: Clear keeps them, as it keeps the pins, so
            // everything above the line is what stays.
            if showsLine(listed: browser.listedPins.count, loose: loose.count) {
                KeepLine(clears: !loose.isEmpty) { browser.clearTabs() }
            }
            ForEach(Array(loose.enumerated()), id: \.element.id) { index, tab in
                let step = SideBar.row + SideBar.gap
                rowItem(tab, tabs: browser.tabs, splits: browser.splits,
                        activeID: browser.activeID, interactive: true, pill: pill,
                        close: { browser.close(tab) })
                // Positions here are among the loose rows; the pinned block
                // sits in front of them in the real list.
                .modifier(Carried(index: index, count: loose.count, step: step, vertical: true,
                                  space: "rows", onDropTab: { source, point in drop(source, at: point) },
                                  outside: { browser.dragOut(tab) }, browser: browser, tab: tab) {
                    if prefs.usesTabGroups {
                        browser.move(tab, within: nil, to: $0)
                    } else {
                        browser.moveDisplayedTab(tab, to: $0 + browser.pinnedCount)
                    }
                })
            }
        }
        .coordinateSpace(name: "rows")
        .onPreferenceChange(GroupDropFrames.self) { groupFrames = $0 }
    }

    private func drop(_ tab: Tab, at point: CGPoint) {
        guard prefs.usesTabGroups, tab.pin == nil else { return }
        if let id = groupFrames.first(where: { $0.value.contains(point) })?.key {
            browser.move(tab, toGroup: id)
        }
    }

    private func groupRows(_ group: TabGroup) -> some View {
        let members = browser.visibleTabs(in: group)
        return VStack(spacing: SideBar.gap) {
            ForEach(Array(members.enumerated()), id: \.element.id) { index, tab in
                rowItem(tab, tabs: browser.tabs, splits: browser.splits,
                        activeID: browser.activeID, interactive: true, pill: pill,
                        close: { browser.close(tab) })
                    .padding(.leading, 14)
                    .modifier(Carried(index: index, count: members.count,
                                      step: SideBar.row + SideBar.gap, vertical: true,
                                      space: "rows", onDropTab: { source, point in drop(source, at: point) },
                                      outside: { browser.dragOut(tab) }, browser: browser, tab: tab) {
                        browser.move(tab, within: group.id, to: $0)
                    })
            }
        }
    }

    /// The pinned rows, the loose tabs and the row that makes another,
    /// which scroll as one.
    private var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            listed
            loose
            newTab
        }
    }

    /// The foot's door and its margin beneath.
    private static let footHeight: CGFloat = 26 + 10

    private var newTab: some View {
        Quiet(icon: "plus", title: "New tab", height: SideBar.row) { browser.newTab() }
            .padding(.top, SideBar.gap)
    }

    /// One small door at the bottom: the settings.
    private var foot: some View {
        SideFoot(browser: browser, prefs: prefs, fetches: browser.fetches)
    }

}

/// The row at the bottom of the column. Never wider than the column: wider,
/// the column took its width, and centred in its own frame it slid half the
/// overflow off each side (#535). The space's door, the puzzle, bookmarks and
/// downloads stay put; the pinned extensions that don't fit give way, from
/// the last, and are still in the puzzle's list.
private struct SideFoot: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    @ObservedObject var fetches: Fetches

    var body: some View {
        HStack(spacing: 2) {
            if prefs.usesSpaces { SpaceDot(browser: browser) }
            ExtensionSlot(edge: .trailing, room: room)
            BookmarkDoor(browser: browser, arrowEdge: .trailing)
            // Only while a download is running, and a moment after.
            FetchDoor(browser: browser, fetches: fetches)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
    }

    /// How many pinned extensions fit beside the doors that stay. Every door
    /// is 26 points, with 2 between them.
    private var room: Int {
        let door: CGFloat = 26 + 2
        var kept = 2  // the puzzle and bookmarks
        if prefs.usesSpaces { kept += 1 }
        if FetchDoor.shows(fetches, prefs) { kept += 1 }
        let free = prefs.sideWidth - 2 * 10 + 2 - CGFloat(kept) * door
        return max(0, Int((free / door).rounded(.down)))
    }
}

/// The pinned squares' grid, every cell laid out at once. A lazy grid makes
/// its cells only once the column is on screen, where the column's slide
/// can't take them along: folded with ⌘S and brought back, the squares stood
/// in place while the column came in beneath them. A dozen squares need no
/// laziness.
private struct PinGrid: Layout {
    /// Each square's place, worked out by the column (see pinCells).
    let cells: [CGRect]

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: cells.map(\.maxX).max() ?? 0, height: cells.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (index, subview) in subviews.enumerated() where cells.indices.contains(index) {
            let cell = cells[index]
            subview.place(
                at: CGPoint(x: bounds.minX + cell.minX, y: bounds.minY + cell.minY),
                proposal: ProposedViewSize(width: cell.width, height: cell.height)
            )
        }
    }
}

/// A pinned tab as a cell in the block at the top of the column — as wide as
/// its row asks for, but never taller than the classic square, so a row with
/// room to spare turns into a wide, short button rather than a bigger icon.
private struct PinSquare: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    @ObservedObject var tab: Tab
    let live: Bool
    let pill: Namespace.ID
    var width: CGFloat = 34
    var height: CGFloat = 34

    @State private var hovering = false

    /// Everything drawn inside scales off the shorter edge — the one that
    /// stays put — so the glyph sits at its usual size, centred, rather than
    /// stretching to chase the width.
    private var scale: CGFloat { min(width, height) }

    var body: some View {
        Group {
            if browser.editingPin == tab.id {
                PinField(browser: browser, tab: tab)
            } else if tab.loading {
                // Its page on the way, as a row's ring says.
                Ring(size: scale * 11 / 34)
            } else if prefs.glyph == .icons, let icon = tab.icon {
                Mark(icon: icon, letter: tab.pin ?? "", size: scale * 16 / 34, dim: tab.asleep)
            } else {
                Text(tab.pin ?? "")
                    .font(.system(size: scale * 12 / 34, weight: .medium))
                    .foregroundStyle((live ? Palette.ink : Palette.muted).opacity(tab.asleep ? 0.45 : 1))
            }
        }
        .frame(width: scale * 16 / 34, height: scale * 16 / 34)
        .frame(width: width, height: height)
        .background {
            if live {
                // Darker than the resting squares' grey by as much as a live
                // row is darker than the white it sits on (Drice: the live
                // pin barely showed among the others).
                RoundedRectangle(cornerRadius: scale * 9 / 34, style: .continuous)
                    .fill(Palette.pinLive)
                    .matchedGeometryEffect(id: "live", in: pill)
            } else {
                RoundedRectangle(cornerRadius: scale * 9 / 34, style: .continuous)
                    .fill(browser.selectedTabIDs.contains(tab.id) ? Palette.wash :
                          hovering ? Palette.hover : Palette.wash.opacity(0.55))
            }
        }
        .overlay {
            if browser.selectedTabIDs.contains(tab.id) {
                RoundedRectangle(cornerRadius: scale * 9 / 34, style: .continuous)
                    .strokeBorder(Palette.ink.opacity(0.35), lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: scale * 9 / 34, style: .continuous))
        .modifier(OneClick(double: live) {
            guard NSEvent.modifierFlags.intersection([.command, .shift]).isEmpty else { return }
            browser.clearTabSelection()
            if live { browser.goHome(tab) } else { browser.select(tab) }
        })
        .modifier(ModifiedTabClick { browser.extendTabSelection(to: tab, modifiers: $0) })
        // Put down, like ⌘W: close() is what knows a pin isn't removed.
        .overlay { MiddleClick { browser.close(tab) } }
        .onHover { hovering = $0 }
        .contextMenu { TabMenu(browser: browser, tab: tab, close: { browser.close(tab) }) }
        .help(tab.label)
        .animation(Motion.quick, value: hovering)
        .transition(.scale(scale: 0.8).combined(with: .opacity))
    }
}

/// One tab, as a line in the column.
private struct SideRow: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    @ObservedObject var tab: Tab
    let live: Bool
    let pill: Namespace.ID
    let close: () -> Void
    var interactive = true

    @State private var hovering = false
    @State private var shake: CGFloat = 0

    private var editing: Bool { browser.editingTab == tab.id }

    /// The ring or the speaker, which stay for as long as the page loads or
    /// plays (or is muted) and so keep a place of their own at the end of the
    /// row. The cross is only there under the pointer, and takes none.
    private var status: Bool { !editing && (tab.loading || speaker) }
    /// The speaker, which can be pressed, and so steps in beside the cross
    /// under the pointer rather than hiding beneath it as the ring does.
    private var speaker: Bool { !tab.loading && (tab.noisy || tab.muted) }

    var body: some View {
        HStack(spacing: 8) {
            if editing {
                TabAddressField(browser: browser)
                    .frame(height: 16)
            } else {
                if prefs.glyph == .icons, !tab.isBlank {
                    Mark(icon: tab.icon, letter: tab.monogram, size: 15)
                }
                if tab.bench {
                    // A script's tab, not yours.
                    Image(systemName: "flask")
                        .font(.system(size: 9))
                        .foregroundStyle(colour.opacity(0.7))
                }
                if tab.shy {
                    Image(systemName: "eye.slash")
                        .font(.system(size: 9))
                        .foregroundStyle(colour.opacity(0.7))
                }
                if tab.recording {
                    // An extension recording from this page (RecordingIndicator).
                    Image(systemName: "record.circle")
                        .font(.system(size: 10))
                        .foregroundStyle(colour.opacity(0.8))
                        .help("Recording")
                }
                Text(tab.label)
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(colour)
            }

            if status {
                Spacer(minLength: 2)

                ZStack {
                    if tab.loading {
                        Ring().transition(.opacity)
                    } else {
                        Speaker(tab: tab).transition(.opacity)
                    }
                }
                .frame(width: 15, height: 15)
                // The cross takes this place while the pointer is here; the
                // speaker moves one place in, clear of the cross's reach.
                .opacity(hovering && !speaker ? 0 : 1)
                .padding(.trailing, hovering && speaker ? 23 : 0)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, status ? 7 : 10)
        .frame(height: 28)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The title keeps its length under the pointer and fades out
        // beneath the cross, rather than being cut shorter, so its end
        // doesn't jump on each row the pointer passes.
        .mask {
            ZStack {
                Rectangle().opacity(hovering && !editing && !status ? 0 : 1)
                HStack(spacing: 0) {
                    Rectangle()
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: 16)
                    Color.clear.frame(width: 26)
                }
            }
        }
        .overlay(alignment: .trailing) {
            if !editing {
                ZStack {
                    if hovering {
                        // A pinned row is put down, not closed (see
                        // Browser.close), and says so, as Arc's does.
                        Image(systemName: tab.pin != nil ? "minus" : "xmark")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(Palette.muted)
                            .frame(width: 15, height: 15)
                            .background(Palette.ink.opacity(0.07), in: Circle())
                            .transition(.opacity)
                    }
                }
                .frame(width: 15, height: 15)
                .overlay {
                    Color.clear
                        .frame(width: 30, height: 28)
                        .contentShape(Rectangle())
                        .onTapGesture { if hovering { close() } }
                }
                .padding(.trailing, 7)
            }
        }
        .animation(Motion.quick, value: tab.loading)
        .animation(Motion.quick, value: speaker)
        .background { ground }
        .overlay {
            if browser.selectedTabIDs.contains(tab.id) {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Palette.ink.opacity(0.35), lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
        .modifier(Shake(travel: shake))
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .modifier(OneClick(double: false) {
            guard interactive, NSEvent.modifierFlags.intersection([.command, .shift]).isEmpty else { return }
            browser.clearTabSelection()
            if live { browser.beginTabEdit(tab) } else { browser.select(tab) }
        })
        .modifier(ModifiedTabClick { if interactive && !editing { browser.extendTabSelection(to: tab, modifiers: $0) } })
        .overlay { if interactive { MiddleClick(act: close) } }
        .onHover { hovering = $0 }
        .contextMenu { if interactive { TabMenu(browser: browser, tab: tab, close: close) } }
        .background {
            if interactive && prefs.splitView {
                SplitDropZone(browser: browser, tab: tab, kind: .strip)
            }
        }
        .animation(Motion.quick, value: hovering)
        .animation(Motion.glide, value: editing)
        .onChange(of: browser.refusals) { _, _ in
            guard editing else { return }
            shake = 0
            withAnimation(.easeOut(duration: 0.5)) { shake = 1 }
        }
        .transition(.scale(scale: 0.94, anchor: .leading).combined(with: .opacity))
    }

    @ViewBuilder
    private var ground: some View {
        if live {
            ZStack(alignment: .leading) {
                Rectangle().fill(Palette.wash)
                if prefs.showsReading {
                    GeometryReader { geo in
                        ReadingFill(meter: tab.meter, width: geo.size.width)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .matchedGeometryEffect(id: "live", in: pill)
        } else if browser.selectedTabIDs.contains(tab.id) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Palette.wash)
        } else if hovering {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Palette.hover)
        }
    }

    private var colour: Color {
        if live { return Palette.ink }
        return hovering ? Palette.ink.opacity(0.7) : Palette.muted
    }
}

/// A row that is an action rather than a page. Quiet until the pointer is on it.
struct Quiet: View {
    let icon: String
    let title: String
    var height: CGFloat = 28
    let act: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: act) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .medium))
                    .frame(width: 15)
                Text(title)
                    .font(.system(size: 12.5))
                Spacer(minLength: 0)
            }
            .foregroundStyle(hovering ? Palette.ink.opacity(0.7) : Palette.faint)
            .padding(.leading, 10)
            .frame(height: height)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(hovering ? Palette.hover : .clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
    }
}

/// The line between what is kept and the tabs that come and go, as Arc
/// draws it over its Today tabs, with Clear at its end under the pointer:
/// the tabs below it closed, everything above it left as it was.
struct KeepLine: View {
    static let height: CGFloat = 18
    /// Whether there is anything under it to clear.
    let clears: Bool
    let act: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Rectangle()
                .fill(Palette.hairline)
                .frame(height: 1)
            if clears && hovering {
                Button(action: act) {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 8, weight: .semibold))
                        Text("Clear")
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(Palette.muted)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close the tabs under the line. Pins and groups stay; ⇧⌘T brings them all back.")
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: KeepLine.height)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
    }
}

/// The speaker at the end of a tab that plays sound, or that was muted and
/// so says it is: a press mutes the tab or lets it be heard again. Drawn as
/// it was before it could be pressed, with the cross's faint disc behind
/// it only while the pointer is on it.
struct Speaker: View {
    @ObservedObject var tab: Tab

    @State private var hovering = false

    var body: some View {
        Button(action: tab.toggleMute) {
            Image(systemName: tab.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 8))
                .foregroundStyle(Palette.muted)
                .frame(width: 15, height: 15)
                .background(Palette.ink.opacity(hovering ? 0.07 : 0), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(tab.muted ? "Unmute Tab" : "Mute Tab")
        .animation(Motion.quick, value: hovering)
    }
}

/// A small square holding one symbol. Lit when what it opens is open.
struct Door: View {
    let icon: String
    var on = false
    var help = ""
    let act: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: act) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(on ? Palette.ink : (hovering ? Palette.ink.opacity(0.7) : Palette.muted))
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(on ? Palette.wash : (hovering ? Palette.hover : .clear))
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .animation(Motion.quick, value: hovering)
        .animation(Motion.quick, value: on)
    }
}

/// A pinned square picked up and carried across the grid, its travel its
/// own: only the square being carried redraws as the hand moves, and the
/// grid only when it changes place.
struct PinCarried: ViewModifier {
    let index: Int
    let cells: [CGRect]
    let move: (Int) -> Void

    @State private var held = false
    @State private var from = 0
    @State private var travel: CGSize = .zero

    func body(content: Content) -> some View {
        content
            .offset(held ? PinCarried.offset(travel: travel, from: from, index: index, cells: cells) : .zero)
            // Under the hand exactly, as a row is (see Carried).
            .transaction { if held { $0.animation = nil } }
            .zIndex(held ? 1 : 0)
            .shadow(color: .black.opacity(held ? 0.16 : 0), radius: 10, y: 3)
            // Measured in the grid's own space, not the square's: a square
            // that has just been moved to a new cell would otherwise report
            // the drag from where it now is, and shuttle between two cells.
            .gesture(
                DragGesture(minimumDistance: 5, coordinateSpace: .named("pins"))
                    .onChanged { value in
                        if !held {
                            held = true
                            from = index
                        }
                        travel = value.translation
                        let target = PinCarried.target(travel: travel, from: from, cells: cells)
                        if target != index {
                            withAnimation(Motion.settle) { move(target) }
                        }
                    }
                    .onEnded { _ in
                        withAnimation(Motion.settle) {
                            held = false
                            travel = .zero
                        }
                    }
            )
    }

    /// The held square stays glued to the fingers; every other square is
    /// already where it belongs, because the move put it there. This only
    /// takes off what the held square got for free by changing cell under
    /// its own drag.
    static func offset(travel: CGSize, from: Int, index: Int, cells: [CGRect]) -> CGSize {
        guard cells.indices.contains(from), cells.indices.contains(index) else { return .zero }
        let start = cells[from], now = cells[index]
        return CGSize(width: travel.width - (now.midX - start.midX), height: travel.height - (now.midY - start.midY))
    }

    /// The cell the held square is over: the one whose centre is nearest to
    /// where the fingers have taken the square's own centre. Rows of
    /// different lengths have cells of different widths, so a count of
    /// steps along one axis would land in the wrong one.
    static func target(travel: CGSize, from: Int, cells: [CGRect]) -> Int {
        guard cells.indices.contains(from) else { return 0 }
        let start = cells[from]
        let point = CGPoint(x: start.midX + travel.width, y: start.midY + travel.height)
        func distance(_ cell: CGRect) -> CGFloat { hypot(cell.midX - point.x, cell.midY - point.y) }
        return cells.indices.min { distance(cells[$0]) < distance(cells[$1]) } ?? from
    }
}
