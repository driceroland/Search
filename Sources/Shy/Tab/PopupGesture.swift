import WebKit

/// One new browsing context for a recent real interaction. WebKit's form
/// submission path still uses its synchronous gesture indicator; after a
/// fetch, a POST to _blank can be refused even while userActivation is active.
/// Shy keeps the short-lived permission outside the page instead.
struct PopupGesture {
    private var origin: String?
    private var recorded = false
    private var time: TimeInterval = 0
    private var consumed = false
    private var input = false
    private var menu = false
    /// Which interaction this is, kept across clear(), and the tab the
    /// page's own window for it became (see opened(_:) and claim()).
    private var serial = 0
    private var made: (serial: Int, tab: UUID)?

    mutating func record(origin: String?, kind: String, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        // Click and contextmenu follow mousedown (or keyboard activation). They must not
        // grant a second window after the first event already opened one,
        // even when the button was held for most of the activation window.
        if kind != "input", input, self.origin == origin, now >= time, now - time <= 5 {
            if kind == "menu" { menu = true }
            return
        }
        self.origin = origin
        serial += 1
        recorded = true
        time = now
        consumed = false
        input = kind != "click"
        menu = kind == "menu"
    }

    mutating func take(origin: String?, mainFrame: Bool = false, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        // Activation in an iframe also activates its top-level document.
        // It does not activate an unrelated third-party sibling frame.
        // Opaque origins have no tuple to compare. They can activate the
        // top-level document, never another opaque (or named) subframe.
        guard recorded, (mainFrame || (origin != nil && self.origin == origin)),
              !consumed, now >= time, now - time <= 5 else { return false }
        consumed = true
        return true
    }

    /// Whether a refused window came from an interaction that already
    /// had its one: a second window for the same click, or a page's own
    /// beside the tab Shy opened for a ⌘-click (see claim()). That one
    /// is the duplicate one click must not make, not a pop-up to offer.
    func spent(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        recorded && consumed && now >= time && now - time <= 5
    }

    mutating func clear() {
        let serial = serial
        self = PopupGesture()
        self.serial = serial
    }

    /// The window take() just granted became this tab.
    mutating func opened(_ tab: UUID) {
        made = (serial, tab)
    }

    /// A tab Shy opens itself for a click — ⌘-click, the middle button.
    /// One click makes one tab: a page that also calls window.open from the
    /// same click (Gmail's links do, beside their own target=_blank) gets no
    /// second one, whichever comes first. Returns the tab the page's window
    /// already became for this interaction, if it came first; otherwise the
    /// interaction is spent, so a window.open after this is refused.
    mutating func claim(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> UUID? {
        guard recorded, now >= time, now - time <= 5 else { return nil }
        if consumed, let made, made.serial == serial { return made.tab }
        consumed = true
        return nil
    }

    /// A native menu can remain open beyond the activation window. Keep the
    /// recorded frame and one-use limit when its action finally reaches WebKit.
    mutating func menuClosed(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard menu else { return }
        menu = false
        guard recorded, !consumed, now >= time else { return }
        time = now
    }

    static func origin(_ info: WKFrameInfo) -> String? {
        let origin = info.securityOrigin
        if let key = originKey(scheme: origin.protocol, host: origin.host, port: origin.port) { return key }
        // A sandboxed frame has an opaque origin: no tuple, so its own click
        // never matched the link it was on, and every target=_blank link in
        // it did nothing (answers some AI chats draw in a sandbox). It is
        // keyed by its own document instead, never matching a frame with a
        // tuple, nor an opaque top-level page (that one goes by mainFrame).
        guard !info.isMainFrame, let url = info.request.url?.absoluteString, !url.isEmpty else { return nil }
        return "opaque " + url
    }

    static func originKey(scheme: String, host: String, port: Int) -> String? {
        guard !scheme.isEmpty, !host.isEmpty else { return nil }
        return "\(scheme)://\(host):\(port)"
    }
}

/// Only the isolated Shy world has this handler. Website code cannot
/// call it or replace its listener; dispatched events do not grant windows.
final class PopupGestureRelay: NSObject, WKScriptMessageHandler {
    static let name = "officePopupGesture"

    static let script = Scripts.load("popup-gesture")

    @MainActor static func install(on controller: WKUserContentController) {
        controller.add(PopupGestureRelay(), contentWorld: Web.world, name: name)
    }

    @MainActor static var userScript: WKUserScript {
        WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: Web.world)
    }

    // Extension pages share a controller, so its most recently installed
    // relay must route by the message's view, not by the tab that made it.
    @MainActor static func tab(for webView: WKWebView) -> Tab? {
        (webView.navigationDelegate as? Browser)?.popupTab(for: webView)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let kind = message.body as? String, ["input", "click", "menu"].contains(kind) else { return }
        MainActor.assumeIsolated {
            guard let webView = message.webView, let tab = Self.tab(for: webView) else { return }
            tab.popupGesture.record(origin: PopupGesture.origin(message.frameInfo), kind: kind)
        }
    }
}
