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

    init?(context: WKWebExtensionContext, url: URL, browser: Browser) {
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
        web.load(URLRequest(url: url))
    }

    func forget() {
        Extensions.shared.controller.didCloseTab(page, windowIsClosing: false)
    }

    // MARK: - the page asking

    /// window.close() from the panel — how an extension closes its own
    /// panel, Chrome having no sidePanel.close().
    func webViewDidClose(_ webView: WKWebView) { browser.closePanel() }

    /// A link that asks for a new window becomes a tab. The panel stays: it
    /// is the window's furniture, not a popup that a click is done with.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url { browser.open(url, foreground: true) }
        return nil
    }

    /// The panel shows the extension's own pages and nothing else: a
    /// website it sends itself to goes to the row, and the panel keeps its
    /// page. Frames inside it may load what they like.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard action.targetFrame?.isMainFrame ?? true, let url = action.request.url,
              url.scheme != "about", url.scheme != base.scheme || url.host != base.host
        else { decisionHandler(.allow); return }
        browser.open(url, foreground: true)
        decisionHandler(.cancel)
    }
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
    /// The extension's panel, up beside the page. Another extension's panel
    /// goes first — one at a time, as in Chrome; the same one already up
    /// stays as it is.
    @available(macOS 15.4, *)
    func showPanel(for context: WKWebExtensionContext) throws {
        let id = context.uniqueIdentifier
        if panel?.id == id { return }
        guard let path = ExtensionShims.panelPath[id] ?? ExtensionShims.defaultPanel(context) else {
            // Chrome refuses the same call the same way.
            throw ExtensionShims.Unsupported(what: "No side panel path is set")
        }
        let url = context.baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        closePanel()
        guard let opened = ExtensionPanel(context: context, url: url, browser: self) else { return }
        panel = opened
    }

    /// Put away. The one path out: the cross, the button, window.close(),
    /// setOptions({enabled: false}) and an extension going all come here.
    func closePanel() {
        guard let panel else { return }
        self.panel = nil
        panel.forget()
    }

    /// The extension's button: up if it isn't, away if it is, as Chrome's.
    @available(macOS 15.4, *)
    func togglePanel(for context: WKWebExtensionContext) throws {
        if panel?.id == context.uniqueIdentifier { closePanel() } else { try showPanel(for: context) }
    }
}
