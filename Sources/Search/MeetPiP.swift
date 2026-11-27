import AppKit
import WebKit

// Google Meet's own little window, as Chrome shows it.
//
// In Chrome, a Meet call you step away from comes along in a small window
// in the corner of the screen: the call's tiles and Meet's own buttons —
// mute, camera, raise a hand, leave. That window is Chrome's Document
// Picture-in-Picture (documentPictureInPicture.requestWindow): a blank page
// of the call's own site, always on top, that Meet draws its controls into
// from the call's page. Chrome opens it by itself when you go to another tab
// during a call, by calling the handler Meet gave
// navigator.mediaSession.setActionHandler('enterpictureinpicture'), and
// closes it when you come back.
//
// WebKit has neither (WebKit/standards-positions#41), and Meet only offers
// the window to a browser that says it is Chrome 120 or later: it reads
// navigator.userAgent. So, only on meet.google.com and only with Settings ›
// Videos › "Google Meet's own mini window" on (on unless turned off):
//
// - in the page's own world, before Meet's scripts, navigator says Chrome,
//   documentPictureInPicture stands in as Chrome's does, and the
//   'enterpictureinpicture' handler Meet hands mediaSession is kept;
// - requestWindow is a window.open of a blank page of Meet's own, which
//   Search shows as a small panel floating in a corner of the screen instead
//   of a tab (see Browser's createWebViewWith and MeetPiPWindow below). The
//   page Meet gets back is the window's own, same origin, as Chrome's is;
// - going to another tab during a call calls Meet's handler with a gesture
//   of Search's, as Chrome does; coming back closes the window it opened.
//
// Nothing new is reachable: the panel's page is one the site could already
// open with a click (window.open), it can't go anywhere else, opens nothing,
// and gets no camera or microphone of its own. Page-world patches show their
// source, never hidden (see LiveRate.swift).

enum MeetPiP {
    /// Settings › Videos. On unless turned off.
    @MainActor static var on = false

    /// Where it applies: Meet only. A test run may add one host of its own.
    static let hosts: Set<String> = ["meet.google.com"]
    static let testHostKey = "meetPiP.testHost"

    @MainActor static func applies(_ url: URL?) -> Bool {
        guard on, let url, let host = url.hostCompat()?.lowercased() else { return false }
        if url.scheme == "https", hosts.contains(host) { return true }
        return Store.testing && host == Store.settings.string(forKey: testHostKey)
    }

    /// Smallest and largest the panel is made, in points.
    static let smallest = NSSize(width: 240, height: 180)
    static let largest = NSSize(width: 800, height: 800)

    /// In the page's own world, the main frame, before any of the page's
    /// scripts. Events to and from Search's world (`bridge`) carry nothing
    /// but sizes and words; the page can send them itself, and gains nothing
    /// it couldn't do with a click.
    static var page: String {
        """
        (function () {
          'use strict';
          if (window.top !== window || 'documentPictureInPicture' in window) return;
          var SAY = '__searchDocPiP:say', ENTER = '__searchDocPiP:enter';
          var dispatch = EventTarget.prototype.dispatchEvent, listen = EventTarget.prototype.addEventListener;
          var open = window.open, Custom = CustomEvent, stringify = JSON.stringify;
          function say(message) {
            try { dispatch.call(window, new Custom(SAY, { detail: stringify(message) })); } catch (e) {}
          }

          // Meet offers its window only to Chrome, which it tells by
          // navigator.userAgent. Here only: every other site sees Search.
          //
          // Except to Meet's camera effects (blur, backgrounds): the script
          // Meet loads for them from www.gstatic.com/video_effects reads the
          // user agent itself, and for Chrome 122 or later it runs its
          // pipeline in a worker fed by MediaStreamTrackProcessor and
          // MediaStreamTrackGenerator, which a WebKit page hasn't got: the
          // effect failed ("Can't find variable: MediaStreamTrackGenerator")
          // and Meet turned the camera off. Asked by that script, the answer
          // is Search's own, and it takes the way it takes in Safari.
          try {
            var ua = navigator.userAgent, av = navigator.appVersion;
            if (!/ Chrome\\//.test(ua)) {
              var chrome = ua.replace(/ Version\\/[\\d.]+.*$/, '').replace(/ Safari\\/[\\d.]+$/, '') +
                ' Chrome/\(Crx.chromeVersion) Safari/537.36';
              var version = chrome.replace(/^Mozilla\\//, '');
              var effects = /\\/\\/www\\.gstatic\\.com\\/video_effects\\/|\\/_\\/rtcvidproc\\//;
              var fromEffects = function () { try { return effects.test(String(new Error().stack || '')); } catch (e) { return false; } };
              Object.defineProperty(Navigator.prototype, 'userAgent', { get: function () { return fromEffects() ? ua : chrome; }, configurable: true, enumerable: true });
              Object.defineProperty(Navigator.prototype, 'appVersion', { get: function () { return fromEffects() ? av : version; }, configurable: true, enumerable: true });
            }
          } catch (e) {}

          var current = null, handler = null, constructing = false;

          function DocumentPictureInPictureEvent(type, init) {
            if (!(this instanceof DocumentPictureInPictureEvent)) throw new TypeError("Constructor requires 'new'");
            var event = new Event(type, init);
            var win = init && init.window || null;
            Object.setPrototypeOf(event, DocumentPictureInPictureEvent.prototype);
            Object.defineProperty(event, 'window', { get: function () { return win; }, enumerable: true, configurable: true });
            return event;
          }
          DocumentPictureInPictureEvent.prototype = Object.create(Event.prototype, {
            constructor: { value: DocumentPictureInPictureEvent, writable: true, configurable: true }
          });

          class DocumentPictureInPicture extends EventTarget {
            #onenter = null;
            constructor() {
              if (!constructing) throw new TypeError('Illegal constructor');
              super();
            }
            get window() { return current && !current.closed ? current : null; }
            get onenter() { return this.#onenter; }
            set onenter(f) {
              if (this.#onenter) this.removeEventListener('enter', this.#onenter);
              this.#onenter = typeof f === 'function' ? f : null;
              if (this.#onenter) this.addEventListener('enter', this.#onenter);
            }
            requestWindow(options) {
              try { return Promise.resolve(request(this, options || {})); }
              catch (e) { return Promise.reject(e); }
            }
          }
          constructing = true;
          var pip = new DocumentPictureInPicture();
          constructing = false;

          function request(target, o) {
            var hasW = o.width !== undefined && o.width !== 0, hasH = o.height !== undefined && o.height !== 0;
            if (hasW !== hasH) throw new RangeError('requestWindow: width and height must be given together');
            var width = Math.round(+o.width || 400), height = Math.round(+o.height || 300);
            if (!(width > 0 && height > 0)) throw new RangeError('requestWindow: a size must be positive');
            // One window a page: a second request closes the first.
            if (current && !current.closed) { try { current.close(); } catch (e) {} }
            current = null;
            say({ kind: 'ask', width: width, height: height });
            // Search turns this window into the floating panel. Refused —
            // no click, or Search's switch off — it is null.
            var w = open.call(window, '', '_blank', 'popup,width=' + width + ',height=' + height);
            if (!w) throw new DOMException('Document Picture-in-Picture requires user activation', 'NotAllowedError');
            var d = w.document;
            if (!d.documentElement) d.appendChild(d.createElement('html'));
            if (!d.head) d.documentElement.appendChild(d.createElement('head'));
            if (!d.body) d.documentElement.appendChild(d.createElement('body'));
            current = w;
            // Chrome closes the window when its page goes; and tells the
            // page by pagehide, which a closed window here may not fire.
            var hid = false;
            listen.call(w, 'pagehide', function () { hid = true; if (current === w) current = null; });
            var watch = setInterval(function () {
              if (!w.closed) return;
              clearInterval(watch);
              if (current === w) current = null;
              if (!hid) { hid = true; try { dispatch.call(w, new PageTransitionEvent('pagehide', { persisted: false })); } catch (e) {} }
            }, 250);
            dispatch.call(target, new DocumentPictureInPictureEvent('enter', { window: w }));
            return w;
          }

          listen.call(window, 'pagehide', function () { if (current && !current.closed) current.close(); });

          try {
            Object.defineProperty(window, 'documentPictureInPicture', { get: function () { return pip; }, enumerable: true, configurable: true });
            window.DocumentPictureInPicture = DocumentPictureInPicture;
            window.DocumentPictureInPictureEvent = DocumentPictureInPictureEvent;
          } catch (e) {}

          // The handler Chrome calls when you go to another tab during a
          // call. WebKit refuses the action's name; it is kept here instead.
          try {
            var proto = window.MediaSession && MediaSession.prototype;
            var set = proto && proto.setActionHandler;
            if (set) {
              Object.defineProperty(proto, 'setActionHandler', {
                value: function setActionHandler(action, h) {
                  if (action === 'enterpictureinpicture') {
                    handler = typeof h === 'function' ? h : null;
                    say({ kind: handler ? 'armed' : 'disarmed' });
                    return;
                  }
                  return set.apply(this, arguments);
                }, writable: true, configurable: true
              });
            }
          } catch (e) {}
          // Meet opens its window by itself ('contentoccluded') only when a
          // setting of its own allows it; asked as a person asks Chrome's own
          // button ('useraction'), it opens it.
          listen.call(window, ENTER, function () {
            if (!handler || (current && !current.closed)) return;
            try {
              var r = handler({ action: 'enterpictureinpicture', enterPictureInPictureReason: 'useraction' });
              if (r && typeof r.then === 'function') r.then(null, function () {});
            } catch (e) {}
          });

          // Meet, as Chrome, tells the browser whether its camera and
          // microphone are on (setCameraActive / setMicrophoneActive); Chrome
          // only shows it. WebKit acts on it — mutes the capture, and won't
          // turn it back on without a click — so Meet's own camera and
          // microphone buttons turned each other off. Here they are what
          // they are in Chrome: noted, nothing done.
          try {
            ['setCameraActive', 'setMicrophoneActive'].forEach(function (name) {
              var mp = window.MediaSession && MediaSession.prototype;
              if (!mp || typeof mp[name] !== 'function') return;
              Object.defineProperty(mp, name, {
                value: function () { return Promise.resolve(); }, writable: true, configurable: true
              });
            });
          } catch (e) {}
        })();
        """
    }

    /// In Search's world, the main frame: the page's words passed on to
    /// Search (MeetPiPRelay).
    static let bridge = """
    (function () {
      var h = window.webkit && webkit.messageHandlers && webkit.messageHandlers.\(MeetPiPRelay.name);
      if (!h || window.__meetPiPBridged) return;
      window.__meetPiPBridged = true;
      h.postMessage({ kind: 'fresh' });
      window.addEventListener('__searchDocPiP:say', function (e) {
        var m;
        try { m = JSON.parse(e.detail); } catch (x) { return; }
        if (!m || typeof m.kind !== 'string') return;
        h.postMessage({ kind: m.kind.slice(0, 400), width: +m.width || 0, height: +m.height || 0 });
      });
    })();
    """

    /// Run in Search's world on the call's page: Meet's handler, as Chrome
    /// calls it on a tab switch.
    static let enter = "window.dispatchEvent(new CustomEvent('__searchDocPiP:enter')); 1"

    /// The panel WebKit's new window becomes, when the call's page asked for
    /// it just now (requestWindow). nil: an ordinary window.open, left to
    /// the usual paths.
    @MainActor static func take(
        for opener: Tab, from webView: WKWebView, action: WKNavigationAction,
        features: WKWindowFeatures, configuration: WKWebViewConfiguration, browser: Browser
    ) -> WKWebView? {
        let now = ProcessInfo.processInfo.systemUptime
        guard on, action.sourceFrame.isMainFrame, applies(webView.url),
              let asked = opener.meetPiPAsk, now - asked.at < 2
        else { return nil }
        let target = action.request.url?.absoluteString ?? ""
        guard target.isEmpty || target == "about:blank" else { return nil }
        // A click on the page, as for any window; or Search's own tab
        // switch, which is good for this window only and only once — never
        // for a pop-up of another kind.
        let switched = opener.meetPiPAuto.map { now - $0 < 3 } ?? false
        opener.meetPiPAuto = nil
        guard switched || opener.popupGesture.take(origin: PopupGesture.origin(action.sourceFrame), mainFrame: true) else { return nil }
        opener.meetPiPAsk = nil
        let auto = switched
        MeetPiPWindow.all.filter { $0.openerID == opener.id }.forEach { $0.close() }
        let size = NSSize(width: features.width?.doubleValue ?? asked.width,
                          height: features.height?.doubleValue ?? asked.height)
        let window = MeetPiPWindow(opener: opener, browser: browser, configuration: configuration,
                                   size: size, host: webView.url?.hostCompat() ?? "", auto: auto)
        return window.web
    }

    /// The tab in front changed: a call left gets Meet's window, as in
    /// Chrome; the call come back to loses the one that opened by itself.
    @MainActor static func switched(from left: Tab?, to now: Tab?) {
        if let now {
            MeetPiPWindow.all.filter { $0.openerID == now.id && $0.auto }.forEach { $0.close() }
        }
        guard on, let left, left.meetPiPArmed, let web = left.built, applies(web.url),
              StageView.onCall(web),
              !MeetPiPWindow.all.contains(where: { $0.openerID == left.id })
        else { return }
        // Chrome's switch is the gesture its handler opens the window with:
        // here, a grant for Meet's window alone (see take).
        left.meetPiPAuto = ProcessInfo.processInfo.systemUptime
        web.evaluateInSearch(enter)
    }
}

/// The page's words, from MeetPiP.bridge in Search's world.
final class MeetPiPRelay: NSObject, WKScriptMessageHandler {
    static let name = "officeMeetPiP"
    weak var tab: Tab?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any],
              let kind = body["kind"] as? String else { return }
        let width = (body["width"] as? Double) ?? 0, height = (body["height"] as? Double) ?? 0
        MainActor.assumeIsolated {
            guard let tab, let web = message.webView, web === tab.built else { return }
            switch kind {
            case "fresh":
                tab.meetPiPArmed = false
                tab.meetPiPAsk = nil
            case "armed", "disarmed":
                tab.meetPiPArmed = kind == "armed" && MeetPiP.applies(web.url)
            case "ask":
                guard MeetPiP.applies(web.url), width > 0, height > 0 else { return }
                tab.meetPiPAsk = (ProcessInfo.processInfo.systemUptime, width, height)
            default: break
            }
        }
    }
}

/// Meet's window: its blank page, in a small panel over every app, in a
/// corner of the screen. Its page can't go anywhere, open anything or use
/// the camera; it closes with its call's tab, and when its page closes it.
@MainActor
final class MeetPiPWindow: NSObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    private(set) static var all: [MeetPiPWindow] = []

    let openerID: UUID
    let web: WKWebView
    let panel: NSPanel
    /// Opened by Search on a tab switch, so closed when you come back.
    let auto: Bool
    let host: String
    private weak var browser: Browser?
    private var closing = false

    /// Never on screen in a test run: made, filled and driven, not shown.
    static var shows: Bool { !Store.testing }

    init(opener: Tab, browser: Browser, configuration: WKWebViewConfiguration, size: NSSize, host: String, auto: Bool) {
        openerID = opener.id
        self.auto = auto
        self.host = host
        self.browser = browser
        // None of the opener's scripts or handlers: a page of the site's own
        // to draw into, nothing of Search's in it.
        configuration.userContentController = WKUserContentController()
        web = WKWebView(frame: .zero, configuration: configuration)
        let screen = (browser.window?.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let fitted = Self.fit(size, in: screen)
        let place = NSRect(x: screen.maxX - fitted.width - 20, y: screen.minY + 20, width: fitted.width, height: fitted.height)
        panel = NSPanel(contentRect: place, styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        super.init()
        panel.title = host
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.minSize = Self.smallestFrame
        panel.delegate = self
        web.navigationDelegate = self
        web.uiDelegate = self
        web.autoresizingMask = [.width, .height]
        web.frame = panel.contentView?.bounds ?? .zero
        panel.contentView?.addSubview(web)
        Self.all.append(self)
        if Self.shows { panel.orderFront(nil) }
    }

    private static var smallestFrame: NSSize { MeetPiP.smallest }

    static func fit(_ size: NSSize, in screen: NSRect) -> NSSize {
        let most = NSSize(width: min(MeetPiP.largest.width, screen.width / 2), height: min(MeetPiP.largest.height, screen.height * 0.7))
        return NSSize(width: min(max(size.width, MeetPiP.smallest.width), most.width),
                      height: min(max(size.height, MeetPiP.smallest.height), most.height))
    }

    /// Closes its page — which tells the call's page by pagehide — and goes.
    func close() {
        guard !closing else { return }
        closing = true
        Self.all.removeAll { $0 === self }
        panel.delegate = nil
        panel.orderOut(nil)
        panel.close()
        web.navigationDelegate = nil
        web.uiDelegate = nil
        web.removeFromSuperview()
        // As a tab's view is let go: its page closed now, its window.closed
        // true for the call's page, rather than whenever the view is freed.
        let close = NSSelectorFromString("_close")
        if web.responds(to: close) { web.perform(close) }
    }

    func windowWillClose(_ notification: Notification) { close() }

    func webViewDidClose(_ webView: WKWebView) { close() }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        // Its own blank page only, and the frames the site puts in it.
        guard action.targetFrame?.isMainFrame ?? true else { return decisionHandler(.allow) }
        let target = action.request.url?.absoluteString ?? ""
        decisionHandler(target.isEmpty || target == "about:blank" ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType, decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) {
        decisionHandler(.deny)
    }

    /// outerWidth and the rest, as for a tab (see Browser's).
    @objc(_webView:getWindowFrameWithCompletionHandler:)
    func webView(_ webView: WKWebView, getWindowFrameWithCompletionHandler done: @escaping (CGRect) -> Void) {
        done(panel.frame)
    }

    /// resizeTo: Meet sizes its window to the layout it draws. Kept in its
    /// corner, at most the size requestWindow could ask for.
    @objc(_webView:setWindowFrame:)
    func webView(_ webView: WKWebView, setWindowFrame frame: CGRect) {
        let screen = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? panel.frame
        let size = Self.fit(frame.size, in: screen)
        let old = panel.frame
        panel.setFrame(NSRect(x: old.maxX - size.width, y: old.minY, width: size.width, height: size.height), display: Self.shows)
    }

    /// What the bench reports.
    var state: [String: Any] {
        ["opener": openerID.uuidString, "auto": auto, "host": host, "shown": panel.isVisible,
         "level": panel.level.rawValue, "frame": [panel.frame.minX, panel.frame.minY, panel.frame.width, panel.frame.height],
         "url": web.url?.absoluteString ?? ""]
    }
}
