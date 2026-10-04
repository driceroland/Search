import WebKit

/// One new browsing context for a recent real interaction. WebKit's form
/// submission path still uses its synchronous gesture indicator; after a
/// fetch, a POST to _blank can be refused even while userActivation is active.
/// Search keeps the short-lived permission outside the page instead.
struct PopupGesture {
    private var origin: String?
    private var time: TimeInterval = 0
    private var consumed = false
    private var input = false
    private var menu = false

    mutating func record(origin: String, kind: String, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        // Click and contextmenu follow mousedown (or keyboard activation). They must not
        // grant a second window after the first event already opened one.
        if kind != "input", input, self.origin == origin, now - time < 1 {
            if kind == "menu" { menu = true }
            return
        }
        self.origin = origin
        time = now
        consumed = false
        input = kind != "click"
        menu = kind == "menu"
    }

    mutating func take(origin: String, mainFrame: Bool = false, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        // Activation in an iframe also activates its top-level document.
        // It does not activate an unrelated third-party sibling frame.
        guard self.origin != nil, (self.origin == origin || mainFrame),
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
        guard origin != nil, !consumed, now >= time else { return }
        time = now
    }

    static func origin(_ info: WKFrameInfo) -> String {
        let origin = info.securityOrigin
        return "\(origin.protocol)://\(origin.host):\(origin.port)"
    }
}

/// Only the isolated Search world has this handler. Website code cannot
/// call it or replace its listener; dispatched events do not grant windows.
final class PopupGestureRelay: NSObject, WKScriptMessageHandler {
    static let name = "officePopupGesture"
    weak var tab: Tab?

    static let script = """
    (() => {
      function note(e) {
        if (!e.isTrusted) return;
        if (e.type === 'keydown' && (e.key === 'Escape' ||
            ['Shift', 'Control', 'Alt', 'Meta'].includes(e.key))) return;
        window.webkit.messageHandlers.officePopupGesture.postMessage(
          e.type === 'click' ? 'click' : e.type === 'contextmenu' ? 'menu' : 'input');
      }
      addEventListener('mousedown', note, true);
      addEventListener('keydown', note, true);
      addEventListener('click', note, true);
      addEventListener('contextmenu', note, true);
    })();
    """

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let kind = message.body as? String, ["input", "click", "menu"].contains(kind) else { return }
        MainActor.assumeIsolated {
            guard let tab, message.webView === tab.built else { return }
            tab.popupGesture.record(origin: PopupGesture.origin(message.frameInfo), kind: kind)
        }
    }
}
