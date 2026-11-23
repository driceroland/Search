import AppKit
import Combine
import WebKit

// A page's full screen in the browser window itself:
// Settings › Video › Full screen in the window. Off unless asked for.
//
// WebKit's own full screen lends the page to a window of WebKit's, which it
// always takes into a Space of its own (WKFullScreenWindowController), and
// the browser window stays behind on its desktop. Nothing in WebKit's API
// changes that. So with the switch on, the page's Fullscreen API is answered
// here instead: the element is laid over the page where it is, the window's
// chrome steps aside as it does for WebKit's (Tab.immersed), and the window
// goes into macOS full screen, unless it is there already, when nothing new
// is made at all. Leaving puts it back as it was: out of full screen only if
// it was this that took it there.
//
// The page's side stands in the page's own world, ahead of its scripts, in
// every frame: requestFullscreen and the rest are the page's functions. A
// frame's request is carried up frame by frame with postMessage, each
// parent laying the frame over itself, until the top one asks Search through
// a bridge in Search's world. That bridge is where a request without a click
// behind it is refused, since a page could otherwise ask by sending the
// bridge's event itself.

@MainActor
final class WindowFullScreen {
    static let shared = WindowFullScreen()

    /// The events the page's world and Search's say this on.
    nonisolated static let ask = "__searchFillsWindow"
    nonisolated static let leave = "__searchLeavesWindow"
    nonisolated static let off = "__searchFillsWindowOff"

    /// The switch changed with pages up: those take it now, rather than at
    /// their next load. A page's main frame, that is; a frame already in it
    /// (an embedded player) follows once the page is loaded again.
    func setting(_ on: Bool, for tabs: [Tab]) {
        for tab in tabs {
            guard let web = tab.built else { continue }
            if on {
                web.evaluateInSearch(Self.bridge)
                web.evaluateJavaScript(Self.page, in: nil, in: .page) { _ in }
            } else {
                end(web)
                web.evaluateInSearch("window.dispatchEvent(new CustomEvent('\(Self.off)')); void 0")
            }
        }
    }

    /// A page filling its window: the tab, its window, and whether it was this
    /// that took the window into full screen.
    private struct Filling {
        weak var tab: Tab?
        weak var window: NSWindow?
        var took: Bool
        var immersion: AnyCancellable?
    }

    private var filling: [ObjectIdentifier: Filling] = [:]
    /// Windows asked to leave full screen while still on their way in, which
    /// AppKit ignores: they go once they have arrived.
    private var leaveOnArrival = Set<ObjectIdentifier>()
    private var watches: [NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        // The window leaving full screen by itself (the green button, ⌃⌘F, a
        // swipe out) takes its page out too.
        watches.append(center.addObserver(forName: NSWindow.willExitFullScreenNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                guard let window = note.object as? NSWindow else { return }
                WindowFullScreen.shared.windowLeaving(window)
            }
        })
        watches.append(center.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                guard let window = note.object as? NSWindow else { return }
                WindowFullScreen.shared.arrived(window)
            }
        })
    }

    /// The page in this web view fills its window this way.
    func fills(_ web: WKWebView?) -> Bool {
        guard let web else { return false }
        return filling[ObjectIdentifier(web)] != nil
    }

    /// The top frame's word, through the bridge: its page has gone into full
    /// screen, or come out.
    func page(_ tab: Tab, fills on: Bool) {
        guard let web = tab.built else { return }
        let key = ObjectIdentifier(web)
        guard on else { return finish(key) }
        guard filling[key] == nil else { return }
        // Only a page on show: one behind another tab has nowhere to fill.
        guard let browser = Browsers.all.first(where: { $0.tabs.contains { $0 === tab } }),
              let window = browser.window, shown(tab, in: browser) else {
            return Self.endPage(web)
        }
        let took = !isFull(window)
        filling[key] = Filling(tab: tab, window: window, took: took, immersion: tab.immersion.sink { on in
            // The chrome back some other way (the tab sent elsewhere, woken,
            // or put to sleep): the window goes back with it.
            MainActor.assumeIsolated { if !on { WindowFullScreen.shared.end(web) } }
        })
        if !tab.immersed { tab.immersed = true }
        if took { toggle(window) }
    }

    /// Full screen ended from Search's side: Esc, a key that goes to another
    /// tab, another tab shown. The page is told, and the window put back at
    /// once rather than waiting to hear from a page that may be gone.
    func end(_ web: WKWebView) {
        let key = ObjectIdentifier(web)
        guard filling[key] != nil else { return }
        Self.endPage(web)
        finish(key)
    }

    private func finish(_ key: ObjectIdentifier) {
        guard let entry = filling.removeValue(forKey: key) else { return }
        if let tab = entry.tab, tab.immersed { tab.immersed = false }
        guard entry.took, let window = entry.window else { return }
        // Another page of the same window still filling it keeps it there.
        guard !filling.values.contains(where: { $0.window === window }) else { return }
        if isFull(window), !leaveOnArrival.contains(ObjectIdentifier(window)) {
            toggle(window)
        } else {
            leaveOnArrival.insert(ObjectIdentifier(window))
        }
    }

    private func arrived(_ window: NSWindow) {
        guard leaveOnArrival.remove(ObjectIdentifier(window)) != nil else { return }
        toggle(window)
    }

    private func windowLeaving(_ window: NSWindow) {
        leaveOnArrival.remove(ObjectIdentifier(window))
        for (key, entry) in filling where entry.window === window {
            // Out already: nothing to toggle back.
            filling[key]?.took = false
            if let web = entry.tab?.built { Self.endPage(web) }
            finish(key)
        }
    }

    // MARK: - test runs

    /// A test run's macOS full screen, only pretended: a hidden probe never
    /// takes its window into a Space (Tests/fullscreen_in_window.py). Nil
    /// outside one, where the window's own is the answer.
    private var pretended: Bool?
    /// How many times the window was asked into or out of full screen.
    private(set) var toggles = 0

    func pretend(_ full: Bool) {
        pretended = full
        toggles = 0
    }

    private func isFull(_ window: NSWindow) -> Bool {
        pretended ?? window.styleMask.contains(.fullScreen)
    }

    private func toggle(_ window: NSWindow) {
        toggles += 1
        if let pretended { self.pretended = !pretended } else { window.toggleFullScreen(nil) }
    }

    /// For the bench: which of this window's tabs fill it, and its full screen.
    func state(of browser: Browser) -> [String: Any] {
        let tabs = browser.tabs.filter { fills($0.built) }.map(Bench.short)
        let full = browser.window.map(isFull) ?? false
        return ["filling": tabs, "windowFull": full, "toggles": toggles,
                "immersed": browser.tabs.filter(\.immersed).map(Bench.short)]
    }

    private func shown(_ tab: Tab, in browser: Browser) -> Bool {
        if browser.active === tab { return true }
        guard browser.prefs.splitView, let split = browser.activeSplit else { return false }
        return split.contains(tab.id)
    }

    /// The page told to leave, in every frame that is part of it. WebKit's
    /// own full screen too, should it have one: the script that answers in
    /// the page's world may not be in this document yet.
    static func endPage(_ web: WKWebView) {
        web.evaluateInSearch("""
            if (document.fullscreenElement) document.exitFullscreen();
            window.dispatchEvent(new CustomEvent('\(leave)'));
            void 0
            """)
    }

    /// In Search's world, the top frame only: the page's request, passed on.
    /// Going in needs a click or a key behind it, as the Fullscreen API's
    /// own does; coming out never does.
    static let bridge = """
    (function () {
      var handler = window.webkit && webkit.messageHandlers && webkit.messageHandlers.\(FormRelay.name);
      if (!handler || window.__searchFillsBridge) return;
      window.__searchFillsBridge = true;
      window.addEventListener('\(ask)', function (event) {
        var on = event.detail === 'on';
        if (on && navigator.userActivation && !navigator.userActivation.isActive) return;
        handler.postMessage({ kind: 'fillsWindow', on: on });
      });
    })();
    """

    /// In the page's own world, every frame, before the page's scripts.
    nonisolated static let page = """
    (function () {
      if (window.__searchFills) return;
      Object.defineProperty(window, '__searchFills', { value: true, configurable: true });
      var ASK = '\(ask)', LEAVE = '\(leave)', OFF = '\(off)', NOTE = '__searchFullScreen';
      var FILLS = 'data-search-fullscreen', ABOVE = 'data-search-fullscreen-ancestor',
          ROOT = 'data-search-fullscreen-document';
      var isTop = window === window.top;
      var EP = Element.prototype, DP = Document.prototype;
      var plain = {
        enabled: Object.getOwnPropertyDescriptor(DP, 'fullscreenEnabled')
          || Object.getOwnPropertyDescriptor(DP, 'webkitFullscreenEnabled')
      };
      var current = null, lifted = [], kept = new Map(), watcher = null, sheet = null;

      // The element over everything, as the spec's own style for :fullscreen
      // has it; and everything it is inside of made unable to hold it back,
      // as WebKit's style for full-screen ancestors did before the top layer.
      var mine = {
        position: 'fixed', inset: '0', margin: '0', 'box-sizing': 'border-box',
        'min-width': '0', 'max-width': 'none', 'min-height': '0', 'max-height': 'none',
        width: '100%', height: '100%', transform: 'none', 'object-fit': 'contain',
        'z-index': '2147483647', visibility: 'visible'
      };
      var framed = { border: '0', padding: '0' };
      var ancestor = {
        'z-index': 'auto', position: 'static', opacity: '1', transform: 'none', mask: 'none',
        clip: 'none', filter: 'none', transition: 'none', overflow: 'visible', contain: 'none',
        'will-change': 'auto', 'clip-path': 'none', 'backdrop-filter': 'none', visibility: 'visible'
      };

      function set(el, styles) {
        var before = kept.get(el) || { '': el.hasAttribute('style') };
        for (var name in styles) {
          if (!(name in before)) {
            before[name] = [el.style.getPropertyValue(name), el.style.getPropertyPriority(name)];
          }
          el.style.setProperty(name, styles[name], 'important');
        }
        kept.set(el, before);
      }
      function restore() {
        kept.forEach(function (before, el) {
          for (var name in before) {
            if (!name) continue;
            if (before[name][0]) el.style.setProperty(name, before[name][0], before[name][1]);
            else el.style.removeProperty(name);
          }
          if (!before[''] && !el.getAttribute('style')) el.removeAttribute('style');
          el.removeAttribute(FILLS);
          el.removeAttribute(ABOVE);
        });
        kept.clear();
        lifted = [];
        document.documentElement && document.documentElement.removeAttribute(ROOT);
      }

      // The rest of the page out of sight behind it, and black, as the
      // backdrop of a real full screen is.
      function style() {
        if (sheet && sheet.isConnected) return;
        sheet = document.createElement('style');
        sheet.textContent =
          'html[' + ROOT + '] { background: #000 !important; overflow: hidden !important; }' +
          'html[' + ROOT + '] body *:not([' + FILLS + ']):not([' + ABOVE + ']):not([' + FILLS + '] *)' +
          ' { visibility: hidden !important; }' +
          'video[' + FILLS + '] { background-color: #000 !important; }';
        // YouTube can measure its controls while moving the player between
        // containers and leave them 100px wide until the viewport resizes.
        if (location.hostname === 'youtube.com' || location.hostname.endsWith('.youtube.com')) {
          sheet.textContent += 'html[' + ROOT + '] #movie_player.ytp-fullscreen .ytp-chrome-bottom' +
            '[style*="width: 100px;"][style*="left: 12px;"] { width: auto !important; right: 12px !important; }';
        }
        (document.head || document.documentElement).appendChild(sheet);
      }

      function up(el) {
        if (el.parentElement) return el.parentElement;
        var root = el.getRootNode && el.getRootNode();
        return root && root.host ? root.host : null;
      }

      function lay(el) {
        style();
        document.documentElement.setAttribute(ROOT, '');
        el.setAttribute(FILLS, '');
        set(el, mine);
        if (el.localName === 'iframe') set(el, framed);
        for (var at = up(el); at; at = up(at)) {
          at.setAttribute(ABOVE, '');
          set(at, at === document.documentElement ? { overflow: 'hidden' } : ancestor);
          lifted.push(at);
        }
        watcher = new MutationObserver(function () { if (current && !current.isConnected) leave(true); });
        watcher.observe(document, { childList: true, subtree: true });
      }

      function fire(el) {
        var target = el && el.isConnected ? el : document;
        ['fullscreenchange', 'webkitfullscreenchange'].forEach(function (type) {
          target.dispatchEvent(new Event(type, { bubbles: true, composed: true }));
        });
      }
      function refuse(el) {
        var target = el && el.isConnected ? el : document;
        ['fullscreenerror', 'webkitfullscreenerror'].forEach(function (type) {
          target.dispatchEvent(new Event(type, { bubbles: true, composed: true }));
        });
      }
      // After the page has been laid out at its new size, as a real full
      // screen's events come: the next frame, or a moment, whichever is
      // first, since a page out of sight draws no frames.
      // A resize after the change, and again once the window has settled:
      // in a real full screen the viewport changes after the page hears of
      // it, and players measure themselves on that. Here the window can be
      // at its new size already, and YouTube, which lays its player out
      // again on fullscreenchange at a moment its player measures nothing,
      // kept its controls at their 100px least, waiting for a resize that
      // never came.
      function settle() {
        var nudge = function () { window.dispatchEvent(new Event('resize')); };
        requestAnimationFrame(nudge);
        setTimeout(nudge, 750);
      }
      function later(fn) {
        var done = false;
        function once() { if (!done) { done = true; fn(); } }
        requestAnimationFrame(function () { setTimeout(once, 0); });
        setTimeout(once, 100);
      }

      function tell(on) {
        if (isTop) window.dispatchEvent(new CustomEvent(ASK, { detail: on ? 'on' : 'off' }));
        else window.parent.postMessage({ [NOTE]: on ? 'up' : 'down' }, '*');
      }

      function enter(el) {
        if (current === el) return;
        if (current) quiet();
        current = el;
        lay(el);
        // The page hears of it first, and only then is the room made: the
        // window's chrome stepping aside, the window going full screen, a
        // frame laid over its parent. In a real full screen too the viewport
        // grows after fullscreenchange, and players measure themselves
        // again on that. Told the other way round, the room was already
        // there when the change came: YouTube in a window already full
        // screen laid its player out at that moment, measured nothing, and
        // its controls stayed at their 100px least, with no resize to come.
        later(function () {
          if (current !== el) return;
          fire(el);
          later(function () { if (current === el) tell(true); });
          settle();
        });
      }

      // Out, with nothing said: on the way to another element.
      function quiet() {
        var el = current;
        current = null;
        if (watcher) { watcher.disconnect(); watcher = null; }
        restore();
        if (el && el.localName === 'iframe' && el.contentWindow) {
          el.contentWindow.postMessage({ [NOTE]: 'leave' }, '*');
        }
        return el;
      }

      function leave(upward) {
        if (!current) return;
        var el = quiet();
        if (upward) tell(false);
        later(function () { fire(el); settle(); });
      }

      function allowed() {
        var enabled = plain.enabled && plain.enabled.get ? plain.enabled.get.call(document) : true;
        var activation = navigator.userActivation;
        return enabled && (!activation || activation.isActive);
      }

      function request() {
        var el = this;
        if (!(el instanceof Element) || !el.isConnected || el.ownerDocument !== document || !allowed()) {
          later(function () { refuse(el); });
          return Promise.reject(new TypeError('Full screen is not allowed here.'));
        }
        enter(el);
        return new Promise(function (resolve) { later(resolve); });
      }
      function exit() {
        if (!current) return Promise.reject(new TypeError('Not in full screen.'));
        leave(true);
        return new Promise(function (resolve) { later(resolve); });
      }
      function legacy(fn) { return function () { fn.apply(this, arguments).catch(function () {}); }; }

      // The element as this document or shadow root sees it: one inside a
      // shadow tree is its host from outside.
      function seen(root) {
        for (var el = current; el; ) {
          var at = el.getRootNode();
          if (at === root) return el;
          if (!at.host) return null;
          el = at.host;
        }
        return null;
      }
      // What each patch replaced, to put back when the switch goes off.
      var undo = [];
      function getter(proto, name, fn) {
        var was = Object.getOwnPropertyDescriptor(proto, name);
        if (was && !was.configurable) return;
        undo.push([proto, name, was]);
        Object.defineProperty(proto, name, {
          get: fn, enumerable: was ? was.enumerable : true, configurable: true
        });
      }
      function method(proto, name, fn) {
        var was = Object.getOwnPropertyDescriptor(proto, name);
        if (!was || !was.configurable) return;
        undo.push([proto, name, was]);
        Object.defineProperty(proto, name, {
          value: fn, writable: true, enumerable: was.enumerable, configurable: true
        });
      }

      method(EP, 'requestFullscreen', request);
      method(EP, 'webkitRequestFullscreen', legacy(request));
      method(EP, 'webkitRequestFullScreen', legacy(request));
      method(DP, 'exitFullscreen', exit);
      method(DP, 'webkitExitFullscreen', legacy(exit));
      method(DP, 'webkitCancelFullScreen', legacy(exit));
      ['fullscreenElement', 'webkitFullscreenElement', 'webkitCurrentFullScreenElement'].forEach(function (name) {
        getter(DP, name, function () { return this === document ? seen(document) : null; });
        if (window.ShadowRoot) getter(ShadowRoot.prototype, name, function () { return seen(this); });
      });
      ['fullscreen', 'webkitIsFullScreen'].forEach(function (name) {
        getter(DP, name, function () { return this === document && !!current; });
      });

      // Safari's own video full screen, which some players use in its place.
      if (window.HTMLVideoElement) {
        var VP = HTMLVideoElement.prototype;
        var enterVideo = function () { legacy(request).call(this); };
        var exitVideo = function () { if (current === this) leave(true); };
        method(VP, 'webkitEnterFullscreen', enterVideo);
        method(VP, 'webkitEnterFullScreen', enterVideo);
        method(VP, 'webkitExitFullscreen', exitVideo);
        method(VP, 'webkitExitFullScreen', exitVideo);
        getter(VP, 'webkitDisplayingFullscreen', function () { return current === this; });
        var mode = Object.getOwnPropertyDescriptor(VP, 'webkitPresentationMode');
        var setMode = Object.getOwnPropertyDescriptor(VP, 'webkitSetPresentationMode');
        if (mode && mode.get && setMode && setMode.value) {
          getter(VP, 'webkitPresentationMode', function () {
            return current === this ? 'fullscreen' : mode.get.call(this);
          });
          method(VP, 'webkitSetPresentationMode', function (to) {
            if (to === 'fullscreen') return enterVideo.call(this);
            if (current === this) leave(true);
            if (to !== 'inline') return setMode.value.call(this, to);
          });
        }
      }

      // A frame's full screen, carried up: the frame laid over this page.
      // Down: this frame's own, ended from above.
      function heard(event) {
        var data = event.data, note = data && typeof data === 'object' ? data[NOTE] : null;
        if (!note) return;
        event.stopImmediatePropagation();
        if (note === 'off') {
          if (event.source === window.parent) off();
          return;
        }
        if (note === 'leave') {
          if (event.source === window.parent && current) leave(false);
          return;
        }
        var frame = Array.prototype.find.call(document.querySelectorAll('iframe, frame'), function (f) {
          return f.contentWindow === event.source;
        });
        if (!frame) return;
        if (note === 'up') {
          if (navigator.userActivation && !navigator.userActivation.isActive) {
            event.source.postMessage({ [NOTE]: 'leave' }, '*');
            return;
          }
          enter(frame);
        } else if (note === 'down' && current === frame) {
          leave(true);
        }
      }
      window.addEventListener('message', heard, true);

      // Search ending it: Esc, another tab, the window leaving full screen.
      function ended() { leave(false); }
      function hidden() { if (current) leave(true); }
      if (isTop) window.addEventListener(LEAVE, ended);
      window.addEventListener('pagehide', hidden);

      // The switch off, for a page already up: WebKit's own full screen back,
      // in this frame and every frame inside it.
      function off() {
        if (current) leave(false);
        undo.reverse().forEach(function (entry) {
          if (entry[2]) Object.defineProperty(entry[0], entry[1], entry[2]);
          else delete entry[0][entry[1]];
        });
        undo = [];
        window.removeEventListener('message', heard, true);
        window.removeEventListener(LEAVE, ended);
        window.removeEventListener(OFF, off);
        window.removeEventListener('pagehide', hidden);
        Array.prototype.forEach.call(document.querySelectorAll('iframe, frame'), function (f) {
          if (f.contentWindow) f.contentWindow.postMessage({ [NOTE]: 'off' }, '*');
        });
        delete window.__searchFills;
      }
      if (isTop) window.addEventListener(OFF, off);
    })();
    """
}
