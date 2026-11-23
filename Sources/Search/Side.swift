import SwiftUI

/// The column's and the side panel's widths while an edge of theirs is held,
/// for the page beside them: it follows the pointer from here, and the
/// settings are written once, when the edge is let go. Each window has its
/// own, so only the window being pulled moves until then.
final class HeldEdges: ObservableObject {
    @Published var side: CGFloat?
    @Published var panel: CGFloat?
}

/// The tabs, down either side instead of across the top.
///
/// The same pieces as the strip — the grey that slides to the tab you picked,
/// the pinned squares, the cross that appears under the pointer — laid out the
/// other way. The traffic lights keep their corner; the column starts under
/// them and the page takes the whole height beside it.
struct SideBar: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    @ObservedObject private var agents = AgentControl.shared
    @Environment(\.colorScheme) private var colourScheme
    /// On the window's ground, beside the page's card (see CardEdge): the
    /// ground's colour and no edge of its own, the card's edge being the line.
    var onFrame = false
    /// The greys for that ground, handed down to every row, pin and door.
    private var greys: Greys { onFrame ? .frame : .white }

    @Namespace private var pill
    /// The live tab's glass, when it is glass (LiquidTab.swift).
    @StateObject private var lens = LensMotion()

    @State private var landing = false
    /// The width the column had when the edge was picked up.
    @State private var grabbed: CGFloat?
    /// The width while the edge is held. The setting is written once, when
    /// it is let go: written on every step, each one was a write to the
    /// settings and a change heard by every window and all that is in it.
    @State private var live: CGFloat?
    /// The width while the edge is held, nil once it is let go, for the page
    /// beside the column to follow (see HeldEdges).
    var onDrag: (CGFloat?) -> Void = { _ in }
    @State private var onEdge = false

    @State private var groupFrames: [UUID: GroupDropFrame] = [:]
    @State private var looseFrames = LooseFrames()

    /// A tab carried over the pins, or a pin over the tabs, and where it
    /// would land (see PinDrop).
    @State private var crossing: PinDrop.Crossing?
    /// Where the blocks are, for working that out.
    @State private var frames = ColumnFrames()
    /// Where each line of the pinned rows is, with pin folders drawn.
    @State private var pinLineFrames = PinLineFrames()
    /// Where a pin carried among the folders would go (see PinTree.place).
    @State private var folderDrop: PinTree.Place?
    /// Where a folder carried by its heading would go (PinTree.folderPlace).
    @State private var folderMove: PinTree.FolderPlace?
    /// Whether the rows fit under the pins without scrolling: set
    /// only when the answer changes, from the room under the pins and what
    /// the rows add up to, which are kept where changing them draws nothing.
    @State private var fits = true
    @State private var room = Room()
    private final class Room {
        var height: CGFloat = .infinity
        var needed: CGFloat = 0
        /// The rows' own height, as last laid out.
        var drawn: CGFloat = 0
        /// The tab in front and the room when the rows last fitted in a
        /// room measured: the column on screen, a plain stack at its top.
        var fitted: (active: Tab.ID?, height: CGFloat)?
    }

    /// A tab's line: the setting's height.
    private var rowHeight: CGFloat { prefs.sideRow }
    /// The column's width: the setting, or where the edge is while it is held.
    private var width: CGFloat { live ?? prefs.columnWidth }
    private static let gap: CGFloat = 4
    private static let groupInset: CGFloat = 4
    private static let square: CGFloat = 34
    private static let pinGap: CGFloat = 4

    private var onRight: Bool { prefs.sidePosition == .right }
    /// Icons only (SideIcons.swift): tiles for rows, a fixed width, the
    /// lights and the three doors stacked at the top.
    private var icons: Bool { prefs.iconColumn }
    /// The strip the column narrows to (Preferences.narrowStrip): icons
    /// only without back, forward and reload, and its edge still there to
    /// pull it back out.
    private var strip: Bool { prefs.narrowStrip }
    /// The strip's buttons under the lights, before the pins, with Buttons
    /// at the top; otherwise at its foot, after the tabs.
    private var stripUp: Bool { strip && prefs.doorsUp }
    /// The foot's doors one above the other, and the margin under them.
    private var stackedDoors: CGFloat {
        CGFloat(SideFoot.doors(prefs, browser.fetches, hanging: browser.downloadsHanging)) * 28 + 8
    }
    /// With icons only, the band the stacked lights take: gone in full
    /// screen, with them.
    private var lightsBand: CGFloat { browser.fullScreen ? 8 : Metrics.iconLights }
    /// What sits above the pins: the lights' band, and with icons only the
    /// three doors under it.
    private var top: CGFloat {
        !icons ? Metrics.strip : !strip ? lightsBand + Metrics.helmDoors + 8 : lightsBand + (stripUp ? stackedDoors : 0)
    }
    private var innerEdge: Alignment { onRight ? .leading : .trailing }

    /// The window's buttons' corner: gone in full screen, where macOS takes
    /// them away, and back, forward and reload move up to the edge (idea 184).
    private var lights: CGFloat {
        browser.fullScreen ? 0 : max(0, min(Metrics.sideLights, width - 20 - Metrics.helmDoors))
    }

    /// What is left of the lights' row right of back, forward and reload.
    private var beyondHelm: CGFloat { SideBar.beyondHelm(width, fullScreen: browser.fullScreen, fold: prefs.foldButton) }
    /// The room right of the helm at the width let go at, for the doors up
    /// there: how many pinned extensions show, not changing under the pointer.
    private var upRoom: CGFloat {
        max(SideBar.beyondHelm(prefs.columnWidth, fullScreen: browser.fullScreen, fold: prefs.foldButton), SideFoot.keptWidth(prefs))
    }
    private var doorsUp: Bool { SideBar.doorsUp(prefs, width: width, fullScreen: browser.fullScreen) }
    /// Where the doors are: up in the lights' row or down at the foot. Not
    /// doorsUp itself: while the edge is held, the doors up there stay up as
    /// it pushes them under the helm, and only go once they are under it
    /// all; let go, they stay only if they fit (settleDoors).
    @State private var drawnUp: Bool?
    private var doorsTop: Bool { drawnUp ?? doorsUp }
    private var doorsFoot: Bool { !doorsTop }
    /// Room past what the doors need before, with the edge held, they come
    /// back up: on the line itself, they went up and down with the pointer.
    private static let doorsSlack: CGFloat = 12
    /// One end going, quickly, and the other coming after it, slower: at
    /// once, both were half there together and the doors blinked. Short and
    /// plain, so it is seen to happen and not watched. The rows' end makes
    /// room back down at this pace too.
    private static var doorsOut: Animation? {
        Motion.reduced ? nil : .easeIn(duration: 0.1)
    }
    /// The top fading back in, after the foot has gone.
    private static var doorsIn: Animation? {
        Motion.reduced ? nil : .easeOut(duration: 0.5).delay(0.1)
    }
    /// The foot rising from under the column's edge with the rows' end:
    /// soft to start and to stop, so the rise itself is what is seen.
    private static var footIn: Animation? {
        Motion.reduced ? nil : .timingCurve(0.25, 0.1, 0.25, 1, duration: 0.45)
    }
    /// The foot's height in a row: its doors and the margin beneath.
    private static let footBox: CGFloat = 26 + 10
    /// How far the strip's edge is pulled before the titles come back.
    static let stripPull: CGFloat = 24

    /// The edge held where it would make the column `wanted` wide: the width
    /// to draw it at, or, narrowing to icons and past the line, the strip
    /// (no width held; the strip's is fixed) — the same in either direction
    /// while it is held.
    static func held(_ wanted: CGFloat, narrows: Bool) -> (narrow: Bool, width: CGFloat?) {
        guard narrows else { return (false, min(Metrics.sideMax, max(Metrics.sideMin, wanted))) }
        if wanted < Metrics.narrowLine { return (true, nil) }
        return (false, min(Metrics.sideMax, wanted))
    }

    static func beyondHelm(_ width: CGFloat, fullScreen: Bool, fold: Bool = false) -> CGFloat {
        let lights = fullScreen ? 0 : max(0, min(Metrics.sideLights, width - 20 - Metrics.helmDoors))
        return width - 20 - lights - foldDoor(fold) - Metrics.helm
    }
    /// The door that folds the column away, between the lights and back
    /// (FoldDoor), when it is asked for: one door and the air after it.
    static func foldDoor(_ shown: Bool) -> CGFloat { shown ? 26 + 4 : 0 }
    /// The foot's doors up in the lights' row (Preferences.doorsUp): only
    /// with titles, and only where the doors that always show fit there —
    /// downloads counted whether running or not, so a download starting
    /// doesn't send them all back down.
    @MainActor static func doorsUp(_ prefs: Preferences, width: CGFloat, fullScreen: Bool) -> Bool {
        prefs.doorsUp && !prefs.iconColumn
            && beyondHelm(width, fullScreen: fullScreen, fold: prefs.foldButton) >= SideFoot.keptWidth(prefs)
    }

    var body: some View {
        ZStack(alignment: .top) {
            // A right-click anywhere in the column with nothing of its own
            // there — under the tabs, between groups, the band at the top,
            // round the foot's buttons — brings up the column's menu.
            DragStrip(reserved: 0, below: rowsEnd, onDoubleClick: browser.newTab,
                      menu: columnMenu)

            // The band the lights sit in is this mode's title bar: the window
            // is dragged by it and a double-click fills the screen with it,
            // everywhere but over the three doors, which take their own
            // clicks. The lights are the title bar's own and answer first.
            if icons {
                DragStrip(menu: columnMenu)
                    .frame(height: lightsBand)
            } else {
                HStack(spacing: 0) {
                    DragStrip(menu: columnMenu)
                        .frame(width: 10 + lights)
                    // Back, forward and reload's, as tall as they are: above
                    // and below them the band is still title bar.
                    DragStrip(reserved: SideBar.foldDoor(prefs.foldButton) + Metrics.helm, band: 30, menu: columnMenu)
                        .frame(width: SideBar.foldDoor(prefs.foldButton) + Metrics.helm)
                    // The doors, when they are up here, at its far end.
                    DragStrip(trailing: doorsTop ? upRoom + 10 : 0, menu: columnMenu)
                }
                .frame(height: Metrics.strip)
            }

            VStack(alignment: .leading, spacing: 0) {
                // The traffic lights' corner, with back, forward and reload
                // sitting right of them — the same three doors as the top
                // bar, moved beside the lights since there's no far end of a
                // row to put them at in this mode.
                if icons {
                    // The lights stacked in their band (Lights, vertical),
                    // the three doors one above the other under them.
                    Color.clear.frame(height: lightsBand)
                    if stripUp {
                        foot
                    } else if !strip {
                        Helm(browser: browser, vertical: true)
                            .frame(maxWidth: .infinity)
                            .padding(.bottom, 8)
                    }
                } else {
                    HStack(spacing: 0) {
                        Color.clear.frame(width: lights)
                        if prefs.foldButton {
                            FoldDoor(browser: browser, right: prefs.sidePosition == .right)
                                .padding(.trailing, SideBar.foldDoor(true) - 26)
                        }
                        Helm(browser: browser)
                        Spacer(minLength: 0)
                    }
                    .frame(height: Metrics.strip)
                    // At the column's far end, fading out as the foot rises,
                    // and back (settleDoors). Laid over the row, the width
                    // let go at, not the one held: sized to the edge as it
                    // moved, they were laid out again at every frame of it.
                    .overlay(alignment: .trailing) {
                        if prefs.doorsUp {
                            SideFoot(browser: browser, prefs: prefs, fetches: browser.fetches, up: true, live: doorsTop, width: upRoom)
                                .fixedSize()
                                .opacity(doorsTop ? 1 : 0)
                                .animation(doorsTop ? SideBar.doorsIn : SideBar.doorsOut, value: doorsTop)
                                .allowsHitTesting(doorsTop)
                                .accessibilityHidden(!doorsTop)
                        }
                    }
                    // The page's address, when it is to be in sight.
                    if prefs.addressLine {
                        AddressLine(browser: browser, height: prefs.sideRow)
                            .padding(.bottom, 6)
                            // Its suggestions hang over the rows below.
                            .zIndex(1)
                    }
                    // The pinned extensions, a row of tiles over the pinned
                    // tabs, as Arc has them (ExtensionShelf).
                    ExtensionShelf(browser: browser, width: width - 20)
                }

                pages

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            // Clear of the foot, which sits over the sidebar's bottom edge,
            // and of what plays in another tab, over the foot.
            // The rows' end with the foot, as it rises and goes: this inset
            // alone animated, not the rows under it, which only take it.
            .animation(doorsFoot ? SideBar.footIn : SideBar.doorsOut) {
                $0.modifier(EndInset(bottom: footHeight))
            }
            .padding(.bottom, (browser.player == nil ? 0 : rowHeight + SideBar.playerGap)
                     + (agentHere && !icons ? SideBar.agentRow + SideBar.playerGap : 0))

            VStack(spacing: 0) {
                Spacer()
                // A coding agent allowed in this window: its pill and Stop,
                // in the column rather than over the page (AgentBanner).
                if agentHere, !icons {
                    AgentStatus(browser: browser, style: .row)
                        .frame(height: SideBar.agentRow)
                        .padding(.horizontal, 10)
                        .padding(.bottom, SideBar.playerGap)
                        .transition(.opacity)
                }
                if let tab = browser.player {
                    PlayerRow(browser: browser, prefs: prefs, tab: tab)
                        .padding(.horizontal, 10)
                        .padding(.bottom, SideBar.playerGap)
                        .transition(.opacity)
                }
                // Up from under the column's edge as the top goes, with the
                // rows' end: moved, not resized, as the edge held resizes it
                // every frame; by Rise, as a plain offset only jumped there.
                // Going, its room shuts at once and it is gone with it.
                // The strip's buttons are up under the lights instead.
                if !stripUp {
                    foot
                        // As far as the rows' end moves (10 to footBox), so the
                        // two go up together, the doors just under the edge.
                        .modifier(Rise(y: doorsFoot ? 0 : SideBar.footBox - 10))
                        .animation(SideBar.footIn, value: doorsFoot)
                        .frame(height: icons ? nil : doorsFoot ? SideBar.footBox : 0, alignment: .top)
                        .clipped()
                        .transaction(value: doorsFoot) { $0.animation = nil }
                        .allowsHitTesting(doorsFoot)
                        .accessibilityHidden(!doorsFoot)
                }
            }
        }
        .onChange(of: width) { _, _ in settleDoors() }
        .onChange(of: live == nil) { _, _ in settleDoors() }
        // Bench "edgetime": the edge held at a width, or let go (nil).
        .onReceive(NotificationCenter.default.publisher(for: Bench.edgeHeld)) { note in
            guard Store.testing else { return }
            live = note.object as? CGFloat
            grabbed = live == nil ? nil : grabbed ?? prefs.columnWidth
            onDrag(live)
        }
        .onChange(of: doorsUp) { was, _ in
            // Where they were drawn, kept from here on: left to doorsUp,
            // they were already at the other end by the time settleDoors
            // looked, and went there without moving.
            if drawnUp == nil, !icons, prefs.doorsUp {
                drawnUp = was
            }
            settleDoors()
        }
        .onChange(of: icons) { _, _ in
            // Into icons only or out of it, the doors are simply where they go.
            drawnUp = nil
        }
        .environment(\.greys, greys)
        .frame(width: width)
        .frame(maxHeight: .infinity)
        // ⌘S to icons only while the edge is held takes the edge away, and
        // its gesture ends without onEnded: let go of the held width too.
        .onChange(of: icons) { _, now in
            // Narrowed to the strip by the edge itself: still held.
            guard now, live != nil, !strip else { return }
            live = nil
            grabbed = nil
            onDrag(nil)
        }
        // Gone while the edge is held (hidden, or the pane changed), the
        // gesture never ends: let go of the held width, or the page stays
        // laid out at it until the next pull.
        .onDisappear {
            guard live != nil else { return }
            live = nil
            grabbed = nil
            onDrag(nil)
        }
        .clipped()
        .background {
            ZStack {
                onFrame ? Palette.frame : Palette.ground
                if landing { greys.hover }
                // The window's colour, if it has one: over the ground, so the
                // column stays opaque and folded out over the page it brings
                // the same wash along.
                ThemeWash(look: browser.wash)
                if prefs.splitView {
                    SplitDropZone(browser: browser, tab: nil, kind: .strip)
                }
            }
        }
        .overlay(alignment: innerEdge) {
            if !onFrame { Rectangle().fill(Palette.hairline).frame(width: 1) }
        }
        // A fixed width with icons only: nothing to pull. The strip keeps
        // its edge, to be pulled back out to titles.
        .overlay(alignment: innerEdge) { if !icons || strip { edge } }
        .onDrop(of: [.url, .text], isTargeted: $landing) { providers in
            browser.take(providers)
        }
        .animation(Motion.quick, value: landing)
        .animation(Motion.quick, value: browser.player?.id)
        .animation(Motion.glide, value: browser.activeID)
        .animation(Motion.glide, value: browser.editingTab)
        .animation(Motion.settle, value: browser.tabs.map(\.id))
        .animation(Motion.settle, value: browser.pinnedCount)
        // The last square made the first row changes nothing in the row's
        // order; only how many of each there are.
        .animation(Motion.settle, value: browser.listedPins.count)
    }

    /// The column's menu, for a right-click where nothing else has one.
    private var columnMenu: () -> NSMenu? {
        let browser = self.browser
        return { [weak browser] in browser.map(ColumnMenu.make(for:)) }
    }

    /// The column's edge: pull it to make the column wider or narrower,
    /// double-click it to put it back. The whole edge takes the pointer; on
    /// it, a small pill shows in the middle (see Grip) so the edge says it
    /// can be taken before it is. Edge to edge, the pill sits on the page's
    /// hairline; as cards, in the gap before the page.
    private var edge: some View {
        EdgeGrip(lit: onEdge || grabbed != nil)
            .offset(x: onFrame ? 0 : onRight ? -4 : 4)
            .frame(width: 9)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { over in
                onEdge = over
                if over { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        // Taken from the strip, as if a little short of the
                        // line: a short pull brings the titles back, where
                        // the strip's own width would need a long one.
                        if grabbed == nil { grabbed = strip ? Metrics.narrowLine - SideBar.stripPull : prefs.columnWidth }
                        let delta = onRight ? -value.translation.width : value.translation.width
                        let wanted = (grabbed ?? prefs.columnWidth) + delta
                        let held = SideBar.held(wanted, narrows: prefs.narrowsToIcons)
                        if held.narrow != prefs.narrowed, prefs.narrowsToIcons {
                            withAnimation(Motion.glide) { prefs.narrowed = held.narrow }
                        }
                        live = held.width
                        onDrag(live)
                    }
                    .onEnded { _ in
                        if let live { prefs.sideWidth = live }
                        live = nil
                        grabbed = nil
                        onDrag(nil)
                    }
            )
            .modifier(OneClick(double: true) {
                withAnimation(Motion.settle) {
                    prefs.narrowed = false
                    prefs.sideWidth = Metrics.side
                }
            })
            .animation(Motion.quick, value: onEdge)
    }

    // MARK: - the rows

    private var pages: some View {
        page
            // The page is the column's whole width, with its own margin.
            .padding(.horizontal, -10)
            // The room there is, and never more.
            .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
    }

    /// The rows on screen: the pins, then the rows under them.
    private var page: some View {
        Group {
                VStack(alignment: .leading, spacing: 0) {
                    if !browser.squarePins.isEmpty || ghostSquare != nil {
                        pinned
                            .padding(.bottom, 10)
                            // A square carried down over the rows passes
                            // over them, not under.
                            .zIndex(carriedPin ? 1 : 0)
                    }
                    // A row too long for the window scrolls between the pins
                    // and the foot, rather than running under the lights at one
                    // end and the foot at the other. While it fits it stays a
                    // plain stack, and the space under it is still the
                    // window's to be dragged by.
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
                            rows.onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                                room.drawn = $0
                                refit()
                            }
                        } else {
                            ScrollViewReader { proxy in
                                // Without scroll indicators: the tab column stays quiet
                                // and distraction-free, matching other vertical-tab browsers.
                                // The wheel and the trackpad still scroll smoothly.
                                ScrollView(.vertical, showsIndicators: false) {
                                    rows.onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                                        room.drawn = $0
                                        refit()
                                    }
                                }
                                .coordinateSpace(name: "scroll")
                                // The tab you go to is the tab you see — ⌘1–⌘9,
                                // ⇧⌘], a link opening beside the one on screen.
                                .onChange(of: browser.activeID) { _, id in
                                    guard let id else { return }
                                    let representative = browser.activeSplit?.left ?? id
                                    // Without the glide on a test run: a hidden
                                    // probe's window draws no frames, and the
                                    // scroll stopped where its first one left it.
                                    withAnimation(Store.testing ? nil : Motion.glide) { scroll(proxy, to: representative) }
                                }
                                // A turn of the run loop later, as the row across
                                // the folded
                                // column comes out mid-animation, and asked at
                                // once, before the rows had their height, the
                                // scroll could be dropped and the tab you were on
                                // left out of sight.
                                //
                                // Not when the rows grew past the same room
                                // under the tab you were already on, a folder
                                // opened: the stack was at its top, and
                                // the scroll that takes over starts there too,
                                // where Arc leaves it (a folder opened is
                                // opened in place).
                                .onAppear {
                                    let stayed = room.fitted.map { $0.active == browser.activeID && $0.height == room.height } ?? false
                                    room.fitted = nil
                                    guard !stayed, let id = browser.activeID else { return }
                                    // At once too, so a row that has just grown
                                    // too long to fit doesn't show its top
                                    // for a frame; the turn later is for when
                                    // this one is dropped.
                                    scroll(proxy, to: browser.activeSplit?.left ?? id, anchor: .center)
                                    DispatchQueue.main.async {
                                        scroll(proxy, to: browser.activeSplit?.left ?? id, anchor: .center)
                                    }
                                }
                            }
                        }
                    }
                    // The whole room under the pins, and never more, to be
                    // measured: a minimum of nothing, so a plain stack taller
                    // than the room runs on past its foot rather than making
                    // the room as tall as itself. With no minimum, the room
                    // measured was whatever the rows asked for once they ran
                    // past the window, so a sum a few points short (two for
                    // every folded group) kept the plain stack for good; and
                    // the column, as tall as its rows, stood centred over the
                    // window where nothing holds it at the top — folded away
                    // and out over the page — its top out of reach, with
                    // nothing to scroll it back by (idea 443). A window
                    // changing size, or a tab opened or closed, builds
                    // nothing until the rows stop fitting or start: what the
                    // rows add up to decides at once, what they measure a
                    // frame later, the larger of the two winning.
                    .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
                    // The live tab as a pane of Liquid Glass, held to the
                    // room (LiquidTab.swift). Nothing unless it is on.
                    .liveLens(browser, motion: lens)
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
        }
        .padding(.horizontal, 10)
        .frame(width: width, alignment: .topLeading)
    }

    private func refit() {
        let now = max(room.needed, room.drawn) <= room.height
        if now, room.height.isFinite { room.fitted = (browser.activeID, room.height) }
        if Store.testing { SideBar.measured = ["room": room.height, "needed": room.needed, "drawn": room.drawn, "fits": now ? 1 : 0] }
        if fits != now { fits = now }
    }

    /// What the column last measured, for the bench (`columnscroll`). Test runs only.
    @MainActor static var measured: [String: CGFloat] = [:]
    /// The pinned rows' lines as last drawn with folders, for the bench
    /// (`pinfolder`): kind, depth, title, folded. Test runs only.
    @MainActor static var drawnPinLines: [[Any]] = []
    /// Where each of those lines was drawn, in the rows' own space. Test runs only.
    @MainActor static var drawnPinFrames: [UUID: CGRect] = [:]
    /// Where those lines' own space starts down the window. Test runs only.
    @MainActor static var drawnPinTop: CGFloat?

    private var rowsEnd: CGFloat {
        let pins = browser.squarePins.count
        let pinBlock = pins == 0 ? 0 : (pinCells(pins).map(\.maxY).max() ?? 0) + 10
        let shelf = icons ? 0 : ExtensionShelf.height(width: width - 20)
        return top + shelf + pinBlock + rowsHeight
    }

    /// The pinned rows and the loose tabs, added
    /// up the same way, with a few points to spare: what decides whether
    /// they scroll.
    private var rowsHeight: CGFloat {
        let displayed = browser.displayedTabs
        let listed = browser.listedPins.count
        let ungrouped = browser.looseRow.count
        let listBlock = listedHeight(listed)
            + (showsLine(kept: keptCount, listed: listed, loose: ungrouped) ? KeepLine.height + SideBar.gap : 0)
        let grouped = prefs.usesTabGroups ? browser.tabGroups.map { browser.visibleTabs(in: $0) } : []
        let rows = prefs.usesTabGroups
            ? displayed.filter { $0.pin == nil && browser.group(of: $0) == nil } + grouped.flatMap { $0 }
            : displayed.filter { $0.pin == nil }
        // A split is a line for each page (see SplitTabItem): the lines
        // past the first.
        let pairs = rows.reduce(0) { $0 + max(0, (browser.split(for: $1)?.tabs.count ?? 1) - 1) }
        let heading = icons ? GroupHeading.compactHeight : GroupHeading.height
        // A folded group showing none of its tabs still has its empty stack
        // of them under its heading, and the gap after it.
        let headings = CGFloat(grouped.count) * (heading + SideBar.gap)
            + CGFloat(grouped.filter(\.isEmpty).count) * SideBar.gap
        let loose = CGFloat(rows.count) * (rowHeight + SideBar.gap) + CGFloat(pairs) * rowHeight + headings
        return listBlock + loose + 8
    }

    /// The pinned rows' height: each row, or with pin folders each line,
    /// the gap under it, and one more under them all.
    private func listedHeight(_ listed: Int) -> CGFloat {
        guard browser.showsPinFolderRows else {
            return CGFloat(listed) * (rowHeight + SideBar.gap) + (listed > 0 ? SideBar.gap : 0)
        }
        let heading = PinFolderHeading.height(prefs, compact: icons)
        let lines = browser.pinRowLines()
        let total = lines.reduce(CGFloat(0)) { sum, line in
            if case .folder = line { return sum + heading + SideBar.gap }
            return sum + rowHeight + SideBar.gap
        }
        return total + (lines.isEmpty ? 0 : SideBar.gap)
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
        let pages = pair.map { pair in pair.tabs.compactMap { id in tabs.first { $0.id == id } } } ?? []
        if icons {
            if let pair, pages.count >= 2 {
                IconPair(browser: browser, prefs: prefs, pages: pages,
                         live: activeID.map { pair.contains($0) } ?? false,
                         focusedID: activeID, interactive: interactive, pill: pill)
            } else {
                IconTile(browser: browser, prefs: prefs, tab: tab, live: tab.id == activeID,
                         pill: pill, close: close, interactive: interactive)
            }
        } else if let pair, pages.count >= 2 {
            SplitTabItem(browser: browser, prefs: prefs, pages: pages,
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

    /// Each row's place down the column, the gap under it included: a pair
    /// stands as two lines (see Carried). Worked out once for the list.
    private func steps(_ rows: [Tab]) -> [CGFloat] {
        let pairs = prefs.splitView
            ? Dictionary(browser.splits.filter { $0.left != $0.right }.map { ($0.left, $0.tabs.count) }, uniquingKeysWith: { first, _ in first })
            : [:]
        return rows.map { rowHeight * CGFloat(pairs[$0.id] ?? 1) + SideBar.gap }
    }

    // MARK: - the pinned squares

    private var pinnedTabs: [Tab] { browser.squarePins }
    private var looseTabs: [Tab] { browser.looseRow }

    /// The line between what is kept and what comes and goes, with the
    /// pinned rows on: over the tabs Clear would close, or under rows with
    /// nothing below them yet. Not with the rows off, nor with nothing on
    /// either side of it: nothing kept above it either — no pin, square or
    /// row, and no group — until the first is pinned
    /// (idea 444), separates the pinned and regular tabs.
    /// `loose`: the tabs under it that hold a page. Over nothing but the
    /// empty tab a window starts with, it was a line with nothing to keep
    /// apart (Drice, 18 Nov 2026).
    private func showsLine(kept: Int, listed: Int, loose: Int) -> Bool {
        prefs.showsPinRows && kept > 0 && listed + loose > 0
    }

    /// What stands above the line: the pins and the groups.
    private var keptCount: Int {
        browser.squarePins.count + browser.listedPins.count + (prefs.usesTabGroups ? browser.tabGroups.count : 0)
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
        let room = width - 20
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
        // A tab carried over the grid: one cell more, and the one it
        // would take left open for it.
        let ghost = ghostSquare
        let all = pinCells(tabs.count + (ghost == nil ? 0 : 1))
        let cells = ghost.map { open in all.indices.filter { $0 != open }.map { all[$0] } } ?? all
        let placed = cells + (ghost.map { [all[$0]] } ?? [])
        // Measured in the grid's own space, not the square's: a square that
        // has just been moved to a new cell would otherwise report the drag
        // from where it now is, the target would jump back, and the square
        // would shuttle between two cells for as long as the finger stayed.
        return VStack(spacing: 0) { PinGrid(cells: placed) {
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
                .modifier(PinCarried(index: index, cells: cells,
                                     cross: { cross(tab, $0, from: .pins) },
                                     land: { land(tab, $0) }) { browser.move(tab, to: $0) })
            }
            if let ghost, let tab = crossingTab {
                PinGhost(tab: tab, width: all[ghost].width, height: all[ghost].height)
            }
        } }
        .coordinateSpace(name: "pins")
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named("column")) }) { [frames] in frames.grid = $0 }
    }

    // MARK: - the rows

    /// The pins kept as rows, under the squares: Arc's pinned list. Each is
    /// a row like any other to look at, carried only among its own kind.
    @ViewBuilder
    private var listed: some View {
        if browser.showsPinFolderRows { foldered } else { flatListed }
    }

    /// The pinned rows in their folders (see PinFolders.swift): each
    /// folder's heading, then what it holds, set in. A row carried among
    /// them goes where it is let go — into the folder whose heading it is
    /// over, or beside the row it is over — rather than moving along as it
    /// goes; a mark shows where.
    private var foldered: some View {
        // A split pinned whole is one line, drawn at its first page.
        let lines = browser.pinRowLines().filter { line in
            if case .pin(let tab, _) = line { return browser.standsInRow(tab) }
            return true
        }
        if Store.testing { SideBar.drawnPinLines = lines.map(\.described) }
        let heading = PinFolderHeading.height(prefs, compact: icons)
        let lineSteps = lines.map { line -> CGFloat in
            switch line {
            case .folder: return heading + SideBar.gap
            case .pin(let tab, _): return rowHeight * CGFloat(browser.split(for: tab)?.tabs.count ?? 1) + SideBar.gap
            }
        }
        let drop = folderDrop
        let move = folderMove
        let moveMark = Self.folderMoveMark(move, lines: lines)
        return VStack(spacing: SideBar.gap) {
            ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                switch line {
                case .folder(let folder, let depth):
                    PinFolderHeading(browser: browser, prefs: prefs, folder: folder, depth: depth, compact: icons,
                                     target: (drop?.folder == folder.id && drop?.anchor == nil)
                                        || (move != nil && move?.parent == folder.id && move?.before == nil))
                        .overlay(alignment: moveMark?.after == true ? .bottom : .top) {
                            if let moveMark, moveMark.id == folder.id {
                                PinFolderMark().offset(y: (moveMark.after ? 1 : -1) * (SideBar.gap / 2 + 1))
                            }
                        }
                        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named("listed")) }) { [pinLineFrames] in
                            pinLineFrames.rects[folder.id] = $0
                            if Store.testing { SideBar.drawnPinFrames[folder.id] = $0 }
                        }
                        // Carried by its heading, as a pinned row is, and put
                        // down where let go: into a folder, out of one, or
                        // before another (PinTree.folderPlace).
                        .modifier(Carried(index: index, steps: lineSteps, vertical: true, space: "listed",
                                          cross: { folderMoveCross(folder, $0) },
                                          land: { folderMoveLand(folder, $0) }) { _ in })
                case .pin(let tab, let depth):
                    // A split pinned whole as a split, as among the tabs.
                    rowItem(tab, tabs: browser.tabs, splits: browser.splits, activeID: browser.activeID,
                            interactive: true, pill: pill, close: { browser.close(tab) })
                        .padding(.leading, icons ? 0 : CGFloat(depth) * PinFolderHeading.indent)
                    .overlay(alignment: drop?.after == true ? .bottom : .top) {
                        if let drop, drop.anchor == tab.id {
                            PinFolderMark().offset(y: (drop.after ? 1 : -1) * (SideBar.gap / 2 + 1))
                        }
                    }
                    .overlay(alignment: moveMark?.after == true ? .bottom : .top) {
                        if let moveMark, moveMark.id == tab.id {
                            PinFolderMark().offset(y: (moveMark.after ? 1 : -1) * (SideBar.gap / 2 + 1))
                        }
                    }
                    .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named("listed")) }) { [pinLineFrames] in
                        pinLineFrames.rects[tab.id] = $0
                        if Store.testing { SideBar.drawnPinFrames[tab.id] = $0 }
                    }
                    // Carried as rows are, but put down only where let go:
                    // its place among the lines is no place in the row.
                    .modifier(Carried(index: index, steps: lineSteps, vertical: true,
                                      space: "listed",
                                      cross: { folderCross(tab, $0) },
                                      land: { folderLand(tab, $0) }, faded: crossing?.tab == tab.id) { _ in })
                }
            }
        }
        .coordinateSpace(name: "listed")
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named("column")) }) { [frames] in frames.listed = $0 }
        .onGeometryChange(for: CGFloat.self, of: { $0.frame(in: .global).minY }) { if Store.testing { SideBar.drawnPinTop = $0 } }
        .padding(.bottom, lines.isEmpty ? 0 : SideBar.gap)
    }

    /// Where a pin let go at `y` in the rows' own space would go.
    private func folderPlace(for id: UUID, y: CGFloat) -> PinTree.Place? {
        let measured = measuredPinLines()
        return PinTree.place(y: y, lines: measured.lines, folders: measured.folders, carrying: id)
    }

    /// The pin folders' lines as measured, for where something let go
    /// among them goes.
    private func measuredPinLines() -> (lines: [(line: PinTree.Line, frame: CGRect)], folders: [UUID: UUID?]) {
        let lines = browser.pinRowLines()
        let measured = lines.compactMap { line -> (line: PinTree.Line, frame: CGRect)? in
            guard let rect = pinLineFrames.rects[line.id] else { return nil }
            switch line {
            case .folder(let folder, let depth): return (.folder(folder, depth: depth), rect)
            case .pin(let tab, let depth): return (.pin(tab.id, depth: depth), rect)
            }
        }
        var folders: [UUID: UUID?] = [:]
        for line in lines { if case .pin(let tab, _) = line { folders[tab.id] = tab.pinFolder } }
        return (measured, folders)
    }

    /// Where the mark for a carried folder goes: over the folder it would
    /// go before; going last at the top, over the first pin there, or under
    /// the last line. Into a folder, that folder's heading is lit instead.
    static func folderMoveMark(_ place: PinTree.FolderPlace?, lines: [PinRowLine]) -> (id: UUID, after: Bool)? {
        guard let place else { return nil }
        if let before = place.before { return (before, false) }
        guard place.parent == nil else { return nil }
        if let top = lines.first(where: { if case .pin(_, 0) = $0 { return true }; return false }) { return (top.id, false) }
        return lines.last.map { ($0.id, true) }
    }

    /// A folder carried by its heading: the place it would go. It stays
    /// among the pinned rows, so no other block takes it.
    private func folderMoveCross(_ folder: PinFolder, _ point: CGPoint) -> Bool {
        let measured = measuredPinLines()
        let place = PinTree.folderPlace(y: point.y, lines: measured.lines, folders: browser.pinFolders,
                                        pinFolder: measured.folders, carrying: folder.id)
        if folderMove != place { withAnimation(Motion.settle) { folderMove = place } }
        return true
    }

    private func folderMoveLand(_ folder: PinFolder, _ point: CGPoint?) -> Bool {
        let place = folderMove
        if folderMove != nil { withAnimation(Motion.settle) { folderMove = nil } }
        guard point != nil, let place else { return true }
        withAnimation(Motion.settle) { browser.movePinFolder(folder.id, to: place) }
        return true
    }

    private func showFolderDrop(_ place: PinTree.Place?) {
        if folderDrop != place { withAnimation(Motion.settle) { folderDrop = place } }
    }

    /// A pinned row carried among the folders: over another block, that
    /// block's; here, the place it would go.
    private func folderCross(_ tab: Tab, _ point: CGPoint) -> Bool {
        if cross(tab, point, from: .listed) {
            showFolderDrop(nil)
            return true
        }
        showFolderDrop(browser.takesFolder(tab) ? folderPlace(for: tab.id, y: point.y) : nil)
        return false
    }

    private func folderLand(_ tab: Tab, _ point: CGPoint?) -> Bool {
        let place = folderDrop
        showFolderDrop(nil)
        if land(tab, point) { return true }
        guard point != nil, let place else { return false }
        withAnimation(Motion.settle) { browser.movePin(tab, to: place) }
        return true
    }

    /// The pinned rows as they always were, with no folder to draw.
    private var flatListed: some View {
        // A split pinned whole is one row, drawn at its first page.
        let pins = browser.listedPins.filter { browser.standsInRow($0) }
        let squares = browser.squarePins.count
        let ghost: Int? = if case .listed(let at)? = crossing?.target { at } else { nil }
        let pinSteps = steps(pins)
        return VStack(spacing: SideBar.gap) {
            ForEach(Array(pins.enumerated()), id: \.element.id) { index, tab in
                if ghost == index, let carried = crossingTab {
                    RowGhost(tab: carried, height: rowHeight, size: prefs.sideTitle)
                }
                rowItem(tab, tabs: browser.tabs, splits: browser.splits, activeID: browser.activeID,
                        interactive: true, pill: pill, close: { browser.close(tab) })
                    .modifier(Carried(index: index, steps: pinSteps, vertical: true,
                                      space: "listed",
                                      cross: { cross(tab, $0, from: .listed) },
                                      land: { land(tab, $0) }, faded: crossing?.tab == tab.id) {
                        browser.moveDisplayedTab(tab, to: $0 + squares)
                    })
            }
            if let ghost, ghost >= pins.count, let carried = crossingTab {
                RowGhost(tab: carried, height: rowHeight, size: prefs.sideTitle)
            }
        }
        .coordinateSpace(name: "listed")
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named("column")) }) { [frames] in frames.listed = $0 }
        .padding(.bottom, pins.isEmpty && ghost == nil ? 0 : SideBar.gap)
    }

    private var loose: some View {
        VStack(spacing: SideBar.gap) {
            if prefs.usesTabGroups {
                ForEach(browser.tabGroups) { group in
                    let members = browser.visibleTabs(in: group)
                    let ghost = crossing?.target == .group(group.id) ? crossingTab : nil
                    VStack(spacing: SideBar.gap) {
                        GroupHeading(browser: browser, group: group, dragSpace: "rows", compact: icons)
                        groupRows(group, members: members, ghost: ghost)
                    }
                    .background(alignment: .top) {
                        groupWash(group.colour)
                            .frame(height: members.isEmpty && ghost == nil
                                   ? (icons ? GroupHeading.compactHeight : GroupHeading.height) : nil)
                    }
                }
            }
            // See the grid: the drag is measured in the column's space, not
            // the row's, so a row that has just moved keeps its bearings.
            // Worked out once, not by every row: each look walks the whole
            // row, and 300 rows asking made redrawing the column quadratic.
            let loose = looseTabs
            // Under the groups: Clear keeps them, as it keeps the pins, so
            // everything above the line is what stays.
            if showsLine(kept: keptCount, listed: browser.listedPins.count, loose: loose.filter { !$0.isBlank }.count) {
                KeepLine(clears: !loose.isEmpty) { browser.clearTabs() }
            }
            let ghost: Int? = if case .loose(let at)? = crossing?.target { at } else { nil }
            // In a stack of their own, measured, for where a pin carried
            // among them would land.
            if !loose.isEmpty || ghost != nil {
                let looseSteps = steps(loose)
                let rows = loose.enumerated().map { LooseRow(id: $0.element.id, index: $0.offset, tab: $0.element) }
                VStack(spacing: SideBar.gap) {
                    ForEach(rows) { row in
                        let index = row.index, tab = row.tab
                        if ghost == index, let carried = crossingTab {
                            RowGhost(tab: carried, height: rowHeight, size: prefs.sideTitle)
                        }
                        rowItem(tab, tabs: browser.tabs, splits: browser.splits,
                                activeID: browser.activeID, interactive: true, pill: pill,
                                close: { browser.closeTab(tab) })
                        // Positions here are among the loose rows; the pinned block
                        // sits in front of them in the real list.
                        .modifier(Carried(index: index, steps: looseSteps, vertical: true,
                                          space: "rows", onDropTab: { source, point in drop(source, at: point) },
                                          groupDestination: { source, point in destination(source, at: point) },
                                          loose: prefs.usesTabGroups ? looseFrames : nil,
                                          outside: { browser.dragOut(tab) }, browser: browser, tab: tab,
                                          cross: { cross(tab, $0, from: .rows) },
                                          land: { land(tab, $0) }, faded: crossing?.tab == tab.id) {
                            if prefs.usesTabGroups {
                                browser.move(tab, within: nil, to: $0)
                            } else {
                                browser.moveDisplayedTab(tab, to: $0 + browser.pinnedCount)
                            }
                        })
                    }
                    if let ghost, ghost >= loose.count, let carried = crossingTab {
                        RowGhost(tab: carried, height: rowHeight, size: prefs.sideTitle)
                    }
                }
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named("column")) }) { [frames] in frames.loose = $0 }
            }
        }
        .coordinateSpace(name: "rows")
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named("column")) }) { [frames] in frames.rows = $0 }
        .onPreferenceChange(GroupDropFrames.self) { groupFrames = $0 }
    }

    private func destination(_ tab: Tab, at point: CGPoint) -> GroupDropTarget? {
        guard prefs.usesTabGroups, tab.pin == nil else { return nil }
        return GroupDropFrames.resolve(point, frames: groupFrames, groups: browser.tabGroups,
                                       excluding: tab.id, vertical: true)
    }

    private func drop(_ tab: Tab, at point: CGPoint) {
        if let target = destination(tab, at: point) {
            browser.move(tab, toGroup: target)
        } else if let out = leaving(tab, at: point) {
            browser.move(tab, outOfGroupBefore: out.before)
        }
    }

    private func leaving(_ tab: Tab, at point: CGPoint) -> LooseDrop? {
        guard prefs.usesTabGroups, tab.pin == nil else { return nil }
        let loose = Set(looseTabs.map(\.id))
        return GroupDropFrames.leaving(point, frames: groupFrames, loose: looseFrames.rects.filter { loose.contains($0.key) },
                                       groups: browser.tabGroups, source: tab.id, vertical: true)
    }

    /// Where the scroll goes for `id`.
    private func scroll(_ proxy: ScrollViewProxy, to id: Tab.ID, anchor: UnitPoint? = nil) {
        proxy.scrollTo(id, anchor: anchor)
    }

    @ViewBuilder
    private func groupWash(_ colour: Int?) -> some View {
        if let colour, let opacity = Tints.wash(colour, dark: colourScheme == .dark) {
            RoundedRectangle(cornerRadius: icons ? 6 : 9, style: .continuous)
                .fill(Tints.colours[colour].opacity(opacity))
                .allowsHitTesting(false)
        }
    }

    private func groupRows(_ group: TabGroup, members: [Tab], ghost: Tab?) -> some View {
        let memberSteps = steps(members)
        let inset = groupRowInset(group)
        return VStack(spacing: SideBar.gap) {
            ForEach(Array(members.enumerated()), id: \.element.id) { index, tab in
                rowItem(tab, tabs: browser.tabs, splits: browser.splits,
                        activeID: browser.activeID, interactive: true, pill: pill,
                        close: { browser.closeTab(tab) })
                    .padding(.leading, icons ? 0 : 14)
                    .padding(.trailing, inset)
                    .modifier(Carried(index: index, steps: memberSteps, vertical: true,
                                      space: "rows", onDropTab: { source, point in drop(source, at: point) },
                                      groupDestination: { source, point in destination(source, at: point) },
                                      outside: { browser.dragOut(tab) }, browser: browser, tab: tab,
                                      cross: { cross(tab, $0, from: .rows) },
                                      land: { land(tab, $0) }, faded: crossing?.tab == tab.id) {
                        browser.move(tab, within: group.id, to: $0)
                    })
            }
            // A pin carried over its heading goes in at the end.
            if let carried = ghost {
                RowGhost(tab: carried, height: rowHeight, size: prefs.sideTitle)
                    .padding(.leading, icons ? 0 : 14)
                    .padding(.trailing, inset)
            }
        }
        // With icons only, the group's tiles held by a thin bracket in the
        // margin, rather than set in under a name.
        .overlay(alignment: .leading) {
            if icons && !members.isEmpty { IconGroupBracket(folded: group.collapsed).offset(x: -6) }
        }
    }

    private func groupRowInset(_ group: TabGroup) -> CGFloat {
        !icons && Tints.wash(group.colour, dark: colourScheme == .dark) != nil ? Self.groupInset : 0
    }

    // MARK: - carried between the pins and the tabs

    /// The block a carried tab's point is measured in.
    private enum From { case pins, listed, rows }

    /// The place open in the grid, while a tab is carried over it.
    private var ghostSquare: Int? {
        if case .squares(let at)? = crossing?.target { return at }
        return nil
    }

    /// The tab being carried across, while it is.
    private var crossingTab: Tab? {
        crossing.flatMap { crossing in browser.tabs.first { $0.id == crossing.tab } }
    }

    /// A square being carried out over the rows.
    private var carriedPin: Bool {
        guard let crossing, ghostSquare == nil else { return false }
        return browser.tabs.first { $0.id == crossing.tab }.map { $0.pin != nil && !($0.listed && prefs.showsPinRows) } ?? false
    }

    private func columnPoint(_ point: CGPoint, from: From) -> CGPoint {
        let origin: CGPoint
        switch from {
        case .pins: origin = frames.grid?.origin ?? .zero
        case .listed: origin = frames.listed?.origin ?? .zero
        case .rows: origin = frames.rows.origin
        }
        return CGPoint(x: point.x + origin.x, y: point.y + origin.y)
    }

    /// Where `tab` would land with the hand at `point` (the column's
    /// space): nil over its own block, where it moves as it always did, or
    /// over one that won't take it — a pair, a private tab.
    private func target(for tab: Tab, at point: CGPoint) -> PinDrop.Target? {
        let squares = browser.squarePins.filter { $0.id != tab.id }
        let gridShown = !squares.isEmpty || ghostSquare != nil
        let rowsOn = prefs.showsPinRows
        let listedShown = rowsOn && (!browser.listedPins.isEmpty || isListedGhost || browser.showsPinFolderRows)
        let zone = PinDrop.zone(point, width: width - 20,
                                gridBottom: gridShown ? frames.grid?.maxY : nil,
                                listed: listedShown ? frames.listed : nil)
        switch zone {
        case .none:
            return nil
        case .squares:
            // A split, pinned or not, goes among the rows only.
            let takes = (tab.pin == nil ? browser.pinsByDrag(tab) : (rowsOn && tab.listed)) && browser.split(for: tab) == nil
            guard takes else { return nil }
            let origin = gridShown ? frames.grid?.origin ?? .zero : .zero
            let slot = PinDrop.gridSlot(CGPoint(x: point.x - origin.x, y: point.y - origin.y),
                                        cells: pinCells(squares.count + 1))
            return .squares(browser.pinSlot(tab, listed: false, proposed: slot))
        case .listed:
            let takes = tab.pin == nil ? browser.pinsByDrag(tab) : !tab.listed
            guard takes, let listed = frames.listed else { return nil }
            let rows = browser.listedPins.filter { $0.id != tab.id }
            let ghost: (Int, CGFloat)? = if case .listed(let at)? = crossing?.target { (at, rowHeight) } else { nil }
            let slot = PinDrop.rowSlot(y: point.y - listed.minY, heights: rows.map { _ in rowHeight },
                                       gap: SideBar.gap, ghost: ghost)
            return .listed(browser.pinSlot(tab, listed: true, proposed: slot))
        case .loose:
            guard tab.pin != nil else { return nil }
            let inRows = CGPoint(x: point.x - frames.rows.minX, y: point.y - frames.rows.minY)
            if prefs.usesTabGroups, let id = groupFrames.values.first(where: { $0.rect.contains(inRows) })?.group {
                return .group(id)
            }
            let loose = looseTabs
            guard !loose.isEmpty, let top = frames.loose?.minY else { return .loose(0) }
            let ghost: (Int, CGFloat)? = if case .loose(let at)? = crossing?.target { (at, rowHeight) } else { nil }
            let heights = loose.map { browser.split(for: $0) != nil ? rowHeight * 2 : rowHeight }
            return .loose(PinDrop.rowSlot(y: point.y - top, heights: heights, gap: SideBar.gap, ghost: ghost))
        }
    }

    private var isListedGhost: Bool {
        if case .listed? = crossing?.target { return true }
        return false
    }

    /// The hand moved: the block it is over shows where the tab would
    /// land, and says so once, by touch, as it starts to. True while it does.
    private func cross(_ tab: Tab, _ point: CGPoint, from: From) -> Bool {
        let at = columnPoint(point, from: from)
        let now = target(for: tab, at: at)
            .map { PinDrop.Crossing(tab: tab.id, target: $0) }
        // Coming into the rows from the squares or the tabs, with folders:
        // the place among them, as a row carried there has it.
        if from != .listed, browser.showsPinFolderRows {
            if case .listed? = now?.target {
                showFolderDrop(folderPlace(for: tab.id, y: at.y - (frames.listed?.minY ?? 0)))
            } else {
                showFolderDrop(nil)
            }
        }
        if now != crossing {
            if crossing == nil, now != nil {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
            withAnimation(Motion.settle) { crossing = now }
        }
        return now != nil
    }

    /// Let go (nil: called off). Where it was shown it would land is where
    /// it lands; true when that was across the line.
    private func land(_ tab: Tab, _ point: CGPoint?) -> Bool {
        let shown = crossing?.tab == tab.id ? crossing?.target : nil
        guard point != nil, let shown else {
            if crossing != nil { withAnimation(Motion.settle) { crossing = nil } }
            if folderDrop != nil, crossing == nil { showFolderDrop(nil) }
            return false
        }
        withAnimation(Motion.settle) {
            crossing = nil
            switch shown {
            case .squares(let at): browser.pinDropped(tab, listed: false, at: at)
            case .listed(let at):
                if browser.pinDropped(tab, listed: true, at: at), browser.showsPinFolderRows {
                    if let place = folderDrop { browser.movePin(tab, to: place) } else { browser.arrangePinFolders() }
                }
            case .loose(let at): browser.unpinDropped(tab, at: at)
            case .group(let id): browser.unpinDropped(tab, at: 0, group: id)
            }
        }
        // The mark among the pinned rows goes with the drop it showed: a tab
        // let go there from the tabs left it standing until the next carry
        // moved it (#1245).
        showFolderDrop(nil)
        return true
    }

    /// The pinned rows and the loose tabs,
    /// which scroll as one.
    private var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            listed
            loose
        }
    }

    /// The foot's door and its margin beneath; with icons only, its doors
    /// one above the other.
    private var footHeight: CGFloat {
        if !doorsFoot || stripUp { return 10 }
        return icons ? stackedDoors : SideBar.footBox
    }
    /// Between what plays in another tab and the foot's doors.
    private static let playerGap: CGFloat = 4
    /// The agent's quiet line at the column's foot.
    private static let agentRow: CGFloat = 30
    /// An agent's pill is showing in this window (AgentControl).
    private var agentHere: Bool { agents.shownIn == ObjectIdentifier(browser) }

    /// The doors from one end of the column to the other, the top fading
    /// as the foot rises, and back: down once they no longer fit, up once
    /// they do again — with the edge held, a little past that.
    private func settleDoors() {
        guard !icons else { return }
        guard prefs.doorsUp else { drawnUp = nil; return }
        let up: Bool
        let kept = SideFoot.keptWidth(prefs)
        if doorsTop || live == nil {
            up = doorsUp
        } else {
            up = beyondHelm >= kept + SideBar.doorsSlack
        }
        guard up != doorsTop else { return }
        // No withAnimation: each end moves on its own (doorsIn, doorsOut,
        // footIn, EndInset). Animated as a whole, every row was laid out
        // again at each frame of it, and the edge held lagged the pointer.
        drawnUp = up
    }

    /// One small door at the bottom: the settings.
    private var foot: some View {
        SideFoot(browser: browser, prefs: prefs, fetches: browser.fetches, vertical: icons, live: doorsFoot, width: width)
    }

}

/// The row at the bottom of the column. Never wider than the column: wider,
/// the column took its width, and centred in its own frame it slid half the
/// overflow off each side (#535). The puzzle, bookmarks and
/// downloads stay put; the pinned extensions that don't fit give way, from
/// the last, and are still in the puzzle's list.
private struct SideFoot: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    @ObservedObject var fetches: Fetches
    /// The column of icons: one above the other, centred, no pinned
    /// extensions (their list is still the puzzle's).
    var vertical = false
    /// Up in the lights' row, right of back, forward and reload, laid out
    /// to its far end: `width` is then what that row has left.
    var up = false
    /// Whether this row is the one drawn; the other is kept, hidden, and must
    /// not take the downloads list's card for itself (see FetchDoor.live).
    var live = true
    /// The column's width, as it is drawn; up, the room right of the helm.
    let width: CGFloat

    var body: some View {
        if vertical {
            VStack(spacing: 2) {
                // An agent connected in this window: a click on it is Stop.
                AgentStatus(browser: browser, style: .icon)
                FetchDoor(browser: browser, fetches: fetches, arrowEdge: prefs.sidePosition == .right ? .leading : .trailing, live: live)
                ExtensionSlot(browser: browser, edge: prefs.sidePosition == .right ? .leading : .trailing, room: 0)
                BookmarkDoor(browser: browser, arrowEdge: prefs.sidePosition == .right ? .leading : .trailing)
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 8)
        } else if up {
            // The foot's order: the puzzle at the far end.
            HStack(spacing: 2) {
                FetchDoor(browser: browser, fetches: fetches, arrowEdge: .bottom, live: live)
                BookmarkDoor(browser: browser, arrowEdge: .bottom)
                // The pinned ones are over the pinned tabs (ExtensionShelf).
                ExtensionSlot(browser: browser, edge: .bottom, room: 0)
            }
        } else {
            HStack(spacing: 2) {
                // The pinned ones are over the pinned tabs (ExtensionShelf).
                ExtensionSlot(browser: browser, edge: prefs.sidePosition == .right ? .leading : .trailing, room: 0)
                BookmarkDoor(browser: browser, arrowEdge: prefs.sidePosition == .right ? .leading : .trailing)
                // Only while a download is running, and a moment after.
                FetchDoor(browser: browser, fetches: fetches, arrowEdge: prefs.sidePosition == .right ? .leading : .trailing, live: live)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
        }
    }

    /// How many doors the foot has, stacked: what the rows stop short of.
    @MainActor static func doors(_ prefs: Preferences, _ fetches: Fetches, hanging: Bool = false) -> Int {
        var kept = 2  // the puzzle and bookmarks
        if FetchDoor.shows(fetches, prefs, hanging: hanging) { kept += 1 }
        return kept
    }

    /// The doors that always show, and downloads, side by side: what the
    /// lights' row must have to take them (SideBar.doorsUp).
    @MainActor static func keptWidth(_ prefs: Preferences) -> CGFloat {
        let kept = 3  // the puzzle, bookmarks and downloads
        return CGFloat(kept) * (26 + 2) - 2
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

/// The ground of the tab in front, matched from row to row as another tab
/// is picked so that it glides there.
enum LivePill {
    @MainActor static func id(_ browser: Browser) -> String { "live" }
}

/// The ground's glide from row to row (LivePill).
struct LiveMatch: ViewModifier {
    @Environment(\.liquidTabs) private var liquid
    let id: String
    let space: Namespace.ID
    /// The live tab, for the pane of Liquid Glass laid under it instead
    /// (LiquidTab.swift): its ground says where it is. Nil where the grey
    /// stays, as on a pinned square.
    let tab: AnyHashable?

    init(id: String, in space: Namespace.ID, tab: AnyHashable? = nil) {
        self.id = id
        self.space = space
        self.tab = tab
    }

    func body(content: Content) -> some View {
        if liquid, let tab {
            content
                .matchedGeometryEffect(id: id, in: space)
                .anchorPreference(key: LiveLensKey.self, value: .bounds) { [LiveLensMark(tab: tab, anchor: $0)] }
        } else {
            content.matchedGeometryEffect(id: id, in: space)
        }
    }
}

/// A pinned tab as a cell in the block at the top of the column — as wide as
/// its row asks for, but never taller than the classic square, so a row with
/// room to spare turns into a wide, short button rather than a bigger icon.
private struct PinSquare: View, Equatable {
    @Environment(\.greys) private var greys
    @Environment(\.tabShortcutNumbers) private var shortcutNumbers
    let browser: Browser
    @ObservedObject var prefs: Preferences
    @ObservedObject var tab: Tab
    let live: Bool
    let pill: Namespace.ID
    var width: CGFloat = 34
    var height: CGFloat = 34
    /// Its letter being changed.
    private let lettering: Bool
    private let selected: Bool
    /// Picked with ⌘ or ⇧ along with others: its press leaves the pick be.
    private let pickedAmongOthers: Bool
    /// The peek opened from it, while it is up.
    private let peek: Tab?

    init(browser: Browser, prefs: Preferences, tab: Tab, live: Bool, pill: Namespace.ID,
         width: CGFloat = 34, height: CGFloat = 34) {
        self.browser = browser
        self.prefs = prefs
        self.tab = tab
        self.live = live
        self.pill = pill
        self.width = width
        self.height = height
        lettering = browser.editingPin == tab.id
        selected = browser.selectedTabIDs.contains(tab.id)
        pickedAmongOthers = browser.isPickedAmongOthers(tab)
        peek = browser.peekFrom == tab.id ? browser.peekTab : nil
    }

    static func == (a: PinSquare, b: PinSquare) -> Bool {
        a.browser === b.browser && a.prefs === b.prefs && a.tab === b.tab && a.live == b.live
            && a.pill == b.pill && a.width == b.width && a.height == b.height
            && a.lettering == b.lettering && a.selected == b.selected
            && a.pickedAmongOthers == b.pickedAmongOthers && a.peek === b.peek
    }

    @State private var hovering = false
    @State private var selectedOnPress = false

    /// Everything drawn inside scales off the shorter edge — the one that
    /// stays put — so the glyph sits at its usual size, centred, rather than
    /// stretching to chase the width.
    private var scale: CGFloat { min(width, height) }

    /// The pin's letter: full ink with High contrast text, otherwise soft
    /// grey until the square is live or under the pointer.
    private var pinLetter: Color {
        if live || prefs.highContrastText { return Palette.ink }
        return hovering ? Palette.ink.opacity(0.7) : Palette.muted
    }

    var body: some View {
        Group {
            if lettering {
                PinField(browser: browser, tab: tab)
            } else if let number = shortcutNumbers[tab.id] {
                TabShortcutNumber(number: number)
            } else if tab.loading {
                // Its page on the way, as a row's ring says.
                Ring(size: scale * 11 / 34)
            } else if prefs.glyph == .icons, let icon = tab.icon {
                Mark(icon: icon, letter: tab.pin ?? "", size: scale * 16 / 34, dim: tab.asleep,
                     contrast: prefs.highContrastText)
            } else {
                Text(tab.pin ?? "")
                    .font(.system(size: scale * 12 / 34, weight: .medium))
                    .foregroundStyle(pinLetter.opacity(tab.asleep ? 0.45 : 1))
            }
        }
        .frame(width: scale * 16 / 34, height: scale * 16 / 34)
        .frame(width: width, height: height)
        .background {
            Group {
                if live {
                    // Darker than the resting squares' grey by as much as a live
                    // row is darker than the white it sits on (Drice: the live
                    // pin barely showed among the others).
                    RoundedRectangle(cornerRadius: scale * 9 / 34, style: .continuous)
                        .fill(greys.pinLive)
                        .modifier(LiveMatch(id: LivePill.id(browser), in: pill))
                } else {
                    RoundedRectangle(cornerRadius: scale * 9 / 34, style: .continuous)
                        .fill(selected ? greys.wash :
                              hovering ? greys.hover : greys.tile)
                }
            }
            .animation(Motion.quick, value: live)
        }
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: scale * 9 / 34, style: .continuous)
                    .strokeBorder(Palette.ink.opacity(0.35), lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topTrailing) {
            // The peek opened from it, while it is up.
            if let page = peek {
                PeekBadge(page: page, size: scale * 16 / 34)
                    .offset(x: scale * 4 / 34, y: -scale * 4 / 34)
            }
        }
        .animation(Motion.quick, value: peek?.id)
        .contentShape(RoundedRectangle(cornerRadius: scale * 9 / 34, style: .continuous))
        .modifier(TabPress(enabled: !lettering && !pickedAmongOthers, active: live, selected: $selectedOnPress) {
            browser.clearTabSelection()
            browser.select(tab)
        })
        .modifier(OneClick(double: live) {
            guard !selectedOnPress, TabClick.flags.intersection([.command, .shift, .option]).isEmpty else { return }
            browser.clearTabSelection()
            if live { browser.goHome(tab) } else { browser.select(tab) }
        })
        .modifier(ModifiedTabClick { browser.extendTabSelection(to: tab, modifiers: $0) })
        .modifier(OptionClick { if !lettering { browser.optionClick(tab) } })
        // Put down, like ⌘W: close() is what knows a pin isn't removed.
        .overlay { MiddleClick { browser.close(tab) } }
        .onHover { hovering = $0 }
        .contextMenu { TabMenu(browser: browser, tab: tab, close: { browser.close(tab) }) }
        .help(tab.label)
        .animation(nil, value: hovering)
        .transition(.scale(scale: 0.8).combined(with: .opacity))
    }
}

/// A loose row of the column: its tab's id, its place among the loose rows
/// and the tab in it.
private struct LooseRow: Identifiable {
    let id: Tab.ID
    let index: Int
    let tab: Tab
}

/// One tab, as a line in the column.
///
/// It doesn't watch the Browser. The little of it a row shows is read as the
/// column makes the row, and a row is drawn again only when that, its tab or
/// the settings change (==): watching the whole Browser, every row was drawn
/// again for anything that changed in the window. The Browser is kept for
/// what a click on the row does.
private struct SideRow: View, Equatable {
    @Environment(\.liquidTabs) private var liquid
    @Environment(\.greys) private var greys
    @Environment(\.tabShortcutNumbers) private var shortcutNumbers
    let browser: Browser
    @ObservedObject var prefs: Preferences
    @ObservedObject var tab: Tab
    let live: Bool
    let pill: Namespace.ID
    let close: () -> Void
    var interactive = true
    /// Its address being typed in the row.
    private let editing: Bool
    /// Picked with ⌘ or ⇧.
    private let selected: Bool
    /// Picked along with others: its press leaves the pick be.
    private let pickedAmongOthers: Bool
    /// The peek opened from it, while it is up.
    private let peek: Tab?
    /// Bumped when what was typed in a tab can't be gone to (see Shake).
    private let refusals: Int
    /// Its cross is a minus: closing it puts its page away (Browser.putsAway).
    private let putsAway: Bool
    /// In a group, with groups on: a page put away from it stays a row there.
    private let grouped: Bool

    init(browser: Browser, prefs: Preferences, tab: Tab, live: Bool, pill: Namespace.ID,
         close: @escaping () -> Void, interactive: Bool = true) {
        self.browser = browser
        self.prefs = prefs
        self.tab = tab
        self.live = live
        self.pill = pill
        self.close = close
        self.interactive = interactive
        editing = interactive && browser.editingTab == tab.id
        selected = browser.selectedTabIDs.contains(tab.id)
        pickedAmongOthers = browser.isPickedAmongOthers(tab)
        peek = browser.peekFrom == tab.id ? browser.peekTab : nil
        refusals = browser.refusals
        putsAway = browser.putsAway(tab)
        grouped = prefs.usesTabGroups && browser.group(of: tab) != nil
    }

    /// The close action is left out: it closes the same tab every time.
    static func == (a: SideRow, b: SideRow) -> Bool {
        a.browser === b.browser && a.prefs === b.prefs && a.tab === b.tab && a.live == b.live
            && a.pill == b.pill && a.interactive == b.interactive && a.editing == b.editing
            && a.selected == b.selected && a.pickedAmongOthers == b.pickedAmongOthers
            && a.peek === b.peek && a.refusals == b.refusals && a.putsAway == b.putsAway
            && a.grouped == b.grouped
    }

    @State private var hovering = false
    @State private var selectedOnPress = false
    @State private var shake: CGFloat = 0
    @State private var pressed = false

    /// The ring or the speaker, which stay for as long as the page loads or
    /// plays (or is muted) and so keep a place of their own at the end of the
    /// row. The cross is only there under the pointer, and takes none.
    private var status: Bool { !editing && (tab.loading || speaker) }
    /// The speaker, which can be pressed, and so steps in beside the cross
    /// under the pointer rather than hiding beneath it as the ring does.
    private var speaker: Bool { !tab.loading && (tab.noisy || tab.muted) }
    /// A pinned row with a peek opened from it: the peek's icon at its end,
    /// as on a square's corner.
    private var peeking: Bool { !editing && tab.pin != nil && peek != nil }
    /// Where the page is, said on the row you're on (Settings › Tabs › Show
    /// the address on the tab you're on).
    private var rest: AtRest? { live && !editing ? AtRest.said(tab.restAddress, always: prefs.showsAddress) : nil }
    private var atRest: Bool { rest != nil }
    /// A pin already put down has nothing left to put down: no minus (#1050).
    private var closable: Bool { tab.pin == nil || !tab.asleep }
    /// A grouped tab holding no page — put away with its minus (Browser.putAway),
    /// put to sleep, or not opened since launch: the row stays, dimmed as a
    /// pin put down is, so the minus is seen to have done something.
    /// Read from the tab here, not when the column made the row: the column
    /// isn't drawn again when one of its tabs lets its page go.
    private var putAway: Bool { grouped && tab.asleep && !live }
    /// Any other tab asleep, with Settings › Tabs › Dim sleeping tabs on:
    /// faded until the pointer is on it.
    private var dim: Bool { prefs.dimsSleepingTabs && tab.asleep && !live && !hovering && !putAway }

    var body: some View {
        let _ = Bench.count("row")
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                if editing {
                    TabAddressField(browser: browser)
                        .frame(height: 16)
                } else {
                    // The site's icon, or with Letters its letter: beside the
                    // title either way, as Settings says (#919).
                    if !tab.isBlank {
                        Mark(icon: prefs.glyph == .icons ? tab.icon : nil, letter: tab.monogram, size: 15,
                             dim: putAway || dim, contrast: prefs.highContrastText)
                            // A coding agent at work here: a dot on the
                            // icon's corner, the row as it was.
                            .overlay(alignment: .bottomTrailing) { AgentMark(tab: tab) }
                    }
                    if tab.bench, !tab.agent {
                        // A script's tab, not yours.
                        Image(systemName: "flask")
                            .font(.system(size: 9))
                            .foregroundStyle(colour.opacity(0.7))
                            .help("Opened by a script")
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
                    // A window the page asked for was refused (BlockedPopups).
                    PopupSign(browser: browser, tab: tab, colour: colour)
                    // The page is translated (Translate.swift).
                    TranslateSign(tab: tab, colour: colour)
                    TitleAtRest(label: tab.label, rest: rest, shown: atRest, hovering: hovering,
                                size: prefs.sideTitle, colour: colour, roomy: true, dim: dim, fades: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 10)
            .padding(.trailing, status || peeking ? 0 : 10)
            .frame(height: prefs.sideRow)
            // Stop, under the pointer, on the row the agent is working in.
            .overlay(alignment: .trailing) {
                if hovering, tab.agentWorking, !editing { AgentRowStop().padding(.trailing, 4) }
            }
            .contentShape(Rectangle())
            .modifier(TabPress(enabled: interactive && !editing && !pickedAmongOthers, active: live, selected: $selectedOnPress, pressing: $pressed) {
                browser.clearTabSelection()
                browser.select(tab)
            })

            if peeking, let page = peek {
                // Under the pointer the cross takes its place, unless the
                // ring or the speaker already holds the end of the row.
                PeekBadge(page: page, size: 16)
                    .opacity(hovering && !status ? 0 : 1)
            }

            if interactive, !editing, let number = shortcutNumbers[tab.id] {
                TabShortcutNumber(number: number)
                    .padding(.trailing, status ? 0 : 28)
            }

            if status {
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
        .padding(.trailing, status || peeking ? 7 : 0)
        .frame(height: prefs.sideRow)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The title keeps its length under the pointer and fades out
        // beneath the cross, rather than being cut shorter, so its end
        // doesn't jump on each row the pointer passes.
        .mask {
            ZStack {
                Rectangle().opacity(hovering && closable && !editing && !status ? 0 : 1)
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
                    if hovering && closable {
                        // A pinned row is put down, not closed (see
                        // Browser.close), and says so, as Arc's does; so is
                        // a grouped tab's page while it is open (closeTab).
                        Image(systemName: tab.pin != nil || (putsAway && !tab.asleep) ? "minus" : "xmark")
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
                        .frame(width: 30, height: prefs.sideRow)
                        .contentShape(Rectangle())
                        .onTapGesture { if hovering && closable { close() } }
                }
                .padding(.trailing, 7)
            }
        }
        .animation(Motion.quick, value: tab.loading)
        .animation(Motion.quick, value: speaker)
        .animation(Motion.quick, value: tab.blockedPopups.isEmpty)
        .animation(Motion.quick, value: tab.translation == nil)
        .animation(Motion.quick, value: peeking)
        .background { ground.animation(Motion.quick, value: live) }
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Palette.ink.opacity(0.35), lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
        .modifier(Shake(travel: shake))
        .modifier(Give(pressed: pressed && prefs.tabsGive))
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .modifier(OneClick(double: false) {
            guard interactive, !selectedOnPress, TabClick.flags.intersection([.command, .shift, .option]).isEmpty else { return }
            browser.clearTabSelection()
            if live { browser.beginTabEdit(tab) } else { browser.select(tab) }
        })
        .modifier(ModifiedTabClick { if interactive && !editing { browser.extendTabSelection(to: tab, modifiers: $0) } })
        .modifier(OptionClick { if interactive && !editing { browser.optionClick(tab) } })
        .overlay { if interactive { MiddleClick(act: close) } }
        .onHover(perform: hover)
        .onAppear { if interactive { Bench.rowAppeared(tab.id, hover: hover) } }
        .onDisappear { if interactive { Bench.rowDisappeared(tab.id) } }
        .onChange(of: tab.id) { was, now in
            guard interactive else { return }
            Bench.rowDisappeared(was)
            Bench.rowAppeared(now, hover: hover)
        }
        .contextMenu { if interactive { TabMenu(browser: browser, tab: tab, close: close) } }
        .background {
            if interactive && prefs.splitView {
                SplitDropZone(browser: browser, tab: tab, kind: .strip)
            }
        }
        .animation(nil, value: hovering)
        .animation(Motion.glide, value: editing)
        .animation(Motion.quick, value: dim)
        .onChange(of: refusals) { _, _ in
            guard editing else { return }
            shake = 0
            withAnimation(.easeOut(duration: 0.5)) { shake = 1 }
        }
        .transition(.scale(scale: 0.94, anchor: .leading).combined(with: .opacity))
    }

    private func hover(_ over: Bool) { hovering = over }

    @ViewBuilder
    private var ground: some View {
        if live {
            ZStack(alignment: .leading) {
                // Under a pane of Liquid Glass, the glass is its ground.
                Rectangle().fill(liquid ? Color.clear : greys.wash)
                if prefs.showsReading {
                    GeometryReader { geo in
                        ReadingFill(meter: tab.meter, width: geo.size.width)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .modifier(LiveMatch(id: LivePill.id(browser), in: pill, tab: tab.id))
        } else if selected {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(greys.wash)
        } else if hovering {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(greys.hover)
        }
    }

    private var colour: Color {
        // Black (white in the dark) for every title, as Zen's are, not the
        // soft grey High contrast text used to be the only way out of.
        putAway ? Palette.ink.opacity(0.45) : Palette.ink
    }
}

/// A row that is an action rather than a page. Quiet until the pointer is on it.
struct Quiet: View {
    @Environment(\.greys) private var greys
    let icon: String
    let title: String
    var height: CGFloat = 28
    var size: CGFloat = 12.5
    /// The icon alone, in the middle: the column of icons' new tab.
    var centred = false
    let act: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: act) {
            HStack(spacing: 8) {
                if centred { Spacer(minLength: 0) }
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .medium))
                    .frame(width: 15)
                if !title.isEmpty {
                    Text(title)
                        .font(.system(size: size))
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(hovering ? Palette.ink.opacity(0.7) : greys.faint)
            .padding(.leading, centred ? 0 : 10)
            .frame(height: height)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(hovering ? greys.hover : .clear)
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
    /// How many are drawn in the column, for the bench (`columnscroll`).
    /// Test runs only.
    @MainActor static var drawn = 0
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
                .shortcutHelp { "Close the tabs under the line. Pins and groups stay; \($0.display("file.reopen") ?? "Reopen Closed Tab") brings them all back." }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: KeepLine.height)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onAppear { if Store.testing { KeepLine.drawn += 1 } }
        .onDisappear { if Store.testing { KeepLine.drawn -= 1 } }
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
    @Environment(\.greys) private var greys
    let icon: String
    var on = false
    var help = ""
    /// The command this button does too (Shortcuts.swift): its key, as it
    /// stands in Settings › Shortcuts, joins the tooltip (shortcutHelp).
    var shortcut: String? = nil
    /// What holding the button down opens, as Back and Forward list the
    /// pages that way. Nil, or a nil menu, and a hold is just a slow click.
    var held: (() -> NSMenu?)? = nil
    /// Moves the symbol sideways in its button, for one whose ink isn't
    /// centred in its own box: the puzzle's weighs almost a point left.
    var nudge: CGFloat = 0
    let act: () -> Void

    @State private var hovering = false
    /// The hold opened its menu: the click that ends the press is the
    /// menu's, not the button's.
    @State private var opened = false

    var body: some View {
        Button {
            if opened { opened = false } else { act() }
        } label: {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(on ? Palette.ink : (hovering ? Palette.ink.opacity(0.7) : Palette.muted))
                .offset(x: nudge)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(on ? greys.wash : (hovering ? greys.hover : .clear))
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.35).onEnded { _ in
                guard let menu = held?() else { return }
                opened = true
                // Opened under the pointer while the button is still down,
                // so dragging onto a row and letting go picks it, as in
                // Safari. popUp returns once the menu has closed.
                menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
                // The press ended inside the menu, so no click may reach the
                // button after all; don't let this one swallow the next.
                DispatchQueue.main.async { opened = false }
            },
            isEnabled: held != nil
        )
        // A right-click opens the same menu at once, as in Chrome.
        .overlay { if let held { RightClick(menu: held) } }
        .onHover { hovering = $0 }
        .shortcutHelp(help, shortcut)
        .animation(Motion.quick, value: hovering)
        .animation(Motion.quick, value: on)
    }
}

/// A right-click over a door, and only that. SwiftUI has no right-click of
/// its own short of a context menu built when the view is drawn, which would
/// list the pages as they were then. This view answers the hit test only for
/// a right-click, so every other click and the hover fall through to the
/// button beneath.
private struct RightClick: NSViewRepresentable {
    let menu: () -> NSMenu?

    func makeNSView(context: Context) -> Catcher { Catcher() }
    func updateNSView(_ view: Catcher, context: Context) { view.pages = menu }

    final class Catcher: NSView {
        var pages: (() -> NSMenu?)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard NSApp.currentEvent?.type == .rightMouseDown || DragStrip.probingRightClick else { return nil }
            return super.hitTest(point)
        }

        override func rightMouseDown(with event: NSEvent) {
            guard let menu = pages?() else { return }
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }

        /// The same menu, for the bench (`columnmenu`).
        override func menu(for event: NSEvent) -> NSMenu? { pages?() }
    }
}

/// A pinned square picked up and carried across the grid, its travel its
/// own: only the square being carried redraws as the hand moves, and the
/// grid only when it changes place.
struct PinCarried: ViewModifier {
    let index: Int
    let cells: [CGRect]
    /// Carried out over the tabs (see Carried.cross): true while they show
    /// where it would land, and the square then stays out of the grid's way.
    var cross: ((CGPoint) -> Bool)? = nil
    /// Let go: true when the tabs took it.
    var land: ((CGPoint?) -> Bool)? = nil
    let move: (Int) -> Void

    @State private var held = false
    @State private var from = 0
    @State private var travel: CGSize = .zero
    /// Put back by SwiftUI when the drag is called off as well as when it
    /// ends: the square's look changing under the hand calls it off, and the
    /// square stayed floating (see CarryGuard).
    @GestureState private var carrying = false
    @State private var ticket = UUID()

    func body(content: Content) -> some View {
        content
            // Read where the square is drawn this frame, partway through the
            // spring to its new cell, and only for the square in hand.
            .visualEffect { [held, travel, from, cells] content, proxy in
                guard held else { return content.offset(.zero) }
                let frame = proxy.frame(in: .named("pins"))
                return content.offset(PinCarried.offset(travel: travel, from: from, cells: cells,
                                                        now: CGPoint(x: frame.midX, y: frame.midY)))
            }
            // Under the hand exactly, as a row is (see Carried).
            .transaction { if held { $0.animation = nil } }
            .zIndex(held ? 1 : 0)
            .shadow(color: .black.opacity(held ? 0.16 : 0), radius: 10, y: 3)
            // Measured in the grid's own space, not the square's: a square
            // that has just been moved to a new cell would otherwise report
            // the drag from where it now is, and shuttle between two cells.
            .gesture(
                DragGesture(minimumDistance: 5, coordinateSpace: .named("pins"))
                    .updating($carrying) { _, carrying, _ in carrying = true }
                    .onChanged { value in
                        if !held {
                            held = true
                            from = index
                            CarryGuard.open(ticket, end: callOff)
                        }
                        travel = value.translation
                        if cross?(value.location) == true { return }
                        let target = PinCarried.target(travel: travel, from: from, cells: cells)
                        if target != index {
                            withAnimation(Motion.settle) { move(target) }
                        }
                    }
                    .onEnded { value in
                        guard CarryGuard.close(ticket) else { return }
                        _ = land?(value.location)
                        withAnimation(Motion.settle) {
                            held = false
                            travel = .zero
                        }
                    }
            )
            .onChange(of: carrying) { _, now in if !now { callOff() } }
    }

    /// Called off rather than let go: it stays in the cell it was last
    /// moved to, and nothing is dropped across.
    private func callOff() {
        CarryGuard.close(ticket)
        guard held else { return }
        _ = land?(nil)
        withAnimation(Motion.settle) {
            held = false
            travel = .zero
        }
    }

    /// The held square stays glued to the fingers; every other square is
    /// already where it belongs, because the move put it there. This only
    /// takes off what the held square got for free by changing cell under
    /// its own drag: as far as its centre is drawn `now`, which the spring
    /// to the new cell hasn't finished carrying yet.
    nonisolated static func offset(travel: CGSize, from: Int, cells: [CGRect], now: CGPoint) -> CGSize {
        guard cells.indices.contains(from) else { return .zero }
        let start = cells[from]
        return CGSize(width: travel.width - (now.x - start.midX), height: travel.height - (now.y - start.midY))
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

/// Room left under the rows, laid out again on every frame of a change to it.
private struct EndInset: ViewModifier, Animatable {
    var bottom: CGFloat
    var animatableData: CGFloat { get { bottom } set { bottom = newValue } }
    func body(content: Content) -> some View { content.padding(.bottom, bottom) }
}

/// Down by y, drawn again on every frame of a change to it.
private struct Rise: GeometryEffect {
    var y: CGFloat
    var animatableData: CGFloat {
        get { y }
        set { y = newValue }
    }
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 0, y: y))
    }
}

/// The column away, as ⌘S puts it, from the lights' row: where Safari and
/// Arc keep theirs, beside the window's own buttons, so the column can be
/// folded without a key (Preferences.foldButton). Out over the page (the
/// pointer at the edge brought it), the same click keeps it out beside the
/// page, as ⌘S does there.
private struct FoldDoor: View {
    @ObservedObject var browser: Browser
    /// The column down the window's right side: the icon mirrored to it.
    let right: Bool

    var body: some View {
        Door(icon: right ? "sidebar.right" : "sidebar.left",
             help: browser.folded ? "Keep the Sidebar Out   ⌘S" : "Hide Sidebar   ⌘S") {
            browser.toggleFold()
        }
        .accessibilityLabel(browser.folded ? "Show Sidebar" : "Hide Sidebar")
    }
}
