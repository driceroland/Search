import SwiftUI

// What's new, once, after an update.
//
// New features start off, so someone who never opens Settings never meets
// them (a reply on X). The first time a newer version opens, a small card
// shows its new switches, each with a line of what it does and the switch
// itself, and — so nothing gets lost — the switches from earlier versions
// that are still off. Nothing else: few words (Drice). Closed, it
// doesn't come back for that version. Not after a fresh install: the welcome
// is for that. Every version's notes are in Settings › About › What's New…
//
// A release edits `toggles` (its new switches, marked with its version),
// `releases` (that it has a card) and `notes` (what it brought).

enum WhatsNew {
    /// A switch the card offers: the same setting as in Settings.
    struct Toggle {
        let title: String
        let detail: String
        /// The version it came in.
        let since: String
        let get: @MainActor (Preferences) -> Bool
        let set: @MainActor (Preferences, Bool) -> Void
    }

    /// A version that has a card.
    struct Release {
        let version: String
    }

    /// Every switch worth meeting, oldest last. The card shows this
    /// version's, and the older ones still off.
    static let toggles: [Toggle] = [
        Toggle(title: "Tab groups", detail: "Named sections of tabs. Right-click a tab to start one.",
               since: "1.0.4", get: { $0.usesTabGroups }, set: { $0.usesTabGroups = $1 }),
        Toggle(title: "Sidebar on the right", detail: "The tabs down the right edge of the window.",
               since: "1.0.4", get: { $0.sidebar && $0.sidePosition == .right },
               set: { prefs, on in
                   if on { prefs.sidebar = true }
                   prefs.sidePosition = on ? .right : .left
               }),
        Toggle(title: "Videos wait for a click", detail: "Videos don't start by themselves, even without sound.",
               since: "1.0.4", get: { $0.waitsForPlay }, set: { $0.waitsForPlay = $1 }),
        Toggle(title: "Always show the downloads button", detail: "Your downloads one click away, beside the other buttons.",
               since: "1.0.4", get: { $0.alwaysShowsDownloads }, set: { $0.alwaysShowsDownloads = $1 }),

        Toggle(title: "Spaces", detail: "Separate sets of tabs, each with its own sign-ins. ⌃1–⌃9 to switch.",
               since: "1.0.1", get: { $0.usesSpaces }, set: { $0.usesSpaces = $1 }),
        Toggle(title: "A sidebar that hides", detail: "The page takes the whole window; the tabs come out at the edge.",
               since: "1.0.1", get: { $0.sidebar && $0.sideHides },
               set: { prefs, on in
                   if on { prefs.sidebar = true }
                   prefs.sideHides = on
               }),
        Toggle(title: "Bookmarks bar", detail: "Your bookmarks in a row above the page.",
               since: "1.0.2", get: { $0.bookmarksBar }, set: { $0.bookmarksBar = $1 }),
        Toggle(title: "Float the video when you switch apps", detail: "A playing video follows you out into a small window.",
               since: "1.0.2", get: { $0.floatsAway }, set: { $0.floatsAway = $1 }),
        Toggle(title: "Pages at 120 Hz", detail: "Smoother scrolling and animations on screens that can. Uses more battery.",
               since: "1.0.2", get: { $0.fastPages }, set: { $0.fastPages = $1 }),
        Toggle(title: "Scroll with the middle button", detail: "Click the wheel, then move the mouse to scroll, as on Windows.",
               since: "1.0.3", get: { $0.autoScroll }, set: { $0.autoScroll = $1 }),
    ]

    static let releases: [Release] = [
        Release(version: "1.0.4"),
    ]

    /// This version's card, when it has one.
    static var current: Release? { releases.first { $0.version == Updater.version } }

    /// Version strings in order: 1.0.10 after 1.0.9.
    static func older(_ one: String, than other: String) -> Bool {
        let a = one.split(separator: ".").compactMap { Int($0) }
        let b = other.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    private static let seenKey = "whatsnew.seen"

    /// At launch, once: whether the card is due. Not on a fresh install (the
    /// welcome is up, and this version counts as seen), nor in a test world
    /// unless the bench asks; otherwise once per version that has a card.
    @MainActor static func due(prefs: Preferences, welcoming: Bool) -> Bool {
        let store = Store.settings
        guard let current, !Store.testing else { return false }
        if welcoming {
            store.set(current.version, forKey: seenKey)
            return false
        }
        guard store.string(forKey: seenKey) != current.version else { return false }
        store.set(current.version, forKey: seenKey)
        return true
    }

    // MARK: - every version's notes

    /// What a version brought, for Settings › About › What's New…
    struct Notes {
        let version: String
        let date: String
        /// A sentence or two: what the version is about.
        let headline: String
        let new: [String]
        let better: [String]
        let fixed: [String]
    }

    /// Newest first.
    static let notes: [Notes] = [
        Notes(
            version: "1.0.4", date: "27 September 2026",
            headline: "Several windows, and a lot to discover. Most of what's new is off until you turn it on, and the card after the update offers it.",
            new: [
                "Several windows. ⌘N opens one with its own tabs; drag a tab out of the row, or use Move to Window in its menu, and it moves with its page as it is. Pinned tabs are the same in every window.",
                "Tab groups, and a sidebar on the right.",
                "⌃Tab shows your recent tabs as pictures, the last one first: a quick ⌃Tab goes back to the tab you were on.",
                "Your own keyboard shortcuts, in Settings › Shortcuts.",
                "Downloads show while they happen: a small circle fills beside the other buttons, and the Finder and the Dock show the progress too. The button can stay there for good.",
                "Bring things over from Firefox, Zen, Helium, Comet, Opera, Chrome's other channels and Arc, its spaces and pinned tabs included, or from an exported file.",
                "Site shortcuts: a word of your own before a search sends it to that site, like yt cats to YouTube.",
                "Bookmarks in the order you choose, folders of your own, and a card to name a bookmark as you add it.",
                "Videos can wait for a click, and every site can start at a zoom of your choice.",
                "A double-click on a pinned tab takes it back to the page it was pinned at.",
                "Hold a back or forward swipe to pick a page from history.",
            ],
            better: [
                "Scrolling asks far less of the window, and a tab still loading no longer keeps the Mac busy.",
                "Where links go, peeking at a link with a shift-click, and flicking the floating video to a corner are now on.",
                "Tab managers and other extensions see every tab, in every window.",
                "Window › Move & Resize and the Mac's tiling work with Search's window.",
                "⌘K always opens the list of your tabs, whatever the page.",
            ],
            fixed: [
                "⌘← and ⌘→ go back and forward again.",
                "Links from Notion and other apps bring Search to the front.",
                "Addresses a dev server prints, like 0.0.0.0:3000, open.",
                "The tabs you had at quit are the ones that come back.",
                "The × closes a tab in the tab bar folded away with ⌘S.",
                "1Password, Bitwarden, NordPass, Passbolt, iCloud Passwords and the Claude extension each get their fixes.",
                "And many smaller fixes.",
            ]
        ),
        Notes(
            version: "1.0.3", date: "24 September 2026",
            headline: "Security, and the mouse wheel.",
            new: [
                "Copying a saved password asks for Touch ID.",
            ],
            better: [
                "A mouse wheel scrolls smoothly again on x.com and pages like it.",
                "History opens at once.",
                "Music keeps playing when you switch spaces.",
                "Pop-ups need a click.",
            ],
            fixed: [
                "The holes found in this week's reviews: an extension could read files outside its own folder, and a page or an ad could open another app without asking.",
                "Bitwarden signs in to a self-hosted server, and extension popups hear what changes while they're open.",
                "A link from Mail brings Search to the front, and a full-screen video no longer goes black.",
                "Your extensions may each ask once more for their permissions at their next update.",
            ]
        ),
        Notes(
            version: "1.0.2", date: "24 September 2026",
            headline: "Passkeys, password managers and Google.",
            new: [
                "A site's passkey button brings up the Mac's own passkey sheet: Touch ID, your iPhone, a security key.",
                "Search can be the Mac's default browser.",
                "Each off until you turn it on in Settings: a bookmarks bar, a peek at a link with a shift-click, the video that follows you to another app, pages at 120 Hz, and where a link goes.",
                "Mute a tab, share a page, copy a link as Markdown, the mouse's back and forward buttons, and spaces in the bar across the top.",
            ],
            better: [
                "Faster to open, and new tabs in about 10 ms.",
                "Pages see nothing of Search that Safari doesn't show them, and a saved password is offered only on its own site.",
            ],
            fixed: [
                "1Password, Bitwarden and Proton Pass.",
                "If passkeys still fail after the update, restart your Mac once.",
            ]
        ),
        Notes(
            version: "1.0.1", date: "23 September 2026",
            headline: "The first update, made of a day of your replies and pull requests.",
            new: [
                "Each off until you turn it on in Settings: Spaces, a sidebar that hides until the pointer reaches the edge, and the search engine of your choice.",
                "⌘S folds the sidebar away, a middle-click closes a tab, a tab can be renamed, and the Web Inspector is in the View menu.",
            ],
            better: [],
            fixed: [
                "Search opens again on macOS 14.",
                "Signing in to Google no longer reloads the page over and over with iCloud Passwords installed.",
                "⌘1–⌘9 on every keyboard layout, Tab between a form's fields, dragging tabs, a double-click along the top to fill the screen, and the Mac's beep while typing.",
            ]
        ),
        Notes(
            version: "1.0", date: "23 September 2026",
            headline: "The first version. A browser for the Mac with nothing in the way.",
            new: [
                "Tabs in a row or down the side, pinned tabs that keep their place, and one field for addresses and searches.",
                "Ads blocked before they load; passwords and passkeys in your keychain.",
                "Anything on a page can be hidden; articles open in a reading mode and videos float.",
                "Chrome extensions from the Chrome Web Store, on macOS 15.4 or later.",
                "Tabs you haven't looked at for half an hour sleep and give their memory back.",
                "It runs on the engine already in macOS and weighs 2.9 MB.",
            ],
            better: [],
            fixed: []
        ),
    ]
}

/// The card: what's new in this version, its switches right there, and
/// the earlier ones still off.
struct WhatsNewCard: View {
    let release: WhatsNew.Release
    @ObservedObject var prefs: Preferences
    let close: () -> Void
    let notes: () -> Void

    /// Read once, as the card opens: a switch turned on here stays in the
    /// list rather than vanishing under the hand.
    @State private var earlier: [WhatsNew.Toggle]?

    private var fresh: [WhatsNew.Toggle] { WhatsNew.toggles.filter { $0.since == release.version } }

    var body: some View {
        Plate("New in Search \(release.version)", width: 460, close: close) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    rows(fresh)
                    if let earlier, !earlier.isEmpty {
                        Caption("From earlier versions, in case you missed them")
                            .padding(.top, 6)
                        rows(earlier)
                    }
                }
            }
            .frame(maxHeight: 470)
            .fixedSize(horizontal: false, vertical: true)
        } foot: {
            HStack {
                Button(action: notes) {
                    Text("Everything that's new…")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                }
                .buttonStyle(.plain)
                Spacer()
                Pill("Close", filled: true, action: close)
            }
        }
        .onAppear {
            if earlier == nil {
                earlier = WhatsNew.toggles.filter { WhatsNew.older($0.since, than: release.version) && !$0.get(prefs) }
            }
        }
    }

    private func rows(_ toggles: [WhatsNew.Toggle]) -> some View {
        Card {
            ForEach(Array(toggles.enumerated()), id: \.offset) { index, toggle in
                if index > 0 { Rule() }
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(toggle.title)
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.ink)
                        Text(toggle.detail)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Palette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Switch(on: Binding(get: { toggle.get(prefs) }, set: { toggle.set(prefs, $0) }))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        }
    }
}

/// Every version's notes, newest first: Settings › About › What's New…
struct ReleaseNotesPanel: View {
    let close: () -> Void

    var body: some View {
        Plate("What's New", width: 560, close: close) {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    ForEach(WhatsNew.notes, id: \.version) { note in
                        version(note)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
            .frame(maxHeight: 480)
        }
    }

    private func version(_ note: WhatsNew.Notes) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Search \(note.version)")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                if !note.date.isEmpty {
                    Text(note.date)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.faint)
                }
            }
            Text(note.headline)
                .font(.system(size: 13))
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
            list("New", note.new)
            list("Better", note.better)
            list("Fixed", note.fixed)
        }
    }

    @ViewBuilder
    private func list(_ title: String, _ lines: [String]) -> some View {
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Palette.muted)
                ForEach(lines, id: \.self) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(Palette.faint)
                        Text(line)
                            .foregroundStyle(Palette.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.system(size: 12.5))
                }
            }
        }
    }
}
