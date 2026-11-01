import AppKit
import SwiftUI
import WebKit
import Combine

// The buttons in the row: what WebKit says each extension's action is.
extension Extensions {
    struct Button: Identifiable {
        let id: String
        let name: String
        let label: String
        let icon: NSImage?
        let badge: String
        let enabled: Bool
        let pinned: Bool
    }

    /// Where a popup hangs when its extension isn't pinned: the puzzle button.
    static let menuAnchor = "__menu"

    /// One per loaded extension that has something to press, in install order.
    var buttons: [Button] {
        _ = actionsChanged
        return installed.compactMap { item in
            guard let context = contexts[item.id], let action = context.action(for: activeAdapter(for: context)) else { return nil }
            return Button(
                id: item.id,
                name: item.name,
                label: action.label.isEmpty ? item.name : action.label,
                icon: action.icon(for: CGSize(width: 16, height: 16)),
                badge: action.badgeText,
                enabled: action.isEnabled,
                pinned: item.pinned ?? false
            )
        }
    }

    /// When you last clicked each extension's button or its line in the
    /// menu: a permissions.request made from that click is one you asked
    /// for, even once WebKit no longer sees the click (see
    /// ExtensionShims, "permissions.afterClick").
    static var clicked: [String: Date] = [:]

    /// The same, kept: permissions.request uses up `clicked`, and a
    /// recording started from the button counts it for a minute (see
    /// ExtensionCapture).
    static var pressed: [String: Date] = [:]

    /// When you last clicked or typed in one of each extension's own pages —
    /// its popup, or a page of its in a tab. Real events only: a page's
    /// script can dispatch one, but it never reaches here.
    static var touched: [String: Date] = [:]

    /// Whether a view with these scripts is one of any profile's extension pages.
    static func isPages(_ scripts: WKUserContentController) -> Bool {
        made.values.contains { $0.pages === scripts }
    }

    private static var touching: Any?

    static func watchTouches() {
        guard touching == nil else { return }
        touching = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .keyDown]) { event in
            var view: NSView? = event.type == .keyDown
                ? event.window?.firstResponder as? NSView
                : event.window?.contentView?.superview?.hitTest(event.locationInWindow)
            while let found = view, !(found is WKWebView) { view = found.superview }
            if let url = (view as? WKWebView)?.url, url.scheme?.lowercased() == Extensions.scheme, let id = url.host() {
                Extensions.touched[id] = Date()
            }
            return event
        }
    }

    /// You just did something in this extension — its button, its menu
    /// line, a click or a key in one of its pages — as Chrome's "user
    /// gesture" means: within the last few seconds.
    static func justUsed(_ id: String) -> Bool {
        let latest = [clicked[id], touched[id]].compactMap { $0 }.max()
        return latest.map { Date().timeIntervalSince($0) < 5 } ?? false
    }

    func press(_ id: String) {
        guard let context = contexts[id], !ExtensionPopup.shared.closes(id) else { return }
        Extensions.clicked[id] = Date()
        Extensions.pressed[id] = Date()
        let tab = activeAdapter(for: context)
        if let tab { context.userGesturePerformed(in: tab) }
        // An extension that asked for its button to open its side panel.
        if ExtensionShims.panelOnClick.contains(id), context.action(for: tab)?.presentsPopup != true {
            ExtensionShims.openPanel(context, owner: self)
            return
        }
        // A popup is opened here, straight away. Left to WebKit, it builds
        // a popup of its own first, and closing that one in favour of
        // Shy's lost the new popup's first messages to its worker.
        if context.action(for: tab)?.presentsPopup == true, let url = popupURL(for: context) {
            ExtensionPopup.shared.show(url, for: context, from: anchor(for: id))
            return
        }
        context.performAction(for: tab)
    }

    /// What an extension's popup hangs from: its own button in the row,
    /// else the puzzle button — whichever is in the window now.
    func anchor(for id: String) -> NSView? {
        let own = anchors[id]?.view
        return own?.window != nil ? own : anchors[Extensions.menuAnchor]?.view
    }

    /// The page the button's popup is now: one the extension set for this
    /// tab or for all of them, else its manifest's.
    private func popupURL(for context: WKWebExtensionContext) -> URL? {
        let set = ExtensionShims.popups[context.uniqueIdentifier] ?? [:]
        let path = activeAdapter(for: context)?.tab.flatMap { set[$0.id.uuidString] } ?? set["*"]
        guard let path else { return Extensions.popupURL(for: context) }
        guard !path.isEmpty else { return nil }
        // Its own pages only: action.setPopup is handed any string, and a
        // site or a file shown in the popup would wear the extension's chrome.
        return ExtensionShims.page(path, in: context)
    }

    /// Chrome's versions, one to four dotted numbers: an update only ever
    /// goes up, so a reply naming an older (signed, but perhaps vulnerable)
    /// version never rolls an extension back.
    static func newer(_ offered: String, than current: String) -> Bool {
        func parts(_ v: String) -> [Int]? {
            let p = v.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
            guard !p.isEmpty, p.count <= 4, p.allSatisfy({ ($0 ?? -1) >= 0 }) else { return nil }
            return p.map { $0! } + Array(repeating: 0, count: 4 - p.count)
        }
        guard let a = parts(offered) else { return false }
        guard let b = parts(current) else { return offered != current }
        return a.lexicographicallyPrecedes(b) == false && a != b
    }

    /// A keystroke an extension registered for.
    func take(_ event: NSEvent) -> Bool {
        for context in contexts.values where context.command(for: event) != nil {
            return context.performCommand(for: event)
        }
        return false
    }
}
