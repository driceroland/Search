import SwiftUI
import AppKit
import Combine

// A window, a row of titles, and a field. Typing an address gets you a page;
// there is nothing else to learn and nothing else to press.

@main
struct SearchApp: App {
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
        Window("Search", id: Browsers.sceneID) {
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
                Button("New Tab") { browser.newTab() }
                    .shortcut("file.newTab")
                Button("New Private Tab") { browser.newShyTab() }
                    .shortcut("file.newPrivateTab")
                Button(browser.reopenTitle) { browser.reopen() }
                    .shortcut("file.reopen")
                    .disabled(browser.ghosts.isEmpty && Browsers.lastClosedAt == nil)
                Divider()
                Button("Open Address…") { browser.edit() }
                    .shortcut("file.openAddress")
                Divider()
                // Another browser's bookmarks, history, passwords and the
                // rest, as Safari's File › Import From: the one sheet every
                // other way in opens too.
                Button("Bring Things Over…") { browser.bringingIn = "" }
                    .shortcut("file.import")
                Divider()
                Button("Close Tab") { if let tab = browser.active { browser.close(tab) } }
                    .shortcut("file.closeTab")
            }
            CommandGroup(replacing: .printItem) {
                Button("Share…") { browser.share() }
                    .shortcut("file.share")
                    .disabled(browser.active?.isBlank ?? true)
                Button("Print…") { browser.printPage() }
                    .shortcut("file.print")
                    .disabled(browser.active?.isBlank ?? true)
            }
            CommandGroup(after: .pasteboard) {
                Divider()
                Button("Find on Page…") { browser.openFind() }
                    .shortcut("edit.find")
                    .disabled(browser.active?.isBlank ?? true)
                Button("Find Next") { browser.look(forward: true) }
                    .shortcut("edit.findNext")
                    .disabled(!browser.finding)
                Button("Find Previous") { browser.look(forward: false) }
                    .shortcut("edit.findPrevious")
                    .disabled(!browser.finding)
            }
            CommandGroup(replacing: .toolbar) {
                Toggle("Show Tabs in Sidebar", isOn: Binding(
                    get: { browser.prefs.sidebar },
                    set: { _ in browser.toggleSidebar() }
                ))
                .shortcut("view.sidebar")
                // Folded away, not moved (see Fold.swift) — the column, or the
                // strip across the top.
                Button(browser.prefs.sidebar
                       ? (browser.folded ? "Show Sidebar" : "Hide Sidebar")
                       : (browser.folded ? "Show Tab Bar" : "Hide Tab Bar")) { browser.toggleFold() }
                    .shortcut("view.fold")
                Picker("Tabs Wear", selection: Binding(
                    get: { browser.prefs.glyph },
                    set: { browser.prefs.glyph = $0 }
                )) {
                    ForEach(Glyph.allCases) { glyph in
                        Text(glyph.title).tag(glyph)
                    }
                }
                Divider()
                Button("Reload Page") { browser.reload() }
                    .shortcut("view.reload")
                Button("Reload Page From Origin") { browser.reload(fromOrigin: true) }
                    .shortcut("view.reloadOrigin")
                Button("Reading Mode") { browser.toggleReader() }
                    .shortcut("view.reader")
                Button("Float Video") { browser.toggleFloat() }
                    .shortcut("view.float")
                // The AI add-on's, only once it is on (Settings › AI).
                if browser.prefs.ai {
                    Divider()
                    Button("Summarize Page") { browser.summarizePage() }
                        .shortcut("view.summarize")
                        .disabled(browser.active?.isBlank ?? true)
                    Button("Ask About This Page…") { browser.askAboutPage() }
                        .shortcut("view.ask")
                        .disabled(browser.active?.isBlank ?? true)
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
                if browser.prefs.splitView {
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
                }
                if let tab = browser.active {
                    let rows = browser.prefs.showsPinRows
                    if tab.pin == nil {
                        Button("Pin Tab") { browser.pin(tab) }
                            .disabled(tab.isBlank || tab.shy)
                        if rows {
                            Button("Pin Tab as Row") { browser.pin(tab, listed: true) }
                                .disabled(tab.isBlank || tab.shy)
                        }
                    } else {
                        if rows {
                            Button(tab.listed ? "Show Pin as Square" : "Show Pin as Row") { browser.setListed(tab, !tab.listed) }
                        }
                        if !(rows && tab.listed) {
                            Button("Change Letter") { browser.editLetter(tab) }
                        }
                        Button("Unpin Tab") { browser.unpin(tab) }
                    }
                }
                Button("Rename Tab") { if let tab = browser.active { browser.beginTabRename(tab) } }
                    .shortcut("tabs.rename")
                    .disabled(browser.active == nil)
                Button("Duplicate Tab") { browser.duplicate() }
                    .shortcut("tabs.duplicate")
                    .disabled(browser.active?.isBlank ?? true)
                Button("Copy Address") { browser.copyAddress() }
                    .shortcut("tabs.copyAddress")
                    .disabled(browser.active?.isBlank ?? true)
                Button("Copy as Markdown Link") { browser.copyMarkdownLink() }
                    .shortcut("tabs.copyMarkdown")
                    .disabled(browser.active?.isBlank ?? true)
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
                    .disabled(browser.active?.isBlank ?? true)
                Button("Show Bookmarks…") { browser.bookmarking = true }
                    .shortcut("bookmarks.show")
                Toggle("Show Bookmarks Bar", isOn: Binding(
                    get: { browser.prefs.bookmarksBar },
                    set: { on in withAnimation(Motion.glide) { browser.prefs.bookmarksBar = on } }
                ))
                .shortcut("bookmarks.bar")
                // The bookmarks themselves follow, put in by AppKit (see
                // BookmarkMenu in Bookmarks.swift).
            }
            CommandMenu("History") {
                Section("Recently Visited") {
                    ForEach(browser.recentlyVisited) { trace in
                        Button {
                            browser.open(trace.url, foreground: true)
                        } label: {
                            MenuLine(title: trace.title.isEmpty ? Address.withoutWWW(trace.address) : trace.title, url: trace.url)
                        }
                    }
                }
                if !browser.ghosts.isEmpty {
                    Section("Recently Closed") {
                        ForEach(browser.ghosts.reversed().prefix(10)) { ghost in
                            Button {
                                browser.reopen(ghost)
                            } label: {
                                MenuLine(title: ghost.label, url: ghost.url)
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
            // Search › Check for Updates…, under About, as in any Mac app.
            CommandGroup(after: .appInfo) { UpdateMenuItem() }
            CommandGroup(after: .appSettings) {
                Button("Settings…") { browser.tuning = true }
                    .shortcut("app.settings")
                Button("Welcome…") { browser.welcoming = true }
                    .shortcut("app.welcome")
                Button("Passwords…") { browser.managing = true }
                    .shortcut("app.passwords")
            }
            CommandGroup(replacing: .help) {
                Button("Send Feedback…") { Links.writeFeedback() }
            }
        }
    }
}

/// A page, as a line in a menu: its icon if one is known, and its name.
private struct MenuLine: View {
    let title: String
    let url: URL

    var body: some View {
        if let site = Favicons.site(url),
           let icon = Favicons.shared.cached(site) {
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

struct ContentView: View {
    @ObservedObject var browser: Browser

    @State private var keys: Any?
    @State private var window: NSWindow?
    @State private var resting: RestingLights?
    /// The room the page leaves for the column and the strip, set without
    /// animation (see `make(room:after:)`); nil only before the window is up.
    @State private var room: CGSize?
    @State private var roomTicket = 0
    @State private var immersionRevision = 0


    /// The window: room at the top, one stage for the page, and the row when
    /// there is one.
    private var window_: some View {
        ZStack(alignment: sideOnRight ? .topTrailing : .topLeading) {
            // Black while a page has the screen, so the frame of our own window
            // that survives the transition is not a white band across the top.
            (fullscreenTab != nil ? Color.black : Palette.ground)

            // One stage, always. It starts beside the column and under the
            // strip, not behind them — a page sliding beneath floating chrome
            // is a browser showing off, and it costs a compositing pass.
            //
            // When the column or the strip comes or goes, the page slides with
            // it and is resized once, not on every frame of the slide: laid out
            // again thirty times a second, the page juddered along its right
            // edge and overshot the window with the spring (see `room`).
            stage
                .padding(.leading, sideOnRight ? 0 : roomed.width)
                .padding(.trailing, sideOnRight ? roomed.width : 0)
                .padding(.top, roomed.height)
                .offset(x: sideOnRight ? 0 : chrome.width - roomed.width,
                        y: chrome.height - roomed.height)

            // The column of tabs, in the way that has one. It takes the full
            // height, so the traffic lights sit in its own corner rather than
            // over the page.
            if sidebar {
                SideBar(browser: browser, prefs: browser.prefs)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .transition(.move(edge: sideOnRight ? .trailing : .leading))
            }

            if !browser.prefs.sidebar, !browser.folded, fullscreenTab == nil {
                TabBar(browser: browser)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            // The bookmarks bar, under the strip or beside the column's top.
            if barShown {
                BookmarksBar(browser: browser, bookmarks: browser.bookmarks)
                    .padding(.leading, sideOnRight ? 0 : chrome.width)
                    .padding(.trailing, sideOnRight ? chrome.width : 0)
                    .padding(.top, band)
                    .transition(.opacity)
            }
        }
        .ignoresSafeArea()
        .background { fullscreenWatch }
        .animation(Motion.glide, value: browser.prefs.sidebar)
        .animation(Motion.glide, value: browser.prefs.sidePosition)
        .animation(.easeOut(duration: 0.12), value: fullscreenTab?.id)
        .onAppear { if room == nil { room = chrome } }
        .onChange(of: chrome) { old, new in make(room: new, after: old) }
    }

    // With Split View off, the stage is the one it always was: a single
    // Page that is never rebuilt from one tab to the next (see Stage.swift).
    @ViewBuilder
    private var stage: some View {
        if browser.prefs.splitView {
            SplitStage(browser: browser)
        } else if let tab = browser.active {
            Page(tab: tab)
                .overlay {
                    if browser.prefs.showsLinks { LinkBubble(status: browser.linkStatus) }
                }
                .overlay(alignment: .topTrailing) {
                    if browser.finding {
                        FindBar(browser: browser)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if let assistant = browser.assisting, assistant.tab == tab.id {
                        AssistantPanel(browser: browser, assistant: assistant)
                            .padding(.top, browser.finding ? 64 : 14)
                            .padding(.trailing, 14)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .animation(Motion.settle, value: browser.assisting?.id)
                .overlay(alignment: .topLeading) {
                    if let asked = browser.suggesting, asked.tab == tab.id {
                        AccountList(browser: browser, asked: asked)
                            .transition(.opacity)
                    }
                }
                .animation(Motion.quick, value: browser.suggesting)
        } else {
            Palette.ground
        }
    }

    /// What the column and the strip take from the page right now: animated
    /// as they come and go.
    private var chrome: CGSize {
        CGSize(width: sidebar ? browser.prefs.sideWidth : 0, height: band + (barShown ? BookmarksBar.height : 0))
    }

    /// The bookmarks bar is up: asked for, there are bookmarks, and the tabs
    /// aren't folded away or under a video filling the screen.
    private var barShown: Bool {
        browser.prefs.bookmarksBar && !browser.bookmarks.isEmpty && !browser.folded
            && fullscreenTab == nil
    }

    /// The room the page is laid out to leave them, which is not animated.
    private var roomed: CGSize { room ?? chrome }

    private var sideOnRight: Bool {
        browser.prefs.sidebar && browser.prefs.sidePosition == .right
    }

    /// Chrome going away gives the page its room at once, the page sliding
    /// out from under it at its new size. Chrome arriving slides over a page
    /// still at its old size, which gives up the room once the slide is over.
    /// A column being dragged wider or narrower is followed as it goes.
    private func make(room new: CGSize, after old: CGSize) {
        let now = roomed
        let arriving = (old.width == 0 && new.width > 0, old.height == 0 && new.height > 0)
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
                captureAsking(ask)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if let offer = browser.offering {
                keepAsking(offer)
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

    /// The address field: raised over a page by ⌘L or ⌘K, and standing on its
    /// own whenever a tab has nowhere to be yet.
    @ViewBuilder
    private var field: some View {
        // SplitStage owns the field whenever Split View is enabled, including
        // an ordinary tab that is not currently paired. Drawing it here too
        // leaves two offset address fields on a blank tab.
        if browser.fieldShowing, !browser.prefs.splitView {
            Omnibox(browser: browser, over: !(browser.active?.isBlank ?? true))
                // Centred on the page, not on the window. The column of tabs
                // is not what the field is standing over, and dimming it along
                // with the page says otherwise.
                .padding(.leading, sidebar && !sideOnRight ? browser.prefs.sideWidth : 0)
                .padding(.trailing, sidebar && sideOnRight ? browser.prefs.sideWidth : 0)
                .transition(.scale(scale: 0.97).combined(with: .opacity))
        }
    }

    /// The panels. All the same kind of thing, so they are built the same way.
    @ViewBuilder
    private var panels: some View {
        if browser.recalling {
            sheet { HistoryPanel(browser: browser) } close: { browser.recalling = false }
        }
        if browser.hoarding {
            sheet { DownloadsPanel(browser: browser, loot: browser.loot) }
                close: { browser.hoarding = false }
        }
        if browser.tuning {
            sheet { SettingsPanel(browser: browser, prefs: browser.prefs) }
                close: { browser.tuning = false }
        }
        if browser.bookmarking {
            sheet { BookmarksPanel(browser: browser, bookmarks: browser.bookmarks) }
                close: { browser.bookmarking = false }
        }
        if browser.welcoming {
            WelcomePanel(browser: browser, prefs: browser.prefs)
                .ignoresSafeArea()
        }
        if browser.managing {
            sheet { PasswordsPanel(browser: browser) } close: { browser.managing = false }
        }
        if browser.bringingIn != nil {
            sheet { ImportPanel(browser: browser) } close: { browser.bringingIn = nil }
        }
        // What's new, once after an update, and every version's notes
        // (see WhatsNew.swift).
        if browser.newsShowing, let release = WhatsNew.current {
            sheet {
                WhatsNewCard(release: release, prefs: browser.prefs, close: { browser.newsShowing = false }) {
                    browser.newsShowing = false
                    browser.notesShowing = true
                }
            } close: { browser.newsShowing = false }
        }
        if browser.notesShowing {
            sheet { ReleaseNotesPanel { browser.notesShowing = false } } close: { browser.notesShowing = false }
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
            .overlay { field }
            .overlay { panels }
            .overlay {
                TabSwitcherOverlay(
                    switcher: browser.tabSwitcher,
                    tab: { [browser] id in browser.tabs.first { $0.id == id } ?? LittleWindow.holding(id)?.tab },
                    current: browser.activeID,
                    pick: { [browser] id in browser.commitTabSwitch(picking: id) }
                )
            }
            .overlay(alignment: .topTrailing) {
                if let job = browser.fileImport { ImportProgress(browser: browser, job: job) }
            }
            // The field comes on its spring, and goes quickly: once Return
            // is pressed the page is on its way, and the field is not what
            // there is to watch.
            .animation(browser.fieldShowing ? Motion.settle : Motion.quick, value: browser.fieldShowing)
            .background(WindowSetup { window = $0; dress($0) })
            .onChange(of: browser.prefs.sidebar) { _, _ in
                DispatchQueue.main.async { Lights.refresh(window); measureLights() }
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
                if let window, (note.object as? NSWindow) === window { browser.tabSwitcher.cancel() }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.willEnterFullScreenNotification)) { note in
                if let window, (note.object as? NSWindow) === window { browser.fullScreen = true }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.willExitFullScreenNotification)) { note in
                if let window, (note.object as? NSWindow) === window { browser.fullScreen = false }
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
            .animation(Motion.settle, value: browser.recalling)
            .animation(Motion.settle, value: browser.hoarding)
            .animation(Motion.settle, value: browser.tuning)
            .animation(Motion.settle, value: browser.welcoming)
            .animation(Motion.settle, value: browser.bookmarking)
            .animation(Motion.settle, value: browser.managing)
            .animation(Motion.settle, value: browser.newsShowing)
            .animation(Motion.settle, value: browser.notesShowing)
            .animation(Motion.settle, value: browser.bringingIn != nil)
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
            guard let web = browser.active?.web, let window = web.window else { return }
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

    /// A page asking to see or hear you. Named by the site, in its own words,
    /// with the answer remembered so it is asked once and not every call.
    private func captureAsking(_ ask: Browser.CaptureAsk) -> some View {
        HStack(spacing: 12) {
            Image(systemName: ask.wants == "location" ? "location" : ask.wants == "microphone" ? "mic" : ask.wants == "notifications" ? "bell" : "video")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.muted)
            Text(ask.wants == "location" ? "\(ask.host) wants to know your location"
                 : ask.wants == "notifications" ? "\(ask.host) wants to send you notifications"
                 : "\(ask.host) wants to use your \(ask.wants)")
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.ink)
            Button { ask.once ? browser.allowCaptureOnce() : browser.allowCapture() } label: {
                Text(ask.once ? "Allow once" : "Allow")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.ground)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .background(Palette.ink, in: Capsule())
            }
            .buttonStyle(.plain)
            if ask.once, ask.keeps {
                Button { browser.allowCapture() } label: {
                    Text("Always allow")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.ink)
                }
                .buttonStyle(.plain)
            }
            Button { browser.denyCapture() } label: {
                Text("Don't allow")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .padding(.vertical, 9)
        .background(Palette.ground, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 20, y: 6)
    }

    /// Offered once, answered once. The password is never shown back to you —
    /// there is nothing to be learned from reading your own password.
    private func keepAsking(_ offer: Browser.Offer) -> some View {
        let login = offer.login
        return HStack(spacing: 12) {
            Text(offer.changed
                 ? "Update the password for \(login.user) on \(login.host)?"
                 : (login.user.isEmpty
                    ? "Save this password for \(login.host)?"
                    : "Save the password for \(login.user) on \(login.host)?"))
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
            Button(offer.changed ? "Update" : "Save") { browser.keepOffer() }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Palette.ground)
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(Palette.ink, in: Capsule())
            Button("Not now") { browser.dropOffer() }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
            if !offer.changed {
                Button("Never here") { browser.neverOffer() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .padding(.vertical, 9)
        .background(Palette.ground, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 20, y: 6)
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
        browser.prefs.sidebar && !browser.folded && fullscreenTab == nil
    }

    /// The column has its own corner for the lights, so the page beside it
    /// starts at the very top; the strip needs a band.
    private var band: CGFloat {
        guard fullscreenTab == nil else { return 0 }
        // Folded, the strip is out of the window and the page has its height.
        return browser.prefs.sidebar || browser.folded ? 0 : Metrics.strip
    }

    /// Either visible pane may give its page to WebKit's fullscreen window.
    /// Read through immersionRevision: a tab's going full screen and coming
    /// back are the tab's changes, not the browser's, and this view watches
    /// only the browser (see fullscreenWatch).
    private var fullscreenTab: Tab? {
        _ = immersionRevision
        guard browser.prefs.splitView else { return browser.active?.immersed == true ? browser.active : nil }
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
        if browser.prefs.splitView, let split = browser.activeSplit {
            if let left = browser.tabs.first(where: { $0.id == split.left }) {
                TabImmersionWatch(tab: left) { immersionRevision += 1 }.id(left.id)
            }
            if let right = browser.tabs.first(where: { $0.id == split.right }) {
                TabImmersionWatch(tab: right) { immersionRevision += 1 }.id(right.id)
            }
        } else if let active = browser.active {
            TabImmersionWatch(tab: active) { immersionRevision += 1 }.id(active.id)
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

    private func dress(_ window: NSWindow) {
        browser.window = window
        window.tabbingMode = .disallowed
        // Light or dark is the app's to say (Settings › Appearance); the
        // window only has to be the ground colour that goes with it.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = Palette.NS.ground
        // The strip does the dragging, so the page underneath can't be grabbed
        // by accident while selecting text.
        window.isMovableByWindowBackground = false
        // Nor by its title bar, which the strip is all the way down: AppKit
        // would move the window on any drag there, a tab picked up to take
        // it elsewhere in the row included. DragStrip moves it instead. The
        // window stays movable between clicks, though — macOS's Window ›
        // Move & Resize, its tiling and the tools that arrange windows ask
        // for a movable one (#286) — and is made unmovable only while a
        // press lasts (see Browsers.watchFrames).
        window.isMovable = true

        // The traffic lights set in from the corner and centred in the strip's
        // height, in both modes, without a toolbar's rounder corners — see
        // Lights.swift. The column's first row is the strip's height too, so
        // its three doors sit on the lights' line.
        Lights.keep(window, centreX: {
            browser.prefs.sidebar && browser.prefs.sidePosition == .right
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
        guard keys == nil else { return }
        keys = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .leftMouseDown]) { event in
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
                // ⌃ let go of switches to the tab the switcher is on.
                if browser.tabSwitcher.active, !event.modifierFlags.contains(.control) {
                    browser.commitTabSwitch()
                }
                // ⌘ let go of ends a ⌘K walk, wherever it stopped.
                if !event.modifierFlags.contains(.command) { browser.landSummon() }
                return event
            }
            return take(event) ? nil : event
        }
        ContentView.keyHooks[ObjectIdentifier(browser)] = { event in take(event) ? nil : event }
    }

    /// Whether a key is this window's to act on.
    private func mine(_ event: NSEvent) -> Bool {
        if let window = event.window, Browsers.browser(for: window) != nil { return window === self.window }
        return Browsers.acting === browser
    }

    /// The same handling the key monitor gives an event, for the bench to
    /// put a key through the app's own path — each window's own.
    static var keyHooks: [ObjectIdentifier: (NSEvent) -> NSEvent?] = [:]

    /// The last key handed to the page before Search acted on it (see
    /// `pageFirst`): if WebKit sends it back unused, it is Search's.
    private static var passed: NSEvent?

    /// A key a page may want for itself — ⌘K in Slack, ⌘F in a Google Doc,
    /// ⌘S in an editor — goes to the page first, as it does in Chrome, and is
    /// Search's only if the page leaves it unused: WebKit then sends the same
    /// event back through the app, and it comes here a second time. Only
    /// while the page has the keyboard; in the address field or a panel,
    /// Search's keys are Search's. The keys that make and close tabs and move
    /// between them stay Search's first, as Chrome keeps them its own.
    ///
    /// ⌘K is always Search's, on every page: the way to any open page is
    /// the one key that must never be taken (Drice; #238). Slack, X, GitHub
    /// and ChatGPT use it themselves, and given it first they kept it.
    ///
    /// ⌘← and ⌘→ are Search's too while nothing is being typed: WebKit takes
    /// them to scroll the page sideways and never hands them back, so
    /// passing them on left them dead for going back and forward (#324).
    private func pageFirst(_ event: NSEvent, key: String, shifted: Bool) -> Bool {
        let reserved = (key == "t") || (key == "w" && !shifted) || (key == "n" && shifted)
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
    /// over the page it would have to cover.
    private func canSwitchTabs(_ event: NSEvent) -> Bool {
        guard let window, event.window === window else { return false }
        return !browser.tuning && !browser.recalling && !browser.hoarding &&
            !browser.bookmarking && !browser.welcoming && !browser.managing &&
            !browser.reviewing && !browser.finding && !browser.bookmarksOpen &&
            !browser.veiling && !browser.summoning && !browser.makingSpace &&
            browser.peekTab == nil && browser.editingTab == nil &&
            browser.asking == nil && browser.offering == nil && browser.suggesting == nil
    }

    /// The keys of the top row, by where they sit rather than what they type.
    static let digits: [UInt16: Int] = [
        18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9, 29: 0,
    ]

    private func take(_ event: NSEvent) -> Bool {
        // A small window's keys are its own (see Little.swift).
        if let little = LittleWindow.owning(event.window) { return little.take(event) }
        // An extension's popup window: ⌘W closes it, not a tab of the
        // window menus act on; every other key is its page's.
        if let popup = Browsers.browser(for: event.window), popup.extensionPopup != nil {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard event.charactersIgnoringModifiers?.lowercased() == "w", flags == .command else { return false }
            popup.window?.performClose(nil)
            return true
        }
        // A key being typed into Settings › Shortcuts is for the box.
        guard !ShortcutStore.shared.recording else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let controlTab = event.keyCode == 48 && flags.contains(.control)
            && flags.isDisjoint(with: [.command, .option])

        // While the tab switcher is up, ⌃ and the arrows move through it and
        // ⌃Tab goes on below; any other key puts it away, and Escape does
        // nothing else.
        if browser.tabSwitcher.active, !controlTab {
            if flags.contains(.control), flags.isDisjoint(with: [.command, .option]) {
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
            if browser.notesShowing {
                browser.notesShowing = false
                return true
            }
            if browser.newsShowing {
                browser.newsShowing = false
                return true
            }
            if browser.tuning {
                browser.tuning = false
                return true
            }
            if browser.bookmarking {
                browser.bookmarking = false
                return true
            }
            if browser.managing {
                browser.managing = false
                return true
            }
            if browser.bringingIn != nil {
                browser.bringingIn = nil
                return true
            }
            if browser.recalling {
                browser.recalling = false
                return true
            }
            if browser.hoarding {
                browser.hoarding = false
                return true
            }
            if browser.suggesting != nil {
                browser.dropChoice()
                return true
            }
            if browser.assisting != nil {
                browser.closeAssistant()
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
        if browser.prefs.splitView, browser.activeSplit != nil, let combo = KeyCombo(event: event) {
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
        // ⌥⌘Return, with Split View on, keeps it beside the page instead.
        if event.keyCode == 36 || event.keyCode == 76,
           flags.intersection([.command, .shift, .option, .control]) == .command
            || (browser.prefs.splitView && flags.intersection([.command, .shift, .option, .control]) == [.command, .option]),
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
        if event.keyCode == 48, !flags.contains(.command), !flags.contains(.option) {
            if flags.contains(.control) {
                if canSwitchTabs(event) {
                    // A Tab held down doesn't race through them.
                    if !event.isARepeat { browser.switchTabs(backwards: flags.contains(.shift)) }
                    return true
                }
                browser.step(flags.contains(.shift) ? -1 : 1)
                return true
            }
            if browser.editingTab != nil { return true }
            // "red" then Tab: Reddit, in the field (SiteSearch.swift).
            if browser.fieldShowing, !flags.contains(.shift), browser.lockSiteOffer() { return true }
            if browser.fieldShowing, !browser.offers.isEmpty {
                browser.walk(flags.contains(.shift) ? -1 : 1)
                return true
            }
            return false
        }

        // ⌃1–⌃9 go to that space, when there are spaces — by the key, as
        // ⌘1–⌘9 are below, so the top row works on every layout.
        if browser.prefs.usesSpaces, flags.contains(.control),
           flags.isDisjoint(with: [.command, .option, .shift]),
           let number = ContentView.digits[event.keyCode], number > 0 {
            browser.switchSpace(index: number - 1)
            return true
        }

        // Your own keys (Settings › Shortcuts), before an extension's and the
        // ones below: a command you moved runs on its new key, and a key you
        // took off a command goes on to the page. Nothing here unless you
        // changed something.
        if ShortcutStore.shared.anyChanged, let combo = KeyCombo(event: event) {
            if let command = ShortcutStore.shared.changedCommand(on: combo) {
                if Command.split.contains(command.id), !browser.prefs.splitView { return false }
                if Command.ai.contains(command.id), !browser.prefs.ai { return false }
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
           event.characters(byApplyingModifiers: [])?.lowercased() == "r" {
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
        // in every other browser. The ninth is the last tab, however many.
        // Only tabs on screen count: not those folded away in a group.
        if !shifted, let number = ContentView.digits[event.keyCode] {
            if number == 0 {
                browser.resetZoom()
            } else {
                browser.select(index: number == 9 ? browser.shownTabs.count - 1 : number - 1)
            }
            return true
        }

        // Keep the clearing controls reachable from a focused page editor.
        if shifted, event.keyCode == 51 {
            browser.recallMode = .clearing
            return true
        }

        // The page's turn first, for the keys it may want (Refs #147).
        if pageFirst(event, key: key, shifted: shifted) { return false }

        switch key {
        case "t" where !shifted:
            browser.newTab()
        case "t" where shifted:
            browser.reopen()
        case "c" where shifted:
            browser.copyAddress()
        case "d" where !shifted:
            browser.duplicate()
        case "n" where shifted:
            browser.newShyTab()
        case "y" where !shifted:
            browser.recalling.toggle()
        case "j" where shifted:
            browser.hoarding.toggle()
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
        case "s" where shifted:
            browser.toggleSidebar()
        case "s" where !shifted:
            // The column or the strip, folded away (see Fold.swift).
            browser.toggleFold()
        case "b" where shifted:
            browser.bookmarkCurrent()
        case "," where !shifted:
            browser.tuning.toggle()
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
            if browser.peekTab != nil {
                browser.closePeek()
            } else if let tab = browser.active {
                browser.close(tab)
            }
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
    @State private var previous: Bool?

    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .onReceive(tab.$immersed.removeDuplicates()) { value in
                let didChange = previous != nil && previous != value
                previous = value
                if didChange { changed() }
            }
    }
}

/// The update command, as the updater stands: Check for Updates…, Install
/// Update when installing on its own is off, Download Update… when it
/// couldn't install itself, Restart to Update once a newer build is in place.
/// Its own view, so only the updater's changes redraw it (see SearchApp.body).
private struct UpdateMenuItem: View {
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        switch updater.stage {
        case .none:
            Button(updater.checking ? "Checking for Updates…" : "Check for Updates…") { updater.checkByHand() }
                .disabled(updater.checking)
        case .waiting:
            Button("Install Update") { updater.install() }
        case .fetching:
            Button("Downloading Update…") {}
                .disabled(true)
        case .ready:
            Button("Restart to Update") { updater.relaunch() }
        case .offered:
            Button(updater.fetchingDisk ? "Downloading Update…" : "Download Update…") { updater.openDisk() }
                .disabled(updater.fetchingDisk)
        }
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
