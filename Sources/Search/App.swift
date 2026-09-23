import SwiftUI
import AppKit

// A window, a row of titles, and a field. Typing an address gets you a page;
// there is nothing else to learn and nothing else to press.

@main
struct SearchApp: App {
    @StateObject private var browser = Browser()
    /// Links from other apps, and the Dock icon.
    @NSApplicationDelegateAdaptor(Links.self) private var links

    var body: some Scene {
        Window("Search", id: "browser") {
            ContentView(browser: browser)
                .frame(minWidth: 640, minHeight: 420)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 780)
        .commands {
            // One window. Tabs are the only kind of "new" there is.
            CommandGroup(replacing: .newItem) {
                item("file.newTab")
                item("file.newPrivateTab")
                item("file.reopen")
                    .disabled(browser.ghosts.isEmpty)
                Divider()
                item("file.openAddress")
                Divider()
                item("file.closeTab")
            }
            CommandGroup(replacing: .printItem) {
                item("file.print")
                    .disabled(browser.active?.isBlank ?? true)
            }
            CommandGroup(after: .pasteboard) {
                Divider()
                item("edit.find")
                    .disabled(browser.active?.isBlank ?? true)
                item("edit.findNext")
                    .disabled(!browser.finding)
                item("edit.findPrevious")
                    .disabled(!browser.finding)
            }
            CommandGroup(replacing: .toolbar) {
                Toggle("Show Tabs in Sidebar", isOn: Binding(
                    get: { browser.prefs.sidebar },
                    set: { _ in browser.toggleSidebar() }
                ))
                .keyboardShortcut(key("view.sidebar"))
                // Folded away, not moved (see Fold.swift).
                Button(browser.folded ? "Show Sidebar" : "Hide Sidebar") { browser.run("view.fold") }
                    .keyboardShortcut(key("view.fold"))
                    .disabled(!browser.prefs.sidebar)
                Picker("Tabs Wear", selection: Binding(
                    get: { browser.prefs.glyph },
                    set: { browser.prefs.glyph = $0 }
                )) {
                    ForEach(Glyph.allCases) { glyph in
                        Text(glyph.title).tag(glyph)
                    }
                }
                Divider()
                item("view.reload")
                item("view.reader")
                item("view.float")
                Divider()
                item("view.hide")
                item("view.hidden")
                Divider()
                item("view.zoomIn")
                item("view.zoomOut")
                item("view.actualSize")
            }
            CommandMenu("Tabs") {
                item("tabs.back")
                    .disabled(browser.active?.canGoBack != true)
                item("tabs.forward")
                    .disabled(browser.active?.canGoForward != true)
                Divider()
                item("tabs.next")
                item("tabs.previous")
                item("tabs.search")
                Divider()
                if let tab = browser.active {
                    if tab.pin == nil {
                        item("tabs.pin")
                            .disabled(tab.isBlank)
                    } else {
                        item("tabs.letter")
                        item("tabs.unpin")
                    }
                }
                item("tabs.duplicate")
                    .disabled(browser.active?.isBlank ?? true)
                item("tabs.copyAddress")
                    .disabled(browser.active?.isBlank ?? true)
                item("tabs.pasteAndGo")
                Divider()
                item("tabs.closeOthers")
                    .disabled(browser.tabs.count < 2)
                item("tabs.mute")
            }
            CommandMenu("Bookmarks") {
                item("bookmarks.add")
                    .disabled(browser.active?.isBlank ?? true)
                item("bookmarks.show")
                Divider()
                BookmarkTree(nodes: browser.bookmarks.roots) { browser.visit($0) }
            }
            CommandMenu("History") {
                Section("Recently Visited") {
                    ForEach(browser.recentlyVisited) { trace in
                        Button {
                            browser.open(trace.url, foreground: true)
                        } label: {
                            MenuLine(title: trace.title.isEmpty ? trace.key : trace.title, url: trace.url)
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
                item("history.show")
                item("history.downloads")
                Divider()
                item("history.clear")
            }
            CommandGroup(after: .appSettings) {
                item("app.settings")
                item("app.welcome")
                item("app.passwords")
            }
            CommandGroup(replacing: .help) {
                Button("Send Feedback…") { Links.writeFeedback() }
            }
        }
    }

    /// A command as a menu item, on the key it has now (Settings › Shortcuts).
    private func item(_ id: String) -> some View {
        Button(Command.named(id)?.title ?? id) { browser.run(id) }
            .keyboardShortcut(key(id))
    }

    private func key(_ id: String) -> KeyboardShortcut? {
        browser.shortcuts.key(for: id)?.swiftUI
    }
}

/// The bookmarks, as menus within menus, for the menu bar.
private struct BookmarkTree: View {
    let nodes: [Bookmark]
    let open: (URL) -> Void

    var body: some View {
        ForEach(nodes) { node in
            if node.isFolder {
                Menu(node.title) {
                    if let kids = node.children, !kids.isEmpty {
                        BookmarkTree(nodes: kids, open: open)
                    } else {
                        Text("Empty")
                    }
                }
            } else if let text = node.url, let url = URL(string: text) {
                Button(node.title) { open(url) }
            }
        }
    }
}

/// A page, as a line in a menu: its icon if one is known, and its name.
private struct MenuLine: View {
    let title: String
    let url: URL

    var body: some View {
        if let host = url.host()?.lowercased(),
           let icon = Favicons.shared.cached(host) {
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

struct ContentView: View {
    @ObservedObject var browser: Browser

    @State private var keys: Any?
    @State private var window: NSWindow?
    @State private var resting: RestingLights?


    /// The window: room at the top, one stage for the page, and the row when
    /// there is one.
    private var window_: some View {
        ZStack(alignment: .top) {
            // Black while a page has the screen, so the frame of our own window
            // that survives the transition is not a white band across the top.
            (browser.active?.immersed == true ? Color.black : Palette.ground)

            HStack(spacing: 0) {
                // The column of tabs, in the way that has one. It takes the
                // full height, so the traffic lights sit in its own corner
                // rather than over the page.
                if sidebar {
                    SideBar(browser: browser, prefs: browser.prefs)
                        .transition(.move(edge: .leading))
                }

                VStack(spacing: 0) {
                    // Room for the traffic lights, and for the strip when there
                    // is one. The page starts under it, not behind it — a page
                    // sliding beneath floating chrome is a browser showing off,
                    // and it costs a compositing pass.
                    Color.clear.frame(height: band)

                    // One stage, always.
                    if let tab = browser.active {
                        Page(tab: tab)
                            .overlay(alignment: .topTrailing) {
                                if browser.finding {
                                    FindBar(browser: browser)
                                        .transition(.move(edge: .top).combined(with: .opacity))
                                }
                            }
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
            }

            if !browser.prefs.sidebar, browser.active?.immersed != true {
                TabBar(browser: browser)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .ignoresSafeArea()
        .animation(Motion.glide, value: browser.prefs.sidebar)
        .animation(.easeOut(duration: 0.12), value: browser.active?.immersed)
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
            if let ask = browser.shortcutAsk {
                shortcutAsking(ask)
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
        .animation(Motion.settle, value: browser.shortcutAsk)
    }

    /// The address field: raised over a page by ⌘L or ⌘K, and standing on its
    /// own whenever a tab has nowhere to be yet.
    @ViewBuilder
    private var field: some View {
        if browser.fieldShowing {
            Omnibox(browser: browser, over: !(browser.active?.isBlank ?? true))
                // Centred on the page, not on the window. The column of tabs
                // is not what the field is standing over, and dimming it along
                // with the page says otherwise.
                .padding(.leading, sidebar ? browser.prefs.sideWidth : 0)
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
            .overlay(alignment: .leading) { Fold(browser: browser, prefs: browser.prefs) }
            .overlay(alignment: .bottom) { bars }
            .overlay { field }
            .overlay { panels }
            .animation(Motion.settle, value: browser.fieldShowing)
            .background(WindowSetup { window = $0; dress($0) })
            .onChange(of: browser.prefs.sidebar) { _, _ in
                DispatchQueue.main.async { measureLights() }
            }
            // Stepping away to another app: macOS draws its own resting
            // buttons, and on a light window they come out nearly white. Ours
            // go on in their place until the app comes back.
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
                measureLights()
                resting?.isHidden = false
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                resting?.isHidden = true
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
            .animation(Motion.settle, value: browser.reviewing)
        .onAppear {
            watchKeys()
            PageView.unused = { [browser] event in
                guard let id = browser.keyRouter.takeBack(event) else { return false }
                browser.run(id)
                return true
            }
            browser.askFocus()
            // Addresses from other apps have somewhere to go from here on.
            Links.hand(to: browser)
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
            guard let web = browser.active?.web, let window = web.window else { return }
            window.makeFirstResponder(web)
        }
    }

    // MARK: - the window

    /// A line that rises from the bottom, says one thing, and leaves.
    @ViewBuilder
    private var announcement: some View {
        if let text = browser.announcement {
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Palette.ink)
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
            Image(systemName: ask.wants == "microphone" ? "mic" : "video")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.muted)
            Text("\(ask.host) wants to use your \(ask.wants)")
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.ink)
            Button { browser.allowCapture() } label: {
                Text("Allow")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.ground)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .background(Palette.ink, in: Capsule())
            }
            .buttonStyle(.plain)
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


    /// A site used a key one of Search's commands is on, and that command is
    /// set to ask: who gets the key from now on.
    private func shortcutAsking(_ ask: Browser.ShortcutAsk) -> some View {
        let command = Command.named(ask.id)
        let keys = browser.shortcuts.key(for: ask.id)?.display ?? ""
        return HStack(spacing: 12) {
            Text("\(ask.site ?? "This page") used \(keys). Use Search's \(command?.title ?? "shortcut") instead?")
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
            Button("Use Search's") { browser.answerShortcutAsk(app: true) }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Palette.ground)
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(Palette.ink, in: Capsule())
            Button("Keep for websites") { browser.answerShortcutAsk(app: false) }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
            Button { browser.shortcutAsk = nil } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Palette.muted)
            }
            .buttonStyle(.plain)
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
        browser.prefs.sidebar && !browser.folded && browser.active?.immersed != true
    }

    /// The column has its own corner for the lights, so the page beside it
    /// starts at the very top; the strip needs a band.
    private var band: CGFloat {
        guard browser.active?.immersed != true else { return 0 }
        return browser.prefs.sidebar ? 0 : Metrics.strip
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
        Links.window = window
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
        // it elsewhere in the row included. DragStrip moves it instead.
        window.isMovable = false
        // Where you left it, at the size you left it. A test run keeps its
        // own: the name lives in the app's standard defaults, which every
        // copy shares, and a probe resized for a test once changed the size
        // the real window came back at.
        window.setFrameAutosaveName(Store.world.map { "search (\($0))" } ?? "search")

        // The traffic lights set in from the corner and centred in the strip's
        // height, in both modes, without a toolbar's rounder corners — see
        // Lights.swift. The column's first row is the strip's height too, so
        // its three doors sit on the lights' line.
        Lights.keep(window) { measureLights() }
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
        keys = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            guard event.type == .keyDown else {
                // ⌘ let go of ends a ⌘K walk, wherever it stopped.
                if !event.modifierFlags.contains(.command) { browser.landSummon() }
                return event
            }
            return take(event) ? nil : event
        }
    }

    /// The keys of the top row, by where they sit rather than what they type.
    static let digits: [UInt16: Int] = [
        18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9, 29: 0,
    ]

    private func take(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""

        // Settings › Shortcuts is waiting for a key: it's the recorder's.
        if browser.recordingShortcut { return false }

        // A key handed to the page first, sent back unused: Search's after all.
        if let id = browser.keyRouter.takeBack(event) {
            browser.run(id)
            return true
        }

        // Escape puts the page back. On a blank tab there is no page to put
        // back, so it belongs to whatever else wants it.
        if event.keyCode == 53 {
            if browser.editingTab != nil {
                browser.cancelTabEdit()
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
            guard browser.editing, browser.active?.isBlank == false else { return false }
            browser.dismiss()
            return true
        }

        // Tab is the page's: it moves between a form's fields and a page's
        // links, as in every browser. It used to walk the row of tabs, which
        // took it from anyone filling in a form. ⌃Tab walks the row and comes
        // round to the first again, ⌃⇧Tab the other way — the keys every
        // other browser uses for that.
        //
        // While an address is being typed, the list under the field is what
        // there is to move through, and Return takes whatever the walk landed on.
        if event.keyCode == 48, !flags.contains(.command), !flags.contains(.option) {
            if flags.contains(.control) {
                browser.step(flags.contains(.shift) ? -1 : 1)
                return true
            }
            if browser.editingTab != nil { return true }
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

        // A shortcut an extension registered — ⌥⇧D, ⌃⇧Y — before ours, since
        // none of ours use those.
        if #available(macOS 15.4, *), !flags.intersection([.command, .option, .control]).isEmpty,
           Extensions.shared.take(event) {
            return true
        }

        // Only while pointing. Everywhere else undo belongs to the page.
        if browser.veiling, key == "z", flags == .command {
            browser.undoHiding()
            return true
        }

        guard let combo = KeyCombo(event: event), combo.isUsable,
              let command = browser.shortcuts.command(matching: combo)
        else { return false }

        // Set to let websites have the key first: the page gets it, and
        // Search acts only if the page sends it back unused.
        let conflict = browser.shortcuts.conflict(for: command.id)
        if KeyRoute.decide(conflict, pageHasFocus: pageHasFocus(event)) == .hand, let page = browser.active?.built {
            browser.keyRouter.hand(event, for: command.id, to: page, prompt: conflict == .prompt,
                                   site: browser.active?.address?.host()) { id, site in
                browser.shortcutAsk = Browser.ShortcutAsk(id: id, site: site)
            }
            return true
        }
        return command.run(browser)
    }

    /// The page is what the key is meant for: its view has the keyboard and
    /// nothing is open over it.
    private func pageHasFocus(_ event: NSEvent) -> Bool {
        guard let page = browser.active?.built, let window = event.window,
              window.firstResponder === page, !browser.fieldShowing
        else { return false }
        return nothingOver
    }

    /// No panel, field, bar or mode is up over the page.
    private var nothingOver: Bool {
        !browser.tuning && !browser.recalling && !browser.hoarding &&
            !browser.bookmarking && !browser.welcoming && !browser.managing &&
            !browser.reviewing && !browser.finding && !browser.bookmarksOpen &&
            !browser.veiling && !browser.summoning && browser.editingTab == nil &&
            browser.asking == nil && browser.offering == nil && browser.suggesting == nil
    }
}
