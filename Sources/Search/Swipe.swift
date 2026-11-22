import AppKit
import WebKit

// Two fingers sideways means back, or forward.
//
// WebKit has a swipe of its own, and it drags the whole page across the window
// with a picture of the last one behind it. This is the other kind: a disc
// comes in from the edge you are pulling from, and past a certain point it is
// armed. Let go then, and the page simply goes back. Let go before, and it
// slips out again. Nothing slides, nothing is kept in memory to slide.
//
// The one hard question is whether a sideways swipe belongs to the page — a
// carousel, a wide table, a map, a canvas — or is free to mean something. The
// page is asked, on every sideways wheel event, whether anything under the
// pointer could scroll that way, or whether the page took the event for
// itself. The answer arrives a frame or two after the gesture starts, which
// is before there is anything to show.

enum Swipe {
    /// Whether a sideways scroll may mean back or forward: the Mac's own
    /// Swipe between pages, in System Settings › Trackpad and › Mouse, the
    /// one Safari follows. Search draws its own swipe, with WebKit's turned
    /// off, so it has to ask: a one-finger Magic Mouse scroll swiped with the
    /// setting off, taking a Google Sheet's sideways scroll for a way back
    /// (#464). The Mac answers for the device of the event being handled —
    /// the Mouse's switch for a mouse, the Trackpad's for a trackpad — so it
    /// is asked in scrollWheel, for that event, and never ahead of time or
    /// kept. A test run stands in for the setting (`ui swipepages`), since
    /// the Mac's own is the person's, not a test's.
    @MainActor static var followsTheMac: Bool {
        testing ?? NSEvent.isSwipeTrackingFromScrollEventsEnabled
    }
    /// Set only by a test run (see Bench), never by the browser people use.
    @MainActor static var testing: Bool?

    /// No rubber-banding. Pulling past the top of a page showed a band of
    /// blank ground above it, and nobody who came from Chrome read that as
    /// anything but a fault. WebKit lets a view turn off the bounce along
    /// chosen edges natively through `_setRubberBandingEnabled:`. Top and
    /// bottom never bounce. The sides bounce only on a page pinched in, where
    /// panning on to its edge needs them; at its own size a swipe back is a
    /// pull past the left edge, and the stretch it left behind kept the page
    /// shifted 60 to 120 points to the side (#810, #815). Asked again as each
    /// gesture starts, since a pinch changes the answer (PageView.scrollWheel).
    ///
    /// Turning this off via CSS `overscroll-behavior-y: none` on `html, body`
    /// broke mouse-wheel scrolling entirely on any page that had a non-passive
    /// wheel event listener (WebKit bug rdar://137757208). Native edge
    /// configuration avoids touching the page's styling and prevents the bug.
    /// Top and bottom bounce after all, when asked for in Settings (Prefs.bounces).
    static var bounces = false

    static func calm(_ web: WKWebView) {
        let set = NSSelectorFromString("_setRubberBandingEnabled:")
        guard web.responds(to: set) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, UInt) -> Void
        // _WKRectEdge: one bit per CGRectEdge (_WKRectEdge.h) — the edges
        // that keep their bounce. Left and right, and only pinched in.
        let left: UInt = 1 << 0, right: UInt = 1 << 2   // CGRectMinXEdge, CGRectMaxXEdge
        let top: UInt = 1 << 1, bottom: UInt = 1 << 3   // CGRectMinYEdge, CGRectMaxYEdge
        let sides: UInt = web.magnification > 1 ? left | right : 0
        unsafeBitCast(web.method(for: set), to: Setter.self)(web, set, sides | (bounces ? top | bottom : 0))
    }

    /// Whether a sideways swipe here would scroll something. Said once per
    /// change of mind, and at most ten times a second, so the page is never
    /// made to shout.
    ///
    /// A box at its edge is free only when it was resting there. WebKit
    /// scrolls a sideways box before the page hears of the wheel event, so
    /// a swipe that carried a box to its edge found it there already, and
    /// went back (#1219): the box's own scroll events say it was moving.
    static let watch = """
    (function () {
      if (window.__officeSwipe) return;
      window.__officeSwipe = true;

      var was = null, said = 0;
      // When each box, and the page itself, last moved sideways. Only
      // sideways: a page scrolled down a moment ago can still be swiped,
      // and so can one pinched in whose side bounces under the swipe
      // without its place changing.
      var moved = new WeakMap(), at = new WeakMap();
      function mark(el) {
        var root = el === document.documentElement, vv = window.visualViewport;
        var x = root ? (vv ? vv.pageLeft : window.scrollX) : el.scrollLeft;
        // At or past the left edge, clamping always yields 0 — skip reading
        // scrollWidth/clientWidth on every vertical scroll.
        if (x > 0) {
          // A side bouncing past its edge is not moving along: held to it.
          var max = root ? document.documentElement.scrollWidth - (vv ? vv.width : window.innerWidth) : el.scrollWidth - el.clientWidth;
          x = Math.min(Math.max(0, max), x);
        } else {
          x = 0;
        }
        if (at.has(el) && Math.abs(at.get(el) - x) < 1) return;
        at.set(el, x);
        moved.set(el, Date.now());
      }
      window.addEventListener('scroll', function (e) {
        var t = e.target;
        mark(t === document || t === document.body ? document.documentElement : t);
      }, { passive: true, capture: true });
      if (window.visualViewport) {
        window.visualViewport.addEventListener('scroll', function () { mark(document.documentElement); }, { passive: true });
      }
      // The boxes under the pointer that scroll that way and are at their
      // edge: free only if they were resting there.
      var edges = [];

      function rootCanScroll() {
        var html = getComputedStyle(document.documentElement).overflowX;
        var body = document.body ? getComputedStyle(document.body).overflowX : 'visible';
        var effective = html === 'visible' ? body : html;
        return effective !== 'hidden' && effective !== 'clip';
      }

      function taken(e) {
        var el = e.target;
        if (el && el.nodeType !== 1) el = el.parentElement;
        while (el) {
          var root = el === document.documentElement || el === document.body;
          var can, left, max;
          var vv = window.visualViewport;
          if (root && vv && vv.scale > 1.01) {
            // Pinched in: what is on screen pans across the page even where
            // the page itself can't scroll sideways (overflow-x: hidden), so
            // that is taken until the edge, as in Safari.
            can = true;
            left = vv.pageLeft;
            max = (rootCanScroll() ? document.documentElement.scrollWidth : document.documentElement.clientWidth) - vv.width;
          } else if (root) {
            max = document.documentElement.scrollWidth - window.innerWidth;
            can = max > 1 && rootCanScroll();
            left = window.scrollX || 0;
          } else {
            max = el.scrollWidth - el.clientWidth;
            if (max > 1) {
              var ox = getComputedStyle(el).overflowX;
              can = ox === 'auto' || ox === 'scroll';
              left = el.scrollLeft;
            } else {
              can = false;
            }
          }
          if (can && max > 1) {
            if (e.deltaX > 0 ? left < max - 1 : left > 1) return true;
            edges.push(root ? document.documentElement : el);
          }
          el = el.parentElement;
        }
        return false;
      }

      function resting(edges) {
        var now = Date.now();
        return edges.every(function (el) { return now - (moved.get(el) || 0) > 400; });
      }

      function say(t) {
        var now = Date.now();
        if (t === was && now - said < 100) return;
        was = t; said = now;
        window.webkit.messageHandlers.officeScroll.postMessage({ side: t ? 'taken' : 'free' });
      }

      window.addEventListener('wheel', function (e) {
        if (Math.abs(e.deltaX) <= Math.abs(e.deltaY)) return;
        edges = [];
        if (taken(e)) return say(true);
        var those = edges;
        // A whiteboard or a map pans with its own wheel handler and nothing
        // under it has overflow to scroll. Its preventDefault is its claim,
        // as Safari and Chrome read it; it can only be seen once every
        // handler has run, and this one runs first. A box's scroll event
        // comes with the next frame, so that is waited for too.
        setTimeout(function () { say(e.defaultPrevented || !resting(those)); }, 50);
      }, { passive: true, capture: true });
    })();
    """

    /// Asked as the fingers lift (PageView.heard): settled once every wheel
    /// event before it has been answered, which the 50 ms above allows for.
    static let heard = "await new Promise(function (done) { setTimeout(done, 80); }); return true;"
}

/// Where a sideways swipe has got to, for the disc that shows it.
struct Pull: Equatable {
    /// Pulling from the left edge, to go back; otherwise from the right.
    var back: Bool
    /// How far the fingers have come, in points, before any damping.
    var travel: CGFloat
    /// Far enough that letting go will do it.
    var armed: Bool
    /// Let go while armed: the page is on its way, and the disc leaves.
    var going: Bool
    /// Held once armed: the pages that way, top to bottom, in place of the
    /// disc, and the one letting go would open (see PageView.openList).
    var stops: [Stop]? = nil
    var picked = 0
    /// Going back from the first page, where back means leaving: the small
    /// window closes rather than the page changing (see PageView.leave).
    var leaves = false
}

/// A page in the list a held swipe shows.
struct Stop: Equatable {
    var title: String
    var url: URL
}
