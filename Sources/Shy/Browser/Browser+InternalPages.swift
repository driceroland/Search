import SwiftUI
import WebKit
import Combine

// MARK: - Shy's own pages, in tabs (see InternalPages.swift)

extension Browser {
    /// The tab in this window's row showing that kind of page, if any.
    func pageTab(_ kind: InternalPage.Kind) -> Tab? {
        tabs.first { $0.page?.kind == kind }
    }

    /// ⌘, ⌘Y ⇧⌘J and the menus: the page's tab, brought forward if it is
    /// open, made otherwise. An empty tab in front becomes the page rather
    /// than being left behind it; a private one doesn't — these pages are
    /// never private, as Chrome's settings never open in an incognito
    /// window — and the page opens beside it.
    @discardableResult
    func show(_ page: InternalPage) -> Tab {
        // A pop-up window holds its one page: Shy's own open beside it.
        if websitePopup { return tabDestination.show(page) }
        if page.kind == .settings, let detail = page.detail, let section = SettingsPanel.Page(rawValue: detail) {
            settingsPage = section
        }
        // Settings is the card, not a tab, wherever it is asked for from.
        if page.kind == .settings, let active {
            tuning = true
            return active
        }
        if page.kind == .passwords { relist() }
        if page.kind == .history, pageTab(.history) == nil { recallMode = .history }
        let tab: Tab
        if let open = pageTab(page.kind) {
            tab = open
            // Asked for another section, or another browser to bring
            // things from: the open tab moves there, without a step back.
            if page.detail != nil, open.page != page {
                open.show(page, stepping: false)
                objectWillChange.send()
            }
        } else {
            if let blank = active, blank.isBlank, !blank.shy, !blank.bench, blank.pin == nil,
               blank.draft.isEmpty, typed.isEmpty {
                tab = blank
            } else {
                tab = Tab(configuration: Web.configuration(space: spaceID))
                prepare(tab)
                tabs.insert(tab, at: placeForNew())
            }
            tab.show(page)
        }
        if launching { dismiss() }
        summoning = false
        editing = false
        typed = ""
        if activeID != tab.id { select(tab) }
        writeSessionSoon()
        return tab
    }

    /// From one of these pages to another — Settings' "Passwords…", Bring
    /// Things Over's "Show bookmarks": the same tab goes there, and Back
    /// comes back, as a link would. Unless that page is already open in a
    /// tab of its own, which is then the one shown.
    func lead(to page: InternalPage) {
        guard page.kind != .settings, let here = active, here.page != nil, pageTab(page.kind) == nil else {
            show(page)
            return
        }
        if page.kind == .settings, let detail = page.detail, let section = SettingsPanel.Page(rawValue: detail) {
            settingsPage = section
        }
        here.show(page)
        writeSessionSoon()
    }

    /// The page's tab closed, as ⌘W would close it. For the bench, and the
    /// last few callers that put a panel away.
    func putAway(_ kind: InternalPage.Kind) {
        if kind == .settings { tuning = false }
        guard let tab = pageTab(kind) else { return }
        close(tab)
    }

    /// Settings moved to another of its sections: the tab's address says
    /// so, and comes back there after a relaunch.
    func settingsMoved(to section: SettingsPanel.Page) {
        guard let tab = pageTab(.settings), tab.page?.detail != section.rawValue else { return }
        tab.show(InternalPage(.settings, section.rawValue), stepping: false)
        writeSessionSoon()
    }
}
