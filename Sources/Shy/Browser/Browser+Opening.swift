import SwiftUI
import WebKit
import Combine

extension Browser {
    /// A link from another app. A blank tab with nothing typed in it takes
    /// the page rather than staying behind as an empty one; otherwise the
    /// page gets a tab of its own, in front.
    func arrive(_ url: URL) {
        if let active, active.isBlank, typed.isEmpty {
            active.go(to: url)
            editing = false
        } else {
            open(url, foreground: true)
        }
    }

    /// A bookmark, or a page from a list of them: into the tab you are on,
    /// the way every bookmarks bar has ever worked — into a new one with ⌘
    /// held.
    func visit(_ url: URL) {
        let apart = NSApp.currentEvent?.modifierFlags.contains(.command) ?? false
        if let active, !apart {
            active.go(to: url)
            editing = false
            typed = ""
        } else {
            open(url, foreground: true, from: active)
        }
    }

    /// A bookmark, from the bar, the Bookmarks menu or a list of them: in a
    /// tab of its own, never in place of the one you are on (Drice: opened
    /// from a pin, it took the pin's place). An empty new tab is the one
    /// exception, since nothing is lost by using it. With ⌘ it opens behind.
    func openBookmark(_ url: URL) {
        let behind = NSApp.currentEvent?.modifierFlags.contains(.command) ?? false
        if !behind, let active, active.isBlank || active.page?.kind == .bookmarks, active.pin == nil {
            active.go(to: url)
            editing = false
            typed = ""
        } else {
            open(url, foreground: !behind, from: active, mayWait: behind)
        }
    }

    /// A bookmark picked from the button's list or the full one. Either
    /// goes as the page starts: the list off the button used to stay open
    /// over the page it had just sent you to. A middle-click opens it in a
    /// new tab behind this one and leaves the list open for the next; with
    /// ⇧ it goes to the new tab, and the list closes.
    func pickBookmark(_ url: URL, inNewTab: Bool = false) {
        let foreground = !inNewTab || NSApp.currentEvent?.modifierFlags.contains(.shift) == true
        if foreground {
            // From the Bookmarks tab, the bookmark opens in it, as Chrome's
            // manager does; Back comes back to the list.
            bookmarksOpen = false
        }
        if inNewTab {
            open(url, foreground: foreground, from: active, mayWait: true)
        } else {
            openBookmark(url)
        }
    }

    /// A page in a new tab, paired with the one on screen as a tab's Open in
    /// Split View pairs it. Used, for one, by the bookmarks bar's Open in
    /// Split View.
    func openInSplit(_ url: URL) {
        openInSplit(open(url, foreground: false, from: active))
    }

    /// ⌘⇧N. A tab that keeps nothing — its own cookies, its own sign-ins, no
    /// history, and no place in tomorrow's session.
    func newShyTab() {
        if watchingAgent != nil { watchAgent(nil) }
        if websitePopup { tabDestination.newShyTab(); return }
        // Never two empty private tabs, as ⌘T never makes two empty ones:
        // one already open is moved to the chosen position.
        if let blank = tabs.last(where: { $0.isBlank && $0.shy && !$0.bench && split(for: $0) == nil }) {
            placeBlank(blank)
            if activeID != blank.id { leaving() }
            activeID = blank.id
            summoning = false
            typed = ""
            blank.draft = ""
            editing = false
            focusRequest += 1
            return
        }
        let tab = Tab(shy: true)
        prepare(tab)
        tabs.insert(tab, at: placeForFront())
        leaving()
        activeID = tab.id
        summoning = false
        typed = ""
        editing = false
        focusRequest += 1
        announce("A tab that keeps nothing")
    }

    /// ⌘D. The same page, beside itself.
    func duplicate() {
        guard let url = active?.address else { return }
        open(url, foreground: true, from: active)
    }

    /// ⌘⇧V, when nothing is being typed. What is in the clipboard, if it is a
    /// place — or a search — in the tab you're on.
    func pasteAndGo() {
        guard let text = NSPasteboard.general.string(forType: .string),
              let url = destination(for: text.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            refusals += 1
            return
        }
        (active ?? tabs.first)?.go(to: url)
        editing = false
        typed = ""
    }

    /// File › Export as PDF…. Unlike Print, this keeps the page's screen
    /// layout and takes its whole current length. WebKit splits only a page
    /// taller than a PDF page can be (200 inches).
    func exportPDF() {
        guard let tab = active, tab.isWeb, let window = tab.web.window ?? self.window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        let title = tab.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let stem = (title.isEmpty ? tab.pageAddress?.host() ?? "Page" : title)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = stem.lowercased().hasSuffix(".pdf") ? stem : stem + ".pdf"
        panel.directoryURL = downloadsFolder
        panel.beginSheetModal(for: window) { [weak self] answer in
            guard answer == .OK, let file = panel.url else { return }
            self?.exportPDF(tab, to: file)
        }
    }

    /// Keep the tab the save panel was opened for, even if another is active
    /// when it finishes. The bench passes the current tab without a panel.
    func exportPDF(_ tab: Tab, to file: URL, finished: ((Bool) -> Void)? = nil) {
        guard tab.isWeb else {
            finished?(false)
            return
        }
        tab.web.createPDF(configuration: WKPDFConfiguration()) { [weak self] result in
            do {
                let data = try result.get()
                try data.write(to: file, options: .atomic)
                self?.announce("Saved \(file.lastPathComponent)", file: file)
                finished?(true)
            } catch {
                self?.announce("Couldn't export page")
                finished?(false)
            }
        }
    }

    /// ⌘P. The system's print sheet, where a paginated PDF can also be saved.
    func printPage() {
        guard let tab = active, tab.isWeb, let window = NSApp.keyWindow else { return }
        Browser.printing(tab.web).runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    /// The print job for a page, or for one frame of it when WebKit names
    /// one: a page's own print() in a frame prints that frame, as in Safari.
    /// The frame's printing is outside the public framework, so it is asked
    /// for first, and a WebKit without it prints the whole page.
    static func printing(_ web: WKWebView, frame: AnyObject? = nil) -> NSPrintOperation {
        let info = NSPrintInfo.shared
        info.horizontalPagination = .fit
        info.isHorizontallyCentered = false
        let forFrame = NSSelectorFromString("_printOperationWithPrintInfo:forFrame:")
        let job: NSPrintOperation
        if let frame, web.responds(to: forFrame) {
            typealias Make = @convention(c) (AnyObject, Selector, NSPrintInfo, AnyObject) -> NSPrintOperation
            job = unsafeBitCast(web.method(for: forFrame), to: Make.self)(web, forFrame, info, frame)
        } else {
            job = web.printOperation(with: info)
        }
        job.view?.frame = web.bounds
        return job
    }
}

// Opening an address: in a tab, beside one, in a split, as a PDF or on paper.
extension Browser {
    /// A link opened from a page lands next to the page it came from, not at
    /// the far end of the row — unless it is one of a batch, which keeps the
    /// order it came in.
    ///
    /// `from`: the tab it was opened out of. A private one's opens private,
    /// in the same store, as a link that asks for a new window already does.
    ///
    /// `mayWait`: opened behind the page by hand, or one of a batch of links
    /// from another app. With Settings › Tabs › Load background tabs when
    /// you go to them, such a tab keeps its address and loads nothing until
    /// it is gone to, as a tab brought back from the last session does. A
    /// tab in front always loads, and so does one an extension opens, which
    /// may be waiting on its page.
    @discardableResult
    func open(_ url: URL, foreground: Bool, atEnd: Bool = false, from source: Tab? = nil, mayWait: Bool = false) -> Tab {
        if websitePopup {
            return tabDestination.open(url, foreground: foreground, atEnd: atEnd, from: source ?? active, mayWait: mayWait)
        }
        // One of Shy's own pages, from a link, a script or another app:
        // its own tab, one of each (see InternalPages.swift).
        if let own = InternalPage(url: url) { return show(own) }
        // An extension's own page is served only to a view built from that
        // extension's configuration.
        let url = Browser.page(url)
        let page = Browser.extensionConfiguration(for: url)
        // A new tab is in this window's space, with its sign-ins — not the
        // space of whichever window is in front, when this one is behind it.
        let tab = if let source, source.shy, page == nil {
            Tab(shy: true, configuration: Web.configuration(shy: true, store: source.store))
        } else {
            Tab(configuration: page ?? Web.configuration(space: spaceID))
        }
        prepare(tab)
        tabs.insert(tab, at: atEnd ? tabs.count : placeForNew())
        if mayWait, !foreground, prefs.lazyTabs, page == nil {
            tab.restore(url: url, title: "")
        } else {
            tab.go(to: url)
        }
        if foreground {
            leaving()
            activeID = tab.id
            editing = false
            typed = ""
        }
        return tab
    }

    /// An extension's page sending its own tab to a website — 1Password's
    /// "Sign in" does, when its Mac app isn't connected. The page's view was
    /// built from the extension's configuration, which WebKit keeps to that
    /// extension's own pages, so the load went nowhere and the button did
    /// nothing. The tab is swapped where it stands for an ordinary one on
    /// the site: to the eye, the page went there. The other way round too:
    /// an extension sending a website's tab to one of its own pages.
    func replace(_ tab: Tab, going url: URL) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        // A private tab stays private, and keeps its own sign-ins when it
        // had them; an extension's page it showed was in that extension's
        // store, so going back to the web takes a new private one.
        let page = Browser.extensionConfiguration(for: url)
        let fresh = if tab.shy {
            Tab(shy: true, bench: tab.bench, configuration: page
                ?? Web.configuration(shy: true, store: tab.store.isPersistent ? nil : tab.store))
        } else {
            Tab(bench: tab.bench, configuration: page ?? Web.configuration(space: spaceID))
        }
        // Preserve the sign-in popup's link to the page that opened it —
        // and, since a website can now start the swap, what you made of the
        // tab: a pinned one stays pinned, a named one keeps its name.
        fresh.opener = tab.opener
        fresh.popup = tab.popup
        fresh.pin = tab.pin
        fresh.listed = tab.listed
        fresh.folder = tab.folder
        fresh.name = tab.name
        prepare(fresh)
        let wasActive = activeID == tab.id
        replaceSplitMember(tab.id, with: fresh.id)
        tabs[index] = fresh
        fresh.go(to: url)
        if wasActive { activeID = fresh.id }
        tab.close()
        rememberSession()
    }

    /// An address from before extensions moved to chrome-extension://, as
    /// it is now; any other, as it is.
    static func page(_ url: URL) -> URL {
        if #available(macOS 15.4, *) { return Extensions.current(url) }
        return url
    }

    /// The extension an address belongs to, or nil for the web.
    static func extensionHost(of url: URL) -> String? {
        guard #available(macOS 15.4, *) else { return nil }
        let url = Extensions.current(url)
        return url.scheme == Extensions.scheme ? url.host : nil
    }

    /// The configuration for an extension's page, or nil for anything else.
    static func extensionConfiguration(for url: URL) -> WKWebViewConfiguration? {
        guard #available(macOS 15.4, *) else { return nil }
        let url = Extensions.current(url)
        guard url.scheme == Extensions.scheme else { return nil }
        return Extensions.shared.controller.extensionContext(for: url)?.webViewConfiguration
    }
}

#if DEBUG
extension Browser {
    /// A page for the bench: at the end of the row, behind whatever you are
    /// looking at, and marked as not yours. `shy`: a private one, for a test run.
    @discardableResult
    func benchOpen(_ url: URL, shy: Bool = false) -> Tab {
        let url = Browser.page(url)
        let tab = Tab(shy: shy, bench: true, configuration: shy ? nil : Browser.extensionConfiguration(for: url))
        prepare(tab)
        tabs.append(tab)
        tab.go(to: url)
        return tab
    }
}
#endif
