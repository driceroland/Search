import SwiftUI

// The address above the page, with the tabs down a side, as Chrome lays it
// out: back, forward and reload before it, the extensions after it, in a
// row of its own across the top of the page. Off unless asked for
// (Settings › Appearance › Window › Always show the address bar, then
// Above the page). The column gives those up while the row has them, so
// each is in one place only: an extension's popup hangs from the one
// button there is (ExtensionSlot).
//
// With the page as a card, the row is inside the card, over the page: the
// card's top (CardHead) rounds above it and the page's own edge is the line
// between the two, so the page and its address read as one thing and the
// window's grey is only the gap around them, not a band across the top.
// Two pages side by side hang under the one head, a card each. Its middle
// is on the lights' line, so it still reads as one title bar with the
// column's top row. Edge to edge it
// has its own ground and is as tall as the column's top row. It stays when
// the column folds away (⌘S), as Chrome's does with no tabs to show; a page
// filling the screen takes it away.

struct Toolbar: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    var ground = RowGround.own
    /// The air at its ends: none over a card it stands beside, whose edges
    /// the row lines up with; inside a card or edge to edge, some.
    var air: CGFloat = 10

    /// The column's top row's height (Metrics.strip).
    static let height: CGFloat = Metrics.strip
    /// Inside the card, from the card's top down, centred on the lights'
    /// line as the column's top row is.
    static let inCard: CGFloat = 2 * (Metrics.strip / 2 - Metrics.cardGap)
    /// The address field: a tab's height, as it is in the column.
    private static let field: CGFloat = 28

    var body: some View {
        HStack(spacing: 8) {
            if prefs.helmDoors > 0 { Helm(browser: browser) }
            AddressLine(browser: browser, height: Toolbar.field)
                // Its suggestions hang over the page below.
                .zIndex(1)
            ExtensionSlot(browser: browser, edge: .bottom, puzzle: !prefs.hidesExtensionsDoor)
        }
        .padding(.horizontal, air)
        .frame(height: ground == .card ? Toolbar.inCard : Toolbar.height)
        .frame(maxWidth: .infinity)
        // Title bar above and below the row's controls, as the column's top
        // row is: a press there moves the window and a double-click does
        // what the title bar's does. The band the controls sit in is theirs.
        .background(DragStrip(reserved: .greatestFiniteMagnitude, band: 30))
        .background {
            ZStack(alignment: .bottom) {
                // In the card, the card's own ground (CardEdge); on glass
                // the window's shows through (Glass.swift).
                if ground != .card, !browser.glassy { ground == .frame ? Palette.frame : Palette.ground }
                // The space's wash carried on under it, as under the column.
                if ground != .card, !browser.glassy { SpaceWash(look: browser.wash) }
                // Under the row, not over it: the suggestions hang across
                // this line and on down over the page. Beside or inside a
                // card, the card's edge is the line.
                if ground == .own { Rectangle().fill(Palette.hairline).frame(height: 1) }
            }
        }
        .environment(\.greys, ground == .frame ? .frame : .white)
    }
}

/// The page's card's top, above the page, under the rows inside it: the
/// card's ground with its top corners round and its edge down the sides,
/// as CardEdge draws the card's. Not along its foot: the page's own edge
/// (the stage's cards) is the line between the rows and the page, so it
/// isn't doubled, and two pages side by side show the window's grey
/// between them under the one head.
struct CardHead: View {
    /// The screen's scale, for a hairline one pixel wide (CardEdge).
    let scale: CGFloat

    var body: some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: Metrics.cardRadius,
                                           topTrailingRadius: Metrics.cardRadius, style: .continuous)
        let line = 1 / max(scale, 1)
        shape
            .fill(Palette.ground)
            .overlay {
                shape
                    .strokeBorder(Color.primary.opacity(CardEdge.edge), lineWidth: line)
                    .mask(alignment: .top) { Rectangle().padding(.bottom, line) }
            }
            .allowsHitTesting(false)
    }
}
