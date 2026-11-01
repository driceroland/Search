import AppKit
import SwiftUI
import WebKit
import Combine

// Chrome extensions, on WebKit.
//
// The engine is Apple's: WKWebExtension, the same one Safari runs its
// extensions on, reading the same manifest.json a Chrome extension ships.
// What is here is the browser's half of the contract — which tabs exist and
// which one is in front, what a new tab or a popup means in this window, who
// is asked for a permission and how — plus the Chrome Web Store install
// (Crx.swift) and the APIs WebKit doesn't have, filled in natively
// (ExtensionShims.swift, ExtensionNative.swift, ExtensionSocket.swift).
//
// Tab is a Swift class and the protocols are Objective-C ones, so each tab
// is represented to WebKit by a small adapter kept here. A tab can be in the
// row with no web view at all — asleep, or put down — and is reported with
// none; `built` is read, never `web`, which would make one.

/// One installed extension, as the list in Settings shows it.
struct Installed: Codable, Identifiable, Equatable {
    /// The Chrome Web Store id, or for one loaded from a folder the id
    /// Chrome would give it ("local-…" in lists written before that).
    let id: String
    var name: String
    var version: String
    var enabled: Bool
    var fromStore: Bool
    /// The permissions it was installed with, so an update that asks for more
    /// is asked about rather than slipped through.
    var permissions: [String]
    /// Kept in the row beside the menu rather than only in it. Optional, so
    /// a list written before there was pinning still reads.
    var pinned: Bool? = nil
    /// For one loaded from a folder: where that folder is, so Reload can
    /// bring the author's latest edits in. Kept with its links resolved:
    /// the path its id was worked out from.
    var source: String? = nil

    /// Whether Reload may copy from `source` under this id: a link put on
    /// the way since would bring in another folder, which has another id.
    /// "local-…" ids came from no path, and reload as they always did.
    var sourceKeepsID: Bool {
        guard let source, !fromStore, !id.hasPrefix("local-") else { return true }
        return Crx.unpackedID(for: URL(fileURLWithPath: source, isDirectory: true)) == id
    }
}

@available(macOS 15.4, *)
@MainActor
final class Extensions: NSObject, ObservableObject {
    /// Each profile's extensions are its own: installed there, run by a
    /// controller of its own with its own storage, and shown only that
    /// profile's tabs — one profile's never read another's (H2 in the
    /// audit). Made the first time the profile needs them. Personal's are
    /// the ones there always were, where they always were.
    static var made: [UUID: Extensions] = [:]

    static func of(_ profile: UUID) -> Extensions {
        if let known = made[profile] { return known }
        let new = Extensions(profile: profile)
        made[profile] = new
        // Made after launch, for a profile gone to for the first time: it
        // starts as the first did, once whatever asked for it is done.
        if let first = launchedWith {
            DispatchQueue.main.async { [weak first] in
                MainActor.assumeIsolated { if let first { new.start(for: first) } }
            }
        }
        return new
    }

    /// The profile in front's: what the toolbar, Settings and an install act on.
    static var shared: Extensions { of((Browsers.front ?? Browsers.primary)?.profileID ?? Profile.personalID) }
    /// Every profile's made so far.
    static var all: [Extensions] { Array(made.values) }
    /// Whose this extension is: the profile that loaded it.
    static func owner(of context: WKWebExtensionContext) -> Extensions? {
        made.values.first { $0.contexts.values.contains { $0 === context } }
    }
    /// Whose this controller is.
    static func owner(of controller: WKWebExtensionController?) -> Extensions? {
        controller.flatMap { controller in made.values.first { $0.controller === controller } }
    }

    /// Where a yes given to one extension is kept: "private" (let into
    /// private tabs) or "granted" (permissions asked for later). Per
    /// profile, as SiteMemory keeps sites: the same extension installed in
    /// two profiles is asked in each, and a yes in one never answers for
    /// the other. Personal's are the keys there always were.
    static func grantKey(_ kind: String, _ id: String, _ profile: UUID) -> String {
        SiteMemory.key("extensions.\(kind).", id, profile)
    }

    /// The same, for a running extension — or one being loaded, whose
    /// profile is named since no profile holds it yet: no owner, no yes.
    static func grantKey(_ kind: String, _ context: WKWebExtensionContext, profile: UUID? = nil) -> String {
        guard let profile = profile ?? owner(of: context)?.profile else { return "extensions.\(kind).unowned" }
        return grantKey(kind, context.uniqueIdentifier, profile)
    }
    /// The first window, once extensions have started with it.
    private static weak var launchedWith: Browser?

    /// At launch: Personal's start, and any other profile's made by then.
    static func launch(with browser: Browser) {
        launchedWith = browser
        _ = of(Profile.personalID)
        for extensions in made.values { extensions.start(for: browser) }
    }

    /// Every page view built for a tab is handed its profile's controller
    /// at birth — it can't be given one later.
    func attach(_ configuration: WKWebViewConfiguration) {
        configuration.webExtensionController = controller
        ExtensionWorkerRecovery.shared.attach(configuration.userContentController)
    }

    let profile: UUID
    var isPersonal: Bool { profile == Profile.personalID }
    let controller: WKWebExtensionController
    @Published var installed: [Installed] = []
    /// The loaded ones, by id.
    @Published var contexts: [String: WKWebExtensionContext] = [:]
    /// Bumped when any extension's button changes — icon, badge, enabled.
    @Published var actionsChanged = 0
    @Published var busy: String?
    /// Errors an extension's pages and worker ran into, newest last, a few
    /// dozen at most per extension.
    @Published var errors: [String: [String]] = [:]

    func noteError(_ text: String, for id: String) {
        var list = errors[id] ?? []
        list.append(text)
        errors[id] = Array(list.suffix(40))
    }

    /// The browser to act in when an extension opens something or is told
    /// something: the window in front's (see Windows.swift), if it shows
    /// this profile, or else one that does. None when no window shows it:
    /// a window of another profile would hand the extension that profile's
    /// history, bookmarks, cookies and tabs.
    var browser: Browser? {
        if let front = Browsers.front ?? Browsers.primary, front.profileID == profile { return front }
        return Browsers.all.first { $0.profileID == profile }
    }
    var adapters: [Tab.ID: ExtensionTab] = [:]
    /// Each window's row as WebKit last heard it, by browser.
    var orders: [ObjectIdentifier: [Tab.ID]] = [:]
    var watching: [Tab.ID: [AnyCancellable]] = [:]
    private var bag = Set<AnyCancellable>()
    /// Each window's adapter, by browser.
    var windows: [ObjectIdentifier: ExtensionWindow] = [:]
    /// Each window's subscriptions to its row and its tab in front.
    var following: [ObjectIdentifier: [AnyCancellable]] = [:]
    /// A tab gone from one window's row into another's, and where it was.
    var inTransit: [Tab.ID: (window: ObjectIdentifier, orders: [String: [Tab.ID]])] = [:]
    /// Every extension switched on has loaded, at launch.
    private(set) var started = false
    /// Waiting for that (see whenStarted).
    private var onStarted: [() -> Void] = []
    /// The window in front's adapter.
    var window: ExtensionWindow? { browser.map(window(of:)) }

    func window(of browser: Browser) -> ExtensionWindow {
        let key = ObjectIdentifier(browser)
        if let known = windows[key] { return known }
        let made = ExtensionWindow(owner: self, browser: browser)
        windows[key] = made
        return made
    }
    /// Where each extension's button is on screen, for its popup to hang from.
    var anchors: [String: WeakView] = [:]

    static var folder: URL { Store.folder.appendingPathComponent("Extensions", isDirectory: true) }

    /// An extension's pages are served from chrome-extension://<id>/, the
    /// address they have in Chrome — Shy uses the same ids. Servers allow
    /// their own extension in by that origin (Raindrop's refuses any other),
    /// and sites look for an extension at it. WebKit's own
    /// webkit-extension:// is what Shy used before; addresses kept from
    /// then are read as the new ones.
    static let scheme = "chrome-extension"
    static let formerScheme = "webkit-extension"

    static func current(_ url: URL) -> URL {
        guard url.scheme == formerScheme, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        parts.scheme = scheme
        return parts.url ?? url
    }
    /// This profile's: Personal's in the folder itself, as always; another's
    /// in a folder of its own under it, which no extension id is named.
    var home: URL {
        isPersonal ? Extensions.folder : Extensions.folder.appendingPathComponent("profiles/\(profile.uuidString)", isDirectory: true)
    }
    var list: URL { home.appendingPathComponent("installed.json") }
    func folder(for id: String) -> URL { home.appendingPathComponent(id, isDirectory: true) }
    func stagingFolder(for id: String) -> URL {
        home.appendingPathComponent(".staging-\(id)-\(UUID().uuidString)", isDirectory: true)
    }
    /// A setting of this profile's own: Personal's under the key there always was.
    func key(_ name: String) -> String { SiteMemory.key(name, profile) }

    /// One loaded from a folder is copied in links and all, and both WebKit,
    /// serving its files, and the shim, rewriting its pages, go where a link
    /// points. So a link stays only if what it names is there and inside the
    /// package; one leading anywhere else, or nowhere, is taken out. (A
    /// package from the store with any link in it is refused whole: see
    /// Crx.) Throws if one couldn't be taken out.
    nonisolated static func unlinkOutside(_ root: URL) throws {
        guard let base = realpath(root.path, nil) else { return }
        let inside = String(cString: base) + "/"
        free(base)
        let files = FileManager.default
        let found = files.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey])
        while let item = found?.nextObject() as? URL {
            guard (try? item.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true else { continue }
            var kept = false
            if let real = realpath(item.path, nil) {
                kept = String(cString: real).hasPrefix(inside)
                free(real)
            }
            if !kept { try files.removeItem(at: item) }
        }
    }

    private init(profile: UUID) {
        self.profile = profile
        WKWebExtension.MatchPattern.registerCustomURLScheme(Extensions.scheme)
        // A test run keeps its extensions' storage apart, as it does its
        // cookies and passwords. Another profile's is its own, under the
        // profile's id, as its sign-ins are.
        let configuration: WKWebExtensionController.Configuration = profile != Profile.personalID
            ? .init(identifier: Store.webKitID(profile))
            : Store.testing && !Store.ownContainer ? .init(identifier: Store.probeStore(2)) : .default()
        let websites = Profiles.store(profile)
        configuration.defaultWebsiteDataStore = websites
        let views = configuration.webViewConfiguration ?? WKWebViewConfiguration()
        // Its own configuration starts with WebKit's default store; an
        // extension's pages keep what they store where the browser does —
        // and a test run's apart from the real one's.
        views.websiteDataStore = websites
        // The same user agent as the web tabs, to the letter. WebKit gives
        // workers the user agent of the last page that loaded and, when it
        // differs, stops the running workers to apply it — and extension
        // workers it then never starts again: every page that opened killed
        // the extensions. Extensions are told they run in Chrome by the shim
        // instead (navigator.userAgent in their pages and workers).
        views.applicationNameForUserAgent = Web.userAgentName
        // A test run sits behind other windows, where WebKit slows its views
        // to a crawl and messages between an extension's popup and its
        // worker stop arriving. Not what anyone is testing.
        if Store.testing, !Store.measuring { views.preferences.inactiveSchedulingPolicy = .none }
        // Screen recording: an extension's pages ask Shy through this,
        // which knows which page is asking (see ExtensionCapture).
        views.userContentController.addScriptMessageHandler(ExtensionCapture.shared, contentWorld: .page, name: ExtensionCapture.channel)
        pages = views.userContentController
        ExtensionWorkerRecovery.shared.attach(views.userContentController)
        ExtensionCapture.mockDevices(views.preferences)
        configuration.webViewConfiguration = views
        controller = WKWebExtensionController(configuration: configuration)
        super.init()
        controller.delegate = self
        installed = (try? JSONDecoder().decode([Installed].self, from: Data(contentsOf: list))) ?? []
    }

    // MARK: - starting

    func start(for browser: Browser) {
        attach(browser)
        let begin: @MainActor () -> Void = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await forgetWorkersIfChanged()
                await forgetLeftOver()
                // One after another, a moment apart: started all at once, WebKit
                // fails some of their workers and never tries them again.
                let enabled = installed.filter(\.enabled)
                for (n, item) in enabled.enumerated() {
                    await load(item)
                    if n < enabled.count - 1, contexts[item.id]?.webExtension.hasBackgroundContent == true {
                        try? await Task.sleep(for: .milliseconds(400))
                    }
                }
                markStarted()
                // Their rules, built as they loaded (Trim.swift).
                Trim.rulesBuilt()
                checkForUpdates()
            }
        }
        // Once the window is up: loading one takes the main thread for tens
        // of milliseconds (uBlock Origin Lite, 45), and the first frame
        // waited behind it. A launch started hidden has no frame to wait
        // for, and waited a second or so for a window that doesn't show
        // while the page it restored loaded without its extensions (#199).
        if NSApp.isHidden { begin() } else { Links.onceShown(begin) }
    }

    /// Whether a page loaded now would miss extensions still to load.
    var starting: Bool { !started && installed.contains(where: \.enabled) }

    /// Runs once every extension switched on has loaded, or after `limit`
    /// seconds, whichever comes first — for a page that should have its
    /// extensions' early scripts, and shouldn't wait forever for them.
    func whenStarted(within limit: TimeInterval, _ then: @escaping () -> Void) {
        guard starting else { return then() }
        var done = false
        let once: @MainActor () -> Void = {
            guard !done else { return }
            done = true
            then()
        }
        onStarted.append(once)
        DispatchQueue.main.asyncAfter(deadline: .now() + limit) { MainActor.assumeIsolated { once() } }
    }

    private func markStarted() {
        started = true
        let waiting = onStarted
        onStarted = []
        waiting.forEach { $0() }
    }

    // MARK: - workers WebKit remembers

    /// WebKit keeps each extension's service worker registered from one
    /// launch to the next, with the scripts it fetched then, and may start
    /// that copy rather than what is on disk now. A copy from another build
    /// of the shim or another version of the extension can leave the worker
    /// dead for good — reinstalling, reloading and restarting all bring the
    /// same stale copy back (Vimium's keys stopped working, for one). WebKit
    /// lists no records for extension origins, so there is no clearing one
    /// extension's alone; clearing them all stops the workers that run. So
    /// it is done at launch, before any extension loads, and only when what
    /// they would run has changed since. Websites' workers go with them and
    /// are registered again on the next visit.
    private static let workersKey = "extensions.workers"

    private var workers: String {
        ([ExtensionShims.version] + installed.map { "\($0.id) \($0.version)" }.sorted()).joined(separator: "\n")
    }

    private func forgetWorkersIfChanged() async {
        guard Store.settings.string(forKey: key(Extensions.workersKey)) != workers else { return }
        await Profiles.store(profile).removeData(ofTypes: [WKWebsiteDataTypeServiceWorkerRegistrations], modifiedSince: .distantPast)
        Store.settings.set(workers, forKey: key(Extensions.workersKey))
    }

    /// An extension put in again, reloaded or found with its worker dead:
    /// the version alone doesn't tell, so the next launch clears regardless.
    func workersChanged() {
        Store.settings.removeObject(forKey: key(Extensions.workersKey))
    }

    /// An extension whose worker won't start again: unloaded and loaded,
    /// as a relaunch would — at most once a minute, so one that can never
    /// start doesn't go round in circles.
    var revived: [String: Date] = [:]
    var reloading: Set<String> = []
    /// Recent failed native messages, per extension and host.
    var failures: [String: [Date]] = [:]
    var nativePorts: [String: NSHashTable<WKWebExtension.MessagePort>] = [:]

    /// Loaded at least once since the browser started, and loaded again.
    var loadsThisRun: Set<String> = []
    var loadedBefore: Set<String> = []

    /// WebKit records a worker that failed to start as an error on its
    /// context, and then doesn't try again: the extension would be dead
    /// until someone noticed. It is taken up afresh as soon as that shows.
    var errorWatchers: [String: NSObjectProtocol] = [:]

    /// What removed extensions kept, still being cleared. The same folder
    /// loaded again, or another put at its path, gets the same id, and
    /// starts with nothing of the one before, as in Chrome: loading waits.
    var forgetting: [String: Task<Void, Never>] = [:]

    var updateClock: Timer?
    var updating: Set<String> = []

    /// The last question asked, so the next waits for its answer.
    var question: Task<Bool, Never>?
    /// For the bench, in a test run only: answer every question this way
    /// instead of asking. Nil asks.
    var answerForTests: Bool?
    /// What was asked, for the bench.
    var asked: [String] = []

    /// The list behind the puzzle button.
    @Published var menuOpen = false

    /// What every extension page's view in this profile shares, by which a
    /// tab knows it shows one (see ExtensionPageDelegate).
    weak var pages: WKUserContentController?
}
