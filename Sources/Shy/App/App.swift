import SwiftUI
import AppKit
import Combine

// A window, a row of titles, and a field. Typing an address gets you a page;
// there is nothing else to learn and nothing else to press.

@main
struct ShyApp: App {
    /// The window in front's browser, for the menus (see Windows.swift).
    @StateObject private var front = Front.shared
    /// Your own keys (Settings › Shortcuts): the menus are drawn again when
    /// one changes, and show it.
    @ObservedObject private var shortcuts = ShortcutStore.shared
    /// Links from other apps, and the Dock icon.
    @NSApplicationDelegateAdaptor(Links.self) private var links

    /// What the menus act on: the window in front's browser.
    private var browser: Browser { front.browser ?? SceneSlot.shared.browser }

    init() {
        // Settings › General › Start with a fresh window: the files are cut
        // down before any window reads its row from them.
        if Store.settings.bool(forKey: Preferences.freshKey) {
            Session.startFresh(spaces: Spaces.read().map(\.id))
            Browsers.startFresh()
        }
    }

    var body: some Scene {
        // Where you left it, at the size you left it. SwiftUI saves a
        // window's frame under its id and puts it back before the window
        // first shows; set by hand once the window was up, it showed at the
        // default size first and then jumped (#202). The id is the name the
        // frame has always been kept under. A test run keeps its own: the
        // name lives in the app's standard defaults, which every copy
        // shares, and a probe resized for a test once changed the size the
        // real window came back at. The other windows' frames are in
        // windows.json (see Windows.swift).
        Window("Shy", id: Browsers.sceneID) {
            SceneRoot(slot: SceneSlot.shared)
                .frame(minWidth: 640, minHeight: 420)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {
                // Another window, with tabs of its own (see Windows.swift).
                Button("New Window") { Browsers.newWindow() }
                    .shortcut("file.newWindow")
                Button("New Tab") { browser.launch() }
                    .shortcut("file.newTab")
                Button("New Private Tab") { browser.newShyTab() }
                    .shortcut("file.newPrivateTab")
                Button(browser.reopenTitle) { browser.reopen() }
                    .shortcut("file.reopen")
                    .disabled(browser.closedHere.isEmpty && Browsers.lastClosedAt == nil)
                Divider()
                Button("Open Address…") { browser.edit() }
                    .shortcut("file.openAddress")
                Divider()
                // Another browser's bookmarks, history, passwords and the
                // rest, as Safari's File › Import From: the one sheet every
                // other way in opens too.
                Button("Bring In a File…") { browser.importFile() }
                    .shortcut("file.import")
                Divider()
                Button("Close Tab") { browser.closeFront() }
                    .shortcut("file.closeTab")
                Button("Close Window") { browser.closeWindow() }
                    .shortcut("file.closeWindow")
            }
            CommandGroup(replacing: .printItem) {
                Button("Share…") { browser.share() }
                    .shortcut("file.share")
                    .disabled(!(browser.active?.isWeb ?? false))
                Button("Export as PDF…") { browser.exportPDF() }
                    .shortcut("file.exportPDF")
                    .disabled(!(browser.active?.isWeb ?? false))
                Button("Print…") { browser.printPage() }
                    .shortcut("file.print")
                    .disabled(!(browser.active?.isWeb ?? false))
            }
            CommandGroup(after: .pasteboard) {
                Button("Copy Clean Link") { browser.copyCleanLink() }
                    .shortcut("edit.copyCleanLink")
                    .disabled(browser.active?.isBlank ?? true)
                Divider()
                Button("Find on Page…") { browser.openFind() }
                    .shortcut("edit.find")
                    .disabled(!(browser.active?.isWeb ?? false))
                Button("Find Next") { browser.look(forward: true) }
                    .shortcut("edit.findNext")
                    .disabled(!browser.finding)
                Button("Find Previous") { browser.look(forward: false) }
                    .shortcut("edit.findPrevious")
                    .disabled(!browser.finding)
                Divider()
                // As in Safari: each follows the Mac until switched here
                // (see Substitutions.swift).
                Menu("Substitutions") {
                    Button("Show Substitutions") { Substitution.showPanel() }
                    Divider()
                    ForEach(Substitution.allCases, id: \.self) { kind in
                        Toggle(kind.title, isOn: Binding(
                            get: { browser.substitutes(kind) },
                            set: { _ in browser.toggleSubstitution(kind) }
                        ))
                    }
                }
            }
            CommandGroup(replacing: .toolbar) {
                // Folded away, not moved (see Fold.swift) — the column, or the
                // strip across the top.
                Button((browser.folded ? "Show Sidebar" : "Hide Sidebar")
                      ) { browser.toggleFold() }
                    .shortcut("view.fold")
                Divider()
                Button("Reload Page") { browser.reload() }
                    .shortcut("view.reload")
                Button("Reload Page From Origin") { browser.reload(fromOrigin: true) }
                    .shortcut("view.reloadOrigin")
                Button("Reading Mode") { browser.toggleReader() }
                    .shortcut("view.reader")
                Button("Picture in Picture") { browser.toggleFloat() }
                    .shortcut("view.float")
                // Websites in the side panel.
                Menu("Side Panel") {
                    Button(browser.sidePanelShown ? "Close Side Panel" : "Show Side Panel") { browser.toggleSitePanel() }
                        .shortcut("view.sitePanel")
                    Divider()
                    ForEach(PanelSites.offered, id: \.name) { site in
                        Button(site.name) { browser.showSiteInPanel(site.url) }
                    }
                    Divider()
                    Button("This Page") { if let tab = browser.active { browser.openInSidePanel(tab) } }
                        .disabled(!(browser.active?.isWeb ?? false) || (browser.active?.shy ?? true))
                }
                Divider()
                Button("Hide Elements…") { browser.toggleHiding() }
                    .shortcut("view.hide")
                Button("Hidden on This Site…") { browser.reviewing.toggle() }
                    .shortcut("view.hidden")
                Divider()
                Button("Zoom In") { browser.zoom(by: 1.1) }
                    .shortcut("view.zoomIn")
                Button("Zoom Out") { browser.zoom(by: 1 / 1.1) }
                    .shortcut("view.zoomOut")
                Button("Actual Size") { browser.resetZoom() }
                    .shortcut("view.actualSize")
                Divider()
                // The Web Inspector, on the keys Chrome and Arc use (see Inspector.swift).
                Button("Web Inspector") { browser.toggleInspector() }
                    .shortcut("view.inspector")
                Button("JavaScript Console") { browser.showConsole() }
                    .shortcut("view.console")
                Button("Inspect Element") { browser.inspectElement() }
                    .shortcut("view.inspect")
            }
            CommandMenu("Tabs") {
                Button("Back") { browser.back() }
                    .shortcut("tabs.back")
                    .disabled(browser.active?.canGoBack != true)
                Button("Forward") { browser.forward() }
                    .shortcut("tabs.forward")
                    .disabled(browser.active?.canGoForward != true)
                Divider()
                Button("Next Tab") { browser.step(1) }
                    .shortcut("tabs.next")
                Button("Previous Tab") { browser.step(-1) }
                    .shortcut("tabs.previous")
                Button("Search Tabs…") { browser.summon() }
                    .shortcut("tabs.search")
                Divider()
                Button("Split Current Page") { browser.startSplit() }
                    .shortcut("tabs.split")
                    .disabled(browser.active == nil || browser.active?.bench == true)
                Button("Focus Left Page") { browser.focusPane(onLeft: true) }
                    .shortcut("tabs.focusLeftPane")
                    .disabled(browser.activeSplit == nil)
                Button("Focus Right Page") { browser.focusPane(onLeft: false) }
                    .shortcut("tabs.focusRightPane")
                    .disabled(browser.activeSplit == nil)
                Button("Swap Pages") { browser.swapSplit() }
                    .shortcut("tabs.swapSplit")
                    .disabled(browser.activeSplit == nil)
                Button("Separate Split Tabs") {
                    if let tab = browser.active { browser.detachSplit(tab) }
                }
                .shortcut("tabs.separateSplit")
                .disabled(browser.activeSplit == nil)
                Button("Close Both Pages") { browser.closeSplit() }
                    .disabled(browser.activeSplit == nil)
                Divider()
                if let tab = browser.active {
                    if tab.pin == nil {
                        Button("Pin Tab") { browser.pin(tab) }
                            .disabled(!tab.isWeb || tab.shy)
                        Button("Pin Tab as Row") { browser.pin(tab, listed: true) }
                            .disabled(!tab.isWeb || tab.shy)
                    } else {
                        Button(tab.listed ? "Show Pin as Square" : "Show Pin as Row") { browser.setListed(tab, !tab.listed) }
                        Button("Unpin Tab") { browser.unpin(tab) }
                    }
                }
                Button("Rename Tab") { if let tab = browser.active { browser.beginTabRename(tab) } }
                    .shortcut("tabs.rename")
                    .disabled(browser.active == nil)
                Button("Duplicate Tab") { browser.duplicate() }
                    .shortcut("tabs.duplicate")
                    .disabled(!(browser.active?.isWeb ?? false))
                Button("Copy Address") { browser.copyAddress() }
                    .shortcut("tabs.copyAddress")
                    .disabled(!(browser.active?.isWeb ?? false))
                Button("Copy as Markdown Link") { browser.copyMarkdownLink() }
                    .shortcut("tabs.copyMarkdown")
                    .disabled(!(browser.active?.isWeb ?? false))
                Button("Paste and Go") { browser.pasteAndGo() }
                    .shortcut("tabs.pasteAndGo")
                Divider()
                Button("Close Other Tabs") { if let tab = browser.active { browser.closeOthers(but: tab) } }
                    .shortcut("tabs.closeOthers")
                    .disabled(browser.tabs.count < 2)
                Button("Stop Sound in Tab") { browser.pauseMedia() }
                    .shortcut("tabs.mute")
            }
            CommandMenu("Bookmarks") {
                Button(browser.pageKept ? "Edit Bookmark\u{2026}" : "Add This Page") { browser.bookmarkCurrent() }
                    .shortcut("bookmarks.add")
                    .disabled(!(browser.active?.isWeb ?? false))
                Button("Show Bookmarks…") { browser.bookmarking = true }
                    .shortcut("bookmarks.show")
                // The bookmarks themselves follow, put in by AppKit (see
                // BookmarkMenu in Bookmarks.swift).
            }
            CommandMenu("History") {
                Section("Recently Visited") {
                    ForEach(browser.recentlyVisited) { trace in
                        Button {
                            browser.open(trace.url, foreground: true)
                        } label: {
                            MenuLine(title: trace.title.isEmpty ? Address.withoutWWW(trace.address) : trace.title, url: trace.url, profile: browser.profileID)
                        }
                    }
                }
                if !browser.closedHere.isEmpty {
                    Section("Recently Closed") {
                        ForEach(browser.closedHere.reversed().prefix(10)) { ghost in
                            Button {
                                browser.reopen(ghost)
                            } label: {
                                MenuLine(title: ghost.label, url: ghost.url, profile: browser.profileID)
                            }
                        }
                    }
                }
                Divider()
                Button("Show History…") { browser.recalling = true }
                    .shortcut("history.show")
                Button("Downloads…") { browser.hoarding = true }
                    .shortcut("history.downloads")
                Divider()
                Button("Clear Browsing Data…") { browser.recallMode = .clearing }
                    .shortcut("history.clearData")
                Button("Clear History") { browser.clearHistory() }
                    .shortcut("history.clear")
            }
            // Shy › Check for Updates…, under About, as in any Mac app.
            CommandGroup(after: .appSettings) {
                Button("Settings…") { browser.tuning = true }
                    .shortcut("app.settings")
                Button("Passwords…") { browser.managing = true }
                    .shortcut("app.passwords")
            }
            QuitAndHelp()
        }
    }
}

/// Quit Shy, which can ask first (Settings › General), and Help. One
/// value, because a scene's commands take at most ten.
private struct QuitAndHelp: Commands {
    var body: some Commands {
        CommandGroup(replacing: .appTermination) {
            Button("Quit Shy") {
                if Links.shouldQuit() { NSApp.terminate(nil) }
            }
            .keyboardShortcut("q", modifiers: .command)
        }
        CommandGroup(replacing: .help) {
            Button("Send Feedback…") { Links.writeFeedback() }
        }
    }
}

/// A page, as a line in a menu: its icon if one is known, and its name.
private struct MenuLine: View {
    let title: String
    let url: URL
    let profile: UUID

    var body: some View {
        if let icon = Favicons.of(profile).cached(for: url) {
            Label {
                Text(title)
            } icon: {
                Image(nsImage: MenuLine.small(icon))
            }
        } else {
            Text(title)
        }
    }

    /// The cached icon is sixty-four points across; a menu wants sixteen.
    private static func small(_ icon: NSImage) -> NSImage {
        let copy = icon.copy() as! NSImage
        copy.size = NSSize(width: 16, height: 16)
        return copy
    }
}

/// The base a sheet draws on, and the reason a panel is legible over a page
/// that has hidden its own cursor.
///
/// WebKit turns `cursor: none` into an AppKit cursor rect over the whole web
/// view. SwiftUI panels layered on top add no rect of their own, so when the
/// pointer crosses from the page into a sheet the invisible rect still wins,
/// and the sheet reads as empty air. This gives the sheet one arrow-sized
/// rect to win with, frontmost because its NSView sits above the web view
/// (a sheet is drawn by `.overlay { panels }` on `ContentView.body`).
private struct CursorGround: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { CursorGroundView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class CursorGroundView: NSView {
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    // Re-arm the rect each time this view joins a window or changes size, so
    // AppKit notices it even if the pointer has not moved since the sheet
    // appeared. Without this the arrow only shows after a twitch.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.invalidateCursorRects(for: self)
    }

    override func layout() {
        super.layout()
        window?.invalidateCursorRects(for: self)
    }
}

private final class WeakWindow {
    weak var window: NSWindow?
}

struct ContentView: View {
    @ObservedObject var browser: Browser

    /// Its window, held weakly: the window holds this view's state, and
    /// held strongly back, a window closed for good was never freed.
    @State private var held = WeakWindow()
    private var window: NSWindow? { held.window }
    @State private var resting: RestingLights?
    /// The room the page leaves for the column and the strip, set without
    /// animation (see `make(room:after:)`); nil only before the window is up.
    @State private var room: CGSize?
    @State private var roomTicket = 0
    @State private var immersionRevision = 0
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
    private var chrome: CGSize {
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

    // MARK: - the window

    /// A line that rises from the bottom, says one thing, and leaves.
    @ViewBuilder
    private var announcement: some View {
        if let text = browser.announcement {
            HStack(spacing: 8) {
                Text(text)
                    .foregroundStyle(Palette.ink)
                // A file just saved: the line shows it in the Finder.
                if browser.announcedFile != nil {
                    Text("Show in Finder")
                        .foregroundStyle(Palette.muted)
                }
            }
                .font(.system(size: 12))
                .contentShape(Capsule())
                .onTapGesture {
                    if let file = browser.announcedFile { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                }
                .padding(.horizontal, 15)
                .padding(.vertical, 9)
                .background(Palette.ground, in: Capsule())
                .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
                .shadow(color: .black.opacity(0.10), radius: 18, y: 6)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(Motion.settle, value: browser.announcement)
        }
    }

    /// A dark pill, for the one mode this browser has. It stays up for as long
    /// as the mode does, which is how you know you are still in it.
    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(Palette.ground.opacity(0.92))
            .padding(.horizontal, 15)
            .padding(.vertical, 9)
            .background(Palette.ink.opacity(0.92), in: Capsule())
            .shadow(color: .black.opacity(0.18), radius: 18, y: 6)
    }

    /// The same dimmed ground and spring for every panel that floats over a
    /// page, so they read as one kind of thing.
    @ViewBuilder
    private func sheet<Panel: View>(
        @ViewBuilder _ panel: () -> Panel,
        close: @escaping () -> Void
    ) -> some View {
        ZStack {
            // The floor owns the cursor; see CursorGround.
            CursorGround()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
            Color.black.opacity(0.10)
                .ignoresSafeArea()
                .onTapGesture(perform: close)
            panel()
                .transition(.scale(scale: 0.97).combined(with: .opacity))
        }
        .transition(.opacity)
    }

    /// True while the tabs are down the left, and not folded away (see Fold.swift).
    private var sidebar: Bool {
        !browser.folded && fullscreenTab == nil
    }


    /// Either visible pane may give its page to WebKit's fullscreen window.
    /// Read through immersionRevision: a tab's going full screen and coming
    /// back are the tab's changes, not the browser's, and this view watches
    /// only the browser (see fullscreenWatch).
    private var fullscreenTab: Tab? {
        _ = immersionRevision
        if let split = browser.activeSplit,
           let immersed = browser.tabs.first(where: { split.contains($0.id) && $0.immersed }) {
            return immersed
        }
        return browser.active?.immersed == true ? browser.active : nil
    }

    /// The pages on screen, watched for full screen. The page alone too: left
    /// unwatched, a video's full screen ended with nothing to draw the window
    /// again, and the column stayed away until something else did — until
    /// the column was switched off and on again, as it was reported.
    @ViewBuilder
    private var fullscreenWatch: some View {
        if let split = browser.activeSplit {
            if let left = browser.tabs.first(where: { $0.id == split.left }) {
                TabImmersionWatch(tab: left) { immersing() }.id(left.id)
            }
            if let right = browser.tabs.first(where: { $0.id == split.right }) {
                TabImmersionWatch(tab: right) { immersing() }.id(right.id)
            }
        } else if let active = browser.active {
            TabImmersionWatch(tab: active) { immersing() }.id(active.id)
        }
    }

    /// A page going full screen or coming back: everything around it at
    /// once, in one transaction and without animation — the column, the
    /// strip, the card's gap and corners, the bookmarks bar, the side panel,
    /// Split View's other page, and the room the page leaves them, given
    /// with them rather than after a slide (see `make(room:after:)`). WebKit's
    /// window covers ours both ways when this happens (see Tab.immersed), so
    /// there is nothing to watch move; one at a time, each in its own turn
    /// and on its own curve, they resized the page four or five times on the
    /// way back from a YouTube video.
    private func immersing() {
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) {
            immersionRevision += 1
            roomTicket += 1
            room = chrome
        }
    }

    /// Put the resting circles in the title bar, exactly over the buttons.
    private func measureLights() {
        guard let window,
              let close = window.standardWindowButton(.closeButton),
              let titlebar = close.superview
        else { return }

        let view = resting ?? RestingLights()
        if view.superview !== titlebar {
            view.frame = titlebar.bounds
            view.autoresizingMask = [.width, .height]
            titlebar.addSubview(view, positioned: .above, relativeTo: nil)
            resting = view
        }
        view.spots = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { window.standardWindowButton($0) }
            .map { $0.convert($0.bounds, to: titlebar) }
        view.isHidden = NSApp.isActive
    }

    /// The window, once there is one: held, dressed, and named for the page
    /// in front so its name doesn't wait for the next change.
    private func setUp(_ window: NSWindow) {
        held.window = window
        dress(window)
        if let tab = browser.active { WindowTitle.set(tab, in: window) }
    }

    private func dress(_ window: NSWindow) {
        browser.window = window
        // Off screen at once, while a link's small window keeps the browser's
        // windows away (see Browsers.keepAway).
        Browsers.putAway()
        window.tabbingMode = .disallowed
        // Light or dark is the app's to say (Settings › Appearance); the
        // window only has to be the ground colour that goes with it.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // A window put back in full screen is so before any notice says it.
        browser.fullScreen = window.styleMask.contains(.fullScreen)
        window.backgroundColor = browser.asCards ? Palette.NS.frame : Palette.NS.ground
        // The strip does the dragging, so the page underneath can't be grabbed
        // by accident while selecting text.
        window.isMovableByWindowBackground = false
        // Nor by its title bar, which the strip is all the way down: AppKit
        // would move the window on any drag there, a tab picked up to take
        // it elsewhere in the row included. DragStrip moves it instead. The
        // window stays movable, though — macOS's Window › Move & Resize, its
        // tiling and the tools that arrange windows ask for a movable one
        // (#286) — and is made unmovable only while the pointer is over the
        // strip (see DragStrip).
        window.isMovable = true

        // The traffic lights set in from the corner and centred in the strip's
        // height, in both modes, without a toolbar's rounder corners — see
        // Lights.swift. The column's first row is the strip's height too, so
        // its three doors sit on the lights' line.
        Lights.keep(window, centreX: { window in
            browser.prefs.sidePosition == .right
                ? window.frame.width - browser.prefs.sideWidth + Lights.centre.x
                : Lights.centre.x
        }) { measureLights() }
        DispatchQueue.main.async { measureLights() }

        // The traffic lights are drawn — measured, they paint themselves — but
        // the window shows white where they are. The content view fills the
        // whole window, title bar included, and its layer was compositing over
        // the title bar's own. AppKit's subview order said otherwise; Core
        // Animation is the one actually deciding, so it is told directly.
        DispatchQueue.main.async {
            guard let close = window.standardWindowButton(.closeButton),
                  let container = close.superview?.superview,
                  let content = window.contentView,
                  let frame = content.superview
            else { return }
            frame.addSubview(container, positioned: .above, relativeTo: content)
            container.wantsLayer = true
            container.layer?.zPosition = 10
        }
    }

    // MARK: - keys

    /// A web view takes first responder and keeps most of the keyboard, so the
    /// shortcuts are caught before the event ever reaches it. The menu carries
    /// the same commands for anyone looking for them, and never sees these
    /// keystrokes because this runs first.
    private func watchKeys() {
        let id = ObjectIdentifier(browser)
        if let old = ContentView.monitors[id] { NSEvent.removeMonitor(old) }
        ContentView.monitors[id] = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .leftMouseDown]) { event in
            // A click on the tab switcher, in this window only (see
            // Browser.clickTabSwitcher), turned into the top-left coordinates
            // SwiftUI's frames are in.
            if event.type == .leftMouseDown {
                guard let window, event.window === window, let height = window.contentView?.bounds.height
                else { return event }
                let at = event.locationInWindow
                return browser.clickTabSwitcher(at: CGPoint(x: at.x, y: height - at.y)) ? nil : event
            }
            // Every window has a monitor, and every monitor hears every key:
            // each takes only its own window's, and the one in front takes
            // those of windows that aren't a browser's (a panel, the little
            // window).
            guard mine(event) else { return event }
            guard event.type == .keyDown else {
                // ⌃ let go of switches to the tab the switcher is on — or
                // whichever its key is held with (Settings › Shortcuts).
                if browser.tabSwitcher.active, !ShortcutStore.shared.recentHeld(event.modifierFlags) {
                    browser.commitTabSwitch()
                }
                // ⌘ let go of ends a ⌘K walk, wherever it stopped.
                if !event.modifierFlags.contains(.command) { browser.landSummon() }
                return event
            }
            // Escape on a page filling the screen is WebKit's, which leaves
            // on the first one, as Safari does. Its window isn't a browser's,
            // so the key came here first and put away what was left up in
            // the window behind the video, a find bar or the address field,
            // and only the second press reached the page.
            // A ⌃Tab switcher up behind it goes too, or letting ⌃ go would
            // switch tabs as the page comes back. With Esc twice asked for
            // (Settings › General), as in Arc, the first press only puts a
            // reminder up (see FullScreenEscape).
            if event.keyCode == 53, let page = ContentView.pageFillingScreen(event) {
                if browser.tabSwitcher.active { browser.tabSwitcher.cancel() }
                guard browser.prefs.escapeTwice else { return event }
                return FullScreenEscape.shared.passes(event, to: page) ? event : nil
            }
            // A key typed while the field is on its way is the field's (holdKey),
            // Escape in a full-screen window included.
            if browser.holdKey(event) { return nil }
            // Escape in this window while it is itself in macOS full screen
            // (the green button, ⌃⌘F). Nothing in Shy wanting it, it went
            // on through the page to AppKit, which takes the window out of
            // full screen on it: one press, whatever it was meant for. With
            // Esc twice asked for, Shy's own Escape jobs still go first and
            // at one press — the find bar, the address field, a peek, a panel,
            // a rename, a new tab never sent anywhere, the ⌃Tab switcher —
            // and a press none of them wants is kept from the page and from
            // AppKit and counted instead (see FullScreenEscape): the first
            // puts the reminder up, a second within two seconds leaves. Held
            // down, its repeats are kept and count for nothing.
            if event.keyCode == 53, browser.prefs.escapeTwice, let window, event.window === window,
               window.styleMask.contains(.fullScreen) {
                if event.isARepeat { return nil }
                if take(event) { return nil }
                FullScreenEscape.shared.press(event, leaving: window)
                return nil
            }
            return take(event) ? nil : event
        }
        ContentView.keyHooks[id] = { event in take(event) ? nil : event }
    }

    /// Each browser's key monitor. Kept here rather than in the view, so
    /// that a window closed for good takes its monitor and hook with it
    /// (see `forget`), and they no longer hold its browser.
    private static var monitors: [ObjectIdentifier: Any] = [:]

    static func forget(_ browser: Browser) {
        let id = ObjectIdentifier(browser)
        if let monitor = monitors.removeValue(forKey: id) { NSEvent.removeMonitor(monitor) }
        keyHooks[id] = nil
    }

    /// Whether a key is this window's to act on.
    private func mine(_ event: NSEvent) -> Bool {
        if let window = event.window, let owner = Browsers.browser(for: window) {
            // Popup hosts have no ContentView monitor of their own.
            return owner.isPopup ? Browsers.acting === browser : window === self.window
        }
        return Browsers.acting === browser
    }

    /// The page a key goes to, if it fills the screen: one WebKit has in its
    /// own window, where the page's view takes the keys, or one whose page
    /// said it is going (Tab.immersed, which is how the bench fakes it).
    private static func pageFillingScreen(_ event: NSEvent) -> PageView? {
        guard let page = event.window?.firstResponder as? PageView else { return nil }
        let fills = page.fullscreenState != .notInFullscreen
            || Browsers.all.contains { $0.tabs.contains { $0.immersed && $0.built === page } }
        return fills ? page : nil
    }

    /// The same handling the key monitor gives an event, for the bench to
    /// put a key through the app's own path — each window's own.
    static var keyHooks: [ObjectIdentifier: (NSEvent) -> NSEvent?] = [:]

    /// The last key handed to the page before Shy acted on it (see
    /// `pageFirst`): if WebKit sends it back unused, it is Shy's.
    static var passed: NSEvent?
    /// The key a page was given in place of ⌘S, kept so it is dropped if
    /// WebKit sends it back unused (see Browser.handOver).
    static var handedOver: NSEvent?

    /// A key a page may want for itself — ⌘K in Slack, ⌘F in a Google Doc,
    /// ⌘S in an editor — goes to the page first, as it does in Chrome, and is
    /// Shy's only if the page leaves it unused: WebKit then sends the same
    /// event back through the app, and it comes here a second time. Only
    /// while the page has the keyboard; in the address field or a panel,
    /// Shy's keys are Shy's. The keys that make and close tabs and move
    /// between them stay Shy's first, as Chrome keeps them its own.
    ///
    /// ⌘K is always Shy's, on every page: the way to any open page is
    /// the one key that must never be taken (Drice; #238). Slack, X, GitHub
    /// and ChatGPT use it themselves, and given it first they kept it.
    ///
    /// ⌘← and ⌘→ are Shy's too while nothing is being typed: WebKit takes
    /// them to scroll the page sideways and never hands them back, so
    /// passing them on left them dead for going back and forward (#324).
    private func pageFirst(_ event: NSEvent, key: String, shifted: Bool) -> Bool {
        let reserved = (key == "t") || (key == "w") || (key == "n" && shifted)
            || ((key == "[" || key == "]" || key == "{" || key == "}") && shifted)
            || (key == "z" && browser.veiling)
            || (key == "k" && !shifted)
            || (!shifted && (event.keyCode == 123 || event.keyCode == 124) && !caretIn(event))
        guard !reserved, event.window?.firstResponder is PageView else { return false }
        if let passed = ContentView.passed, PageView.same(passed, event) {
            ContentView.passed = nil
            return false
        }
        ContentView.passed = event
        return true
    }

    /// Whether the caret is in something editable: the address field or a
    /// panel's, or a text box on the page. The page's own word on typing
    /// misses a click straight into a frame and never reaches into another
    /// site's, such as an embedded comment box; the web view has an input
    /// context while the caret is in something editable, in any frame.
    private func caretIn(_ event: NSEvent) -> Bool {
        event.window?.firstResponder is NSTextView || browser.active?.typing == true
            || browser.active?.built?.inputContext != nil
    }

    /// Whether the caret is in the window's address field: its field editor
    /// answers to the field, and the field to AddressField (Omnibox.swift).
    private static func inAddressField(_ window: NSWindow) -> Bool {
        guard let editor = window.firstResponder as? NSTextView else { return false }
        return (editor.delegate as? NSTextField)?.delegate is AddressField.Coordinator
    }

    /// Whether the tab switcher can come up: in this window, with nothing
    /// over the page it would have to cover. The find bar isn't one: it sits
    /// in a corner, stays open, and looks again on the tab picked (#553).
    private func canSwitchTabs(_ event: NSEvent) -> Bool {
        guard let window, event.window === window else { return false }
        // Settings, History and the rest are tabs, and ⌃Tab goes to and
        // from them like any other.
        return !browser.reviewing && !browser.bookmarksOpen &&
            !browser.veiling && !browser.summoning && !browser.makingSpace &&
            browser.peekTab == nil && browser.editingTab == nil &&
            browser.asking == nil && browser.offering == nil && browser.suggesting == nil
    }

    /// The keys of the top row, by where they sit rather than what they type.
    static let digits: [UInt16: Int] = [
        18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9, 29: 0,
    ]

    private func take(_ event: NSEvent) -> Bool {
        // The ⇧⌘S a page was handed for its ⌘S (see Browser.handOver), back
        // unused: nobody's. Let through, the menu took it for ⌘S and the
        // sidebar folded straight back.
        if let back = ContentView.handedOver, PageView.same(back, event), event.modifierFlags.contains(.command),
           event.modifierFlags.intersection([.shift, .option]) == back.modifierFlags.intersection([.shift, .option]) {
            ContentView.handedOver = nil
            return true
        }
        // A question hanging from the window (Ask) answers its own keys. Esc
        // there is its Cancel: taken here, it closed the panel under it and
        // left the question up, with Return still on its first button.
        if event.window?.sheetParent != nil || NSApp.modalWindow != nil { return false }
        // A small window's keys are its own (see Little.swift).
        if let little = LittleWindow.owning(event.window) { return little.take(event) }
        // A popup window: ⌘W closes it, not a tab of the
        // window menus act on. New tabs return to its browser; Escape
        // dismisses its permission question.
        if let popup = Browsers.browser(for: event.window), popup.isPopup {
            if popup.websitePopup, let combo = KeyCombo(event: event) {
                if combo == ShortcutStore.shared.key(for: "file.newTab") { popup.newTab(); return true }
                if combo == ShortcutStore.shared.key(for: "file.newPrivateTab") { popup.newShyTab(); return true }
            }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if event.keyCode == 53, flags.isEmpty, popup.asking != nil {
                popup.cancelCapture()  // the screen's question too
                return true
            }
            guard event.shortcutCharacters == "w", flags == .command else { return false }
            popup.window?.performClose(nil)
            return true
        }
        // A key being typed into Settings › Shortcuts is for the box.
        guard !ShortcutStore.shared.recording else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.shortcutCharacters
        // ⌃Tab, or the key Settings › Shortcuts gave the switcher instead,
        // and whether ⇧ sends it back.
        let recent = ShortcutStore.shared.recentSwitch(event)

        // While the tab switcher is up, ⌃ and the arrows move through it and
        // ⌃Tab goes on below; any other key puts it away, and Escape does
        // nothing else. ⌃ is whatever the switcher's key is held with.
        if browser.tabSwitcher.active, recent == nil {
            if ShortcutStore.shared.recentOnly(flags) {
                let direction: TabSwitcher.Direction? = switch event.keyCode {
                case 123: .left
                case 124: .right
                case 125: .down
                case 126: .up
                default: nil
                }
                if let direction {
                    browser.tabSwitcher.move(direction)
                    return true
                }
            }
            // ⌃W, ⌃R, ⌃M, ⌃O, when Settings › Tabs has them on: the card
            // picked, closed, reloaded, muted or kept, and the switcher stays up.
            if let action = TabSwitcher.Action(event), let id = browser.tabSwitcher.selectedID {
                if !event.isARepeat { browser.act(action, onCard: id, in: browser.tabSwitcher) }
                return true
            }
            browser.tabSwitcher.cancel()
            if event.keyCode == 53 { return true }
        }

        // Escape puts the page back. On a blank tab there is no page to put
        // back, so it belongs to whatever else wants it.
        if event.keyCode == 53 {
            if browser.editingTab != nil {
                browser.cancelTabEdit()
                return true
            }
            if browser.peekTab != nil {
                browser.closePeek()
                return true
            }
            if browser.makingSpace {
                browser.cancelSpaceCreation()
                withAnimation(Motion.glide) { browser.makingSpace = false }
                return true
            }
            // The same panels in the same order as ⌘W (Browser.closeFront).
            if browser.closePanel() { return true }
            if browser.suggesting != nil {
                browser.dropChoice()
                return true
            }
            if browser.veiling {
                browser.toggleHiding()
                return true
            }
            if browser.reviewing {
                browser.reviewing = false
                return true
            }
            if browser.finding {
                browser.closeFind()
                return true
            }
            // One step at a time: the list first, then the field.
            if browser.picked != nil {
                browser.picked = nil
                return true
            }
            // A new tab never sent anywhere is itself what is open: Escape
            // takes it away, back to the tab you were on, which is the one
            // touched last. Chosen before closing, so close() doesn't wake a
            // neighbour on the way. Anything typed keeps it; so does being
            // the last tab, where closing it would close the window.
            if let blank = browser.active, blank.isBlank, browser.typed.isEmpty,
               let back = browser.tabs.filter({ $0.id != blank.id }).max(by: { $0.touched < $1.touched }) {
                browser.select(back)
                browser.close(blank)
                return true
            }
            guard browser.editing, browser.active?.isBlank == false else { return false }
            browser.dismiss()
            return true
        }

        // Keep split focus ahead of WebKit's arrow-key handling. Its panes
        // remain native first responders, so the menu shortcut alone would
        // never see ⌃⌘→ on a page.
        if browser.activeSplit != nil, let combo = KeyCombo(event: event) {
            let store = ShortcutStore.shared
            if combo == store.key(for: "tabs.focusLeftPane") { browser.focusPane(onLeft: true); return true }
            if combo == store.key(for: "tabs.focusRightPane") { browser.focusPane(onLeft: false); return true }
            if combo == store.key(for: "tabs.focusOtherPane") { browser.focusOtherPane(); return true }
        }

        // ⌘Return keeps a peek, as its other button does: Return or the
        // keypad's Enter, by the key rather than what it types, whatever Caps
        // Lock says. Not while typing in the peeked page — a comment box or
        // a mail there sends with the same keys — by the page's word or by
        // the caret being in something editable, in any frame.
        // ⌥⌘Return keeps it beside the page instead.
        if event.keyCode == 36 || event.keyCode == 76,
           flags.intersection([.command, .shift, .option, .control]) == .command
            || (flags.intersection([.command, .shift, .option, .control]) == [.command, .option]),
           let peek = browser.peekTab, !peek.typing, peek.built?.inputContext == nil {
            browser.keepPeek(beside: flags.contains(.option))
            return true
        }

        // Tab is the page's: it moves between a form's fields and a page's
        // links, as in every browser. It used to walk the row of tabs, which
        // took it from anyone filling in a form. ⌃Tab walks the row and comes
        // round to the first again, ⌃⇧Tab the other way — the keys every
        // other browser uses for that.
        //
        // ⌃Tab brings up the switcher instead, most recently used first —
        // whenever there is nothing over the page it would have to cover;
        // otherwise it walks the row as before.
        //
        // While an address is being typed, the list under the field is what
        // there is to move through, and Return takes whatever the walk landed on.
        //
        // The switcher's key can be another (Settings › Shortcuts, as in
        // Arc); ⌃Tab is then whatever command has it, or the page's.
        if let backwards = recent {
            if canSwitchTabs(event) {
                // A key held down doesn't race through them.
                if !event.isARepeat { browser.switchTabs(backwards: backwards) }
                return true
            }
            browser.step(backwards ? -1 : 1)
            return true
        }
        if event.keyCode == 48, !flags.contains(.command), !flags.contains(.option), !flags.contains(.control) {
            if browser.editingTab != nil { return true }
            // "red" then Tab: Reddit, in the field (SiteSearch.swift).
            if browser.fieldShowing, !flags.contains(.shift), browser.lockSiteOffer() { return true }
            if browser.fieldShowing, !browser.offers.isEmpty {
                browser.walk(flags.contains(.shift) ? -1 : 1)
                return true
            }
            return false
        }

        // Space keys have no menu; other commands arrive here when rebound.
        // A key taken off a command goes back to the page.
        if ShortcutStore.shared.anyChanged, let combo = KeyCombo(event: event) {
            if let command = ShortcutStore.shared.customCommand(on: combo) {
                if command.section == .spaces { return false }
                command.run(browser)
                return true
            }
            if ShortcutStore.shared.isFreed(combo) { return false }
        }

        // A shortcut an extension registered — ⌥⇧D, ⌃⇧Y — before ours, since
        // none of ours use those. Never one of ours, nor one of the Mac's:
        // those an extension doesn't get (see ShortcutStore.adopt).
        if #available(macOS 15.4, *), !flags.intersection([.command, .option, .control]).isEmpty,
           KeyCombo(event: event).map({ !ShortcutStore.shared.keepsFromExtensions($0) }) ?? true,
           Extensions.shared.take(event) {
            return true
        }

        guard flags.contains(.command) else { return false }
        let shifted = flags.contains(.shift)

        if flags.contains(.option), !shifted, !flags.contains(.control),
           event.shortcutKey == "r" {
            if pageFirst(event, key: "r", shifted: false) { return false }
            browser.reload(fromOrigin: true)
            return true
        }

        // Other shortcuts with ⌥ or ⌃ on top are somebody else's.
        guard !flags.contains(.option), !flags.contains(.control) else { return false }

        // ⌘Return in the address field: what is typed there in a new tab,
        // the one you are on left as it was, as in Safari; ⇧⌘Return goes to
        // it. Here rather than in the field's delegate, which ⌘Return doesn't
        // reliably reach. Only this window's own address field: ⌘Return in a
        // page, the peek, or another box (Settings, History's search) is
        // theirs as before.
        if event.keyCode == 36 || event.keyCode == 76, browser.fieldShowing,
           browser.editingTab == nil, let window, event.window === window,
           ContentView.inAddressField(window) {
            browser.submit(aside: true, front: shifted)
            return true
        }

        // ⌘1 through ⌘9, and ⌘0, by the key rather than the character it
        // types. On AZERTY and many other layouts the top row types &, é, "…
        // unless shift is held, so matching the character left these
        // shortcuts dead there; the shortcut belongs to the key, as it does
        // in every other browser. The ninth is the last tab or folded folder;
        // a folded folder counts once, under its name.
        if !shifted, let number = ContentView.digits[event.keyCode] {
            if number == 0 {
                browser.resetZoom()
            } else {
                browser.select(index: number == 9 ? browser.tabShortcutTargets.count - 1 : number - 1)
            }
            return true
        }

        // Keep the clearing controls reachable from a focused page editor.
        if shifted, event.keyCode == 51 {
            browser.recallMode = .clearing
            return true
        }

        // ⌘S is Shy's even on a page that wants it: the page gets ⇧⌘S instead.
        if key == "s", !shifted, flags == .command, let page = event.window?.firstResponder as? PageView,
           ShortcutStore.shared.key(for: "view.fold") == KeyCombo("s") {
            // Held down, it folds once rather than flickering in and out.
            if event.isARepeat { return true }
            browser.toggleFold()
            browser.handOver(event, to: page)
            return true
        }

        // The page's turn first, for the keys it may want (Refs #147).
        if pageFirst(event, key: key, shifted: shifted) { return false }

        switch key {
        case "t" where !shifted:
            browser.launch()
        case "t" where shifted:
            browser.reopen()
        case "c" where shifted:
            browser.copyAddress()
        case "d" where !shifted:
            browser.duplicate()
        case "n" where shifted:
            browser.newShyTab()
        // Shown, or brought forward if open: never a second one, and never
        // closed by the key that opened it — ⌘W does that, as for any tab.
        case "y" where !shifted:
            browser.recalling = true
        case "j" where shifted:
            browser.hoarding = true
        case "v" where shifted:
            // In a text field this key is paste without formatting — a Google
            // Doc, a form, the address field. It only means Paste and Go when
            // nothing is being typed. Passing the key on is not enough: WebKit
            // has no use for ⌘⇧V, hands it back, and the menu's Paste and Go
            // takes it. So the plain paste is done here, as Chrome does.
            // A web view has an input context only while the caret is in
            // something editable, in any frame — including frames the page's
            // own script can't look into, like the one a Google Doc types in.
            if browser.active?.typing == true || browser.active?.built?.inputContext != nil
                || browser.editing || event.window?.firstResponder is NSTextView {
                _ = event.window?.firstResponder?.tryToPerform(#selector(NSTextView.pasteAsPlainText(_:)), with: nil)
            } else {
                browser.pasteAndGo()
            }
        case "p" where !shifted:
            browser.printPage()
        case "f" where !shifted:
            browser.openFind()
        case "g":
            browser.look(forward: !shifted)
        case "m" where shifted:
            browser.pauseMedia()
        case "p" where shifted:
            browser.toggleFloat()
        case "k" where !shifted:
            // Held down, ⌘K walks the list a step at a time; letting go of ⌘
            // takes wherever it stopped.
            if browser.editing, !browser.offers.isEmpty {
                browser.stepSummon()
            } else {
                browser.summon()
            }
        case "s" where !shifted:
            // The column or the strip, folded away (see Fold.swift).
            browser.toggleFold()
        case "b" where shifted:
            browser.bookmarkCurrent()
        case "," where !shifted:
            browser.tuning = true
        case "h" where shifted:
            browser.toggleHiding()
        case "u" where shifted:
            browser.reviewing.toggle()
        case "z" where !shifted:
            // Only while pointing. Everywhere else undo belongs to the page.
            guard browser.veiling else { return false }
            browser.undoHiding()
        // ⌘+ arrives as "=" or "+" depending on the keyboard; both mean bigger.
        case "=", "+":
            browser.zoom(by: 1.1)
        case "-":
            browser.zoom(by: 1 / 1.1)
        case "0":
            browser.resetZoom()
        case "w" where !shifted:
            browser.closeFront()
        case "w" where shifted:
            browser.closeWindow()
        case "l" where !shifted:
            browser.edit()
        case "r" where !shifted:
            browser.reload()
        case "r" where shifted:
            browser.toggleReader()
        case "[":
            shifted ? browser.step(-1) : browser.back()
        case "]":
            shifted ? browser.step(1) : browser.forward()
        default:
            // Moving or selecting text belongs to the editor, not the page's
            // history — in web forms and in the browser's own fields alike.
            guard !shifted, !caretIn(event) else { return false }
            // ⌘← and ⌘→, for hands that never learned the brackets.
            if event.keyCode == 123 { browser.back(); return true }
            if event.keyCode == 124 { browser.forward(); return true }
            return false
        }
        return true
    }
}

/// A page's own fullscreen state changes without changing the Browser's tab
/// identity. Listen to both visible pages so the surrounding chrome follows.
private struct TabImmersionWatch: View {
    let tab: Tab
    let changed: () -> Void

    var body: some View {
        // Once the flag has changed (Tab.immersion), never before: what the
        // window works out from it at once must read the new value.
        Color.clear.frame(width: 0, height: 0)
            .onReceive(tab.immersion) { _ in changed() }
    }
}

/// SwiftUI's window, around whichever browser it holds now (see SceneSlot):
/// a fresh one, laid out afresh, when the old one went with its window.
struct SceneRoot: View {
    @ObservedObject var slot: SceneSlot

    var body: some View {
        ContentView(browser: slot.browser)
            .id(ObjectIdentifier(slot.browser))
            .onAppear { Browsers.restoreOnce() }
    }
}

/// A file being brought in, in the background (#380): its name, how far it
/// has got, and Cancel — in the corner, in the quiet grey of everything
/// else that floats over the page.
private struct ImportProgress: View {
    @ObservedObject var browser: Browser
    let job: Browser.FileImportJob

    private var fraction: CGFloat? {
        guard let total = job.total, total > 0 else { return nil }
        return min(1, CGFloat(job.completed) / CGFloat(total))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(job.filename)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(job.message)
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
                .lineLimit(1)
            bar
            footer
        }
        .padding(14)
        .frame(width: 250, alignment: .leading)
        .background(Palette.ground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.08), radius: 16, y: 5)
        .padding(20)
        .transition(.opacity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Importing \(job.filename), \(job.message)")
    }

    private var bar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.hairline)
                if let fraction {
                    Capsule().fill(Palette.ink.opacity(0.7)).frame(width: geo.size.width * fraction)
                }
            }
        }
        .frame(height: 3)
    }

    private var footer: some View {
        HStack {
            if let total = job.total, total > 0 {
                Text("\(job.completed.formatted()) of \(total.formatted())")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
            }
            Spacer(minLength: 0)
            Button { browser.cancelFileImport() } label: {
                Text(job.cancelling ? "Cancelling…" : "Cancel")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.ink)
                    .padding(.horizontal, 10)
                    .frame(height: 22)
                    .background(Palette.ink.opacity(0.07), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(job.cancelling)
        }
    }
}
