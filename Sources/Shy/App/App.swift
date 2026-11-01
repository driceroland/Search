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
