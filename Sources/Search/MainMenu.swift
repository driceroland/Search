import AppKit
import SwiftUI

// The menu bar, built natively in AppKit and populated lazily on open.
//
// SwiftUI's `.commands` builds an AttributeGraph for every menu item up front
// during applicationWillFinishLaunching (50–98 ms on the main thread, plus a
// synchronous dlopen of WritingToolsUI) and rebuilds the whole bar whenever
// the front Browser publishes any change. Here the menu bar starts as nine
// lightweight NSMenu shells; each submenu builds its items in `menuNeedsUpdate`
// when opened or when a menu key equivalent is matched.

@MainActor
final class MainMenu: NSObject, NSMenuDelegate, NSMenuItemValidation {
    static let shared = MainMenu()

    private let appMenu = NSMenu(title: "Search")
    private let fileMenu = NSMenu(title: "File")
    private let editMenu = NSMenu(title: "Edit")
    private let substitutionsMenu = NSMenu(title: "Substitutions")
    private let spellingMenu = NSMenu(title: "Spelling and Grammar")
    private let viewMenu = NSMenu(title: "View")
    private let glyphMenu = NSMenu(title: "Tabs Wear")
    private let sidePanelMenu = NSMenu(title: "Side Panel")
    private let tabsMenu = NSMenu(title: "Tabs")
    private let bookmarksMenu = NSMenu(title: "Bookmarks")
    private let historyMenu = NSMenu(title: "History")
    private let windowMenu = NSMenu(title: "Window")
    private let helpMenu = NSMenu(title: "Help")
    private let servicesMenu = NSMenu(title: "Services")

    private var installed = false
    /// Actions keyed by menu item identity; cleared each time a submenu rebuilds.
    private var actions: [ObjectIdentifier: () -> Void] = [:]
    private var enabledFlags: [ObjectIdentifier: Bool] = [:]
    /// Per-submenu item ids so rebuilding one menu frees only its own closures.
    private var owned: [ObjectIdentifier: [ObjectIdentifier]] = [:]

    private var browser: Browser { Front.shared.browser ?? SceneSlot.shared.browser }

    func install(on app: NSApplication) {
        guard !installed else { return }
        installed = true

        let bar = NSMenu()
        let top: [(String, NSMenu, Bool)] = [
            ("Search", appMenu, true),
            ("File", fileMenu, false),
            ("Edit", editMenu, true),
            ("View", viewMenu, false),
            ("Tabs", tabsMenu, false),
            ("Bookmarks", bookmarksMenu, false),
            ("History", historyMenu, false),
            ("Window", windowMenu, true),
            ("Help", helpMenu, false),
        ]
        for (title, submenu, autoEnables) in top {
            submenu.autoenablesItems = autoEnables
            submenu.delegate = self
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            holder.submenu = submenu
            bar.addItem(holder)
        }
        for sub in [substitutionsMenu, spellingMenu, glyphMenu, sidePanelMenu] {
            sub.autoenablesItems = false
            sub.delegate = self
        }

        // Fixed Window menu skeleton: macOS appends open windows below these,
        // and Bench "window" reads the "Search" item directly.
        buildWindowMenu()

        app.mainMenu = bar
        app.servicesMenu = servicesMenu
        app.windowsMenu = windowMenu
        app.helpMenu = helpMenu
        // Register any window that already opened before windowsMenu was attached.
        for window in app.windows where window.isVisible && !window.isExcludedFromWindowsMenu {
            app.addWindowsItem(window, title: window.title, filename: false)
        }
    }

    /// Rebuilds the Bookmarks menu in place (for Bench tests).
    func refreshBookmarks() {
        rebuild(bookmarksMenu)
    }

    // MARK: - NSMenuDelegate

    nonisolated func menuNeedsUpdate(_ menu: NSMenu) {
        MainActor.assumeIsolated {
            rebuild(menu)
        }
    }

    private func rebuild(_ menu: NSMenu) {
        switch menu {
        case appMenu: buildAppMenu()
        case fileMenu: buildFileMenu()
        case editMenu: buildEditMenu()
        case substitutionsMenu: buildSubstitutionsMenu()
        case spellingMenu: buildSpellingMenu()
        case viewMenu: buildViewMenu()
        case glyphMenu: buildGlyphMenu()
        case sidePanelMenu: buildSidePanelMenu()
        case tabsMenu: buildTabsMenu()
        case bookmarksMenu: buildBookmarksMenu()
        case historyMenu: buildHistoryMenu()
        case windowMenu: updateWindowMenu()
        case helpMenu: buildHelpMenu()
        default: break
        }
    }

    // MARK: - item builders

    private func reset(_ menu: NSMenu) {
        let key = ObjectIdentifier(menu)
        if let old = owned.removeValue(forKey: key) {
            for id in old {
                actions.removeValue(forKey: id)
                enabledFlags.removeValue(forKey: id)
            }
        }
        menu.removeAllItems()
    }

    @discardableResult
    private func add(
        to menu: NSMenu,
        _ title: String,
        shortcut id: String? = nil,
        key: String? = nil,
        modifiers: NSEvent.ModifierFlags? = nil,
        enabled: Bool = true,
        state: NSControl.StateValue = .off,
        image: NSImage? = nil,
        action: @escaping () -> Void
    ) -> NSMenuItem {
        let (equiv, mods) = shortcutSpec(id: id, key: key, modifiers: modifiers)
        let item = NSMenuItem(title: title, action: #selector(invoke(_:)), keyEquivalent: equiv)
        item.keyEquivalentModifierMask = mods
        item.target = self
        item.isEnabled = enabled
        item.state = state
        item.image = image
        let itemID = ObjectIdentifier(item)
        actions[itemID] = action
        enabledFlags[itemID] = enabled
        owned[ObjectIdentifier(menu), default: []].append(itemID)
        menu.addItem(item)
        return item
    }

    @discardableResult
    private func addResponder(
        to menu: NSMenu,
        _ title: String,
        action: Selector,
        key: String = "",
        modifiers: NSEvent.ModifierFlags = [.command],
        target: AnyObject? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        if !key.isEmpty { item.keyEquivalentModifierMask = modifiers }
        item.target = target
        menu.addItem(item)
        return item
    }

    private func addSubmenu(to menu: NSMenu, _ title: String, _ submenu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        menu.addItem(item)
    }

    private func shortcutSpec(
        id: String?,
        key: String?,
        modifiers: NSEvent.ModifierFlags?
    ) -> (String, NSEvent.ModifierFlags) {
        if let id {
            if let spec = ShortcutStore.shared.key(for: id)?.appKit {
                return spec
            }
            return ("", [])
        }
        if let key {
            return (key, modifiers ?? [.command])
        }
        return ("", [])
    }

    @objc private func invoke(_ sender: NSMenuItem) {
        actions[ObjectIdentifier(sender)]?()
    }

    nonisolated func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        MainActor.assumeIsolated {
            enabledFlags[ObjectIdentifier(menuItem)] ?? true
        }
    }

    // MARK: - Search (App)

    private func buildAppMenu() {
        let b = browser
        reset(appMenu)
        addResponder(to: appMenu, "About Search", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), target: NSApp)
        appMenu.addItem(.separator())
        add(to: appMenu, "Settings…", shortcut: "app.settings") { b.tuning = true }
        add(to: appMenu, "Welcome…", shortcut: "app.welcome") { b.welcoming = true }
        appMenu.addItem(.separator())
        addSubmenu(to: appMenu, "Services", servicesMenu)
        appMenu.addItem(.separator())
        addResponder(to: appMenu, "Hide Search", action: #selector(NSApplication.hide(_:)), key: "h", target: NSApp)
        addResponder(to: appMenu, "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), key: "h", modifiers: [.command, .option], target: NSApp)
        addResponder(to: appMenu, "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), target: NSApp)
        appMenu.addItem(.separator())
        add(to: appMenu, "Quit Search", key: "q", modifiers: [.command]) {
            if Links.shouldQuit() { NSApp.terminate(nil) }
        }
    }

    // MARK: - File

    private func buildFileMenu() {
        let b = browser
        let isWeb = b.active?.isWeb ?? false
        reset(fileMenu)
        add(to: fileMenu, "New Window", shortcut: "file.newWindow") { Browsers.newWindow() }
        add(to: fileMenu, "New Tab", shortcut: "file.newTab") { b.launch() }
        add(to: fileMenu, "New Blank Tab", shortcut: "file.newBlankTab") { b.newTab() }
        add(to: fileMenu, "New Private Tab", shortcut: "file.newPrivateTab") { b.newShyTab() }
        add(to: fileMenu, b.reopenTitle, shortcut: "file.reopen",
            enabled: !(b.ghosts.isEmpty && Browsers.lastClosedAt == nil)) { b.reopen() }
        fileMenu.addItem(.separator())
        add(to: fileMenu, "Open Address…", shortcut: "file.openAddress") { b.edit() }
        fileMenu.addItem(.separator())
        add(to: fileMenu, "Bring Things Over…", shortcut: "file.import") { b.bringingIn = "" }
        fileMenu.addItem(.separator())
        add(to: fileMenu, "Close Tab", shortcut: "file.closeTab") { b.closeFront() }
        add(to: fileMenu, "Close Window", shortcut: "file.closeWindow") { b.closeWindow() }
        let agents = AgentControl.shared
        add(to: fileMenu,
            agents.shownIn == nil ? "Stop Agent" : "Stop \(agents.session?.client ?? "Agent")",
            shortcut: "file.stopAgent",
            enabled: agents.shownIn != nil) {
            AgentControl.shared.stopSession()
        }
        fileMenu.addItem(.separator())
        add(to: fileMenu, "Share…", shortcut: "file.share", enabled: isWeb) { b.share() }
        add(to: fileMenu, "Save Page As…", shortcut: "file.savePage", enabled: isWeb) { b.savePage() }
        add(to: fileMenu, "Export as PDF…", shortcut: "file.exportPDF", enabled: isWeb) { b.exportPDF() }
        add(to: fileMenu, "Print…", shortcut: "file.print", enabled: isWeb) { b.printPage() }
    }

    // MARK: - Edit

    private func buildEditMenu() {
        let b = browser
        reset(editMenu)
        addResponder(to: editMenu, "Undo", action: Selector(("undo:")), key: "z")
        addResponder(to: editMenu, "Redo", action: Selector(("redo:")), key: "z", modifiers: [.command, .shift])
        editMenu.addItem(.separator())
        addResponder(to: editMenu, "Cut", action: #selector(NSText.cut(_:)), key: "x")
        addResponder(to: editMenu, "Copy", action: #selector(NSText.copy(_:)), key: "c")
        addResponder(to: editMenu, "Paste", action: #selector(NSText.paste(_:)), key: "v")
        addResponder(to: editMenu, "Paste and Match Style", action: #selector(NSTextView.pasteAsPlainText(_:)), key: "v", modifiers: [.command, .option, .shift])
        addResponder(to: editMenu, "Delete", action: #selector(NSText.delete(_:)))
        addResponder(to: editMenu, "Select All", action: #selector(NSText.selectAll(_:)), key: "a")
        editMenu.addItem(.separator())
        add(to: editMenu, "Copy Clean Link", shortcut: "edit.copyCleanLink",
            enabled: !(b.active?.isBlank ?? true)) { b.copyCleanLink() }
        editMenu.addItem(.separator())
        let canFind = (b.active?.isWeb ?? false) || b.active?.page?.kind == .settings
        add(to: editMenu, "Find on Page…", shortcut: "edit.find", enabled: canFind) { b.openFind() }
        add(to: editMenu, "Find Next", shortcut: "edit.findNext", enabled: b.finding) { b.look(forward: true) }
        add(to: editMenu, "Find Previous", shortcut: "edit.findPrevious", enabled: b.finding) { b.look(forward: false) }
        editMenu.addItem(.separator())
        addSubmenu(to: editMenu, "Substitutions", substitutionsMenu)
        addSubmenu(to: editMenu, "Spelling and Grammar", spellingMenu)
    }

    private func buildSubstitutionsMenu() {
        let b = browser
        reset(substitutionsMenu)
        add(to: substitutionsMenu, "Show Substitutions") { Substitution.showPanel() }
        substitutionsMenu.addItem(.separator())
        for kind in Substitution.allCases {
            add(to: substitutionsMenu, kind.title,
                state: b.substitutes(kind) ? .on : .off) { b.toggleSubstitution(kind) }
        }
    }

    private func buildSpellingMenu() {
        let b = browser
        reset(spellingMenu)
        add(to: spellingMenu, "Correct Spelling Automatically",
            state: b.prefs.autocorrect ? .on : .off) { b.prefs.autocorrect.toggle() }
        add(to: spellingMenu, "Show Inline Predictions",
            state: b.prefs.inlinePredictions ? .on : .off) { b.prefs.inlinePredictions.toggle() }
    }

    // MARK: - View

    private func buildViewMenu() {
        let b = browser
        let isWeb = b.active?.isWeb ?? false
        reset(viewMenu)

        let foldTitle = b.prefs.shrinks && !b.folded
            ? (b.prefs.sideIcons ? "Show Sidebar Titles" : "Show Sidebar as Icons Only")
            : (b.folded ? "Show Sidebar" : "Hide Sidebar")
        add(to: viewMenu, foldTitle, shortcut: "view.fold") { b.toggleFold() }
        addSubmenu(to: viewMenu, "Tabs Wear", glyphMenu)
        add(to: viewMenu, "Fold All Groups", shortcut: "view.foldGroups", enabled: b.canFoldAllGroups) {
            b.foldAllGroups(true)
        }
        add(to: viewMenu, "Unfold All Groups", shortcut: "view.unfoldGroups", enabled: b.canUnfoldAllGroups) {
            b.foldAllGroups(false)
        }
        viewMenu.addItem(.separator())
        add(to: viewMenu, "Reload Page", shortcut: "view.reload") { b.reload() }
        add(to: viewMenu, "Reload Page From Origin", shortcut: "view.reloadOrigin") { b.reload(fromOrigin: true) }
        add(to: viewMenu, "Reading Mode", shortcut: "view.reader") { b.toggleReader() }
        add(to: viewMenu, "Float Video", shortcut: "view.float") { b.toggleFloat() }
        if b.prefs.sitesInPanel {
            addSubmenu(to: viewMenu, "Side Panel", sidePanelMenu)
        }
        if b.prefs.darkensPages {
            viewMenu.addItem(.separator())
            add(to: viewMenu, "Darken This Site", shortcut: "view.dusk",
                enabled: b.canDusk,
                state: (b.active?.dusked ?? false) ? .on : .off) { b.toggleDusk() }
            add(to: viewMenu, "Pause Darkening", shortcut: "view.duskPause",
                state: Dusk.shared.paused ? .on : .off) { b.pauseDusk() }
        }
        if b.prefs.ai {
            viewMenu.addItem(.separator())
            add(to: viewMenu, "Summarize Page", shortcut: "view.summarize", enabled: isWeb) { b.summarizePage() }
            add(to: viewMenu, "Ask About This Page…", shortcut: "view.ask", enabled: isWeb) { b.askAboutPage() }
        }
        viewMenu.addItem(.separator())
        if b.prefs.capturesPages {
            add(to: viewMenu, "Capture…", shortcut: "view.capture", enabled: isWeb) { b.toggleSnap() }
        }
        add(to: viewMenu, "Hide Elements…", shortcut: "view.hide") { b.toggleHiding() }
        add(to: viewMenu, "Hidden on This Site…", shortcut: "view.hidden") { b.reviewing.toggle() }
        if b.prefs.sitesStyles {
            add(to: viewMenu, "Edit Site Style…", shortcut: "view.style",
                enabled: isWeb && b.active?.shy != true) { b.editSiteStyle() }
        }
        viewMenu.addItem(.separator())
        add(to: viewMenu, "Zoom In", shortcut: "view.zoomIn") { b.zoom(by: 1.1) }
        add(to: viewMenu, "Zoom Out", shortcut: "view.zoomOut") { b.zoom(by: 1 / 1.1) }
        add(to: viewMenu, b.prefs.actualSizeTitle, shortcut: "view.actualSize") { b.resetZoom() }
        viewMenu.addItem(.separator())
        add(to: viewMenu, "Web Inspector", shortcut: "view.inspector") { b.toggleInspector() }
        add(to: viewMenu, "JavaScript Console", shortcut: "view.console") { b.showConsole() }
        add(to: viewMenu, "Inspect Element", shortcut: "view.inspect") { b.inspectElement() }
        viewMenu.addItem(.separator())
        add(to: viewMenu, b.fullScreen ? "Exit Full Screen" : "Enter Full Screen",
            key: "f", modifiers: [.control, .command]) {
            (NSApp.keyWindow ?? b.window)?.toggleFullScreen(nil)
        }
    }

    private func buildGlyphMenu() {
        let b = browser
        reset(glyphMenu)
        for glyph in Glyph.allCases {
            add(to: glyphMenu, glyph.title, state: b.prefs.glyph == glyph ? .on : .off) {
                b.prefs.glyph = glyph
            }
        }
    }

    private func buildSidePanelMenu() {
        let b = browser
        reset(sidePanelMenu)
        add(to: sidePanelMenu, b.sidePanelShown ? "Close Side Panel" : "Show Side Panel",
            shortcut: "view.sitePanel") { b.toggleSitePanel() }
        sidePanelMenu.addItem(.separator())
        for site in PanelSites.offered {
            add(to: sidePanelMenu, site.name) { b.showSiteInPanel(site.url) }
        }
        sidePanelMenu.addItem(.separator())
        let canOpen = (b.active?.isWeb ?? false) && !(b.active?.shy ?? true)
        add(to: sidePanelMenu, "This Page", enabled: canOpen) {
            if let tab = b.active { b.openInSidePanel(tab) }
        }
    }

    // MARK: - Tabs

    private func buildTabsMenu() {
        let b = browser
        let isWeb = b.active?.isWeb ?? false
        reset(tabsMenu)

        add(to: tabsMenu, "Back", shortcut: "tabs.back", enabled: b.active?.canGoBack == true) { b.back() }
        add(to: tabsMenu, "Forward", shortcut: "tabs.forward", enabled: b.active?.canGoForward == true) { b.forward() }
        tabsMenu.addItem(.separator())
        add(to: tabsMenu, "Next Tab", shortcut: "tabs.next") { b.step(1) }
        add(to: tabsMenu, "Previous Tab", shortcut: "tabs.previous") { b.step(-1) }
        add(to: tabsMenu, "Search Tabs…", shortcut: "tabs.search") { b.summon() }
        tabsMenu.addItem(.separator())
        if b.prefs.splitView {
            let splitTitle = (b.activeSplit == nil || b.pickedSplit != nil) ? "Split Current Page" : "Separate Split Tabs"
            add(to: tabsMenu, splitTitle, shortcut: "tabs.split",
                enabled: b.active != nil && b.active?.bench != true) { b.splitKey() }
            if b.activeSplit != nil {
                add(to: tabsMenu, "Add Page to Split View", enabled: b.canAddPane) { b.addPaneToSplit() }
            }
            add(to: tabsMenu, "Focus Left Page", shortcut: "tabs.focusLeftPane", enabled: b.activeSplit != nil) {
                b.focusPane(onLeft: true)
            }
            add(to: tabsMenu, "Focus Right Page", shortcut: "tabs.focusRightPane", enabled: b.activeSplit != nil) {
                b.focusPane(onLeft: false)
            }
            add(to: tabsMenu, "Swap Pages", shortcut: "tabs.swapSplit", enabled: b.activeSplit != nil) {
                b.swapSplit()
            }
            if b.activeSplit == nil || b.pickedSplit != nil {
                add(to: tabsMenu, "Separate Split Tabs", shortcut: "tabs.separateSplit", enabled: b.activeSplit != nil) {
                    if let tab = b.active { b.detachSplit(tab) }
                }
            }
            let closeSplitTitle = (b.activeSplit?.tabs.count ?? 2) > 2 ? "Close All Pages" : "Close Both Pages"
            add(to: tabsMenu, closeSplitTitle, enabled: b.activeSplit != nil) { b.closeSplit() }
            tabsMenu.addItem(.separator())
        }
        if let tab = b.active {
            let rows = b.prefs.showsPinRows
            if tab.pin == nil {
                add(to: tabsMenu, "Pin Tab", shortcut: "tabs.pin", enabled: tab.isWeb && !tab.shy) { b.pin(tab) }
                if rows {
                    add(to: tabsMenu, "Pin Tab as Row", shortcut: "tabs.pinRow", enabled: tab.isWeb && !tab.shy) {
                        b.pin(tab, listed: true)
                    }
                }
            } else {
                if rows {
                    add(to: tabsMenu, tab.listed ? "Show Pin as Square" : "Show Pin as Row") {
                        b.setListed(tab, !tab.listed)
                    }
                }
                if !(rows && tab.listed) {
                    add(to: tabsMenu, "Change Letter") { b.editLetter(tab) }
                }
                add(to: tabsMenu, "Unpin Tab", shortcut: rows && tab.listed ? "tabs.pinRow" : "tabs.pin") {
                    b.unpin(tab)
                }
            }
        }
        add(to: tabsMenu, "Rename Tab", shortcut: "tabs.rename", enabled: b.active != nil) {
            if let tab = b.active { b.beginTabRename(tab) }
        }
        add(to: tabsMenu, "Duplicate Tab", shortcut: "tabs.duplicate", enabled: isWeb) { b.duplicate() }
        if b.prefs.littleLinks {
            add(to: tabsMenu, "Open in Small Window", enabled: b.active.map(b.liftable) ?? false) {
                if let tab = b.active { b.openInLittleWindow(tab) }
            }
        }
        add(to: tabsMenu, "Copy Address", shortcut: "tabs.copyAddress", enabled: isWeb) { b.copyAddress() }
        add(to: tabsMenu, "Copy as Markdown Link", shortcut: "tabs.copyMarkdown", enabled: isWeb) { b.copyMarkdownLink() }
        add(to: tabsMenu, "Paste and Go", shortcut: "tabs.pasteAndGo") { b.pasteAndGo() }
        tabsMenu.addItem(.separator())
        add(to: tabsMenu, "Close Other Tabs", shortcut: "tabs.closeOthers", enabled: b.tabs.count >= 2) {
            if let tab = b.active { b.closeOthers(but: tab) }
        }
        add(to: tabsMenu, "Stop Sound in Tab", shortcut: "tabs.mute") { b.pauseMedia() }
    }

    // MARK: - Bookmarks

    private func buildBookmarksMenu() {
        let b = browser
        let isWeb = b.active?.isWeb ?? false
        reset(bookmarksMenu)
        add(to: bookmarksMenu, b.pageKept ? "Edit Bookmark\u{2026}" : "Add This Page",
            shortcut: "bookmarks.add", enabled: isWeb) { b.bookmarkCurrent() }
        add(to: bookmarksMenu, "Show Bookmarks…", shortcut: "bookmarks.show") { b.bookmarking = true }
        add(to: bookmarksMenu, "Show Bookmarks Bar", shortcut: "bookmarks.bar",
            state: b.prefs.bookmarksBar ? .on : .off) {
            withAnimation(Motion.glide) { b.prefs.bookmarksBar.toggle() }
        }
        BookmarkMenu.shared.fill(bookmarksMenu)
    }

    // MARK: - History

    private func buildHistoryMenu() {
        let b = browser
        reset(historyMenu)
        let recent = b.recentlyVisited
        if !recent.isEmpty {
            historyMenu.addItem(.sectionHeader(title: "Recently Visited"))
            for trace in recent {
                let title = trace.title.isEmpty ? Address.withoutWWW(trace.address) : trace.title
                add(to: historyMenu, title, image: MainMenu.smallIcon(for: trace.url)) {
                    b.open(trace.url, foreground: true)
                }
            }
        }
        if !b.ghosts.isEmpty {
            historyMenu.addItem(.sectionHeader(title: "Recently Closed"))
            for ghost in b.recentlyClosed.prefix(10) {
                add(to: historyMenu, b.closedTitle(for: ghost), image: MainMenu.smallIcon(for: ghost.url)) {
                    b.reopen(ghost)
                }
            }
        }
        historyMenu.addItem(.separator())
        add(to: historyMenu, "Show History…", shortcut: "history.show") { b.recalling = true }
        add(to: historyMenu, "Downloads…", shortcut: "history.downloads") { b.showDownloads() }
        if b.prefs.tabLife != .never {
            add(to: historyMenu, "Archived Tabs…", shortcut: "history.archive") { b.archiving = true }
        }
        historyMenu.addItem(.separator())
        add(to: historyMenu, "Clear Browsing Data…", shortcut: "history.clearData") { b.clearBrowsingData() }
        add(to: historyMenu, "Clear History", shortcut: "history.clear") { b.clearHistory() }
    }

    private static func smallIcon(for url: URL) -> NSImage? {
        guard let icon = Favicons.shared.cached(for: url) else { return nil }
        let copy = icon.copy() as? NSImage ?? icon
        copy.size = NSSize(width: 16, height: 16)
        return copy
    }

    // MARK: - Window & Help

    private func buildWindowMenu() {
        addResponder(to: windowMenu, "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), key: "m")
        addResponder(to: windowMenu, "Zoom", action: #selector(NSWindow.performZoom(_:)))
        windowMenu.addItem(.separator())
        add(to: windowMenu, "Search") { Browsers.ensureWindow() }
        windowMenu.addItem(.separator())
        addResponder(to: windowMenu, "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), target: NSApp)
    }

    private func updateWindowMenu() {
        // Keep system-managed window entries intact.
    }

    private func buildHelpMenu() {
        reset(helpMenu)
        add(to: helpMenu, "Send Feedback…") { Links.writeFeedback() }
    }
}
