import Combine
import ImageIO
import SwiftUI
import WebKit

// The small listeners a tab's page talks to: scrolling, middle clicks, sound.

/// Carries the page's scroll position back to its tab.
///
/// A content controller holds its handlers strongly, so this stands between the
/// two rather than the tab registering itself — otherwise a closed tab is kept
/// alive by the very page it was told to stop showing.
final class ScrollRelay: NSObject, WKScriptMessageHandler {
    static let name = "officeScroll"

    weak var tab: Tab?

    func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any] else { return }
        if let side = body["side"] as? String {
            MainActor.assumeIsolated { tab?.web.answer(free: side == "free") }
            return
        }
        guard let y = body["y"] as? Double,
              let ceiling = body["max"] as? Double
        else { return }
        let screens = body["screens"] as? Double
        MainActor.assumeIsolated { tab?.scrolled(to: y, of: ceiling, screens: screens) }
    }

    /// Reports at most once a frame, and passively, so a page that scrolls
    /// smoothly without us keeps scrolling smoothly with us.
    static let script = """
    (function () {
      var waiting = false;
      function tell() {
        var root = document.documentElement;
        var y = window.scrollY || root.scrollTop || 0;
        var ceiling = Math.max(1, (root.scrollHeight || 0) - window.innerHeight);
        var screens = (root.scrollHeight || 0) / Math.max(1, window.innerHeight);
        window.webkit.messageHandlers.\(name).postMessage({ y: y, max: ceiling, screens: screens });
      }
      window.addEventListener('scroll', function () {
        if (waiting) return;
        waiting = true;
        requestAnimationFrame(function () { waiting = false; tell(); });
      }, { passive: true });
      tell();
    })();
    """
}

/// Whether the page is making noise.
///
/// WebKit knows, but only says so through a name that isn't part of the public
/// framework — so it is asked whether it answers to that name at all before
/// anyone listens, and the tab simply goes without the indicator if it doesn't.
final class AudioWatch: NSObject {
    private static let key = "_isPlayingAudio"

    private weak var web: WKWebView?
    private var tell: ((Bool) -> Void)?

    func watch(_ web: WKWebView, _ tell: @escaping (Bool) -> Void) {
        guard web.responds(to: NSSelectorFromString(AudioWatch.key)) else { return }
        self.web = web
        self.tell = tell
        web.addObserver(self, forKeyPath: AudioWatch.key, options: [.new], context: nil)
    }

    func stop() {
        guard let web, tell != nil else { return }
        web.removeObserver(self, forKeyPath: AudioWatch.key)
        tell = nil
        self.web = nil
    }

    override func observeValue(
        forKeyPath path: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        guard path == AudioWatch.key else { return }
        let on = (change?[.newKey] as? Bool) ?? false
        DispatchQueue.main.async { self.tell?(on) }
    }

    deinit { stop() }
}

/// The middle button on a link, as the page reports it.
///
/// A middle-click on a link opens it beside the tab you are on, in every
/// other browser, and WebKit leaves that to the browser: it tells the page
/// about the click and hands this app no navigation action for it at all, the
/// way it does for ⌘-click (and where it does report a button, it answers
/// with a mask — 1 left, 2 right, 4 middle — so a check for the middle button
/// as 2 would catch the right one). The page can see the click, though, so
/// the page is asked: its own `auxclick` for the middle button names the link
/// under the pointer, and from there it is an ordinary address to open.
///
/// Only the main frame, only a real link to somewhere this browser
/// would go, and only the middle button. A page's own handler runs as it
/// always did — this says where to, and changes nothing about the click.
///
/// Two things are checked before anything is opened. The event has to carry a
/// real click: a synthesized `auxclick` is not one, so a page that dispatches
/// its own does not get a tab per dispatch. And it has to be unclaimed — a
/// click a page has called `preventDefault` on is a click it has dealt with,
/// which is why this listens as the event comes back up rather than on the
/// way down, where nothing has answered yet.
final class MiddleRelay: NSObject, WKScriptMessageHandler {
    static let name = "officeMiddle"

    weak var tab: Tab?

    static let watch = Scripts.load("tab-watch")

    func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        // A file page's link to another file (see watch): only from a file
        // page's main frame, only to a file, which then gets the folder it
        // would have had typed in, and no more (WKWebView.open).
        if let body = message.body as? [String: Any], let file = body["file"] as? String {
            guard message.frameInfo.isMainFrame,
                  message.frameInfo.securityOrigin.protocol == "file",
                  let url = URL(string: file), url.isFileURL
            else { return }
            let blank = body["blank"] as? Bool ?? false
            MainActor.assumeIsolated { [weak self] in
                guard let self, let tab, tab.address?.isFileURL == true else { return }
                tab.onFileLink?(tab, url, blank)
            }
            return
        }
        guard let body = message.body as? [String: Any],
              message.frameInfo.isMainFrame,
              let href = body["href"] as? String,
              let url = URL(string: href),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return }
        MainActor.assumeIsolated { [weak self] in
            guard let self, let tab else { return }
            tab.onMiddleClick?(tab, url)
        }
    }
}
