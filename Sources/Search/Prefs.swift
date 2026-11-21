import Security
import SwiftUI
import WebKit

// Everything there is to set, in one observable place.
//
// Each of these is a line in the settings file and nothing more; the object
// exists so that a panel can bind to them and the rest of the window can
// redraw when one changes. Defaults are chosen so that a browser nobody has
// configured behaves the way it always did.

/// What a tab wears beside its title, and what a pinned one is reduced to: a
/// letter, or the site's own icon.
enum Glyph: String, CaseIterable, Identifiable {
    case letters, icons

    var id: String { rawValue }

    var title: String {
        switch self {
        case .letters: return "Letters"
        case .icons: return "Site icons"
        }
    }
}

/// Peek uses modified left clicks, leaving plain clicks and Control-click alone.
enum PeekClick: String, CaseIterable {
    case shift, optionShift, optionCommand

    var title: String {
        switch self {
        case .shift: return "Shift-click"
        case .optionShift: return "Option-Shift-click"
        case .optionCommand: return "Option-Command-click"
        }
    }

    var flags: NSEvent.ModifierFlags {
        switch self {
        case .shift: return .shift
        case .optionShift: return [.option, .shift]
        case .optionCommand: return [.option, .command]
        }
    }
}

/// How long a tab you aren't keeping stays open once you leave it (see
/// Closing.swift): never, or one of Arc's four choices, counted in hours.
enum TabLife: Int, CaseIterable, Identifiable {
    case never = 0, halfDay = 12, day = 24, week = 168, month = 720

    var id: Int { rawValue }
    /// Nil when tabs never close.
    var interval: TimeInterval? { self == .never ? nil : TimeInterval(rawValue) * 60 * 60 }

    var title: String {
        switch self {
        case .never: return "Never"
        case .halfDay: return "After 12 hours"
        case .day: return "After a day"
        case .week: return "After a week"
        case .month: return "After a month"
        }
    }
}

/// Where a new tab goes in the row (Settings › Tabs).
enum NewTabPlace: String {
    case next, top, end
}

/// Where Downloads opens: a tab of its own, as it always has; the side
/// panel's card floating by the downloads button; or the side panel,
/// beside the page.
enum DownloadsOpening: String, CaseIterable, Identifiable {
    case tab, popover, panel

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tab: return "In a tab"
        case .popover: return "Floating by the button"
        case .panel: return "In the side panel"
        }
    }
}

/// Which edge the tab column sits on when tabs are arranged in a sidebar.
enum SidebarPosition: String, CaseIterable, Identifiable {
    case left, right

    var id: String { rawValue }

    var title: String {
        switch self {
        case .left: return "Left"
        case .right: return "Right"
        }
    }
}

/// Where the tabs go when the settings have no line for it. Down the side,
/// as Arc has them, for a Search opened for the first time (Drice, 17 Nov
/// 2026); across the top before that. Nobody already using Search sees the
/// tabs move with an update: `settle` writes the old place down for them,
/// once, before the setting is first read.
enum SidebarDefault {
    /// Set at the first launch of a build that knows the new default, fresh
    /// install or not, so `settle` looks only once: a fresh install's second
    /// launch has settings and a session too, and must not be taken for one
    /// from before.
    static let settledKey = "sidebar.settled"

    /// The column, except in a test world: the hidden suites were written
    /// against tabs across the top and set `sidebar` when they want the
    /// column.
    static func fresh(testing: Bool) -> Bool { !testing }

    /// Lines only a Search that has run before leaves behind: the welcome
    /// walked through, a choice of what tabs wear (written by every build
    /// before the welcome existed), and the window's frame AppKit keeps.
    static let traces = ["welcomed", "glyph", "NSWindow Frame search"]

    /// One time only. A Search that ran before this build, with no line for
    /// where its tabs go, had them across the top: that is written down, so
    /// the new default never reaches it. `ranBefore` is whether a session
    /// or windows file is already in the folder.
    static func settle(_ store: UserDefaults, testing: Bool, ranBefore: Bool) {
        guard !store.bool(forKey: settledKey) else { return }
        store.set(true, forKey: settledKey)
        guard fresh(testing: testing),
              store.object(forKey: "sidebar") == nil,
              store.object(forKey: "manner") == nil
        else { return }
        if ranBefore || traces.contains(where: { store.object(forKey: $0) != nil }) {
            store.set(false, forKey: "sidebar")
        }
    }

    /// Whether this folder holds what a Search that has run leaves there.
    static func ranBefore(in folder: URL) -> Bool {
        ["session.json", "windows.json", "pins.json"].contains {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
        }
    }
}

@MainActor
final class Preferences: ObservableObject {
    private let store = Store.settings

    /// Back, forward and reload before the tabs rather than after them, with
    /// the tabs across the top. Off unless asked for.
    @Published var navigationLeft: Bool {
        didSet { store.set(navigationLeft, forKey: "toolbar.left") }
    }

    /// The tab strip only a few points taller than its tabs, where it is
    /// otherwise a toolbar's height (Metrics.strip). With the tabs across the
    /// top; off unless asked for.
    @Published var compactStrip: Bool {
        didSet { store.set(compactStrip, forKey: "tabs.compact") }
    }

    /// A local socket a script can drive the browser through, in tabs of its
    /// own. Off unless asked for — in Settings, which is also what leaves
    /// the mark it needs at launch (see Bench.Consent).
    @Published var bench: Bool {
        didSet {
            store.set(bench, forKey: "bench")
            bench ? Bench.Consent.grant() : Bench.Consent.revoke()
        }
    }
    /// The setting said on at launch with no mark from the switch behind it,
    /// and was put back to off.
    private(set) var benchRefused = false
    /// Coding agents may ask to use the window (AgentControl). Off unless
    /// turned on in Settings, which leaves the mark it needs at launch, as
    /// the bench's switch does.
    @Published var agents: Bool {
        didSet {
            store.set(agents, forKey: "agents")
            agents ? Preferences.agentsMark.grant() : Preferences.agentsMark.revoke()
            // Turned off, or on afresh: nobody is remembered (AgentTrust).
            if agents != oldValue { AgentTrust.shared.forgetAll() }
        }
    }
    static let agentsMark = SwitchMark(service: "com.officecommun.search.agents")
    /// Found on at launch without the mark, and put back to off.
    private(set) var agentsRefused = false
    /// Light, dark, or the Mac's own.
    @Published var look: Look {
        didSet {
            store.set(look.rawValue, forKey: "look")
            look.apply()
        }
    }
    /// The painted wall behind the blank tab (see HomeTheme). Off unless chosen.
    @Published var homeTheme: HomeTheme {
        didSet { store.set(homeTheme.rawValue, forKey: "home.theme") }
    }
    /// The sliders and colours behind it: intensity, density, scale, pack.
    @Published var homeTuning: HomeTuning {
        didSet { store.set(homeTuning.text, forKey: "home.tuning") }
    }
    /// A different wall or sticker pack each day, from the chosen family.
    @Published var homeShuffle: Bool {
        didSet { store.set(homeShuffle, forKey: "home.shuffle") }
    }
    /// Where the chosen picture's copy lives, for the image theme.
    @Published var homeThemeImage: String? {
        didSet {
            if let homeThemeImage { store.set(homeThemeImage, forKey: "home.theme.image") }
            else { store.removeObject(forKey: "home.theme.image") }
        }
    }
    /// Titles down a side instead of across the top.
    @Published var sidebar: Bool {
        didSet { store.set(sidebar, forKey: "sidebar") }
    }
    /// The side panel's width, as you last left it (see SidePanel.swift).
    @Published var sidePanelWidth: CGFloat {
        didSet {
            let kept = min(max(sidePanelWidth, Preferences.sidePanelWidths.lowerBound), Preferences.sidePanelWidths.upperBound)
            if kept != sidePanelWidth { sidePanelWidth = kept; return }
            store.set(Double(sidePanelWidth), forKey: "sidepanel.width")
        }
    }
    /// Which side the column is on when it is shown vertically.
    @Published var sidePosition: SidebarPosition {
        didSet { store.set(sidePosition.rawValue, forKey: "sidebar.position") }
    }
    /// The column folded away whenever the pointer isn't at its edge,
    /// rather than only after ⌘S (see Fold.swift). Off unless asked for.
    @Published var sideHides: Bool {
        didSet { store.set(sideHides, forKey: "sidebar.hides") }
    }
    /// The column slides out and back in a longer, eased slide (Motion.slidesColumn),
    /// where it otherwise snaps out on a short spring. Off unless asked for.
    @Published var slidesColumn: Bool {
        didSet { store.set(slidesColumn, forKey: Motion.slidesKey) }
    }
    /// Taller lines and larger titles in the column, for anyone who finds
    /// the default hard to read (#570). Off unless asked for.
    @Published var roomyTabs: Bool {
        didSet { store.set(roomyTabs, forKey: "sidebar.roomy") }
    }
    /// The foot's doors — spaces, extensions, bookmarks, downloads — up in
    /// the lights' row, right of back, forward and reload, and no foot.
    /// Only where they fit; a column too narrow keeps them at the bottom.
    /// Off unless asked for.
    @Published var doorsUp: Bool {
        didSet { store.set(doorsUp, forKey: "sidebar.doorsUp") }
    }
    /// The column as icons only: each tab its site's mark, no titles, a
    /// fixed narrow width, and nothing that grows under the pointer (idea
    /// 413). Off unless asked for; Settings › Appearance › Tabs, Icons only.
    @Published var sideIcons: Bool {
        didSet { store.set(sideIcons, forKey: "sidebar.icons") }
    }
    /// ⌘S makes the column icons only, and gives it its titles back, rather
    /// than folding it away: the tabs stay in sight (idea 620). Off unless
    /// asked for; Settings › Appearance › Tabs.
    @Published var foldsToIcons: Bool {
        didSet { store.set(foldsToIcons, forKey: "sidebar.foldIcons") }
    }
    /// Whether ⌘S does that as things are set: with the tabs down a side,
    /// and not with the column kept folded, where ⌘S is what brings it out
    /// to stay (see Fold.swift).
    var shrinks: Bool { sidebar && foldsToIcons && !sideHides }
    /// Whether the column is showing as icons now: down a side, and asked for.
    var iconColumn: Bool { sidebar && sideIcons }
    /// The column's width as drawn: fixed with icons only, pulled by its
    /// edge otherwise (the width pulled is kept for when titles come back).
    var columnWidth: CGFloat { iconColumn ? Metrics.iconColumn : sideWidth }
    /// A tab playing sound out of sight shows at the foot of the sidebar,
    /// with its pause (see Player.swift). Off unless asked for.
    @Published var showsPlayer: Bool {
        didSet { store.set(showsPlayer, forKey: "sidebar.player") }
    }
    /// One tab's line in the column, and the size its title is set in.
    var sideRow: CGFloat { iconColumn ? Metrics.iconTile : roomyTabs ? 36 : 28 }
    var sideTitle: CGFloat { roomyTabs ? 14 : 12.5 }
    /// How wide the column is. Pulled by its edge, and remembered.
    @Published var sideWidth: CGFloat {
        didSet { store.set(Double(sideWidth), forKey: "sidebar.width") }
    }
    /// With the tabs down the side, the page as a card: a little room
    /// around it and rounded corners (see CardEdge). On unless turned off,
    /// since 1.0.5 shipped with it; off, the page reaches the window's edges
    /// and the column is white with its hairline, as before 1.0.5 (#607).
    @Published var cards: Bool {
        didSet { store.set(cards, forKey: "layout.cards") }
    }
    /// The page stays a card when the window fills the screen (#1152). Off,
    /// it goes edge to edge there, as asked for on #607.
    @Published var cardsInFullScreen: Bool {
        didSet { store.set(cardsInFullScreen, forKey: "layout.cardsFullScreen") }
    }
    /// The page's address always in sight (see AddressLine.swift).
    @Published var addressLine: Bool {
        didSet { store.set(addressLine, forKey: "address.shown") }
    }
    /// How wide it is before the tabs across the top.
    @Published var addressWidth: AddressWidth {
        didSet { store.set(addressWidth.rawValue, forKey: "address.width") }
    }
    /// The ground the card and the column sit on as glass: what is behind
    /// the window shows through, blurred (see Glass.swift). Off unless
    /// turned on.
    @Published var glass: Bool {
        didSet { store.set(glass, forKey: "window.glass") }
    }
    /// How much grain lies over it, nought to one (GlassGround.mostGrain).
    @Published var glassGrain: Double {
        didSet { store.set(glassGrain, forKey: "window.glass.grain") }
    }
    /// How see-through the glass is: nought, as much of the space's colour
    /// as glass takes (GlassGround.mostTint); one, the glass alone, frosted,
    /// with no colour and no dimming over what shows through. The blur
    /// itself is always there. Chosen in the space's Colour…
    /// (SpaceLookPicker), or in Settings with spaces off.
    @Published var glassClear: Double {
        didSet { store.set(glassClear, forKey: "window.glass.clear") }
    }
    /// The tab you are on under a pane of Liquid Glass that glides from tab
    /// to tab (see LiquidTab.swift). Off unless turned on; macOS 26 on.
    @Published var liquidTabs: Bool {
        didSet { store.set(liquidTabs, forKey: "tabs.liquid") }
    }
    /// Frosted, the Mac's blur since Big Sur, or Liquid Glass, from macOS 26.
    @Published var glassStyle: GlassStyle {
        didSet { store.set(glassStyle.rawValue, forKey: "window.glass.style") }
    }
    @Published var glyph: Glyph {
        didSet { store.set(glyph.rawValue, forKey: "glyph") }
    }
    @Published var engine: Engine {
        didSet { store.set(engine.rawValue, forKey: "search.engine") }
    }
    @Published var customEngine: String {
        didSet { store.set(customEngine, forKey: "search.custom") }
    }
    /// Where Shift-Return in the address field sends the words instead of
    /// the default engine (#848). Nil, as for anyone who never picks one:
    /// Shift-Return is Return, as it always was.
    @Published var shiftEngine: Engine? {
        didSet {
            if let shiftEngine { store.set(shiftEngine.rawValue, forKey: "search.shift") }
            else { store.removeObject(forKey: "search.shift") }
        }
    }
    @Published var shiftCustom: String {
        didSet { store.set(shiftCustom, forKey: "search.shiftCustom") }
    }
    /// Shortcuts to a site's own search, ahead of the default engine (see
    /// Keyword.swift). Empty until someone adds one.
    @Published var keywords: [Keyword] {
        didSet { store.set((try? JSONEncoder().encode(keywords)) ?? Data(), forKey: "search.keywords") }
    }
    /// Always on since the Settings rework (Drice, 24 Oct 2026): it only
    /// adds a command, so there is no switch. Still a property, for the
    /// code that asks and the tests that turn it off; never written.
    @Published var keepsSitesAwake = true
    /// A tab gives a little under the pointer while it is pressed, as Arc's
    /// do (see Give). Off unless turned on.
    @Published var tabsGive: Bool {
        didSet { store.set(tabsGive, forKey: "tabs.give") }
    }
    @Published var awakeSites: Set<String> {
        didSet { store.set(Array(awakeSites).sorted(), forKey: "tabs.awakeSites") }
    }
    /// Sized website pop-ups may use small windows instead of tabs (#552).
    @Published var popupWindows: Bool {
        didSet { store.set(popupWindows, forKey: "tabs.popupWindows") }
    }
    /// Sites whose pages may open windows without a click just before
    /// (BlockedPopups.swift), each a registrable domain. Empty until you
    /// choose Always Allow on one; Settings › Privacy lists them.
    @Published var popupSites: Set<String> {
        didSet { store.set(Array(popupSites).sorted(), forKey: "privacy.popupSites") }
    }
    /// Tabs nobody has looked at for half an hour give their page back and
    /// keep where they were. On unless turned off.
    @Published var sleepsTabs: Bool {
        didSet { store.set(sleepsTabs, forKey: "tabs.sleep") }
    }
    /// A resting tab's title and icon fade until you go to it. Off unless chosen.
    @Published var dimsSleepingTabs: Bool {
        didSet { store.set(dimsSleepingTabs, forKey: "tabs.sleep.dim") }
    }
    /// Tabs you haven't pinned, named or grouped close once left alone this
    /// long, as in Arc. Never unless asked for.
    @Published var tabLife: TabLife {
        didSet { store.set(tabLife.rawValue, forKey: "tabs.close.after") }
    }
    /// How soon they do (see SleepPace). Normal unless chosen.
    @Published var sleepPace: SleepPace {
        didSet { store.set(sleepPace.rawValue, forKey: SleepPace.key) }
    }
    /// A tab opened behind the page — ⌘-click, the middle button, a batch
    /// of links from another app — waits to load until it is gone to, as a
    /// tab brought back from the last session does (see Browser.open).
    /// Off unless asked for.
    /// Settings › Privacy › Let sites ask to send notifications. On: a site
    /// asks on a card, and only what you allow ever reaches the Mac.
    @Published var siteNotifications: Bool {
        didSet { store.set(siteNotifications, forKey: "notifications.ask") }
    }
    @Published var lazyTabs: Bool {
        didSet { store.set(lazyTabs, forKey: "tabs.lazy") }
    }
    /// Closing the last tab that isn't a pin, with pins beside it, leaves a
    /// new tab instead of taking you to a pin (see Browser.close, #537).
    /// Off unless asked for.
    @Published var newTabAfterLast: Bool {
        didSet { store.set(newTabAfterLast, forKey: "tabs.newAfterLast") }
    }
    /// Closing the tab on screen goes back to the one viewed before it
    /// rather than the neighbour (see Browser.close). Off unless asked for.
    @Published var closeGoesBack: Bool {
        didSet { store.set(closeGoesBack, forKey: "tabs.closeGoesBack") }
    }
    /// ⌘Z reopens the tab just closed, as in Safari, while closing it is
    /// still the last thing done (Browser.lastClose). Off unless asked for.
    @Published var undoReopensTab: Bool {
        didSet { store.set(undoReopensTab, forKey: "tabs.undoReopens") }
    }
    /// ⌃Tab shows a link opened behind the page right after the page, so a
    /// quick ⌃Tab goes to it; off, the tab left last keeps that place and
    /// the link comes next (see TabSwitcher.ordered). Off unless asked for.
    @Published var switcherBehindFirst: Bool {
        didSet { store.set(switcherBehindFirst, forKey: "tabs.switcherBehindFirst") }
    }
    /// The ⌃Tab switcher leaves out pinned tabs, showing only regular open
    /// tabs (see Browser.switcherRow). Off unless asked for (#1110).
    @Published var switcherLeavesOutPins: Bool {
        didSet { store.set(switcherLeavesOutPins, forKey: "tabs.switcherLeavesOutPins") }
    }
    /// Where a new tab goes in the row. Next unless asked for.
    @Published var newTabPlace: NewTabPlace {
        didSet { store.set(newTabPlace.rawValue, forKey: "tabs.newPlace") }
    }
    /// With After current, a page a link opens in front goes right after
    /// the page it came from, as a ⌘-click's does, rather than to the end
    /// of the row (see Browser.frontLinksBeside). Off unless asked for.
    @Published var frontLinksBeside: Bool {
        didSet { store.set(frontLinksBeside, forKey: "tabs.frontBeside") }
    }
    /// Every window of a profile lists the same open tabs in each space, as
    /// it lists the same pins: opened, closed, moved, grouped or renamed in
    /// one, so in the others (see Twins.swift). Off unless asked for.
    @Published var mirrorsTabs: Bool {
        didSet { store.set(mirrorsTabs, forKey: "tabs.mirror") }
    }
    /// Each launch starts with a fresh window: the pins stay, last time's
    /// other tabs don't come back (see Session.startFresh). Off unless
    /// asked for (#406).
    @Published var startsFresh: Bool {
        didSet { store.set(startsFresh, forKey: Preferences.freshKey) }
    }
    nonisolated static let freshKey = "start.fresh"
    /// Ask before the Quit menu or ⌘Q closes the app. Off unless asked for.
    @Published var confirmsQuit: Bool {
        didSet { store.set(confirmsQuit, forKey: Preferences.confirmQuitKey) }
    }
    nonisolated static let confirmQuitKey = "quit.confirm"
    /// Search a site from the address field: the start of its name, then
    /// Tab (see SiteSearch.swift).
    /// Always on since the Settings rework (Drice, 24 Oct 2026): it only
    /// adds a command, so there is no switch. Still a property, for the
    /// code that asks and the tests that turn it off; never written.
    @Published var searchesSites = true
    /// Suggestions from the search engine under the address field, as you
    /// type (see EngineSuggest.swift). Off unless asked for: what is typed
    /// is sent to the engine while it is typed.
    @Published var engineSuggests: Bool {
        didSet { store.set(engineSuggests, forKey: "search.suggest") }
    }
    /// Numbers beside tabs while Command is held. Off unless asked for.
    @Published var showsTabShortcuts: Bool {
        didSet { store.set(showsTabShortcuts, forKey: "tabs.shortcuts") }
    }
    @Published var showsReading: Bool {
        didSet { store.set(showsReading, forKey: "tabs.reading") }
    }
    /// Tab titles in full ink (black or white) instead of the soft greys
    /// used for tabs that aren't the one you're on. Off unless asked for.
    @Published var highContrastText: Bool {
        didSet { store.set(highContrastText, forKey: "tabs.highContrast") }
    }
    /// The tab you're on says where its page is, at rest, without a click:
    /// its site, from the address on screen (see AtRest.swift). On unless
    /// turned off.
    @Published var showsAddress: Bool {
        didSet { store.set(showsAddress, forKey: "tabs.address") }
    }
    /// The ad blocker. On unless turned off; there is nothing else to it.
    @Published var shielded: Bool {
        didSet { store.set(shielded, forKey: "shield") }
    }
    /// Settings › Privacy › Prevent cross-site tracking, turned off: WebKit's
    /// tracking prevention off, as Safari's same switch does (see
    /// Store.keepsSignIns). On unless turned off.
    @Published var keepsSignIns: Bool {
        didSet {
            store.set(keepsSignIns, forKey: "sites.keep")
            Store.keepsSignIns = keepsSignIns
        }
    }
    /// Global Privacy Control sent with every request (see Privacy.swift).
    /// On unless turned off.
    @Published var sendsPrivacySignal: Bool {
        didSet {
            store.set(sendsPrivacySignal, forKey: "privacy.gpc")
            PrivacySignal.on = sendsPrivacySignal
        }
    }
    /// Ad-click IDs taken off links before the page loads (see
    /// Privacy.swift). On unless turned off.
    @Published var removesClickIDs: Bool {
        didSet {
            store.set(removesClickIDs, forKey: "privacy.clickIDs")
            ClickIDs.on = removesClickIDs
        }
    }
    /// Whether sites may ask for a passkey here. Off sends them to the
    /// password instead — the only thing that works in a build without
    /// Apple's browser entitlement.
    @Published var passkeys: Bool {
        didSet { store.set(passkeys, forKey: "passkeys") }
    }
    /// Whether this build can actually do them: signed with the entitlement,
    /// its profile embedded. Fixed for the life of the process.
    let passkeysPossible: Bool

    /// Asked of the running process's own signature, which is the only thing
    /// that decides it — a profile file in the bundle proves nothing on its
    /// own, and an ad-hoc build has neither.
    static var entitledToPasskeys: Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let value = SecTaskCopyValueForEntitlement(
            task, "com.apple.developer.web-browser.public-key-credential" as CFString, nil
        )
        return (value as? Bool) == true
    }
    @Published var downloads: URL {
        didSet { store.set(downloads.path, forKey: "downloads") }
    }
    @Published var asksWhereToSave: Bool {
        didSet { store.set(asksWhereToSave, forKey: "downloads.ask") }
    }
    /// Offer to keep a password the first time a site sees it.
    @Published var savesPasswords: Bool {
        didSet { store.set(savesPasswords, forKey: "passwords.save") }
    }
    /// Put a kept name and password into a sign-in as soon as one appears.
    @Published var fillsPasswords: Bool {
        didSet { store.set(fillsPasswords, forKey: "passwords.fill") }
    }
    /// Your card in Contacts under the boxes for your name, email, phone and
    /// address (MeCard). Off unless turned on, which is when macOS asks.
    @Published var fillsContacts: Bool {
        didSet {
            store.set(fillsContacts, forKey: "contacts.fill")
            FormRelay.contacts = fillsContacts
        }
    }
    /// Accounts from the Mac's Passwords app under the sign-in box too, by
    /// Apple's helper for its Chrome extension (ApplePasswords.swift). Off
    /// unless turned on: unofficial, and it pairs with a code.
    @Published var applePasswords: Bool {
        didSet { store.set(applePasswords, forKey: "passwords.apple") }
    }
    /// The first launch has been walked through. Until then the welcome
    /// stands over the window.
    @Published var welcomed: Bool {
        didSet { store.set(welcomed, forKey: "welcomed") }
    }
    /// macOS's own autocorrect, inside web pages: the little "Not ×" that
    /// capitalises what you meant to leave lower-case. As the Mac has it
    /// (System Settings › Keyboard › Correct spelling automatically) until
    /// the switch here is used.
    @Published var autocorrect: Bool {
        didSet {
            store.set(autocorrect, forKey: "autocorrect")
            // Every page, open and to come: WebKit's one switch for them all.
            Preferences.switchWebKit(autocorrect: autocorrect)
        }
    }
    /// How big every site is drawn until it has been zoomed on its own.
    @Published var pageZoom: Double {
        didSet { store.set(pageZoom, forKey: "pageZoom") }
    }
    /// View › Actual Size goes to that zoom, as in Safari; away from 100%
    /// its title says where (#1210).
    var actualSizeTitle: String {
        let percent = Int((pageZoom * 100).rounded())
        return percent == 100 ? "Actual Size" : "Actual Size (\(percent)%)"
    }
    /// The stops the setting steps through — every 5%, from as small as
    /// anyone reads to as big as a page is worth.
    static let zooms: [Double] = stride(from: 50, through: 300, by: 5).map { Double($0) / 100 }

    /// Pages with no dark look of their own darkened while the frame is
    /// dark (see Dusk.swift). Off unless asked for.
    @Published var darkensPages: Bool {
        didSet {
            store.set(darkensPages, forKey: "pages.dusk")
            Dusk.shared.on = darkensPages
        }
    }

    /// Capture… in the View menu (see Snap.swift). Off unless asked for.
    @Published var capturesPages: Bool {
        didSet { store.set(capturesPages, forKey: "pages.capture") }
    }

    /// Your own style for a site, Edit Site Style… in the View menu (see
    /// SiteStyles.swift). Off unless asked for; off, the styles are kept.
    @Published var sitesStyles: Bool {
        didSet {
            store.set(sitesStyles, forKey: "sites.styles")
            SiteStyles.shared.on = sitesStyles
        }
    }

    /// Chrome's colors on the Web Inspector (see Inspector.swift). Off
    /// unless asked for, so the inspector stays as it comes.
    @Published var inspectorChrome: Bool {
        didSet {
            store.set(inspectorChrome, forKey: "inspector.chrome")
            guard inspectorChrome != oldValue else { return }
            Browser.coatOpenInspectors()
        }
    }

    /// The Web Inspector stays dark while Search is light. Off, it follows
    /// Appearance. Off unless asked for.
    @Published var inspectorDark: Bool {
        didSet {
            store.set(inspectorDark, forKey: "inspector.dark")
            guard inspectorDark != oldValue else { return }
            Browser.coatOpenInspectors()
        }
    }

    /// A click of the wheel scrolls the page as on Windows (see AutoScroll.swift).
    /// Off unless asked for.
    @Published var autoScroll: Bool {
        didSet {
            store.set(autoScroll, forKey: "autoscroll")
            AutoScroll.on = autoScroll
        }
    }
    /// Pages bounce at their top and bottom, as in Safari, rather than stop
    /// there (see Swipe.calm). Off unless asked for.
    @Published var bounces: Bool {
        didSet {
            store.set(bounces, forKey: "pages.bounce")
            Swipe.bounces = bounces
        }
    }
    /// Pages draw at 120 frames a second on a screen that can (see FrameRate.swift).
    /// On power unless chosen otherwise.
    @Published var fastPages: FastPages {
        didSet {
            store.set(fastPages.rawValue, forKey: "pages.120.mode")
            FrameRate.mode = fastPages
        }
    }
    /// Springs become a short ease-out in Low Power Mode (see Motion.light),
    /// and idle tabs sleep after Sooner's ten minutes at most (see
    /// Motion.savingPower). Off unless turned on, and even then nothing
    /// changes until the Mac is asked to save power.
    @Published var lightMotion: Bool {
        didSet { store.set(lightMotion, forKey: Motion.lightKey) }
    }
    /// Every transition immediate, whatever the Mac's Reduce Motion says
    /// (see Motion.instant). Off unless turned on.
    @Published var instantMotion: Bool {
        didSet {
            store.set(instantMotion, forKey: Motion.instantKey)
            Motion.instant = instantMotion
        }
    }
    /// The modifier chosen in Settings › Shortcuts; Shift-click by default.
    @Published var peekClick: PeekClick {
        didSet { store.set(peekClick.rawValue, forKey: "links.peekClick") }
    }
    /// Open a clicked link over the page (see Peek.swift). On unless turned off.
    @Published var peeksLinks: Bool {
        didSet { store.set(peeksLinks, forKey: "links.peek") }
    }
    /// A peek stays with the tab it was opened from: another tab hides it,
    /// and coming back shows it (see Browser.peekInFront). Its page stays
    /// loaded while hidden, its video and sound paused (Browser.followPeek).
    /// A change to how a peek goes away, so off unless asked for.
    @Published var peekStays: Bool {
        didSet { store.set(peekStays, forKey: "links.peek.stays") }
    }
    /// ⌥-click on a link opens it in Split View, as its menu's Open Link in
    /// Split View does (see Browser.openLinkBeside). Safari's ⌥-click
    /// downloads the link instead, so off unless asked for; off, a ⌥-click
    /// follows the link as before.
    @Published var optionClickSplits: Bool {
        didSet { store.set(optionClickSplits, forKey: "links.optionSplit") }
    }
    /// Pins as in Arc: a link from a pinned tab to another site opens in a
    /// peek, so the pin stays on its page (see Peek.swift), and ⌘W takes it
    /// back to the page it was pinned at. Half of "Pins keep their site"
    /// (Preferences.pinsKeepSite), on unless turned off.
    @Published var pinsPeek: Bool {
        didSet { store.set(pinsPeek, forKey: "pins.peek") }
    }
    /// Reading mode shows a site's own markdown copy of the page when it
    /// publishes one, and works the article out only when it doesn't (see
    /// Reader.twin). Off unless asked for.
    @Published var readsTwins: Bool {
        didSet { store.set(readsTwins, forKey: "reader.twins") }
    }
    /// Reading mode goes dark with the window, with a light/dark/window
    /// switch in its corner (see ReaderLook). Off unless asked for: the
    /// article is white, as it always was.
    @Published var readerFollowsLook: Bool {
        didSet { store.set(readerFollowsLook, forKey: "reader.follows") }
    }
    /// A link from another app opens in a small window of its own (see
    /// Little.swift). On for a new install, off as it was for one from
    /// before (see settleLittleLinks).
    @Published var littleLinks: Bool {
        didSet { store.set(littleLinks, forKey: Preferences.littleKey) }
    }
    nonisolated static let littleKey = "links.little"

    /// Small windows for links became the default for new installs (Drice,
    /// 17 Nov 2026); an install from before keeps its links in the browser's
    /// window, as they always went, rather than finding them changed by an
    /// update. Settled once, the first time a build with this runs: no line
    /// yet, and a line from an earlier launch (the welcome walked through,
    /// a glyph chosen, or the passkey lines every launch has written since
    /// 1.0.1) means an install from before, which gets its old value, off,
    /// written down. A new one gets on, written down too, so the next launch
    /// (which finds those lines) doesn't take it for an old one. A choice
    /// already made stands. Before anything else in init writes a line.
    nonisolated static func settleLittleLinks(in store: UserDefaults) {
        guard store.object(forKey: littleKey) == nil else { return }
        let before = ["welcomed", "glyph", "passkeys.for", "passkeys.entitled"].contains { store.object(forKey: $0) != nil }
        store.set(!before, forKey: littleKey)
    }
    /// The webmail email links open in (see Webmail.swift). None unless
    /// asked for: the Mac's mail app, as before.
    @Published var webmail: Webmail {
        didSet { store.set(webmail.rawValue, forKey: "mail.webmail") }
    }
    /// With those small windows on: a link to a page already open in a tab
    /// goes to that tab instead (see Links.little). Off unless asked for.
    @Published var littleFindsTabs: Bool {
        didSet { store.set(littleFindsTabs, forKey: "links.little.tabs") }
    }
    /// Links to chosen sites open in their space (see SpaceRoutes.swift).
    /// Off unless asked for, and only with spaces on.
    @Published var sendsLinksToSpaces: Bool {
        didSet { store.set(sendsLinksToSpaces, forKey: SpaceRoutes.key) }
    }
    /// Which site goes to which space, for that.
    @Published var spaceRoutes: [SpaceRoute] {
        didSet { store.set(spaceRoutes.map(\.plist), forKey: SpaceRoutes.rulesKey) }
    }
    /// With links from other apps: ask which space each opens in, before it
    /// loads (see LinkChooser.swift). Off unless asked for.
    @Published var asksSpaceForLinks: Bool {
        didSet { store.set(asksSpaceForLinks, forKey: "links.ask") }
    }
    /// Where each site went last, newest first, for that panel to pick first.
    @Published var linkChoices: [LinkChooser.Choice] {
        didSet { store.set(linkChoices.map(\.plist), forKey: "links.ask.last") }
    }
    /// The downloads button always in the chrome, not only while something
    /// downloads (see Fetching.swift). Off unless asked for.
    @Published var alwaysShowsDownloads: Bool {
        didSet { store.set(alwaysShowsDownloads, forKey: "downloads.button") }
    }
    /// Where Downloads opens, from its button, ⇧⌘J or the menu (see
    /// Browser.showDownloads). A tab unless asked for.
    @Published var downloadsOpening: DownloadsOpening {
        didSet { store.set(downloadsOpening.rawValue, forKey: "downloads.open") }
    }
    /// The bookmarks bar above the page (see BookmarksBar.swift). Off
    /// unless asked for.
    @Published var bookmarksBar: Bool {
        didSet { store.set(bookmarksBar, forKey: "bookmarks.bar") }
    }
    /// Where a link goes, at the bottom of the page while the pointer is on
    /// it (see StatusLine.swift). On unless turned off.
    @Published var showsLinks: Bool {
        didSet {
            store.set(showsLinks, forKey: "links.show")
            HoveredLink.on = showsLinks
        }
    }
    /// A back or forward swipe held once armed shows the pages that way to
    /// pick from (see PageView.openList). On unless turned off.
    @Published var holdsHistory: Bool {
        didSet {
            store.set(holdsHistory, forKey: "swipe.history")
            PageView.holdsHistory = holdsHistory
        }
    }
    /// Two fingers flick the floating video to a corner (see Float.swift).
    /// On unless turned off.
    @Published var floatFlicks: Bool {
        didSet {
            store.set(floatFlicks, forKey: "float.flicks")
            Float.flicks = floatFlicks
        }
    }
    /// A button on the floating video tucks it into a corner (see Float.swift).
    /// Off unless asked for.
    @Published var floatMinimizes: Bool {
        didSet {
            store.set(floatMinimizes, forKey: "float.minimize")
            Float.minimizes = floatMinimizes
        }
    }
    /// A video playing floats out when another app comes to the front, and
    /// back when Search does (see Browser.appLeft). Off unless asked for.
    @Published var floatsAway: Bool {
        didSet { store.set(floatsAway, forKey: "float.away") }
    }
    /// Videos wait for a click instead of starting by themselves, as Safari's
    /// Never Auto-Play has it (see Web.configuration). Off unless asked for.
    @Published var waitsForPlay: Bool {
        didSet { store.set(waitsForPlay, forKey: Preferences.waitsKey) }
    }
    nonisolated static let waitsKey = "media.click"
    /// Translate Page in the page's right-click menu, on this Mac only
    /// (Translate.swift).
    /// Always on since the Settings rework (Drice, 24 Oct 2026): it only
    /// adds a command, so there is no switch. Still a property, for the
    /// code that asks and the tests that turn it off; never written.
    @Published var translatesPages = true
    /// Empty follows the Mac's preferred language.
    @Published var translateTarget: String {
        didSet { store.set(translateTarget, forKey: "translate.target") }
    }
    /// The languages whose pages are translated as they open, chosen from
    /// the translated sign's menu (never from a private tab). None at first.
    @Published var translateAlways: Set<String> {
        didSet { store.set(Array(translateAlways).sorted(), forKey: PageTranslator.alwaysKey) }
    }
    /// A video playing on a video site comes out into the floating window
    /// when you go to another tab (Browser.leaving). On, as it always was;
    /// the switch is for turning it off.
    @Published var floatsOnLeave: Bool {
        didSet { store.set(floatsOnLeave, forKey: "float.leave") }
    }
    /// Websites in the side panel (SidePanel.swift).
    /// Always on since the Settings rework (Drice, 24 Oct 2026): it only
    /// adds a command, so there is no switch. Still a property, for the
    /// code that asks and the tests that turn it off; never written.
    @Published var sitesInPanel = true
    /// The website last put in the side panel, for View › Side Panel.
    @Published var panelSite: String {
        didSet { store.set(panelSite, forKey: "panel.site") }
    }
    /// Which window a floating video goes into: Search's own, as it always
    /// was, or macOS's picture in picture (see NativePiP.swift).
    @Published var floatStyle: FloatStyle {
        didSet {
            store.set(floatStyle.rawValue, forKey: "float.style")
            NativePiP.allowEverywhere()
        }
    }
    /// Escape on a page filling the screen leaves only when pressed twice
    /// within two seconds, as in Arc; the first puts up a reminder (see
    /// FullScreenEscape). Off unless asked for: one press leaves, as in
    /// Safari.
    @Published var escapeTwice: Bool {
        didSet { store.set(escapeTwice, forKey: "fullscreen.escapeTwice") }
    }
    /// The window stays whole and in use on its own desktop while a page
    /// fills the screen on another, its other tabs in reach (see
    /// Browser.fillsHere). Off unless asked for: the window steps aside
    /// behind the video, as in Safari.
    @Published var keepsWindow: Bool {
        didSet { store.set(keepsWindow, forKey: "fullscreen.keepsWindow") }
    }
    /// A newer build is fetched, checked and put in place on its own, as it
    /// always was. Off, Search still looks every hour and says so, and waits
    /// for Install in Settings (see Updater.installsOnItsOwn).
    @Published var installsUpdates: Bool {
        didSet {
            store.set(installsUpdates, forKey: Updater.installKey)
            // Switched back on with one waiting: it goes in now.
            if installsUpdates { Updater.shared.install() }
        }
    }
    /// Separate sets of tabs, each with its own sign-ins (see Spaces.swift).
    /// Off unless asked for.
    @Published var usesSpaces: Bool {
        didSet { store.set(usesSpaces, forKey: "spaces") }
    }
    /// ⌘1–⌘9 switch spaces and ⌃1–⌃9 pick tabs, as in Arc: the two swapped,
    /// while spaces are on (KeyCombo.spacesOnCommand). Off unless asked for.
    @Published var spacesOnCommand: Bool {
        didSet { store.set(spacesOnCommand, forKey: Preferences.spacesOnCommandKey) }
    }
    static let spacesOnCommandKey = "spaces.commandNumbers"
    /// Profiles in one window (see OneWindow.swift): a space of another
    /// profile, chosen, brings that profile's window into this one's place.
    /// Off unless asked for; turned off, the windows tucked away come out.
    @Published var profilesInOneWindow: Bool {
        didSet {
            store.set(profilesInOneWindow, forKey: "profiles.oneWindow")
            if oldValue, !profilesInOneWindow { Browsers.unmerge() }
        }
    }
    /// Named, collapsible sections in the sidebar.
    /// Always on since the Settings rework (Drice, 24 Oct 2026): it only
    /// adds a command, so there is no switch. Still a property, for the
    /// code that asks and the tests that turn it off; never written.
    @Published var usesTabGroups = true
    /// Arc's three tiers in the sidebar: the squares, pins kept as rows
    /// under them, and a line with Clear above the tabs that come and go
    /// (see Tab.listed). Off unless asked for.
    @Published var listsPins: Bool {
        didSet { store.set(listsPins, forKey: "pins.list") }
    }
    /// Folders among the pinned rows, as in Arc's pinned list (see
    /// PinFolders.swift): Arc's folders come in as folders of rows rather
    /// than as tab groups. Off unless asked for; without Pinned rows it
    /// does nothing.
    @Published var pinFolders: Bool {
        didSet { store.set(pinFolders, forKey: "pins.folders") }
    }
    /// A pin goes back to the page it was pinned at when it is closed with
    /// ⌘W and when Search opens again, as Arc's pins do, rather than keeping
    /// wherever it was taken since. The other half of "Pins keep their
    /// site", on unless turned off.
    @Published var pinsGoHome: Bool {
        didSet { store.set(pinsGoHome, forKey: "pins.home") }
    }
    /// ⌘-click on a pin opens a new tab at its address (or moves a wandered
    /// pin into the loose tabs), as in Arc. Off, ⌘-click adds the pin to the
    /// tab selection.
    @Published var pinCommandOpensTab: Bool {
        didSet { store.set(pinCommandOpensTab, forKey: "pins.commandNewTab") }
    }
    /// A pin's ⌘ number pressed again, on that pin, goes back to the tab
    /// you were on before it.
    /// Always on since the Settings rework (Drice, 24 Oct 2026): it only
    /// adds a command, so there is no switch. Still a property, for the
    /// code that asks and the tests that turn it off; never written.
    @Published var pinNumberGoesBack = true
    /// Whether the pinned rows are drawn as rows: asked for, and with the
    /// tabs down the side. Across the top every pin is a square.
    var showsPinRows: Bool { listsPins && sidebar }
    /// Whether the pinned rows are drawn in their folders.
    var showsPinFolders: Bool { pinFolders && showsPinRows }
    /// Pins every space shows above its own, as Arc's favourites sit above
    /// every space (see Pins.shared).
    /// Always on since the Settings rework (Drice, 24 Oct 2026): it only
    /// adds a command, so there is no switch. Still a property, for the
    /// code that asks and the tests that turn it off; never written.
    @Published var sharesPins = true
    /// Whether the shared pins are in the rows: asked for, and with Spaces
    /// on. Off, they wait in pins.json for the switch to come back.
    var showsSharedPins: Bool { sharesPins && usesSpaces }
    /// The AI add-on: summaries of the page and questions about it (see
    /// AIAssist). Off unless asked for; nothing is sent until you ask.
    @Published var ai: Bool {
        didSet {
            // Never on in a build without it (AI.shipped); a test run's
            // bench may still turn it on to exercise the code.
            if ai, !AI.shipped, !Store.testing { ai = false; return }
            store.set(ai, forKey: "ai")
        }
    }
    /// Where its answers come from. None until you choose.
    @Published var aiProvider: AIProvider? {
        didSet { store.set(aiProvider?.rawValue, forKey: "ai.provider") }
    }
    /// The model asked for at each provider, where it isn't the default.
    @Published private(set) var aiModels: [String: String] {
        didSet { store.set(aiModels, forKey: "ai.models") }
    }

    func aiModel(for provider: AIProvider) -> String {
        let chosen = (aiModels[provider.rawValue] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return chosen.isEmpty ? provider.defaultModel : chosen
    }

    /// A model's name, and nothing that isn't one: no spaces, no key pasted
    /// into the wrong field (which would go out in a request).
    func setAIModel(_ model: String, for provider: AIProvider) {
        let name = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let looksLikeKey = ["sk-", "AIza", "AQ.", "gsk_", "hf_"].contains { name.hasPrefix($0) } || name.count > 100
        guard name.isEmpty || (!looksLikeKey && name.range(of: #"^[A-Za-z0-9._:/@\-]+$"#, options: .regularExpression) != nil)
        else { return }
        aiModels[provider.rawValue] = name
    }

    /// Two pages share one place in the tab row.
    /// Always on since the Settings rework (Drice, 24 Oct 2026): it only
    /// adds a command, so there is no switch. Still a property, for the
    /// code that asks and the tests that turn it off; never written.
    @Published var splitView = true
    /// ⌃W, ⌃R, ⌃M and ⌃O on the ⌃Tab switcher's card picked, with the keys
    /// listed under the tabs (see TabSwitcher.Action).
    /// Always on since the Settings rework (Drice, 24 Oct 2026): it only
    /// adds a command, so there is no switch. Still a property, for the
    /// code that asks and the tests that turn it off; never written.
    @Published var switcherKeys = true
    /// The page in front offered to your iPhone, iPad and other Macs
    /// through Handoff (see Handoff.swift). Off unless asked for: its
    /// address leaves this Mac, if only for your own devices.
    @Published var handoff: Bool {
        didSet { store.set(handoff, forKey: "handoff") }
    }
    /// "settings", "new tab" and the like, typed alone in the address field,
    /// reach that part of the app instead of asking a search engine for the
    /// word; part of one is offered (see AddressCommands.swift). Off unless
    /// asked for.
    @Published var commandBar: Bool {
        didSet { store.set(commandBar, forKey: "commandbar") }
    }
    /// ⌘T raises the field over the page you are on, as in Arc, and a tab is
    /// only made once Return sends it somewhere. Escape, ⌘W or a click
    /// outside puts the field away and leaves you where you were. Off unless
    /// asked for.
    @Published var floatingNewTab: Bool {
        didSet { store.set(floatingNewTab, forKey: "newtab.floating") }
    }
    /// The address field from any app, as Spotlight's comes: a key of your
    /// own raises it over the app in front, and Return opens what was typed
    /// in Search (see Launcher.swift). Off unless asked for, and no key
    /// taken from the Mac until one is chosen (#783).
    @Published var launcher: Bool {
        didSet { store.set(launcher, forKey: "launcher.on") }
    }
    /// Return in that field opens the page in a small window of its own
    /// (Little.swift) over the app you're in, as Arc's ⌥⌘N opens Little Arc,
    /// rather than in Search's window. Off unless asked for.
    @Published var launcherLittle: Bool {
        didSet { store.set(launcherLittle, forKey: "launcher.little") }
    }
    /// The key it is on, chosen in Settings. None until then.
    @Published var launcherKey: LauncherKey? {
        didSet {
            if let launcherKey, let data = try? JSONEncoder().encode(launcherKey) {
                store.set(data, forKey: "launcher.key")
            } else {
                store.removeObject(forKey: "launcher.key")
            }
        }
    }
    /// The floating field lists the last few places from History before
    /// anything is typed (Browser.recentPlaces). Off unless asked for.
    @Published var recentInNewTab: Bool {
        didSet { store.set(recentInNewTab, forKey: "newtab.recent") }
    }

    init() {
        Preferences.settleLittleLinks(in: store)
        navigationLeft = store.bool(forKey: "toolbar.left")
        compactStrip = store.bool(forKey: "tabs.compact")
        // Carried over from when there were four ways of holding the browser
        // and this was one of them.
        // The Mac's own unless asked otherwise — a Mac in dark mode expects
        // a dark browser, pages included.
        let scripted = store.bool(forKey: "bench")
        let allowed = scripted && (Store.testing || Bench.Consent.given)
        bench = allowed
        if scripted, !allowed {
            benchRefused = true
            store.set(false, forKey: "bench")
        }
        let agentsAsked = store.bool(forKey: "agents")
        let agentsAllowed = agentsAsked && (Store.testing || Preferences.agentsMark.given)
        agents = agentsAllowed
        if agentsAsked, !agentsAllowed {
            agentsRefused = true
            store.set(false, forKey: "agents")
        }
        let chosen = store.string(forKey: "look").flatMap(Look.init) ?? .system
        look = chosen
        homeTheme = store.string(forKey: "home.theme").flatMap(HomeTheme.stored) ?? .off
        homeThemeImage = store.string(forKey: "home.theme.image")
        homeShuffle = store.bool(forKey: "home.shuffle")
        homeTuning = HomeTuning.read(store.string(forKey: "home.tuning")) ?? HomeTuning()
        // Before the first window, and not deferred: the window that is about
        // to be made should be made in the right appearance. Through `shared`
        // rather than `NSApp`: on macOS 14 SwiftUI builds this before it has
        // made the application, and `NSApp` is still nil here.
        NSApplication.shared.appearance = chosen.appearance
        sidePanelWidth = min(max(CGFloat(store.object(forKey: "sidepanel.width") as? Double ?? 380),
                                 Preferences.sidePanelWidths.lowerBound), Preferences.sidePanelWidths.upperBound)
        SidebarDefault.settle(store, testing: Store.testing, ranBefore: SidebarDefault.ranBefore(in: Store.folder))
        sidebar = store.object(forKey: "sidebar") as? Bool
            ?? store.string(forKey: "manner").map { $0 == "side" }
            ?? SidebarDefault.fresh(testing: Store.testing)
        sidePosition = store.string(forKey: "sidebar.position").flatMap(SidebarPosition.init) ?? .left
        sideHides = store.bool(forKey: "sidebar.hides")
        slidesColumn = store.bool(forKey: Motion.slidesKey)
        roomyTabs = store.bool(forKey: "sidebar.roomy")
        doorsUp = store.bool(forKey: "sidebar.doorsUp")
        sideIcons = store.bool(forKey: "sidebar.icons")
        foldsToIcons = store.bool(forKey: "sidebar.foldIcons")
        showsPlayer = store.bool(forKey: "sidebar.player")
        let width = store.object(forKey: "sidebar.width") as? Double ?? Double(Metrics.side)
        sideWidth = min(Metrics.sideMax, max(Metrics.sideMin, CGFloat(width)))
        cards = store.object(forKey: "layout.cards") as? Bool ?? true
        cardsInFullScreen = store.bool(forKey: "layout.cardsFullScreen")
        addressLine = store.bool(forKey: "address.shown")
        addressWidth = store.string(forKey: "address.width").flatMap(AddressWidth.init) ?? .small
        glass = store.bool(forKey: "window.glass")
        glassGrain = (store.object(forKey: "window.glass.grain") as? Double).map { min(1, max(0, $0)) } ?? 0.2
        glassClear = (store.object(forKey: "window.glass.clear") as? Double).map { min(1, max(0, $0)) } ?? 0.5
        glassStyle = store.string(forKey: "window.glass.style").flatMap(GlassStyle.init) ?? .frosted
        liquidTabs = store.bool(forKey: "tabs.liquid")
        glyph = store.string(forKey: "glyph").flatMap(Glyph.init) ?? .letters
        engine = store.string(forKey: "search.engine").flatMap(Engine.init) ?? .standard
        customEngine = store.string(forKey: "search.custom") ?? ""
        shiftEngine = store.string(forKey: "search.shift").flatMap(Engine.init)
        shiftCustom = store.string(forKey: "search.shiftCustom") ?? ""
        keywords = store.data(forKey: "search.keywords")
            .flatMap { try? JSONDecoder().decode([Keyword].self, from: $0) } ?? []
        tabsGive = store.bool(forKey: "tabs.give")
        awakeSites = Set(store.stringArray(forKey: "tabs.awakeSites") ?? [])
        popupWindows = store.bool(forKey: "tabs.popupWindows")
        popupSites = Set(store.stringArray(forKey: "privacy.popupSites") ?? [])
        sleepsTabs = store.object(forKey: "tabs.sleep") as? Bool ?? true
        dimsSleepingTabs = store.bool(forKey: "tabs.sleep.dim")
        tabLife = TabLife(rawValue: store.integer(forKey: "tabs.close.after")) ?? .never
        sleepPace = SleepPace.chosen
        lazyTabs = store.bool(forKey: "tabs.lazy")
        newTabAfterLast = store.bool(forKey: "tabs.newAfterLast")
        closeGoesBack = store.bool(forKey: "tabs.closeGoesBack")
        undoReopensTab = store.bool(forKey: "tabs.undoReopens")
        switcherBehindFirst = store.bool(forKey: "tabs.switcherBehindFirst")
        switcherLeavesOutPins = store.bool(forKey: "tabs.switcherLeavesOutPins")
        frontLinksBeside = store.bool(forKey: "tabs.frontBeside")
        mirrorsTabs = store.bool(forKey: "tabs.mirror")
        newTabPlace = store.string(forKey: "tabs.newPlace").flatMap(NewTabPlace.init(rawValue:)) ?? .next
        startsFresh = store.bool(forKey: Preferences.freshKey)
        confirmsQuit = store.bool(forKey: Preferences.confirmQuitKey)
        engineSuggests = store.bool(forKey: "search.suggest")
        siteNotifications = store.object(forKey: "notifications.ask") as? Bool ?? true
        showsTabShortcuts = store.bool(forKey: "tabs.shortcuts")
        showsReading = store.bool(forKey: "tabs.reading")
        highContrastText = store.bool(forKey: "tabs.highContrast")
        // On for everyone who never touched it (Drice, 24 Oct 2026, on
        // Security's advice); a choice made before stands.
        showsAddress = store.object(forKey: "tabs.address") as? Bool ?? true
        shielded = store.object(forKey: "shield") as? Bool ?? true
        let keeps = store.bool(forKey: "sites.keep")
        keepsSignIns = keeps
        // Before the first page is loaded into the store.
        Store.keepsSignIns = keeps
        Spaces.everyStore.forEach(Store.followCookies)
        let signals = store.object(forKey: "privacy.gpc") as? Bool ?? true
        sendsPrivacySignal = signals
        PrivacySignal.on = signals
        let removes = store.object(forKey: "privacy.clickIDs") as? Bool ?? true
        removesClickIDs = removes
        ClickIDs.on = removes
        // Offered by default only in a build that can actually do them —
        // one with Apple's browser entitlement and its profile embedded. A
        // choice made under the other kind of build is not a choice about
        // this one: the first run of a build that can offers them, and the
        // first run of one that can't — a release swapped for a build of your
        // own — stops offering them, which would strand every sign-in on a
        // passkey path that can only fail. From then on the switch is the
        // person's. "passkeys.for" is the kind of build the switch was last
        // set under; before it there was only "passkeys.entitled", which a
        // build that couldn't wrote on its first run as well.
        let entitled = Preferences.entitledToPasskeys
        passkeysPossible = entitled
        let settledFor = store.object(forKey: "passkeys.for") as? Bool
            ?? (entitled && store.bool(forKey: "passkeys.entitled") ? true : nil)
        let offers: Bool
        if settledFor != entitled {
            offers = entitled
            store.set(entitled, forKey: "passkeys")
        } else {
            offers = store.object(forKey: "passkeys") as? Bool ?? entitled
        }
        passkeys = offers
        FormRelay.passkeysOffered = offers
        store.set(entitled, forKey: "passkeys.for")
        store.set(entitled, forKey: "passkeys.entitled")
        // A test run downloads into its own folder: ~/Downloads would have
        // macOS stop it to ask for access, with a dialog on the screen of
        // whoever is working beside it.
        let testDownloads = Store.folder.appendingPathComponent("Downloads", isDirectory: true)
        if Store.testing { try? FileManager.default.createDirectory(at: testDownloads, withIntermediateDirectories: true) }
        downloads = Store.testing
            ? testDownloads
            : (store.string(forKey: "downloads")).map { URL(fileURLWithPath: $0) }
                ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        asksWhereToSave = store.bool(forKey: "downloads.ask")
        savesPasswords = store.object(forKey: "passwords.save") as? Bool ?? true
        fillsPasswords = store.object(forKey: "passwords.fill") as? Bool ?? true
        applePasswords = store.bool(forKey: "passwords.apple")
        let contacts = store.bool(forKey: "contacts.fill")
        fillsContacts = contacts
        FormRelay.contacts = contacts
        // Anyone who already has a session was here before the welcome
        // existed; they are not asked to sit through it.
        welcomed = store.bool(forKey: "welcomed") || store.object(forKey: "glyph") != nil
        usesSpaces = store.bool(forKey: "spaces")
        spacesOnCommand = store.bool(forKey: Preferences.spacesOnCommandKey)
        profilesInOneWindow = store.bool(forKey: "profiles.oneWindow")
        listsPins = store.bool(forKey: "pins.list")
        pinFolders = store.bool(forKey: "pins.folders")
        pinCommandOpensTab = store.bool(forKey: "pins.commandNewTab")
        // "Pins keep their site" is one switch over two keys (see
        // SettingsIndex): on when either was on, on by default when neither
        // was ever touched (Drice, 24 Oct 2026), off when one was turned
        // off and the other never set. Nothing is written here.
        let home = store.object(forKey: "pins.home") as? Bool
        let peek = store.object(forKey: "pins.peek") as? Bool
        let keepsSite = home == nil && peek == nil ? true : (home ?? false) || (peek ?? false)
        pinsGoHome = keepsSite
        ai = AI.shipped && store.bool(forKey: "ai")
        aiProvider = store.string(forKey: "ai.provider").flatMap(AIProvider.init(rawValue:))
        aiModels = store.dictionary(forKey: "ai.models") as? [String: String] ?? [:]
        commandBar = store.bool(forKey: "commandbar")
        handoff = store.bool(forKey: "handoff")
        floatingNewTab = store.bool(forKey: "newtab.floating")
        launcher = store.bool(forKey: "launcher.on")
        launcherLittle = store.bool(forKey: "launcher.little")
        launcherKey = store.data(forKey: "launcher.key").flatMap { try? JSONDecoder().decode(LauncherKey.self, from: $0) }
        recentInNewTab = store.bool(forKey: "newtab.recent")
        // On for everyone who never touched it (24 Oct 2026).
        let history = store.object(forKey: "swipe.history") as? Bool ?? true
        holdsHistory = history
        PageView.holdsHistory = history
        // On for everyone who never touched these three switches (Drice,
        // 27 Sep 2026); a choice made before stands.
        let flicks = store.object(forKey: "float.flicks") as? Bool ?? true
        floatFlicks = flicks
        Float.flicks = flicks
        let minimizes = store.bool(forKey: "float.minimize")
        floatMinimizes = minimizes
        Float.minimizes = minimizes
        floatsAway = store.bool(forKey: "float.away")
        floatsOnLeave = store.object(forKey: "float.leave") as? Bool ?? true
        panelSite = store.string(forKey: "panel.site") ?? ""
        floatStyle = store.string(forKey: "float.style").flatMap(FloatStyle.init(rawValue:)) ?? .search
        escapeTwice = store.bool(forKey: "fullscreen.escapeTwice")
        keepsWindow = store.bool(forKey: "fullscreen.keepsWindow")
        waitsForPlay = store.bool(forKey: Preferences.waitsKey)
        translateTarget = store.string(forKey: "translate.target") ?? ""
        translateAlways = Set(store.stringArray(forKey: PageTranslator.alwaysKey) ?? [])
        installsUpdates = store.object(forKey: Updater.installKey) as? Bool ?? true
        peeksLinks = store.object(forKey: "links.peek") as? Bool ?? true
        peekClick = store.string(forKey: "links.peekClick").flatMap(PeekClick.init(rawValue:)) ?? .shift
        peekStays = store.bool(forKey: "links.peek.stays")
        optionClickSplits = store.bool(forKey: "links.optionSplit")
        pinsPeek = keepsSite
        readsTwins = store.bool(forKey: "reader.twins")
        readerFollowsLook = store.bool(forKey: "reader.follows")
        littleLinks = store.bool(forKey: Preferences.littleKey)
        littleFindsTabs = store.bool(forKey: "links.little.tabs")
        webmail = store.string(forKey: "mail.webmail").flatMap(Webmail.init(rawValue:)) ?? .none
        sendsLinksToSpaces = store.bool(forKey: SpaceRoutes.key)
        spaceRoutes = (store.array(forKey: SpaceRoutes.rulesKey) ?? []).compactMap(SpaceRoute.init(plist:))
        asksSpaceForLinks = store.bool(forKey: "links.ask")
        linkChoices = (store.array(forKey: "links.ask.last") ?? []).compactMap(LinkChooser.Choice.init(plist:))
        bookmarksBar = store.bool(forKey: "bookmarks.bar")
        alwaysShowsDownloads = store.bool(forKey: "downloads.button")
        downloadsOpening = store.string(forKey: "downloads.open").flatMap(DownloadsOpening.init(rawValue:)) ?? .tab
        let links = store.object(forKey: "links.show") as? Bool ?? true
        showsLinks = links
        HoveredLink.on = links
        let dusk = store.bool(forKey: "pages.dusk")
        darkensPages = dusk
        Dusk.shared.on = dusk
        capturesPages = store.bool(forKey: "pages.capture")
        let styles = store.bool(forKey: "sites.styles")
        sitesStyles = styles
        SiteStyles.shared.on = styles
        inspectorChrome = store.bool(forKey: "inspector.chrome")
        inspectorDark = store.bool(forKey: "inspector.dark")
        let scrolls = store.bool(forKey: "autoscroll")
        autoScroll = scrolls
        AutoScroll.on = scrolls
        let bouncing = store.bool(forKey: "pages.bounce")
        bounces = bouncing
        Swipe.bounces = bouncing
        // "pages.120" was a switch before it was three choices: on is now
        // always, an explicit off never. Never touched: On power (24 Oct
        // 2026), which changes nothing on battery.
        let fast = store.string(forKey: "pages.120.mode").flatMap(FastPages.init)
            ?? (store.object(forKey: "pages.120") as? Bool).map { $0 ? FastPages.always : .never }
            ?? .onPower
        fastPages = fast
        FrameRate.mode = fast
        lightMotion = store.bool(forKey: Motion.lightKey)
        let instant = store.bool(forKey: Motion.instantKey)
        instantMotion = instant
        Motion.instant = instant
        // Left behind by the Web Inspector's switch, from before it was
        // always there.
        store.removeObject(forKey: "inspector")
        let corrects = store.object(forKey: "autocorrect") as? Bool
            ?? NSSpellChecker.isAutomaticSpellingCorrectionEnabled
        autocorrect = corrects
        // Before the first web view exists: WebKit reads these once.
        Preferences.tellWebKit(autocorrect: corrects)
        Substitution.register()
        pageZoom = store.object(forKey: "pageZoom") as? Double ?? 1
        // Left behind by an assistant this browser no longer has.
        for key in ["mind.model", "mind.effort", "mind.acting", "mind.width", "mind.open"] {
            store.removeObject(forKey: key)
        }
    }

    /// The folder the settings file is in, watched for as long as the app
    /// runs (see followFile).
    private var fileWatch: DispatchSourceFileSystemObject?

    /// A line of the settings file changed from outside, by `defaults write`
    /// while Search runs, moves its switch at once, as if it had been
    /// flipped in Settings. The folder rather than the file: `defaults` puts
    /// a new file in place of the old one. Nothing else hears it on macOS
    /// 27.2: UserDefaults.didChangeNotification only fires for this
    /// process's own writes, and KVO misses every key with a dot in it.
    /// Started once, at launch, for the app's own settings (see Links).
    func followFile() {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences")
        let handle = open(folder.path, O_EVTONLY)
        guard handle >= 0 else { return }
        let watch = DispatchSource.makeFileSystemObjectSource(fileDescriptor: handle, eventMask: .write, queue: .main)
        watch.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.reread() } }
        watch.resume()
        fileWatch = watch
    }

    /// The settings that only change how the tabs, the sidebar and the
    /// window look and sit, read again as init reads them, and set only
    /// where that differs, through their own didSet: what the switch does
    /// happens, and the value written back says what the line already said,
    /// so the next look finds nothing to do. Only these: privacy, security,
    /// passwords, extensions and anything that loosens a protection keep
    /// applying at the next launch, as before, and `bench` stays behind
    /// Bench.Consent (Drice, on #736, 26 Oct 2026). The folder holds every
    /// app's settings, and a change is often heard twice, the first time
    /// before it can be read; either costs a read and nothing more. A line
    /// taken out puts its default back and leaves no line, as launch leaves
    /// none; a choice or a width this build can't read is left as it is (see
    /// take). The switches that are off unless turned on are read through
    /// bool as launch reads them: any line, or none, is off, and that is
    /// written back.
    func reread() {
        take(\.look, "look", store.string(forKey: "look").flatMap(Look.init), or: .system)
        take(\.homeTheme, "home.theme", store.string(forKey: "home.theme").flatMap(HomeTheme.stored), or: .off)
        take(\.homeThemeImage, store.string(forKey: "home.theme.image"))
        take(\.homeShuffle, store.bool(forKey: "home.shuffle"))
        take(\.homeTuning, "home.tuning", HomeTuning.read(store.string(forKey: "home.tuning")), or: HomeTuning())
        take(\.navigationLeft, store.bool(forKey: "toolbar.left"))
        take(\.compactStrip, store.bool(forKey: "tabs.compact"))
        take(\.sidebar, "sidebar", store.object(forKey: "sidebar") as? Bool,
             or: store.string(forKey: "manner").map { $0 == "side" } ?? SidebarDefault.fresh(testing: Store.testing))
        take(\.sidePosition, "sidebar.position", store.string(forKey: "sidebar.position").flatMap(SidebarPosition.init),
             or: .left)
        take(\.sideHides, store.bool(forKey: "sidebar.hides"))
        take(\.slidesColumn, store.bool(forKey: Motion.slidesKey))
        take(\.roomyTabs, store.bool(forKey: "sidebar.roomy"))
        take(\.doorsUp, store.bool(forKey: "sidebar.doorsUp"))
        take(\.sideIcons, store.bool(forKey: "sidebar.icons"))
        take(\.foldsToIcons, store.bool(forKey: "sidebar.foldIcons"))
        take(\.sideWidth, "sidebar.width", (store.object(forKey: "sidebar.width") as? Double).map { CGFloat($0) }
            .flatMap { (Metrics.sideMin...Metrics.sideMax).contains($0) ? $0 : nil }, or: Metrics.side)
        take(\.sidePanelWidth, "sidepanel.width", (store.object(forKey: "sidepanel.width") as? Double).map { CGFloat($0) }
            .flatMap { Preferences.sidePanelWidths.contains($0) ? $0 : nil }, or: 380)
        take(\.cards, "layout.cards", store.object(forKey: "layout.cards") as? Bool, or: true)
        take(\.cardsInFullScreen, store.bool(forKey: "layout.cardsFullScreen"))
        take(\.addressLine, store.bool(forKey: "address.shown"))
        take(\.addressWidth, "address.width", store.string(forKey: "address.width").flatMap(AddressWidth.init), or: .small)
        take(\.glass, store.bool(forKey: "window.glass"))
        take(\.glassGrain, "window.glass.grain", (store.object(forKey: "window.glass.grain") as? Double).map { min(1, max(0, $0)) }, or: 0.2)
        take(\.glassClear, "window.glass.clear", (store.object(forKey: "window.glass.clear") as? Double).map { min(1, max(0, $0)) }, or: 0.5)
        take(\.glassStyle, "window.glass.style", store.string(forKey: "window.glass.style").flatMap(GlassStyle.init), or: .frosted)
        take(\.liquidTabs, store.bool(forKey: "tabs.liquid"))
        take(\.bounces, store.bool(forKey: "pages.bounce"))
        Swipe.bounces = bounces
        take(\.glyph, "glyph", store.string(forKey: "glyph").flatMap(Glyph.init), or: .letters)
        take(\.tabsGive, store.bool(forKey: "tabs.give"))
        take(\.instantMotion, store.bool(forKey: Motion.instantKey))
        take(\.showsTabShortcuts, store.bool(forKey: "tabs.shortcuts"))
        take(\.spacesOnCommand, store.bool(forKey: Preferences.spacesOnCommandKey))
        take(\.bookmarksBar, store.bool(forKey: "bookmarks.bar"))
        take(\.alwaysShowsDownloads, store.bool(forKey: "downloads.button"))
    }

    /// The setting as its line reads, or `fallback` where there's no line,
    /// and still no line after didSet has run: launch writes none for a
    /// default, so a later build that changes the default finds it never
    /// touched. A line there that this build can't read (a choice a newer
    /// build added, a width past this one's limits, a typo) leaves the
    /// setting and the line as they are: launch falls back to the default for
    /// it, but written back the default would take that choice from the newer
    /// build as well.
    private func take<T: Equatable>(_ setting: ReferenceWritableKeyPath<Preferences, T>, _ key: String, _ read: T?,
                                    or fallback: T) {
        if let read { return take(setting, read) }
        guard store.object(forKey: key) == nil, self[keyPath: setting] != fallback else { return }
        self[keyPath: setting] = fallback
        store.removeObject(forKey: key)
    }

    private func take<T: Equatable>(_ setting: ReferenceWritableKeyPath<Preferences, T>, _ value: T) {
        if self[keyPath: setting] != value { self[keyPath: setting] = value }
    }

    /// WebKit's text checker takes its orders from the app's standard
    /// defaults — the real ones, not the test suite, because it is WebKit
    /// reading them and not us. Text replacement, smart quotes and smart
    /// dashes are Edit › Substitutions' (see Substitutions.swift).
    static func tellWebKit(autocorrect: Bool) {
        UserDefaults.standard.set(autocorrect, forKey: autocorrectKey)
    }

    static let autocorrectKey = "WebAutomaticSpellingCorrectionEnabled"

    /// Once WebKit has read the default it keeps its own copy, for every
    /// page of the app, and the only way to change it is its own toggle
    /// (what Safari's menu sends): a flip, not a value. It used to be flipped
    /// when the default disagreed with the choice, and that is what turned
    /// autocorrect on when it was switched off (idea 743): the default can
    /// change without WebKit reading it again — written by another Search
    /// sharing the app's defaults, or with no page view to flip — and from
    /// then on every flip went the wrong way while the menu's tick said
    /// otherwise. So the guess goes: the default is cleared, WebKit flips
    /// and writes back where it now stands, and flips once more if that
    /// isn't `on`. Any page view will do, since the switch is the app's;
    /// with none open, one made for the purpose and let go.
    static func switchWebKit(autocorrect on: Bool) {
        let defaults = UserDefaults.standard
        let toggle = NSSelectorFromString("toggleAutomaticSpellingCorrection:")
        let web: WKWebView = Web.pages.allObjects.first ?? WKWebView(frame: .zero)
        if web.responds(to: toggle) {
            defaults.removeObject(forKey: autocorrectKey)
            web.perform(toggle, with: nil)
            if let now = defaults.object(forKey: autocorrectKey) as? Bool, now != on {
                web.perform(toggle, with: nil)
            }
        }
        tellWebKit(autocorrect: on)
    }
}
