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
    /// On the window's ground, beside the page's card (see CardEdge): the
    /// ground's colour and no edge of its own, the card's edge being the line.
    var onFrame = false
    /// The greys for that ground, handed down to every row, pin and door.
    private var greys: Greys { onFrame ? .frame : .white }

    @Namespace var pill
    /// The agent's session: its folder sits under the pins in every space.
    @ObservedObject var agent = Agent.shared

    @State private var landing = false
    /// The width the column had when the edge was picked up.
    @State private var grabbed: CGFloat?
    @State private var onEdge = false

    /// A pin, picked up out of the grid — a separate state from the loose
    /// rows above, since the two gestures never happen at once but move on
    /// two different axes.
    /// The neighbouring spaces' own grey, apart from this one's.
    @Namespace var before
    @Namespace var after

    /// A tab carried over the pins, or a pin over the tabs, and where it
    /// would land (see PinDrop).
    @State var crossing: PinDrop.Crossing?
    /// A folder carried by its row, and where it would go (see placing).
    @State var placing: PinDrop.Place?
    /// Where the blocks are, for working that out.
    @State var frames = ColumnFrames()
    /// Whether this space's rows fit under the pins without scrolling: set
    /// only when the answer changes, from the room under the pins and what
    /// the rows add up to, which are kept where changing them draws nothing.
    @State var fits = true
    @State var room = Room()
    final class Room {
        var height: CGFloat = .infinity
        var needed: CGFloat = 0
    }

    /// A tab's line: taller with roomier tabs turned on.
    var rowHeight: CGFloat { prefs.sideRow }
    static let gap: CGFloat = 2
    private static let foldDoorWidth: CGFloat = 230
    static let pinGap: CGFloat = 4

    private var onRight: Bool { prefs.sidePosition == .right }
    private var innerEdge: Alignment { onRight ? .leading : .trailing }

    /// The window's buttons' corner: gone in full screen, where macOS takes
    /// them away, and back, forward and reload move up to the edge (idea 184).
    private var lights: CGFloat {
        browser.fullScreen ? 0 : max(0, min(Metrics.sideLights, prefs.sideWidth - 20 - Metrics.helmDoors))
    }

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
                    // Folds the column away, as ⌘S does; no room for it in a
                    // column narrowed to its least.
                    if prefs.sideWidth >= SideBar.foldDoorWidth {
                        Door(icon: onRight ? "sidebar.right" : "sidebar.left", help: "Hide Sidebar") { browser.toggleFold() }
                    }
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
        .environment(\.greys, greys)
        .frame(width: prefs.sideWidth)
        .frame(maxHeight: .infinity)
        // Rows on their way to or from another space stay in the column.
        .clipped()
        .onAppear { SpaceSwipe.shared.start(for: browser) }
        .background {
            ZStack {
                landing ? greys.hover : onFrame ? Palette.frame : Palette.ground
                SplitDropZone(browser: browser, tab: nil, kind: .strip)
            }
        }
        .overlay(alignment: innerEdge) {
            if !onFrame { Rectangle().fill(Palette.hairline).frame(width: 1) }
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
}
