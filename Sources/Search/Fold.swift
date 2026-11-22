import SwiftUI
import WebKit

// The column of tabs, folded away with ⌘S.
//
// The column is two hundred and some points the page never gets back, even
// while all you do is read. Folded, the page takes the whole window. The tabs
// are one push against its edge away: the column slides out over the
// page, the same column with the same rows, and goes again once the pointer
// leaves it. A short grace before it goes, so a hand that overshoots on the
// way back in doesn't lose it.
//
// The traffic lights go with it. They live in the column's corner, and left
// alone over a page they sit on top of whatever the page put in its own
// corner — a logo, a menu button. They come back with the column when it
// slides out, which is also where the window is dragged from.
//
// Folding lasts as long as you leave it: each window's fold is written
// down with the window (windows.json) and comes back with it at the next
// launch and with ⇧⌘T, as Safari and Arc keep a hidden sidebar hidden
// (idea 738). A new window folds as the one it came from. Switching
// between the column and the strip still brings the tabs back out.
//
// Unless that is the reason: Settings can keep the column folded for good,
// Arc's way, and then the fold is where it rests, at launch and after every
// change of layout. ⌘S still brings it out to stay, and puts it away again.
// Folded like that, the edge is met far more often by a hand on its way
// somewhere else — the Dock, the window beside — than by one reaching for
// the tabs, so the column waits for the pointer to settle there a moment
// before it comes. Folded by hand with ⌘S, it comes at once, as it always did.
//
// The edge isn't only where the pointer stops. A hand flung at it, with the
// window away from the screen's own edge, sails past it off the window, and
// was never seen at the edge at all. Just past the edge counts as the edge,
// if the pointer got there from the window, not from beyond, and once it
// rests there a moment: a pointer only crossing to a display on that side
// goes on through. And while the column is out, a pointer just past the
// edge is still on it.
//
// While a tab's address is being typed into its row, the column stays out:
// the pointer drifting off it is no reason to take the field away.
//
// The strip across the top folds the same way: up out of the window, the
// page taking the full height, and back down over the page when the pointer
// rests against the top edge. There the edge is crossed on every trip to the
// menu bar just above, so the strip always waits for the pointer to settle.

extension Browser {
    /// ⌘S. The column, or the strip across the top, out of the way, or back.
    func toggleFold() {
        // Asked to keep the tabs in sight: the column goes to icons only and
        // back to its titles, the layout Settings calls Icons only, and is
        // not folded away. One folded before the switch was turned on comes
        // out first, as it always did.
        if prefs.shrinks, !folded {
            // Narrowed to the strip by its edge: the titles come back, as
            // pulling the edge out would bring them.
            // The other spaces' rows, kept out of sight for a swipe, out of
            // the column while its width glides: laid out again with it,
            // with three spaces of 25 tabs the column moved on every other
            // frame at best (idea 927, since 1.0.16: frames 20 ms apart at
            // 120 Hz, 8 with one space). Made again once it rests, as after
            // the edge is let go (SideBar.pages).
            turnTicket += 1
            let ticket = turnTicket
            if !columnTurning { columnTurning = true }
            withAnimation(Motion.glide) {
                if prefs.narrowStrip { prefs.narrowed = false } else { prefs.sideIcons.toggle() }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self, ticket == self.turnTicket else { return }
                self.columnTurning = false
            }
            return
        }
        // Out over the page already (the pointer at the edge brought it):
        // it stays where it is, beside the page now. Put away first and then
        // brought out, it went for a frame — the page bare where the column
        // had been, the window's buttons over it — and slid out again.
        if folded, peeking {
            foldTicket += 1
            moveColumn(out: true) {
                self.peeking = false
                self.folded = false
            }
            return
        }
        // Only if it was out: set at all, every row of the column is built
        // again, 30 of them with 30 tabs, before the slide starts.
        if peeking { peeking = false }
        foldTicket += 1
        // Going away, however the column or the strip moves, what a page
        // grows into is in its own colour until WebKit has drawn it there
        // (see cover). Called off, it shrinks back and the cover goes.
        if !folded, !foldingAway { Browser.cover(shownPages) }
        // Pressed again before the column went: it stays.
        if foldingAway {
            foldingAway = false
            return
        }
        // Going away, the page is given the column's room first, and the
        // column slides only once WebKit has drawn the page at that size.
        // Given it as the slide started, the page grew while it slid, and
        // what WebKit hadn't drawn yet came in from the far edge as a bar
        // of the web view's own ground, black or white with the theme. Out
        // over the far edge, where the room goes, nothing of it shows.
        let pages = shownPages
        if !folded, prefs.sidebar, !Motion.reduced, !pages.isEmpty {
            let ticket = foldTicket
            foldingAway = true
            Browser.drawn(pages, within: 0.12) { [weak self] in
                guard let self, ticket == self.foldTicket, self.foldingAway else { return }
                self.moveColumn(out: false) {
                    self.foldingAway = false
                    self.folded = true
                }
            }
            return
        }
        moveColumn(out: folded) { self.folded.toggle() }
    }

    /// `change`, which brings the column out (`out`) or puts it away, on
    /// the column's motion: its slide (Motion.folding), nothing under
    /// Reduce Motion, or with Slide the column in and out on under Reduce
    /// Motion a fade where it stands (Motion.fadesColumn). Fading, the
    /// column is held in its place (`fadeHeld`) while its opacity goes, and
    /// only then sent off the window's edge, where it waits for the next
    /// time; coming back, it is put in its place, still clear, a turn
    /// before it fades in.
    func moveColumn(out: Bool, _ change: @escaping () -> Void) {
        guard prefs.sidebar, Motion.fadesColumn else {
            withAnimation(Motion.folding(out: out)) { change() }
            return
        }
        fadeTicket += 1
        let ticket = fadeTicket
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) { fadeHeld = true }
        // Nothing else moves, as under Reduce Motion: the page takes or
        // gives its room at once. Only the column's opacity is animated, by
        // its own modifier (see Fold).
        if out {
            DispatchQueue.main.async { withTransaction(Transaction()) { change() } }
        } else {
            withTransaction(Transaction()) { change() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Motion.fade + 0.05) { [weak self] in
            guard let self, ticket == self.fadeTicket else { return }
            withTransaction(still) { self.fadeHeld = false }
        }
    }

    /// The pages on screen beside the column: the one in front, and its
    /// other half in Split View.
    private var shownPages: [WKWebView] {
        guard let active else { return [] }
        let tabs = activeSplit.map { pair in pair.tabs.compactMap { id in tabs.first { $0.id == id } } } ?? [active]
        return tabs.compactMap { $0.isWeb && !$0.asleep && !$0.floating ? $0.built : nil }
    }

    /// `done` once each of `pages` has its new size and WebKit has put it
    /// on screen drawn at that size — its next presentation after the
    /// resize, asked of its private side — or after `within` seconds,
    /// whichever is first: a WebKit without that question, or a page too
    /// busy to answer, holds nothing up for long.
    static func drawn(_ pages: [WKWebView], within: TimeInterval, _ done: @escaping @MainActor () -> Void) {
        var finished = false
        let finish = {
            guard !finished else { return }
            finished = true
            done()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + within) { MainActor.assumeIsolated { finish() } }
        // Asked before the layout that resizes them, the next presentation
        // is the one already on its way, at the old size.
        let sizes = pages.map(\.frame.size)
        func resized() {
            guard !finished else { return }
            guard zip(pages, sizes).contains(where: { $0.frame.size != $1 }) else {
                DispatchQueue.main.async { MainActor.assumeIsolated { resized() } }
                return
            }
            presented(pages, finish)
        }
        DispatchQueue.main.async { MainActor.assumeIsolated { resized() } }
    }

    /// What each of `pages` grows into, once its size changes, covered in
    /// the page's own colour until WebKit has drawn it at that size.
    ///
    /// WebKit draws a page that has grown at its old size until its web
    /// process has laid it out again, and the rest of the view shows the web
    /// view's own ground: black or white with the theme, the column's width
    /// across. A page waited for (see `drawn`) is ready before the column
    /// moves; one busy for longer than that wait — a large app, a page that
    /// does work on resize — had the bar slide into the window on the far
    /// side and stay there until it was ready (idea 737, seen frame by
    /// frame at 250 ms). Reduce Motion and the strip across the top, which
    /// give the page its room at once, showed it too. The cover lies over
    /// only what the page hasn't drawn, in the colour WebKit gives the
    /// page's surround, and goes once the page has been put on screen at
    /// its new size, or after a second whatever happens.
    static func cover(_ pages: [WKWebView]) {
        guard !pages.isEmpty else { return }
        let sizes = pages.map(\.frame.size)
        let until = CFAbsoluteTimeGetCurrent() + 0.25
        // Covered here, so the stage leaves them be (PaneStage.backPages).
        pages.forEach { FoldCover.coming.add($0) }
        func resized() {
            let grown = zip(pages, sizes).filter { page, size in
                page.frame.width > size.width + 0.5 || page.frame.height > size.height + 0.5
            }
            guard !grown.isEmpty else {
                guard CFAbsoluteTimeGetCurrent() < until,
                      zip(pages, sizes).allSatisfy({ $0.frame.size == $1 }) else {
                    pages.forEach { FoldCover.coming.remove($0) }
                    return
                }
                DispatchQueue.main.async { MainActor.assumeIsolated { resized() } }
                return
            }
            pages.forEach { FoldCover.coming.remove($0) }
            var covers: [NSView] = []
            for (page, old) in grown {
                for rect in undrawn(page, old: old) {
                    let cover = FoldCover(frame: rect)
                    cover.wantsLayer = true
                    cover.layer?.backgroundColor = page.underPageBackgroundColor.cgColor
                    page.addSubview(cover)
                    covers.append(cover)
                }
            }
            Bench.foldCovers = covers.count
            var gone = false
            let remove = {
                guard !gone else { return }
                gone = true
                covers.forEach { $0.removeFromSuperview() }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { MainActor.assumeIsolated { remove() } }
            presented(grown.map(\.0), remove)
        }
        DispatchQueue.main.async { MainActor.assumeIsolated { resized() } }
    }

    /// The part of `page`, now larger than `old`, that WebKit has yet to
    /// draw: past the old width, and below the old height. Its drawing
    /// keeps to the top left corner.
    static func undrawn(_ page: NSView, old: CGSize) -> [CGRect] {
        let size = page.bounds.size
        var rects: [CGRect] = []
        if size.width > old.width {
            rects.append(CGRect(x: old.width, y: 0, width: size.width - old.width, height: size.height))
        }
        if size.height > old.height {
            let tall = size.height - old.height
            rects.append(CGRect(x: 0, y: page.isFlipped ? old.height : 0, width: min(old.width, size.width), height: tall))
        }
        return rects
    }

    private static func presented(_ pages: [WKWebView], _ finish: @escaping @MainActor () -> Void) {
        var left = pages.count
        let ask = NSSelectorFromString("_doAfterNextPresentationUpdate:")
        for page in pages {
            guard page.responds(to: ask), let imp = page.method(for: ask) else { continue }
            typealias Then = @convention(block) () -> Void
            typealias After = @convention(c) (AnyObject, Selector, Then) -> Void
            let then: Then = {
                MainActor.assumeIsolated {
                    left -= 1
                    if left == 0 { finish() }
                }
            }
            unsafeBitCast(imp, to: After.self)(page, ask, then)
        }
    }

    /// The folded column out over the page, or back in.
    func peek(_ out: Bool) {
        moveColumn(out: out) { self.peeking = out }
    }

    /// A page filling the screen in front of this window. With
    /// Preferences.keepsWindow, one settled in a Space of its own isn't, once
    /// this window's Space is the one in view: the window is whole again, to
    /// be used beside the video.
    func fillsHere(_ tab: Tab) -> Bool {
        guard tab.immersed else { return false }
        guard prefs.keepsWindow, let window, tab.built?.fullscreenState == .inFullscreen else { return true }
        return !window.isOnActiveSpace
    }

    /// The tab in front is such a page.
    var frontFillsHere: Bool { active.map(fillsHere) ?? false }

    /// Whether something of the window's lies over `page` at `point`, in the
    /// window's own coordinates: a peek over the page in front (not over its
    /// own), the address field or a panel over it, the Find bar, or the
    /// folded column or strip out over the page. The page then
    /// hears nothing of the pointer there (see PageView.underCover).
    func covers(_ page: NSView, at point: NSPoint) -> Bool {
        guard let window, page.window === window else { return false }
        if peekInFront, let peek = peekTab, peek.built !== page { return true }
        // The address field raised over the page in front, by ⌘L or by ⌘T's
        // floating field, dims all of that page and only that page: with
        // Split View on, the other pane is still there to point at.
        if editing, let active, !active.isBlank, active.built === page { return true }
        // What comes over the whole window: the ⌃Tab switcher, the hidden
        // elements' list and a site's style (a click beside either puts it
        // away), Welcome and What's New.
        if tabSwitcher.visible || reviewing || styling != nil || welcoming || newsShowing { return true }
        // The Find bar is a pill over one corner of the page: whatever a
        // click there would land on decides. Asking the window costs far more
        // than the flags above, so only while the bar is open.
        if finding, let frame = window.contentView?.superview,
           let hit = frame.hitTest(frame.convert(point, from: nil)),
           hit !== page, !hit.isDescendant(of: page) {
            return true
        }
        guard folded, peeking, !frontFillsHere, let size = window.contentView?.bounds.size else { return false }
        if !prefs.sidebar { return point.y >= size.height - Metrics.strip }
        return prefs.sidePosition == .right ? point.x >= size.width - prefs.columnWidth : point.x <= prefs.columnWidth
    }
}

/// Over the window: the column, beside the page or folded away, and the
/// strip while it is folded; out over the page once the pointer is at the
/// window's chosen side, or its top edge.
struct Fold: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    /// The column's width while its edge is held, for the page beside it
    /// (see HeldEdges).
    var onDrag: (CGFloat?) -> Void = { _ in }

    /// The column going back in, a moment after the pointer left it.
    @State private var leaving: DispatchWorkItem?
    /// The column coming out, once the pointer has settled on the edge.
    @State private var arriving: DispatchWorkItem?
    /// The pointer is over the column.
    @State private var inside = false
    @State private var pointer = Pointer()

    /// How near the edge the pointer has to be.
    private static let edge: CGFloat = 6
    /// For a column hidden for good, which waits for the pointer to settle
    /// (see dwell): a wider edge to find, as a hand reaches for it (#1279).
    private static let hiddenEdge: CGFloat = 10
    /// How far past the window's edge, on the column's side, the pointer
    /// still counts as on it.
    private static let overshoot: CGFloat = 48
    /// The grace before the column goes back in. With the time the slide
    /// takes to start, the column begins to go as soon after the pointer
    /// leaves as Dia's does. Arc doesn't wait at all, which loses the column
    /// to a hand that overshoots on the way back in.
    private static let grace: TimeInterval = 0.065
    /// How far down from the top, in full screen, the edge leaves the
    /// window's buttons alone: the menu bar and the title bar macOS brings
    /// down with it.
    static let fullScreenCorner: CGFloat = 60
    /// The band along the top that is the title bar over the page. At 8
    /// it was hard to find with the pointer; 12 is still under a page's
    /// own first line of anything to click.
    private static let top: CGFloat = 12
    /// How long the pointer rests on the edge before the strip comes out,
    /// whose edge is the way to the menu bar. Long enough to cross the edge,
    /// short enough not to be waited for.
    private static let dwell: TimeInterval = 0.15
    /// The same for a column hidden for good: a hand on its way along the
    /// side crosses its edge in a frame or two, and anything longer was felt
    /// as a wait (#1279).
    private static let columnDwell: TimeInterval = 0.05

    var body: some View {
        ZStack(alignment: onRight ? .topTrailing : .topLeading) {
            // In the column's mode the page reaches the window's top edge —
            // beside the column, and everywhere once it is folded away — and
            // there was nowhere there to drag the window from, or to
            // double-click to fill the screen: only the column's own corner,
            // gone when folded. A band too thin to be in a page's way stands
            // in for the title bar along the whole top; the column lies over
            // it with its own. The strip across the top, folded away, leaves
            // the page the top edge too, and the same band: there was nothing
            // to take hold of until the strip came down. Unfolded, the strip
            // is its own title bar, and no band lies over its tabs.
            if prefs.sidebar || folding, !browser.frontFillsHere {
                // Over the page, which keeps what it has to press there.
                DragStrip(overPage: true)
                    .frame(height: Fold.top)
                    .frame(maxWidth: .infinity)
            }
            if folding, !prefs.sidebar {
                // Kept while folded, above the window's top edge, and slid
                // down and back up, as the column is (see below).
                //
                // The row has no ground of its own: in the window it lies on
                // the window's. Out over the page it brings that ground along,
                // as the column does, or the page showed through between the
                // tabs, and the shadow fell from every title and icon rather
                // than from the row's edge.
                TabBar(browser: browser)
                    .modifier(FoldShadow(y: 4, behind: true, strength: browser.peeking ? 1 : 0))
                    .offset(y: browser.peeking ? 0 : -Metrics.strip)
                    .allowsHitTesting(browser.peeking)
            }
            ZStack(alignment: onRight ? .trailing : .leading) {
                Color.clear.frame(width: 0)
                if prefs.sidebar {
                    // The one column, beside the page or folded away: ⌘S
                    // slides it rather than trading it for another. Two
                    // columns, one beside the page and one here for the fold,
                    // had every row built four times over on each ⌘S, 130 to
                    // 165ms of the main thread with 30 tabs before the slide's
                    // first frame, against a slide of 150ms (measured
                    // 2026-11-06, bench foldtime).
                    //
                    // Kept while folded, off the window's edge, and slid out
                    // and back rather than made anew each time. Made anew,
                    // every row was built again on every peek, about 60ms of
                    // the main thread before the first frame, so the column
                    // came out late; and a pointer turning back met a new
                    // column rather than the one on its way in. It stays in
                    // accessibility while away: taken out of it as it went
                    // and put back as it came, its rows had the window's
                    // whole accessibility tree rebuilt each time, up to
                    // 120ms of the main thread with the slide waiting.
                    //
                    // Its shadow falls from a ground laid under it, as the
                    // strip's does. Cast by the column itself, it was drawn
                    // again from every row, icon and title on each frame of
                    // the slide, the column's full height over: in full
                    // screen, the whole screen's, and the slide lagged there.
                    // The column's own ground is opaque, so it is the same
                    // rectangle either way. It wears the window's ground, as
                    // it does beside the page's card (see CardEdge), or its
                    // own white where the page is no card.
                    // Away exactly when the lights are, which ride with it.
                    SideBar(browser: browser, prefs: prefs, onFrame: browser.asCards, onDrag: onDrag)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .modifier(FoldShadow(x: onRight ? -4 : 4, behind: true,
                                             strength: browser.folded && browser.peeking ? 1 : 0,
                                             ground: !browser.glassUnder))
                        // Faded rather than slid under Reduce Motion with
                        // Slide the column in and out on (Browser.moveColumn).
                        .animation(Motion.fadesColumn ? .easeInOut(duration: Motion.fade) : nil) { column in
                            column.opacity(lightsOff && Motion.fadesColumn ? 0 : 1)
                        }
                        .offset(x: lightsOff && !browser.fadeHeld ? (onRight ? prefs.columnWidth : -prefs.columnWidth) : 0)
                        .allowsHitTesting(!lightsOff)
                        .transition(.move(edge: onRight ? .trailing : .leading))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity,
                   alignment: onRight ? .trailing : .leading)
            // As the page beside it moves (see ContentView).
            .animation(Motion.glide, value: prefs.sidebar)
            .animation(Motion.glide, value: prefs.sidePosition)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity,
               alignment: onRight ? .topTrailing : .topLeading)
        .ignoresSafeArea()
        .onAppear {
            hideLights()
            watch()
        }
        .onDisappear {
            resetPending()
            pointer.stop()
        }
        // A column folded for good is folded before there is a window to
        // hide the lights of; they go once there is one.
        .background(WindowSetup { window in
            window.standardWindowButton(.closeButton)?.superview?.isHidden = lightsOff && !window.styleMask.contains(.fullScreen)
            pointer.window = window
            watch()
        })
        .onChange(of: lightsOff) { _, _ in hideLights() }
        // Into full screen, the buttons are given back to macOS; out of it,
        // they go the way the fold says again.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { note in
            if (note.object as? NSWindow) === browser.window { hideLights() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { note in
            if (note.object as? NSWindow) === browser.window { hideLights() }
        }
        .onChange(of: folding) { _, _ in
            resetPending()
            watch()
        }
        // Back to the strip and then to the column again: the column comes
        // back as it rests — whole, not folded from a time nobody remembers,
        // unless Settings says it rests folded.
        .onChange(of: prefs.sidebar) { _, _ in
            resetPending()
            browser.folded = prefs.sidebar && prefs.sideHides
            browser.peeking = false
        }
        .onChange(of: prefs.sidePosition) { _, _ in
            resetPending()
            browser.peeking = false
            // This window's own bar: every window hears the change, and each
            // had set the front window's by its own fold, the last one
            // deciding. In full screen the buttons are macOS's to show (see
            // hideLights); hidden here, they were missing from the bar that
            // comes down with the menu bar until the column next came out.
            if let window = browser.window, let bar = window.standardWindowButton(.closeButton)?.superview {
                Fold.reset(bar, hidden: lightsOff && !window.styleMask.contains(.fullScreen))
            }
        }
        .onChange(of: prefs.columnWidth) { _, _ in
            if browser.folded { hideLights() }
        }
        .onChange(of: prefs.sideHides) { _, hides in
            resetPending()
            guard prefs.sidebar else { return }
            browser.peeking = false
            browser.moveColumn(out: !hides) { browser.folded = hides }
        }
        // The address typed into a row is done with, and the pointer went
        // elsewhere while it was: the column goes the way it would have.
        .onChange(of: browser.editingTab) { _, editing in
            if editing == nil, !inside, browser.peeking { peek(false) }
        }
        // The bookmarks list closed with the pointer elsewhere: the same.
        .onChange(of: browser.bookmarksOpen) { _, open in
            if !open, !inside, browser.peeking { peek(false) }
        }
    }

    /// A popover opened from a button in the column, still open: the
    /// bookmarks list or the extensions menu. Folding the column would take
    /// it along, so it holds the column out wherever the pointer has gone,
    /// on the way to a bookmark over the page included (#88).
    private var holding: Bool {
        if browser.bookmarksOpen { return true }
        if #available(macOS 15.4, *), Extensions.shared.menuOpen { return true }
        return false
    }

    /// Folded, and not taken over by a page filling the screen.
    private var folding: Bool {
        browser.folded && !browser.frontFillsHere
    }

    private var lightsOff: Bool {
        browser.folded && !browser.peeking
    }

    private var onRight: Bool {
        prefs.sidebar && prefs.sidePosition == .right
    }

    private func resetPending() {
        arriving?.cancel()
        arriving = nil
        leaving?.cancel()
        leaving = nil
        inside = false
    }

    /// The pointer is watched only while there is something folded for it
    /// to bring out; the rest of the time no move of it costs anything.
    private func watch() {
        if folding {
            pointer.start { follow() }
        } else {
            pointer.stop()
        }
    }

    /// Opens or closes the column from the pointer's actual position, on
    /// every move. Hover events weren't enough: a view that appears under a
    /// still pointer never gets "entered", so it never gets "exited" either,
    /// and after a few quick opens and closes the column stayed open, or the
    /// edge stopped opening it.
    private func follow() {
        guard folding, let window = pointer.window, window.isVisible else { return pass() }
        let screen = NSEvent.mouseLocation
        let point = window.convertPoint(fromScreen: screen)
        let size = window.frame.size
        let inWindow = point.x >= 0 && point.x < size.width && point.y >= 0 && point.y < size.height
        // Distance from the column's edge for the column, from the top for
        // the strip.
        let distance = prefs.sidebar ? (onRight ? size.width - point.x : point.x) : size.height - point.y
        // Just past the column's edge, beside the window rather than above
        // or below it, come off the window to get there, and not on the Dock
        // or the menu bar.
        let past = onRight ? point.x - size.width : -point.x
        let beside = prefs.sidebar && past > 0 && past < Fold.overshoot
            && point.y >= 0 && point.y < size.height
        let overshot = beside && pointer.crossing
            && NSScreen.screens.contains { $0.visibleFrame.contains(screen) }
        pointer.crossing = inWindow || overshot
        if browser.peeking {
            pass()
            // Only this window counts, not another app's window over it. One
            // of this app's own windows, such as a popover opened from the
            // column, counts as the column.
            let top = NSWindow.windowNumber(at: screen, belowWindowWithWindowNumber: 0)
            let onWindow = top == window.windowNumber
            let onOwnPanel = !onWindow && NSApp.windows.contains { $0.windowNumber == top }
            let reach = prefs.sidebar ? prefs.columnWidth : Metrics.strip
            // An extension's popup hangs from its button in the column: the
            // column stays out while it is up, or the popup is left hanging
            // from nothing (see ExtensionPopup).
            let popup = if #available(macOS 15.4, *) { ExtensionPopup.shared.isUp } else { false }
            let over = onOwnPanel || popup || holding || overshot || (onWindow && inWindow && distance < reach)
            if over != inside { inside = over }
            peek(over)
        } else if inWindow, distance < (prefs.sidebar && prefs.sideHides ? Fold.hiddenEdge : Fold.edge),
                  // In full screen, not from the corner where macOS brings
                  // the window's buttons down with the menu bar: the column
                  // came out over them there, on the way to the red one (#241).
                  !(prefs.sidebar && window.styleMask.contains(.fullScreen) && size.height - point.y < Fold.fullScreenCorner) {
            // Which window is under the pointer is asked only here, at the
            // edge: another app's window over it doesn't bring the column out.
            guard NSWindow.windowNumber(at: screen, belowWindowWithWindowNumber: 0) == window.windowNumber
            else { return pass() }
            if arriving == nil { arrive() }
        } else if overshot {
            // Off the window, so whatever is under the pointer isn't it. The
            // wait starts again with every move: the column comes once the
            // pointer stops, not while it is on its way somewhere else.
            // Unless it is pinned against the screen's own edge, with no
            // display beyond: it has nowhere else to be going. A window kept
            // off the screen's edge by a tiling window manager's gaps
            // otherwise always waited here, and a hand still settling after
            // the fling started the wait again with every move. Not with the
            // Dock hidden on that side, which the same push brings out.
            let further = NSPoint(x: screen.x + (onRight ? 1 : -1), y: screen.y)
            if NSScreen.screens.contains(where: { NSMouseInRect(further, $0.frame, false) })
                || Fold.dockHides(right: onRight) {
                arrive(resting: true)
            } else {
                pass()
                peek(true)
            }
        } else {
            pass()
        }
    }

    /// Whether the Dock hides on the screen's `right` (or left) edge, and
    /// comes out there when the pointer pushes against it.
    static func dockHides(right: Bool) -> Bool {
        guard let dock = UserDefaults(suiteName: "com.apple.dock"), dock.bool(forKey: "autohide") else { return false }
        return dock.string(forKey: "orientation") == (right ? "right" : "left")
    }

    /// The pointer on the edge: out at once, or after the dwell when the
    /// column is folded for good, and always for the strip, whose edge is
    /// the way to the menu bar, and for the pointer just past the edge.
    private func arrive(resting: Bool = false) {
        guard resting || !prefs.sidebar || prefs.sideHides else { return peek(true) }
        pass()
        let coming = DispatchWorkItem {
            arriving = nil
            peek(true)
        }
        arriving = coming
        DispatchQueue.main.asyncAfter(deadline: .now() + (prefs.sidebar ? Fold.columnDwell : Fold.dwell), execute: coming)
    }

    /// The pointer crossed the edge without stopping.
    private func pass() {
        guard let arriving else { return }
        arriving.cancel()
        self.arriving = nil
    }

    /// Out at once; in only once the pointer has stayed away for the grace,
    /// counted from when it left rather than from its latest move.
    private func peek(_ out: Bool) {
        if out {
            if let leaving {
                leaving.cancel()
                self.leaving = nil
            }
            guard !browser.peeking else { return }
            browser.peek(true)
        } else {
            guard leaving == nil else { return }
            let going = DispatchWorkItem {
                leaving = nil
                guard browser.editingTab == nil, !holding else { return }
                browser.peek(false)
            }
            leaving = going
            DispatchQueue.main.asyncAfter(deadline: .now() + Fold.grace, execute: going)
        }
    }

    /// The title bar's own view holds the three buttons and the resting
    /// circles drawn over them while the app is behind (see RestingLights),
    /// so hiding it hides both, and hidden buttons take no clicks.
    private func hideLights() {
        guard let bar = browser.window?.standardWindowButton(.closeButton)?.superview else { return }
        // In full screen the buttons are macOS's to show, in the bar that
        // comes down with the menu bar; hidden or slid away here, they were
        // missing from it, or out of reach behind the column (#241).
        if browser.window?.styleMask.contains(.fullScreen) == true {
            bar.layer?.removeAnimation(forKey: "fold")
            bar.isHidden = false
            return
        }
        if prefs.sidebar {
            Fold.slide(bar, off: lightsOff, by: prefs.columnWidth, right: onRight)
        } else {
            Fold.slide(bar, off: lightsOff, by: Metrics.strip, up: true)
        }
    }

    /// The window in front's title bar, for the bench.
    static var titlebar: NSView? {
        Links.window?.standardWindowButton(.closeButton)?.superview
    }

    /// Bumped by every slide, so one that was overtaken doesn't hide the
    /// lights on its way out.
    private static var slides = 0

    /// Drop an overtaken slide when the column changes sides.
    static func reset(_ bar: NSView, hidden: Bool) {
        slides += 1
        bar.layer?.removeAnimation(forKey: "fold")
        bar.isHidden = hidden
    }

    /// The lights ride with the column, as everything else in its corner
    /// does. Shown or hidden at once, they stood in their place while the
    /// column was still sliding in under them, and vanished before it had
    /// gone. So they come in from the chosen edge and go back off it, on the
    /// column's own spring (Motion.fold, in Core Animation's terms) — from
    /// wherever they are, when the pointer turns back halfway. `up` sends
    /// the strip's lights off the top edge.
    static func slide(_ bar: NSView, off: Bool, by width: CGFloat, up: Bool = false,
                      right: Bool = false) {
        slides += 1
        let turn = slides
        guard let layer = bar.layer else {
            bar.isHidden = off
            return
        }
        // Faded in place with the column (Browser.moveColumn).
        if !up, Motion.fadesColumn {
            layer.removeAnimation(forKey: "fold")
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = bar.isHidden ? 0 : (layer.presentation()?.opacity ?? 1)
            fade.toValue = off ? 0 : 1
            fade.duration = Motion.fade
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            fade.fillMode = .forwards
            fade.isRemovedOnCompletion = false
            bar.isHidden = false
            CATransaction.begin()
            CATransaction.setCompletionBlock {
                MainActor.assumeIsolated {
                    guard turn == slides else { return }
                    layer.removeAnimation(forKey: "fold")
                    bar.isHidden = off
                }
            }
            layer.add(fade, forKey: "fold")
            CATransaction.commit()
            return
        }
        // With Reduce Motion on, the column comes and goes at once, and the
        // lights with it.
        if Motion.reduced {
            layer.removeAnimation(forKey: "fold")
            bar.isHidden = off
            return
        }
        // Up is +y in a superview that isn't flipped, -y in one that is.
        let path = up ? "transform.translation.y" : "transform.translation.x"
        let gone: CGFloat = up ? ((bar.superview?.isFlipped ?? false) ? -width : width)
            : (right ? width : -width)
        let other = up ? "transform.translation.x" : "transform.translation.y"
        let moving = layer.animation(forKey: "fold") != nil
        // A slide still running on the other axis — the layout was switched
        // halfway — is simply let go.
        if moving, (layer.animation(forKey: "fold") as? CABasicAnimation)?.keyPath == other {
            layer.removeAnimation(forKey: "fold")
        }
        let still = layer.animation(forKey: "fold") != nil
        let from = still
            ? (layer.presentation()?.value(forKeyPath: path) as? CGFloat ?? 0)
            : (bar.isHidden ? gone : 0)
        let to: CGFloat = off ? gone : 0
        guard from != to else {
            layer.removeAnimation(forKey: "fold")
            bar.isHidden = off
            return
        }
        let spring: CABasicAnimation
        if let slide = Motion.slide(out: !off) {
            // The column's eased slide (Slide the column in and out).
            spring = CABasicAnimation(keyPath: path)
            spring.timingFunction = CAMediaTimingFunction(name: off ? .easeIn : .easeOut)
            spring.duration = slide
        } else {
            let fold = Motion.fold(out: !off)
            let bounce = CASpringAnimation(keyPath: path)
            bounce.mass = 1
            bounce.stiffness = pow(2 * .pi / fold.response, 2)
            bounce.damping = 4 * .pi * fold.damping / fold.response
            bounce.duration = bounce.settlingDuration
            spring = bounce
        }
        spring.fromValue = from
        spring.toValue = to
        spring.fillMode = .forwards
        spring.isRemovedOnCompletion = false
        bar.isHidden = false
        CATransaction.begin()
        CATransaction.setCompletionBlock {
            MainActor.assumeIsolated {
                guard turn == slides else { return }
                layer.removeAnimation(forKey: "fold")
                bar.isHidden = off
            }
        }
        layer.add(spring, forKey: "fold")
        CATransaction.commit()
    }
}

/// The shadow the column or the strip casts over the page while it is out.
/// It draws past their edge, where a slide by their own size doesn't take
/// it: sliding away, the column was gone and its shadow still lay along the
/// window's edge, until it vanished at once (#441). So it goes with the
/// slide, from full to nothing, and is gone when they are. The slide itself
/// stays their size: the window's buttons ride in the column's corner by
/// exactly that much.
private struct FoldShadow: ViewModifier {
    var x: CGFloat = 0
    var y: CGFloat = 0
    /// Cast from a ground laid behind: the strip has no ground of its own,
    /// and a shadow from the row itself fell from every title and icon.
    /// Combined with the slide, this comes first and the offset second: the
    /// offset moves only what it wraps, and a ground laid outside it
    /// stayed where the column or the strip had been, a blank band over the
    /// page until the slide was over.
    var behind = false
    var strength: Double = 1
    /// Left out where the window's glass is to show through (see Glass.swift).
    var ground = true

    func body(content: Content) -> some View {
        let color = Color.black.opacity(0.14 * strength)
        if behind {
            content.background { (ground ? Palette.ground : Color.clear).shadow(color: color, radius: 20, x: x, y: y) }
        } else {
            content.shadow(color: color, radius: 20, x: x, y: y)
        }
    }
}

/// The pointer's moves, wherever it goes, while something is folded: over
/// this app's windows, and over everything else while another app is in
/// front, since the edge is still the edge with Search behind.
@MainActor
private final class Pointer {
    weak var window: NSWindow?
    /// The pointer is over the window, or just went off the column's edge from
    /// it and hasn't gone further.
    var crossing = false
    private var local: Any?
    private var global: Any?
    /// The window's own say on mouse-moved events, given back when the
    /// watch ends.
    private var accepted = false

    func start(_ moved: @escaping @MainActor () -> Void) {
        guard local == nil, let window else { return }
        crossing = false
        // The pointer's moves reach the monitor wherever it is over the
        // window, not only over what tracks it — for as long as the watch
        // lasts, and no longer.
        accepted = window.acceptsMouseMovedEvents
        window.acceptsMouseMovedEvents = true
        local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { event in
            MainActor.assumeIsolated { moved() }
            return event
        }
        global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { _ in
            MainActor.assumeIsolated { moved() }
        }
    }

    func stop() {
        guard local != nil || global != nil else { return }
        if let local { NSEvent.removeMonitor(local) }
        if let global { NSEvent.removeMonitor(global) }
        local = nil
        global = nil
        window?.acceptsMouseMovedEvents = accepted
    }
}

/// What a page has yet to draw while it grows (see Browser.cover): its
/// own colour, never in the way of the pointer.
final class FoldCover: NSView {
    /// Pages about to grow with ⌘S, whose new room a cover is coming for:
    /// the stage doesn't clear their ground for it as well (see
    /// PaneStage.backPages).
    @MainActor static let coming = NSHashTable<WKWebView>.weakObjects()

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isOpaque: Bool { true }
}

/// Settings › The column folded away › A loading line (idea 269): with the
/// tabs out of sight nothing said a page was coming, since the ring is on
/// its tab. A hairline along the page's top, as far as WebKit says the page
/// has come, only while it is loading. Drawn by a layer watching the view,
/// so the page's progress never makes SwiftUI lay anything out again.
struct LoadingLine: NSViewRepresentable {
    let web: WKWebView?

    func makeNSView(context: Context) -> LineView { LineView() }
    func updateNSView(_ view: LineView, context: Context) { view.watch(web) }
    static func dismantleNSView(_ view: LineView, coordinator: ()) { view.watch(nil) }

    final class LineView: NSView {
        private let line = CALayer()
        private var watched: [NSKeyValueObservation] = []
        private weak var web: WKWebView?
        /// What the bench reads: shown, and how far along.
        private(set) var shown = false
        private(set) var fraction: Double = 0

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            line.backgroundColor = NSColor.controlAccentColor.cgColor
            line.opacity = 0
            line.anchorPoint = .zero
            layer?.addSublayer(line)
        }

        required init?(coder: NSCoder) { nil }

        /// Seen, never pressed.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override var isFlipped: Bool { true }

        func watch(_ next: WKWebView?) {
            guard next !== web || (next == nil && !watched.isEmpty) else { return }
            watched = []
            web = next
            guard let next else { show(false, 0, animated: false); return }
            let changed: (WKWebView) -> Void = { [weak self] web in
                MainActor.assumeIsolated { self?.show(web.isLoading, web.estimatedProgress, animated: true) }
            }
            watched = [
                next.observe(\.estimatedProgress, options: [.new]) { web, _ in changed(web) },
                next.observe(\.isLoading, options: [.new]) { web, _ in changed(web) },
            ]
            show(next.isLoading, next.estimatedProgress, animated: false)
        }

        override func layout() {
            super.layout()
            place(animated: false)
        }

        private func show(_ loading: Bool, _ progress: Double, animated: Bool) {
            let was = shown
            fraction = loading ? max(0.08, progress) : (was ? 1 : 0)
            shown = loading
            CATransaction.begin()
            // A new load starts from the left at once, not run back to it.
            CATransaction.setDisableActions(!animated || (loading && !was))
            CATransaction.setAnimationDuration(0.2)
            place(animated: animated)
            if loading {
                line.opacity = 0.9
            } else if was {
                // Run to the end, then fade, as a line that just stopped
                // halfway reads as a page that didn't come.
                CATransaction.setCompletionBlock { [weak self] in
                    guard let self, !self.shown else { return }
                    CATransaction.begin()
                    CATransaction.setAnimationDuration(0.3)
                    self.line.opacity = 0
                    CATransaction.commit()
                }
            } else {
                line.opacity = 0
            }
            CATransaction.commit()
        }

        private func place(animated: Bool) {
            line.frame = CGRect(x: 0, y: 0, width: bounds.width * fraction, height: 2)
        }
    }
}

/// The loading line for the tab in front, following its view as it is
/// built, woken or let go.
struct TabLoadingLine: View {
    @ObservedObject var tab: Tab

    var body: some View {
        LoadingLine(web: tab.isWeb ? tab.built : nil)
            .frame(height: 2)
            .allowsHitTesting(false)
    }
}
