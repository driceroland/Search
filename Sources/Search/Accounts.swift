import SwiftUI

/// What your card in Contacts offers for the box the caret is in, hanging
/// from it: under a box for your name, email, phone or address, one line per
/// detail, and a click fills the form. The same white and hairline as
/// everything else that floats over a page. ↓ and ↑ light a row from the
/// keyboard and Return takes it, as a click (App.swift's `take`). It follows
/// the box when the page scrolls, and goes when the caret does. Many rows:
/// the list is no taller than the room under the box, or above it when there
/// is more room there, and scrolls; a row lit from the keyboard is scrolled to.
struct AccountList: View {
    @ObservedObject var browser: Browser
    let asked: Browser.Suggesting
    /// Where the card came out in its host, for a host that has to know
    /// where it is to keep a click on it (see PaneStage's AccountHost).
    var onFrame: ((CGRect) -> Void)? = nil
    /// How far below the top of its host the page starts (a small window's
    /// bar): the box's spot is from the page's top-left.
    var top: CGFloat = 0

    /// Kept clear between the list and the host's edge.
    static let margin: CGFloat = 8
    /// Less room than this under the box, and more above it: the list goes
    /// above. Never shorter than this either, if the page is that small.
    static let least: CGFloat = 140

    /// Where the list goes for a box at `spot` on a page `height` tall:
    /// under it or above it, and how tall it may be.
    nonisolated static func place(spot: CGRect, height: CGFloat) -> (up: Bool, room: CGFloat) {
        let below = height - spot.maxY - 6 - margin
        let above = spot.minY - 6 - margin
        let up = below < least && above > below
        return (up, max(up ? above : below, least))
    }

    var body: some View {
        GeometryReader { space in
            let spot = asked.spot.offsetBy(dx: 0, dy: top)
            let place = Self.place(spot: spot, height: space.size.height)
            card(room: place.room)
                // Measured inside the offset, so where it is drawn, not laid out.
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(FromTopLeft<AccountList>.space)) }) { onFrame?($0) }
                // Above the box: its foot 6 points over the box's top.
                .frame(height: place.up ? max(0, spot.minY - 6) : nil, alignment: .bottom)
                // Just under the box (or over it), left edges lined up. The
                // offset is from the stage's top-left, which is also the web view's.
                .offset(x: spot.minX, y: place.up ? 0 : spot.maxY + 6)
        }
    }

    private func card(room: CGFloat) -> some View {
        Capped(room: room) {
        VStack(alignment: .leading, spacing: 0) {
            // As tall as the rows when they fit; otherwise they scroll under
            // a footer that stays.
            ScrollViewReader { scroller in
                ViewThatFits(in: .vertical) {
                    rows(marked: false)
                    ScrollView(.vertical) { rows(marked: true) }
                        .scrollIndicators(.automatic)
                }
                .onChange(of: asked.lit) { _, lit in
                    guard let lit else { return }
                    scroller.scrollTo(lit)
                }
            }
            do {
            HStack(spacing: 6) {
                Image(systemName: "person.crop.rectangle")
                    .font(.system(size: 9, weight: .medium))
                Text("From your card in Contacts")
                    .font(.system(size: 10.5))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Palette.faint)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Palette.wash.opacity(0.5))
            }
        }
        .frame(width: max(240, min(360, asked.spot.width)), alignment: .leading)
        }
        .background(Palette.ground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Palette.hairline, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.14), radius: 22, y: 8)
    }

    /// The rows in the order ↓ walks them (Suggesting.choices).
    /// `marked`: each row carries its number, for the scroller to find; only
    /// in the one that scrolls, so it never looks in the other.
    private func rows(marked: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            let choices = asked.choices
            ForEach(Array(choices.enumerated()), id: \.offset) { at, choice in
                if marked { row(choice, lit: asked.lit == at).id(at) } else { row(choice, lit: asked.lit == at) }
            }
        }
    }

    @ViewBuilder
    private func row(_ choice: Browser.Suggesting.Choice, lit: Bool) -> some View {
        switch choice {
        case .contact(let contact):
            // A click fills the form; a shift-click, the box alone.
            Row(mark: .symbol("person.crop.circle"), name: contact.title, detail: contact.detail, lit: lit) {
                browser.choose(contact, alone: NSEvent.modifierFlags.contains(.shift))
            }
            .help("Fills the form. Shift-click fills only this box.")
        }
    }

    private enum Mark { case letter(String), symbol(String) }

    /// Offers its content no more than `room` and is as tall as the content
    /// then is: a short list keeps its own height, a long one stops at
    /// `room` (where its rows scroll). `.frame(maxHeight:)` would make the
    /// short one `room` tall too.
    private struct Capped: Layout {
        let room: CGFloat

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            guard let only = subviews.first else { return .zero }
            let size = only.sizeThatFits(ProposedViewSize(width: proposal.width, height: room))
            return CGSize(width: size.width, height: min(size.height, room))
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
        }
    }

    private struct Row: View {
        let mark: Mark
        let name: String
        let detail: String
        /// Come to with ↓ and ↑: lit as under the pointer.
        var lit = false
        let pick: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: pick) {
                HStack(spacing: 10) {
                    Group {
                        switch mark {
                        case .letter(let letter): Text(letter).font(.system(size: 11, weight: .medium))
                        case .symbol(let name): Image(systemName: name).font(.system(size: 10, weight: .medium))
                        }
                    }
                    .foregroundStyle(Palette.ink)
                    .frame(width: 22, height: 22)
                    .background(Palette.wash, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(name)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Palette.ink)
                            .lineLimit(1)
                        Text(detail)
                            .font(.system(size: 10.5))
                            .foregroundStyle(Palette.muted)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(hovering || lit ? Palette.hover : .clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(Motion.quick, value: hovering)
        }
    }
}

extension Browser.Suggesting {
    /// One row of the list, which a click or Return on it picks.
    enum Choice: Equatable {
        case contact(MeCard.Offer)
    }

    /// The rows top to bottom, as drawn and as ↓ walks them.
    var choices: [Choice] { contacts.map(Choice.contact) }
}
