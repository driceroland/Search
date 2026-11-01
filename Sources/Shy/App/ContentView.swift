import SwiftUI
import AppKit
import Combine

struct ContentView: View {
    @ObservedObject var browser: Browser

    /// Its window, held weakly: the window holds this view's state, and
    /// held strongly back, a window closed for good was never freed.
    @State var held = WeakWindow()
    var window: NSWindow? { held.window }
    @State var resting: RestingLights?
    /// The room the page leaves for the column and the strip, set without
    /// animation (see `make(room:after:)`); nil only before the window is up.
    @State var room: CGSize?
    @State var roomTicket = 0
    @State var immersionRevision = 0
    /// The window's width, for a side panel that leaves the page some room.
    @State private var across: CGFloat = 0

    /// The window: room at the top, one stage for the page, and the row when
    /// there is one.
    private var window_: some View {
        ZStack(alignment: sideOnRight ? .topTrailing : .topLeading) {
            // Black while a page has the screen, so the frame of our own window
            // that survives the transition is not a white band across the top.
            // With the tabs down the side, the ground the page's card and the
            // column sit on (see CardEdge).
            (fullscreenTab != nil ? Color.black : cards ? Palette.frame : Palette.ground)

            // One stage, always. It starts beside the column and under the
            // strip, not behind them — a page sliding beneath floating chrome
            // is a browser showing off, and it costs a compositing pass.
            //
            // When the column or the strip comes or goes, the page slides with
            // it and is resized once, not on every frame of the slide: laid out
            // again thirty times a second, the page juddered along its right
            // edge and overshot the window with the spring (see `room`).
            //
            // With the tabs down the side the page is a card on the window's
            // ground: a gap on the far side and along the bottom here, at the
            // top and on the column's side in the room (see chrome). Two pages
            // side by side are a card each (see PaneStage).
            stage
                .padding(.leading, sideOnRight ? farGap + panelRoom : 0)
                .padding(.trailing, sideOnRight ? 0 : farGap + panelRoom)
                .padding(.bottom, farGap)
                .padding(.leading, sideOnRight ? 0 : roomed.width)
                .padding(.trailing, sideOnRight ? roomed.width : 0)
                .padding(.top, roomed.height)
                .offset(x: sideOnRight ? 0 : chrome.width - roomed.width,
                        y: chrome.height - roomed.height)

            // An extension's side panel, on the side away from the column
            // (see SidePanel.swift); two pages in Split View share what's left.
            if panelRoom > 0 { sidePanel }

            // The column of tabs, in the way that has one. It takes the full
            // height, so the traffic lights sit in its own corner rather than
            // over the page.
            if sidebar {
                SideBar(browser: browser, prefs: browser.prefs, onFrame: cards)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .transition(.move(edge: sideOnRight ? .trailing : .leading))
            }
        }
        .ignoresSafeArea()
        .background { fullscreenWatch }
        .background { GeometryReader { geo in Color.clear.onAppear { across = geo.size.width }
            .onChange(of: geo.size.width) { _, width in across = width } } }
        .animation(Motion.glide, value: browser.prefs.sidePosition)
        .onAppear { if room == nil { room = chrome } }
        .onChange(of: chrome) { old, new in make(room: new, after: old) }
    }

    /// The page area: the stage that holds the page, or the two side by side
    /// (see SplitView.swift), and under it the developer's bar for a tab
    /// with Developer Mode on — never over a page filling the screen.
    private var stage: some View {
        VStack(spacing: 0) {
            ZStack {
                SplitStage(browser: browser, corner: cards ? Metrics.cardRadius : 0, immersed: fullscreenTab?.id)
                // An agent's page, over yours, while you watch it.
                AgentStage(browser: browser, agent: .shared, corner: cards ? Metrics.cardRadius : 0)
            }
            // Nothing, for a tab without Developer Mode (see DeveloperBar).
            if fullscreenTab == nil {
                DeveloperBar(browser: browser, gap: cards ? Metrics.cardGap : 0)
            }
        }
    }

    /// What the column and the strip take from the page right now: animated
    /// as they come and go. With the page as a card, the column folded away
    /// still leaves the card's gap, and so does the top.
    var chrome: CGSize {
        if cards {
            return CGSize(width: sidebar ? browser.prefs.sideWidth : Metrics.cardGap, height: Metrics.cardGap)
        }
        return CGSize(width: sidebar ? browser.prefs.sideWidth : 0, height: 0)
    }

    /// The page as a card on the window's ground: with the tabs down the
    /// side, the column out or folded away, the switch on, and neither the
    /// window nor a page filling the screen (see Browser.asCards).
    private var cards: Bool {
        browser.asCards && fullscreenTab == nil
    }

    /// The card's gap on the side away from the column, and along the bottom.
    private var farGap: CGFloat { cards ? Metrics.cardGap : 0 }

    /// The side panel is up: an extension's page in it, the tab in front one
    /// that extension may see, and no page filling the screen.
    private var panelUp: Bool {
        browser.sidePanelShown && browser.sidePanel != nil && !browser.sidePanelHeld && fullscreenTab == nil
    }

    /// The side panel's width as drawn: as you left it, or narrower in a
    /// window too narrow to keep 320 points of page beside it.
    private var panelWidth: CGFloat {
        let asked = browser.prefs.sidePanelWidth
        guard across > 0 else { return asked }
        let left = across - chrome.width - farGap * 2 - 320
        return max(240, min(asked, left))
    }

    /// What the side panel takes from the page: its width, and the card's
    /// gap before it with the page as a card, or its hairline edge to edge.
    private var panelRoom: CGFloat {
        panelUp ? panelWidth + (cards ? Metrics.cardGap : 1) : 0
    }

    private var sidePanel: some View {
        SidePanelBeside(browser: browser, prefs: browser.prefs, onLeft: sideOnRight,
                        card: cards, width: panelWidth)
            .padding(.top, chrome.height)
            .padding(.bottom, farGap)
            .padding(sideOnRight ? .leading : .trailing, farGap)
            .frame(maxWidth: .infinity, maxHeight: .infinity,
                   alignment: sideOnRight ? .topLeading : .topTrailing)
            .transition(.opacity)
    }

    /// The room the page is laid out to leave them, which is not animated.
    private var roomed: CGSize { room ?? chrome }

    private var sideOnRight: Bool {
        browser.prefs.sidePosition == .right
    }

    /// Chrome going away gives the page its room at once, the page sliding
    /// out from under it at its new size. Chrome arriving slides over a page
    /// still at its old size, which gives up the room once the slide is over.
    /// A column being dragged wider or narrower is followed as it goes.
    private func make(room new: CGSize, after old: CGSize) {
        let now = roomed
        // Given already, with the chrome itself (see `immersing`).
        if now == new {
            roomTicket += 1
            return
        }
        // Out of nothing, or out of the card's gap (see chrome): never more
        // than that unless something is there.
        let floor = Metrics.cardGap
        let arriving = (old.width <= floor && new.width > floor, old.height <= floor && new.height > floor)
        var at = now
        if !arriving.0 { at.width = new.width }
        if !arriving.1 { at.height = new.height }
        roomTicket += 1
        var still = Transaction()
        still.disablesAnimations = true
        // With Reduce Motion on, nothing slides: the page takes its new room
        // with the chrome, not after a slide that isn't there.
        withTransaction(still) { room = Motion.reduced ? new : at }
        guard !Motion.reduced, arriving.0 || arriving.1 else { return }
        let ticket = roomTicket
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) {
            guard ticket == roomTicket else { return }
            withTransaction(still) { room = chrome }
        }
    }

    /// Everything that rises from the bottom edge to say one thing.
    private var bars: some View {
        VStack(spacing: 8) {
            announcement
            if let ask = browser.asking {
                Group {
                    if ask.screen { ScreenQuestion(browser: browser, ask: ask) }
                    else { CaptureQuestion(browser: browser, ask: ask) }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if let offer = browser.offering {
                PasswordOffer(browser: browser, offer: offer)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            StoreOffer(browser: browser)
            if browser.veiling {
                hint("Click anything to hide it   ⌘Z undo   esc done")
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.bottom, 30)
        .animation(Motion.settle, value: browser.veiling)
        .animation(Motion.settle, value: browser.asking)
        .animation(Motion.settle, value: browser.offering)
    }

    /// What still comes over the page. Settings, History, Downloads,
    /// Bookmarks and Passwords are tabs of their own now (see
    /// InternalPages.swift).
    @ViewBuilder
    private var panels: some View {
        if browser.tuning {
            sheet { SettingsPanel(browser: browser, prefs: browser.prefs) } close: { browser.tuning = false }
        }
        if let tab = browser.handingOver {
            sheet { HandoverCard(browser: browser, tab: tab) } close: { browser.handingOver = nil }
        }
        if browser.reviewing {
            // No dimming for this one: the whole point is to keep looking at
            // the page while the list offers to put things back on it.
            ZStack(alignment: .topTrailing) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { browser.reviewing = false }
                HiddenPanel(browser: browser)
                    .padding(.top, Metrics.strip + 8)
                    .padding(.trailing, 14)
                    .transition(.scale(scale: 0.97, anchor: .topTrailing).combined(with: .opacity))
            }
            .ignoresSafeArea()
            .transition(.opacity)
        }
    }

    /// The ⌃Tab switcher, small windows' moons included. Its own property:
    /// written inline, body is more than the type checker will take.
    private var switcherOverlay: some View {
        TabSwitcherOverlay(
            switcher: browser.tabSwitcher,
            tab: { [browser] id in browser.tabs.first { $0.id == id } ?? LittleWindow.holding(id)?.tab },
            current: browser.activeID,
            pick: { [browser] id in browser.commitTabSwitch(picking: id) }
        )
    }

    /// The window held, dressed and named for the page in front (see
    /// WindowTitle.swift).
    private var windowSetup: some View {
        ZStack {
            WindowSetup(ready: setUp)
            if let tab = browser.active { WindowTitle(tab: tab, window: window).id(tab.id) }
        }
    }

    var body: some View {
        window_
            // The column folded away, and out again at the edge (see Fold.swift).
            .overlay(alignment: sideOnRight ? .trailing : .leading) {
                if fullscreenTab == nil { Fold(browser: browser, prefs: browser.prefs) }
            }
            .overlay(alignment: .bottom) { bars }
            .overlay {
                // Over the page only: the column, the strip and the bookmarks
                // bar stay as they are, uncovered and in reach.
                PeekLayer(browser: browser)
                    .padding(.leading, sideOnRight ? 0 : chrome.width)
                    .padding(.trailing, sideOnRight ? chrome.width : 0)
                    .padding(.top, chrome.height)
                    // From the window's own top edge, as the page is:
                    // the title bar's band is page too.
                    .ignoresSafeArea()
            }
            .overlay { panels }
            .overlay { switcherOverlay }
            .overlay(alignment: .topTrailing) {
                if let job = browser.fileImport { ImportProgress(browser: browser, job: job) }
            }
            // The field comes on its spring, and goes quickly: once Return
            // is pressed the page is on its way, and the field is not what
            // there is to watch.
            .animation(browser.fieldShowing ? Motion.settle : Motion.quick, value: browser.fieldShowing)
            .background(windowSetup)
            .onChange(of: browser.asCards) { _, cards in
                // The ground the page's card sits on, or the page's own.
                window?.backgroundColor = cards ? Palette.NS.frame : Palette.NS.ground
            }
            .onChange(of: browser.prefs.sidePosition) { _, _ in
                DispatchQueue.main.async { Lights.refresh(window); measureLights() }
            }
            .onChange(of: browser.prefs.sideWidth) { _, _ in
                DispatchQueue.main.async { Lights.refresh(window); measureLights() }
            }
            // Stepping away to another app: macOS draws its own resting
            // buttons, and on a light window they come out nearly white. Ours
            // go on in their place until the app comes back.
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
                browser.tabSwitcher.cancel()
                measureLights()
                resting?.isHidden = false
                // Only the window you were in, or every window's video would come.
                browser.appLeft()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
                if let window, (note.object as? NSWindow) === window { Browsers.becameKey(browser) }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { note in
                if let window, (note.object as? NSWindow) === window {
                    browser.tabSwitcher.cancel()
                    }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.willEnterFullScreenNotification)) { note in
                if let window, (note.object as? NSWindow) === window { browser.fullScreen = true }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.willExitFullScreenNotification)) { note in
                if let window, (note.object as? NSWindow) === window { browser.fullScreen = false }
            }
            // And as it is once there, or back: a way in that macOS gave up
            // on half way says so only by where the window ends up.
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { note in
                if let window, (note.object as? NSWindow) === window { browser.fullScreen = window.styleMask.contains(.fullScreen) }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { note in
                if let window, (note.object as? NSWindow) === window { browser.fullScreen = window.styleMask.contains(.fullScreen) }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                resting?.isHidden = true
                browser.appBack()
            }
            .onChange(of: browser.fieldShowing) { _, showing in
                if showing {
                    DispatchQueue.main.async { browser.askFocus() }
                } else {
                    handBack()
                }
            }
            .onChange(of: browser.activeID) { _, _ in handBack() }
            .animation(Motion.settle, value: browser.tuning)
            .animation(Motion.settle, value: browser.reviewing)
        .onAppear {
            watchKeys()
            browser.askFocus()
            // Addresses from other apps have somewhere to go from here on.
            Links.hand(to: browser)
            BookmarkMenu.shared.start(for: browser)
            Browsers.watchFrames()
        }
    }

    /// Give the keyboard back to the page once the field is done with it.
    ///
    /// Nothing did this before, so after typing an address the window's first
    /// responder was a text field that no longer existed: typing went nowhere
    /// until you clicked the page. It also mattered more than it looked —
    /// WebAuthn refuses to run on a document that isn't focused, and so do a
    /// number of paste and shortcut handlers pages install for themselves.
    private func handBack() {
        guard !browser.fieldShowing, browser.editingTab == nil else { return }
        DispatchQueue.main.async {
            guard !browser.fieldShowing, browser.editingTab == nil else { return }
            // Shy's own pages have no web view to hand the keys to.
            guard browser.active?.page == nil, let web = browser.active?.web, let window = web.window else { return }
            if let responder = window.firstResponder as? NSView,
               responder === web || responder.isDescendant(of: web) { return }
            window.makeFirstResponder(web)
        }
    }
}
