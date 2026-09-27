import Foundation

// The address field doubles as the most basic kind of command line: a
// handful of words that mean "go here in the app" rather than "go here on
// the web". Only ever the whole of what was typed, so a search that merely
// starts with one of these words still searches. Off by default (Settings ›
// General › Address bar commands): nobody typing "settings" into a browser
// expects the app to open its own panel instead of asking Google.
//
// Not the menus' Command (Shortcuts.swift): these are words, not keys.

@MainActor
enum AddressCommand: CaseIterable, Equatable {
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

    /// The command whose words are all that was typed, if any. Only the
    /// whole thing, never a prefix or a near miss: a command must not take a
    /// search from anyone, so "settings for gmail" or "sett" still searches.
    static func matching(_ typed: String, in browser: Browser) -> AddressCommand? {
        let needle = typed.trimmingCharacters(in: .whitespaces).lowercased()
        return allCases.first { $0.available(in: browser) && $0.aliases.contains(needle) }
    }
}
