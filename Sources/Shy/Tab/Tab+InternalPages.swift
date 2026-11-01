import Combine
import ImageIO
import SwiftUI
import WebKit

// Shy's own pages, in a tab (see InternalPages.swift).
extension Tab {
    /// What the field shows for this tab, and what is copied.
    /// For a tab a page opened, the page that arrived, as `pageAddress`: its
    /// opener can stop the load it asked for and write into it, and the
    /// address it asked for must not stand over what it wrote.
    var shownURL: URL? { page?.url ?? (opener == nil ? address : pageAddress) }

    /// Go to one of Shy's own pages. `stepping`: whether the page it
    /// leaves is one Back comes back to — not for another section of the
    /// same page, which only moves the address.
    func show(_ next: InternalPage, stepping: Bool = true) {
        if let page, page != next, stepping, page.kind != next.kind {
            trail.append(page)
            ahead = []
        }
        // A web page in this tab is let go of: these pages have no web view
        // behind them, and a tab with both would have two things to go back to.
        if address != nil || built != nil {
            discard()
            address = nil
            committed = nil
            held = nil
            pending = nil
            memory = nil
            picture = nil
            cover = nil
            failure = nil
            loading = false
            progress = 0
            reader = false
            behind = nil
            trail = []
            ahead = []
        }
        draft = ""
        page = next
        title = next.title
        adoptIcon()
        steps()
    }

    /// Back and Forward as this tab has them now.
    func steps() {
        let back = page != nil ? !trail.isEmpty : (built?.canGoBack ?? false) || behind != nil
        let forward = page != nil ? !ahead.isEmpty : built?.canGoForward ?? false
        if canGoBack != back { canGoBack = back }
        if canGoForward != forward { canGoForward = forward }
    }

    /// The title if the page has offered one, the address until it does. A tab
    /// that says nothing at all for the first second of every load is a tab you
    /// can't find your way back to.
    var label: String {
        if let name, !name.isEmpty { return name }
        if let page { return page.title }
        if popup, let host = address?.host(), !host.isEmpty {
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        if !title.isEmpty { return title }
        if let address { return Address.pretty(address) }
        return "New Tab"
    }
}
