import Foundation

// The address field doubles as the most basic kind of command line: a
// handful of words that mean "go here in the app" rather than "go here on
// the web". Off by default (Settings › General › Address bar commands) —
// nobody typing "settings" into a browser expects the app to open its own
// panel instead of asking Google.

@MainActor
enum Command: CaseIterable, Equatable {
    case settings
    case newTab
    case newPrivateTab
    case newSpace
    case bookmarks
    case history
    case downloads
    case passwords
    case toggleSidebar

    /// What you'd type to reach it. The first is what the list shows.
    var aliases: [String] {
        switch self {
        case .settings: return ["settings", "preferences"]
        case .newTab: return ["new tab"]
        case .newPrivateTab: return ["new private tab", "private tab"]
        case .newSpace: return ["new space"]
        case .bookmarks: return ["bookmarks"]
        case .history: return ["history"]
        case .downloads: return ["downloads"]
        case .passwords: return ["passwords"]
        case .toggleSidebar: return ["toggle sidebar", "sidebar"]
        }
    }

    var title: String { aliases[0].localizedCapitalized }

    /// Some only mean something once the feature behind them is even on.
    func available(in browser: Browser) -> Bool {
        switch self {
        case .newSpace: return browser.prefs.usesSpaces
        default: return true
        }
    }

    func run(on browser: Browser) {
        switch self {
        case .settings: browser.tuning = true
        case .newTab: browser.newTab()
        case .newPrivateTab: browser.newShyTab()
        case .newSpace: browser.makingSpace = true
        case .bookmarks: browser.bookmarking = true
        case .history: browser.recalling = true
        case .downloads: browser.hoarding = true
        case .passwords: browser.managing = true
        case .toggleSidebar: browser.toggleSidebar()
        }
    }

    /// The best match for what was typed, if any — exact before prefix, so
    /// "sidebar" doesn't lose to "settings" just for being listed first.
    static func matching(_ typed: String, in browser: Browser) -> Command? {
        let needle = typed.trimmingCharacters(in: .whitespaces).lowercased()
        guard needle.count >= 2 else { return nil }
        let candidates = allCases.filter { $0.available(in: browser) }
        if let exact = candidates.first(where: { $0.aliases.contains(needle) }) { return exact }
        return candidates.first { $0.aliases.contains { $0.hasPrefix(needle) } }
    }
}
