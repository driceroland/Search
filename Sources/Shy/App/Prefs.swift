import Security
import SwiftUI

// Everything there is to set, in one observable place.
//
// Each of these is a line in the settings file and nothing more; the object
// exists so that a panel can bind to them and the rest of the window can
// redraw when one changes. Defaults are chosen so that a browser nobody has
// configured behaves the way it always did.

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
/// When a playing video goes into picture in picture by itself (Settings › General).
enum FloatWhen: String, CaseIterable, Identifiable {
    case never, tabs, tabsOrApps

    nonisolated static let key = "float.when"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .never: return "Off"
        case .tabs: return "Switching tabs"
        case .tabsOrApps: return "Tabs or apps"
        }
    }

    /// What the line in Settings says under the choice.
    var detail: String {
        switch self {
        case .never: return "Only when you press ⇧⌘P"
        case .tabs: return "When you switch to another tab"
        case .tabsOrApps: return "When you switch to another tab or app"
        }
    }

    /// The one chosen, or what the two switches before it said
    /// ("float.leave", on unless turned off, and "float.away").
    static func chosen(_ store: UserDefaults) -> FloatWhen {
        if let chosen = store.string(forKey: key).flatMap(FloatWhen.init) { return chosen }
        if store.bool(forKey: "float.away") { return .tabsOrApps }
        return store.object(forKey: "float.leave") as? Bool ?? true ? .tabs : .never
    }
}

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

@MainActor
final class Preferences: ObservableObject {
    private let store = Store.settings

    #if DEBUG
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
    #endif
    /// Agents' pages, through shy-mcp (see Agent.swift). Off unless asked
    /// for. A plain setting, with no mark to prove Settings set it, unlike
    /// the bench's: an agent's pages hold nothing of yours (none of your
    /// tabs, sign-ins or passwords) and only you can hand one over, so
    /// whatever turned it on gets a browser of its own and nothing more.
    @Published var agent: Bool {
        didSet { store.set(agent, forKey: "agent") }
    }
    /// What agents may not do in their pages (see Agent.Ability): each turned
    /// off in Settings › Agents. Everything allowed unless taken away.
    @Published var agentDenied: Set<String> {
        didSet { store.set(Array(agentDenied).sorted(), forKey: "agent.denied") }
    }
    /// Light, dark, or the Mac's own.
    @Published var look: Look {
        didSet {
            store.set(look.rawValue, forKey: "look")
            look.apply()
        }
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
    /// A column folded away comes out when the pointer meets its edge. On
    /// unless turned off; off, only ⌘S (or its button) brings it back.
    @Published var sidePeeks: Bool {
        didSet { store.set(sidePeeks, forKey: "sidebar.peeks") }
    }
    /// Clear leaves a tab that is playing sound, as well as the one you are
    /// on. Off unless asked for.
    @Published var clearKeepsPlaying: Bool {
        didSet { store.set(clearKeepsPlaying, forKey: "clear.keepsPlaying") }
    }
    /// Taller lines and larger titles in the column, for anyone who finds
    /// the default hard to read (#570). Off unless asked for.
    @Published var roomyTabs: Bool {
        didSet { store.set(roomyTabs, forKey: "sidebar.roomy") }
    }
    /// One tab's line in the column, and the size its title is set in.
    var sideRow: CGFloat { roomyTabs ? 36 : 28 }
    var sideTitle: CGFloat { roomyTabs ? 14 : 12.5 }
    /// A pinned square's height, roomier with the rows.
    var sideSquare: CGFloat { roomyTabs ? 42 : 34 }
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
    @Published var engine: Engine {
        didSet { store.set(engine.rawValue, forKey: "search.engine") }
    }
    @Published var customEngine: String {
        didSet { store.set(customEngine, forKey: "search.custom") }
    }
    /// Shortcuts to a site's own search, ahead of the default engine (see
    /// Keyword.swift). Empty until someone adds one.
    @Published var keywords: [Keyword] {
        didSet { store.set((try? JSONEncoder().encode(keywords)) ?? Data(), forKey: "search.keywords") }
    }
    /// Sites kept awake (see Sleep.swift), each profile its own (SiteMemory).
    func awakeSites(in profile: UUID) -> Set<String> {
        Set(store.stringArray(forKey: SiteMemory.key("tabs.awakeSites", profile)) ?? [])
    }
    func setAwakeSites(_ sites: Set<String>, in profile: UUID) {
        objectWillChange.send()
        store.set(Array(sites).sorted(), forKey: SiteMemory.key("tabs.awakeSites", profile))
    }
    /// Sized website pop-ups may use small windows instead of tabs (#552).
    @Published var popupWindows: Bool {
        didSet { store.set(popupWindows, forKey: "tabs.popupWindows") }
    }
    /// Sites whose pages may open windows without a click just before
    /// (BlockedPopups.swift), each a registrable domain. Empty until you
    /// choose Always Allow on one; Settings › Privacy lists them. Each
    /// profile its own (SiteMemory).
    func popupSites(in profile: UUID) -> Set<String> {
        Set(store.stringArray(forKey: SiteMemory.key("privacy.popupSites", profile)) ?? [])
    }
    func setPopupSites(_ sites: Set<String>, in profile: UUID) {
        objectWillChange.send()
        store.set(Array(sites).sorted(), forKey: SiteMemory.key("privacy.popupSites", profile))
    }
    /// Tabs nobody has looked at for a while give their page back and keep
    /// where they were: unless sleepPace is Never.
    var sleepsTabs: Bool { sleepPace != .never }
    /// Tabs you haven't pinned, named or grouped close once left alone this
    /// long, as in Arc. Never unless asked for.
    @Published var tabLife: TabLife {
        didSet { store.set(tabLife.rawValue, forKey: "tabs.close.after") }
    }
    /// How soon they do, or never (see SleepPace). Normal unless chosen.
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
    /// Where a new tab goes in the row. Next unless asked for.
    @Published var newTabPlace: NewTabPlace {
        didSet { store.set(newTabPlace.rawValue, forKey: "tabs.newPlace") }
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
    /// Suggestions from the search engine under the address field, as you
    /// type (see EngineSuggest.swift). Off unless asked for: what is typed
    /// is sent to the engine while it is typed.
    @Published var engineSuggests: Bool {
        didSet { store.set(engineSuggests, forKey: "search.suggest") }
    }
    /// The tab you're on says where its page is, at rest, without a click:
    /// its site, from the address on screen (see AtRest.swift). Off unless
    /// asked for.
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
    /// macOS's own autocorrect, inside web pages: the little "Not ×" that
    /// capitalises what you meant to leave lower-case. As the Mac has it
    /// (System Settings › Keyboard › Correct spelling automatically) until
    /// the switch here is used.
    @Published var autocorrect: Bool {
        didSet {
            store.set(autocorrect, forKey: "autocorrect")
            Preferences.tellWebKit(autocorrect: autocorrect)
        }
    }
    /// How big every site is drawn until it has been zoomed on its own.
    @Published var pageZoom: Double {
        didSet { store.set(pageZoom, forKey: "pageZoom") }
    }
    /// The stops the setting steps through — every 5%, from as small as
    /// anyone reads to as big as a page is worth.
    static let zooms: [Double] = stride(from: 50, through: 300, by: 5).map { Double($0) / 100 }


    /// A click of the wheel scrolls the page as on Windows (see AutoScroll.swift).
    /// Off unless asked for.
    @Published var autoScroll: Bool {
        didSet {
            store.set(autoScroll, forKey: "autoscroll")
            AutoScroll.on = autoScroll
        }
    }
    /// Pages draw at 120 frames a second on a screen that can (see FrameRate.swift).
    /// Never unless asked for.
    @Published var fastPages: FastPages {
        didSet {
            store.set(fastPages.rawValue, forKey: "pages.120.mode")
            FrameRate.mode = fastPages
        }
    }
    /// Springs become a short ease-out in Low Power Mode (see Motion.light).
    /// Off unless turned on, and even then nothing changes until the Mac is
    /// asked to save power.
    @Published var lightMotion: Bool {
        didSet { store.set(lightMotion, forKey: Motion.lightKey) }
    }
    /// The modifier chosen in Settings › Shortcuts; Shift-click by default.
    @Published var peekClick: PeekClick {
        didSet { store.set(peekClick.rawValue, forKey: "links.peekClick") }
    }
    /// Reading mode goes dark with the window, with a light/dark/window
    /// switch in its corner (see ReaderLook). Off unless asked for: the
    /// article is white, as it always was.
    @Published var readerFollowsLook: Bool {
        didSet { store.set(readerFollowsLook, forKey: "reader.follows") }
    }
    /// A link from another app opens in a small window of its own (see
    /// Little.swift). Off unless asked for.
    @Published var littleLinks: Bool {
        didSet { store.set(littleLinks, forKey: "links.little") }
    }
    /// The downloads button always in the chrome, not only while something
    /// downloads (see Fetching.swift). Off unless asked for.
    @Published var alwaysShowsDownloads: Bool {
        didSet { store.set(alwaysShowsDownloads, forKey: "downloads.button") }
    }
    /// Videos wait for a click instead of starting by themselves, as Safari's
    /// Never Auto-Play has it (see Web.configuration). Off unless asked for.
    @Published var waitsForPlay: Bool {
        didSet { store.set(waitsForPlay, forKey: Preferences.waitsKey) }
    }
    nonisolated static let waitsKey = "media.click"
    /// Translate Page in the page's right-click menu, on this Mac only
    /// (Translate.swift). Off unless asked for.
    @Published var translatesPages: Bool {
        didSet { store.set(translatesPages, forKey: PageTranslator.key) }
    }
    /// The languages whose pages are translated as they open, chosen from
    /// the translated sign's menu (never from a private tab). None at first.
    @Published var translateAlways: Set<String> {
        didSet { store.set(Array(translateAlways).sorted(), forKey: PageTranslator.alwaysKey) }
    }
    /// When a playing video goes into picture in picture by itself:
    /// never, when you go to another tab (Browser.leaving), or then and when
    /// another app comes to the front (Browser.appLeft). Tabs unless chosen.
    @Published var floatWhen: FloatWhen {
        didSet { store.set(floatWhen.rawValue, forKey: FloatWhen.key) }
    }
    var floatsOnLeave: Bool { floatWhen != .never }
    var floatsAway: Bool { floatWhen == .tabsOrApps }
    /// The website last put in the side panel, for View › Side Panel.
    @Published var panelSite: String {
        didSet { store.set(panelSite, forKey: "panel.site") }
    }
    /// Escape on a page filling the screen leaves only when pressed twice
    /// within two seconds, as in Arc; the first puts up a reminder (see
    /// FullScreenEscape). Off unless asked for: one press leaves, as in
    /// Safari.
    @Published var escapeTwice: Bool {
        didSet { store.set(escapeTwice, forKey: "fullscreen.escapeTwice") }
    }
    /// ⌘T raises the field over the page you are on, as in Arc, and a tab is
    /// only made once Return sends it somewhere. Escape, ⌘W or a click
    /// outside puts the field away and leaves you where you were. Off unless
    /// asked for.
    @Published var floatingNewTab: Bool {
        didSet { store.set(floatingNewTab, forKey: "newtab.floating") }
    }

    init() {
        // Carried over from when there were four ways of holding the browser
        // and this was one of them.
        // The Mac's own unless asked otherwise — a Mac in dark mode expects
        // a dark browser, pages included.
        #if DEBUG
        let scripted = store.bool(forKey: "bench")
        let allowed = scripted && (Store.testing || Bench.Consent.given)
        bench = allowed
        if scripted, !allowed {
            benchRefused = true
            store.set(false, forKey: "bench")
        }
        #endif
        agent = store.bool(forKey: "agent")
        agentDenied = Set(store.stringArray(forKey: "agent.denied") ?? [])
        let chosen = store.string(forKey: "look").flatMap(Look.init) ?? .system
        look = chosen
        // Before the first window, and not deferred: the window that is about
        // to be made should be made in the right appearance. Through `shared`
        // rather than `NSApp`: on macOS 14 SwiftUI builds this before it has
        // made the application, and `NSApp` is still nil here.
        NSApplication.shared.appearance = chosen.appearance
        sidePanelWidth = min(max(CGFloat(store.object(forKey: "sidepanel.width") as? Double ?? 380),
                                 Preferences.sidePanelWidths.lowerBound), Preferences.sidePanelWidths.upperBound)
        sidePosition = store.string(forKey: "sidebar.position").flatMap(SidebarPosition.init) ?? .left
        sidePeeks = store.object(forKey: "sidebar.peeks") as? Bool ?? true
        roomyTabs = store.bool(forKey: "sidebar.roomy")
        clearKeepsPlaying = store.bool(forKey: "clear.keepsPlaying")
        let width = store.object(forKey: "sidebar.width") as? Double ?? Double(Metrics.side)
        sideWidth = min(Metrics.sideMax, max(Metrics.sideMin, CGFloat(width)))
        cards = store.object(forKey: "layout.cards") as? Bool ?? true
        engine = store.string(forKey: "search.engine").flatMap(Engine.init) ?? .standard
        customEngine = store.string(forKey: "search.custom") ?? ""
        keywords = store.data(forKey: "search.keywords")
            .flatMap { try? JSONDecoder().decode([Keyword].self, from: $0) } ?? []
        popupWindows = store.bool(forKey: "tabs.popupWindows")
        tabLife = TabLife(rawValue: store.integer(forKey: "tabs.close.after")) ?? .never
        sleepPace = SleepPace.chosen
        lazyTabs = store.bool(forKey: "tabs.lazy")
        newTabPlace = store.string(forKey: "tabs.newPlace").flatMap(NewTabPlace.init(rawValue:)) ?? .next
        startsFresh = store.bool(forKey: Preferences.freshKey)
        confirmsQuit = store.bool(forKey: Preferences.confirmQuitKey)
        engineSuggests = store.bool(forKey: "search.suggest")
        siteNotifications = store.object(forKey: "notifications.ask") as? Bool ?? true
        showsAddress = store.bool(forKey: "tabs.address")
        shielded = store.object(forKey: "shield") as? Bool ?? true
        let keeps = store.bool(forKey: "sites.keep")
        keepsSignIns = keeps
        // Before the first page is loaded into the store.
        Store.keepsSignIns = keeps
        Spaces.everyStore.forEach(Store.followCookies)
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
        if settledFor != entitled {
            passkeys = entitled
            store.set(entitled, forKey: "passkeys")
        } else {
            passkeys = store.object(forKey: "passkeys") as? Bool ?? entitled
        }
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
        floatingNewTab = store.bool(forKey: "newtab.floating")
        floatWhen = FloatWhen.chosen(store)
        panelSite = store.string(forKey: "panel.site") ?? ""
        escapeTwice = store.bool(forKey: "fullscreen.escapeTwice")
        waitsForPlay = store.bool(forKey: Preferences.waitsKey)
        translatesPages = store.bool(forKey: PageTranslator.key)
        translateAlways = Set(store.stringArray(forKey: PageTranslator.alwaysKey) ?? [])
        peekClick = store.string(forKey: "links.peekClick").flatMap(PeekClick.init(rawValue:)) ?? .shift
        readerFollowsLook = store.bool(forKey: "reader.follows")
        littleLinks = store.bool(forKey: "links.little")
        alwaysShowsDownloads = store.bool(forKey: "downloads.button")
        let scrolls = store.bool(forKey: "autoscroll")
        autoScroll = scrolls
        AutoScroll.on = scrolls
        // "pages.120" was a switch before it was three choices: on is now always.
        let fast = store.string(forKey: "pages.120.mode").flatMap(FastPages.init)
            ?? (store.bool(forKey: "pages.120") ? .always : .never)
        fastPages = fast
        FrameRate.mode = fast
        lightMotion = store.bool(forKey: Motion.lightKey)
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
        // Left behind by switches for things that are now simply there:
        // tab groups, Split View, pins as in Arc, and the rest.
        for key in ["tabs.groups", "splitView", "panel.sites", "tabs.keepAwake", "pins.shared",
                    "links.show", "swipe.history", "switcher.keys", "tabs.shortcuts", "float.flicks",
                    "commandbar", "search.sites", "spaces", "sidebar", "manner",
                    "tabs.give", "bookmarks.bar", "links.peek", "toolbar.left", "update.install", "update.checked", "pins.list", "pins.home", "pins.numberBack", "pins.peek"] {
            store.removeObject(forKey: key)
        }
        // Left behind by an assistant, and an AI add-on, this browser no
        // longer has.
        for key in ["mind.model", "mind.effort", "mind.acting", "mind.width", "mind.open", "ai", "ai.provider", "ai.models"] {
            store.removeObject(forKey: key)
        }
    }

    /// WebKit's text checker takes its orders from the app's standard
    /// defaults — the real ones, not the test suite, because it is WebKit
    /// reading them and not us. Text replacement, smart quotes and smart
    /// dashes are Edit › Substitutions' (see Substitutions.swift).
    static func tellWebKit(autocorrect: Bool) {
        UserDefaults.standard.set(autocorrect, forKey: "WebAutomaticSpellingCorrectionEnabled")
    }
}
