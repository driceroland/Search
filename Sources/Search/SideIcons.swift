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
// - the address the row says at rest, and private: in the tooltip.
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

    /// The tooltip: the title, then what a row would have said beside it.
    static func tip(_ tab: Tab, address: AtRest?) -> String {
        var lines = [tab.label.isEmpty ? "New Tab" : tab.label]
        if let address { lines.append(address.lead + address.name + address.tail) }
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
    @State private var selectedOnPress = false
    @State private var pressed = false
    /// This tile, for the bench's list of them (IconTiles).
    @State private var me = UUID()

    private var rest: AtRest? { live ? AtRest.said(tab.restAddress, always: prefs.showsAddress) : nil }
    private var tip: String { IconTiles.tip(tab, address: rest) }
    private var speaker: Bool { !tab.loading && (tab.noisy || tab.muted) }
    private var closable: Bool { interactive && live && tab.pin == nil }

    var body: some View {
        let _ = Bench.count("row")
        ZStack {
            if closable && hovering {
                // Put away rather than closed, in a group (Browser.closeTab).
                Image(systemName: browser.putsAway(tab) ? "minus" : "xmark")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Palette.muted)
                    .frame(width: 15, height: 15)
                    .background(Palette.ink.opacity(0.07), in: Circle())
            } else if interactive, let number = shortcutNumbers[tab.id] {
                TabShortcutNumber(number: number)
            } else if tab.loading {
                Ring()
            } else if tab.isBlank {
                Image(systemName: "plus.magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(live ? Palette.ink : Palette.muted)
            } else {
                Mark(icon: tab.icon, letter: tab.monogram, size: 16, dim: tab.asleep)
                    .opacity(live || hovering ? 1 : 0.85)
            }
        }
        .frame(width: Metrics.iconTile, height: Metrics.iconTile)
        // Only the tab already on screen wears a cross, so picking another
        // tile cannot close it with that same press.
        .overlay {
            if closable {
                CloseClick(armed: hovering, act: close)
                    .frame(width: 22, height: 22)
            }
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
        .modifier(TabPress(enabled: interactive, active: live, selected: $selectedOnPress, pressing: $pressed) {
            browser.clearTabSelection()
            browser.select(tab)
        })
        .modifier(OneClick(double: live) {
            guard interactive, !selectedOnPress, NSEvent.modifierFlags.intersection([.command, .shift]).isEmpty else { return }
            browser.clearTabSelection()
            // The tile you're on has no room for its address: a click opens
            // the field over the page, as ⌘L does in this column.
            if live { browser.beginTabEdit(tab) } else { browser.select(tab) }
        })
        .modifier(ModifiedTabClick { if interactive { browser.extendTabSelection(to: tab, modifiers: $0) } })
        .overlay { if interactive { MiddleClick(act: close) } }
        .onHover { over in hovering = over }
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
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { frame in
            if interactive { IconTiles.seen(tab.id, tile: me, frame: frame, tip: tip) }
        }
        .onChange(of: tip) { _, tip in
            if interactive, let frame = IconTiles.frame(of: me) { IconTiles.seen(tab.id, tile: me, frame: frame, tip: tip) }
        }
        .contextMenu { if interactive { TabMenu(browser: browser, tab: tab, close: close) } }
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
        .animation(Motion.quick, value: hovering)
        .animation(Motion.quick, value: tab.loading)
        .animation(Motion.quick, value: speaker)
        .animation(Motion.quick, value: tab.recording)
        .transition(.scale(scale: 0.9).combined(with: .opacity))
    }

    @ViewBuilder
    private var ground: some View {
        if live {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(greys.pinLive)
                .matchedGeometryEffect(id: "live", in: pill)
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

/// A pair as one tile: its two marks, one over the other, inside one edge.
/// Each half is pressed on its own, as a half of a pair's row is.
struct IconPair: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    @ObservedObject var left: Tab
    @ObservedObject var right: Tab
    let live: Bool
    var focusedID: Tab.ID? = nil
    let interactive: Bool
    let pill: Namespace.ID

    @Environment(\.greys) private var greys

    private var focused: Tab.ID? { live ? (focusedID ?? browser.activeID) : nil }

    var body: some View {
        VStack(spacing: 0) {
            half(left)
            half(right)
        }
        .background {
            // The pair's own ground, lighter than the live grey that sits on
            // the half the keys go to.
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(live ? greys.wash : greys.tile)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Palette.hairline, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .onAppear { if interactive && Store.testing { IconTiles.pairs[left.id] = right.id } }
        .onDisappear { if interactive && Store.testing && IconTiles.pairs[left.id] == right.id { IconTiles.pairs[left.id] = nil } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Split tabs")
    }

    private func half(_ tab: Tab) -> some View {
        IconTile(browser: browser, prefs: prefs, tab: tab, live: focused == tab.id, pill: pill,
                 close: { browser.closeTab(tab) }, interactive: interactive, half: true)
            .background {
                if focused == tab.id {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(greys.pinLive)
                        .padding(2)
                        .matchedGeometryEffect(id: "live", in: pill)
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
