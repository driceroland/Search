import AppKit
import SwiftUI

/// The bookmarks in the menu bar's Bookmarks menu, made by AppKit rather
/// than SwiftUI. SwiftUI makes a menu bar's items all at once, folders
/// and all, before the app has finished launching: 1,500 bookmarks, as a
/// Chrome import brings, held the window back by 230 ms at every launch.
/// Here the top of the list is made as the menu opens, and a folder's
/// items as that folder opens.
///
/// SwiftUI keeps its own two items, and its own delegate, which lays the
/// menu out afresh each time it opens — anything added beside them was
/// gone by then. So its delegate is wrapped: SwiftUI does its update,
/// then the bookmarks go in after it. SwiftUI puts its delegate back on
/// every update, so the wrapping is put back too (see `start`).
@MainActor
final class BookmarkMenu: NSObject, NSMenuDelegate {
    static let shared = BookmarkMenu()

    private weak var browser: Browser?
    private var watch: [Any] = []
    private let relay = Relay()
    /// What each folder's submenu holds, until it opens.
    private var folders: [ObjectIdentifier: [Bookmark]] = [:]
    /// The items put in here, among SwiftUI's own.
    fileprivate static let mark = 0x5EAC

    func start(for browser: Browser) {
        guard self.browser == nil else { return }
        self.browser = browser
        relay.after = { [weak self] menu in self?.fill(menu) }
        // SwiftUI puts its own delegate back whenever it updates the menu
        // bar, which is whenever anything in the window changes. So: after
        // each event, and as the menu bar starts to be used, before any of
        // its menus opens.
        let centre = NotificationCenter.default
        watch = [
            centre.addObserver(forName: NSApplication.didUpdateNotification, object: nil, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.wrap() }
            },
            centre.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { [weak self] note in
                MainActor.assumeIsolated {
                    guard (note.object as? NSMenu) === NSApp.mainMenu else { return }
                    self?.wrap()
                }
            },
            // However the menu bar is let go of, even if SwiftUI's delegate
            // got the menu's own close instead.
            centre.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: nil) { [weak self] note in
                MainActor.assumeIsolated {
                    guard (note.object as? NSMenu) === NSApp.mainMenu else { return }
                    self?.closed()
                }
            },
        ]
        wrap()
    }

    private var menu: NSMenu? { NSApp.mainMenu?.items.first(where: { $0.title == "Bookmarks" })?.submenu }

    /// Looks, while the menu is open, after each turn of the run loop.
    private var looking: CFRunLoopObserver?

    /// An open menu is updated by SwiftUI itself, straight through its own
    /// delegate, whenever anything it shows could have changed — a tab's
    /// title, every second on a download page — and that took the bookmarks
    /// out from under the pointer. While it is open, they go back in as soon
    /// as a turn of the run loop finds them gone.
    fileprivate func opened(_ menu: NSMenu) {
        guard looking == nil else { return }
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 0) { [weak self, weak menu] _, _ in
            MainActor.assumeIsolated {
                guard let self, let menu, !menu.items.contains(where: { $0.tag == Self.mark }) else { return }
                self.fill(menu)
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        looking = observer
    }

    fileprivate func closed() {
        guard let looking else { return }
        CFRunLoopObserverInvalidate(looking)
        self.looking = nil
    }

    private func wrap() {
        guard let menu, menu.delegate !== relay
        else { return }
        relay.inner = menu.delegate
        menu.delegate = relay
    }

    /// SwiftUI's own update of the menu, without ours after it: what it
    /// does by itself to a menu that is open. For the bench.
    func swiftUIUpdate() {
        guard let menu else { return }
        relay.inner?.menuNeedsUpdate?(menu)
    }

    /// How many items this has put in the menu, for the bench.
    var count: Int {
        menu?.items.filter { $0.tag == Self.mark }.count ?? 0
    }

    /// The top of the list, after SwiftUI's items, in place of any left
    /// from the last time.
    private func fill(_ menu: NSMenu) {
        for item in menu.items where item.tag == Self.mark { menu.removeItem(item) }
        folders = [:]
        guard let roots = browser?.bookmarks.roots, !roots.isEmpty else { return }
        let line = NSMenuItem.separator()
        line.tag = Self.mark
        menu.addItem(line)
        for item in items(for: roots) { menu.addItem(item) }
    }

    /// A folder of the bookmarks bar, opened as a menu at the pointer: the
    /// same items as the menu bar's, folders opening as they are reached.
    func popUp(_ folder: Bookmark) {
        let menu = NSMenu(title: folder.title)
        let made = items(for: folder.children ?? [])
        if made.isEmpty {
            let empty = NSMenuItem(title: "Empty", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for item in made { menu.addItem(item) }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private func items(for nodes: [Bookmark]) -> [NSMenuItem] {
        nodes.compactMap { node in
            let item: NSMenuItem
            if node.isFolder {
                item = NSMenuItem(title: node.title, action: nil, keyEquivalent: "")
                item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
                let sub = NSMenu(title: node.title)
                sub.delegate = self
                folders[ObjectIdentifier(sub)] = node.children ?? []
                item.submenu = sub
            } else if let text = node.url, let url = URL(string: text) {
                // One without a name reads as its address here.
                item = NSMenuItem(title: node.label, action: #selector(open(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = url
                // The site's icon, as the bar wears it: a folder opened from
                // the bar, or the Bookmarks menu, had none (idea 183). A site
                // whose icon isn't kept yet (brought in, never visited) wears
                // a plain globe in its place, rather than nothing and its
                // title out of line with the others'.
                if let icon = Favicons.of(browser?.profileID ?? Profile.personalID).cached(for: node.address) {
                    let small = icon.copy() as? NSImage ?? icon
                    small.size = NSSize(width: 16, height: 16)
                    item.image = small
                } else {
                    item.image = BookmarkMenu.globe
                }
            } else {
                return nil
            }
            item.tag = Self.mark
            return item
        }
    }

    /// Mark with no icon, for a menu: a globe, as the menu draws its own
    /// symbols, so it follows light and dark.
    private static var globe: NSImage? {
        let image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        image?.size = NSSize(width: 16, height: 16)
        return image
    }

    /// What a folder of the bar holds as its menu: every item, its folders
    /// opened as a click would, deepest last. For the bench.
    func walk(_ folder: Bookmark) -> [(depth: Int, item: NSMenuItem)] {
        func down(_ items: [NSMenuItem], _ depth: Int) -> [(depth: Int, item: NSMenuItem)] {
            items.flatMap { item -> [(depth: Int, item: NSMenuItem)] in
                guard let sub = item.submenu else { return [(depth, item)] }
                menuNeedsUpdate(sub)
                return [(depth, item)] + down(sub.items, depth + 1)
            }
        }
        return down(items(for: folder.children ?? []), 0)
    }

    /// A folder, opening.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let kids = folders[ObjectIdentifier(menu)] else { return }
        menu.removeAllItems()
        let made = items(for: kids)
        if made.isEmpty {
            let empty = NSMenuItem(title: "Empty", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for item in made { menu.addItem(item) }
    }

    @objc private func open(_ item: NSMenuItem) {
        guard let url = item.representedObject as? URL else { return }
        browser?.openBookmark(url)
    }

    /// SwiftUI's delegate, with the bookmarks put in after its update.
    /// Everything else it answers goes straight to it.
    private final class Relay: NSObject, NSMenuDelegate {
        weak var inner: NSMenuDelegate?
        var after: ((NSMenu) -> Void)?

        func menuNeedsUpdate(_ menu: NSMenu) {
            inner?.menuNeedsUpdate?(menu)
            MainActor.assumeIsolated { after?(menu) }
        }

        func menuWillOpen(_ menu: NSMenu) {
            inner?.menuWillOpen?(menu)
            MainActor.assumeIsolated { BookmarkMenu.shared.opened(menu) }
        }

        func menuDidClose(_ menu: NSMenu) {
            inner?.menuDidClose?(menu)
            MainActor.assumeIsolated { BookmarkMenu.shared.closed() }
        }

        /// Only for its own items: the bookmarks aren't SwiftUI's to know.
        func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
            guard item?.tag != BookmarkMenu.mark else { return }
            inner?.menu?(menu, willHighlight: item)
        }

        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || (inner?.responds(to: selector) ?? false)
        }

        override func forwardingTarget(for selector: Selector!) -> Any? { inner }
    }
}
