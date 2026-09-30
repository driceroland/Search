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

    mutating func record(origin: String, kind: String, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        // A click follows mousedown (or keyboard activation). It must not
        // grant a second window after the first event already opened one.
        if kind == "click", input, self.origin == origin, now - time < 1 { return }
        self.origin = origin
        time = now
        consumed = false
        input = kind == "input"
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
          e.type === 'click' ? 'click' : 'input');
      }
      addEventListener('mousedown', note, true);
      addEventListener('keydown', note, true);
      addEventListener('click', note, true);
    })();
    """

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let kind = message.body as? String, ["input", "click"].contains(kind) else { return }
        MainActor.assumeIsolated {
            guard let tab, message.webView === tab.built else { return }
            tab.popupGesture.record(origin: PopupGesture.origin(message.frameInfo), kind: kind)
        }
    }
}
