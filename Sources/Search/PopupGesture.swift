import WebKit

/// One new browsing context for a recent real interaction. WebKit's form
/// submission path still uses its synchronous gesture indicator; after a
/// fetch, a POST to _blank can be refused even while userActivation is active.
/// Search keeps the short-lived permission outside the page instead.
struct PopupGesture {
    private var origin: String?
    private var recorded = false
    private var time: TimeInterval = 0
    private var consumed = false
    private var input = false
    private var menu = false

    mutating func record(origin: String?, kind: String, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        // Click and contextmenu follow mousedown (or keyboard activation). They must not
        // grant a second window after the first event already opened one,
        // even when the button was held for most of the activation window.
        if kind != "input", input, self.origin == origin, now >= time, now - time <= 5 {
            if kind == "menu" { menu = true }
            return
        }
        self.origin = origin
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

    mutating func clear() { self = PopupGesture() }

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
        return originKey(scheme: origin.protocol, host: origin.host, port: origin.port)
    }

    static func originKey(scheme: String, host: String, port: Int) -> String? {
        guard !scheme.isEmpty, !host.isEmpty else { return nil }
        return "\(scheme)://\(host):\(port)"
    }
}

/// Only the isolated Search world has this handler. Website code cannot
/// call it or replace its listener; dispatched events do not grant windows.
final class PopupGestureRelay: NSObject, WKScriptMessageHandler {
    static let name = "officePopupGesture"

    static let script = """
    (() => {
      const keys = new Set();
      function note(e) {
        if (!e.isTrusted) return;
        if (e.type === 'keydown' && (e.key === 'Escape' ||
            ['Shift', 'Control', 'Alt', 'Meta'].includes(e.key))) return;
        if (e.type === 'keydown') keys.add(e.code || e.key);
        if (e.repeat) return;
        // Enter can produce trusted clicks while held; those clicks have no
        // repeat flag. The initial keydown already supplied their one grant.
        if (e.type === 'click' && e.detail === 0 && keys.size) return;
        window.webkit.messageHandlers.officePopupGesture.postMessage(
          e.type === 'click' ? 'click' : e.type === 'contextmenu' ? 'menu' : 'input');
      }
      addEventListener('mousedown', note, true);
      addEventListener('keydown', note, true);
      addEventListener('click', note, true);
      addEventListener('contextmenu', note, true);
      addEventListener('keyup', e => { if (e.isTrusted) keys.delete(e.code || e.key); }, true);
      addEventListener('blur', e => { if (e.isTrusted && e.target === window) keys.clear(); }, true);
    })();
    """

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
