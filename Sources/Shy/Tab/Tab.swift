import Combine
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
    var built: PageView?
    var configuration: WKWebViewConfiguration
    let extensionReturn = ExtensionReturnNavigation()

    /// Whether its page was made with the extension controller in it — every
    /// ordinary tab, and a private one only when extensions were allowed
    /// there as it was made (a controller can't be added to a page later).
    @available(macOS 15.4, *)
    var carriesExtensions: Bool { configuration.webExtensionController != nil }
    /// The controller its page was made with: its profile's (see Extensions.of).
    @available(macOS 15.4, *)
    var extensionController: WKWebExtensionController? { configuration.webExtensionController }
    /// Where its cookies and sign-ins are kept.
    var store: WKWebsiteDataStore { configuration.websiteDataStore }
    /// The profile its page is signed in as, read from its store (see
    /// Profiles.owner); Personal for a private tab, which keeps nothing.
    var profile: UUID { Profiles.owner(of: store) ?? Profile.personalID }
    /// Whoever handles navigation and windows for this page; applied when
    /// the page is built, whenever that is.
    weak var delegate: (WKNavigationDelegate & WKUIDelegate)? {
        didSet {
            built?.navigationDelegate = delegate
            built?.uiDelegate = uiDelegate(delegate)
        }
    }
    /// An extension's page answers WebKit's question about recording the
    /// screen itself (see ExtensionCapture); held here, as WebKit doesn't.
    private var pageDelegate: NSObject?

    func uiDelegate(_ delegate: (WKNavigationDelegate & WKUIDelegate)?) -> WKUIDelegate? {
        guard #available(macOS 15.4, *), MainActor.assumeIsolated({ Extensions.isPages(configuration.userContentController) })
        else { return delegate }
        let made = pageDelegate as? ExtensionPageDelegate ?? ExtensionPageDelegate()
        made.next = delegate
        pageDelegate = made
        return made
    }
    /// The stylesheet a page not yet built is to be armed with.
    var veils = ""

    @Published var title = ""
    @Published var address: URL?
    /// The address of the page that is actually on screen. `address` moves
    /// to where the tab is going as soon as a load starts, while the page
    /// and its certificate are still the old one's: what is said about the
    /// connection, and which passwords a sign-in box is offered, go by this
    /// one, set when the new page has arrived.
    @Published var committed: URL?
    /// The view has drawn its first frame; until then the peek shows its
    /// skeleton (see PeekSkeleton). True from the start on a WebKit that
    /// doesn't say when.
    @Published var painted = false
    /// Like `restAddress`: once the tab has a view, only what arrived. A
    /// window a page opened toward another site, stopped and wrote into
    /// itself, would otherwise be shown, shared and offered passwords as
    /// that site while nothing of it ever loaded.
    var pageAddress: URL? { built == nil ? address : committed }
    /// What the tab says at rest about where its page is (AtRest.swift):
    /// the document that arrived, never one only on its way. A page that
    /// opened this tab can write into it while the address it asked for is
    /// still loading, and that address must not vouch for what it wrote.
    /// A tab with no view (asleep, restored) has only its address to say.
    var restAddress: URL? { built == nil ? address : committed }

    func didCommit() {
        popupGesture.clear()
        // A new page may ask its own questions again.
        built?.questionsHushed = false
        built?.questionsInARow = 0
        // What the old page was refused went with it.
        if !blockedPopups.isEmpty { blockedPopups = [] }
        // A translated page is gone; its frames with it.
        if translator != nil || translation != nil || !translateFrames.isEmpty { translationGone(sleeping: false) }
        // A new document: whatever the old one waited for under its field
        // went with it.
        if let built { Passkeys.shared.forget(built) }
        // about:blank too: a document another page wrote into (an opener
        // sending its window there, then writing) is that page's, not the
        // one before it, and is offered nothing that belonged to it.
        if let url = built?.url { committed = url }
        // A link followed out of an article is a page, not an article: ⇧⌘R
        // reads it rather than reloading it, and the article's corner goes.
        reader = false
        // A page arrived after all: the address is its own again.
        if held != nil, let url = built?.url, url.absoluteString != "about:blank" {
            held = nil
            address = url
        }
    }

    /// An address the tab shows, and reports to extensions, without loading
    /// it (see ExtensionAuth.handOver). The page on screen stays. WebKit
    /// going back to that page's address as the cancelled load unwinds is not
    /// a move, so the observer below lets it pass. The page is WebKit's own
    /// current item, not `committed`, which a same-site load in progress has
    /// already moved on.
    var held: URL?
    var heldOver: URL?

    func hold(_ url: URL) {
        held = url
        heldOver = built?.backForwardList.currentItem?.url
        address = url
        failure = nil
    }
    @Published var progress: Double = 0
    @Published var loading = false
    @Published var canGoBack = false
    @Published var canGoForward = false
    /// Set when the page never arrived — no host, no network, a refused
    /// connection. Shown in place of the page rather than in a dialog.
    @Published var failure: String?
    /// How long the page is, in screens of it: one for a page that doesn't
    /// scroll. Read from the page's scroll report; nothing is drawn
    /// from it as it changes (see TabSwitcher's moons). None before the page
    /// has said.
    var screens: Double?

    /// True while the page has been stripped back to its article.
    @Published var reader = false

    /// The site's icon, for tabs set to wear one. From the cache the moment
    /// the tab has an address, and from the page a moment after it loads.
    @Published var icon: NSImage?

    /// True while the caret is in something on the page that takes typing.
    @Published var typing = false
    /// True while the page has taken over the screen: from the moment
    /// WebKit has the page in its own full-screen window until it starts
    /// giving it back (see the fullscreenState watch in `build`), so the
    /// window's chrome steps aside and comes back while that window covers
    /// ours, and the page comes home once, at its own size.
    @Published var immersed = false {
        didSet { if immersed != oldValue { immersion.send(immersed) } }
    }
    /// `immersed`, once it has changed: $immersed speaks before the value
    /// is set, and what the window works out from it has to see the new one.
    let immersion = PassthroughSubject<Bool, Never>()

    /// A sideways swipe in progress, for the disc that shows it.
    @Published var pull: Pull?

    /// What going back from the first page does, for a tab where it does
    /// anything (see PageView.leave).
    var leave: (() -> Void)? {
        didSet { built?.leave = leave }
    }

    /// How much bigger the page is being drawn. Not a magnifying glass over
    /// the rendered page — the page is laid out again at this size, so text
    /// stays as sharp at 200% as it was at 100%.
    @Published var zoom: CGFloat = 1

    var onZoom: ((Tab, CGFloat) -> Void)?
    /// The resolved address under the pointer, or nil when it leaves a link.
    var onLink: ((Tab, String?) -> Void)?
    /// The page took the keys (see PageView.onKeys).
    var onKeys: ((Tab) -> Void)?

    /// True while something on the page is making noise, so the row can say
    /// which tab it is coming from.
    @Published var noisy = false
    /// Silenced by hand from its speaker or its menu: the page plays on and
    /// is not heard. WebKit keeps the mute on the view from one page to the
    /// next, so it is only set again on a view built new, as a sleeping tab
    /// wakes (see build()).
    @Published var muted = false
    /// An extension is recording from this tab's page (see RecordingIndicator).
    @Published var recording = false

    /// What the page hands back when you point at something and click it.
    var onPick: ((Tab, String, String, String) -> Void)?
    /// The page has a sign-in on it; the page has just sent one.
    var onSignIn: ((Tab) -> Void)?
    /// The caret has entered or left one of the sign-in boxes; where the box
    /// is, in the web view's points, or nil when it has left. Then whether
    /// it goes with a password, and whether it is a first step's name box,
    /// which takes the name alone.
    var onField: ((Tab, CGRect?, Bool, Bool) -> Void)?
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
    /// "Add to Shy" was pressed on the Chrome Web Store page this tab shows.
    var onStoreAdd: ((Tab) -> Void)?
    /// The middle button was let go over a link. The browser opens it in a
    /// tab of its own beside this one, without leaving the page you are on.
    var onMiddleClick: ((Tab, URL) -> Void)?
    /// A page on this Mac's link to another file, clicked: here, or in a
    /// tab of its own for target="_blank" (see MiddleRelay).
    var onFileLink: ((Tab, URL, Bool) -> Void)?
    /// Sent where this tab's view can't go: from an extension's page to the
    /// web or another extension, or from the web to an extension's page.
    /// WebKit keeps each kind of view to its own pages, so the tab has to be
    /// swapped for one built for the address (see Browser.replace).
    var onCross: ((Tab, URL) -> Void)?
    /// The extension whose store page has its own "Add to Shy" button in
    /// place — so the bar at the bottom of the window doesn't offer it twice.
    @Published var storePlaced: String?

    let relay = ScrollRelay()
    let veils_ = VeilRelay()
    let forms = FormRelay()
    let images = ImageRelay()
    let media = MediaKeys()
    /// Counting down once the page's sound stops, to give the media keys
    /// back (see MediaKeys.swift). One at most.
    var quiet: Timer?
    let shop = StoreRelay()
    let iconChanges = IconRelay()
    let middles = MiddleRelay()
    var popupGesture = PopupGesture()
    /// Windows this page asked for and was refused, newest last, a few at
    /// most: the quiet sign beside its title offers them (BlockedPopups.swift).
    /// Gone with the page.
    @Published var blockedPopups: [BlockedPopup] = []
    /// A private tab's own Always Allow: only for as long as the tab, never
    /// written anywhere, as its Keep This Site Awake.
    var popupSites: Set<String> = []
    /// Translate Page (Translate.swift): what the sign beside the title
    /// shows, the run while there is one, the frames that said they're
    /// there, a private tab's own Always Translate, and the page a tab put
    /// to sleep translated was on. All in memory, gone with the tab.
    @Published var translation: TranslationMark?
    var translator: PageTranslator?
    var translateFrames: [WKFrameInfo] = []
    var translateLanguages: Set<String> = []
    var translateOnWake: (url: URL, to: String)?
    let translateRelay = TranslateRelay()
    let passkeyRelay = PasskeyRelay()
    let hovered = HoveredLink()
    let ears = AudioWatch()

    // Private exceptions belong only to this tab, never its session record.
    @Published var awakeSites: Set<String> = []

    var awakeHost: String? {
        guard let address, ["http", "https"].contains(address.scheme?.lowercased()) else { return nil }
        return address.host()?.lowercased()
    }

    /// A tab that keeps nothing: its own cookies, no history, no place in the
    /// session. Signed in as nobody, and forgotten when it goes.
    let shy: Bool

    /// A tab a script opened through the bench, beside yours. Signed in as
    /// you, so it sees what you see — but never selected for you, never in
    /// the session or the history, and gone when the script is done.
    #if DEBUG
    let bench: Bool
    #else
    /// Release builds have no bench, so no tab of one.
    var bench: Bool { false }
    #endif

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
    @Published var pin: String? {
        didSet { if pin == nil, oldValue != nil { letGo = Date() } }
    }
    /// For a pin, the page it was pinned at: a double-click on it goes back
    /// there (Browser.goHome).
    var home: URL?
    /// For a pin, which of the pins it is, in every window (see Pins.swift).
    var pinID: UUID?
    /// For a pin, the site a link from it was just peeked at, and when: the
    /// page's own script sending the pin there after all is turned away
    /// (see Browser.peek).
    var peeked: (site: String, at: Date)?
    /// For a pin, kept as a row under the squares rather than as a square:
    /// Arc's pinned list, below its favourites. Still a pin in every other
    /// way: put down by ⌘W, the same in every window.
    @Published var listed = false
    /// For a pinned row, the folder it is in (see Folders.swift). Set when
    /// the row is built, from pins.json, as `listed` is.
    @Published var folder: UUID?

    /// A name you gave it, in place of whatever the page calls itself. It
    /// stays through navigation: a tab you named is a tab you are keeping for
    /// a job, not for a page.
    ///
    /// Pinned (in a folder or not) and named are the two ways of keeping a
    /// tab when tabs close themselves (see Closing.swift). A tab let go from
    /// either starts its time from then (letGo), not from whenever it was
    /// last left.
    @Published var name: String? {
        didSet { if name == nil, oldValue != nil { letGo = Date() } }
    }

    /// When you last looked at it. The summon lists pages by this, because
    /// what you were just reading is what you are most likely to want back.
    /// Written into the session, so a tab's time away counts across quits.
    var touched = Date()
    /// When it was last let go of: unpinned or its name taken away. Kept apart from `touched`, which says when you last
    /// looked, for ⌃Tab and for where ⌘W on a pin lands; letting go of a
    /// tab isn't looking at it. In the session too (see Closing.swift).
    var letGo: Date?
    /// Since when a tab that closes itself counts as left: the later of the
    /// last look and the last letting go.
    var leftSince: Date { max(touched, letGo ?? .distantPast) }

    /// What was typed into this blank tab's field and not sent, kept while
    /// another tab is in front: the field is one for every tab. Only ever in
    /// memory, and gone once the tab goes somewhere or closes.
    var draft = ""

    /// Set on a tab brought back from the last session and not yet opened. It
    /// has a name and an address in the row, and costs nothing until you go to
    /// it — which is the difference between a browser that starts in half a
    /// second with twenty tabs and one that doesn't.
    var pending: URL?

    /// For a tab put to sleep for not being looked at: the page's own history
    /// — the back list, the page, where it was scrolled to — handed to the
    /// view built to wake it, so it opens exactly where this one was left.
    var memory: Any?
    /// The last picture of that page, compressed, for the moment it wakes.
    var picture: Data?
    /// That picture, over the stage while the page is rebuilt underneath it:
    /// coming back to a tab that slept starts from what you left, not white.
    @Published var cover: NSImage?

    var watch: [NSKeyValueObservation] = []

    /// A tab that has never been anywhere shows the address field instead of a
    /// page. It still owns a web view — built now, warm by the time it's needed.
    var isBlank: Bool { address == nil && page == nil }
    /// A tab with a web page — loaded, on its way or asleep — as opposed to
    /// an empty one or one of Shy's own pages.
    var isWeb: Bool { address != nil }

    /// Settings, History and the rest, shown in this tab in place of a web
    /// page. Never with a web view behind it.
    @Published var page: InternalPage?
    /// The pages Back and Forward go to, between Shy's own pages.
    var trail: [InternalPage] = []
    var ahead: [InternalPage] = []
    /// The page this tab left for the web: Back from the first web page
    /// comes back to it, as Back from a link in chrome://history does.
    var behind: InternalPage?

    init(shy: Bool = false, bench: Bool = false, configuration: WKWebViewConfiguration? = nil) {
        self.shy = shy
        #if DEBUG
        self.bench = bench
        #endif
        self.configuration = configuration ?? Web.configuration(shy: shy)
    }

    /// The name a sign-in that asks for it first was just sent, for the
    /// page after it: that one asks for the password alone, with no box
    /// for the name, and a password saved without its name is half a
    /// login. In memory only — never written down — for this tab alone,
    /// a few minutes, and only for the same site: a private tab's name
    /// never reaches another tab, and another site never sees it.
    var named: (site: String, user: String, at: Date)?

    /// A name and password the page has just sent — held, not yet offered.
    /// Whether the sign-in worked is only known afterwards: a page that
    /// comes back without a password box took it, one that still has the
    /// box refused it, and only the first is worth remembering.
    var sent: (host: String, user: String, password: String, clear: Bool, at: Date)?

    /// Set when WebKit said the page's process went away while nobody was
    /// looking at the tab. Coming back to it loads the page again rather
    /// than showing the white that is left.
    var stale = false
}
