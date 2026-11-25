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
//
// A few switches lead: first on every card, above that version's own, for
// as long as they are off. Sync with iCloud and Handoff do, since 22 Nov
// 2026: on for a new install (SyncDefault.swift), offered here to everyone
// who had Search before and never turned them on.

enum WhatsNew {
    /// A switch the card offers: the same setting as in Settings.
    struct Toggle {
        let title: String
        let detail: String
        /// The version it came in.
        let since: String
        let get: @MainActor (Preferences) -> Bool
        let set: @MainActor (Preferences, Bool) -> Void
        /// Whether it can do anything now: a switch that needs another one
        /// on stays off the card until it is.
        var shown: @MainActor (Preferences) -> Bool = { _ in true }
        /// First on every card while it is off, whatever its version.
        var lead = false
    }

    /// A version that has a card.
    struct Release {
        let version: String
    }

    /// Every switch worth meeting, the leading ones first, then oldest
    /// last. The card shows the leading ones still off, this version's, and
    /// the older ones still off. Only switches that are off unless turned
    /// on: the ones on for everyone who never touched them since 25 Nov 2026
    /// (HTTPS first, video keys, smooth wheel, the loading line, unread
    /// counts, swipe back closes, Home tiles, site styles, commands, Capture,
    /// pin folders) left the card then, so turning one off isn't asked about
    /// again.
    static let toggles: [Toggle] = [
        // Leading, in this order (see the top of this file).
        Toggle(title: "Sync with iCloud", detail: "Your tabs, pins and spaces on your iPhone and your other Macs, end-to-end encrypted.",
               since: "1.0.16", get: { _ in ICloudSync.shared.on },
               set: { _, on in on ? ICloudSync.shared.turnOnOrWait() : ICloudSync.shared.turnOff() },
               // Never beside the folder sync: the two would undo each other.
               shown: { _ in ICloudSync.shared.on || !Sync.shared.on }, lead: true),
        Toggle(title: "Handoff to your iPhone", detail: "The page in front comes up in your iPhone's and iPad's app switcher.",
               since: "1.0.16", get: { $0.handoff }, set: { $0.handoff = $1 }, lead: true),
    ] + (AI.shipped ? [
        Toggle(title: "AI on pages", detail: "Summarize a page or ask about it. Choose where it runs in Settings › AI.",
               since: "1.0.5", get: { $0.ai }, set: { $0.ai = $1 }),
    ] : []) + [
        Toggle(title: "Backspace goes back", detail: "⌫ goes back a page and ⇧⌫ forward, when you aren't typing in a field.",
               since: "1.0.21", get: { $0.backspaceGoesBack }, set: { $0.backspaceGoesBack = $1 }),

        Toggle(title: "Hide the page behind the field", detail: "⌘T's and ⌘L's field over a plain ground, the page out of sight instead of dimmed.",
               since: "1.0.21", get: { $0.fieldHidesPage }, set: { $0.fieldHidesPage = $1 }),

        Toggle(title: "Return takes the top suggestion", detail: "Return goes to the place on top of the field's list as you type, as in Arc's command bar; ↑ lets go of it.",
               since: "1.0.21", get: { $0.returnTakesTop }, set: { $0.returnTakesTop = $1 }),

        Toggle(title: "Links from pins open in a new tab", detail: "A link clicked in a pinned tab opens in a tab of its own, and the pin stays on its page.",
               since: "1.0.20", get: { $0.pinLinksOpenTabs }, set: { $0.pinLinksOpenTabs = $1 }),

        Toggle(title: "Keep the window when its last tab closes", detail: "⌘W on the last, empty tab leaves it there, as in Arc; ⇧⌘W still closes the window.",
               since: "1.0.20", get: { $0.keepWindowAfterLast }, set: { $0.keepWindowAfterLast = $1 }),

        Toggle(title: "Clicking the tab you're on keeps its name", detail: "With the address bar always shown, the address is edited there or with ⌘L.",
               since: "1.0.20", get: { $0.tabClickKeepsName }, set: { $0.tabClickKeepsName = $1 },
               shown: { $0.addressLine && !$0.iconColumn }),

        Toggle(title: "Fade scroll bars", detail: "Thin bars over the page that come up as it scrolls and fade when it stops, even with a mouse.",
               since: "1.0.20", get: { $0.scrollbarsFade }, set: { $0.scrollbarsFade = $1 }),

        Toggle(title: "Update ready, in the window", detail: "When a new version is waiting, \"Update ready\" and Restart at the foot of the sidebar, or a pill by the tabs. On; × hides it until the next one.",
               since: "1.0.20", get: { $0.showsUpdateReady }, set: { $0.showsUpdateReady = $1 }),

        Toggle(title: "Bookmarks bar only on new tabs", detail: "The bookmarks bar above a new tab only, gone once a page opens, as in Chrome and Edge.",
               since: "1.0.20", get: { $0.bookmarksNewTabOnly }, set: { $0.bookmarksNewTabOnly = $1 },
               shown: { $0.bookmarksBar && !$0.sideBookmarks }),

        Toggle(title: "Bookmarks bar in the sidebar", detail: "The bookmarks bar at the top of the sidebar, in every space.",
               since: "1.0.19", get: { $0.bookmarksInSidebar }, set: { $0.bookmarksInSidebar = $1 }),
        Toggle(title: "The field in the middle of the window", detail: "⌘T's and ⌘L's field centred on the window and higher up, as in Arc.",
               since: "1.0.19", get: { $0.fieldOnWindow }, set: { $0.fieldOnWindow = $1 }),
        Toggle(title: "Click the tab you're on to edit its address", detail: "Without the site card; Site Information… stays on the right-click.",
               since: "1.0.19", get: { $0.tabClickAddressOnly }, set: { $0.tabClickAddressOnly = $1 }),
        Toggle(title: "Touch ID before filling a password", detail: "Touch ID, or your Mac's password, before a saved password goes into a page.",
               since: "1.0.19", get: { $0.asksBeforeFilling }, set: { $0.asksBeforeFilling = $1 }),
        Toggle(title: "Icons only on the bookmarks bar", detail: "Each bookmark its site's icon, its name on hover. Folders keep their names.",
               since: "1.0.19", get: { $0.bookmarksIconsOnly }, set: { $0.bookmarksIconsOnly = $1 }),

        Toggle(title: "Sidebar button", detail: "Beside the window's buttons, it hides the sidebar as ⌘S does.",
               since: "1.0.18", get: { $0.foldButton }, set: { $0.foldButton = $1 }),
        Toggle(title: "Narrow to icons", detail: "Pull the sidebar narrower and it becomes a strip of site icons.",
               since: "1.0.18", get: { $0.narrowsToIcons }, set: { $0.narrowsToIcons = $1 }),

        Toggle(title: "⌘T finds your open tabs", detail: "As you type in ⌘T's field, a matching open tab or pin comes first.",
               since: "1.0.17", get: { $0.arcTabPopup }, set: { $0.arcTabPopup = $1 },
               shown: { $0.floatingNewTab }),
        Toggle(title: "One button per space", detail: "Every space beside the bookmarks, one click away.",
               since: "1.0.17", get: { $0.spaceButtons }, set: { $0.spaceButtons = $1 },
               shown: { $0.usesSpaces }),

        Toggle(title: "Always show the address bar", detail: "The page's full address stays in sight, to type in.",
               since: "1.0.16", get: { $0.addressLine }, set: { $0.addressLine = $1 }),
        Toggle(title: "Glass window", detail: "The column and the window's edge as frosted glass over your desktop.",
               since: "1.0.16", get: { $0.glass }, set: { $0.glass = $1 }),
        Toggle(title: "Buttons at the top", detail: "The column's bottom buttons beside back, forward and reload.",
               since: "1.0.16", get: { $0.doorsUp }, set: { $0.doorsUp = $1 }),
        Toggle(title: "Ask which space a link opens in", detail: "For links from other apps.",
               since: "1.0.16", get: { $0.asksSpaceForLinks }, set: { $0.asksSpaceForLinks = $1 }),
        Toggle(title: "Dim sleeping tabs", detail: "A tab put to sleep fades until you come back to it.",
               since: "1.0.16", get: { $0.dimsSleepingTabs }, set: { $0.dimsSleepingTabs = $1 }),
        Toggle(title: "High contrast tab text", detail: "Tab titles in full black or white.",
               since: "1.0.16", get: { $0.highContrastText }, set: { $0.highContrastText = $1 }),

        Toggle(title: "⌘1–⌘9 switch spaces", detail: "As in Arc: the tabs move to ⌃1–⌃9.",
               since: "1.0.15", get: { $0.spacesOnCommand }, set: { $0.spacesOnCommand = $1 },
               shown: { $0.usesSpaces }),
        Toggle(title: "Same tabs in every window", detail: "Every window lists the same open tabs, as Arc's sidebar does.",
               since: "1.0.15", get: { $0.mirrorsTabs }, set: { $0.mirrorsTabs = $1 }),
        Toggle(title: "⌥-click a link opens it in Split View", detail: "Beside the page you're reading.",
               since: "1.0.15", get: { $0.optionClickSplits }, set: { $0.optionClickSplits = $1 }),
        Toggle(title: "Bounce at the top and bottom", detail: "Pages stretch past their ends and spring back, as in Safari.",
               since: "1.0.15", get: { $0.bounces }, set: { $0.bounces = $1 }),
        Toggle(title: "Slide the column in and out", detail: "An eased slide for ⌘S and the column that hides.",
               since: "1.0.15", get: { $0.slidesColumn }, set: { $0.slidesColumn = $1 }),

        Toggle(title: "Keep the card in full screen", detail: "The page keeps its room and rounded corners when the window fills the screen.",
               since: "1.0.14", get: { $0.cardsInFullScreen }, set: { $0.cardsInFullScreen = $1 },
               shown: { $0.sidebar && $0.cards }),
        Toggle(title: "⌘-click on a pin opens a new tab", detail: "As in Arc, or takes a page that wandered off into the loose tabs.",
               since: "1.0.14", get: { $0.pinCommandOpensTab }, set: { $0.pinCommandOpensTab = $1 }),

        Toggle(title: "Send links to a space", detail: "Links to the sites you choose open in their space, with its sign-ins, as in Arc.",
               since: "1.0.11", get: { $0.sendsLinksToSpaces }, set: { $0.sendsLinksToSpaces = $1 },
               shown: { $0.usesSpaces }),

        Toggle(title: "Profiles in one window", detail: "A space of another profile opens in the same window, with that profile's sign-ins, as in Arc.",
               since: "1.0.9", get: { $0.profilesInOneWindow }, set: { $0.profilesInOneWindow = $1 }),

        Toggle(title: "Close goes back", detail: "Closing the tab you're on takes you to the one you were on before it, as ⌃Tab would.",
               since: "1.0.8", get: { $0.closeGoesBack }, set: { $0.closeGoesBack = $1 }),

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
        Release(version: "1.0.21"),
        Release(version: "1.0.20"),
        Release(version: "1.0.19"),
        Release(version: "1.0.18"),
        Release(version: "1.0.17"),
        Release(version: "1.0.16"),
        Release(version: "1.0.15"),
        Release(version: "1.0.14"),
        Release(version: "1.0.13"),
        Release(version: "1.0.12"),
        Release(version: "1.0.11"),
        Release(version: "1.0.10"),
        Release(version: "1.0.9"),
        Release(version: "1.0.8"),
        Release(version: "1.0.7"),
        Release(version: "1.0.6"),
        Release(version: "1.0.5"),
        Release(version: "1.0.4"),
    ]

    /// What a card opened now lists: first the leading switches still off,
    /// then the version's own; under their caption, the earlier ones still
    /// off.
    @MainActor static func rows(for release: Release, prefs: Preferences) -> (leading: [Toggle], own: [Toggle], earlier: [Toggle]) {
        (toggles.filter { $0.lead && !$0.get(prefs) && $0.shown(prefs) },
         toggles.filter { !$0.lead && $0.since == release.version && $0.shown(prefs) },
         toggles.filter { !$0.lead && older($0.since, than: release.version) && !$0.get(prefs) && $0.shown(prefs) })
    }

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

    /// Search › What's New… and the About window's button (idea 968): this
    /// version's card again, exactly as after an update, switches and all.
    /// Nothing is marked: the card was already seen once.
    @MainActor static func showAgain(in browser: Browser) {
        guard current != nil else { return }
        browser.newsShowing = true
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
            version: "1.0.21", date: "25 November 2026",
            headline: "Your fixes, from NordPass to YouTube's sign-in.",
            new: [
                "Backspace can go back a page, and ⇧⌫ forward, when you aren't typing, in Settings › Keyboard & Mouse.",
                "The page can be hidden behind ⌘T's and ⌘L's field, over a plain ground, in Settings › Spaces & Pins.",
                "Return can take the top suggestion as you type, as in Arc's command bar, in Settings › Browsing.",
            ],
            better: [
                "Hide Elements names exactly what you picked, so on later visits it hides that one thing, not everything that looks like it, and it goes at once from every open page of the site.",
                "A slept tab wakes where you were in a page that scrolls inside itself, as a long Google Doc does.",
                "A column folded with ⌘S comes out when the pointer is flung past the window's side.",
                "Zen's open tabs come into the space of their Zen space's name, and come at all when Zen keeps them only in its own file.",
                "Darken pages keeps pictures drawn in SVG as they are, and leaves Google Docs, Sheets and Slides as they are.",
                "Extensions that ask for chrome.identity.AccountStatus find it, as Fathom AI Note Taker does before every request.",
                "A download with nothing coming in says Stalled, and the Downloads list keeps each row's buttons under its text and fades at its head once scrolled.",
                "Closing tabs across the top one after another: the next tab's cross comes to where the last one was.",
                "When Apple Passwords asks for its code again, the log says why the last pairing ended, and the log says why an extension's connection to its app on the Mac closed.",
            ],
            fixed: [
                "NordPass freezing, its popup an empty dark box.",
                "YouTube signing you out every few weeks when you mostly watch: the floating video's and the sidebar player's controls now count as using the site.",
                "Saved passwords and passkeys not showing in a site's sized pop-up window, as Gmail's Add another account opens.",
                "Saved passwords not offered in sign-ins that mark every box as new, as some crew portals do.",
                "A page closing itself in a small window leaving the window open.",
                "An extension update waiting for your OK being dropped while Search was in the background; it now shows in Settings › Extensions.",
                "A pinned tab's Site Information… doing nothing on the pin you were on, one put down with ⌘W, pins brought back at launch, and in the column of icons.",
                "Arc's spaces brought over staying empty until Spaces was turned off and on.",
                "With profiles in one window, a space's name popping up on nearly every profile switch.",
                "Two Macs set up one from the other with Migration Assistant sharing one sync id and taking each other's tabs for their own.",
                "The floating video's return arrow bringing forward another window instead of the video's own.",
                "With Liquid Glass, the buttons beside the tabs and a tab's letter fading into what is behind the window, and the glass not following the tab when the column scrolls.",
                "An extension's new tab opening as an empty page instead of ⌘T's blank tab, and the home background drawn past the window's rounded corners.",
                "LOCALHOST and other local names typed in capitals not opening over HTTP.",
            ]
        ),
        Notes(
            version: "1.0.20", date: "24 November 2026",
            headline: "Your fixes, from the Dock to extension popups.",
            new: [
                "Sync with iCloud carries your tab groups with your open tabs: on another Mac, History › Tabs on Your Other Devices lists them by group, with Open All in Tab Group.",
                "Links from pinned tabs can open in a tab of their own, in Settings › Spaces & Pins.",
                "Keep the window when its last tab closes: ⌘W on the last, empty tab leaves it there, as in Arc, in Settings › Tabs.",
                "Clicking the tab you're on can keep its name while the address bar is shown, in Settings › Tabs.",
                "A pinned row taken away from its page goes back with a click on its icon, as in Arc.",
                "Several picked tabs move together into a pin folder or a group, and ⌘Z puts them back in one step.",
                "A coding agent using Search shows as a card at the foot of the sidebar with Stop, like \"Update ready\".",
                "Scroll bars that fade once scrolling stops, even with a mouse, in Settings › Appearance › Window.",
                "Drag a finished download out of the Downloads list as its file, onto a page or into the Finder.",
                "Send links to a space: links from other apps that match none of your sites can go to a space you pick.",
                "A peek can share your screen, so Google Meet's Present now works from a pinned Calendar or Gmail.",
                "vnc://, ssh:// and other apps' addresses typed in the field open in their app.",
                "Space and the arrow keys play, pause and seek a clicked video, in Settings › Videos.",
                "When an update is ready, \"Update ready\" and Restart show at the foot of the sidebar, or as a pill by the tabs. On, in Settings › About.",
                "Developer Tools Lite (Lighthouse, Recorder, device toolbar) and Developer Tools Full (Chrome-style panels docked beside the page): optional downloads in Settings › About › Developer. Web Inspector stays the default.",
                "Pinned tabs have Site Information… in their right-click menu, so a pinned site's ad blocking and other settings can be changed.",
                "The bookmarks bar can show only on new tabs, in Settings › Appearance › Tabs.",
                "A custom search engine can have a suggestions address, in Settings › Browsing › Search with.",
            ],
            better: [
                "Settings is easier to find your way in: Sync and other devices, and Closing and switching, have groups of their own, and the two syncs say how they differ.",
                "⌘S with the page as a card: the page, the column and the window's buttons slide together, the page and the side panel edge to edge once folded, and the column brought out over it floats as a rounded card.",
                "Go to a tab that has the page works without small windows too.",
                "Find on Page finds text inside pages' own components, as on Reddit and MSN.",
                "Extension popups take their content's size and follow it, growing and shrinking.",
                "With AdGuard, Search no longer compiles its rules twice at every launch.",
                "A saved password is offered in the email box of more sign-ins.",
                "Hidden on This Site… lets a restored row go at once, and can be moved.",
                "A space's Colour… previews the colour as the window will wear it.",
            ],
            fixed: [
                "⇧⌘B with the Bookmarks button hidden now says \"Bookmarked\" or \"Already a bookmark\".",
                "The small window from the address field from any app opening behind the app you were in.",
                "The Dock icon doing nothing while the floating video was up, and the first window missing from the Window menu.",
                "A page that fails to load showing the page it was leaving in the field: it now shows and copies the address that failed.",
                "⌘T, ⌘W, ⌘L and the other ⌘ shortcuts with the Dvorak – QWERTY ⌘ layout following the Dvorak letters.",
                "⌘T's and ⌘L's field in the middle of the window not taking the keys.",
                "⌘T's and ⌘L's field losing the keys as it finished opening, on macOS 27.",
                "⌘W going round between a pin and a new tab, and closing a pin not going back to the pin before it.",
                "A closed tab's page process left spinning a core.",
                "An extension's popup sent without its window's sign-ins, extension pages in quirks mode, and the extensions list closing as it opened.",
                "A menu along the page's edge opening under the folded sidebar, and a tab dragged along the hidden sidebar opening Split View.",
                "Settings › Themes in a narrow window, scroll bars on Search's own pages, the sidebar's foot buttons and long tab titles.",
            ]
        ),
        Notes(
            version: "1.0.19", date: "23 November 2026",
            headline: "Your fixes, and more of Arc's ways.",
            new: [
                "Set Up Like Arc turns on Arc's newer habits too, and is offered on the welcome and after an Arc import.",
                "Search › What's New… brings this card back.",
                "File › Open File…, Paste and Match Style, Open Link in Private Tab, Open Image in Split View and New Tab in Group.",
                "A » at the end of the bookmarks bar for what doesn't fit, icons only if you like, and a middle-click or ⌘-click on a folder opens all of it.",
                "Touch ID before a saved password is filled, in Settings › Passwords.",
                "Unread counts on pinned tabs, and every site's camera, microphone, location and notification choice listed in Settings › Privacy.",
                "Keys of your own for the next and previous space and for each profile, in Settings › Keyboard & Mouse › Shortcuts.",
                "Hide back, forward, reload and the buttons under the sidebar, one by one, in Settings › Appearance.",
                "Safari extensions that came inside your apps, in Settings › Extensions, off until you turn it on.",
            ],
            better: [
                "uBlock Origin Lite blocks from the first second after launch.",
                "Extensions from the Chrome Web Store get the update a new install would, and a failed check is tried again within the hour.",
                "Saved passwords are offered in more sign-in pages, and filled more safely.",
                "Escape in the window's full screen goes to the page, as in Safari.",
                "With Float the video when you switch apps, the video waits until the window is out of sight.",
                "Continue Anyway trusts only the certificate you saw.",
                "Extension managers see your installed extensions (chrome.management).",
            ],
            fixed: [
                "uBlock Origin's popup, Readwise Highlighter, Raindrop.io's sign-in, Zotero Connector and Claude's side panel.",
                "A sideways swipe in Google Sheets, or a fast scroll, going back a page.",
                "Two rows of window buttons in split screen, and the full-screen bar taller than Safari's.",
                "A video left in full screen coming back white, and YouTube opening as a download.",
                "The Liquid Glass tab hard to see in light mode, and the side panel's white flash.",
                "A beachball in a window full of tabs when the address field took the keyboard.",
                "Enhancer for YouTube's buttons showing four times, and the extensions list closing at once in the screen's corner.",
                "Picture in picture's return button across spaces, a narrowed sidebar's rows, and a tab's renamed title sticking.",
            ]
        ),
        Notes(
            version: "1.0.18", date: "22 November 2026",
            headline: "Sync on from the start, news by email, and your fixes.",
            new: [
                "Sync with iCloud and Handoff are on for a new install, with both switches on the welcome's first page.",
                "News by email and the Search for iPhone beta: leave your email on this card, in the welcome or in Settings › About.",
                "A sidebar button beside the window's buttons, and a sidebar that narrows to icons. Settings › Appearance › Tabs.",
            ],
            better: [
                "⌘S is smooth again with several spaces and the column made icons only.",
                "With the tabs across the top, an open group shows where it starts and ends.",
                "Buttons say the key you set for them in Settings › Shortcuts.",
            ],
            fixed: [
                "In full screen, the menu bar no longer comes down over the tabs.",
                "Selecting text in a field at the very top of a page, and Rename on a pinned square.",
                "Asking to save a password nobody typed, and YouTube previews floating as a video.",
                "Windows coming back twice, sites at .local names, and tabs showing a lone \u{2026}.",
            ]
        ),
        Notes(
            version: "1.0.17", date: "22 November 2026",
            headline: "Spaces from Zen, more browsers to come from, and your fixes.",
            new: [
                "Coming from Zen brings its spaces, pins and folders, and open tabs come over from Firefox and Zen.",
                "Eleven more browsers to come from, and Safari directly when macOS allows it.",
                "Themes for the blank tab, your Home bookmarks as tiles, and ⌘T finding your open tabs. Settings › Themes and Settings › Tabs.",
                "A split pinned as a split, one button per space, and Try HTTPS first. Settings › Spaces & Pins and Settings › Privacy.",
            ],
            better: [
                "⌘S slides the column smoothly again, as in 1.0.15.",
                "Any space can be deleted, the first one included, and profiles can be put in any order.",
                "A bookmarks folder of thousands opens at once.",
            ],
            fixed: [
                "Pinned-row folders syncing between Macs, and the history of signed-out spaces.",
                "YouTube videos held at 0:00, YouTube Music's floating player, and Reddit's promoted posts.",
                "Client certificates for company sign-ins, security keys with passkeys off, and games locking the pointer.",
                "Stylus, Monarch Money, Floccus, Similarweb and Brandsearch.",
            ]
        ),
        Notes(
            version: "1.0.16", date: "20 November 2026",
            headline: "Sync with your iPhone, Handoff, and two days of your fixes.",
            new: [
                "Sync with iCloud: open tabs, pins, spaces and bookmarks with Search on iPhone, in public beta. Settings › General.",
                "Handoff of the page in front to your iPhone and iPad. Settings › General.",
                "The address bar always in sight, a glass window, and buttons at the top. Settings › Appearance.",
                "Choose the space a link from another app opens in. Settings › Spaces & Pins.",
            ],
            better: [
                "Switching spaces is about three times quicker with many tabs.",
                "The accounts under a sign-in box answer ↓, ↑ and Return.",
                "A sideways scroll in Google Sheets scrolls the sheet instead of going back.",
            ],
            fixed: [
                "Swish and other window managers moving the window, and ⌃⌘F.",
                "Teams' Shared tab, PDFs that stopped zooming, and Zotero Connector.",
                "⌘S forgetting the hidden column, and spelling corrected with correction off.",
                "A crash on macOS 27.2.",
            ]
        ),
        Notes(
            version: "1.0.15", date: "18 November 2026",
            headline: "Space gradients, extensions that work, coding agents, and a day of your fixes.",
            new: [
                "A gradient or a stronger colour for a space. The space's menu › Colour….",
                "The same tabs in every window. Settings › Tabs.",
                "⌘1–⌘9 switch spaces, as in Arc. Settings › Spaces & Pins.",
                "Email links open in Gmail, Outlook.com, Fastmail or Proton Mail. Settings › General.",
                "Choose where each extension runs: all sites, some, or on click. Settings › Extensions.",
                "Claude Code or Codex can browse in tabs of their own while you watch. Settings › About › Developer.",
            ],
            better: [
                "Pages load faster with extensions on.",
                "Spread two fingers on a peek to open it as a tab.",
                "A right-click anywhere in the tab column has a menu.",
            ],
            fixed: [
                "Eagle, Cosmos, Raindrop.io, Language Reactor and Voice-over-Translation.",
                "Signing in to X with passkeys off, and 1Password passkeys.",
                "Claude's side panel once signed in.",
                "Extensions reopening their welcome tab at every launch.",
            ]
        ),
        Notes(
            version: "1.0.14", date: "17 November 2026",
            headline: "Live folders, your own style for a site, space colours on the window, and your fixes.",
            new: [
                "Live folders: a folder in the pinned rows that fills itself from a feed. Right-click a pinned row › New Live Folder….",
                "Your own CSS for a site, as Arc's Boosts. Turn it on in Settings › Browsing.",
                "Keep the page as a card in full screen. Settings › Appearance › Window.",
                "⌘-click on a pin opens a new tab, as in Arc. Settings › Spaces & Pins.",
            ],
            better: [
                "A space with a colour gives the window a faint wash of it.",
            ],
            fixed: [
                "⌘1–⌘9 counting a group's closed tabs.",
                "⌫ leaving the page you were typing in.",
                "Extension popups that open themselves, such as Inoreader's.",
            ]
        ),
        Notes(
            version: "1.0.13", date: "17 November 2026",
            headline: "Folders in pinned rows, Split View with four pages, sync between your Macs, and your fixes.",
            new: [
                "Sync your spaces, pins, bookmarks and a few settings between your Macs, through a folder they share. Settings › General.",
                "Folders in pinned rows, as in Arc. Settings › Spaces & Pins.",
                "Capture… in the View menu: a picture of part of a page, or all of it.",
                "Commands in the address field, as Arc's Command Bar.",
                "History › Archived Tabs: the tabs Search closed by itself, for 30 days.",
                "A colour for each space, from the space's menu.",
                "The address field from any app, with a key of your own. Settings › Keyboard & Mouse.",
            ],
            better: [
                "Split View holds up to four pages.",
                "Switching tabs shows the page sooner.",
                "A new install starts with the tabs down the side, and links from other apps in a small window.",
            ],
            fixed: [
                "⌘T opening its page in a group, from an empty tab left there.",
                "A window opened with ⌘N that the menus didn't act on.",
                "Control Panel for YouTube not saving its switches.",
                "The floating video coming back small in its tab.",
                "A link from another app bringing up the browser's window beside its small one.",
            ]
        ),
        Notes(
            version: "1.0.12", date: "9 November 2026",
            headline: "Your contact details in forms, a tab dragged across the top again, and your fixes.",
            new: [
                "Your card in Contacts under a box for your name, email, phone or address, as in Safari. Turn it on in Settings › Passwords.",
                "Open All in New Tabs at the foot of each folder in the Bookmarks menu.",
            ],
            better: [
                "A tab carried off its row or column goes with the pointer.",
                "Pages with many frames load quicker with extensions such as 1Password.",
            ],
            fixed: [
                "A tab across the top that couldn't be dragged, moving the window instead, with Tabs give when pressed on.",
            ]
        ),
        Notes(
            version: "1.0.11", date: "9 November 2026",
            headline: "Send links to a space, a proxy for the whole browser, a quicker window with many tabs, and your fixes.",
            new: [
                "Send links to a space, as in Arc: the sites you choose open in their space, in Settings › Spaces & Pins or a tab's right-click menu.",
                "An HTTP or SOCKS5 proxy for the whole browser, in Settings › Privacy.",
                "Bring Things Over can bring the tabs Helium, Chrome or another Chromium browser has open, with their groups.",
                "⌥-click a tab to put it beside the page in Split View.",
                "Replace a pin's page with the one it shows, from the pin's right-click menu.",
            ],
            better: [
                "Typing in the address field and swiping between spaces stay quick with many tabs open.",
                "Your site shortcuts are offered as you type, like the built-in sites.",
                "The tab column has no scroll bar, as the tabs across the top.",
                "Show how far you've read is off unless you turn it on.",
                "Passkeys and saved passwords are handled more carefully, and the sites you sign in to stay out of the Mac's log.",
            ],
            fixed: [
                "⌘-click opening a link in the same tab on some shops.",
                "The floating video flickering as it pops out of the page.",
                "Closing a window right after using it taking away its space's pins.",
                "And more, from your messages and pull requests.",
            ]
        ),
        Notes(
            version: "1.0.10", date: "8 November 2026",
            headline: "Site permissions in the site card, Claude in Chrome can act in Search, ⇧⌘T brings tabs back as they were, and your fixes.",
            new: [
                "Site Permissions in the site card: camera, microphone, location and notifications, each Ask, Allow or Block.",
                "Codes from Apple's Passwords app under the box that asks for one.",
                "Choose the language pages are translated into, in Settings › Browsing.",
                "Shift-Return searches with a second engine, if you pick one in Settings › Browsing.",
                "Copy Address in a download's right-click menu.",
                "With a site put in the address field with Tab, what you searched there before, read from this Mac only.",
            ],
            better: [
                "The address field says where Return goes, and the key that raised it puts it away.",
                "⇧⌘T brings a tab back with its Back and Forward, and brings back Settings, History and the other pages of Search.",
                "Turning the blocker off for one site is a switch in the site's card.",
                "With Tabs show: Letters, a tab's letter is beside its title.",
                "⌘S slides the column at once, and keeping a bookmark no longer stalls a window with many tabs.",
                "Dragging one of several selected tabs carries them all.",
                "A space's downloads folder is one Downloads submenu in its menu.",
            ],
            fixed: [
                "Claude in Chrome's actions, which all failed with \"No tabs to group\".",
                "Discord signing you out when reloaded with the column out.",
                "A video on a TV or second display floating out when you work in another app on this screen.",
                "A tab carried past another or a Split View pair drifting away from the pointer.",
                "A closed tab's video or music playing on in the background.",
                "uBlock Origin Lite leaving GitLab and similar pages half-drawn.",
                "A waking tab shown zoomed in, and a window stuck after a video's full screen.",
                "And many more, most from your messages and pull requests.",
            ]
        ),
        Notes(
            version: "1.0.9", date: "4 November 2026",
            headline: "Claude in the side panel, profiles in one window, and your fixes.",
            new: [
                "Profiles in one window, as in Arc, if you turn it on in Settings › Spaces & Pins.",
                "Downloads can open floating by its button, or in the side panel.",
                "Delete in a pin's right-click menu.",
            ],
            better: [
                "Claude in Chrome's side panel is signed in when your tabs are.",
                "Address suggestions match words anywhere in a page's title and forgive typos.",
                "⌘R reloads the page in a peek, and a link's menu starts with Open Link in New Tab.",
                "A video floats when you switch spaces, if automatic floating is on.",
            ],
            fixed: [
                "Copy Image copies at once, where a big picture took up to a minute.",
                "Google Docs and Sheets are sharp on macOS 26.3 and earlier.",
                "A pin no longer stays stuck mid-drag, and a page no longer stays shifted after a swipe back.",
                "A page that keeps crashing stops reloading itself and says so.",
                "And many more, most from your messages and pull requests.",
            ]
        ),
        Notes(
            version: "1.0.8", date: "2 November 2026",
            headline: "Your fixes, by the dozen, and a few small things.",
            new: [
                "Open Link in Split View, in a link's right-click menu.",
                "Close Tabs Below, beside Close Other Tabs.",
                "File › Save Page As… keeps a page as one web archive.",
                "Closing a tab can take you back to the one you were on before, if you turn it on.",
            ],
            better: [
                "Bookmarks in the address field as you type, by name or address.",
                "Links opened behind a page go after it in the order you clicked them.",
                "⌘W closes every tab picked in the column; a tab in a group is put away rather than closed.",
                "Closing the last window lets its pages sleep, as Safari and Chrome do.",
            ],
            fixed: [
                "Typing in a new tab no longer stops with a beep after the first letters.",
                "The page under a peek no longer reacts to the pointer.",
                "1Password no longer quits Search on macOS 15; Claude's and ChatGPT's side panels and Vimium C work again.",
                "Picture in picture's button takes you back to the video, and a paused full-screen video takes clicks.",
                "And many more, most from your messages and pull requests.",
            ]
        ),
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
    /// A link from the card (the privacy page), opened in a tab.
    var open: (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// For pictures: the email block's state, and whether it is offered
    /// whatever this Mac remembers.
    var optInStart: OptInForm.Phase = .idle
    var optInEmail = ""
    var optInForced: Bool? = nil

    /// The leading and earlier switches, read once as the card opens
    /// (WhatsNew.rows): one turned on here stays in the list rather than
    /// vanishing under the hand. The version's own are read as they stand.
    @State private var listed: (leading: [WhatsNew.Toggle], own: [WhatsNew.Toggle], earlier: [WhatsNew.Toggle])?
    /// Sync with iCloud's switch is its own, not a preference's.
    @ObservedObject private var icloud = ICloudSync.shared
    /// The email block (OptIn.swift), read once as the card opens: offered
    /// until an email has been given, and kept after one is, for its thanks.
    @State private var offering: Bool?
    @ObservedObject private var reach = OptIn.Reach.shared

    /// Pinned under the list, outside its scroll, so it is always in sight;
    /// left off while the Mac is offline, where a press could only fail.
    private var showsOptIn: Bool { (optInForced ?? offering ?? OptIn.offered()) && (optInForced != nil || reach.online) }

    var body: some View {
        Plate("New in Search \(release.version)", width: 460, close: close) {
            VStack(alignment: .leading, spacing: 14) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        rows((listed?.leading ?? []) + WhatsNew.rows(for: release, prefs: prefs).own)
                        if let earlier = listed?.earlier, !earlier.isEmpty {
                            Caption("From earlier versions, in case you missed them")
                                .padding(.top, 6)
                            rows(earlier)
                        }
                    }
                }
                .frame(maxHeight: showsOptIn ? 360 : 470)
                .fixedSize(horizontal: false, vertical: true)
                if showsOptIn {
                    OptInBlock(source: .whatsNew, open: open, start: optInStart, startEmail: optInEmail)
                }
            }
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
            if offering == nil { offering = OptIn.offered() }
            if listed == nil { listed = WhatsNew.rows(for: release, prefs: prefs) }
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
