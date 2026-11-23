import AppKit
import WebKit

// The one file that touches WebKit's private inspector. The panels that read
// the page through WebKit's inspector protocol (Elements and Styles,
// Console, Sources and the debugger, Network, Application's storage,
// Performance, Memory, Coverage, CSS overview and Issues) need it: WebKit
// gives no public way to that protocol. It is the same inspector Web
// Inspector uses, connected without showing its window; the package's
// scripts then run in that hidden inspector page, never in the site's.
//
// Every name is asked for before it is used (respondsToSelector), and the
// inspector page must be WebKit's own (WebInspectorUI.framework). A WebKit
// that changed them leaves those panels saying "Not available on this
// macOS" rather than the app falling over. Lighthouse, the Recorder and the
// device toolbar don't use it.

@MainActor
final class DeveloperInspectorLink {
    /// _WKInspector, as WKWebView's private `_inspector` gives it.
    private let inspector: NSObject

    /// The names this file calls. All of them, or none is used.
    private static let needed = ["connect", "close", "inspectorWebView", "isVisible"]

    /// The page's inspector, if this WebKit has every name asked for.
    init?(_ web: WKWebView) {
        let get = NSSelectorFromString("_inspector")
        guard web.responds(to: get), let inspector = web.perform(get)?.takeUnretainedValue() as? NSObject,
              Self.needed.allSatisfy({ inspector.responds(to: NSSelectorFromString($0)) }) else { return nil }
        self.inspector = inspector
    }

    /// Whether this macOS's WebKit has what the inspector panels need, asked
    /// of a page view without connecting anything.
    static func available(_ web: WKWebView) -> Bool { DeveloperInspectorLink(web) != nil }

    /// Web Inspector's own window, if it is up on this page.
    var visible: Bool {
        let selector = NSSelectorFromString("isVisible")
        guard inspector.responds(to: selector) else { return false }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(inspector.method(for: selector), to: Getter.self)(inspector, selector)
    }

    /// Connected without a window: Web Inspector's window, if up, closes.
    func connect() {
        if visible { send("close") }
        send("connect")
    }

    /// Web Inspector's window came up over the hidden one: hidden again.
    func hide() { send("hide") }

    func close() { send("close") }

    /// WebKit's hidden inspector page, once it has loaded.
    func frontend(besides web: WKWebView?) -> WKWebView? {
        let selector = NSSelectorFromString("inspectorWebView")
        guard inspector.responds(to: selector),
              let view = inspector.perform(selector)?.takeUnretainedValue() as? WKWebView,
              view !== web, Self.isInspectorPage(view.url) else { return nil }
        return view
    }

    /// WebKit's own inspector page, and nothing else.
    static func isInspectorPage(_ url: URL?) -> Bool {
        guard let url, url.lastPathComponent == "Main.html" else { return false }
        if url.scheme == "inspector-resource" { return url.host()?.isEmpty != false && url.path == "/Main.html" }
        return url.isFileURL && url.path.hasPrefix("/System/") && url.path.contains("/WebInspectorUI.framework/")
    }

    private func send(_ name: String) {
        let selector = NSSelectorFromString(name)
        guard inspector.responds(to: selector) else { return }
        inspector.perform(selector)
    }
}
