import SwiftUI
import WebKit
import Combine

// The side panel: beside the page on the side away from the column (on the
// right with the tabs across the top), closed until something asks for it,
// as wide as you last left it. With the page as a card it is a card of its
// own; edge to edge, it meets the page at a hairline. If it can't be made,
// the extension's panel opens as a tab of its own, as before there was one.
//
// What lives in it is an extension's panel (chrome.sidePanel): ChatGPT's,
// Claude's, Sider, Merlin — their page, made from the extension's own
// configuration so it is one of its pages in every way (runtime messages,
// storage), shown here rather than in a tab. From Office Search Community's
// work in progress (o5-panel).
//
// Or a website (idea 365), for whoever turns on Settings › General ›
// Websites in the side panel: Claude or ChatGPT kept beside the page
// without an extension. It is an ordinary page of the window's space, signed
// in where that space's tabs are, never a private tab's; its address is on
// the panel's own line, since it stays beside every tab. Links it opens in
// a new window go to a tab.
//
// Where the card goes, its gap, corners and the handle that resizes it are
// the window's layout (ContentView); what is in it is here.

enum SidePanelContent: Equatable {
    /// An extension's panel page. `tab`: the tab it was opened for, when the
    /// extension named one (setOptions with a tabId) — it goes with that tab,
    /// hidden on the others and back on it, as in Chrome. Nil: the window's.
    case page(extensionID: String, url: URL, tab: Tab.ID?)
    /// A website, in the space the window was in when it opened.
    case site(url: URL, space: UUID)
}

/// The sites offered in View › Side Panel, as they are typed: a short list,
/// plus whatever page you are on.
enum PanelSites {
    static let offered: [(name: String, url: URL)] = [
        ("Claude", URL(string: "https://claude.ai/new")!),
        ("ChatGPT", URL(string: "https://chatgpt.com/")!),
        ("Gemini", URL(string: "https://gemini.google.com/app")!),
        ("Perplexity", URL(string: "https://www.perplexity.ai/")!),
    ]

    /// Only the web: never a file, a script or an extension's page.
    static func allowed(_ url: URL?) -> Bool {
        guard let scheme = url?.scheme?.lowercased() else { return false }
        return scheme == "https" || scheme == "http"
    }
}

extension Preferences {
    /// The side panel's width, as you last left it, within reason.
    static let sidePanelWidths: ClosedRange<CGFloat> = 300...640
    static let sidePanelStart: CGFloat = 380
}

/// What came of asking for the panel. `taken`: the panel dealt with it, up
/// or put away again. `noPanel`: none can be made in this window (a popup
/// window, a page that didn't load), and the caller opens the extension's
/// page as a tab instead, as it did before there was a panel. `notHere`:
/// the tab in front is private and the extension hasn't been let into
/// private tabs, so nothing opens at all, a tab least of all.
enum SidePanelAnswer: Equatable {
    case taken
    case noPanel
    case notHere
}

// MARK: - opening and closing

extension Browser {
    /// An extension's panel page in this window's side panel.
    @available(macOS 15.4, *)
    @discardableResult
    func showSidePanel(_ context: WKWebExtensionContext, url: URL, for tab: Tab.ID? = nil) -> SidePanelAnswer {
        guard !isPopup else { return .noPanel }
        // An extension not let into private tabs is given nothing of one
        // (Extensions' `hidden`): no address, no title, no view to run a
        // script in. A panel of its own beside that page would be a panel
        // about a page it cannot see, so it doesn't open there.
        guard !Browser.holdsPanel(shy: panelPanes(tab).contains { $0.shy },
                                  letIn: Extensions.mayGoPrivate(context))
        else { return .notHere }
        let content = SidePanelContent.page(extensionID: context.uniqueIdentifier, url: url, tab: tab)
        guard SidePanelPages.shared.load(url, from: context, in: self) else { return .noPanel }
        if let tab { SidePanelPages.shared.bind(content, to: tab, in: self) }
        sidePanel = content
        sidePanelShown = true
        return .taken
    }

    /// The extension's button again, with its panel up: it goes, as a
    /// second press on a popup's button does.
    @available(macOS 15.4, *)
    func toggleSidePanel(_ context: WKWebExtensionContext, url: URL, for tab: Tab.ID? = nil) -> SidePanelAnswer {
        if sidePanelShown, case .page(let id, _, _) = sidePanel, id == context.uniqueIdentifier {
            closeSidePanel()
            return .taken
        }
        return showSidePanel(context, url: url, for: tab)
    }

    /// The panel's page didn't load: it goes, and the page opens as a tab
    /// of its own instead, as before there was a panel.
    func sidePanelFailed(_ url: URL) {
        guard case .page(_, let shown, _) = sidePanel, shown == url else { return }
        closeSidePanel()
        guard #available(macOS 15.4, *), (try? Extensions.mayOpen(url)) != nil else { return }
        open(url, foreground: true)
    }

    /// A website in this window's side panel, signed in as this space's tabs
    /// are (Settings › General › Websites in the side panel). The same site
    /// again closes it, as a second press on an extension's button does.
    @discardableResult
    func showSiteInPanel(_ url: URL) -> Bool {
        guard prefs.sitesInPanel, PanelSites.allowed(url), !isPopup else { return false }
        if sidePanelShown, case .site = sidePanel, SidePanelPages.shared.siteArrived(in: self)?.host() == url.host() {
            closeSidePanel()
            return true
        }
        if case .page(_, _, let tab?) = sidePanel { SidePanelPages.shared.unbind(tab, in: self) }
        SidePanelPages.shared.loadSite(url, space: spaceID, in: self)
        sidePanel = .site(url: url, space: spaceID)
        sidePanelShown = true
        prefs.panelSite = url.absoluteString
        return true
    }

    /// View › Side Panel › Show Side Panel: the site last there, or Claude,
    /// and closing whatever is there.
    func toggleSitePanel() {
        guard prefs.sitesInPanel else { return }
        if sidePanelShown { return closeSidePanel() }
        let last = URL(string: prefs.panelSite).flatMap { PanelSites.allowed($0) ? $0 : nil }
        showSiteInPanel(last ?? PanelSites.offered[0].url)
    }

    /// The store this window's tabs use in `space`: that space's, inside the
    /// window's profile (Spaces.store), or the profile's own for a space it
    /// doesn't list. Never another profile's, whatever Spaces.current is.
    func panelStore(_ space: UUID) -> WKWebsiteDataStore {
        spaces.contains(where: { $0.id == space }) ? Spaces.store(for: space) : Profiles.store(profileID)
    }

    /// The tab's page into the side panel, from the tab's menu. Not a
    /// private tab's: the panel is signed in as the space is.
    func openInSidePanel(_ tab: Tab) {
        guard !tab.shy, let url = tab.address else { return }
        showSiteInPanel(url)
    }

    /// The site in the panel, as a tab of its own, and the panel closed.
    func sitePanelToTab() {
        guard case .site(let first, _) = sidePanel else { return }
        let url = SidePanelPages.shared.siteArrived(in: self) ?? first
        closeSidePanel()
        open(url, foreground: true)
    }

    /// The window went to another space: the site comes again, signed in as
    /// that space is.
    func sitePanelFollowsSpace() {
        guard case .site(let first, let space) = sidePanel, space != spaceID else { return }
        let url = SidePanelPages.shared.siteArrived(in: self) ?? first
        SidePanelPages.shared.loadSite(url, space: spaceID, in: self)
        sidePanel = .site(url: url, space: spaceID)
    }

    /// Closed: an extension's page is let go, as Chrome does.
    func closeSidePanel() {
        if case .page(_, _, let tab?) = sidePanel { SidePanelPages.shared.unbind(tab, in: self) }
        SidePanelPages.shared.drop(in: self)
        sidePanelShown = false
        sidePanel = nil
    }

    /// Another tab in front: a panel opened for the tab just left goes
    /// with it, and one opened for this tab comes back. A panel whose
    /// extension may not see the tab arriving is neither of those: it is
    /// held back where it stands, which the window works out as it draws
    /// (`sidePanelHeld`).
    func sidePanelFollows(_ tab: Tab) {
        if case .page(_, _, let bound?) = sidePanel, bound != tab.id {
            SidePanelPages.shared.drop(in: self)
            sidePanelShown = false
            sidePanel = nil
        }
        sidePanelReturns(to: tab)
    }

    /// The switch in Settings > Extensions has moved for an extension: a
    /// panel bound to the tab in front comes back if it may be seen there
    /// now, and the window draws again for one let through or held back.
    /// `sidePanelHeld` is worked out, not kept, so every other way a tab
    /// comes to the front is right without knowing about the panel.
    func sidePanelPrivacyChanged() {
        if let active { sidePanelReturns(to: active) }
        objectWillChange.send()
    }

    /// A panel bound to this tab and not up: back, if this tab is one its
    /// extension may see.
    private func sidePanelReturns(to tab: Tab) {
        guard #available(macOS 15.4, *), sidePanel == nil,
              case .page(let id, let url, _)? = SidePanelPages.shared.bound(to: tab.id, in: self),
              let context = Extensions.shared.contexts[id]
        else { return }
        showSidePanel(context, url: url, for: tab.id)
    }

    /// The panel is up and held back beside a private page: one of the
    /// pages on screen is a private tab, and its extension hasn't been let
    /// into private tabs. The window gives the panel's room to the page
    /// meanwhile, and the page in the panel is kept, so it comes back as
    /// you left it on a page the extension may see. An extension gone while
    /// its panel is up is held back too, having nothing left to say it may
    /// be there.
    var sidePanelHeld: Bool {
        guard case .page(let id, _, _) = sidePanel, panelPanes().contains(where: { $0.shy })
        else { return false }
        guard #available(macOS 15.4, *), let context = Extensions.shared.contexts[id] else { return true }
        return Browser.holdsPanel(shy: true, letIn: Extensions.mayGoPrivate(context))
    }

    /// The decision itself, away from a window: a private page on screen and
    /// an extension not let into private tabs hold its panel back.
    static func holdsPanel(shy: Bool, letIn: Bool) -> Bool { shy && !letIn }

    /// The pages a panel sits beside: the tab it was opened for, else the
    /// one in front, and in Split View the other half of its pair, since
    /// the panel stands beside both at once. A pair holds two tabs of the
    /// same kind today (`canSplit` asks for `first.shy == second.shy`), so
    /// the pair's half says nothing the tab in front hasn't already said;
    /// it is written on what is on screen rather than on that rule holding.
    /// `split(for:)` answers nothing while Split View is off, where a kept
    /// pair shows one page as any other tab does.
    private func panelPanes(_ tab: Tab.ID? = nil) -> [Tab] {
        guard let here = tabs.first(where: { $0.id == (tab ?? activeID) }) else { return [] }
        guard let pair = split(for: here), let other = pair.partner(of: here.id),
              let beside = tabs.first(where: { $0.id == other })
        else { return [here] }
        return [here, beside]
    }
}

// MARK: - the extension's page

/// Each window's panel page, and the panels bound to its tabs.
@MainActor
final class SidePanelPages: NSObject {
    static let shared = SidePanelPages()

    private final class Page {
        let web: WKWebView
        let delegate: NSObject
        init(web: WKWebView, delegate: NSObject) { self.web = web; self.delegate = delegate }
    }
    private var pages: [ObjectIdentifier: Page] = [:]
    private var bound: [ObjectIdentifier: [Tab.ID: SidePanelContent]] = [:]

    /// The page up in this window's panel, for SidePanelView and the bench.
    func web(in browser: Browser) -> WKWebView? { pages[ObjectIdentifier(browser)]?.web }

    /// A website's page that arrived (committed) in this window's panel: what
    /// its line names, what goes to a tab and what follows a space switch.
    /// Not where it is only on its way to.
    func siteArrived(in browser: Browser) -> URL? {
        (pages[ObjectIdentifier(browser)]?.delegate as? SitePanelDelegate)?.arrived
    }

    fileprivate func siteDelegate(in browser: Browser) -> SitePanelDelegate? {
        pages[ObjectIdentifier(browser)]?.delegate as? SitePanelDelegate
    }

    /// For the bench: the website's page as its line shows it, and how often
    /// it was made again after a crash.
    func siteReport(in browser: Browser) -> [String: Any] {
        guard let delegate = siteDelegate(in: browser) else { return [:] }
        return ["arrived": delegate.arrived?.absoluteString ?? "", "line": SiteLine.Seen.name(delegate.arrived),
                "reloads": delegate.reloads, "gaveUp": delegate.gaveUp]
    }

    /// For the bench: WebKit's word that the page's process is gone, as a
    /// crash gives it.
    func siteCrashed(in browser: Browser) {
        guard let page = pages[ObjectIdentifier(browser)], let delegate = page.delegate as? SitePanelDelegate else { return }
        delegate.webViewWebContentProcessDidTerminate(page.web)
    }

    @available(macOS 15.4, *)
    func load(_ url: URL, from context: WKWebExtensionContext, in browser: Browser) -> Bool {
        let key = ObjectIdentifier(browser)
        // The same page already up: left as it is.
        if let page = pages[key], page.web.url == url { return true }
        drop(in: browser)
        guard let configuration = context.webViewConfiguration else { return false }
        // No window opens from the panel without a click.
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 380, height: 600), configuration: configuration)
        let delegate = PanelDelegate(browser: browser, base: context.baseURL, first: url)
        web.navigationDelegate = delegate
        web.uiDelegate = delegate
        web.allowsMagnification = true
        if #available(macOS 13.3, *) { web.isInspectable = true }
        web.load(URLRequest(url: url))
        pages[key] = Page(web: web, delegate: delegate)
        return true
    }

    /// A website, in a page made as a tab's is in `space` (Web.configuration):
    /// its store, its user agent, extensions where tabs have them. Never a
    /// private tab's store. No window opens from it without a click.
    func loadSite(_ url: URL, space: UUID, in browser: Browser) {
        drop(in: browser)
        // The window's profile's store for that space: signed in where
        // this window's tabs are, never another profile's.
        let configuration = Web.configuration(space: space, store: browser.panelStore(space))
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 380, height: 600), configuration: configuration)
        let delegate = SitePanelDelegate(browser: browser)
        delegate.watch(web)
        web.navigationDelegate = delegate
        web.uiDelegate = delegate
        web.allowsMagnification = true
        web.allowsBackForwardNavigationGestures = true
        // The Web Inspector as for a tab, by the same rule (Web.inspectable).
        Web.inspectable(web)
        web.load(URLRequest(url: url))
        pages[ObjectIdentifier(browser)] = Page(web: web, delegate: delegate)
    }

    func drop(in browser: Browser) {
        guard let page = pages.removeValue(forKey: ObjectIdentifier(browser)) else { return }
        page.web.stopLoading()
        page.web.navigationDelegate = nil
        page.web.uiDelegate = nil
        page.web.removeFromSuperview()
    }

    func bind(_ content: SidePanelContent, to tab: Tab.ID, in browser: Browser) {
        bound[ObjectIdentifier(browser), default: [:]][tab] = content
    }

    func unbind(_ tab: Tab.ID, in browser: Browser) {
        bound[ObjectIdentifier(browser)]?[tab] = nil
    }

    func bound(to tab: Tab.ID, in browser: Browser) -> SidePanelContent? {
        bound[ObjectIdentifier(browser)]?[tab]
    }

    /// An extension gone: its panels with it.
    func forget(_ id: String) {
        for browser in Browsers.all {
            if case .page(let shown, _, _) = browser.sidePanel, shown == id { browser.closeSidePanel() }
            bound[ObjectIdentifier(browser)] = bound[ObjectIdentifier(browser)]?.filter {
                if case .page(let owner, _, _) = $0.value { return owner != id }
                return true
            }
        }
    }
}

/// A website in the panel: its own pages stay in it, a window it opens goes
/// to a tab, only on a click, and nothing but the web loads in it. It never
/// gets the camera, the microphone or the screen: it stays beside every tab,
/// so nobody could tell which page is listening.
@MainActor
private final class SitePanelDelegate: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    weak var browser: Browser?
    init(browser: Browser) { self.browser = browser }

    /// The page that arrived: set when a main-frame navigation commits, and
    /// as the address moves inside the same site (a link the page handles
    /// itself, history.pushState). A page only asked for, or on its way,
    /// leaves it as it was, so the line never names a site not yet there.
    @Published private(set) var arrived: URL?
    private var watching: NSKeyValueObservation?

    func watch(_ web: WKWebView) {
        watching = web.observe(\.url, options: [.new]) { [weak self] web, _ in
            let now = web.url
            DispatchQueue.main.async {
                guard let self, let now, let was = self.arrived, Self.sameSite(now, was) else { return }
                self.arrived = now
            }
        }
    }

    static func sameSite(_ a: URL, _ b: URL) -> Bool {
        a.scheme?.lowercased() == b.scheme?.lowercased() && a.host()?.lowercased() == b.host()?.lowercased() && a.port == b.port
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        arrived = webView.url
    }

    /// Crashes in a row: the page is made again twice a minute at most, then
    /// left as it is (the panel's line still closes it or opens it in a tab).
    private var crashes: [Date] = []

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.shouldPerformDownload { return decisionHandler(.cancel) }
        guard navigationAction.targetFrame?.isMainFrame == true else { return decisionHandler(.allow) }
        let url = navigationAction.request.url
        if PanelSites.allowed(url) || url?.scheme?.lowercased() == "about" { return decisionHandler(.allow) }
        decisionHandler(.cancel)
    }

    /// A link to a new window: a tab, after a click in the panel.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if PanelSites.allowed(navigationAction.request.url), let url = navigationAction.request.url {
            browser?.open(url, foreground: true)
        }
        return nil
    }

    /// No camera, no microphone.
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.deny)
    }

    /// No screen sharing: answered here, as no (0), so WebKit never shows
    /// its picker for the panel.
    @objc(_webView:requestDisplayCapturePermissionForOrigin:initiatedByFrame:withSystemAudio:decisionHandler:)
    func displayCapture(_ web: WKWebView, origin: WKSecurityOrigin, frame: WKFrameInfo, systemAudio: Bool,
                        decisionHandler: @escaping (Int) -> Void) {
        decisionHandler(0)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        let now = Date()
        crashes = crashes.filter { now.timeIntervalSince($0) < 60 } + [now]
        guard crashes.count <= 2 else { return }
        reloads += 1
        webView.reload()
    }

    /// How many times the page was made again, for the bench.
    private(set) var reloads = 0
    var gaveUp: Bool { crashes.count > 2 }
}

/// The panel page's own delegate: a link it opens elsewhere goes to a tab,
/// its camera and microphone are asked for as any extension page's are, and
/// recording the screen is Search's own call only (see ExtensionCapture).
@MainActor
private final class PanelDelegate: NSObject, WKNavigationDelegate, WKUIDelegate {
    weak var browser: Browser?
    /// The extension's own pages, the only ones the panel itself shows.
    let base: URL
    /// The touch a tab was last opened for: one click, one tab, whatever a
    /// script does with it in the second after.
    private var usedTouch: Date?
    /// The page the panel was opened on, a tab's if it fails to load.
    let first: URL
    /// The first page came up: a failure after it is the page's own.
    private var loaded = false
    init(browser: Browser, base: URL, first: URL) { self.browser = browser; self.base = base; self.first = first }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded = true }

    /// The panel's page never came up (a missing file, a page WebKit
    /// refuses): it opens as a tab instead, as it did before the panel.
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        fellThrough(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        fellThrough(error)
    }

    private func fellThrough(_ error: Error) {
        // Cancelled is the panel's own doing (a link sent to a tab, a
        // download refused), not a page that failed.
        guard !loaded, (error as NSError).code != NSURLErrorCancelled,
              (error as NSError).code != 102 // WebKitErrorFrameLoadInterruptedByPolicyChange
        else { return }
        loaded = true
        // After WebKit's turn: this delegate goes with the page it drops.
        let url = first
        DispatchQueue.main.async { [weak browser] in browser?.sidePanelFailed(url) }
    }

    /// Its web process gone: the page is made again where it was.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if loaded { webView.reload() } else { fellThrough(NSError(domain: "Search", code: 1)) }
    }

    /// The same rule as tabs.create and a popup's links: never a file on
    /// this Mac, never javascript:.
    private func openInTab(_ url: URL?) {
        guard #available(macOS 15.4, *), let url, (try? Extensions.mayOpen(url)) != nil, let browser else { return }
        browser.open(url, foreground: true)
    }

    /// One of this extension's pages.
    private func own(_ url: URL) -> Bool {
        url.scheme?.lowercased() == base.scheme?.lowercased() && url.host?.lowercased() == base.host?.lowercased()
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        openInTab(navigationAction.request.url)
        return nil
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        guard let browser else { return decisionHandler(.deny) }
        browser.askedForCapture(webView, origin: origin, frame: frame, type: type, decisionHandler: decisionHandler)
    }

    @objc(_webView:requestDisplayCapturePermissionForOrigin:initiatedByFrame:withSystemAudio:decisionHandler:)
    func displayCapture(_ web: WKWebView, origin: WKSecurityOrigin, frame: WKFrameInfo, systemAudio: Bool,
                        decisionHandler: @escaping (Int) -> Void) {
        if #available(macOS 15.4, *) { decisionHandler(ExtensionCapture.shared.displayDecision(for: web)) } else { decisionHandler(0) }
    }

    /// A download the panel starts is the browser's, as from any page. The
    /// panel itself only ever shows the extension's own pages: it has no
    /// address to read, and stays beside every tab, so a website in it would
    /// be a page nobody can tell the address of. A site the panel goes to
    /// opens in a tab instead. Frames inside the page are the page's business
    /// (ChatGPT's and Claude's panels show their site in one).
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.shouldPerformDownload { return decisionHandler(.cancel) }
        guard navigationAction.targetFrame?.isMainFrame == true, let url = navigationAction.request.url else {
            return decisionHandler(.allow)
        }
        if own(url) { return decisionHandler(.allow) }
        // A blank document, only as the extension's own page asks for one.
        if url.scheme?.lowercased() == "about",
           let from = navigationAction.sourceFrame.request.url, own(from) {
            return decisionHandler(.allow)
        }
        decisionHandler(.cancel)
        // Into a tab only for a link followed or a form sent by a hand: a
        // real click or key in the panel this last second (a script's own
        // element.click() counts as a link too). A page setting `location`
        // over and over by itself would otherwise fill the window with tabs.
        guard #available(macOS 15.4, *), [.linkActivated, .formSubmitted].contains(navigationAction.navigationType),
              let touch = base.host.flatMap({ Extensions.touched[$0] }),
              Date().timeIntervalSince(touch) < 1, touch != usedTouch
        else { return }
        usedTouch = touch
        openInTab(url)
    }
}

// MARK: - what the card shows

/// What is in the side panel, filling the card the window gives it.
struct SidePanelView: View {
    @ObservedObject var browser: Browser

    var body: some View {
        switch browser.sidePanel {
        case .page(let id, _, _):
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    if #available(macOS 15.4, *), let icon = Extensions.shared.contexts[id]?.webExtension.icon(for: CGSize(width: 16, height: 16)) {
                        Image(nsImage: icon).resizable().interpolation(.high).frame(width: 14, height: 14)
                    }
                    Text(Browser.extensionName(id))
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Door(icon: "xmark", help: "Close") { browser.closeSidePanel() }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                Rectangle().fill(Palette.hairline).frame(height: 1)
                PanelPage(web: SidePanelPages.shared.web(in: browser))
            }
        case .site:
            VStack(spacing: 0) {
                // Its own line for each page made: a new site's line
                // watches the new page, not the one let go.
                if let delegate = SidePanelPages.shared.siteDelegate(in: browser) {
                    SiteLine(browser: browser, delegate: delegate).id(ObjectIdentifier(delegate))
                }
                Rectangle().fill(Palette.hairline).frame(height: 1)
                PanelPage(web: SidePanelPages.shared.web(in: browser))
            }
        case nil:
            Color.clear
        }
    }
}

/// A website's line above it in the panel: where it is, since it stays
/// beside every tab, then into a tab of its own, and close.
private struct SiteLine: View {
    @ObservedObject var browser: Browser
    @StateObject private var seen: Seen

    init(browser: Browser, delegate: SitePanelDelegate) {
        self.browser = browser
        _seen = StateObject(wrappedValue: Seen(delegate))
    }

    /// The address of the page that arrived, as it changes.
    @MainActor final class Seen: ObservableObject {
        @Published var host = ""
        private var watch: AnyCancellable?
        init(_ delegate: SitePanelDelegate) {
            host = Seen.name(delegate.arrived)
            watch = delegate.$arrived.receive(on: DispatchQueue.main).sink { [weak self] url in
                self?.host = Seen.name(url)
            }
        }
        nonisolated static func name(_ url: URL?) -> String {
            guard let url, let host = url.host() else { return "" }
            return Address.withoutWWW(host) + (url.scheme?.lowercased() == "http" ? " (not secure)" : "")
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(seen.host)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Door(icon: "arrow.up.forward.square", help: "Open in a Tab") { browser.sitePanelToTab() }
            Door(icon: "xmark", help: "Close") { browser.closeSidePanel() }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// The page in the panel. It is handed the page itself, not the window:
/// SwiftUI only updates a representable whose values changed, and the window
/// stays the same object when another site (or the same one again, from
/// View › Side Panel) replaces the page. Holding the window, the holder kept
/// the page just let go, taken out of it, and the panel stayed white.
private struct PanelPage: NSViewRepresentable {
    let web: WKWebView?

    func makeNSView(context: Context) -> NSView {
        let holder = NSView()
        place(in: holder)
        return holder
    }

    func updateNSView(_ holder: NSView, context: Context) { place(in: holder) }

    private func place(in holder: NSView) {
        guard let web else {
            holder.subviews.forEach { $0.removeFromSuperview() }
            return
        }
        guard web.superview !== holder else { return }
        holder.subviews.forEach { $0.removeFromSuperview() }
        web.removeFromSuperview()
        web.frame = holder.bounds
        web.autoresizingMask = [.width, .height]
        holder.addSubview(web)
    }
}

/// The panel beside the page, on the side away from the column. With the
/// page as a card it is a card of its own after the same gap; edge to edge,
/// it meets the page at a hairline. The gap, or a strip along the hairline,
/// is its handle, with a small pill in the middle (see Grip): dragged, the panel is wider or narrower, kept within
/// reason and remembered; double-clicked, back to where it starts.
struct SidePanelBeside: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    /// On the left of the page, the column being on its right.
    let onLeft: Bool
    /// The page as a card, and so this one.
    let card: Bool
    /// As wide as it is drawn: the width asked for, or less in a narrow window.
    let width: CGFloat

    @State private var start: CGFloat?
    @State private var over = false

    var body: some View {
        HStack(spacing: 0) {
            if !onLeft { edge }
            SidePanelView(browser: browser)
                .background(Palette.ground)
                .modifier(CardEdge(on: card))
                .frame(width: width)
            if onLeft { edge }
        }
    }

    /// The card's gap, or the hairline, with the handle on it.
    @ViewBuilder private var edge: some View {
        if card {
            handle.frame(width: Metrics.cardGap)
        } else {
            Rectangle().fill(Palette.hairline).frame(width: 1)
                .overlay { handle.frame(width: 7) }
        }
    }

    /// The whole edge takes the pointer; a small pill in the middle of it
    /// shows under the pointer and while held (see Grip).
    private var handle: some View {
        EdgeGrip(lit: over || start != nil)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { inside in
                guard inside != over else { return }
                over = inside
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { drag in
                        let from = start ?? prefs.sidePanelWidth
                        if start == nil { start = from }
                        let moved = drag.translation.width
                        prefs.sidePanelWidth = from + (onLeft ? moved : -moved)
                    }
                    .onEnded { _ in start = nil }
            )
            // Double-click: back to where it starts.
            .onTapGesture(count: 2) { prefs.sidePanelWidth = Preferences.sidePanelStart }
    }
}
