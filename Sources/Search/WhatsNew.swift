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
    static let toggles: [Toggle] = (AI.shipped ? [
        Toggle(title: "AI on pages", detail: "Summarize a page or ask about it. Choose where it runs in Settings › AI.",
               since: "1.0.5", get: { $0.ai }, set: { $0.ai = $1 }),
    ] : []) + [
        Toggle(title: "Your Apple passwords", detail: "Accounts from Apple's Passwords app under the sign-in field, with a code from your Mac.",
               since: "1.0.7", get: { $0.applePasswords }, set: { $0.applePasswords = $1 }),
        Toggle(title: "Ask before quitting", detail: "⌘Q asks first, so a slip doesn't close every window.",
               since: "1.0.7", get: { $0.confirmsQuit }, set: { $0.confirmsQuit = $1 }),
        Toggle(title: "Tab numbers while ⌘ is held", detail: "See which tab ⌘1–⌘9 goes to.",
               since: "1.0.7", get: { $0.showsTabShortcuts }, set: { $0.showsTabShortcuts = $1 }),
        Toggle(title: "A column of icons only", detail: "The tabs as icons down the side, nothing that grows under the pointer.",
               since: "1.0.7", get: { $0.sideIcons }, set: { $0.sideIcons = $1 }),
        Toggle(title: "Escape twice to leave full screen", detail: "One Escape stays with the page, a second leaves full screen.",
               since: "1.0.7", get: { $0.escapeTwice }, set: { $0.escapeTwice = $1 }),

        Toggle(title: "Suggestions from your search engine", detail: "Searches suggested as you type. What you type is sent to your engine; never from a private tab.",
               since: "1.0.6", get: { $0.engineSuggests }, set: { $0.engineSuggests = $1 }),
        Toggle(title: "Pins keep their site", detail: "Links elsewhere open in a peek, and ⌘W takes a pin back to its page, as in Arc.",
               since: "1.0.6", get: { $0.pinsKeepSite }, set: { $0.pinsKeepSite = $1 }),
        Toggle(title: "Darken light pages", detail: "While Search is dark, pages with no dark look of their own are darkened.",
               since: "1.0.6", get: { $0.darkensPages }, set: { $0.darkensPages = $1 }),
        Toggle(title: "Roomier tabs", detail: "Taller rows and larger titles in the sidebar.",
               since: "1.0.6", get: { $0.roomyTabs }, set: { $0.roomyTabs = $1 }),
        Toggle(title: "New tab in a floating field", detail: "⌘T raises the address field over the page you are on, as in Arc.",
               since: "1.0.6", get: { $0.floatingNewTab }, set: { $0.floatingNewTab = $1 }),

        Toggle(title: "Pinned rows", detail: "Pins as rows with their names, under the squares, as in Arc. Right-click a tab to pin it as a row.",
               since: "1.0.5", get: { $0.listsPins }, set: { $0.listsPins = $1 }),
        Toggle(title: "Start with a fresh window", detail: "Your pinned tabs, tab groups and named tabs, and none of last time's others.",
               since: "1.0.5", get: { $0.startsFresh }, set: { $0.startsFresh = $1 }),

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
               since: "1.0.2", get: { $0.floatsAway }, set: { prefs, on in if on { prefs.floatOwn = .tabsOrApps } else { prefs.floatsAway = false } }),
        Toggle(title: "Pages at 120 Hz", detail: "Smoother scrolling and animations on screens that can. Uses more battery.",
               since: "1.0.2", get: { $0.fastPages != .never }, set: { $0.fastPages = $1 ? .onPower : .never }),
        Toggle(title: "Scroll with the middle button", detail: "Click the wheel, then move the mouse to scroll, as on Windows.",
               since: "1.0.3", get: { $0.autoScroll }, set: { $0.autoScroll = $1 }),
    ]

    static let releases: [Release] = [
        Release(version: "1.0.7"),
        Release(version: "1.0.6"),
        Release(version: "1.0.5"),
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
            version: "1.0.7", date: "25 October 2026",
            headline: "Settings as a page, profiles, page translation, Apple Passwords and YouTube without ads.",
            new: [
                "Settings, History, Downloads, Bookmarks and Passwords open as pages in tabs of their own; Settings is sorted into sections with ⌘F to find a setting.",
                "Profiles: each keeps its own spaces, sign-ins, history and bookmarks, one per window.",
                "Translate a page on your Mac, from its right-click menu; nothing is sent anywhere.",
                "Your passwords from Apple's Passwords app, under the sign-in field.",
                "Shield blocks YouTube's ads.",
                "The tab you're on shows its site; plain http and look-alike names always show.",
                "A site in the side panel, a column of icons only, ask before quitting, tab numbers while ⌘ is held.",
                "Copy Clean Link, Fold All Groups, Move Group to Space, ⌃Tab on a key of your own, Open 2 Tabs in Split View.",
            ],
            better: [
                "Fewer switches: Split View, tab groups and more are simply there; pins keep their site by default.",
                "Drag tabs onto the pins and pins back among the tabs; small handles on the edges you resize.",
                "A call keeps its camera and sound when you switch tabs.",
                "Reading mode keeps pictures and charts and follows light and dark.",
            ],
            fixed: [
                "Saved accounts show under the sign-in field again, and only in real sign-in fields.",
                "Sites you allow get your location; links to other folders' files open.",
                "Norma's and other extensions' block pages show; an extension's rules no longer blank pages.",
                "And many more, most from your messages and pull requests.",
            ]
        ),
        Notes(
            version: "1.0.6", date: "24 October 2026",
            headline: "A side panel, blocked pop-ups you can open, and a month of your fixes. What's new is off until you turn it on, and the card after the update offers it.",
            new: [
                "An extension's side panel, as in Chrome: Claude's, ChatGPT's or Sider's panel opens beside the page instead of in a tab.",
                "A pop-up refused because no click asked for it says so beside the tab's title, with Open and Always Allow, as in Safari.",
                "Suggestions from your search engine as you type, never from a private tab.",
                "Extensions in private tabs, each with its own switch in Settings › Extensions.",
                "Pins go back home and keep their site, with links elsewhere in a peek; pins can sit above every space.",
                "Tabs can close themselves after a while, and chosen sites can stay awake.",
                "⇧⌘W closes the window, the mouse's side buttons change space, and media keys reach the page.",
                "New tabs at the top or the bottom, a floating ⌘T, roomier tabs, and light pages darkened in dark mode.",
                "Select several tabs with ⌘- or ⇧-click, export a page as a PDF, and Open With from the Finder.",
            ],
            better: [
                "The page as a card can be turned off, and full screen goes edge to edge.",
                "Leaving a video's full screen happens in one move.",
                "Pins in spaces you aren't in sleep and give their memory back.",
                "A bookmark opens in a tab of its own, never in a pin's place.",
                "Claude in Chrome signs in, and signs in again quietly each time Search starts.",
                "Stylus and Vimium C work.",
            ],
            fixed: [
                "A pop-up rewritten by the page that opened it is no longer offered that site's saved passwords.",
                "Sites you allow to know your location get it.",
                "Start with a fresh window keeps your tab groups and named tabs.",
                "A Gmail link opens one tab, not two.",
                "A video file opened as a page plays.",
                "Links between files on your Mac open, and links in AI chats' answers too.",
                "Saved accounts show with Split View on.",
                "Dragging a tab across the top moves the tab, not the window.",
                "And many more, most from your messages and pull requests.",
            ]
        ),
        Notes(
            version: "1.0.5", date: "14 October 2026",
            headline: "Split View, pinned rows, notifications and screen recorders. What's new is off until you turn it on, and the card after the update offers it.",
            new: [
                "With the tabs down the side, the page sits in the window as a card, a little apart from the column.",
                "Split View: two tabs side by side. Drag a tab to the left or right edge of a page, choose Open in Split View in its menu, or press ⌥⌘N.",
                "Pinned rows, as in Arc: a pin can be a row with its name, under the squares, and Clear closes the tabs below.",
                "Websites can send notifications and ask for your location, as in Safari, site by site.",
                "Loom and other screen recorders work: macOS asks what to share each time, and a pill says who is recording, with Stop.",
                "Search a site straight from the address field, as in Arc: type its name, then Tab.",
                "Passkeys show under the sign-in field, beside your saved passwords.",
                "Sign-ins that ask for your name first, or for a password alone, offer your saved accounts too.",
                "Your Mac's text replacements work in pages, and Edit › Substitutions turns them, smart quotes and smart dashes on or off.",
                "Find says “3 of 17”, paints every match, and can match case or whole words.",
                "Downloads pause and resume.",
                "Open Link in New Tab leaves you where you are; hold ⌥ to go to it.",
                "Search can start with a fresh window: your pinned tabs, tab groups and named tabs, and none of last time's others.",
                "Intel Macs get a download of their own.",
            ],
            better: [
                "Search is built for size, so all of this fits in 6.8 MB, and pages that change all the time, like a chat writing its answer, stay quick.",
                "An extension's popup window opens as a small window, as in Chrome: a password manager's vault, a sign-in.",
                "Esc closes a new tab you haven't used, and words typed into a new tab wait for you.",
                "Tampermonkey installs scripts from a link, and SingleFile saves pages again.",
                "Close Group in a tab group's menu, and one ⇧⌘T brings the whole group back.",
                "Don't Float Videos Here, in a site's card.",
                "Bringing Arc over keeps its shape: pinned pages as pinned rows, its folders as named tab groups.",
                "Too many pinned extensions no longer push the column off screen.",
                "Empty a bookmark's name and it is its icon alone on the bookmarks bar.",
            ],
            fixed: [
                "A live video, on X and elsewhere, no longer jumps every few seconds.",
                "A site's icon follows the page: GitHub's in the dark, a chat's unread count, and each port of localhost its own.",
                "Pins brought over from Arc wear their icons straight away.",
                "The tabs come back after a video's full screen.",
                "A folder in the bookmarks list opens whole.",
                "Signing in with a passkey works on GitHub again.",
                "Bitwarden's passkey window, its sync and its narrow popup.",
                "Keys in games no longer make the Mac beep.",
                "History keeps localhost:3000 and localhost:4000 apart.",
                "Copy Image works on WhatsApp Web's photos.",
                "Signing in to Claude's extension finishes on claude.ai.",
                "The Bookmarks menu keeps its bookmarks while a tab's title keeps changing.",
                "Popovers keep their rounded corners on macOS 15.",
                "Security hardening from a third careful private report, and many smaller fixes.",
            ]
        ),
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
            .listHeight(480)
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
