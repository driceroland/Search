import WebKit

/// Only a frame with a hand-edited field registers. WebKit supplies its identity;
/// the only thing Search asks that document for is whether it still holds a draft.
@MainActor
final class PageDrafts: NSObject, WKScriptMessageHandler {
    static let name = "officeDrafts"
    static let shared = PageDrafts()

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let web = message.webView as? PageView, message.body as? Bool == true else { return }
        web.draftFrames.append(message.frameInfo)
    }

    static func unsaved(in web: PageView?, _ done: @escaping (Bool) -> Void) {
        guard let web, !web.draftFrames.isEmpty else { return done(false) }
        let asked = DispatchGroup()
        for frame in web.draftFrames {
            asked.enter()
            web.evaluateJavaScript("!!globalThis.__officeDrafts?.()", in: frame, in: Web.world) { result in
                defer { asked.leave() }
                switch result {
                case .success(let answer):
                    guard answer as? Bool == false else { return }
                case .failure(let error as WKError):
                    guard [.javaScriptInvalidFrameTarget, .webContentProcessTerminated, .webViewInvalidated].contains(error.code) else { return }
                case .failure: return
                }
                web.draftFrames.removeAll { $0 === frame }
            }
        }
        // A frame first edited while the others answered counts too.
        asked.notify(queue: .main) { done(!web.draftFrames.isEmpty) }
    }

    static let script = """
    (() => {
      if (globalThis.__officeDrafts) return;
      const fields = new Set();
      let registered = false;
      function eligible(el) {
        return el instanceof HTMLTextAreaElement || el.isContentEditable ||
          (el instanceof HTMLInputElement && ['text','email','url','tel','number'].includes(el.type));
      }
      function register() {
        if (registered || !fields.size) return;
        registered = true;
        window.webkit.messageHandlers.officeDrafts.postMessage(true);
      }
      document.addEventListener('input', event => {
        const el = event.target;
        if (!event.isTrusted || !el || fields.has(el)) return;
        if (!eligible(el)) return;
        for (const old of fields) if (!old.isConnected) fields.delete(old);
        fields.add(el);
        register();
      }, true);
      globalThis.__officeDrafts = () => {
        for (const el of fields) {
          if (!el.isConnected || !eligible(el)) continue;
          if (el.isContentEditable ? el.textContent.trim() :
              el.value.trim() && el.value !== el.defaultValue) return true;
        }
        fields.clear();
        registered = false;
        return false;
      };
      window.addEventListener('pageshow', event => {
        if (event.persisted) { registered = false; register(); }
      });
    })();
    """
}
