import SwiftUI

// ⌃Tab, the way Arc and Dia do it: every tab as a picture, the one on screen
// first and the walk already on the one before it, so a tap of ⌃Tab flicks
// back to wherever you just were. Held, Tab walks on and ⇧Tab walks back;
// letting go of ⌃ goes where the walk stopped. The pointer walks too: a card
// it moves onto is the one letting go takes, and a click goes at once. esc
// puts it away. ⇧⌘[ and ⇧⌘] still walk the row in its own order.
//
// The order is read once, when the panel opens: a list that reshuffled under
// the walk would never land where you meant.

struct Switcher: Equatable {
    /// The tabs, most recently looked at first.
    var order: [Tab.ID]
    /// Which one the walk is on.
    var at: Int
    /// Where the pointer was when the panel came up. A card that merely
    /// appeared under a resting pointer isn't one it moved onto.
    var pointer: CGPoint
}

extension Browser {
    /// ⌃Tab, and ⌃⇧Tab: open on the tab before this one, or take one more step.
    func flip(_ direction: Int) {
        guard var shown = switcher ?? opened() else { return }
        shown.at = (shown.at + direction + shown.order.count) % shown.order.count
        switcher = shown
    }

    /// ⌃ let go of: the tab the walk stopped on.
    func landFlip() {
        guard let shown = switcher else { return }
        switcher = nil
        if let tab = tabs.first(where: { $0.id == shown.order[shown.at] }) { select(tab) }
    }

    /// The pointer moved onto a card: that is the one letting go of ⌃ takes.
    func point(at id: Tab.ID) {
        guard var shown = switcher, NSEvent.mouseLocation != shown.pointer,
              let index = shown.order.firstIndex(of: id), index != shown.at
        else { return }
        shown.at = index
        switcher = shown
    }

    private func opened() -> Switcher? {
        guard tabs.count > 1 else { return nil }
        // Every page with a view pictured afresh — at the stage's size, for
        // one opened behind and never shown. One asleep keeps the picture it
        // had; one not opened since launch shows its icon.
        let stage = active?.built?.frame.size
        tabs.forEach { $0.capture(stage: stage) }
        let rest = tabs.filter { $0.id != activeID }.sorted { $0.touched > $1.touched }
        return Switcher(order: ((active.map { [$0] } ?? []) + rest).map(\.id), at: 0, pointer: NSEvent.mouseLocation)
    }
}

/// The panel: cards five across, centred on the window, dark whatever the
/// window is — it is over every kind of page at once.
struct SwitcherPanel: View {
    @ObservedObject var browser: Browser
    let shown: Switcher

    private static let gap: CGFloat = 2

    var body: some View {
        let tabs = shown.order.compactMap { id in browser.tabs.first { $0.id == id } }
        let chosen = shown.order[shown.at]
        GeometryReader { room in
            // Five cards across nine tenths of the window, fewer when they
            // would come out smaller than a card can be read at.
            let span = room.size.width * 0.93
            let across = max(1, min(5, Int(span / 170)))
            let width = min(300, (span - Self.gap * CGFloat(across - 1)) / (CGFloat(across) + 0.1))
            let inset = width * 0.048
            let columns = min(across, tabs.count)
            let rows = (tabs.count + across - 1) / across
            let height = TabCard.height(width)
            let fit = max(1, Int((room.size.height * 0.86 - 2 * inset) / (height + Self.gap)))

            ScrollViewReader { scroller in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.fixed(width), spacing: Self.gap), count: columns),
                        spacing: Self.gap
                    ) {
                        ForEach(tabs) { tab in
                            TabCard(tab: tab, chosen: tab.id == chosen, width: width)
                                .id(tab.id)
                                .onContinuousHover { phase in
                                    if case .active = phase { browser.point(at: tab.id) }
                                }
                                .onTapGesture {
                                    browser.switcher = nil
                                    browser.select(tab)
                                }
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(
                    width: CGFloat(columns) * width + CGFloat(columns - 1) * Self.gap,
                    height: CGFloat(min(rows, fit)) * (height + Self.gap) - Self.gap
                )
                .onAppear { scroller.scrollTo(chosen) }
                .onChange(of: chosen) { _, id in scroller.scrollTo(id) }
            }
            .padding(inset)
            .background {
                RoundedRectangle(cornerRadius: width * 0.1, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: width * 0.1, style: .continuous)
                            .fill(Color(white: 0.08).opacity(0.9))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: width * 0.1, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.35), radius: 40, y: 14)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .environment(\.colorScheme, .dark)
    }
}

/// One tab: its picture, and under it its icon and name, on a lighter ground
/// when it is the one the walk is on.
private struct TabCard: View {
    @ObservedObject var tab: Tab
    let chosen: Bool
    let width: CGFloat

    /// Proportions measured off Dia's, so the card is the same at any size.
    static func height(_ width: CGFloat) -> CGFloat {
        let pad = width * 0.045
        return pad + (width - 2 * pad) * 0.68 + width * 0.2
    }

    var body: some View {
        let pad = width * 0.045
        let inner = width - 2 * pad
        let corner = width * 0.036
        VStack(spacing: 0) {
            picture
                .frame(width: inner, height: inner * 0.68, alignment: .top)
                .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
                )
            HStack(spacing: width * 0.04) {
                Mark(icon: tab.icon, letter: tab.monogram, size: width * 0.095)
                Text(tab.label)
                    .font(.system(size: width * 0.082, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.94))
                    .lineLimit(1)
                    .fixedSize()
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    .clipped()
                    // Faded out rather than cut with an ellipsis, as Dia does.
                    .mask(
                        LinearGradient(
                            stops: [.init(color: .black, location: 0.82), .init(color: .clear, location: 1)],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
            }
            .padding(.horizontal, width * 0.025)
            .frame(width: inner, height: width * 0.2)
        }
        .padding([.horizontal, .top], pad)
        .background(
            RoundedRectangle(cornerRadius: width * 0.058, style: .continuous)
                .fill(Color.white.opacity(chosen ? 0.3 : 0))
        )
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var picture: some View {
        if let thumb = tab.thumb {
            Image(nsImage: thumb)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            // Never opened since launch, or nothing to show yet: the icon on
            // a quiet ground rather than a white rectangle.
            ZStack {
                Color.white.opacity(0.05)
                Mark(icon: tab.icon, letter: tab.monogram, size: width * 0.16)
            }
        }
    }
}
