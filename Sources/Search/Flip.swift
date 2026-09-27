import AppKit
import SwiftUI

// ⌃Tab as Arc has it, with Settings › Tabs › ⌃Tab goes to the tab you were
// just on.
//
// Walking along the row answers "what is next to this tab", which is almost
// never the question. The one people ask is "where was I a moment ago", and
// its answer is the order tabs were last looked at: one ⌃Tab goes back, a
// second comes forward again, and two tabs you are working between are always
// one keystroke apart however far apart they sit in the row.
//
// With spaces on, every space is a row of its own, in the order ⌃1–⌃9 go,
// starting on the one you're in. Tab and the side arrows move along a row;
// the up and down arrows shift into the space above or below, like a gear
// going into the next slot of the gate, and stop at the end of it rather than
// coming round. Each row keeps its own place, and one you haven't walked yet
// starts on the tab that space was showing when you left it, so letting go of
// ⌃ there is ⌃2 with a look before you jump.
//
// The order is fixed when ⌃Tab is first pressed and kept for the whole walk,
// so pressing Tab again moves down a list that stays still under you. Nothing
// is chosen until ⌃ is let go of, the same bargain as ⌘Tab between apps: a
// tab passed over on the way isn't woken, isn't touched, and doesn't jump to
// the front of the order.

/// A space's row in the switcher: its tabs, most recent first, fixed when
/// the walk began.
struct FlipRow {
    let space: Space
    let tabs: [Tab.ID]
}

/// A card's place in the switcher.
struct FlipSpot: Hashable {
    let row: Int
    let col: Int
}

extension Browser {
    var flipOpen: Bool { flipRows != nil }

    /// A row's tabs, in its order. A tab that closes while the switcher is up
    /// drops out of it.
    func flipTabs(_ row: Int) -> [Tab] {
        guard let rows = flipRows, rows.indices.contains(row) else { return [] }
        let id = rows[row].space.id
        let pool = id == spaceID ? tabs : parked[id]?.tabs ?? []
        return rows[row].tabs.compactMap { tab in pool.first { $0.id == tab } }
    }

    /// The tab a row is showing first, then the rest by when you last had
    /// them: `touched` is set on the way out of a tab as well as the way in
    /// (see `activeID`).
    private func recent(_ list: [Tab], first: Tab.ID?) -> [Tab.ID] {
        list.sorted { a, b in
            if a.id == first { return b.id != first }
            if b.id == first { return false }
            return a.touched > b.touched
        }
        .map(\.id)
    }

    /// ⌃Tab, and ⌃⇧Tab the other way: the first press starts the walk one
    /// tab down from where you are, each one after moves it along the row.
    func flip(_ direction: Int) {
        if flipRows == nil {
            guard let here = activeID else { return }
            let spaced = prefs.usesSpaces && spaces.count > 1
            // A space not visited since launch has no row made yet.
            if spaced { preloadSpaces() }
            let rows = (spaced ? spaces : [space]).map { each in
                each.id == spaceID
                    ? FlipRow(space: each, tabs: recent(tabs, first: here))
                    : FlipRow(space: each, tabs: recent(parked[each.id]?.tabs ?? [], first: parked[each.id]?.active))
            }
            let start = rows.firstIndex { $0.space.id == spaceID } ?? 0
            // Somewhere to go: another tab here, or another space.
            guard rows[start].tabs.count > 1 || rows.count > 1 else { return }
            // The picture of the one you're on is taken now, since nothing
            // has left it yet.
            active?.glimpse()
            flipRows = rows
            flipRow = start
            flipAt = 0
            flipCols = Array(repeating: 0, count: rows.count)
            let show = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.flipOpen else { return }
                    self.flipShown = true
                }
            }
            flipWait = show
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: show)
        }
        let count = flipTabs(flipRow).count
        guard count > 0 else { return }
        flipByPointer = false
        flipAt = ((flipAt + direction) % count + count) % count
    }

    /// ↑ and ↓: into the space above or below, where that row was left, and
    /// nowhere past the first or the last. With one row there is nothing to
    /// shift into, and they move along it as the side arrows do.
    func shiftFlip(_ direction: Int) {
        guard let rows = flipRows else { return }
        guard rows.count > 1 else { return flip(direction) }
        let to = flipRow + direction
        guard rows.indices.contains(to) else { return }
        flipByPointer = false
        flipCols[flipRow] = flipAt
        flipRow = to
        flipAt = min(flipCols[to], max(0, flipTabs(to).count - 1))
        // The notch. Felt only with a finger on a Force Touch trackpad, and
        // nothing at all otherwise, which is the right amount for a keyboard.
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }

    /// The pointer resting on a card: that card picked, row and all.
    func pointFlip(at spot: FlipSpot) {
        guard flipOpen, spot != FlipSpot(row: flipRow, col: flipAt) else { return }
        if spot.row != flipRow { flipCols[flipRow] = flipAt }
        flipByPointer = true
        flipRow = spot.row
        flipAt = spot.col
    }

    /// ⌃ let go of, or Return: go where the walk stopped. In another space's
    /// row that is the space first, then the tab; a space with no tabs is
    /// just the space.
    func landFlip() {
        guard let rows = flipRows, rows.indices.contains(flipRow) else { return endFlip() }
        let target = rows[flipRow].space.id
        let list = flipTabs(flipRow)
        let chosen = list.indices.contains(flipAt) ? list[flipAt].id : nil
        endFlip()
        if target != spaceID { switchSpace(to: target) }
        if let chosen, let tab = tabs.first(where: { $0.id == chosen }) { select(tab) }
    }

    /// A click while the switcher is up, at a point in the window's own
    /// top-left coordinates. On a card, that card, now; outside the panel,
    /// the switcher goes and the click carries on to whatever it was on.
    ///
    /// Caught before any view sees it (see ContentView.watchKeys), and matched
    /// against where the cards are rather than which one the pointer rests
    /// on: ⌃ is usually still down, and a ⌃-click is a right-click to AppKit,
    /// which a tap gesture never hears; and a card that came up under a still
    /// pointer has never been told the pointer is there. True when the click
    /// was the switcher's.
    func clickFlip(at point: CGPoint) -> Bool {
        guard flipShown else { return false }
        guard flipPlate.contains(point) else {
            endFlip()
            return false
        }
        // Between two cards: the switcher's, and nothing happens.
        guard let hit = flipCards.first(where: { $0.value.contains(point) })?.key else { return true }
        flipRow = hit.row
        flipAt = hit.col
        landFlip()
        return true
    }

    /// Escape, or another app coming to the front: back where it started,
    /// with nothing chosen.
    func endFlip() {
        flipWait?.cancel()
        flipWait = nil
        flipRows = nil
        flipRow = 0
        flipAt = 0
        flipCols = []
        flipByPointer = false
        flipShown = false
        flipPlate = .zero
        flipCards = [:]
    }
}

/// The switcher over the page: a row of cards, one a tab, or with spaces a
/// row for each, the one being walked in full and the rest held back. The
/// card the walk is on is outlined. Rows scroll sideways to keep it in view,
/// and the rows scroll too once there are more than fit.
///
/// The pointer walks it as well: resting on a card picks it, so letting go of
/// ⌃ there goes to it, and a click goes at once (see `clickFlip`). Resting
/// picks only once the pointer has moved. The panel comes up wherever the
/// pointer happens to be, and a card that lands under a still pointer would
/// otherwise take the walk from the keys before anyone reached for the mouse.
///
/// Only a key scrolls the picked card into view. Scrolling for the pointer
/// would slide the card out from under it, and put the next one there to be
/// picked in its place. For the same reason the rows change over quickly
/// under the pointer, and on the slower spring, the gear going in, only for
/// the arrows.
struct FlipPanel: View {
    @ObservedObject var browser: Browser
    /// Where the pointer was when the panel first felt it, and whether it has
    /// gone anywhere since.
    @State private var rest: CGPoint?
    @State private var moved = false

    /// Smaller with spaces, so three or four of them fit on a laptop screen.
    private var size: CGSize {
        (browser.flipRows?.count ?? 1) > 1 ? CGSize(width: 136, height: 85) : CGSize(width: 168, height: 105)
    }

    var body: some View {
        let rows = browser.flipRows ?? []
        ScrollViewReader { proxy in
            ViewThatFits(in: .vertical) {
                stack(rows)
                ScrollView(.vertical, showsIndicators: false) { stack(rows) }
            }
            .onAppear { proxy.scrollTo(FlipSpot(row: browser.flipRow, col: browser.flipAt), anchor: .center) }
            .onChange(of: FlipSpot(row: browser.flipRow, col: browser.flipAt)) { _, spot in
                guard !browser.flipByPointer else { return }
                withAnimation(Motion.glide) { proxy.scrollTo(spot, anchor: .center) }
            }
        }
        .background(Palette.ground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Palette.hairline, lineWidth: 1)
        )
        .background(GeometryReader { box in
            Color.clear.preference(key: Frames.self, value: [Frames.plate: box.frame(in: .global)])
        })
        .onPreferenceChange(Frames.self) { frames in
            MainActor.assumeIsolated {
                browser.flipPlate = frames[Frames.plate] ?? .zero
                browser.flipCards = frames.filter { $0.key != Frames.plate }
            }
        }
        .shadow(color: .black.opacity(0.18), radius: 28, y: 10)
        // One watcher for the whole panel, matching the pointer against where
        // the cards are, as a click is (see `clickFlip`): a card's own hover
        // under the panel's didn't always hear the pointer, and a row that
        // took clicks but never lit up said the opposite of what it did.
        .onContinuousHover(coordinateSpace: .global) { phase in
            guard case .active(let at) = phase else { return }
            if !moved {
                guard let rest else { return self.rest = at }
                guard abs(at.x - rest.x) + abs(at.y - rest.y) > 2 else { return }
                moved = true
            }
            guard let spot = browser.flipCards.first(where: { $0.value.contains(at) })?.key else { return }
            browser.pointFlip(at: spot)
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 40)
    }

    /// Each card's frame by its place, and the panel's own under a place no
    /// card has.
    private struct Frames: PreferenceKey {
        static let plate = FlipSpot(row: -1, col: -1)
        static let defaultValue: [FlipSpot: CGRect] = [:]
        static func reduce(value: inout [FlipSpot: CGRect], nextValue: () -> [FlipSpot: CGRect]) {
            value.merge(nextValue()) { $1 }
        }
    }

    private func stack(_ rows: [FlipRow]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(rows.enumerated()), id: \.element.space.id) { index, row in
                line(index, row, spaced: rows.count > 1)
            }
        }
        .padding(.vertical, rows.count > 1 ? 6 : 0)
        .animation(browser.flipByPointer ? Motion.quick : Motion.glide, value: browser.flipRow)
    }

    /// One space's row, under its icon and name when there are spaces.
    private func line(_ index: Int, _ row: FlipRow, spaced: Bool) -> some View {
        let here = index == browser.flipRow
        let tabs = browser.flipTabs(index)
        return VStack(alignment: .leading, spacing: 0) {
            if spaced {
                HStack(spacing: 6) {
                    Image(systemName: row.space.symbol)
                        .font(.system(size: 10, weight: .medium))
                    Text(row.space.name)
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(here ? Palette.ink : Palette.muted)
                .padding(.leading, 18)
                .padding(.top, 6)
            }
            ViewThatFits(in: .horizontal) {
                cards(tabs, row: index, here: here)
                ScrollView(.horizontal, showsIndicators: false) { cards(tabs, row: index, here: here) }
            }
        }
        // The rows not being walked, held back: there, and a notch away.
        .opacity(here ? 1 : 0.45)
    }

    private func cards(_ tabs: [Tab], row: Int, here: Bool) -> some View {
        HStack(spacing: 4) {
            if tabs.isEmpty {
                // A space with nothing open still has a place to land.
                Slide(tab: nil, glyph: browser.prefs.glyph, size: size, chosen: here)
                    .modifier(Spotted(spot: FlipSpot(row: row, col: 0)))
            }
            ForEach(Array(tabs.enumerated()), id: \.element.id) { col, tab in
                Slide(tab: tab, glyph: browser.prefs.glyph, size: size, chosen: here && col == browser.flipAt)
                    .modifier(Spotted(spot: FlipSpot(row: row, col: col)))
            }
        }
        .padding(8)
    }

    /// A card's place: named for scrolling to, and measured for the pointer
    /// to be matched against.
    private struct Spotted: ViewModifier {
        let spot: FlipSpot

        func body(content: Content) -> some View {
            content
                .id(spot)
                .background(GeometryReader { box in
                    Color.clear.preference(key: Frames.self, value: [spot: box.frame(in: .global)])
                })
        }
    }

    private struct Slide: View {
        let tab: Tab?
        let glyph: Glyph
        let size: CGSize
        let chosen: Bool

        var body: some View {
            if let tab {
                Face(tab: tab, glyph: glyph, size: size, chosen: chosen)
            } else {
                card(
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Palette.muted),
                    title: Text("No tabs").foregroundStyle(Palette.muted),
                    size: size,
                    chosen: chosen
                )
            }
        }
    }

    private struct Face: View {
        @ObservedObject var tab: Tab
        let glyph: Glyph
        let size: CGSize
        let chosen: Bool

        var body: some View {
            card(
                picture,
                title: HStack(spacing: 6) {
                    if glyph == .icons, !tab.isBlank {
                        Mark(icon: tab.icon, letter: tab.monogram, size: 13)
                    }
                    if tab.shy {
                        Image(systemName: "eye.slash")
                            .font(.system(size: 9))
                            .foregroundStyle(Palette.muted)
                    }
                    Text(tab.label)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(chosen ? Palette.ink : Palette.muted)
                },
                size: size,
                chosen: chosen
            )
        }

        /// The page as you last saw it, from the top. A tab never left since
        /// it opened, or one back from last session, has no picture yet and
        /// wears its icon large instead.
        @ViewBuilder
        private var picture: some View {
            if let glance = tab.glance {
                Image(nsImage: glance)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size.width, height: size.height, alignment: .top)
                    .clipped()
            } else {
                Mark(icon: tab.isBlank ? nil : tab.icon, letter: tab.monogram, size: 34)
            }
        }
    }
}

/// A card: a picture over a title, outlined when it is the one picked.
@MainActor
private func card(_ picture: some View, title: some View, size: CGSize, chosen: Bool) -> some View {
    VStack(alignment: .leading, spacing: 7) {
        picture
            .frame(width: size.width, height: size.height)
            .background(Palette.wash)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Palette.hairline, lineWidth: 1)
            )
        title
            .font(.system(size: 12))
            .frame(width: size.width, alignment: .leading)
    }
    .padding(8)
    .background(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(chosen ? Palette.wash : .clear)
    )
    .overlay(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(chosen ? Palette.faint : .clear, lineWidth: 1.5)
    )
    .contentShape(Rectangle())
    .animation(Motion.quick, value: chosen)
}
