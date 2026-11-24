import AppKit
import WebKit

// What Search and a developer tools package say to each other, and nothing
// more. A package is a signed bundle Search downloads on request (Settings ›
// About › Developer), checks before every load, and loads only when one of
// its tools is first used. Its principal class conforms to
// SearchDevToolsPlugin; Search hands it a SearchDevToolsHost.
//
// Only Objective-C protocols and plain Foundation, AppKit and WebKit types
// cross: both sides are built from this file, and the runtime matches the
// protocols by name. Nothing here is a class, so the two copies never
// clash. A change that breaks either side raises `apiVersion`; Search loads
// a package only for its own version.

public enum SearchDevToolsAPI {
    /// The version both sides are built against. A package says its own in
    /// its Info.plist (SearchDevToolsAPI) and in the feed.
    public static let version = 1
    /// The Info.plist key with the package's API version.
    public static let infoKey = "SearchDevToolsAPI"
}

/// Search, as a package sees it. Every call is on the main thread.
@objc(SearchDevToolsHost) @MainActor
public protocol SearchDevToolsHost: NSObjectProtocol {
    /// The package's own content world: not the page's, not Search's.
    var isolatedWorld: WKContentWorld { get }
    /// A session for the package's own requests: ephemeral, through
    /// Search's proxy, with no cookies, no credentials and no cache.
    func ephemeralSession() -> URLSession
    /// The tab's page isn't put to sleep while on.
    func keepAwake(_ on: Bool, webView: WKWebView)
    /// Opens an address in a new tab in front.
    func openURL(_ url: URL)
    /// The package's own settings: a store of its own in the profile, never
    /// Search's, deleted with the package. Only the choices made in the
    /// tools go there, never what a page showed them.
    var defaults: UserDefaults { get }
    /// One setting of that store. Nil removes. Only property-list values.
    func setting(forKey key: String) -> Any?
    func setSetting(_ value: Any?, forKey key: String)
    /// A private tab keeps nothing.
    func isPrivate(_ webView: WKWebView) -> Bool
    /// The tab's next document gets the package's scripts again (asks
    /// `scripts(for:)`).
    func rearm(_ webView: WKWebView)
    /// What the package draws around the page changed: Search asks again.
    func invalidate()
}

/// Optional host capability for installed WebExtension DevTools pages.
/// Older hosts and packages still use SearchDevToolsHost.
@objc(SearchDevToolsExtensionHost) @MainActor
public protocol SearchDevToolsExtensionHost: SearchDevToolsHost {
    func startExtensionPanels(in webView: WKWebView, changed: @escaping () -> Void)
    func stopExtensionPanels(in webView: WKWebView)
    /// Registration order, with string id and title in each row.
    func extensionPanels(in webView: WKWebView) -> [[String: String]]
    func extensionPanelIcon(_ id: String, in webView: WKWebView) -> NSImage?
    func selectedExtensionPanel(in webView: WKWebView) -> String?
    /// Nil hides the current panel. A valid selection returns its extension view.
    func showExtensionPanel(_ id: String?, in webView: WKWebView) -> NSView?
}

/// A package, as Search sees it. Every call is on the main thread.
@objc(SearchDevToolsPlugin) @MainActor
public protocol SearchDevToolsPlugin: NSObjectProtocol {
    /// The API version the package was built against.
    static var apiVersion: Int { get }
    init()
    /// Once, right after loading.
    func start(host: SearchDevToolsHost)
    /// Search is going, or the package was removed: put everything back.
    func shutdown()

    /// The menu's items, as [["id": String, "title": String]]. Three ids
    /// mean an inspector, and take Search's own inspector keys while the
    /// package is the one View › Developer uses: "devtools" (⌥⌘I),
    /// "console" (⌥⌘J) and "pick" (⌥⌘C). Search reads them from the
    /// package.json it installed, so a menu never loads the package.
    func menuItems() -> [[String: String]]
    /// A menu item, on the tab's page.
    func open(_ item: String, webView: WKWebView)
    func close(webView: WKWebView)
    func isOpen(webView: WKWebView) -> Bool
    /// A key, before Search's own; true if the package took it.
    func keyDown(_ event: NSEvent, webView: WKWebView) -> Bool
    /// Inspect Element from the page's menu, at a point in the page view's
    /// coordinates: true if the package showed it, false to leave it to Web
    /// Inspector. Asked only of a package whose menu has "devtools".
    func inspect(at point: NSPoint, webView: WKWebView) -> Bool

    /// The panel beside the page, if one is up.
    func dockView(webView: WKWebView) -> NSView?
    /// Where that panel goes and how big it is: ["edge": "right" | "left" |
    /// "bottom", "size": points]. Nil: on the right, 360 points.
    func dockPlacement(webView: WKWebView) -> [String: Any]?
    /// The person dragged the panel's edge to `size` points.
    func setDockSize(_ size: Double, webView: WKWebView)
    /// A bar over the page, if one is up.
    func barView(webView: WKWebView) -> NSView?
    /// The page's size in points, when the package wants it framed (a
    /// device's viewport), as an NSValue of an NSSize.
    func viewportSize(webView: WKWebView) -> NSValue?

    /// The user scripts the tab's next document needs: none unless a tool
    /// is open on it.
    func scripts(webView: WKWebView) -> [WKUserScript]
    /// The main document's answer.
    func didReceiveResponse(_ response: URLResponse, webView: WKWebView)
    /// The tab's page view is going (asleep or closed).
    func tabWillUnload(webView: WKWebView)

    /// A tool driven by name, for tests and automation; the answer is a
    /// property list.
    func perform(_ command: String, arguments: [String: Any], webView: WKWebView?,
                 completion: @escaping ([String: Any]) -> Void)
}
