import SwiftUI
import WebKit

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
// Where the card goes, its gap, corners and the handle that resizes it are
// the window's layout (ContentView); what is in it is here.

enum SidePanelContent: Equatable {
    /// An extension's panel page. `tab`: the tab it was opened for, when the
    /// extension named one (setOptions with a tabId) — it goes with that tab,
    /// hidden on the others and back on it, as in Chrome. Nil: the window's.
    case page(extensionID: String, url: URL, tab: Tab.ID?)
}

extension Preferences {
    /// The side panel's width, as you last left it, within reason.
    static let sidePanelWidths: ClosedRange<CGFloat> = 300...640
    static let sidePanelStart: CGFloat = 380
}

// MARK: - opening and closing

extension Browser {
    /// An extension's panel page in this window's side panel.
    /// False when there is no panel to be had (a popup window, no page
    /// made): the caller opens the page as a tab instead.
    @available(macOS 15.4, *)
    @discardableResult
    func showSidePanel(_ context: WKWebExtensionContext, url: URL, for tab: Tab.ID? = nil) -> Bool {
        guard extensionPopup == nil else { return false }
        let content = SidePanelContent.page(extensionID: context.uniqueIdentifier, url: url, tab: tab)
        guard SidePanelPages.shared.load(url, from: context, in: self) else { return false }
        if let tab { SidePanelPages.shared.bind(content, to: tab, in: self) }
        sidePanel = content
        sidePanelShown = true
        return true
    }

    /// The extension's button again, with its panel up: it goes, as a
    /// second press on a popup's button does.
    @available(macOS 15.4, *)
    func toggleSidePanel(_ context: WKWebExtensionContext, url: URL, for tab: Tab.ID? = nil) -> Bool {
        if sidePanelShown, case .page(let id, _, _) = sidePanel, id == context.uniqueIdentifier {
            closeSidePanel()
            return true
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

    /// Closed: an extension's page is let go, as Chrome does.
    func closeSidePanel() {
        if case .page(_, _, let tab?) = sidePanel { SidePanelPages.shared.unbind(tab, in: self) }
        SidePanelPages.shared.drop(in: self)
        sidePanelShown = false
        sidePanel = nil
    }

    /// Another tab in front: a panel opened for the tab just left goes
    /// with it, and one opened for this tab comes back.
    func sidePanelFollows(_ tab: Tab) {
        if case .page(_, _, let bound?) = sidePanel, bound != tab.id {
            SidePanelPages.shared.drop(in: self)
            sidePanelShown = false
            sidePanel = nil
        }
        if #available(macOS 15.4, *), sidePanel == nil,
           case .page(let id, let url, _)? = SidePanelPages.shared.bound(to: tab.id, in: self),
           let context = Extensions.shared.contexts[id] {
            showSidePanel(context, url: url, for: tab.id)
        }
    }
}

// MARK: - the extension's page

/// Each window's panel page, and the panels bound to its tabs.
@MainActor
final class SidePanelPages: NSObject {
    static let shared = SidePanelPages()

    private final class Page {
        let web: WKWebView
        let delegate: PanelDelegate
        init(web: WKWebView, delegate: PanelDelegate) { self.web = web; self.delegate = delegate }
    }
    private var pages: [ObjectIdentifier: Page] = [:]
    private var bound: [ObjectIdentifier: [Tab.ID: SidePanelContent]] = [:]

    /// The page up in this window's panel, for SidePanelView and the bench.
    func web(in browser: Browser) -> WKWebView? { pages[ObjectIdentifier(browser)]?.web }

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
                PanelPage(browser: browser)
            }
        case nil:
            Color.clear
        }
    }
}

/// The extension's page, in the panel.
private struct PanelPage: NSViewRepresentable {
    let browser: Browser

    func makeNSView(context: Context) -> NSView {
        let holder = NSView()
        place(in: holder)
        return holder
    }

    func updateNSView(_ holder: NSView, context: Context) { place(in: holder) }

    private func place(in holder: NSView) {
        guard let web = SidePanelPages.shared.web(in: browser) else {
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
/// is its handle: dragged, the panel is wider or narrower, kept within
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

    private var handle: some View {
        Color.clear
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
