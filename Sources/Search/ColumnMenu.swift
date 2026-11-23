import AppKit

/// A right-click on the column where there is no tab, pin or button of its
/// own to answer it — the space under the tabs, the gaps between groups,
/// the band at the top, the foot round its buttons — as Arc's sidebar
/// answers one: a new tab, a new folder, what is on the clipboard, and the
/// column's own settings. Right-clicks on a tab, a pin, a group or a
/// folder keep their own menus.
@MainActor
enum ColumnMenu {
    /// Where Paste and Go reads from: the Mac's clipboard, or on a test run
    /// a pasteboard of the bench's own (`columnmenu`).
    static var board: NSPasteboard = .general

    static func make(for browser: Browser) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, _ run: @escaping () -> Void) {
            let item = NSMenuItem(title: title, action: #selector(Do.go), keyEquivalent: "")
            let does = Do(run)
            item.target = does
            // The target is weak: the item keeps it.
            item.representedObject = does
            menu.addItem(item)
        }
        add("New Tab") { [weak browser] in browser?.launch() }
        if browser.prefs.showsPinFolders, !browser.websitePopup {
            add("New Folder") { [weak browser] in _ = browser?.newPinFolder() }
        }
        if let url = pasted(for: browser) {
            menu.addItem(.separator())
            add("Paste and Go") { [weak browser] in browser?.open(url, foreground: true) }
        }
        menu.addItem(.separator())
        add("Hide Sidebar") { [weak browser] in browser?.toggleFold() }
        add("Sidebar Settings…") { [weak browser] in
            browser?.settingsPage = .tabs
            browser?.tuning = true
        }
        return menu
    }

    /// An address on the clipboard, if that is what it holds: a link, or a
    /// name with a dot and no spaces. Words to search for are not offered.
    static func pasted(for browser: Browser) -> URL? {
        let text = (board.string(forType: .string) ?? board.string(forType: .URL) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count < 4096, !text.contains(where: \.isWhitespace) else { return nil }
        if let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
           url.host?.isEmpty == false {
            return url
        }
        guard text.contains("."), !text.hasPrefix("."), !text.hasSuffix(".") else { return nil }
        guard let url = URL(string: "https://" + text), let host = url.host, host.contains(".") else { return nil }
        return url
    }

    private final class Do: NSObject {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
        @objc func go() { run() }
    }
}
