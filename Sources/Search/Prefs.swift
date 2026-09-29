import Security
import SwiftUI

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

    /// Back, forward and reload before the tabs rather than after them, with
    /// the tabs across the top. Off unless asked for.
    @Published var navigationLeft: Bool {
        didSet { store.set(navigationLeft, forKey: "toolbar.left") }
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
    /// Light, dark, or the Mac's own.
    @Published var look: Look {
        didSet {
            store.set(look.rawValue, forKey: "look")
            look.apply()
        }
    }
    /// Titles down a side instead of across the top.
    @Published var sidebar: Bool {
        didSet { store.set(sidebar, forKey: "sidebar") }
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
    /// How wide the column is. Pulled by its edge, and remembered.
    @Published var sideWidth: CGFloat {
        didSet { store.set(Double(sideWidth), forKey: "sidebar.width") }
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
    /// Shortcuts to a site's own search, ahead of the default engine (see
    /// Keyword.swift). Empty until someone adds one.
    @Published var keywords: [Keyword] {
        didSet { store.set((try? JSONEncoder().encode(keywords)) ?? Data(), forKey: "search.keywords") }
    }
    /// Tabs nobody has looked at for half an hour give their page back and
    /// keep where they were. On unless turned off.
    @Published var sleepsTabs: Bool {
        didSet { store.set(sleepsTabs, forKey: "tabs.sleep") }
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
    /// Each launch starts with a fresh window: the pins stay, last time's
    /// other tabs don't come back (see Session.startFresh). Off unless
    /// asked for (#406).
    @Published var startsFresh: Bool {
        didSet { store.set(startsFresh, forKey: Preferences.freshKey) }
    }
    nonisolated static let freshKey = "start.fresh"
    /// Search a site from the address field: the start of its name, then
    /// Tab (see SiteSearch.swift). Off unless asked for.
    @Published var searchesSites: Bool {
        didSet { store.set(searchesSites, forKey: "search.sites") }
    }
    @Published var showsReading: Bool {
        didSet { store.set(showsReading, forKey: "tabs.reading") }
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
    /// A private tab gets extensions too, not just every other page. Off
    /// unless asked for - a private tab keeps nothing by default, extensions
    /// included, and some watch what a page does.
    @Published var extensionsInPrivate: Bool {
        didSet { store.set(extensionsInPrivate, forKey: "extensions.private") }
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

    /// Pages with no dark look of their own darkened while the frame is
    /// dark (see Dusk.swift). Off unless asked for.
    @Published var darkensPages: Bool {
        didSet {
            store.set(darkensPages, forKey: "pages.dusk")
            Dusk.shared.on = darkensPages
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
    /// Pages draw at 120 frames a second on a screen that can (see FrameRate.swift).
    /// Off unless asked for.
    @Published var fastPages: Bool {
        didSet {
            store.set(fastPages, forKey: "pages.120")
            FrameRate.fast = fastPages
        }
    }
    /// Shift-click on a link opens it in a panel over the page (see
    /// Peek.swift). On unless turned off.
    @Published var peeksLinks: Bool {
        didSet { store.set(peeksLinks, forKey: "links.peek") }
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
    /// pick from (see PageView.openList). Off unless asked for.
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
    /// A video playing on a video site comes out into the floating window
    /// when you go to another tab (Browser.leaving). On, as it always was;
    /// the switch is for turning it off.
    @Published var floatsOnLeave: Bool {
        didSet { store.set(floatsOnLeave, forKey: "float.leave") }
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
    /// Named, collapsible sections in the sidebar. Off unless asked for.
    @Published var usesTabGroups: Bool {
        didSet { store.set(usesTabGroups, forKey: "tabs.groups") }
    }
    /// Arc's three tiers in the sidebar: the squares, pins kept as rows
    /// under them, and a line with Clear above the tabs that come and go
    /// (see Tab.listed). Off unless asked for.
    @Published var listsPins: Bool {
        didSet { store.set(listsPins, forKey: "pins.list") }
    }
    /// Whether the pinned rows are drawn as rows: asked for, and with the
    /// tabs down the side. Across the top every pin is a square.
    var showsPinRows: Bool { listsPins && sidebar }
    /// The AI add-on: summaries of the page and questions about it (see
    /// AIAssist). Off unless asked for; nothing is sent until you ask.
    @Published var ai: Bool {
        didSet { store.set(ai, forKey: "ai") }
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

    /// Two pages share one place in the tab row. Off unless asked for.
    @Published var splitView: Bool {
        didSet { store.set(splitView, forKey: "splitView") }
    }
    /// "settings", "new tab" and the like, typed alone in the address field,
    /// reach that part of the app instead of asking a search engine for the
    /// word (see AddressCommands.swift). Off unless asked for.
    @Published var commandBar: Bool {
        didSet { store.set(commandBar, forKey: "commandbar") }
    }

    init() {
        navigationLeft = store.bool(forKey: "toolbar.left")
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
        let chosen = store.string(forKey: "look").flatMap(Look.init) ?? .system
        look = chosen
        // Before the first window, and not deferred: the window that is about
        // to be made should be made in the right appearance. Through `shared`
        // rather than `NSApp`: on macOS 14 SwiftUI builds this before it has
        // made the application, and `NSApp` is still nil here.
        NSApplication.shared.appearance = chosen.appearance
        sidebar = store.object(forKey: "sidebar") as? Bool
            ?? (store.string(forKey: "manner") == "side")
        sidePosition = store.string(forKey: "sidebar.position").flatMap(SidebarPosition.init) ?? .left
        sideHides = store.bool(forKey: "sidebar.hides")
        let width = store.object(forKey: "sidebar.width") as? Double ?? Double(Metrics.side)
        sideWidth = min(Metrics.sideMax, max(Metrics.sideMin, CGFloat(width)))
        glyph = store.string(forKey: "glyph").flatMap(Glyph.init) ?? .letters
        engine = store.string(forKey: "search.engine").flatMap(Engine.init) ?? .standard
        customEngine = store.string(forKey: "search.custom") ?? ""
        keywords = store.data(forKey: "search.keywords")
            .flatMap { try? JSONDecoder().decode([Keyword].self, from: $0) } ?? []
        sleepsTabs = store.object(forKey: "tabs.sleep") as? Bool ?? true
        lazyTabs = store.bool(forKey: "tabs.lazy")
        startsFresh = store.bool(forKey: Preferences.freshKey)
        searchesSites = store.bool(forKey: "search.sites")
        siteNotifications = store.object(forKey: "notifications.ask") as? Bool ?? true
        showsReading = store.object(forKey: "tabs.reading") as? Bool ?? true
        shielded = store.object(forKey: "shield") as? Bool ?? true
        let keeps = store.bool(forKey: "sites.keep")
        keepsSignIns = keeps
        // Before the first page is loaded into the store.
        Store.keepsSignIns = keeps
        extensionsInPrivate = store.bool(forKey: "extensions.private")
        // Offered by default only in a build that can actually do them —
        // one with Apple's browser entitlement and its profile embedded. A
        // choice made while they couldn't work is not a choice about them:
        // the first run of a build that can offers them, whatever was set
        // before; from then on the switch is the person's.
        let entitled = Preferences.entitledToPasskeys
        passkeysPossible = entitled
        if entitled, !store.bool(forKey: "passkeys.entitled") {
            passkeys = true
            store.set(true, forKey: "passkeys")
        } else {
            passkeys = store.object(forKey: "passkeys") as? Bool ?? entitled
        }
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
        // Anyone who already has a session was here before the welcome
        // existed; they are not asked to sit through it.
        welcomed = store.bool(forKey: "welcomed") || store.object(forKey: "glyph") != nil
        usesSpaces = store.bool(forKey: "spaces")
        usesTabGroups = store.bool(forKey: "tabs.groups")
        listsPins = store.bool(forKey: "pins.list")
        splitView = store.bool(forKey: "splitView")
        ai = store.bool(forKey: "ai")
        aiProvider = store.string(forKey: "ai.provider").flatMap(AIProvider.init(rawValue:))
        aiModels = store.dictionary(forKey: "ai.models") as? [String: String] ?? [:]
        commandBar = store.bool(forKey: "commandbar")
        let history = store.bool(forKey: "swipe.history")
        holdsHistory = history
        PageView.holdsHistory = history
        // On for everyone who never touched these three switches (Drice,
        // 27 Sep 2026); a choice made before stands.
        let flicks = store.object(forKey: "float.flicks") as? Bool ?? true
        floatFlicks = flicks
        Float.flicks = flicks
        floatsAway = store.bool(forKey: "float.away")
        floatsOnLeave = store.object(forKey: "float.leave") as? Bool ?? true
        waitsForPlay = store.bool(forKey: Preferences.waitsKey)
        installsUpdates = store.object(forKey: Updater.installKey) as? Bool ?? true
        peeksLinks = store.object(forKey: "links.peek") as? Bool ?? true
        littleLinks = store.bool(forKey: "links.little")
        bookmarksBar = store.bool(forKey: "bookmarks.bar")
        alwaysShowsDownloads = store.bool(forKey: "downloads.button")
        let links = store.object(forKey: "links.show") as? Bool ?? true
        showsLinks = links
        HoveredLink.on = links
        let dusk = store.bool(forKey: "pages.dusk")
        darkensPages = dusk
        Dusk.shared.on = dusk
        let scrolls = store.bool(forKey: "autoscroll")
        autoScroll = scrolls
        AutoScroll.on = scrolls
        let fast = store.bool(forKey: "pages.120")
        fastPages = fast
        FrameRate.fast = fast
        // Left behind by the Web Inspector's switch, from before it was
        // always there.
        store.removeObject(forKey: "inspector")
        let corrects = store.object(forKey: "autocorrect") as? Bool
            ?? NSSpellChecker.isAutomaticSpellingCorrectionEnabled
        autocorrect = corrects
        // Before the first web view exists: WebKit reads these once.
        Preferences.tellWebKit(autocorrect: corrects)
        pageZoom = store.object(forKey: "pageZoom") as? Double ?? 1
        // Left behind by an assistant this browser no longer has.
        for key in ["mind.model", "mind.effort", "mind.acting", "mind.width", "mind.open"] {
            store.removeObject(forKey: key)
        }
    }

    /// WebKit's text checker takes its orders from the app's standard
    /// defaults — the real ones, not the test suite, because it is WebKit
    /// reading them and not us. Smart quotes and dashes go off outright: in a
    /// browser they are wrong in every code field and wanted in almost none.
    static func tellWebKit(autocorrect: Bool) {
        let defaults = UserDefaults.standard
        defaults.set(autocorrect, forKey: "WebAutomaticSpellingCorrectionEnabled")
        defaults.set(false, forKey: "WebAutomaticQuoteSubstitutionEnabled")
        defaults.set(false, forKey: "WebAutomaticDashSubstitutionEnabled")
    }
}
