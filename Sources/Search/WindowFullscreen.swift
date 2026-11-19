import AppKit
import os
import WebKit

// A page's full screen the way Chrome does it: the page never leaves this
// window. WebKit's own element full screen lends the page to a window of its
// own and gives it back behind a frozen picture, held until the page has
// drawn again in ours (240 to 400 ms on YouTube, measured 8 Nov 2026; a bare
// WKWebView holds it 80 ms, Safari 100 to 150). With Settings › Video › Full
// screen takes the window on (off unless asked for), WebKit's is switched off
// for tabs made after (Web.configuration), the page's Fullscreen API is
// answered by the script below, and the window itself goes full screen, the
// chrome stepping aside as it always has for a page filling the screen
// (Tab.immersed). One move each way: of a picture of the window, which gives
// way to the page itself as soon as the page has drawn at its new size.


final class WindowFullscreen: NSObject, WKScriptMessageHandler {
    static let name = "searchFullscreen"

    weak var tab: Tab?

    /// Whether this page's full screen took the window there, so that coming
    /// back gives it back; a window already full screen stays.
    private var tookWindow = false
    /// That window, for the way back once another tab is in front of the
    /// page and the page is out of it.
    private weak var taken: NSWindow?
    private var exitWatch: NSObjectProtocol?

    /// The window's frame before it took the screen, to zoom from and back to.
    private var resting: NSRect?
    /// Standing in for the window's delegate while it zooms.
    private var stand: ZoomDelegate?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let on = (message.body as? [String: Any])?["on"] as? Bool else { return }
        MainActor.assumeIsolated { set(on) }
    }

    @MainActor private func set(_ on: Bool) {
        guard let tab else { return }
        let shown = tab.built?.window
        guard let window = shown ?? (on ? nil : taken) else {
            if tab.immersed != on { tab.immersed = on }
            return
        }
        // Another tab in front by now (⌘T or ⌃Tab on the video, which also
        // end its full screen, #1042): there is no page here to time a zoom
        // by, so the window goes back as macOS moves it.
        if !on, shown == nil { letGo(window) }
        let full = window.styleMask.contains(.fullScreen)
        // Moving the window here: the chrome goes with it, inside the zoom
        // below, which tells the page. A window already full screen, or one
        // macOS moves (Reduce Motion, or no window server calls to move it
        // with): straight away.
        let moving = on ? !full : (tookWindow && full)
        let zooming = moving && (on ? Self.zooms : zoomsOut)
        if !zooming, tab.immersed != on { tab.immersed = on }
        if on {
            watchExit(of: window)
            if moving {
                tookWindow = true
                taken = window
                if zooming {
                    resting = window.frame
                    standIn(for: window)
                }
                window.toggleFullScreen(nil)
            }
        } else {
            stopWatching()
            if moving { window.toggleFullScreen(nil) }
            tookWindow = false
            taken = nil
        }
        if !zooming { tab.built?.evaluateJavaScript(Self.tell, in: nil, in: .page) }
    }

    // MARK: - one zoom

    // Both ends of the move are known, so the window takes the frame it ends
    // at once and everything in it is laid out once, while the window server
    // draws it in a rectangle that goes from where it was to where it ends,
    // as macOS's own full screen and Mission Control move a window (Glide).
    //
    // Tried first, 8 to 10 Nov 2026: the window resized frame by frame (the
    // page lays itself out at every size); the window see-through at the
    // screen's size with its content's layer scaled in it (its title bar
    // drew grey under the menu bar, and AppKit moved the window half way
    // out); waiting for the page's new size before moving (a pause, then
    // the move); WKWebView's own snapshot to fade from (0.9 to 1 s to come).

    /// The window's delegate is SwiftUI's (AppKitWindowController): the
    /// stand-in answers for the full screen animation and hands it the rest.
    @MainActor private func standIn(for window: NSWindow) {
        guard stand == nil || window.delegate !== stand else { return }
        let stand = ZoomDelegate(original: window.delegate, owner: self)
        self.stand = stand
        window.delegate = stand
    }

    @MainActor fileprivate func enter(_ window: NSWindow) {
        zoom(window, from: resting ?? window.frame, to: Self.filling(window), immersed: true)
    }

    @MainActor fileprivate func exit(_ window: NSWindow) {
        zoom(window, from: window.frame, to: resting ?? window.frame, immersed: false)
    }

    /// The frame a window full screen takes: the screen, less the menu
    /// bar's strip beside a camera housing (1512 by 949 of 982 on a 14-inch
    /// MacBook Pro; the safe area alone said 950, and the page was laid out
    /// once more, a point shorter, when macOS settled the window). What a
    /// window full screen on that screen was last given wins.
    private static func filling(_ window: NSWindow) -> NSRect {
        guard let screen = window.screen else { return window.frame }
        if let seen = filled[screen.localizedName] { return seen }
        var frame = screen.frame
        if screen.safeAreaInsets.top > 0 {
            frame.size.height -= max(screen.safeAreaInsets.top, screen.frame.maxY - screen.visibleFrame.maxY)
        }
        return frame
    }

    private static var filled: [String: NSRect] = [:]

    /// A zoom macOS asked the windows for and has yet to start.
    private var awaited = false

    /// The move over without the zoom: macOS asks for its windows and then
    /// skips the animation when the window's Space is not the one in view
    /// (another app in front; 1 exit in 11 with another build's window
    /// taking the front, 19 Nov 2026). What the zoom would have left, at
    /// once: the picture gone, or it stays over every Space; the chrome as
    /// it should be; the window in the frame it had; the page told.
    @MainActor fileprivate func settle(_ window: NSWindow, immersed: Bool) {
        guard awaited else { return }
        awaited = false
        cover?.orderOut(nil)
        cover = nil
        if !immersed, let resting, !window.styleMask.contains(.fullScreen), window.frame != resting {
            window.setFrame(resting, display: true)
        }
        if let tab, tab.immersed != immersed { tab.immersed = immersed }
        tab?.built?.evaluateJavaScript(Self.tell, in: nil, in: .page)
    }

    @MainActor fileprivate func entered(_ window: NSWindow) {
        settle(window, immersed: true)
        // In full screen the buttons are macOS's to show, in the bar that
        // comes down with the menu bar (Fold.hideLights).
        if lightsWere != nil { window.standardWindowButton(.closeButton)?.superview?.isHidden = false }
        lightsWere = nil
        if let screen = window.screen, window.styleMask.contains(.fullScreen) { Self.filled[screen.localizedName] = window.frame }
    }

    @MainActor fileprivate var zoomsOut: Bool { resting != nil && Self.zooms }

    /// Whether the window is moved here; otherwise as macOS moves it.
    @MainActor private static var zooms: Bool { WindowServer.draws && !Motion.reduced }

    private var glide: Glide?
    /// Whether the window's buttons were hidden before it went in.
    private var lightsWere: Bool?
    /// The picture of the window as it was, made when macOS asks which
    /// windows move and handed to it with the window: it slides every other
    /// window away with the Space they are in as the move starts, and a
    /// picture put up later went with them.
    private var cover: NSWindow?

    @MainActor fileprivate func moving(with window: NSWindow) -> [NSWindow] {
        awaited = true
        glide?.finish()
        cover?.orderOut(nil)
        cover = Glide.cover(of: window)
        return [window] + (cover.map { [$0] } ?? [])
    }

    @MainActor private func zoom(_ window: NSWindow, from start: NSRect, to end: NSRect, immersed: Bool) {
        awaited = false
        glide?.finish()
        let picture = cover
        cover = nil
        // The picture first, where it starts and whole, said to the window
        // server outright: ordered front, it was not always on screen yet,
        // and the two frames until its first move showed neither window
        // (2 toggles of 34 without this, none of 28 with it, 10 Nov 2026).
        // Then the window under it, drawn at a point while it takes the
        // frame it ends at: the window server keeps a window's scale when it
        // is resized, so it would show for a frame at the wrong size.
        if let picture {
            WindowServer.draw(picture, in: start)
            WindowServer.fade(UInt32(picture.windowNumber), to: 1)
            WindowServer.draw(window, in: NSRect(x: start.midX, y: start.midY, width: 1, height: 1))
        }
        // Going in, the window's buttons go with the chrome: macOS takes
        // them only once the window is there, and until then they sat over
        // the corner of the video (given back in `entered`).
        if immersed, let lights = window.standardWindowButton(.closeButton)?.superview {
            lightsWere = lights.isHidden
            lights.isHidden = true
        }
        // Laid out once, at that frame, which it has before the chrome
        // changes: the other way round, the page was given two sizes (going
        // in, 1180 by 780 and then 1512 by 949), WebKit held the second until
        // the first was answered, and YouTube laid out twice. Not displayed
        // here and now: AppKit holds every change to the screen while it
        // does that. The frame goes with the flush.
        window.setFrame(end, display: false)
        if let tab, tab.immersed != immersed { tab.immersed = immersed }
        window.contentView?.layoutSubtreeIfNeeded()
        CATransaction.flush()
        // And the two move from here, the clock starting now: a window's
        // rectangle is set in step with what the app last drew in it, so one
        // set during that flush waited for it, 20 to 66 ms (once in fifteen,
        // 0.5 s), and the move then skipped that far ahead.
        let glide = Glide(window, under: picture, from: start, to: end, pace: immersed ? .goingIn : .comingBack) { [weak self] in self?.glide = nil }
        self.glide = glide
        // The page hears of the change now, laid out at the size it ends at,
        // and the picture goes once it has drawn so. (Told only once it had
        // the size, YouTube still sized its video twice coming back, 0.3 to
        // 0.5 s apart: 716 then 808 wide in a 1180 window, 976 then 996 in a
        // 1440 one. Its own.)
        guard let page = tab?.built else { return glide.uncover() }
        page.evaluateJavaScript(Self.tell, in: nil, in: .page)
        let scale = page.pageZoom > 0 ? page.pageZoom : 1
        page.callAsyncJavaScript(Self.sized, arguments: ["w": page.frame.width / scale, "h": page.frame.height / scale],
                                 in: nil, in: Web.world) { _ in
            MainActor.assumeIsolated {
                Self.presented(page) { glide.uncover() }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { glide.uncover() }
    }

    /// Once what the page has drawn is on screen. WebKit puts a page's new
    /// layers in place on the main thread, which is taken for 50 to 400 ms in
    /// the middle of this: uncovered when the page said it had drawn, the
    /// window still showed its old layout at its new size, and cut to the
    /// new one up to 0.25 s later (10 Nov 2026). The name is outside the
    /// public framework, so it is asked first.
    @MainActor private static func presented(_ page: WKWebView, _ then: @escaping @MainActor () -> Void) {
        let after = NSSelectorFromString("_doAfterNextPresentationUpdate:")
        guard page.responds(to: after) else { return then() }
        let block: @convention(block) () -> Void = { MainActor.assumeIsolated { then() } }
        page.perform(after, with: block)
    }

    /// Resolved a frame after the page has the size Search laid it out at, or
    /// after 0.3 s without it.
    static let sized = """
    return await new Promise(function (done) {
      var start = performance.now();
      (function tick() {
        if (Math.abs(innerWidth - w) <= 1 && Math.abs(innerHeight - h) <= 1) return requestAnimationFrame(function () { done(true); });
        if (performance.now() - start > 300) return done(false);
        requestAnimationFrame(tick);
      })();
    });
    """

    @MainActor fileprivate func failed(_ window: NSWindow) {
        if let lightsWere { window.standardWindowButton(.closeButton)?.superview?.isHidden = lightsWere }
        lightsWere = nil
        if let tab, tab.immersed { tab.immersed = false }
        // The picture made for the way in goes too, or it stays over every Space.
        awaited = false
        cover?.orderOut(nil)
        cover = nil
        letGo(window)
    }

    @MainActor fileprivate func letGo(_ window: NSWindow) {
        resting = nil
        if let stand, window.delegate === stand { window.delegate = stand.original }
        stand = nil
    }

    /// A new document in the tab: the page that asked is gone, and its full
    /// screen with it, or the window stays there with the chrome away and
    /// nothing left to bring it back.
    @MainActor func pageLeft() {
        if exitWatch != nil { set(false) }
    }

    /// The window leaving full screen some other way (the green button,
    /// ⌃⌘F, Mission Control) takes the page out of its full screen too.
    @MainActor private func watchExit(of window: NSWindow) {
        stopWatching()
        exitWatch = NotificationCenter.default.addObserver(
            forName: NSWindow.willExitFullScreenNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.tookWindow = false
                self.tab?.built?.evaluateJavaScript(Self.exit, in: nil, in: .page)
            }
        }
    }

    @MainActor private func stopWatching() {
        if let exitWatch { NotificationCenter.default.removeObserver(exitWatch) }
        exitWatch = nil
    }

    static let exit = "window.__searchFullscreen && window.__searchFullscreen.exit(); 0"
    static let tell = "window.__searchFullscreen && window.__searchFullscreen.tell(); 0"

    /// In the page's own world, where its players call the API. The element
    /// asked for is put in the top layer (a manual popover), out from under
    /// any transform, overflow or z-index around it, and pinned to the
    /// viewport, which the window then grows to the whole screen. `:fullscreen`
    /// itself can't be made to match; YouTube styles its player by its own
    /// attributes, so it doesn't look.
    static let script = """
    (function () {
      if (window.__searchFullscreen) return;
      var current = null;
      var css = document.createElement('style');
      css.textContent =
        '[data-search-fullscreen]{position:fixed!important;inset:0!important;width:100%!important;height:100%!important;' +
        'max-width:none!important;max-height:none!important;min-width:0!important;min-height:0!important;' +
        'margin:0!important;padding:0!important;border:0!important;box-sizing:border-box!important;' +
        'transform:none!important;z-index:2147483647!important;background:#000;overflow:hidden!important}' +
        '[data-search-fullscreen]::backdrop{background:#000}';
      function post(on) {
        try { window.webkit.messageHandlers.searchFullscreen.postMessage({ on: on }); } catch (e) {}
      }
      function fire(el) {
        setTimeout(function () {
          var target = el.isConnected ? el : document;
          target.dispatchEvent(new Event('fullscreenchange', { bubbles: true, composed: true }));
          target.dispatchEvent(new Event('webkitfullscreenchange', { bubbles: true, composed: true }));
        }, 0);
      }
      function enter(el) {
        if (navigator.userActivation && !navigator.userActivation.isActive && !current) {
          return Promise.reject(new TypeError('Full screen needs a click or a key press.'));
        }
        if (current === el) return Promise.resolve();
        if (current) leave();
        current = el;
        post(true);
        later(el);
        return Promise.resolve();
      }
      // The element pinned to the viewport: the whole document (YouTube's
      // choice) already has it, which the window then grows.
      function pin(el) {
        if (el !== current || el === document.documentElement) return;
        (document.head || document.documentElement).appendChild(css);
        el.setAttribute('data-search-fullscreen', '');
        if (typeof el.showPopover === 'function' && !el.hasAttribute('popover')) {
          el.setAttribute('popover', 'manual');
          try { el.showPopover(); el.__searchPopover = true; } catch (e) { el.removeAttribute('popover'); }
        }
      }
      function leave() {
        if (!current) return Promise.resolve();
        var el = current;
        current = null;
        if (el.__searchPopover) {
          try { el.hidePopover(); } catch (e) {}
          el.removeAttribute('popover');
          delete el.__searchPopover;
        }
        el.removeAttribute('data-search-fullscreen');
        post(false);
        later(el);
        return Promise.resolve();
      }
      // Each way, the change is said (and the element pinned) once Search has
      // laid the page out at the size it ends at, as the window starts to
      // move (tell, from Search): said at the request, YouTube laid its player
      // out for the window it was leaving, a step of its own before the move,
      // and going in did it inside the small window. Said anyway if Search
      // never answers.
      var told = null;
      function later(el) {
        told = el;
        setTimeout(tell, 400);
      }
      function tell() {
        if (!told) return;
        var el = told;
        told = null;
        pin(el);
        fire(el);
      }
      var E = Element.prototype, D = Document.prototype;
      E.requestFullscreen = function () { return enter(this); };
      E.webkitRequestFullscreen = E.webkitRequestFullScreen = function () { enter(this); };
      D.exitFullscreen = function () { return leave(); };
      D.webkitExitFullscreen = D.webkitCancelFullScreen = function () { leave(); };
      function getter(name, get) { Object.defineProperty(D, name, { get: get, configurable: true }); }
      ['fullscreenElement', 'webkitFullscreenElement', 'webkitCurrentFullScreenElement'].forEach(function (n) {
        getter(n, function () { return current; });
      });
      ['fullscreen', 'webkitIsFullScreen'].forEach(function (n) { getter(n, function () { return !!current; }); });
      ['fullscreenEnabled', 'webkitFullscreenEnabled'].forEach(function (n) { getter(n, function () { return true; }); });
      // Players pick the event to listen for by which handler property
      // exists ("onfullscreenchange" in document); with WebKit's own full
      // screen off, none does, and YouTube never heard it had gone in.
      ['fullscreenchange', 'fullscreenerror', 'webkitfullscreenchange', 'webkitfullscreenerror'].forEach(function (type) {
        var prop = 'on' + type;
        [D, E].forEach(function (proto) {
          if (prop in proto) return;
          var handlers = new WeakMap();
          Object.defineProperty(proto, prop, {
            configurable: true,
            get: function () { return handlers.get(this) || null; },
            set: function (fn) {
              var old = handlers.get(this);
              if (old) this.removeEventListener(type, old);
              if (typeof fn === 'function') { handlers.set(this, fn); this.addEventListener(type, fn); }
              else handlers.delete(this);
            }
          });
        });
      });
      // Escape ends the full screen and goes no further, as WebKit's own
      // never reaches the page: left to go on, AppKit took a window that
      // was full screen already (the green button) out of it as well.
      document.addEventListener('keydown', function (e) {
        if (current && e.key === 'Escape') { e.preventDefault(); e.stopImmediatePropagation(); leave(); }
      }, true);
      Object.defineProperty(window, '__searchFullscreen', { value: { exit: leave, tell: tell } });
    })();
    """
}

/// The window's delegate for as long as it zooms: its own full screen
/// animation (WindowFullscreen.zoom), and every other message to the
/// delegate it had, which it holds until it is put back.
private final class ZoomDelegate: NSObject, NSWindowDelegate {
    let original: NSWindowDelegate?
    weak var owner: WindowFullscreen?

    init(original: NSWindowDelegate?, owner: WindowFullscreen) {
        self.original = original
        self.owner = owner
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || original?.responds(to: selector) == true
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        original?.responds(to: selector) == true ? original : nil
    }

    func customWindowsToEnterFullScreen(for window: NSWindow) -> [NSWindow]? {
        MainActor.assumeIsolated { owner?.moving(with: window) ?? [window] }
    }

    func customWindowsToExitFullScreen(for window: NSWindow) -> [NSWindow]? {
        MainActor.assumeIsolated { owner?.zoomsOut == true ? owner?.moving(with: window) : nil }
    }

    func window(_ window: NSWindow, startCustomAnimationToEnterFullScreenWithDuration duration: TimeInterval) {
        MainActor.assumeIsolated { owner?.enter(window) }
    }

    func window(_ window: NSWindow, startCustomAnimationToExitFullScreenWithDuration duration: TimeInterval) {
        MainActor.assumeIsolated { owner?.exit(window) }
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        original?.windowDidEnterFullScreen?(notification)
        MainActor.assumeIsolated { if let window = notification.object as? NSWindow { owner?.entered(window) } }
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        original?.windowDidExitFullScreen?(notification)
        MainActor.assumeIsolated {
            guard let window = notification.object as? NSWindow else { return }
            owner?.settle(window, immersed: false)
            owner?.letGo(window)
        }
    }

    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        original?.windowDidFailToEnterFullScreen?(window)
        MainActor.assumeIsolated { owner?.failed(window) }
    }
}

/// A window on its way from one rectangle of the screen to another. A
/// picture of it as it was, in a window of its own, does the moving from the
/// first frame; the window itself takes its new frame under the picture,
/// drawn at a point until it has (see zoom), then
/// in the same rectangle as the picture, which fades once the page has drawn.
/// Faded by the window server too: a fade of its layer, set from the main
/// thread, reached the screen 100 ms and more after it was over.
///
/// Moved from a thread of its own: the main thread is taken for 50 to 200 ms
/// in the middle of this, by WebKit putting the page's new layers in place
/// (RemoteLayerTreeDrawingAreaProxy::commitLayerTree) and by AppKit's own
/// full screen bookkeeping (sampled 10 Nov 2026), and a move made from there
/// stood still that long. A spring without bounce, which would carry the
/// window past the screen's edge (Pace); a short ease-out on a Mac short of
/// power.
@MainActor private final class Glide {
    private let window: NSWindow
    private let cover: NSWindow?
    private let done: () -> Void
    /// When the picture began to fade, for the thread that moves the windows.
    private let uncovered: OSAllocatedUnfairLock<CFTimeInterval?>
    private var timer: DispatchSourceTimer?
    private var finished = false

    /// The picture of `window` as it is, in a window of its own exactly over it.
    static func cover(of window: NSWindow) -> NSWindow? {
        guard WindowServer.draws, let picture = WindowServer.picture(of: window) else { return nil }
        let cover = NSWindow(contentRect: window.frame, styleMask: .borderless, backing: .buffered, defer: false)
        cover.isReleasedWhenClosed = false
        // See-through as far as the window server knows: an opaque one
        // over the page's window has WebKit take the page for hidden.
        cover.isOpaque = false
        cover.backgroundColor = .clear
        cover.hasShadow = false
        cover.ignoresMouseEvents = true
        cover.animationBehavior = .none
        cover.level = .floating
        // In every Space, and still through a change of Space, which going
        // full screen is. In the one it was made in only, it went with that
        // Space when macOS left it at the end of the way back, still fading:
        // drawn a sixth of the window out of place for its last 0.1 s.
        cover.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let view = NSView(frame: NSRect(origin: .zero, size: window.frame.size))
        view.wantsLayer = true
        view.layer?.contents = picture
        view.layer?.contentsGravity = .resize
        cover.contentView = view
        cover.orderFrontRegardless()
        CATransaction.flush()
        return cover
    }

    /// How a move goes: its spring (no bounce) and when it is taken as over,
    /// and how long the picture stays whole at least before it fades. The
    /// picture goes when the page has drawn, but no sooner than `whole`:
    /// WebKit says a page's new layers are on screen before they are.
    struct Pace: Sendable {
        var response: Double, length: Double, whole: Double, fade: Double

        /// Search's own response (Motion.glide). Whole for 0.33 s: uncovered
        /// as soon as WebKit said the page was on screen, about 0.17 s in,
        /// the window still showed the old page in its corner until 0.29 to
        /// 0.33 s, in 2 to 6 entries of 16 (11 Nov 2026).
        static let goingIn = Pace(response: 0.34, length: 0.5, whole: 0.33, fade: 0.12)

        /// Slower, and whole for 0.62 s. From 0.48 to 0.61 s in, as macOS
        /// ends its own part of the way back, nothing this app sends
        /// reaches the screen: a fade through it, by the window's alpha or
        /// by its layer's, set frame by frame or handed over ahead, showed
        /// as one cut or two. And YouTube lays its page out a second time
        /// inside it (the video 716 then 808 wide, its list of videos drawn
        /// again, 0.35 s after the first), a jump when the page is already
        /// in sight. So the picture stays until both are past, and the
        /// window takes most of that time to arrive: at Search's response it
        /// was there by 0.26 s, and the picture stood still for the rest.
        static let comingBack = Pace(response: 0.5, length: 0.8, whole: 0.62, fade: 0.12)
    }

    init(_ window: NSWindow, under cover: NSWindow?, from start: NSRect, to end: NSRect, pace: Pace, done: @escaping () -> Void) {
        self.window = window
        self.cover = cover
        self.done = done
        let uncovered = OSAllocatedUnfairLock<CFTimeInterval?>(initialState: nil)
        self.uncovered = uncovered
        timer = Self.ticker(UInt32(window.windowNumber), cover: cover.map { UInt32($0.windowNumber) }, from: start, to: end,
                            top: WindowServer.top, light: Motion.light, pace: pace, uncovered: uncovered) { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.finish() } }
        }
    }

    /// Off the main thread, every 120th of a second: the picture's window
    /// and the page's drawn where the move has got to, and the picture as
    /// faded as it has got. Over once the move is and the picture is gone.
    private nonisolated static func ticker(_ number: UInt32, cover: UInt32?, from start: NSRect, to end: NSRect, top: CGFloat,
                                           light: Bool, pace: Pace, uncovered: OSAllocatedUnfairLock<CFTimeInterval?>,
                                           over: @escaping @Sendable () -> Void) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: DispatchQueue(label: "search.fullscreen.glide", qos: .userInteractive))
        // Counted from the first frame drawn: the first is still held some
        // 15 to 30 ms by what the app drew last.
        var began: CFTimeInterval?
        let length = light ? 0.16 : pace.length
        timer.schedule(deadline: .now(), repeating: 1.0 / 120, leeway: .nanoseconds(0))
        timer.setEventHandler {
            let now = CACurrentMediaTime(), t = began.map { now - $0 } ?? 0
            defer { if began == nil { began = CACurrentMediaTime() } }
            var along = 1.0
            if t < length {
                if light {
                    along = 1 - pow(1 - t / length, 2)
                } else {
                    let turn = 2 * Double.pi / pace.response * t
                    along = 1 - (1 + turn) * exp(-turn)
                }
            }
            func between(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * along }
            let rect = NSRect(x: between(start.minX, end.minX), y: between(start.minY, end.minY),
                              width: between(start.width, end.width), height: between(start.height, end.height))
            var shown = 0.0
            if let cover {
                shown = uncovered.withLock { $0 }.map { said in
                    let from = max(said, (began ?? now) + pace.whole)
                    return min(1, max(0, 1 - (now - from) / pace.fade))
                } ?? 1
                WindowServer.draw(cover, in: rect, top: top)
                WindowServer.fade(cover, to: shown)
            }
            WindowServer.draw(number, in: rect, top: top)
            if t >= length, shown == 0 {
                timer.cancel()
                over()
            }
        }
        timer.resume()
        return timer
    }

    /// The page has drawn, and it is on screen: the picture fades from over it.
    func uncover() {
        uncovered.withLock { if $0 == nil { $0 = CACurrentMediaTime() } }
    }

    /// Where it ends, at once: the move over, or cut short by another.
    func finish() {
        guard !finished else { return }
        finished = true
        timer?.cancel()
        WindowServer.draw(window, in: window.frame)
        cover?.orderOut(nil)
        done()
    }
}

/// The window server's own calls, outside the public frameworks and asked
/// for by name first (WebKit uses the same for its full screen): a window
/// drawn in another rectangle than its frame, and a picture of one, taken
/// at once (3 to 30 ms; WKWebView's own snapshot took 0.9 to 1 s).
private enum WindowServer {
    private typealias Connection = @convention(c) () -> Int32
    private typealias Transform = @convention(c) (Int32, UInt32, CGAffineTransform) -> Int32
    private typealias Bounds = @convention(c) (Int32, UInt32, UnsafeMutablePointer<CGRect>) -> Int32
    private typealias Alpha = @convention(c) (Int32, UInt32, Swift.Float) -> Int32
    private typealias Capture = @convention(c) (Int32, UnsafePointer<UInt32>, Int32, UInt32) -> Unmanaged<CFArray>?

    private static func named<T>(_ name: String) -> T? {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), name).map { unsafeBitCast($0, to: T.self) }
    }

    private static let connection: Int32? = (named("CGSMainConnectionID") as Connection?).map { $0() }
    private static let transform: Transform? = named("CGSSetWindowTransform")
    private static let bounds: Bounds? = named("CGSGetWindowBounds")
    private static let alpha: Alpha? = named("CGSSetWindowAlpha")
    private static let capture: Capture? = named("CGSHWCaptureWindowList")

    /// The main screen's top edge, which the window server counts down from.
    @MainActor static var top: CGFloat { NSScreen.screens.first?.frame.maxY ?? 0 }

    @MainActor static func draw(_ window: NSWindow, in rect: NSRect) {
        draw(UInt32(window.windowNumber), in: rect, top: top)
    }


    static var draws: Bool { connection != nil && transform != nil && bounds != nil }

    /// The window of that number, whatever frame it has at this moment, drawn
    /// in `rect` of the screen; in its own frame, as it is again. `top`: the
    /// main screen's top edge, which the window server counts down from. A
    /// move or a resize keeps the scale set here and shifts the place, when
    /// the window's content for it lands (measured 10 Nov 2026).
    static func draw(_ number: UInt32, in rect: NSRect, top: CGFloat) {
        guard let connection, let transform, let bounds, rect.width > 0, rect.height > 0 else { return }
        var frame = CGRect.zero
        guard bounds(connection, number, &frame) == 0 else { return }
        let across = frame.width / rect.width, down = frame.height / rect.height
        _ = transform(connection, number,
                      CGAffineTransform(a: across, b: 0, c: 0, d: down, tx: -rect.minX * across, ty: -(top - rect.maxY) * down))
    }

    /// The window of that number, that much seen.
    static func fade(_ number: UInt32, to shown: Double) {
        guard let connection, let alpha else { return }
        _ = alpha(connection, number, Swift.Float(shown))
    }

    /// kCGSCaptureIgnoreGlobalClipShape, as WebKit asks.
    @MainActor static func picture(of window: NSWindow) -> CGImage? {
        guard let connection, let capture else { return nil }
        var id = UInt32(window.windowNumber)
        return (capture(connection, &id, 1, 0x0800)?.takeRetainedValue() as? [CGImage])?.first
    }
}
