import AppKit

// AppleScript, read-only, in Safari's words (#232): a window's `tabs` and
// its `current tab`, and each tab's `URL` and `name`. Search.sdef says so,
// and build.sh puts it in the app. Nothing here changes anything, runs
// anything in a page, or opens or closes a tab.
//
// Only an app allowed in System Settings › Privacy & Security › Automation
// gets this far. Private tabs are never shown to it: they are left out of
// the list, and a window whose tab in front is private has no current tab
// (missing value).

/// A tab as a script sees it: where its page is and what it's called.
@MainActor
@objc(ScriptTab)
final class ScriptTab: NSObject {
    private let tab: Tab
    /// Its place among the tabs a script sees, private ones left out, which
    /// is what `tab N of window …` counts.
    private let index: Int
    private weak var window: NSWindow?

    init(_ tab: Tab, index: Int, in window: NSWindow) {
        self.tab = tab
        self.index = index
        self.window = window
    }

    /// The page that is on screen, not an address typed, loading or held.
    /// Never a name or password written into the address (user:password@).
    @objc var url: String {
        guard let page = tab.pageAddress else { return "" }
        guard var parts = URLComponents(url: page, resolvingAgainstBaseURL: false), parts.user != nil || parts.password != nil
        else { return page.absoluteString }
        parts.user = nil
        parts.password = nil
        return parts.url?.absoluteString ?? ""
    }
    /// That page's title. The tab's own is emptied as soon as a load starts;
    /// the page's stays until the next one has arrived, as the address does.
    @objc var name: String {
        if tab.committed != nil, let page = tab.built { return page.title ?? "" }
        return tab.title
    }

    override var objectSpecifier: NSScriptObjectSpecifier? {
        guard let window, let container = window.objectSpecifier,
              let description = container.keyClassDescription
        else { return nil }
        return NSIndexSpecifier(
            containerClassDescription: description,
            containerSpecifier: container, key: "scriptTabs", index: index
        )
    }
}

extension NSWindow {
    /// Its own browser's tabs, private ones left out. A window that isn't a
    /// browser's — Settings, a panel — has none.
    @MainActor @objc var scriptTabs: [ScriptTab] {
        Scripting.shown(in: self).enumerated().map { ScriptTab($0.element, index: $0.offset, in: self) }
    }

    /// The tab in front, unless it is private.
    @MainActor @objc var scriptCurrentTab: ScriptTab? {
        guard let active = Browsers.browser(for: self)?.active, !active.shy,
              let index = Scripting.shown(in: self).firstIndex(where: { $0 === active })
        else { return nil }
        return ScriptTab(active, index: index, in: self)
    }
}

@MainActor
enum Scripting {
    /// The tabs a script may see in a window: its browser's, without the
    /// private ones.
    static func shown(in window: NSWindow) -> [Tab] {
        Browsers.browser(for: window)?.tabs.filter { !$0.shy } ?? []
    }
}
