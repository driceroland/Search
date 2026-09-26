import AppKit
import SwiftUI
import WebKit

// An extension's side panel: its page, docked down the right of the window
// beside the page you are reading, where Chrome docks one.
//
// It used to open as a tab of its own, which is the one place a side panel
// can't work from. A panel exists to look at the page beside it, and a tab
// in front *is* the page in front: tabs.query({active: true}) answered with
// the panel itself, and so did captureVisibleTab.
//
// The page is loaded in a view built from the extension's configuration, as
// its popup is (see ExtensionPopup), and told to WebKit the same way: in the
// browser's window, but not among its tabs. That is what makes it a panel to
// the extension — the tab in front stays the tab in front — without a word
// of special casing in the shim.

/// What the window needs of a docked page, without the extension world it
/// comes from, which begins at macOS 15.4 while the window is built for 14.
@MainActor
protocol DockedPage: AnyObject {
    var id: String { get }
    var name: String { get }
    var icon: NSImage? { get }
    var view: NSView { get }
    /// The window is done with it: WebKit is told, and the view goes.
    func forget()
}

@available(macOS 15.4, *)
@MainActor
final class ExtensionPanel: NSObject, DockedPage, WKUIDelegate, WKNavigationDelegate {
    let id: String
    let name: String
    let icon: NSImage?
    let web: WKWebView
    /// The panel as WebKit is told about it (see PanelPage).
    let page: PanelPage
    private unowned let browser: Browser
    /// Only the extension's own pages are shown here; anything else it
    /// goes to is a page for the row.
    private let base: URL

    var view: NSView { web }
    /// The path the extension asked for, as `onOpened` reports it.
    private var pathShown = ""
    private var expected: URL?
    private var announced = false

    init?(context: WKWebExtensionContext, url: URL, path: String, browser: Browser) {
        guard let configuration = context.webViewConfiguration else { return nil }
        id = context.uniqueIdentifier
        name = context.webExtension.displayName ?? id
        icon = context.action(for: nil)?.icon(for: CGSize(width: 16, height: 16))
        base = context.baseURL
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: Metrics.panel, height: 600), configuration: configuration)
        page = PanelPage(web: web)
        self.browser = browser
        super.init()
        web.uiDelegate = self
        web.navigationDelegate = self
        Extensions.shared.controller.didOpenTab(page)
        show(url, path: path)
    }

    /// Another path for the panel that is already up. The same document,
    /// including one still loading, is left to finish.
    func show(_ url: URL, path: String) {
        pathShown = path
        let same = web.url?.absoluteString == url.absoluteString
            || (expected?.absoluteString == url.absoluteString && (web.isLoading || web.url == nil))
        expected = url
        if same {
            if !web.isLoading, web.url != nil { announce("onOpened") }
            return
        }
        announced = false
        web.load(URLRequest(url: url))
    }

    func forget() {
        Extensions.shared.controller.didCloseTab(page, windowIsClosing: false)
    }

    // MARK: - the page asking

    /// window.close() from the panel, and sidePanel.close() from its worker.
    func webViewDidClose(_ webView: WKWebView) { browser.closePanel() }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // A later load is not a window script opened, so WebKit ignores
        // window.close(). The panel's own page closes itself through us.
        web.evaluateJavaScript("""
        if (!window.__searchPanelClose) {
          window.__searchPanelClose = true;
          window.close = function () {
            try { chrome.runtime.sendNativeMessage("search", {api: "sidePanel.dismiss", args: []}); }
            catch (e) {}
          };
        }
        """) { _, _ in }
        guard let expected, web.url?.absoluteString == expected.absoluteString else { return }
        announce("onOpened")
    }

    /// `onOpened` / `onClosed`, in this page and, through it, in the worker.
    func announce(_ name: String) {
        if name == "onOpened" {
            guard !announced else { return }
            announced = true
        } else {
            guard announced else { return }
            announced = false
        }
        var info: [String: Any] = ["path": pathShown, "windowId": ExtensionShims.frontWindow ?? 0]
        if ExtensionShims.opened?.id == id, let tab = ExtensionShims.opened?.tab { info["tabId"] = tab }
        guard let data = try? JSONSerialization.data(withJSONObject: info),
              let json = String(data: data, encoding: .utf8) else { return }
        let js = """
        (() => { try {
          const info = \(json);
          const ev = chrome.sidePanel && chrome.sidePanel.\(name);
          if (ev && ev.listeners) for (const f of [...ev.listeners]) { try { f(info); } catch (e) {} }
          chrome.runtime.sendMessage({ __searchSidePanel: { event: "\(name)", info } });
        } catch (e) {} })()
        """
        web.evaluateJavaScript(js) { _, _ in }
    }

    /// A link that asks for a new window becomes a tab. The panel stays: it
    /// is the window's furniture, not a popup that a click is done with.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url { browser.open(url, foreground: true) }
        return nil
    }

    /// The panel shows the extension's own pages and nothing else: a
    /// website it sends itself to goes to the row, an address for another
    /// app is handed off as a page's is, and the panel keeps its page. A
    /// download is a download, not the panel's next page (see the same
    /// guard in Browser). Frames inside it may load what they like.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard !action.shouldPerformDownload else { decisionHandler(.download); return }
        guard action.targetFrame?.isMainFrame ?? true, let url = action.request.url,
              let scheme = url.scheme?.lowercased(), !own(url)
        else { decisionHandler(.allow); return }
        decisionHandler(.cancel)
        if ["http", "https", "file"].contains(scheme) {
            browser.open(url, foreground: true)
        } else {
            browser.handOff(url, scheme: scheme, action: action, from: webView)
        }
    }

    /// The extension's own: its pages, and a blob it made for itself
    /// (blob:chrome-extension://id/…, the usual shape of an export).
    private func own(_ url: URL) -> Bool {
        if url.scheme == "about" { return true }
        var inner = url.absoluteString
        if url.scheme == "blob" { inner = String(inner.dropFirst("blob:".count)) }
        guard let parts = URL(string: inner) else { return false }
        return parts.scheme == base.scheme && parts.host == base.host
    }

    /// A download from the panel goes where the window's downloads go.
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { browser.keep(download) }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { browser.keep(download) }
}

/// The panel page, as WebKit finds it: in the browser's window, but not
/// among its tabs — where Chrome keeps a side panel too. Not being a tab is
/// what keeps the tab in front the tab in front: tabs.query({active: true})
/// from the panel is the page beside it, tabs.getCurrent() is nothing, and
/// captureVisibleTab shoots the page.
@available(macOS 15.4, *)
@MainActor
final class PanelPage: NSObject, WKWebExtensionTab {
    weak var web: WKWebView?

    init(web: WKWebView) { self.web = web }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { Extensions.shared.window }
    func indexInWindow(for context: WKWebExtensionContext) -> Int { NSNotFound }
    func webView(for context: WKWebExtensionContext) -> WKWebView? { web }
    func title(for context: WKWebExtensionContext) -> String? { web?.title }
    func url(for context: WKWebExtensionContext) -> URL? { web?.url }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !(web?.isLoading ?? false) }
    func isSelected(for context: WKWebExtensionContext) -> Bool { false }
    func close(for context: WKWebExtensionContext) async throws { Extensions.shared.browser?.closePanel() }
}

extension Browser {
    /// The extension's panel, up beside the page. Another extension's goes
    /// first. The same one, asked for a different path, navigates; Chrome
    /// swaps the open panel's page that way.
    @available(macOS 15.4, *)
    func presentPanel(for context: WKWebExtensionContext, path: String) {
        let url = ExtensionShims.pageURL(path, base: context.baseURL)
        panelHeld = false
        if let panel = panel as? ExtensionPanel, panel.id == context.uniqueIdentifier {
            panel.show(url, path: path)
            return
        }
        closePanel()
        guard let opened = ExtensionPanel(context: context, url: url, path: path, browser: self) else { return }
        panel = opened
    }

    /// Off this tab, but not dismissed: the page stays, the column doesn't.
    /// Coming back to a tab where it is enabled shows it again.
    @available(macOS 15.4, *)
    func holdPanel() {
        guard let panel = panel as? ExtensionPanel else { panelHeld = true; return }
        guard !panelHeld else { return }
        panel.announce("onClosed")
        panelHeld = true
    }

    /// Put away. The cross, the button, window.close(), sidePanel.close(),
    /// setOptions({enabled: false}) and an extension going all come here.
    /// `immediately`: the extension itself is going, so the view cannot
    /// outlive its context by a turn.
    func closePanel(immediately: Bool = false) {
        panelHeld = false
        guard let panel else { return }
        if #available(macOS 15.4, *) {
            (panel as? ExtensionPanel)?.announce("onClosed")
            if ExtensionShims.opened?.id == panel.id { ExtensionShims.opened = nil }
        }
        let going = panel
        self.panel = nil
        if immediately { going.forget(); return }
        // The close event is a script in the page. Let it run, then drop the view.
        DispatchQueue.main.async { going.forget() }
    }

    /// The extension's button: up if it isn't, away if it is, as Chrome's.
    @available(macOS 15.4, *)
    func togglePanel(for context: WKWebExtensionContext) throws {
        if panel?.id == context.uniqueIdentifier, !panelHeld {
            closePanel()
        } else {
            try ExtensionShims.openFromAction(context, owner: Extensions.shared)
        }
    }
}

/// The column: the extension's name over its page, and a hairline on its
/// left that pulls to resize, as the tabs' column pulls on its right.
struct PanelColumn: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    let panel: DockedPage
    /// What the window can give it right now (see ContentView.panelWidth).
    let width: CGFloat

    /// The width the panel had when the edge was picked up.
    @State private var grabbed: CGFloat?
    @State private var onEdge = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if let icon = panel.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 16, height: 16)
                }
                Text(panel.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                Spacer(minLength: 0)
                PeekPanel.Knob("xmark", help: "Close") { browser.closePanel() }
            }
            .padding(.leading, 12)
            .padding(.trailing, 4)
            .frame(height: Metrics.panelHead)
            Rectangle().fill(Palette.hairline).frame(height: 1)
            WebStage(page: panel.view)
        }
        .frame(width: width)
        .frame(maxHeight: .infinity)
        .background(Palette.ground)
        .overlay(alignment: .leading) {
            Rectangle().fill(Palette.hairline).frame(width: 1)
        }
        .overlay(alignment: .leading) { edge }
    }

    /// The panel's edge: pull it to make the panel wider or narrower,
    /// double-click it to put it back. On the right, pulling left widens.
    private var edge: some View {
        Rectangle()
            .fill(Palette.ink.opacity(onEdge || grabbed != nil ? 0.18 : 0))
            .frame(width: onEdge || grabbed != nil ? 2 : 1)
            .frame(width: 9)
            .contentShape(Rectangle())
            .onHover { over in
                onEdge = over
                if over { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        if grabbed == nil { grabbed = prefs.panelWidth }
                        let wanted = (grabbed ?? prefs.panelWidth) - value.translation.width
                        prefs.panelWidth = min(Metrics.panelMax, max(Metrics.panelMin, wanted))
                    }
                    .onEnded { _ in grabbed = nil }
            )
            .modifier(OneClick(double: true) {
                withAnimation(Motion.settle) { prefs.panelWidth = Metrics.panel }
            })
            .animation(Motion.quick, value: onEdge)
    }
}
