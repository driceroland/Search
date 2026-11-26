import SwiftUI

// The column as icons only (idea 413, Settings › Appearance › Tabs, Icons
// only; off unless chosen). Each tab is its site's mark in a small tile, the
// pins as they always are, a fixed narrow width — and nothing that grows or
// slides out under the pointer, which is the one thing asked for against
// Chrome's (@eiyuuos on X, 25 Oct 2026): the title is a tooltip.
//
// What a row says beside its title, a tile says in a corner:
// - loading: the ring, in the mark's place, as on a pin;
// - sound playing or muted: a small speaker in the bottom corner, pressed to
//   mute or unmute, as the row's is;
// - recording (an extension, RecordingIndicator): a red dot in the top
//   corner;
// - the page's host, on every tile, and private: in the tooltip;
// - the close cross, on the tab you're on only, in its top-leading corner
//   and only once the pointer has stayed a moment (crossDwell): passing
//   over a 32 pt tile, or clicking it for the address, must not close it.
// A pair (Split View) is one tile with both marks, one over the other; a
// group is a short heading with the group's first letter, its tiles held by
// a thin bracket.

extension Metrics {
    /// The column of icons: a tile's 32 and 10 either side.
    static let iconColumn: CGFloat = 52
    /// One tab's tile in it, and one pinned square's.
    static let iconTile: CGFloat = 32
    /// The band the three traffic lights take, stacked, at its top
    /// (Lights.stackTop and their own spacing, and the same air under them).
    static let iconLights: CGFloat = 80
}

/// What the tiles say, for the bench (`icons`): where each one is, its
/// tooltip, and whether it is a tile at all. Test runs only.
@MainActor
enum IconTiles {
    /// Each tab's tile as the one that speaks for it last measured it.
    static var frames: [Tab.ID: CGRect] {
        owner.compactMapValues { measured[$0]?.frame }
    }
    static var tips: [Tab.ID: String] {
        owner.compactMapValues { measured[$0]?.tip }
    }
    static var pairs: [Tab.ID: Tab.ID] = [:]
    /// Which of a tab's tiles speaks for it: the one that came last. When a
    /// tab joins a pair or leaves one, the old tile goes as the new comes,
    /// in either order, and keeps reporting while it animates away.
    private static var owner: [Tab.ID: UUID] = [:]
    /// What every tile up last said of itself, the old ones included.
    private static var measured: [UUID: (frame: CGRect, tip: String)] = [:]

    static func frame(of tile: UUID) -> CGRect? { measured[tile]?.frame }

    static func appeared(_ id: Tab.ID, tile: UUID) {
        guard Store.testing else { return }
        owner[id] = tile
    }

    static func seen(_ id: Tab.ID, tile: UUID, frame: CGRect, tip: String) {
        guard Store.testing else { return }
        // Measured before it said it appeared: it is the one.
        if owner[id] == nil { owner[id] = tile }
        measured[tile] = (frame, tip)
    }

    static func gone(_ id: Tab.ID, tile: UUID) {
        guard Store.testing else { return }
        measured[tile] = nil
        guard owner[id] == tile else { return }
        owner[id] = nil
        pairs[id] = nil
    }

    /// The tooltip: the title, then where the page is — on every tile, as
    /// a tile has no room to say it (X, 26 Nov) — and what a row would have
    /// said beside it.
    static func tip(_ tab: Tab, address: AtRest?) -> String {
        var lines = [tab.label.isEmpty ? "New Tab" : tab.label]
        if let address { lines.append(address.text) }
        var marks: [String] = []
        if tab.shy { marks.append("Private") }
        if tab.recording { marks.append("Recording") }
        if !tab.loading && tab.muted { marks.append("Muted") } else if !tab.loading && tab.noisy { marks.append("Playing sound") }
        if !marks.isEmpty { lines.append(marks.joined(separator: " · ")) }
        return lines.joined(separator: "\n")
    }
}

/// One tab as a tile of the column of icons.
struct IconTile: View {
    @Environment(\.greys) private var greys
    @Environment(\.tabShortcutNumbers) private var shortcutNumbers
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    @ObservedObject var tab: Tab
    let live: Bool
    let pill: Namespace.ID
    let close: () -> Void
    var interactive = true
    /// Half of a pair: the pair's tile draws the ground and the edge.
    var half = false

    @State private var hovering = false
    /// Over the cross itself, which reaches past the tile's corner.
    @State private var overCross = false
    /// The pointer has stayed long enough for the cross (crossDwell).
    @State private var dwelled = false
    @State private var selectedOnPress = false
    @State private var pressed = false
    /// This tile, for the bench's list of them (IconTiles).
    @State private var me = UUID()

    private var tip: String { IconTiles.tip(tab, address: AtRest.said(tab.restAddress, always: true)) }
    private var speaker: Bool { !tab.loading && (tab.noisy || tab.muted) }
    private var closable: Bool { interactive && live && tab.pin == nil }
    private var crossShows: Bool { closable && dwelled && (hovering || overCross) }

    /// How long the pointer stays on the tab you're on before its cross
    /// shows: a pass over the column, or a click for the address, is quicker.
    static let crossDwell: Duration = .milliseconds(500)
    /// The cross, in the tile's terms: a small disc on its top-leading
    /// corner, a little past it, as the speaker sits on the bottom-trailing
    /// one. It takes presses there only — never the middle, where a click
    /// is for the tab (the field with its address, on the tab you're on).
    static let crossFrame = CGRect(x: -3, y: -3, width: 13, height: 13)

    var body: some View {
        let _ = Bench.count("row")
        ZStack {
            if interactive, let number = shortcutNumbers[tab.id] {
                TabShortcutNumber(number: number)
            } else if tab.loading {
                Ring()
            } else if tab.isBlank {
                Image(systemName: "plus.magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(live ? Palette.ink : Palette.muted)
            } else {
                // The strip shows what the rows with titles would, letters
                // or icons; icons only has always shown icons.
                Mark(icon: prefs.narrowStrip && prefs.glyph == .letters ? nil : tab.icon, letter: tab.monogram, size: 16, dim: tab.asleep)
                    .opacity(live || hovering ? 1 : 0.85)
            }
        }
        .frame(width: Metrics.iconTile, height: Metrics.iconTile)
        // Only the tab already on screen wears a cross, so picking another
        // tile cannot close it with that same press; and only after the
        // dwell, in the corner, so neither can a click for its address.
        .overlay(alignment: .topLeading) {
            if closable { cross }
        }
        .overlay(alignment: .topTrailing) {
            if tab.recording {
                Circle()
                    .fill(Color(nsColor: .systemRed))
                    .frame(width: 6, height: 6)
                    .overlay(Circle().strokeBorder(Palette.ground, lineWidth: 1))
                    .padding(4)
                    .allowsHitTesting(false)
            } else if browser.peekFrom == tab.id, let page = browser.peekTab {
                PeekBadge(page: page, size: 12).padding(1)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if speaker { CornerSpeaker(tab: tab) }
        }
        .background { if !half { ground.animation(Motion.quick, value: live) } }
        .overlay {
            if browser.selectedTabIDs.contains(tab.id) {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Palette.ink.opacity(0.35), lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
        .modifier(Give(pressed: pressed && prefs.tabsGive))
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .modifier(TabPress(enabled: interactive && !browser.isPickedAmongOthers(tab), active: live, selected: $selectedOnPress, pressing: $pressed) {
            browser.clearTabSelection()
            browser.select(tab)
        })
        .modifier(OneClick(double: live) {
            guard interactive, !selectedOnPress, TabClick.flags.intersection([.command, .shift, .option]).isEmpty else { return }
            browser.clearTabSelection()
            // The tile you're on has no room for its address: a click opens
            // the field over the page, as ⌘L does in this column.
            if live { browser.beginTabEdit(tab) } else { browser.select(tab) }
        })
        .modifier(ModifiedTabClick { if interactive { browser.extendTabSelection(to: tab, modifiers: $0) } })
        .modifier(OptionClick { if interactive { browser.optionClick(tab) } })
        .overlay { if interactive { MiddleClick(act: close) } }
        .onHover { over in hovering = over }
        .task(id: closable && (hovering || overCross)) {
            guard closable && (hovering || overCross) else { dwelled = false; return }
            try? await Task.sleep(for: Self.crossDwell)
            if !Task.isCancelled { dwelled = true }
        }
        .onAppear {
            guard interactive else { return }
            Bench.rowAppeared(tab.id, hover: { hovering = $0 })
            IconTiles.appeared(tab.id, tile: me)
        }
        .onDisappear {
            guard interactive else { return }
            Bench.rowDisappeared(tab.id)
            IconTiles.gone(tab.id, tile: me)
        }
        // Another space's tab come into this tile (Browser.rowKey): the
        // tile is the same, where it is too, and now stands for that tab.
        .onChange(of: tab.id) { was, now in
            guard interactive else { return }
            let frame = IconTiles.frame(of: me)
            Bench.rowDisappeared(was)
            IconTiles.gone(was, tile: me)
            Bench.rowAppeared(now, hover: { hovering = $0 })
            IconTiles.appeared(now, tile: me)
            if let frame { IconTiles.seen(now, tile: me, frame: frame, tip: tip) }
        }
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { frame in
            if interactive { IconTiles.seen(tab.id, tile: me, frame: frame, tip: tip) }
        }
        .onChange(of: tip) { _, tip in
            if interactive, let frame = IconTiles.frame(of: me) { IconTiles.seen(tab.id, tile: me, frame: frame, tip: tip) }
        }
        .contextMenu { if interactive { TabMenu(browser: browser, tab: tab, close: close) } }
        // A tile has no address to open: its card hangs from it (ideas 1081, 1118).
        .modifier(SiteCardPanel.Square(id: tab.id, on: interactive))
        .background {
            if interactive && prefs.splitView && !half {
                SplitDropZone(browser: browser, tab: tab, kind: .strip)
            }
        }
        // The title, after the system's tooltip delay. Nothing else comes
        // out under the pointer: no title sliding out, no column widening.
        .help(tip)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tip)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Close tab") { if interactive { close() } }
        .animation(nil, value: hovering)
        .animation(Motion.quick, value: crossShows)
        .animation(Motion.quick, value: tab.loading)
        .animation(Motion.quick, value: speaker)
        .animation(Motion.quick, value: tab.recording)
        .transition(.scale(scale: 0.9).combined(with: .opacity))
    }

    /// Put away rather than closed, in a group (Browser.closeTab).
    private var cross: some View {
        Image(systemName: browser.putsAway(tab) ? "minus" : "xmark")
            .font(.system(size: 6.5, weight: .bold))
            .foregroundStyle(Palette.muted)
            .frame(width: Self.crossFrame.width, height: Self.crossFrame.height)
            .background(Palette.ground, in: Circle())
            .overlay(Circle().strokeBorder(Palette.hairline, lineWidth: 0.5))
            .opacity(crossShows ? 1 : 0)
            .overlay { CloseClick(armed: crossShows, act: close) }
            .contentShape(Circle())
            .onHover { over in overCross = over && dwelled }
            .offset(x: Self.crossFrame.minX, y: Self.crossFrame.minY)
    }

    @ViewBuilder
    private var ground: some View {
        if live {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(greys.pinLive)
                .modifier(LiveMatch(id: LivePill.id(browser), in: pill))
        } else if browser.selectedTabIDs.contains(tab.id) {
            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(greys.wash)
        } else if hovering {
            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(greys.hover)
        }
    }
}

/// The speaker of a tile: small, in its bottom corner, on a disc of the
/// column's ground so it reads over any mark. A press mutes or unmutes.
private struct CornerSpeaker: View {
    @ObservedObject var tab: Tab

    var body: some View {
        Button(action: tab.toggleMute) {
            Image(systemName: tab.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 6.5))
                .foregroundStyle(Palette.muted)
                .frame(width: 13, height: 13)
                .background(Palette.ground, in: Circle())
                .overlay(Circle().strokeBorder(Palette.hairline, lineWidth: 0.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(tab.muted ? "Unmute Tab" : "Mute Tab")
        .offset(x: 3, y: 3)
    }
}

/// A split as one tile: its marks, one over the other — two to four —
/// inside one edge. Each half is pressed on its own, as a half of a split's
/// row is.
struct IconPair: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    /// Its pages, in order. Each half watches its own.
    let pages: [Tab]
    let live: Bool
    var focusedID: Tab.ID? = nil
    let interactive: Bool
    let pill: Namespace.ID

    @Environment(\.greys) private var greys
    /// Carried and about to come apart: the half that stays dims.
    @ObservedObject private var separation = PairSeparation.shared

    private var focused: Tab.ID? { live ? (focusedID ?? browser.activeID) : nil }
    private var first: Tab.ID? { pages.first?.id }
    private var last: Tab.ID? { pages.last?.id }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(pages) { tab in half(tab) }
        }
        .animation(Motion.quick, value: separation.leaving)
        .background {
            // The split's own ground, lighter than the live grey that sits on
            // the half the keys go to.
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(live ? greys.wash : greys.tile)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Palette.hairline, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .onAppear { if interactive && Store.testing, let first, let last { IconTiles.pairs[first] = last } }
        .onDisappear {
            if interactive && Store.testing, let first, let last, IconTiles.pairs[first] == last { IconTiles.pairs[first] = nil }
        }
        // Another space's pair come into this place (Browser.rowKey).
        .onChange(of: [first, last]) { was, now in
            guard interactive && Store.testing else { return }
            if let a = was[0], let b = was[1], IconTiles.pairs[a] == b { IconTiles.pairs[a] = nil }
            if let a = now[0], let b = now[1] { IconTiles.pairs[a] = b }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Split tabs")
    }

    private func half(_ tab: Tab) -> some View {
        IconTile(browser: browser, prefs: prefs, tab: tab, live: focused == tab.id, pill: pill,
                 close: { browser.closeTab(tab) }, interactive: interactive, half: true)
            .opacity(separation.leaving.map { leaving in leaving != tab.id && pages.contains { $0.id == leaving } } == true ? 0.35 : 1)
            .background {
                if focused == tab.id {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(greys.pinLive)
                        .padding(2)
                        .modifier(LiveMatch(id: LivePill.id(browser), in: pill))
                }
            }
    }
}

/// A group in the column of icons: its first letter, small, where the row
/// had its name — pressed to fold or unfold it, the name in its tooltip,
/// its menu and drop as the heading's (GroupHeading).
struct IconGroupBracket: View {
    let folded: Bool

    var body: some View {
        // The bracket down the tiles' leading edge, from the heading to the
        // last of them: thin, the hairline's grey a little darker.
        Capsule()
            .fill(Palette.ink.opacity(0.18))
            .frame(width: 2)
            .opacity(folded ? 0 : 1)
            .allowsHitTesting(false)
    }
}
