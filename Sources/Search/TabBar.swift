import SwiftUI

/// The only chrome there is. Titles, one of them in a grey pill, and the pill
/// slides from the tab you left to the tab you picked rather than blinking out
/// of one and into the other.
struct TabBar: View {
    /// The room kept at the start for the window's buttons: none to speak of
    /// in full screen, where macOS takes them away (idea 184).
    private var lights: CGFloat { browser.fullScreen ? 12 : Metrics.lights }

    @ObservedObject var browser: Browser

    @Namespace private var pill
    /// The neighbouring spaces' own grey, apart from this one's.
    @Namespace private var above
    @Namespace private var below

    /// Which tab is under the hand, where it started, and how far it has come.
    @State private var landing = false
    @State private var groupFrames: [UUID: CGRect] = [:]
    /// The plus only comes out when the pointer is in the row.
    @State private var nearby = false
    @State private var plussed = false
    /// The helm's width when it stands before the tabs rather than after them.
    private var leading: CGFloat { browser.prefs.navigationLeft ? Metrics.helm - 8 + Metrics.tabGap : 0 }
    /// How wide the doors at the far end are, extension buttons included.
    @State private var doors: CGFloat = 0
    /// The tab being carried along the row, if one is (see Carried).
    @State private var carry: Carry?

    /// What the run of tabs stretches or shrinks by while a tab is on the
    /// move, so the plus after the tabs keeps its place after them: the
    /// last tab carried past the run's end takes the run with it — only a
    /// tab of the run at the far end can be, and only past the end; a tab
    /// carried out of the row leaves its place to close; a tab arriving
    /// from another window has a place made for it (see Carried).
    private func stretch(in strip: CGFloat) -> CGFloat {
        if browser.arrival != nil { return width(in: strip) + Metrics.tabGap }
        guard let carry else { return 0 }
        if carry.out { return -carry.step }
        let last: Int
        if browser.prefs.usesTabGroups {
            guard carry.run == "loose" else { return 0 }
            last = browser.tabs(in: nil).count - 1
        } else {
            guard browser.tabs.indices.contains(carry.from), browser.tabs[carry.from].pin == nil else { return 0 }
            last = browser.tabs.count - 1
        }
        return max(0, carry.travel - CGFloat(last - carry.from) * carry.step)
    }

    /// The plus is out while the pointer is up here — and while a tab is
    /// being carried, since a drag ends the hovering the pointer was doing,
    /// or arriving from another window.
    private var plusUp: Bool { nearby || carry != nil || browser.arrival != nil }

    /// A tab from another window, held over this row: drawn as a pill under
    /// the hand, over the row, while the tabs make way for it (see Tear).
    @ViewBuilder
    private func arriving(in strip: CGFloat) -> some View {
        if browser.arrival != nil, let hand = browser.arrivalHand, let tab = Tear.tab {
            let width = width(in: strip)
            TabPill(browser: browser, prefs: browser.prefs, tab: tab, live: false, width: width,
                    room: strip - lights - leading - 12, pill: pill, close: {})
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Palette.hover))
                .allowsHitTesting(false)
                // Held the way the picture is held: a little in from its
                // leading end.
                .offset(x: hand.x - 40, y: (Metrics.strip - 28) / 2)
        }
    }

    var body: some View {
        // A GeometryReader is only here to measure the width. Its content is
        // put in a stack of its own and told to fill it: left to itself a
        // reader pins whatever it holds to the top corner, which is the row
        // riding at the very top of the strip while the traffic lights centre
        // themselves halfway down it.
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // The empty half of the strip is what you grab to move the
                // window; the tabs keep the run they sit on.
                DragStrip(reserved: lights + dot + leading + (making ? min(540, room(in: geo.size.width)) : run(in: geo.size.width)) + Metrics.tabGap + Metrics.plusWidth, trailing: doors + 12, onDoubleClick: browser.newTab)
                // And the corner the lights sit in, which is title bar too —
                // the one stretch left to take hold of when tabs fill the row.
                DragStrip()
                    .frame(width: lights)

                HStack(spacing: Metrics.tabGap) {
                    // Back, forward and reload by the lights, when asked.
                    if browser.prefs.navigationLeft { Helm(browser: browser) }
                    // The space on screen, first, when there are spaces.
                    // Above the tabs, for the name it shows over them a moment
                    // after a switch.
                    if browser.prefs.usesSpaces { SpaceDot(browser: browser).zIndex(1) }

                    // The tabs, in a run of their own. While they fit, it is
                    // exactly as wide as they are and nothing about the row
                    // changes. Past what the window holds at their narrowest
                    // it takes the room there is and scrolls inside its own
                    // edges — never under the lights, never over the doors —
                    // keeping the tab you are on in view.
                    // The spaces, one above the other: up or down over the bar
                    // and the next one's tabs come in as these go, with nothing
                    // between them (see SpaceSwipe). Past the last, a new one.
                    ZStack(alignment: .leading) {
                        if making {
                            NewSpaceCard(browser: browser, inline: true)
                                .fixedSize()
                                .offset(y: browser.spaceSwipe)
                        } else {
                            ScrollViewReader { reader in
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: Metrics.tabGap) {
                                        if browser.prefs.usesTabGroups {
                                            let pins = browser.displayedTabs.filter { $0.pin != nil }
                                            ForEach(Array(pins.enumerated()), id: \.element.id) { index, tab in
                                                topTab(tab, index: index, count: pins.count,
                                                       group: nil, strip: geo.size.width)
                                            }
                                            ForEach(browser.tabGroups) { group in
                                                GroupHeading(browser: browser, group: group,
                                                             horizontal: true, dragSpace: "strip")
                                                let members = browser.visibleTabs(in: group)
                                                ForEach(Array(members.enumerated()), id: \.element.id) { index, tab in
                                                    topTab(tab, index: index, count: members.count,
                                                           group: group.id, strip: geo.size.width)
                                                }
                                            }
                                            let ungrouped = browser.displayedTabs.filter { $0.pin == nil && browser.group(of: $0) == nil }
                                            ForEach(Array(ungrouped.enumerated()), id: \.element.id) { index, tab in
                                                topTab(tab, index: index, count: ungrouped.count,
                                                       group: nil, strip: geo.size.width)
                                            }
                                        } else {
                                            ForEach(Array(browser.displayedTabs.enumerated()), id: \.element.id) { index, tab in
                                                topTab(tab, index: index, count: browser.displayedTabs.count,
                                                       group: nil, strip: geo.size.width)
                                            }
                                        }
                                    }
                                    .frame(height: Metrics.strip)
                                    .onPreferenceChange(GroupDropFrames.self) { groupFrames = $0 }
                                    .onPreferenceChange(TabFrames.self) { browser.tabFrames = $0 }
                                }
                                .scrollDisabled(!overflowing(in: geo.size.width))
                                // A tab carried past the run's end stays in
                                // view, under the hand, wherever along the
                                // strip that is; the scroll view clipped it
                                // off at the edge. Once the run scrolls, the
                                // clip is what keeps the tabs scrolled out of
                                // it out of sight, so it stays then.
                                .scrollClipDisabled(!overflowing(in: geo.size.width))
                                .frame(width: run(in: geo.size.width))
                                .onAppear { reveal(reader, in: geo.size.width) }
                                .onChange(of: overflowing(in: geo.size.width)) { _, _ in reveal(reader, in: geo.size.width) }
                                .onChange(of: browser.activeID) { _, _ in reveal(reader, in: geo.size.width, gliding: true) }
                            }
                                .offset(y: browser.spaceSwipe)
                        }
                        if browser.spaceSwipe > 0, spaceAt > 0 {
                            page(spaceAt - 1, in: geo.size.width, pill: above)
                                .offset(y: browser.spaceSwipe - Metrics.strip)
                        }
                        if browser.spaceSwipe < 0, spaceAt < browser.spaces.count {
                            page(spaceAt + 1, in: geo.size.width, pill: below)
                                .offset(y: browser.spaceSwipe + Metrics.strip)
                        }
                    }
                    // Stretched by however far the last tab has been carried
                    // past the end, so the plus goes along with it.
                    .frame(width: (making ? min(540, room(in: geo.size.width)) : run(in: geo.size.width)) + stretch(in: geo.size.width), height: Metrics.strip, alignment: .leading)
                    // Only up and down: a neighbour's row may run wider than this one.
                    .mask(Rectangle().frame(width: 4000, height: Metrics.strip))

                    // The way to a new page, right after the tabs rather than
                    // at the end of their run, so it is there however far the
                    // run has scrolled. Out of sight until the pointer is up here.
                    Button { browser.newTab() } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Palette.muted)
                            .frame(width: 15, height: 15)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 6)
                            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .background(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(plussed ? Palette.hover : .clear)
                            )
                    }
                    .buttonStyle(.plain)
                    .onHover { plussed = $0 }
                    .opacity(plusUp ? 1 : 0)
                    .scaleEffect(plusUp ? 1 : 0.7, anchor: .leading)
                    .allowsHitTesting(plusUp)
                    .animation(Motion.settle, value: plusUp)

                    Spacer(minLength: 0)

                    // Back, forward, reload, and the bookmarks, at the far end
                    // of the row. The dropdown hangs from the last one.
                    HStack(spacing: Metrics.tabGap) {
                        // Only while a download is running, and a moment after.
                        FetchDoor(browser: browser, fetches: browser.fetches)
                        ExtensionSlot()
                        if !browser.prefs.navigationLeft {
                            Helm(browser: browser).padding(.trailing, 8)
                        }
                        BookmarkDoor(browser: browser, arrowEdge: .bottom)
                    }
                    .background {
                        GeometryReader { box in
                            Color.clear
                                .onAppear { doors = box.size.width }
                                .onChange(of: box.size.width) { _, width in doors = width }
                        }
                    }
                }
                // The traffic lights are the system's. The row starts after
                // them and stays there — nothing here moves to get out of
                // their way, because nothing here was ever in it.
                .padding(.leading, lights)
                .padding(.trailing, 12)
                .coordinateSpace(name: "strip")
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .overlay(alignment: .topLeading) { arriving(in: geo.size.width) }
        }
        .frame(height: Metrics.strip)
        .onHover { nearby = $0 }
        .onAppear { SpaceSwipe.shared.start(for: browser) }
        // A link dragged onto the row opens there.
        .onDrop(of: [.url, .text], isTargeted: $landing) { providers in
            browser.take(providers)
        }
        .background {
            ZStack {
                landing ? Palette.hover : Color.clear
                if browser.prefs.splitView {
                    SplitDropZone(browser: browser, tab: nil, kind: .strip)
                }
            }
        }
        .animation(Motion.quick, value: landing)
        .animation(Motion.glide, value: browser.activeID)
        // The row makes room for the field on the same spring as everything
        // else. Without this the widths changed between one frame and the next
        // and the tabs appeared to jump aside.
        .animation(Motion.glide, value: browser.editingTab)
        .animation(Motion.settle, value: browser.tabs.map(\.id))
    }

    // MARK: - the spaces, one above the other

    private var making: Bool { browser.prefs.usesSpaces && browser.makingSpace }

    /// Where the space on screen sits among them: one past the last while
    /// the row for a new one is up.
    private var spaceAt: Int {
        browser.makingSpace ? browser.spaces.count : (browser.spaces.firstIndex { $0.id == browser.spaceID } ?? 0)
    }

    /// Another space's row, drawn with the same pills as this one's so the
    /// two read as one bar while they pass — nothing to press until it is
    /// the one on screen. Past the last, the row for a new space.
    @ViewBuilder
    private func page(_ index: Int, in strip: CGFloat, pill: Namespace.ID) -> some View {
        if index == browser.spaces.count {
            NewSpaceCard(browser: browser, inline: true)
                .fixedSize()
                .allowsHitTesting(false)
        } else {
            let space = browser.spaces[index]
            let row = space.id == browser.spaceID
                ? Parked(tabs: browser.tabs, active: browser.activeID, splits: browser.splits)
                : browser.parked[space.id] ?? Parked(tabs: [], active: nil)
            let shown = rowTabs(row.tabs, splits: row.splits)
            let each = width(in: strip, tabs: shown, splits: row.splits)
            HStack(spacing: Metrics.tabGap) {
                ForEach(shown) { tab in
                    rowItem(tab, in: row.tabs, splits: row.splits, activeID: row.active,
                            width: each, room: strip - lights - 12,
                            height: Metrics.strip, interactive: false, pill: pill)
                }
            }
            .frame(height: Metrics.strip)
            .allowsHitTesting(false)
        }
    }

    /// Brings the tab you are on into view once the run scrolls: at once
    /// when the window first shows it, on the strip's spring when you pick
    /// another. A turn of the run loop later, so the run has been laid out.
    private func reveal(_ reader: ScrollViewProxy, in strip: CGFloat, gliding: Bool = false) {
        guard overflowing(in: strip), let activeID = browser.activeID else { return }
        let id: Tab.ID
        if browser.prefs.splitView, let active = browser.tabs.first(where: { $0.id == activeID }) {
            id = browser.split(for: active)?.left ?? activeID
        } else {
            id = activeID
        }
        DispatchQueue.main.async {
            if gliding {
                withAnimation(Motion.glide) { reader.scrollTo(id) }
            } else {
                reader.scrollTo(id)
            }
        }
    }

    private func topTab(_ tab: Tab, index: Int, count: Int, group: UUID?, strip: CGFloat) -> some View {
        let pair = browser.prefs.splitView ? browser.split(for: tab) : nil
        let isPairRepresentative = pair?.left == tab.id
        let itemWidth = isPairRepresentative ? splitItemWidth(base: width(in: strip)) : width(in: strip)
        let step = (tab.pin != nil ? Metrics.pinWidth : itemWidth) + Metrics.tabGap
        // With groups, each run of the row is its own; without, the row is
        // one run, and a pin keeps to the pins in it, a title to the titles.
        let groups = browser.prefs.usesTabGroups
        let run = groups ? (group?.uuidString ?? (tab.pin != nil ? "pins" : "loose")) : "row"
        let pinned = browser.pinnedCount
        let places = groups ? nil : (tab.pin != nil ? 0..<pinned : pinned..<count)
        // A tab from another window lands among the loose tabs, whose count
        // is what its place is given in; in the one run of the row without
        // groups, the pins come before them.
        let taking = groups ? "loose" : "row"
        let arrival = run == taking ? browser.arrival.map { groups ? $0 : $0 + pinned } : nil
        return rowItem(tab, in: browser.tabs, splits: browser.splits, activeID: browser.activeID,
                       width: width(in: strip), room: strip - lights - leading - 12,
                       height: Metrics.strip, interactive: true, pill: pill)
            .background {
                if browser.prefs.splitView && !isPairRepresentative {
                    SplitDropZone(browser: browser, tab: tab, kind: .strip)
                }
            }
            .modifier(Carried(index: index, count: count, step: step, vertical: false,
                              space: "strip", run: run, places: places, arrival: arrival,
                              tab: tab, browser: browser,
                              onDrop: { point in drop(tab, at: point) },
                              onDropTab: { source, point in drop(source, at: point) }, carry: $carry) {
                if browser.prefs.usesTabGroups && tab.pin == nil {
                    browser.move(tab, within: group, to: $0)
                } else {
                    browser.moveDisplayedTab(tab, to: $0)
                }
            })
            .id(tab.id)
    }

    @ViewBuilder
    private func rowItem(
        _ tab: Tab,
        in tabs: [Tab],
        splits: [TabSplit],
        activeID: Tab.ID?,
        width: CGFloat,
        room: CGFloat,
        height: CGFloat,
        interactive: Bool,
        pill: Namespace.ID
    ) -> some View {
        let pair = browser.prefs.splitView ? splits.first(where: { $0.left == tab.id }) : nil
        if let pair, let right = tabs.first(where: { $0.id == pair.right }) {
            let editingPair = browser.editingTab == tab.id || browser.editingTab == right.id
            let pairedWidth = splitItemWidth(base: width)
            let displayedWidth = interactive && editingPair ? min(340, room) : pairedWidth
            SplitTabItem(browser: browser, prefs: browser.prefs, left: tab, right: right,
                         width: displayedWidth, height: height,
                         live: activeID.map { pair.contains($0) } ?? false,
                         focusedID: activeID,
                         interactive: interactive)
        } else {
            TabPill(browser: browser, prefs: browser.prefs, tab: tab,
                    live: tab.id == activeID, width: width, room: room, pill: pill,
                    close: interactive ? { browser.close(tab) } : {})
        }
    }

    private func drop(_ tab: Tab, at point: CGPoint) {
        guard browser.prefs.usesTabGroups, tab.pin == nil else { return }
        if let id = groupFrames.first(where: { $0.value.contains(point) })?.key {
            browser.move(tab, toGroup: id)
        }
    }

    /// How wide the run of tabs is: as wide as the tabs while they fit, as
    /// wide as the room there is once they don't.
    private func run(in strip: CGFloat) -> CGFloat {
        min(content(in: strip), room(in: strip))
    }

    private func overflowing(in strip: CGFloat) -> Bool {
        content(in: strip) > room(in: strip) + 0.5
    }

    /// Everything in the run at the width the tabs get — and the address
    /// field's width for a tab being edited, which grows to take it.
    private func content(in strip: CGFloat) -> CGFloat {
        let each = width(in: strip)
        let displayed = browser.displayedTabs
        let pinned = CGFloat(displayed.filter { $0.pin != nil }.count)
        let ungrouped = displayed.filter { $0.pin == nil && browser.group(of: $0) == nil }
        let grouped = browser.tabGroups.flatMap { browser.visibleTabs(in: $0) }
        let looseTabs = browser.prefs.usesTabGroups ? ungrouped + grouped : displayed.filter { $0.pin == nil }
        let loose = CGFloat(looseTabs.count)
        let extra = pairWidthExtra(in: looseTabs, base: each, splits: browser.splits)
        let headers = browser.prefs.usesTabGroups ? CGFloat(browser.tabGroups.count) : 0
        let headingWidth = browser.prefs.usesTabGroups
            ? browser.tabGroups.reduce(CGFloat.zero) { $0 + GroupHeading.width(for: $1.name) } : 0
        let shown = Int(pinned + loose + headers)
        var total = pinned * Metrics.pinWidth + loose * each + extra
            + headingWidth + CGFloat(max(0, shown - 1)) * Metrics.tabGap
        if let id = browser.editingTab, let tab = browser.tabs.first(where: { $0.id == id }) {
            let splitWidth = browser.prefs.splitView ? browser.split(for: tab).map { _ in splitItemWidth(base: each) } : nil
            let oldWidth = splitWidth ?? (tab.pin != nil ? Metrics.pinWidth : each)
            total += min(340, strip - lights - leading - 12) - oldWidth
        }
        return total
    }

    /// The strip, less the lights, the helm when it leads, the plus, the
    /// doors at the far end and the air around them. The doors are measured;
    /// until they have been, the helm and the bookmarks stand in for them —
    /// unless the helm leads, when nothing at the far end may be a real zero.
    private func room(in strip: CGFloat) -> CGFloat {
        let far = doors > 0 || browser.prefs.navigationLeft ? doors : Metrics.helm + 26
        return max(0, strip - lights - dot - leading - 12 - Metrics.plusWidth - far - 3 * Metrics.tabGap)
    }

    /// What the space's dot takes before the tabs, when there are spaces.
    private var dot: CGFloat { browser.prefs.usesSpaces ? SpaceDot.width + Metrics.tabGap : 0 }

    /// Every loose tab is the same width, so the cross is always in the same
    /// place. Past a dozen or so they start giving ground; too narrow for a
    /// title they show their mark alone (Metrics.tabTitled), down to the
    /// mark and its air. Past that, the run scrolls. The pinned squares take
    /// their room off the top.
    private func width(in strip: CGFloat) -> CGFloat {
        let displayed = browser.displayedTabs
        let ungrouped = displayed.filter { $0.pin == nil && browser.group(of: $0) == nil }
        let grouped = browser.prefs.usesTabGroups ? browser.tabGroups.flatMap { browser.visibleTabs(in: $0) } : []
        let items = browser.prefs.usesTabGroups ? ungrouped + grouped : displayed
        let pins = displayed.filter { $0.pin != nil }.count
        if browser.prefs.usesTabGroups {
            let count = items.count
            guard count > 0 else { return Metrics.tabWidth }
            let extra = pairWidthExtra(in: items, base: Metrics.tabMinWidth, splits: browser.splits)
            let spent = CGFloat(pins) * Metrics.pinWidth + extra
                + browser.tabGroups.reduce(CGFloat.zero) { $0 + GroupHeading.width(for: $1.name) }
                + CGFloat(max(0, pins + count + browser.tabGroups.count - 1)) * Metrics.tabGap
            return max(Metrics.tabMinWidth, min(Metrics.tabWidth, (room(in: strip) - spent) / CGFloat(count)))
        }
        return width(in: strip, tabs: displayed, splits: browser.splits)
    }

    private func width(in strip: CGFloat, tabs: [Tab], splits: [TabSplit]) -> CGFloat {
        let pinned = CGFloat(tabs.filter { $0.pin != nil }.count)
        let looseTabs = tabs.filter { $0.pin == nil }
        let loose = CGFloat(looseTabs.count)
        guard loose > 0 else { return Metrics.tabWidth }
        let extra = pairWidthExtra(in: looseTabs, base: Metrics.tabMinWidth, splits: splits)
        let spent = pinned * Metrics.pinWidth
            + extra + CGFloat(max(0, tabs.count - 1)) * Metrics.tabGap
        return max(Metrics.tabMinWidth, min(Metrics.tabWidth, (room(in: strip) - spent) / loose))
    }

    private func rowTabs(_ tabs: [Tab], splits: [TabSplit]) -> [Tab] {
        guard browser.prefs.splitView else { return tabs }
        let right = Set(splits.map(\.right))
        return tabs.filter { !right.contains($0.id) }
    }

    private func splitItemWidth(base: CGFloat) -> CGFloat {
        min(210, max(136, base * 1.55))
    }

    private func pairWidthExtra(in tabs: [Tab], base: CGFloat, splits: [TabSplit]) -> CGFloat {
        guard browser.prefs.splitView else { return 0 }
        let ids = Set(tabs.map(\.id))
        return splits.reduce(CGFloat.zero) { total, pair in
            guard pair.left != pair.right, ids.contains(pair.left) else { return total }
            return total + splitItemWidth(base: base) - base
        }
    }
}

/// Back, forward, reload. They watch the live tab, not the window: whether
/// there is anywhere to go back to is the tab's to say, and it changes with
/// every page. Used here and, beside the traffic lights instead of at the
/// far end of the row, in the sidebar.
struct Helm: View {
    @ObservedObject var browser: Browser

    var body: some View {
        if let tab = browser.active {
            Wheel(browser: browser, tab: tab)
        } else {
            // Nowhere to go and nothing to reload: the doors stay in place,
            // greyed, so the row doesn't shift when a tab arrives.
            HStack(spacing: 4) {
                Door(icon: "chevron.left") {}
                Door(icon: "chevron.right") {}
                Door(icon: "arrow.clockwise") {}
            }
            .opacity(0.3)
            .allowsHitTesting(false)
        }
    }

    private struct Wheel: View {
        let browser: Browser
        @ObservedObject var tab: Tab

        var body: some View {
            let back = !tab.isBlank && tab.canGoBack
            let forward = !tab.isBlank && tab.canGoForward
            HStack(spacing: 4) {
                Door(icon: "chevron.left", help: "Back   ⌘[") { browser.back() }
                    .disabled(!back)
                    .opacity(back ? 1 : 0.3)
                Door(icon: "chevron.right", help: "Forward   ⌘]") { browser.forward() }
                    .disabled(!forward)
                    .opacity(forward ? 1 : 0.3)
                // Reload, or stop while it is still coming.
                Door(
                    icon: tab.loading ? "xmark" : "arrow.clockwise",
                    help: tab.loading ? "Stop   ⌘." : "Reload   ⌘R"
                ) {
                    if tab.loading { tab.stop() } else { browser.reload() }
                }
                .disabled(tab.isBlank)
                .opacity(tab.isBlank ? 0.3 : 1)
            }
            .animation(Motion.quick, value: back)
            .animation(Motion.quick, value: forward)
            .animation(Motion.quick, value: tab.loading)
        }
    }
}

private struct TabPill: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    @ObservedObject var tab: Tab
    let live: Bool
    let width: CGFloat
    /// How much of the strip there is, for the field that grows over it.
    let room: CGFloat
    let pill: Namespace.ID
    let close: () -> Void

    @State private var hovering = false
    @State private var shake: CGFloat = 0

    private var editing: Bool { browser.editingTab == tab.id }
    private var pinned: Bool { tab.pin != nil && !editing }
    /// Too narrow for a title: the site's mark alone, the title in the
    /// tooltip, and ⌘W or the menu to close it — a cross on something this
    /// small would be what a click to pick the tab lands on.
    private var compact: Bool { !editing && !pinned && width < Metrics.tabTitled }
    /// A speaker to press at the end of the pill: the page plays sound, or
    /// was muted. The ring, while the page is still coming, goes first.
    private var speaker: Bool { !editing && !tab.loading && (tab.noisy || tab.muted) }

    /// A pinned tab is a square, an edited one is a field, everything else is
    /// its share of what is left.
    private var span: CGFloat {
        if editing { return min(340, room) }
        return pinned ? Metrics.pinWidth : width
    }

    var body: some View {
        Group {
            if pinned {
                Group {
                    if browser.editingPin == tab.id {
                        PinField(browser: browser, tab: tab)
                    } else if tab.loading {
                        // Its page on the way, as a tab's ring says; the
                        // letter or icon comes back once it is there.
                        Ring(size: 11)
                    } else if prefs.glyph == .icons, let icon = tab.icon {
                        Mark(icon: icon, letter: tab.pin ?? "", size: 16, dim: tab.asleep)
                    } else {
                        Text(tab.pin ?? "")
                            .font(.system(size: 12, weight: .medium))
                            // A pin holding no page is still there and still
                            // yours; it just isn't costing anything.
                            .foregroundStyle(colour.opacity(tab.asleep ? 0.45 : 1))
                    }
                }
                .frame(width: 16, height: 16)
                .padding(.horizontal, 7)
                .padding(.vertical, 6)
                .frame(width: span)
            } else {
                loose
            }
        }
        .background { ground }
        .modifier(Shake(travel: shake))
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        // Never both at once.
        //
        // A view carrying a single tap *and* a double tap has to wait out the
        // system's double-click delay before it can conclude that a click was
        // single — and that delay is a preference, adjustable up to a second.
        // Which is exactly how long a tab took to come forward.
        //
        // So each tab carries one gesture. The pinned square you are already
        // on has nothing to do on a single click, so it takes the double one
        // and goes back to the page it was pinned at — or, there already,
        // edits its letter; everything else answers the first click at
        // once. Change Letter in the menu covers the rest.
        .modifier(OneClick(double: live && pinned) {
            if live && pinned {
                browser.goHome(tab)
            } else if live && !pinned {
                browser.beginTabEdit(tab)
            } else {
                browser.select(tab)
            }
        })
        .overlay { MiddleClick(act: close) }
        .onHover { hovering = $0 }
        .contextMenu { TabMenu(browser: browser, tab: tab, close: close) }
        .help(pinned || compact ? tab.label : "")
        .animation(Motion.quick, value: hovering)
        .animation(Motion.glide, value: editing)
        .animation(Motion.glide, value: tab.pin)
        .onChange(of: browser.refusals) { _, _ in
            guard editing else { return }
            shake = 0
            withAnimation(.easeOut(duration: 0.5)) { shake = 1 }
        }
        // Arriving and leaving from the strip rather than from nowhere.
        .transition(.scale(scale: 0.9, anchor: .leading).combined(with: .opacity))
    }

    @ViewBuilder
    private var loose: some View {
        if compact {
            ZStack {
                if tab.loading {
                    Ring()
                } else {
                    Mark(icon: prefs.glyph == .icons ? tab.icon : nil, letter: tab.monogram, size: 15, dim: tab.asleep)
                }
            }
            .frame(width: 16, height: 16)
            .padding(.vertical, 6)
            .frame(width: span)
        } else {
            titled
        }
    }

    private var titled: some View {
        HStack(spacing: 6) {
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
                    // Quiet, and only on the tabs that keep nothing.
                    Image(systemName: "eye.slash")
                        .font(.system(size: 9))
                        .foregroundStyle(colour.opacity(0.7))
                }
                Text(tab.label)
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(colour)
            }

            Spacer(minLength: 2)

            // The speaker, which can be pressed, is at the end of the pill on
            // its own, and one place in under the pointer, beside the cross
            // and clear of its reach.
            HStack(spacing: 0) {
                if speaker {
                    Speaker(tab: tab)
                        .padding(.trailing, hovering ? 8 : 0)
                        .transition(.opacity)
                }

                // Pinned to the right-hand end of the pill, not trailing the title.
                // One slot doing two jobs: the cross when the pointer is here, the
                // ring while the page is still coming, never both.
                ZStack {
                    if hovering {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(Palette.muted)
                            .frame(width: 15, height: 15)
                            .background(Palette.ink.opacity(0.07), in: Circle())
                            .transition(.opacity)
                    } else if tab.loading {
                        Ring().transition(.opacity)
                    }
                }
                .frame(width: editing || (speaker && !hovering) ? 0 : 15, height: 15)
                .opacity(editing ? 0 : 1)
                // The cross is 15 points across because that is how big it should
                // look. What you have to hit is the whole right-hand end of the
                // tab: an overlay is not laid out, so it can reach past its own
                // frame without moving anything that is.
                //
                // A view of AppKit's own takes the click there, while the
                // cross shows (see CloseClick).
                .overlay {
                    if !editing {
                        CloseClick(armed: hovering, act: close)
                            .frame(width: 30, height: 28)
                    }
                }
                .animation(Motion.quick, value: hovering)
                .animation(Motion.quick, value: tab.loading)
            }
        }
        .padding(.leading, 11)
        .padding(.trailing, editing ? 11 : 7)
        .padding(.vertical, 6)
        .frame(width: span, alignment: .leading)
        .animation(Motion.quick, value: speaker)
    }

    @ViewBuilder
    private var ground: some View {
        if live {
            // The grey fills from the left as you read down the page. It is
            // the one thing in the window that says how far in you are, and
            // it says it without adding anything to the window.
            ZStack(alignment: .leading) {
                // A pinned square among the faint grey of the others: the
                // darker grey the column's live pin wears too.
                Rectangle().fill(pinned ? Palette.pinLive : Palette.wash)
                // Not on a pinned square, nor a tab down to its mark. Thirty
                // points of grey filling from the left behind a single letter
                // says nothing about anything — it needs the width of a title
                // to read as progress at all.
                if !pinned && !compact && prefs.showsReading {
                    ReadingFill(meter: tab.meter, width: span)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .matchedGeometryEffect(id: "live", in: pill)
        } else if hovering {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Palette.hover)
        } else if pinned {
            // A letter with nothing behind it reads as debris. A pinned tab
            // keeps a faint ground of its own so the block of them reads as
            // one thing.
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Palette.wash.opacity(0.55))
        }
    }

    private var colour: Color {
        if live { return Palette.ink }
        return hovering ? Palette.ink.opacity(0.7) : Palette.muted
    }
}

/// The address, inside its own tab.
///
/// A field of its own rather than SwiftUI's, for one reason: the system paints
/// selected text as a solid block of accent colour, which over a pale grey pill
/// this size is the loudest thing in the window. Here it is a tenth of the ink.
/// A tab on its way along the row or down the column: which one, in which
/// run of tabs, and where the hand has taken it. One per bar or column, in
/// the view that holds the run, and read by every tab in it (see Carried) —
/// the tabs it passes make way by it, and the bar stretches by it.
struct Carry: Equatable {
    /// The run the tab belongs to — the pins, a group, the loose tabs — since
    /// only the tabs of its own run make way for it.
    let run: String
    /// Its place in the run, which it keeps until it is let go.
    let from: Int
    /// One place in the run: the tab's length and the gap after it.
    let step: CGFloat
    /// The place it would take if let go now.
    var to: Int
    /// How far the hand has moved since it was picked up.
    var travel: CGFloat
    /// Carried out of the row altogether (see Tear): the row closes up
    /// behind it, and a picture of its page follows the hand instead.
    var out = false
}

/// A tab picked up and carried along its row, the others making way as it
/// passes them — across the top or down the column alike — and out of the
/// row, to another window or one of its own (see Tear).
///
/// The tabs keep their places in the row until the tab is let go: the carried
/// one is drawn wherever the hand has taken it, and each tab it has passed one
/// place over, out of its way, on a spring. Reordered while it was carried,
/// the row gave the carried tab its new place on the row's own spring, and
/// it jumped a whole place away from the hand and drifted back each time it
/// passed another. Let go, the row is reordered once: every tab's place and
/// its offset spring at the same time, and cancel out, so the ones that made
/// way stay where they are and the carried one settles into its place.
struct Carried: ViewModifier {
    let index: Int
    let count: Int
    /// One place in the row: the tab's length and the gap after it.
    let step: CGFloat
    let vertical: Bool
    /// The row's coordinate space, not the tab's, so the offset the tab is
    /// drawn at doesn't move the measure.
    let space: String
    /// The run of tabs this one is in (see Carry.run).
    var run: String = "tabs"
    /// The places it may take, when the run holds more than one kind: a pin
    /// stays among the pins, a title among the titles.
    var places: Range<Int>? = nil
    /// A tab from another window on its way into this run, and where (see
    /// Browser.arrival): the tabs from there on make way for it.
    var arrival: Int? = nil
    /// The tab and its window, for a tab that can leave the row.
    var tab: Tab? = nil
    var browser: Browser? = nil
    var onDrop: ((CGPoint) -> Void)? = nil
    /// A paired item can be picked up from either half; report that source.
    var onDropTab: ((Tab, CGPoint) -> Void)? = nil
    @Binding var carry: Carry?
    let move: (Int) -> Void

    private var held: Bool { carry?.run == run && carry?.from == index }
    private var allowed: Range<Int> { places ?? 0..<count }

    /// Where the tab is drawn, against its place in the row. The carried
    /// one: as far as the hand has taken it, within its places — and past
    /// the last of them only at the run's far end, where the bar stretches
    /// and the plus goes with it. Each tab it has passed: one place over.
    /// Carried out of the row, the tabs after it close up. A tab arriving
    /// from another window: the tabs from its place on make way.
    private var shift: CGFloat {
        if let carry, carry.run == run {
            if carry.from == index {
                if carry.out { return 0 }
                let low = -CGFloat(carry.from - allowed.lowerBound) * step
                let high = allowed.upperBound == count
                    ? CGFloat.infinity
                    : CGFloat(allowed.upperBound - 1 - carry.from) * step
                return min(max(carry.travel, low), high)
            }
            if carry.out { return index > carry.from ? -step : 0 }
            if carry.from < index, index <= carry.to { return -step }
            if carry.to <= index, index < carry.from { return step }
            return 0
        }
        if let arrival, index >= arrival { return step }
        return 0
    }

    private var out: Bool { held && carry?.out == true }

    func body(content: Content) -> some View {
        content
            // Where its place is, for a tab carried over this window from
            // another to find its own among them (see Tear).
            .background {
                if let tab {
                    GeometryReader { box in
                        Color.clear.preference(key: TabFrames.self, value: [tab.id: box.frame(in: .global)])
                    }
                }
            }
            // A ground of its own while it is carried. The tab's grey comes
            // with the pointer over it, and a tab isn't told of the pointer's
            // comings and goings while the button is down: carried, it lost
            // its grey now and then, and the tab it was passing showed through
            // its title. Under the offset, so it travels with the tab and not
            // with its place.
            .background {
                if held { RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Palette.hover) }
            }
            .offset(x: vertical ? 0 : shift, y: vertical ? shift : 0)
            // Out of the row, the picture stands in for it.
            .opacity(out ? 0 : 1)
            .animation(Motion.settle, value: out)
            // Over the others, and flat: a shadow under it was cut off at
            // the row's edge and read as a smudge.
            .zIndex(held ? 1 : 0)
            // The tabs making way glide; the carried one is under the hand
            // at once. Let go, it is no longer held, and springs into its
            // place on the same spring as the row's reorder.
            .animation(held ? nil : Motion.settle, value: shift)
            .gesture(
                DragGesture(minimumDistance: 5, coordinateSpace: .named(space))
                    .onChanged { value in
                        let travel = vertical ? value.translation.height : value.translation.width
                        if carry == nil {
                            carry = Carry(run: run, from: index, step: step, to: index, travel: travel)
                        }
                        guard held else { return }
                        // Out of the row, nothing in the row changes with
                        // the hand: only the picture follows it, and the
                        // row isn't drawn again for every move.
                        if carry?.out == true {
                            follow()
                            return
                        }
                        carry?.travel = travel
                        // Over a page, with Split View on, the drag is a
                        // pairing and the row keeps still (see TabDrag).
                        if let browser, let tab, browser.prefs.splitView,
                           TabDrag.shared.update(browser: browser, tab: tab,
                                                 translation: value.translation) { return }
                        let target = min(max(allowed.lowerBound, index + Int((travel / step).rounded())), allowed.upperBound - 1)
                        if target != carry?.to { carry?.to = target }
                        follow()
                    }
                    .onEnded { value in
                        guard held, let carry else { return }
                        let point = NSEvent.mouseLocation
                        if carry.out {
                            // Out of the row: to the window it is over, or
                            // one of its own. The row hears of it a moment
                            // later, once the gesture has let go of the tab.
                            if browser?.prefs.splitView == true, let browser, let tab {
                                _ = TabDrag.shared.finish(browser: browser, tab: tab)
                            }
                            Tear.end(at: point)
                            // After the row has let it go, so it doesn't
                            // show for the instant in between; if it stays
                            // after all, it springs back into its place.
                            DispatchQueue.main.async { withAnimation(Motion.settle) { self.carry = nil } }
                            return
                        }
                        // With Split View on, a tab let go over a page pairs
                        // with it, and a half of a pair let go on the row
                        // leaves the pair; the row's own reorder otherwise.
                        var source = tab
                        if let browser, let tab, browser.prefs.splitView {
                            let finished = TabDrag.shared.finish(browser: browser, tab: tab)
                            source = finished.source
                            switch finished.drop {
                            case .stage(let target, let onLeft):
                                withAnimation(Motion.settle) {
                                    self.carry = nil
                                    browser.pair(finished.source, with: target, onLeft: onLeft)
                                }
                                return
                            case .strip(let target):
                                withAnimation(Motion.settle) {
                                    self.carry = nil
                                    browser.dropTabIntoStrip(finished.source, before: target)
                                }
                                if let onDropTab { onDropTab(finished.source, value.location) }
                                else if finished.source.id == tab.id { onDrop?(value.location) }
                                return
                            case .cancelled:
                                withAnimation(Motion.settle) { self.carry = nil }
                                return
                            case .outside:
                                break
                            }
                        }
                        if let onDropTab, let source { onDropTab(source, value.location) }
                        else { onDrop?(value.location) }
                        withAnimation(Motion.settle) {
                            self.carry = nil
                            if carry.to != index { move(carry.to) }
                        }
                    }
            )
            // Escape, with Split View on (see TabDrag): the drag is off, and
            // the tab is back where it was picked up — nothing was reordered
            // yet — the picture shrinking back into it if it was out.
            .onReceive(TabDrag.shared.$cancelledID) { id in
                guard id == tab?.id, held else { return }
                if carry?.out == true, let browser, let tab {
                    Tear.home(pill: browser.tabFrames[tab.id]?.width ?? Metrics.tabWidth)
                }
                withAnimation(Motion.settle) { carry = nil }
            }
    }

    /// Out of the row, or back into it, by where the hand is on the screen:
    /// a little past the row's edge, the tab leaves it; over the row again,
    /// it is back in it. The pins never leave, nor the last tab of the only
    /// window (see Tear.can).
    private func follow() {
        guard let tab, let browser, let carry, Tear.can(tab, leave: browser), let bar = browser.bar else { return }
        let point = NSEvent.mouseLocation
        // The pill's width, for the picture to grow out of and shrink back
        // into a pill that size.
        let pill = browser.tabFrames[tab.id]?.width ?? Metrics.tabWidth
        if carry.out {
            if bar.contains(point) {
                Tear.home(pill: pill)
                withAnimation(Motion.settle) { self.carry?.out = false }
            } else {
                Tear.move(to: point)
            }
        } else if !bar.insetBy(dx: -12, dy: -12).contains(point) {
            Tear.begin(tab, from: browser, at: point, pill: pill)
            withAnimation(Motion.settle) { self.carry?.out = true }
        }
    }
}

struct TabAddressField: NSViewRepresentable {
    @ObservedObject var browser: Browser

    func makeCoordinator() -> Coordinator { Coordinator(browser: browser) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 12.5)
        field.textColor = Palette.NS.ink
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.stringValue = browser.tabDraft
        context.coordinator.watch(field)
        // The site card stands under whichever field the address is in.
        SiteCardPanel.follow(browser, anchor: field)
        return field
    }

    static func dismantleNSView(_ field: NSTextField, coordinator: Coordinator) {
        coordinator.unwatch()
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        let coordinator = context.coordinator
        coordinator.browser = browser
        if !coordinator.typing, field.stringValue != browser.tabDraft {
            field.stringValue = browser.tabDraft
        }
        guard !coordinator.claimed else { return }
        coordinator.claimed = true
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
            guard let editor = field.currentEditor() as? NSTextView else { return }
            editor.selectedTextAttributes = [
                .backgroundColor: NSColor(Palette.ink.opacity(0.11)),
                .foregroundColor: Palette.NS.ink,
            ]
            editor.selectAll(nil)
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var browser: Browser
        var claimed = false
        var typing = false

        init(browser: Browser) { self.browser = browser }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            typing = true
            browser.tabDraft = field.stringValue
            typing = false
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy command: Selector
        ) -> Bool {
            switch command {
            case #selector(NSResponder.insertNewline(_:)):
                // Returning true keeps the field editing, which is what lets a
                // refused address stay on screen instead of being thrown away.
                browser.commitTabEdit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                browser.cancelTabEdit()
                return true
            default:
                return false
            }
        }

        /// Clicking anywhere else keeps what was typed, as Return does.
        func controlTextDidEndEditing(_ note: Notification) {
            let browser = browser
            DispatchQueue.main.async { browser.finishTabEdit() }
        }

        /// A press on something that takes no focus — the strip's empty
        /// stretch, the column below the rows — leaves the field focused and
        /// editing, so presses are watched for while it is there: one anywhere
        /// but in the field ends the edit the same way. The press itself goes
        /// on to what it was for.
        private var watcher: Any?

        @MainActor func watch(_ field: NSTextField) {
            guard watcher == nil else { return }
            watcher = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self, weak field] event in
                guard let self, let field, event.window === field.window,
                      !field.bounds.contains(field.convert(event.locationInWindow, from: nil))
                else { return event }
                let browser = self.browser
                DispatchQueue.main.async { browser.finishTabEdit() }
                return event
            }
        }

        @MainActor func unwatch() {
            if let watcher { NSEvent.removeMonitor(watcher) }
            watcher = nil
        }
    }
}

/// What a right-click on any tab offers, wherever the tab is drawn.
struct TabMenu: View {
    @ObservedObject var browser: Browser
    @ObservedObject var tab: Tab
    let close: () -> Void

    var body: some View {
        if browser.prefs.usesTabGroups && tab.pin == nil && !tab.shy && !tab.bench {
            Menu("Move to Group") {
                Button("New Group") { browser.addTabGroup(containing: tab) }
                if !browser.tabGroups.isEmpty { Divider() }
                ForEach(browser.tabGroups) { group in
                    Button(group.name) { browser.move(tab, toGroup: group.id) }
                        .disabled(tab.groupID == group.id)
                }
                if tab.groupID != nil {
                    Divider()
                    Button("Remove from Group") { browser.move(tab, toGroup: nil) }
                }
            }
        }
        if tab.pin == nil {
            Button("Pin") { browser.pin(tab) }
                .disabled(tab.isBlank || tab.shy)
        } else {
            Button("Change Letter") { browser.editLetter(tab) }
            Button("Unpin") { browser.unpin(tab) }
        }
        if browser.prefs.usesSpaces, !tab.bench,
           tab.address.flatMap({ Browser.extensionHost(of: $0) }) == nil {
            Menu("Move to Space") {
                ForEach(browser.spaces.filter { $0.id != browser.spaceID }) { space in
                    Button {
                        browser.move(tab, toSpace: space.id)
                    } label: {
                        Label(space.name, systemImage: space.symbol)
                    }
                }
                if browser.spaces.count > 1 { Divider() }
                Button("New Space…") {
                    browser.askForSpace { space in
                        browser.move(tab, toSpace: space.id) {
                            browser.switchSpace(to: space.id)
                        }
                    }
                }
            }
            .help("Pages moved to a Space with different sign-ins reopen there.")
        }
        if browser.prefs.splitView {
            if browser.split(for: tab) != nil {
                Button("Separate Split Tabs") { browser.detachSplit(tab) }
            } else {
                Button("Split View") {
                    browser.select(tab)
                    browser.startSplit()
                }
                .disabled(tab.bench)
            }
        }
        if tab.pin == nil, !tab.bench {
            // Another window, or a new one (see Browser.moveToWindow).
            let others = Browsers.all.filter { $0 !== browser && $0.isOpen && $0.extensionPopup == nil }
            if others.isEmpty {
                Button("Move to New Window") { browser.moveToWindow(tab, nil) }
                    .disabled(browser.tabs.count < 2)
            } else {
                Menu("Move to Window") {
                    Button("New Window") { browser.moveToWindow(tab, nil) }
                        .disabled(browser.tabs.count < 2)
                    Divider()
                    ForEach(Array(others.enumerated()), id: \.offset) { _, other in
                        Button(other.windowName) { browser.moveToWindow(tab, other) }
                    }
                }
            }
        }
        Divider()
        Button("Rename") { browser.beginTabRename(tab) }
        Button("Duplicate") {
            browser.select(tab)
            browser.duplicate()
        }
        .disabled(tab.isBlank)
        // The card a click on the tab you are on shows under its address.
        Button("Site Information…") {
            if browser.activeID != tab.id { browser.select(tab) }
            browser.beginTabEdit(tab)
        }
        .disabled(tab.isBlank || tab.address == nil || tab.pin != nil)
        Button("Copy Address") {
            browser.select(tab)
            browser.copyAddress()
        }
        .disabled(tab.isBlank)
        Button("Copy as Markdown Link") {
            browser.select(tab)
            browser.copyMarkdownLink()
        }
        .disabled(tab.isBlank)
        Button(tab.muted ? "Unmute Tab" : "Mute Tab") { tab.toggleMute() }
        // Its page let go of now, as it would be after half an hour unseen:
        // the row keeps its title and picture, and it loads again when gone
        // to. Not the tab on screen, nor one that has to stay awake (#310).
        Button("Put to Sleep") {
            browser.sleep(tab) { outcome in
                if outcome != "asleep" { browser.announce("Stays awake: \(outcome)") }
            }
        }
        .disabled(browser.awake(because: tab) != nil)
        Divider()
        Button("Close Tab", action: close)
        Button("Close Other Tabs") { browser.closeOthers(but: tab) }
            .disabled(browser.tabs.count < 2)
        // ⌘⇧T, and the History menu's Recently Closed, where few think to
        // look for it: here too, where tabs are closed.
        Button("Reopen Closed Tab") { browser.reopen() }
            .disabled(browser.ghosts.isEmpty)
    }
}

/// One gesture or the other, never the two together.
struct OneClick: ViewModifier {
    let double: Bool
    let act: () -> Void

    func body(content: Content) -> some View {
        if double {
            content.onTapGesture(count: 2, perform: act)
        } else {
            content.onTapGesture(perform: act)
        }
    }
}

/// A click on a tab's cross closes it — taken by a real view laid over the
/// cross rather than by a SwiftUI tap. Out over the page, in the strip folded
/// away with ⌘S, the tap never came: the cross showed under the pointer and
/// clicking it did nothing (Drice). A view of AppKit's own is handed the
/// press by AppKit itself, as the middle button's is (MiddleClick), and it
/// answers only while the cross is there to be pressed, only to the left
/// button; to anything else it isn't there, and the tab goes on as before.
struct CloseClick: NSViewRepresentable {
    let armed: Bool
    let act: () -> Void

    func makeNSView(context: Context) -> NSView { Cross() }

    func updateNSView(_ view: NSView, context: Context) {
        (view as? Cross)?.armed = armed
        (view as? Cross)?.act = act
    }

    private final class Cross: NSView {
        var armed = false
        var act: () -> Void = {}
        private var pressed = false

        /// Never the window's to drag from: the press is the cross's.
        override var mouseDownCanMoveWindow: Bool { false }

        /// Asked about every event over the cross, the pointer moving included;
        /// only a left press, while the cross shows, is this view's.
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard armed, let event = NSApp.currentEvent,
                  event.type == .leftMouseDown, event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
            else { return nil }
            return super.hitTest(point)
        }

        override func mouseDown(with event: NSEvent) {
            pressed = true
        }

        /// On the release, and only if it is still over the cross: a press
        /// taken back by moving off before letting go closes nothing.
        override func mouseUp(with event: NSEvent) {
            guard pressed else { return }
            pressed = false
            if bounds.contains(convert(event.locationInWindow, from: nil)) { act() }
        }
    }
}

/// The middle button on a tab closes it, as it does in every other browser.
///
/// SwiftUI has no gesture for that button, so this is a real view laid over
/// the tab — and a real view is asked first (see DragStrip). It says yes for
/// the middle button and nothing else: to a left click, a drag or a right
/// click it isn't there, and the tab's own gestures and menu go on as before.
struct MiddleClick: NSViewRepresentable {
    let act: () -> Void

    func makeNSView(context: Context) -> NSView { Catch() }

    func updateNSView(_ view: NSView, context: Context) {
        (view as? Catch)?.act = act
    }

    private final class Catch: NSView {
        var act: () -> Void = {}
        private var pressed = false

        /// Asked about every event that lands on the tab, the pointer moving
        /// over it included; the one being delivered is the one to judge by.
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent,
                  event.type == .otherMouseDown || event.type == .otherMouseUp,
                  event.buttonNumber == 2
            else { return nil }
            return super.hitTest(point)
        }

        override func otherMouseDown(with event: NSEvent) {
            pressed = true
        }

        /// On the release, not the press, and only if it is still over the
        /// tab: a middle button pressed by mistake can be taken back the way
        /// a click on the cross can, by moving off before letting go.
        override func otherMouseUp(with event: NSEvent) {
            guard pressed else { return }
            pressed = false
            if bounds.contains(convert(event.locationInWindow, from: nil)) { act() }
        }
    }
}

/// An almost-closed ring, turning — the same one the canvas app uses, small
/// enough to sit inside a tab without becoming the loudest thing in it.
///
/// Turned by Core Animation rather than SwiftUI. A SwiftUI animation that
/// never ends has the whole window's view tree laid out and redrawn every
/// frame for as long as it runs — a fifth of a core, all the while a page
/// in some tab behind was still loading. A layer's own animation is played
/// by the render server and costs this process nothing.
struct Ring: NSViewRepresentable {
    var size: CGFloat = 10

    func makeNSView(context: Context) -> RingView { RingView() }
    func updateNSView(_ view: RingView, context: Context) {}
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: RingView, context: Context) -> CGSize? {
        CGSize(width: size, height: size)
    }

    final class RingView: NSView {
        private let ring = CAShapeLayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            ring.fillColor = nil
            ring.lineWidth = 1.4
            ring.lineCap = .round
            ring.strokeEnd = 0.78
            // Nothing but the turn moves: a new size or colour is there at
            // once, not eased into by Core Animation's own quarter second.
            ring.actions = ["bounds": NSNull(), "position": NSNull(), "path": NSNull(), "strokeColor": NSNull()]
            layer?.addSublayer(ring)
        }

        required init?(coder: NSCoder) { nil }

        /// Seen, never pressed: it sits in a tab, over the × while the page
        /// loads and in the middle of a tab down to its mark, and a real view
        /// would take the click meant for either.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            let inset = ring.lineWidth / 2
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            ring.frame = bounds
            ring.path = CGPath(ellipseIn: bounds.insetBy(dx: inset, dy: inset), transform: nil)
            CATransaction.commit()
        }

        /// The colour is resolved against the window's appearance, so it is
        /// set again whenever that changes.
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            effectiveAppearance.performAsCurrentDrawingAppearance {
                ring.strokeColor = Palette.NS.muted.withAlphaComponent(0.7).cgColor
            }
        }

        /// Turning only while it is in a window: a layer animation is dropped
        /// when the view leaves one, so it is added each time it arrives.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            viewDidChangeEffectiveAppearance()
            ring.removeAnimation(forKey: "turn")
            guard window != nil else { return }
            let turn = CABasicAnimation(keyPath: "transform.rotation.z")
            // Clockwise, as the SwiftUI one turned: a layer's positive angle
            // is anticlockwise in a view that isn't flipped.
            turn.fromValue = 0
            turn.toValue = -2 * Double.pi
            turn.duration = 0.85
            turn.repeatCount = .infinity
            ring.add(turn, forKey: "turn")
        }
    }
}


/// The letter of a pinned tab, typed in the square itself.
///
/// A field of its own rather than SwiftUI's, for the same reason as the address
/// in a tab: the system paints selected text as a solid block of accent colour,
/// and over a thirty-point grey square that is the loudest thing on screen.
struct PinField: NSViewRepresentable {
    @ObservedObject var browser: Browser
    @ObservedObject var tab: Tab

    func makeCoordinator() -> Coordinator { Coordinator(browser: browser, tab: tab) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.alignment = .center
        field.font = .systemFont(ofSize: 12, weight: .medium)
        field.textColor = Palette.NS.ink
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.stringValue = tab.pin ?? ""
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        let coordinator = context.coordinator
        coordinator.browser = browser
        coordinator.tab = tab
        if !coordinator.typing, field.stringValue != tab.pin ?? "" {
            field.stringValue = tab.pin ?? ""
        }
        guard !coordinator.claimed else { return }
        coordinator.claimed = true
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
            guard let editor = field.currentEditor() as? NSTextView else { return }
            editor.selectedTextAttributes = [
                .backgroundColor: NSColor(Palette.ink.opacity(0.12)),
                .foregroundColor: Palette.NS.ink,
            ]
            // The guessed letter arrives selected, so one keystroke replaces it
            // and doing nothing keeps it.
            editor.selectAll(nil)
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var browser: Browser
        var tab: Tab
        var claimed = false
        var typing = false

        init(browser: Browser, tab: Tab) {
            self.browser = browser
            self.tab = tab
        }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            typing = true
            browser.letter(field.stringValue, for: tab)
            // One character only, and shown as it will be worn.
            field.stringValue = tab.pin ?? ""
            typing = false
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy command: Selector
        ) -> Bool {
            switch command {
            case #selector(NSResponder.insertNewline(_:)),
                 #selector(NSResponder.cancelOperation(_:)),
                 #selector(NSResponder.insertTab(_:)):
                browser.endPinEdit()
                return true
            default:
                return false
            }
        }

        func controlTextDidEndEditing(_ note: Notification) {
            let browser = browser
            DispatchQueue.main.async { browser.endPinEdit() }
        }
    }
}
