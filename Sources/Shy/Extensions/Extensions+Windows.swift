import AppKit
import SwiftUI
import WebKit
import Combine

// The windows and tabs, as WebKit sees them, followed as they change.
extension Extensions {
    func adapter(for tab: Tab) -> ExtensionTab {
        if let known = adapters[tab.id] { return known }
        let made = ExtensionTab(tab: tab, owner: self)
        adapters[tab.id] = made
        return made
    }

    /// Private tabs keep nothing and show nothing to an extension you haven't
    /// let in (Settings › Extensions). Even to one you have, only the ones
    /// made since some extension was let in carry the controller; one made
    /// before has no page an extension could reach.
    /// Only tabs carrying this profile's controller: another profile's
    /// tabs, and a private one made before any extension was let in, are
    /// never told to it.
    private func seen(_ tab: Tab) -> Bool { tab.extensionController === controller }

    func seen(_ tab: Tab, for context: WKWebExtensionContext) -> Bool {
        seen(tab) && (!tab.shy || context.hasAccessToPrivateData)
    }

    /// A window's tabs as this extension sees them. WebKit's indices and the
    /// shim's places both count in this list.
    func visibleTabs(of browser: Browser, for context: WKWebExtensionContext) -> [Tab] {
        browser.tabs.filter { seen($0, for: context) }
    }

    /// The first window's: what a bare tab index means.
    func visibleTabs(for context: WKWebExtensionContext) -> [Tab] {
        Browsers.primary.map { visibleTabs(of: $0, for: context) } ?? []
    }

    /// Each extension's view of a row, from what WebKit has told it: a move's
    /// old index counts only the tabs that extension knew of.
    private func visibleOrders(_ order: [Tab.ID]) -> [String: [Tab.ID]] {
        contexts.mapValues { context in
            let open = context.openTabs
            return order.filter { id in adapters[id].map { open.contains($0) } ?? false }
        }
    }

    /// The tab at `index` of the window an extension sees with this frame —
    /// `left, top, width, height` from windows.getAll(), whose order is
    /// WebKit's (the window in front first), not Browsers.all's. WebKit
    /// turns the window's frame over from the bottom of the first screen;
    /// it is turned back here, give or take two points.
    func tab(windowFrame frame: CGRect, index: Int, for context: WKWebExtensionContext) -> Tab? {
        let height = NSScreen.screens.first?.frame.height ?? 0
        let match = Browsers.all.filter { browser in
            guard let window = browser.window?.frame else { return false }
            return abs(window.minX - frame.minX) <= 2 && abs((height - window.maxY) - frame.minY) <= 2
                && abs(window.width - frame.width) <= 2 && abs(window.height - frame.height) <= 2
        }
        guard match.count == 1, let browser = match.first else { return nil }
        let tabs = visibleTabs(of: browser, for: context)
        return tabs.indices.contains(index) ? tabs[index] : nil
    }

    /// The window a tab is in, when it is in one's row.
    func browser(of tab: Tab) -> Browser? {
        Browsers.all.first { $0.tabs.contains { $0.id == tab.id } }
    }

    func activeAdapter(for context: WKWebExtensionContext) -> ExtensionTab? {
        browser.flatMap { activeAdapter(of: $0, for: context) }
    }

    /// The tab in front of a window, as an extension may see it. A private
    /// one it may not see: the window's last one it may, as Chrome answers,
    /// rather than none — with none, WebKit dropped the whole window, and
    /// tabs.query({}) came back empty (found by Security).
    func activeAdapter(of browser: Browser, for context: WKWebExtensionContext) -> ExtensionTab? {
        if let tab = browser.active, seen(tab, for: context) { return adapter(for: tab) }
        let last = visibleTabs(of: browser, for: context).max { $0.touched < $1.touched }
        return last.map(adapter(for:))
    }

    /// A window's browser, told to WebKit and followed: its row and its
    /// tab in front.
    func attach(_ browser: Browser) {
        let key = ObjectIdentifier(browser)
        guard following[key] == nil else { return }
        controller.didOpenWindow(window(of: browser))
        following[key] = [
            browser.$tabs
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak browser] tabs in
                    guard let self, let browser else { return }
                    follow(tabs, in: browser)
                },
            browser.$activeID
                .removeDuplicates()
                .scan((nil, nil)) { ($0.1, $1) }
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak browser] pair in
                    guard let self, let browser else { return }
                    activated(from: pair.0, to: pair.1, in: browser)
                },
        ]
    }

    /// Its window closed for good: its tabs, then the window, gone for WebKit.
    func detach(_ browser: Browser) {
        let key = ObjectIdentifier(browser)
        guard following.removeValue(forKey: key) != nil else { return }
        for id in orders.removeValue(forKey: key) ?? [] {
            if let adapter = adapters[id] {
                for context in contexts.values where context.openTabs.contains(adapter) {
                    context.didCloseTab(adapter, windowIsClosing: true)
                }
            }
            adapters[id] = nil
            watching[id] = nil
        }
        if let window = windows.removeValue(forKey: key) { controller.didCloseWindow(window) }
    }

    /// A window came to the front (windows.onFocusChanged).
    func focused(_ browser: Browser) {
        guard following[ObjectIdentifier(browser)] != nil else { return }
        controller.didFocusWindow(window(of: browser))
    }

    private func follow(_ tabs: [Tab], in browser: Browser) {
        let key = ObjectIdentifier(browser)
        let order = orders[key] ?? []
        let oldOrders = visibleOrders(order)
        let now = tabs.filter(seen)
        let ids = now.map(\.id)
        let gone = order.filter { !ids.contains($0) }
        for id in gone {
            // Moved to another window rather than closed: that window says
            // so when it takes it (see below).
            if Browsers.all.contains(where: { $0 !== browser && $0.tabs.contains { $0.id == id } }) {
                inTransit[id] = (key, oldOrders)
                continue
            }
            if let adapter = adapters[id] {
                for context in contexts.values where context.openTabs.contains(adapter) {
                    context.didCloseTab(adapter, windowIsClosing: false)
                }
            }
            adapters[id] = nil
            watching[id] = nil
        }
        for tab in now where !order.contains(tab.id) {
            let from = inTransit.removeValue(forKey: tab.id)
                ?? orders.first(where: { $0.key != key && $0.value.contains(tab.id) })
                    .map { ($0.key, visibleOrders($0.value)) }
            if let from, let other = windows[from.0] {
                // From another window: a move between windows, as WebKit has it.
                for context in contexts.values where seen(tab, for: context) {
                    if let index = from.1[context.uniqueIdentifier]?.firstIndex(of: tab.id) {
                        context.didMoveTab(adapter(for: tab), from: index, in: other)
                    }
                }
                orders[from.0]?.removeAll { $0 == tab.id }
                continue
            }
            for context in contexts.values where seen(tab, for: context) {
                context.didOpenTab(adapter(for: tab))
            }
            watch(tab)
        }
        // Moves: anything whose position changed among the ones that stayed,
        // in each extension's own count.
        let present = Set(ids)
        for context in contexts.values {
            let oldOrder = oldOrders[context.uniqueIdentifier] ?? []
            let stayed = oldOrder.filter(present.contains)
            let current = visibleTabs(of: browser, for: context).map(\.id)
            let kept = Set(stayed)
            for (id, now) in zip(stayed, current.filter(kept.contains)) where id != now {
                if let adapter = adapters[id], let oldIndex = oldOrder.firstIndex(of: id), current.firstIndex(of: id) != oldIndex {
                    context.didMoveTab(adapter, from: oldIndex, in: window(of: browser))
                }
            }
        }
        orders[key] = ids
    }

    private func watch(_ tab: Tab) {
        let id = tab.id
        func changed(_ properties: WKWebExtension.TabChangedProperties) {
            guard let adapter = adapters[id] else { return }
            for context in contexts.values where seen(tab, for: context) {
                context.didChangeTabProperties(properties, for: adapter)
            }
        }
        watching[id] = [
            tab.$title.dropFirst().removeDuplicates().sink { _ in changed(.title) },
            tab.$address.dropFirst().removeDuplicates().sink { _ in changed(.URL) },
            tab.$loading.dropFirst().removeDuplicates().sink { _ in changed(.loading) },
            tab.$pin.dropFirst().map { $0 != nil }.removeDuplicates().sink { _ in changed(.pinned) },
        ]
    }

    private func activated(from old: Tab.ID?, to new: Tab.ID?, in browser: Browser) {
        guard let new, let tab = browser.tabs.first(where: { $0.id == new }), seen(tab) else { return }
        let previous = old.flatMap { id in browser.tabs.first(where: { $0.id == id }) }
        for context in contexts.values where seen(tab, for: context) {
            let visiblePrevious = previous.flatMap { seen($0, for: context) ? adapter(for: $0) : nil }
            context.didActivateTab(adapter(for: tab), previousActiveTab: visiblePrevious)
        }
        actionsChanged += 1
    }
}
