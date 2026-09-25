import ImageIO
import SwiftUI
import WebKit

// One web view per tab, kept alive for as long as the tab is. Switching tabs
// takes the old view out of the window and puts the new one in — the page does
// not reload, does not lose its scroll position, and does not forget what you
// typed into it. That is the whole trick behind switching feeling instant.
//
// Kept alive, that is, while it is worth what it costs. A tab nobody has
// looked at for half an hour gives its view back (see `sleep(picture:)`) and
// keeps what it takes to come back exactly where it was.

enum Web {
    /// Where Search's own page scripts run, and where their messages come
    /// from: a world of their own beside the page's. They see the same page,
    /// and the page sees none of them — no variable of theirs, and no
    /// `window.webkit`, which Safari never shows a page and which sites read
    /// as an app's embedded web view rather than a browser. Google answered
    /// that with a CAPTCHA every few searches, and refused sign-ins as "not
    /// secure" (24 Sep 2026). Only Search's passkey patch has to stand in
    /// the page's own world, and nothing there leads back to it.
    @MainActor static let world = WKContentWorld.world(name: "Search")

    /// Every handler of Search's taken off a controller: in its own world,
    /// and in the page's, where they all were before 24 Sep 2026 — a tab
    /// opened by a link inherits its opener's configuration, handlers
    /// included, and registering a name twice is a hard crash.
    @MainActor static func release(_ controller: WKUserContentController) {
        for name in [ScrollRelay.name, VeilRelay.name, FormRelay.name, ImageRelay.name,
                     StoreRelay.name, PasskeyRelay.name, MiddleRelay.name] {
            controller.removeScriptMessageHandler(forName: name, contentWorld: world)
            controller.removeScriptMessageHandler(forName: name, contentWorld: .page)
        }
        controller.removeScriptMessageHandler(forName: HoveredLink.name, contentWorld: .defaultClient)
    }

    /// What every view says it is after "AppleWebKit … (KHTML, like Gecko)"
    /// — web tabs and extension views alike (see Extensions.init).
    ///
    /// The version is the Safari this Mac has, since its WebKit is the one
    /// every tab runs on. A fixed number went out of date with every macOS:
    /// a page told "Safari 26" by an engine that is Safari 18 sends what the
    /// engine can't run.
    static let userAgentName = "Version/\(safariVersion) Safari/605.1.15"

    private static var safariVersion: String {
        for path in ["/System/Cryptexes/App/System/Applications/Safari.app", "/Applications/Safari.app"] {
            if let version = Bundle(path: path)?.infoDictionary?["CFBundleShortVersionString"] as? String {
                return version
            }
        }
        // Safari can't be read: say the Safari this macOS shipped with, the
        // oldest its WebKit can be. Under-claiming gets a page older code
        // that still runs; over-claiming is what this avoids.
        //
        // This hardly ever runs. Safari can't be removed from modern macOS,
        // so reading the installed Safari above should always work. The
        // formula only matters if that read fails.
        //
        // From macOS 26 Safari shares its number; before, it was 3 ahead (14 -> 17, 15 -> 18).
        let os = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        return os >= 26 ? "\(os).0" : "\(os + 3).0"
    }

    /// One pool for every tab. The property is deprecated and said to do
    /// nothing now, but a configuration without it gets a pool of its own
    /// when its view is made — so every new tab started a web process from
    /// cold, fonts registered and all, on the main thread, before its page
    /// could begin: 41 to 59 ms from a bookmark or Return to the load
    /// starting, the window stuck meanwhile. Sharing one lets WebKit have
    /// the next process ready: 9 to 10 ms, for the same memory and the same
    /// number of processes (measured with ./bench bookmark URL new, 24 Sep 2026).
    static let pool = WKProcessPool()

    /// `space`: the space the tab belongs to, when it is not the one on
    /// screen — a parked row made ahead of time (see Spaces.swift).
    /// `store`: a shy tab's own, for one opened from it — a link followed
    /// out of a private page is still signed in to whatever that page was.
    static func configuration(shy: Bool = false, space: UUID? = nil, store: WKWebsiteDataStore? = nil) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        // The real store, not the ephemeral one: staying signed in between
        // launches is the difference between a browser and a preview pane. A
        // shy tab gets its own store, which exists only while it does — its own
        // cookies, its own sign-ins, and nothing left behind when it closes.
        // With spaces on, each space's tabs share a store of that space's.
        config.websiteDataStore = store ?? (shy ? .nonPersistent() : MainActor.assumeIsolated { Spaces.store(for: space ?? Spaces.current) })
        config.processPool = Web.pool
        // Chrome extensions see every page but a private one, unless Settings
        // › Extensions says they may. The controller has to be there when the
        // view is made; it can't be added after.
        if #available(macOS 15.4, *), !shy || Store.settings.bool(forKey: "extensions.private") {
            MainActor.assumeIsolated { Extensions.attach(config) }
        }
        // Left alone, WKWebView says only "AppleWebKit … (KHTML, like Gecko)" —
        // no browser, no version. Google reads that as something it doesn't
        // recognise and serves the stripped-back page from a decade ago:
        // no side panel, no dark mode, none of the modern tabs. Naming a
        // version turns it into the same string Safari sends, and the modern
        // page comes back.
        config.applicationNameForUserAgent = Web.userAgentName
        config.allowsAirPlayForMediaPlayback = true
        // Off by default on macOS, which is why a full-screen button on a video
        // did nothing at all: the page asks, and WebKit refuses without a word.
        config.preferences.isElementFullscreenEnabled = true
        // On by default on macOS: a page could open a new tab, and take you
        // to it, whenever it liked — on load, on a timer. Off, window.open
        // works only from a click or a key, as Safari's pop-up blocking has
        // it; a sign-in window opened by its button still opens.
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.mediaTypesRequiringUserActionForPlayback = .audio
        if Store.testing, !Store.measuring { config.preferences.inactiveSchedulingPolicy = .none }
        inspector(config.preferences)
        return config
    }

    /// Every page view there is, for the bench.
    @MainActor static let pages = NSHashTable<PageView>.weakObjects()

    /// WebKit's "developer extras": Inspect Element in a page's right-click
    /// menu, and the Web Inspector the View menu opens (see Inspector.swift).
    /// isInspectable alone only lets Safari's Develop menu reach the page.
    /// The name is outside the public framework, so it is asked first.
    static func inspector(_ preferences: WKPreferences, on: Bool = true) {
        let set = NSSelectorFromString("_setDeveloperExtrasEnabled:")
        guard preferences.responds(to: set) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(preferences.method(for: set), to: Setter.self)(preferences, set, on)
    }
}

/// WKWebView can pause a page's media, but not mute it and let it keep
/// playing, the one thing a tab's own speaker does everywhere else. WebKit
/// has that mute one call down from the public framework: the one Safari's
/// own tabs use, the page's JavaScript none the wiser. The names are asked
/// for first, the way `inspector(_:on:)` above asks, and a WebKit without
/// them leaves the tab heard rather than falling over.
enum Muter {
    /// `_mediaMutedState` is a bitmask. Its low bit is the page's own
    /// sound, the only one a tab's speaker should touch: the others are the
    /// camera and the microphone, someone else's to turn off.
    static func set(_ muted: Bool, on web: WKWebView) {
        let get = NSSelectorFromString("_mediaMutedState")
        let set = NSSelectorFromString("_setPageMuted:")
        guard web.responds(to: get), web.responds(to: set) else { return }
        typealias Read = @convention(c) (AnyObject, Selector) -> UInt
        typealias Write = @convention(c) (AnyObject, Selector, UInt) -> Void
        let state = unsafeBitCast(web.method(for: get), to: Read.self)(web, get)
        unsafeBitCast(web.method(for: set), to: Write.self)(web, set, muted ? state | 1 : state & ~UInt(1))
    }
}

@MainActor
final class Tab: ObservableObject, Identifiable {
    let id = UUID()

    /// The page. Built the first time anyone asks for it, not when the tab
    /// is — a session of twenty tabs coming back is twenty objects, not
    /// twenty web views and their processes fighting the first frame.
    var web: PageView {
        if let built { return built }
        let view = build()
        built = view
        return view
    }
    /// The web view if there is one yet, for the callers that must not be
    /// the reason there is.
    private(set) var built: PageView?
    private let configuration: WKWebViewConfiguration

    /// Whether its page was made with the extension controller in it — every
    /// ordinary tab, and a private one only when extensions were allowed
    /// there as it was made (a controller can't be added to a page later).
    @available(macOS 15.4, *)
    var carriesExtensions: Bool { configuration.webExtensionController != nil }
    /// Where its cookies and sign-ins are kept.
    var store: WKWebsiteDataStore { configuration.websiteDataStore }
    /// Whoever handles navigation and windows for this page; applied when
    /// the page is built, whenever that is.
    weak var delegate: (WKNavigationDelegate & WKUIDelegate)? {
        didSet {
            built?.navigationDelegate = delegate
            built?.uiDelegate = delegate
        }
    }
    /// The stylesheet a page not yet built is to be armed with.
    private var veils = ""

    @Published private(set) var title = ""
    @Published private(set) var address: URL?
    @Published private(set) var progress: Double = 0
    @Published private(set) var loading = false
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    /// Set when the page never arrived — no host, no network, a refused
    /// connection. Shown in place of the page rather than in a dialog.
    @Published var failure: String?
    /// How far down the page you are, nought to one. The tab's own pill fills
    /// with it.
    @Published var reading: Double = 0

    /// True while the page has been stripped back to its article.
    @Published private(set) var reader = false

    /// Leaving reading mode reloads rather than putting the old markup back:
    /// restoring the HTML gives you a page that looks right and does nothing,
    /// because every listener the page had was thrown away with it.
    func toggleReader(_ done: @escaping (Bool) -> Void) {
        guard !isBlank else {
            done(false)
            return
        }
        guard !reader else {
            reader = false
            web.reload()
            done(true)
            return
        }
        web.evaluateJavaScript(Reader.script) { [weak self] answer, _ in
            let worked = (answer as? String) == "read"
            if worked { self?.reader = true }
            done(worked)
        }
    }

    /// The site's icon, for tabs set to wear one. From the cache the moment
    /// the tab has an address, and from the page a moment after it loads.
    @Published var icon: NSImage?

    /// The letter a pinned tab is reduced to, and what a tab shows in place of
    /// an icon it doesn't have yet.
    var monogram: String {
        let host = address?.host()?.replacingOccurrences(of: "www.", with: "") ?? ""
        return host.first.map { String($0).uppercased() } ?? "•"
    }

    private func adoptIcon() {
        guard let host = address?.host()?.lowercased() else { return }
        icon = Favicons.shared.cached(host)
    }

    /// True while the caret is in something on the page that takes typing.
    @Published var typing = false
    /// True while the page has taken over the screen.
    @Published var immersed = false

    /// True while this tab's page is out in the little window.
    @Published var floating = false

    /// A sideways swipe in progress, for the disc that shows it.
    @Published var pull: Pull?

    /// Remembered for the site, not for the tab: setting a paper's type to
    /// 125% once should be the last time you think about it.
    func rememberZoom() {
        guard let host = address?.host(), !shy else { return }
        if abs(zoom - 1) < 0.01 {
            Store.settings.removeObject(forKey: "zoom." + host)
        } else {
            Store.settings.set(Double(zoom), forKey: "zoom." + host)
        }
    }

    func applyRememberedZoom() {
        guard let host = address?.host() else { return }
        let kept = Store.settings.object(forKey: "zoom." + host) as? Double ?? 1
        guard abs(CGFloat(kept) - web.pageZoom) > 0.004 else { return }
        web.pageZoom = CGFloat(kept)
        zoom = CGFloat(kept)
    }

    /// How much bigger the page is being drawn. Not a magnifying glass over
    /// the rendered page — the page is laid out again at this size, so text
    /// stays as sharp at 200% as it was at 100%.
    @Published private(set) var zoom: CGFloat = 1

    /// Where the page is and which way it just went, for anything that wants
    /// to follow along.
    var onScroll: ((Tab, Double, Double) -> Void)?
    var onZoom: ((Tab, CGFloat) -> Void)?
    /// The resolved address under the pointer, or nil when it leaves a link.
    var onLink: ((Tab, String?) -> Void)?

    /// True while something on the page is making noise, so the row can say
    /// which tab it is coming from.
    @Published var noisy = false
    /// Silenced by hand from its speaker or its menu: the page plays on and
    /// is not heard. WebKit keeps the mute on the view from one page to the
    /// next, so it is only set again on a view built new, as a sleeping tab
    /// wakes (see build()).
    @Published var muted = false

    /// Not `web`: a tab asleep is muted without being woken, and hears of
    /// it when its page is built again.
    func toggleMute() {
        muted.toggle()
        if let built { Muter.set(muted, on: built) }
    }

    /// What the page hands back when you point at something and click it.
    var onPick: ((Tab, String, String, String) -> Void)?
    /// The page has a sign-in on it; the page has just sent one.
    var onSignIn: ((Tab) -> Void)?
    /// The caret has entered or left one of the sign-in boxes; where the box
    /// is, in the web view's points, or nil when it has left.
    var onField: ((Tab, CGRect?) -> Void)?
    /// The site the sign-in was sent from — not the one it landed on —
    /// then the name and the password, and whether that page came over
    /// plain http.
    var onCredentials: ((Tab, String, String, String, Bool) -> Void)?
    var onPickEnd: ((Tab) -> Void)?
    var onPickTrouble: ((Tab, String) -> Void)?
    /// Right-click landed on an image. WebKit's own menu offers to copy or
    /// download it and then, on at least some sites, does neither — see
    /// ImageMenu.swift for why this is built rather than patched.
    var onImageMenu: ((Tab, URL) -> Void)?
    var searchName: (() -> String?)?
    var onSearch: ((Tab, String) -> Void)?
    /// "Add to Search" was pressed on the Chrome Web Store page this tab shows.
    var onStoreAdd: ((Tab) -> Void)?
    /// The middle button was let go over a link. The browser opens it in a
    /// tab of its own beside this one, without leaving the page you are on.
    var onMiddleClick: ((Tab, URL) -> Void)?
    /// Sent where this tab's view can't go: from an extension's page to the
    /// web or another extension, or from the web to an extension's page.
    /// WebKit keeps each kind of view to its own pages, so the tab has to be
    /// swapped for one built for the address (see Browser.replace).
    var onCross: ((Tab, URL) -> Void)?
    /// The extension whose store page has its own "Add to Search" button in
    /// place — so the bar at the bottom of the window doesn't offer it twice.
    @Published var storePlaced: String?

    private let relay = ScrollRelay()
    private let veils_ = VeilRelay()
    private let forms = FormRelay()
    private let images = ImageRelay()
    private let shop = StoreRelay()
    private let middles = MiddleRelay()
    private let passkeyRelay = PasskeyRelay()
    private let hovered = HoveredLink()
    private let ears = AudioWatch()
    private var lastY: Double = 0

    /// A tab that keeps nothing: its own cookies, no history, no place in the
    /// session. Signed in as nobody, and forgotten when it goes.
    let shy: Bool

    /// A tab a script opened through the bench, beside yours. Signed in as
    /// you, so it sees what you see — but never selected for you, never in
    /// the session or the history, and gone when the script is done.
    let bench: Bool

    /// The tab whose page opened this one, when a script did. Sign-in flows
    /// hand you back to it when they are done.
    var opener: Tab.ID?

    /// A window a page opened at a size of its own, or without a toolbar:
    /// a pop-up, not a link. It is named by its site, never by its title — a
    /// page that opens one can call it anything, "Sign in with Google" over
    /// somebody else's address included.
    var popup = false

    /// One letter, when the tab has been pinned. A pinned tab keeps its place
    /// at the head of the row and gives up its title for that letter — which
    /// is all you need for the five or six pages you keep open all day.
    @Published var pin: String?

    /// A name you gave it, in place of whatever the page calls itself. It
    /// stays through navigation: a tab you named is a tab you are keeping for
    /// a job, not for a page.
    @Published var name: String?

    /// When you last looked at it. The summon lists pages by this, because
    /// what you were just reading is what you are most likely to want back.
    private(set) var touched = Date()

    /// Set on a tab brought back from the last session and not yet opened. It
    /// has a name and an address in the row, and costs nothing until you go to
    /// it — which is the difference between a browser that starts in half a
    /// second with twenty tabs and one that doesn't.
    private(set) var pending: URL?

    /// For a tab put to sleep for not being looked at: the page's own history
    /// — the back list, the page, where it was scrolled to — handed to the
    /// view built to wake it, so it opens exactly where this one was left.
    private var memory: Any?
    /// The last picture of that page, compressed, for the moment it wakes.
    private var picture: Data?
    /// That picture, over the stage while the page is rebuilt underneath it:
    /// coming back to a tab that slept starts from what you left, not white.
    @Published private(set) var cover: NSImage?

    private var watch: [NSKeyValueObservation] = []

    /// A tab that has never been anywhere shows the address field instead of a
    /// page. It still owns a web view — built now, warm by the time it's needed.
    var isBlank: Bool { address == nil }

    /// The title if the page has offered one, the address until it does. A tab
    /// that says nothing at all for the first second of every load is a tab you
    /// can't find your way back to.
    var label: String {
        if let name, !name.isEmpty { return name }
        if popup, let host = address?.host(), !host.isEmpty {
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        if !title.isEmpty { return title }
        if let address { return Address.pretty(address) }
        return "New Tab"
    }

    init(shy: Bool = false, bench: Bool = false, configuration: WKWebViewConfiguration? = nil) {
        self.shy = shy
        self.bench = bench
        self.configuration = configuration ?? Web.configuration(shy: shy)
    }

    private func build() -> PageView {
        // Here rather than in Web.configuration: a tab's configuration is
        // made with the tab, often long before its page, and a site or an
        // extension can hand over one of its own.
        FrameRate.apply(to: configuration.preferences)
        let web = PageView(frame: .zero, configuration: configuration)
        // The trackpad pinch is WebKit's own: it magnifies what is on screen
        // and lets you move around inside it, the way pinching does everywhere
        // else on a Mac. ⌘+ and ⌘- are the other thing — they lay the page out
        // again at a bigger size — and both are worth having.
        web.allowsMagnification = true
        // WebKit's own two-finger swipe stays off. It drags the page across
        // the window with a picture of the last one behind it; ours is in
        // PageView, and it moves nothing but a disc.
        web.allowsBackForwardNavigationGestures = false
        Swipe.calm(web)
        web.onPull = { [weak self] pull in self?.pull = pull }
        web.onTouch = { [weak self] in self?.uncover() }
        web.searchName = { [weak self] in self?.searchName?() }
        web.onSearch = { [weak self] text in
            guard let self else { return }
            self.onSearch?(self, text)
        }
        web.holdForFirstFrame()
        // Pages follow the appearance of the window they are drawn in, and the
        // window follows Settings › Appearance — so a site that honours
        // prefers-color-scheme goes dark with the frame, and not otherwise.
        // Safari's Develop menu can reach it, and so can the page's own
        // Inspect Element — a configuration handed over by an opener included.
        if #available(macOS 13.3, *) { web.isInspectable = true }
        Web.pages.add(web)
        Web.inspector(web.configuration.preferences)
        web.navigationDelegate = delegate
        web.uiDelegate = delegate

        // Each name is cleared before being claimed — registering one twice is
        // a hard crash rather than an error. A tab opened by a link gets a
        // controller of its own (Browser's createWebViewWith), never its
        // opener's.
        let controller = web.configuration.userContentController
        Web.release(controller)
        controller.add(relay, contentWorld: Web.world, name: ScrollRelay.name)
        controller.add(veils_, contentWorld: Web.world, name: VeilRelay.name)
        controller.add(images, contentWorld: Web.world, name: ImageRelay.name)
        controller.add(shop, contentWorld: Web.world, name: StoreRelay.name)
        controller.add(forms, contentWorld: Web.world, name: FormRelay.name)
        controller.addScriptMessageHandler(passkeyRelay, contentWorld: Web.world, name: PasskeyRelay.name)
        hovered.tab = self
        controller.add(hovered, contentWorld: .defaultClient, name: HoveredLink.name)
        controller.add(middles, contentWorld: Web.world, name: MiddleRelay.name)
        Shield.shared.protect(controller)
        built = web
        // A tab muted before it went to sleep wakes muted.
        if muted { Muter.set(true, on: web) }
        arm(hiding: veils)

        watch = [
            web.observe(\.title, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.title = self?.built?.title ?? "" }
            },
            web.observe(\.url, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    guard let self, let fresh = self.built?.url else { return }
                    // about:blank is never a destination. Putting a pinned tab
                    // to sleep loads it deliberately to make WebKit give the
                    // page back — and letting that overwrite the address is how
                    // a pinned tab lost the only thing that could bring it
                    // back, and vanished from the session altogether.
                    guard fresh.absoluteString != "about:blank" else { return }
                    let moved = fresh.host() != self.address?.host()
                    self.address = fresh
                    if moved { self.adoptIcon() }
                }
            },
            web.observe(\.estimatedProgress, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.progress = self?.built?.estimatedProgress ?? 0 }
            },
            web.observe(\.isLoading, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.loading = self?.built?.isLoading ?? false }
            },
            web.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.canGoBack = self?.built?.canGoBack ?? false }
            },
            web.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.canGoForward = self?.built?.canGoForward ?? false }
            },
        ]

        relay.tab = self
        veils_.tab = self
        forms.tab = self
        images.tab = self
        shop.tab = self
        middles.tab = self
        ears.watch(web) { [weak self] on in self?.noisy = on }
        return web
    }

    /// Between two fifths and three times, which is as far as a page is worth
    /// pushing in either direction.
    func magnify(to value: CGFloat) {
        let wanted = min(3, max(0.4, value))
        guard abs(wanted - web.pageZoom) > 0.004 else { return }
        web.pageZoom = wanted
        zoom = wanted
        rememberZoom()
        onZoom?(self, wanted)
    }

    func magnify(by factor: CGFloat) { magnify(to: web.pageZoom * factor) }

    /// ⌘0 undoes both kinds of zoom at once — whichever one you reached for.
    func resetZoom() {
        magnify(to: 1)
        guard web.magnification != 1 else { return }
        web.magnification = 1
        onZoom?(self, 1)
    }

    // MARK: - taking things off the page

    /// What gets injected into the *next* document: the scroll reporter, the
    /// pointing mode, and this site's stylesheet of things you have hidden. The
    /// stylesheet goes in before the document has a body, so nothing is ever
    /// seen arriving and then leaving again.
    func arm(hiding css: String) {
        veils = css
        guard let built else { return }
        let controller = built.configuration.userContentController
        controller.removeAllUserScripts()
        controller.addUserScript(
            WKUserScript(source: ScrollRelay.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: Web.world)
        )
        controller.addUserScript(
            WKUserScript(source: Veiling.picker, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: Web.world)
        )
        controller.addUserScript(
            WKUserScript(source: FormRelay.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: Web.world)
        )
        if AutoScroll.on {
            controller.addUserScript(
                WKUserScript(source: AutoScroll.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: Web.world)
            )
        }
        // Every frame: a swipe over an embedded map is the map's, and only the
        // map's own document can say so.
        controller.addUserScript(
            WKUserScript(source: Swipe.watch, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: Web.world)
        )
        controller.addUserScript(
            WKUserScript(source: ImageRelay.watch, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: Web.world)
        )
        // The store's "Add to Search" only where Search can add extensions.
        // Before macOS 15.4 it was drawn all the same, and pressing it did
        // nothing at all; Settings › Extensions says what they need instead.
        if #available(macOS 15.4, *) {
            controller.addUserScript(
                WKUserScript(source: StoreRelay.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: Web.world)
            )
        }
        // Only while Settings says so: off, pages get nothing at all.
        if HoveredLink.on {
            controller.addUserScript(WKUserScript(
                source: HoveredLink.script, injectionTime: .atDocumentStart,
                forMainFrameOnly: false, in: .defaultClient
            ))
        }
        // The main frame only: a middle-click on a link inside an ad iframe is
        // that frame's own business, and its link is not this tab's to open.
        controller.addUserScript(
            WKUserScript(source: MiddleRelay.watch, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: Web.world)
        )
        // Passkeys stand in the page's own world — they replace the page's
        // functions — and reach Search through a bridge in Search's, off or on:
        // an extension's page script can carry the patch either way (see
        // Passkeys.swift and ExtensionShims.passkeys).
        if !FormRelay.passkeysOffered {
            controller.addUserScript(
                WKUserScript(source: FormRelay.withoutPasskeys, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
            )
        } else {
            controller.addUserScript(
                WKUserScript(source: PasskeyRelay.page, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
            )
        }
        controller.addUserScript(
            WKUserScript(source: PasskeyRelay.bridge, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: Web.world)
        )
        guard !css.isEmpty else { return }
        controller.addUserScript(
            WKUserScript(source: Veiling.style(css), injectionTime: .atDocumentStart, forMainFrameOnly: true, in: Web.world)
        )
    }

    /// The same stylesheet, for the page that is already up.
    func applyVeils(_ css: String) {
        built?.evaluateInSearch(Veiling.style(css))
    }

    func startPicking() { web.evaluateInSearch("window.__officeVeil && window.__officeVeil.on()") }
    func stopPicking() { web.evaluateInSearch("window.__officeVeil && window.__officeVeil.off()") }

    func foundSignIn() { onSignIn?(self) }

    /// From the page, in CSS pixels; passed on in points. Page zoom is the
    /// only scale between the two that matters here.
    func fieldFocused(_ rect: CGRect?) {
        guard let rect else {
            onField?(self, nil)
            return
        }
        let zoom = built?.pageZoom ?? 1
        onField?(self, CGRect(
            x: rect.minX * zoom, y: rect.minY * zoom,
            width: rect.width * zoom, height: rect.height * zoom
        ))
    }

    /// A name and password the page has just sent — held, not yet offered.
    /// Whether the sign-in worked is only known afterwards: a page that
    /// comes back without a password box took it, one that still has the
    /// box refused it, and only the first is worth remembering.
    private var sent: (host: String, user: String, password: String, clear: Bool, at: Date)?

    func sentSignIn(user: String, password: String) {
        // The host now, while the page is still the sign-in page: a moment
        // later it may be somewhere else entirely, and that is not where
        // the password belongs.
        guard let host = address?.host()?.lowercased() else { return }
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        sent = (bare, user, password, address?.scheme?.lowercased() == "http", Date())
    }

    /// The page has moved on — a new document has loaded, or the sign-in
    /// fields have gone. If a password went out recently and there is no
    /// longer a box for it, that is a sign-in that took.
    ///
    /// A new document is judged at once. Fields that a page removed by
    /// itself are given a moment first: a sign-in built into the page closes
    /// its form the instant you press the button and puts it back if the
    /// server says no — and offering in between is offering a password that
    /// may be wrong.
    func settleSignIn(navigated: Bool = true) {
        guard let sent else { return }
        guard Date().timeIntervalSince(sent.at) < 45 else {
            self.sent = nil
            return
        }
        guard navigated else {
            let stamp = sent.at
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                // Only if nothing newer went out in the meantime.
                guard let self, self.sent?.at == stamp else { return }
                self.settleSignIn(navigated: true)
            }
            return
        }
        web.evaluateInSearch("!!(window.__officeForms && window.__officeForms.hasPassword())") { [weak self] still in
            MainActor.assumeIsolated {
                guard let self, let sent = self.sent else { return }
                // The box is still there: a refused sign-in, or the second
                // step of one. Kept for a moment longer, in case the page is
                // still on its way.
                if (still as? Bool) == true { return }
                self.sent = nil
                self.onCredentials?(self, sent.host, sent.user, sent.password, sent.clear)
            }
        }
    }

    /// Puts a remembered name and password where a person would have typed
    /// them. Nothing is echoed back and nothing is written down here.
    /// `done`, when given, hears back `false` for the one case worth saying
    /// something about: the sign-in fields that were there a moment ago,
    /// when this was offered, are gone by the time it actually runs.
    func fill(user: String, password: String, done: ((Bool) -> Void)? = nil) {
        web.evaluateInSearch(
            "window.__officeForms && window.__officeForms.fill(`\(escape(user))`, `\(escape(password))`)"
        ) { result in
            done?((result as? Bool) ?? false)
        }
    }

    func picked(selector: String, label: String, note: String) {
        onPick?(self, selector, label, note)
    }

    /// Show one hidden thing while the pointer rests on its row in the list.
    func peek(_ selector: String, keeping css: String) {
        web.evaluateInSearch(
            "window.__officeVeil && window.__officeVeil.peek(`\(escape(css))`, `\(escape(selector))`)"
        )
    }

    func unpeek(_ css: String) {
        web.evaluateInSearch("window.__officeVeil && window.__officeVeil.unpeek(`\(escape(css))`)")
    }

    private func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")
    }
    func pickingEnded() { onPickEnd?(self) }
    func pickingFailed(_ reason: String) { onPickTrouble?(self, reason) }

    /// Called from the page, a few dozen times a second at most — the script
    /// already waits for a frame before it says anything.
    func scrolled(to y: Double, of ceiling: Double) {
        // In hundredths, and only when that changes. The page reports once a
        // frame while it scrolls — 120 times a second on a 120 Hz screen — and
        // each new value had the window redraw the tab's fill, a third of a
        // core on the thread WebKit needs to put the scrolled page on screen.
        let fraction = ceiling > 0 ? (min(1, max(0, y / ceiling)) * 100).rounded() / 100 : 0
        if fraction != reading { reading = fraction }
        let delta = y - lastY
        lastY = y
        onScroll?(self, y, delta)
    }

    func go(to url: URL) {
        // Judged by the page it shows, not by how it was made: a tab an
        // extension's page opened with window.open is built from that
        // extension's configuration too. A tab with no page yet was just
        // built for where it is going, so it goes there.
        if let onCross, let here = built?.url ?? address,
           Browser.extensionHost(of: here) != Browser.extensionHost(of: url) {
            onCross(self, url)
            return
        }
        // Set straight away rather than waiting for the observer: the tab has to
        // stop being blank in the same frame the field disappears, or the empty
        // state flashes back for an instant on its way out.
        address = url
        title = ""
        failure = nil
        reading = 0
        lastY = 0
        reader = false
        typing = false
        immersed = false
        // Sent somewhere new, a sleeping tab is simply awake again — with
        // nothing of where it was before to bring back.
        pending = nil
        memory = nil
        picture = nil
        cover = nil
        adoptIcon()
        web.open(url)
    }

    /// Brought back from the last session: everything the row needs to draw it,
    /// and nothing fetched.
    func restore(url: URL, title: String, name: String? = nil) {
        address = url
        self.title = title
        self.name = name
        pending = url
        adoptIcon()
    }

    /// True for a tab that has a place and an address but is holding no page —
    /// brought back from the last session, or put down with ⌘W while pinned.
    var asleep: Bool { pending != nil }

    /// ⌘W on a pinned tab. The letter keeps its place in the row and the
    /// address is remembered; everything the page was holding is let go, so a
    /// pin you are not reading costs a line in a file and nothing else.
    func rest() {
        guard let url = address else { return }
        pending = url
        memory = nil
        picture = nil
        reading = 0
        lastY = 0
        noisy = false
        stale = false
        pull = nil
        // Loading about:blank here looked like letting the page go, and
        // wasn't: WebKit keeps the document it just left in the back-forward
        // cache — alive, suspended, and still counted by its own origin as an
        // open tab. Coming back then started a second x.com beside a first
        // that would never answer, and the second waited for it until you
        // gave up and reloaded by hand. Only tearing the view down ends the
        // page; the next wake() builds a fresh one, and a fresh one boots.
        discard()
    }

    /// Nobody has looked at this page for a while. Its view goes, as with a
    /// pin put down by hand, but its history and a picture of it stay: the
    /// view built to wake it opens the same page, at the same place, with
    /// Back still going back. What was typed and not sent is the one thing
    /// that can't come back, which is why the browser asks `unsaved` first.
    func sleep(picture: Data?) {
        guard let url = address, let built else { return }
        memory = built.interactionState
        self.picture = picture
        pending = url
        stale = false
        pull = nil
        discard()
    }

    /// Whether the page holds something typed and not yet sent — a draft, a
    /// half-filled form. A page that can't answer is treated as holding
    /// nothing: a PDF, an image, a page whose process has already gone.
    func unsaved(_ done: @escaping (Bool) -> Void) {
        guard let built else { return done(false) }
        built.evaluateInSearch(
            "!!(window.__officeForms && window.__officeForms.unsaved && window.__officeForms.unsaved())"
        ) { value in
            MainActor.assumeIsolated { done((value as? Bool) == true) }
        }
    }

    /// The page as it looks right now, compressed. Drawn by the page's own
    /// process, so a view that is off screen — every tab but the one you are
    /// on — can still be pictured. Nil when there is nothing to draw.
    func snapshot(_ done: @escaping (Data?) -> Void) {
        guard let built else { return done(nil) }
        built.takeSnapshot(with: nil) { image, _ in
            guard let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                return done(nil)
            }
            DispatchQueue.global(qos: .utility).async {
                let data = Tab.jpeg(cg)
                DispatchQueue.main.async { done(data) }
            }
        }
    }

    nonisolated private static func jpeg(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let out = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(out, image, [kCGImageDestinationLossyCompressionQuality: 0.55] as CFDictionary)
        return CGImageDestinationFinalize(out) ? data as Data : nil
    }

    /// What the store page's own button should say: added, on its way, or
    /// free to add.
    func tellStore(installed: [String], busy: String?) {
        guard let built,
              let data = try? JSONSerialization.data(withJSONObject: ["installed": installed, "busy": busy.map { $0 as Any } ?? NSNull()]),
              let json = String(data: data, encoding: .utf8)
        else { return }
        built.evaluateInSearch("window.__officeStore && window.__officeStore.state(\(json))")
    }

    /// The picture comes off the moment there is something better under it
    /// — the page, painted — or you reach for the page yourself.
    func uncover(after delay: TimeInterval = 0) {
        guard let shown = cover else { return }
        guard delay > 0 else {
            cover = nil
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.cover === shown else { return }
            self.cover = nil
        }
    }

    /// Set when WebKit said the page's process went away while nobody was
    /// looking at the tab. Coming back to it loads the page again rather
    /// than showing the white that is left.
    var stale = false

    /// The process behind this page just died while it was the one on
    /// screen. `reload()`/`reloadFromOrigin()` lean on state the dead
    /// process was keeping — asking for the address back instead is the
    /// same trick `revive()` and the hollow branch of `reload()` already
    /// use, and the one that doesn't depend on anything the crash took with
    /// it. Tried twice: right after a process dies, WebKit doesn't always
    /// accept the very next load, which is what a reload that looks like it
    /// did nothing actually was.
    func recoverFromCrash() {
        guard let address else { return }
        failure = nil
        loadAndVerify(address)
    }

    /// `web.load`, checked a moment later rather than trusted outright: a
    /// load handed to WebKit right after a process just died, or as the
    /// very first thing a freshly-built view is asked to do, doesn't always
    /// take — no error, no navigation, just a view that goes on sitting on
    /// about:blank with nothing left to say so. Still there, or still
    /// answering for a process that's already gone, is asked once more.
    private func loadAndVerify(_ url: URL, state: Any? = nil, tries: Int = 0) {
        // Wait for the stage to take the view back before loading into it. A
        // page loaded while its view is off any window boots as a hidden tab,
        // and a site that holds everything until it is shown — x.com does,
        // right down to making no request at all — can then miss being shown a
        // moment later and sit on its placeholder for good. Coming back to a
        // pinned tab after ⌘W is exactly that: select() asks for the view back
        // and wakes the page in the same breath, one synchronous step ahead of
        // SwiftUI actually putting the view on screen. Bounded at about a
        // second, so a wake with no stage waiting for it still loads rather
        // than hanging on one that will never come.
        let view = web
        if view.window == nil, tries < 50 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
                self?.loadAndVerify(url, state: state, tries: tries + 1)
            }
            return
        }
        // A tab that slept has its own history to go back to — the page, its
        // back list and its scroll position, in one. Anything else starts
        // from the address.
        if let state {
            view.interactionState = state
        } else {
            view.open(url)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            guard built?.url?.absoluteString != "about:blank" else {
                web.open(url)
                return
            }
            web.evaluateJavaScript("document.readyState") { [weak self] _, error in
                MainActor.assumeIsolated {
                    guard let self, let error = error as NSError? else { return }
                    guard error.domain == WKErrorDomain,
                          error.code == WKError.webContentProcessTerminated.rawValue
                    else { return }
                    self.web.open(url)
                }
            }
        }
    }

    /// Coming back to a tab. A page whose process was taken away out of sight
    /// — memory pressure, a long sleep — comes back as a white rectangle, and
    /// WebKit does not always say so for a view that was out of its window.
    /// Asked anything at all, the page answers with one particular error, and
    /// the answer to that is to load it again.
    func revive() {
        if stale {
            stale = false
            recoverFromCrash()
            return
        }
        guard !isBlank, pending == nil, !loading, failure == nil else { return }
        // A view with no document behind an address: whatever emptied it, the
        // address is what to show, and reload alone would have nothing to do.
        if hollow, let address {
            web.open(address)
            return
        }
        web.evaluateJavaScript("document.readyState") { [weak self] _, error in
            MainActor.assumeIsolated {
                guard let self, let error = error as NSError? else { return }
                guard error.domain == WKErrorDomain,
                      error.code == WKError.webContentProcessTerminated.rawValue
                else { return }
                self.recoverFromCrash()
            }
        }
    }

    /// Opened for the first time since the app started, or coming back from
    /// ⌘W while pinned. Answers whether there was anything to wake — the
    /// caller's own `revive()`, right after this, is for a tab that went
    /// quiet a different way, and firing it too here raced this very load
    /// with a second one of its own for the same address.
    @discardableResult
    func wake() -> Bool {
        guard let url = pending else { return false }
        pending = nil
        failure = nil
        reading = 0
        lastY = 0
        reader = false
        typing = false
        immersed = false
        let state = memory
        memory = nil
        if let picture, let image = NSImage(data: picture) {
            cover = image
            // Whatever happens to the page, the picture doesn't outstay it.
            uncover(after: 4)
        }
        picture = nil
        loadAndVerify(url, state: state)
        return true
    }

    /// A tab opened by a link is not blank, even though WebKit hasn't started
    /// loading it yet. Saying so now keeps the empty state from flashing up in
    /// the frame between the tab appearing and the page committing.
    func setAddressOptimistically(_ url: URL) {
        address = url
        failure = nil
        adoptIcon()
    }

    func touch() { touched = Date() }

    /// True when the web view holds nothing — never loaded, or emptied —
    /// while the tab still names a page. The white page, in other words.
    var hollow: Bool {
        guard let built else { return address != nil }
        guard let there = built.url else { return address != nil }
        return there.absoluteString == "about:blank" && pending == nil && address != nil
    }

    /// Again from the network. A view that has lost its document is given
    /// the address back instead: there is nothing else for it to reload.
    func reload() {
        // A pin put down with ⌘W has no view left to reload; waking it is
        // the reload.
        guard !wake() else { return }
        if hollow, let address {
            web.open(address)
        } else {
            web.reloadFromOrigin()
        }
    }
    func stop() { web.stopLoading() }
    /// Straight through, every time. A page that has to be fetched again is
    /// fetched again — nothing is kept behind to make that look otherwise.
    func back() { web.goBack() }
    func forward() { web.goForward() }

    /// Called when the tab is thrown away. Without it the view keeps running
    /// whatever the page left behind — timers, video, sockets.
    func close() {
        onScroll = nil
        onZoom = nil
        onLink = nil
        onPick = nil
        onPickEnd = nil
        onSignIn = nil
        onField = nil
        onCredentials = nil
        discard()
    }

    /// The view and everything listening to it, gone — timers, video,
    /// sockets, and the document WebKit would otherwise keep in its
    /// back-forward cache. The tab keeps its address; `web` builds again the
    /// next time anyone asks for it.
    private func discard() {
        watch = []
        ears.stop()
        guard let web = built else { return }
        built = nil
        let controller = web.configuration.userContentController
        Web.release(controller)
        controller.removeAllUserScripts()
        web.onPull = nil
        web.onTouch = nil
        web.searchName = nil
        web.onSearch = nil
        web.stopLoading()
        web.navigationDelegate = nil
        web.uiDelegate = nil
        web.removeFromSuperview()
    }
}


/// Whether the page is making noise.
///
/// WebKit knows, but only says so through a name that isn't part of the public
/// framework — so it is asked whether it answers to that name at all before
/// anyone listens, and the tab simply goes without the indicator if it doesn't.
final class AudioWatch: NSObject {
    private static let key = "_isPlayingAudio"

    private weak var web: WKWebView?
    private var tell: ((Bool) -> Void)?

    func watch(_ web: WKWebView, _ tell: @escaping (Bool) -> Void) {
        guard web.responds(to: NSSelectorFromString(AudioWatch.key)) else { return }
        self.web = web
        self.tell = tell
        web.addObserver(self, forKeyPath: AudioWatch.key, options: [.new], context: nil)
    }

    func stop() {
        guard let web, tell != nil else { return }
        web.removeObserver(self, forKeyPath: AudioWatch.key)
        tell = nil
        self.web = nil
    }

    override func observeValue(
        forKeyPath path: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        guard path == AudioWatch.key else { return }
        let on = (change?[.newKey] as? Bool) ?? false
        DispatchQueue.main.async { self.tell?(on) }
    }

    deinit { stop() }
}

/// The middle button on a link, as the page reports it.
///
/// A middle-click on a link opens it beside the tab you are on, in every
/// other browser, and WebKit leaves that to the browser: it tells the page
/// about the click and hands this app no navigation action for it at all, the
/// way it does for ⌘-click (and where it does report a button, it answers
/// with a mask — 1 left, 2 right, 4 middle — so a check for the middle button
/// as 2 would catch the right one). The page can see the click, though, so
/// the page is asked: its own `auxclick` for the middle button names the link
/// under the pointer, and from there it is an ordinary address to open.
///
/// Only the main frame, only a real link to somewhere this browser
/// would go, and only the middle button. A page's own handler runs as it
/// always did — this says where to, and changes nothing about the click.
///
/// Two things are checked before anything is opened. The event has to carry a
/// real click: a synthesized `auxclick` is not one, so a page that dispatches
/// its own does not get a tab per dispatch. And it has to be unclaimed — a
/// click a page has called `preventDefault` on is a click it has dealt with,
/// which is why this listens as the event comes back up rather than on the
/// way down, where nothing has answered yet.
final class MiddleRelay: NSObject, WKScriptMessageHandler {
    static let name = "officeMiddle"

    weak var tab: Tab?

    static let watch = """
    (function () {
      if (window.__officeMiddle) return;
      window.__officeMiddle = true;
      document.addEventListener('auxclick', function (e) {
        if (e.button !== 1 || !e.isTrusted || e.defaultPrevented) return;
        // The path, not the parents: a link inside an open shadow root is
        // on it too. An <area> of an image map is a link, and so is an SVG
        // <a>, whose href is an object that holds the address as written.
        var path = e.composedPath();
        for (var i = 0; i < path.length; i++) {
          var el = path[i];
          var tag = el.tagName ? el.tagName.toLowerCase() : '';
          if (tag !== 'a' && tag !== 'area') continue;
          var href = el.href;
          if (href && typeof href === 'object') {
            try { href = href.baseVal ? new URL(href.baseVal, el.baseURI).href : ''; } catch (_) { href = ''; }
          }
          if (!href) continue;
          window.webkit.messageHandlers.officeMiddle.postMessage({ href: href });
          return;
        }
      });
    })();
    """

    func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any],
              message.frameInfo.isMainFrame,
              let href = body["href"] as? String,
              let url = URL(string: href),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return }
        MainActor.assumeIsolated { [weak self] in
            guard let self, let tab else { return }
            tab.onMiddleClick?(tab, url)
        }
    }
}

/// A web view that reads the two-finger swipe for itself.
final class PageView: WKWebView {
    /// What extensions added to the right-click menu, at the end of it.
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        // WebKit names it for a window, but a new window's page arrives here
        // as a new tab (Browser's createWebViewWith), so it says so.
        if let item = menu.items.first(where: { $0.identifier?.rawValue == "WKMenuItemIdentifierOpenLinkInNewWindow" }) {
            item.title = "Open Link in New Tab"
        }
        if let item = menu.items.first(where: { $0.identifier?.rawValue == "WKMenuItemIdentifierSearchWeb" }),
           let name = searchName?() {
            webSearch = (item.target, item.action)
            selection = nil
            evaluateJavaScript(PageView.selected, in: nil, in: .defaultClient) { [weak self] result in
                self?.selection = (try? result.get()) as? String ?? ""
            }
            item.title = "Search with \(name)"
            item.target = self
            item.action = #selector(searchSelection(_:))
        }
        guard #available(macOS 15.4, *),
              let tab = Extensions.shared.browser?.tabs.first(where: { $0.built === self })
        else { return }
        let items = Extensions.shared.menuItems(for: tab)
        guard !items.isEmpty else { return }
        menu.addItem(.separator())
        items.forEach { menu.addItem($0) }
    }

    var searchName: (() -> String?)?
    var onSearch: ((String) -> Void)?
    private var selection: String?

    /// The words selected where the right-click was, read when the menu
    /// opens. The selection of a text field is its own, not the page's, so a
    /// field with the caret in it is asked first; a frame with the caret in it
    /// is looked into when it is of the same site. One of another site can't
    /// be, and gives nothing, so WebKit's own action takes the click, as it
    /// always did. A password field gives nothing either.
    static let selected = """
    (function read(doc) {
      var el = doc.activeElement;
      if (el && /^(IFRAME|FRAME)$/.test(el.tagName)) {
        try { return el.contentDocument ? read(el.contentDocument) : ''; } catch (e) { return ''; }
      }
      if (el && (el.tagName === 'TEXTAREA' || (el.tagName === 'INPUT' && el.type !== 'password'))) {
        try {
          var from = el.selectionStart, to = el.selectionEnd;
          if (typeof from === 'number' && typeof to === 'number' && to > from) return el.value.slice(from, to);
        } catch (e) {}
      }
      if (el && el.tagName === 'INPUT' && el.type === 'password') return '';
      var s = doc.getSelection();
      return s ? s.toString() : '';
    })(document)
    """
    private var webSearch: (target: AnyObject?, action: Selector?) = (nil, nil)

    @objc private func searchSelection(_ item: NSMenuItem) {
        defer { selection = nil }
        guard let selection, !selection.isEmpty else {
            if let action = webSearch.action { NSApp.sendAction(action, to: webSearch.target, from: item) }
            return
        }
        let words = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        if !words.isEmpty { onSearch?(words) }
    }

    /// Told where a sideways swipe has got to, and nil when there is none.
    var onPull: ((Pull?) -> Void)?
    /// Told the moment the page is reached for — a click, a scroll — so the
    /// picture of a tab waking up never stands between you and the page.
    var onTouch: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onTouch?()
        super.mouseDown(with: event)
    }

    /// The side buttons a mouse has for back and forward — button 3 and 4.
    /// No standard hands out that numbering; it's the X11 button order
    /// (0 left, 1 right, 2 middle, 3 back, 4 forward) that most mouse
    /// drivers settled on regardless, so it's what a mouse's own firmware
    /// is tuned to send.
    override func otherMouseDown(with event: NSEvent) {
        switch event.buttonNumber {
        case 3 where canGoBack: goBack()
        case 4 where canGoForward: goForward()
        default: super.otherMouseDown(with: event)
        }
    }

    /// Logi Options+ sends its Back/Forward buttons as a swipe, not buttons
    /// 3 and 4 — deltaX 1 for back, -1 for forward, as Safari reads it.
    override func swipe(with event: NSEvent) {
        if event.deltaX > 0, canGoBack { goBack() }
        else if event.deltaX < 0, canGoForward { goForward() }
        else { super.swipe(with: event) }
    }

    // MARK: - keys the page didn't use

    /// The last key handed to the page. WebKit sends a key the page didn't
    /// use back up the responder chain — the same event, a second time —
    /// where nothing takes it and macOS plays its "can't do that" sound.
    /// Editors that put the text in themselves (X's reply box, anything built
    /// on Draft.js) leave WebKit thinking their keys unused, so typing into
    /// them beeped. Safari keeps those quiet, and so does this view. The
    /// app's own shortcuts never get this far: its key monitor takes them
    /// before the page sees the key.
    private var handed: NSEvent?
    /// How many came back unused and were kept quiet, for the bench.
    static var quieted = 0

    override func keyDown(with event: NSEvent) {
        if let handed, PageView.same(handed, event) {
            self.handed = nil
            PageView.quieted += 1
            return
        }
        handed = event
        super.keyDown(with: event)
    }

    /// The same key press: the event WebKit sends back is the one it was
    /// given, and no two presses share a timestamp.
    static func same(_ one: NSEvent, _ other: NSEvent) -> Bool {
        one === other || (one.timestamp == other.timestamp && one.keyCode == other.keyCode && one.type == other.type)
    }

    // MARK: - the first frame

    /// A web view that has never drawn is opaque white. In a dark window that
    /// is a flash of it between a link that opens a tab and the page arriving,
    /// so a fresh view starts unseen, over the window's own ground, and comes
    /// in once WebKit says there is something on it worth seeing.
    private(set) var unpainted = false

    /// WebKit says when the first frame is only through names outside the
    /// public framework, so it is asked whether it answers to them first. One
    /// that doesn't gets a view shown straight away, as before.
    func holdForFirstFrame() {
        let observe = NSSelectorFromString("_setObservedRenderingProgressEvents:")
        guard responds(to: observe) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, UInt) -> Void
        unsafeBitCast(method(for: observe), to: Setter.self)(self, observe, PageView.firstFrame)
        unpainted = true
        alphaValue = 0
    }

    /// In, quickly: the page is there, and the fade only covers the frame
    /// between WebKit laying it out and putting it on screen.
    func showFirstFrame() {
        guard unpainted else { return }
        unpainted = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            animator().alphaValue = 1
        }
    }

    /// _WKRenderingProgressEventFirstVisuallyNonEmptyLayout — the moment
    /// Safari takes down the picture it shows while a page comes back.
    static let firstFrame: UInt = 1 << 1

    // MARK: - two fingers sideways

    private enum Axis { case across, down }

    private var sideways: CGFloat = 0
    private var gatheredX: CGFloat = 0
    private var gatheredY: CGFloat = 0
    private var axis: Axis?
    /// Which way the gesture set off, decided once and kept. Turning round
    /// mid-swipe pulls the disc back; it never becomes the other disc.
    private var back = true
    /// The page's word on whether this swipe is its own. Nil until it says.
    private var free: Bool?
    private var asked: Date?
    /// Already went somewhere, or was refused: nothing more this gesture.
    private var spent = false
    private var armedNow = false
    private var showing = false
    private var going = false
    private var pulls = 0

    /// How far the fingers travel before letting go means it. It was 110,
    /// and going back took a long reach across the trackpad — "too far",
    /// people said; Safari goes on less.
    private static let arm: CGFloat = 70
    /// A quick flick goes too, short of that, as it does in Safari: at least
    /// this far, within `flickTime` of setting off.
    private static let flick: CGFloat = 30
    private static let flickTime: TimeInterval = 0.25
    /// Less than this and there is nothing to show yet — or nothing left to.
    private static let show: CGFloat = 6

    // MARK: - two fingers together

    // The pinch itself is WebKit's own: during the gesture it scales the
    // rendered layers on the GPU around the fingers and only lays the page
    // out again once they lift. Doing the same from here — a real change of
    // scale on every event — was measured at a few frames a second, and the
    // public `setMagnification(_:centeredAt:)` ignores its point and resets
    // the scroll besides, so the pinch stays with WebKit. What is handled
    // here is the one-shot gesture WebKit does not do well on its own.

    /// Two fingers, tapped twice: the block under them fills the width, the
    /// way Safari's smart zoom does; tapped again, the page is back at its
    /// own size with the same spot still under the fingers. The page picks
    /// the block — it is the only one that knows where a column ends.
    override func smartMagnify(with event: NSEvent) {
        guard allowsMagnification else {
            super.smartMagnify(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        let js = PageView.smart(x: point.x, y: point.y, scale: magnification, width: bounds.width)
        evaluateJavaScript(js) { [weak self] value, _ in
            MainActor.assumeIsolated {
                guard let self, let text = value as? String, let data = text.data(using: .utf8),
                      let zoom = try? JSONDecoder().decode(SmartZoom.self, from: data)
                else { return }
                self.setMagnification(zoom.scale, centeredAt: point)
                self.evaluateJavaScript("window.scrollTo(\(zoom.x), \(zoom.y))")
            }
        }
    }

    private struct SmartZoom: Decodable {
        var scale: CGFloat
        var x: CGFloat
        var y: CGFloat
    }

    /// Where a smart zoom should land: the scale that fits the block under
    /// the fingers to the width, and the scroll that puts it there with the
    /// tapped spot at the same height. Zoomed in already, it is the way back.
    /// Scroll positions are CSS pixels of the whole page — `window.scrollTo`
    /// moves the magnified view here even on a page whose own overflow is
    /// hidden — and they are read before the scale changes, since the
    /// change itself sends the scroll to the corner.
    static func smart(x: CGFloat, y: CGFloat, scale: CGFloat, width: CGFloat) -> String {
        """
        (function (x, y, s, W) {
          var ox = window.scrollX, oy = window.scrollY;
          var cx = x / s, cy = y / s;
          if (s > 1.05) {
            return JSON.stringify({ scale: 1, x: Math.max(0, ox + cx - x), y: Math.max(0, oy + cy - y) });
          }
          var el = document.elementFromPoint(cx, cy);
          if (!el) return null;
          // The innermost block wide enough to be a column of something — a
          // paragraph's column, a card, a feed — rather than the whole page's
          // layout, which is what walking up to a wide ancestor finds.
          var vw = W / s, best = null, enough = Math.max(240, vw * 0.2);
          for (var e = el; e && e !== document.documentElement; e = e.parentElement) {
            var r = e.getBoundingClientRect();
            if (r.width < 80 || r.height < 16) continue;
            var d = getComputedStyle(e).display;
            if (d === 'inline' || d === 'contents') continue;
            if (!best) best = r;
            if (r.width >= enough) { best = r; break; }
          }
          if (!best) best = el.getBoundingClientRect();
          var pad = 12;
          var target = Math.max(1, Math.min(3, W / (best.width + 2 * pad)));
          if (target < 1.15) target = Math.min(3, s * 2);
          return JSON.stringify({
            scale: target,
            x: Math.max(0, ox + best.left - pad),
            y: Math.max(0, oy + cy - y / target)
          });
        })(\(x), \(y), \(scale), \(width))
        """
    }

    override func scrollWheel(with event: NSEvent) {
        onTouch?()
        // The page gets every event first and scrolls as it always did. The
        // swipe is only read, never taken.
        super.scrollWheel(with: event)
        // Only a live trackpad gesture — not its glide afterwards, and not a
        // mouse wheel, which has no beginning or end to speak of.
        guard event.momentumPhase == [] else { return }

        switch event.phase {
        case .mayBegin, .began:
            sideways = 0
            gatheredX = 0
            gatheredY = 0
            axis = nil
            free = nil
            asked = nil
            spent = false
            armedNow = false
            showing = false
            // A disc still on its way out belongs to the last gesture. It is
            // already invisible; it is only taken off the stage so the next
            // one arrives fresh rather than fading back in.
            pulls += 1
            if going {
                going = false
                onPull?(nil)
            }
        case .changed:
            guard !spent else { return }
            if axis == nil {
                // A few points in, the gesture has shown which way it means
                // to go. Only a clearly sideways one is read further.
                gatheredX += abs(event.scrollingDeltaX)
                gatheredY += abs(event.scrollingDeltaY)
                sideways += event.scrollingDeltaX
                guard gatheredX + gatheredY > 6 else { return }
                axis = gatheredX > gatheredY * 1.3 ? .across : .down
                if axis == .down {
                    spent = true
                    return
                }
                back = sideways > 0
                // Nowhere to go that way: nothing to show, and nothing more
                // to read from this gesture.
                if back ? !canGoBack : !canGoForward {
                    spent = true
                    return
                }
                asked = Date()
                tell()
                return
            }
            sideways += event.scrollingDeltaX
            tell()
        case .ended:
            release()
        case .cancelled:
            spent = true
            settle(nil)
        default:
            break
        }
    }

    /// The page has said whether the swipe would scroll something.
    func answer(free yes: Bool) {
        guard axis != .down, !spent else { return }
        guard yes else {
            free = false
            spent = true
            settle(nil)
            return
        }
        guard free == nil else { return }
        free = true
        tell()
    }

    /// Only the distance in the direction it set off in. Past the origin the
    /// other way is just nought.
    private var travel: CGFloat { max(0, back ? sideways : -sideways) }

    private func tell() {
        if free == nil, let asked, Date().timeIntervalSince(asked) > 0.18 {
            // A page that never answers — a PDF, a page that failed to load —
            // still has to be leavable by hand.
            free = true
        }
        guard free == true else { return }

        let travel = travel
        // Drawn all the way back, the disc goes; drawn out again, it returns.
        // Nothing is decided until the fingers lift.
        guard travel >= PageView.show else {
            if showing { settle(nil) }
            return
        }

        let armed = travel >= PageView.arm
        if armed != armedNow {
            // Two different taps: one for reaching it, a lighter one for
            // stepping back from it, so you know without looking that
            // letting go now is safe.
            NSHapticFeedbackManager.defaultPerformer.perform(
                armed ? .levelChange : .alignment, performanceTime: .now
            )
        }
        armedNow = armed
        settle(Pull(back: back, travel: travel, armed: armed, going: false))
    }

    private func release() {
        defer { spent = true }
        let flicked = !spent && free == true && travel >= PageView.flick
            && (asked.map { Date().timeIntervalSince($0) <= PageView.flickTime } ?? false)
        guard !spent, free == true, armedNow || flicked else {
            settle(nil)
            return
        }
        going = true
        settle(Pull(back: back, travel: travel, armed: true, going: true))
        if back { goBack() } else { goForward() }
        pulls += 1
        let mine = pulls
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { [weak self] in
            guard let self, pulls == mine else { return }
            going = false
            settle(nil)
        }
    }

    private func settle(_ pull: Pull?) {
        showing = pull != nil
        onPull?(pull)
    }

}

/// Carries the page's scroll position back to its tab.
///
/// A content controller holds its handlers strongly, so this stands between the
/// two rather than the tab registering itself — otherwise a closed tab is kept
/// alive by the very page it was told to stop showing.
final class ScrollRelay: NSObject, WKScriptMessageHandler {
    static let name = "officeScroll"

    weak var tab: Tab?

    func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any] else { return }
        if let side = body["side"] as? String {
            MainActor.assumeIsolated { tab?.web.answer(free: side == "free") }
            return
        }
        guard let y = body["y"] as? Double,
              let ceiling = body["max"] as? Double
        else { return }
        MainActor.assumeIsolated { tab?.scrolled(to: y, of: ceiling) }
    }

    /// Reports at most once a frame, and passively, so a page that scrolls
    /// smoothly without us keeps scrolling smoothly with us.
    static let script = """
    (function () {
      var waiting = false;
      function tell() {
        var root = document.documentElement;
        var y = window.scrollY || root.scrollTop || 0;
        var ceiling = Math.max(1, (root.scrollHeight || 0) - window.innerHeight);
        window.webkit.messageHandlers.\(name).postMessage({ y: y, max: ceiling });
      }
      window.addEventListener('scroll', function () {
        if (waiting) return;
        waiting = true;
        requestAnimationFrame(function () { waiting = false; tell(); });
      }, { passive: true });
      tell();
    })();
    """
}



extension WKWebView {
    /// An address, or a file on this Mac. WebKit reads a file only when told
    /// which folder the page may read from, and loads nothing at all
    /// otherwise: an .html double-clicked in the Finder, once Search is the
    /// Mac's browser, opened a tab that stayed empty.
    func open(_ url: URL) {
        if url.isFileURL {
            loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            load(URLRequest(url: url))
        }
    }

    /// JavaScript run in Search's own world (see Web.world), where its page
    /// scripts are, answered the way `evaluateJavaScript` answers: the value,
    /// or nil for none or an error.
    func evaluateInSearch(_ js: String, then: ((Any?) -> Void)? = nil) {
        evaluateJavaScript(js, in: nil, in: Web.world) { result in
            then?(try? result.get())
        }
    }
}
