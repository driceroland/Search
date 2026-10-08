import Foundation
import WebKit

// Two fingers sideways means back, or forward — if Settings › General › Swipe
// between pages is on, which it is unless turned off.
//
// WebKit has a swipe of its own, and it drags the whole page across the window
// with a picture of the last one behind it, as Safari's does. That is the one
// used, and none of what follows runs, unless Hold a swipe to pick from
// history is on: that needs the other kind, which is ours. A disc comes in
// from the edge you are pulling from, and past a certain point it is armed.
// Let go then, and the page simply goes back. Let go before, and it slips out
// again. Nothing slides, nothing is kept in memory to slide. Held a moment
// longer, the disc becomes the list of pages that way.
//
// The one hard question is whether a sideways swipe belongs to the page — a
// carousel, a wide table, a map, a canvas — or is free to mean something. The
// page is asked, on every sideways wheel event, whether anything under the
// pointer could scroll that way, or whether the page took the event for
// itself. The answer arrives a frame or two after the gesture starts, which
// is before there is anything to show.

enum Swipe {
    /// No rubber-banding. Pulling past the top of a page showed a band of
    /// blank ground above it, and nobody who came from Chrome read that as
    /// anything but a fault. WebKit lets a view turn off the bounce along
    /// chosen edges natively through `_setRubberBandingEnabled:`. We keep
    /// horizontal rubber-banding for two-finger swipe navigation gestures,
    /// while turning off top and bottom bounce.
    ///
    /// Turning this off via CSS `overscroll-behavior-y: none` on `html, body`
    /// broke mouse-wheel scrolling entirely on any page that had a non-passive
    /// wheel event listener (WebKit bug rdar://137757208). Native edge
    /// configuration avoids touching the page's styling and prevents the bug.
    static func calm(_ web: WKWebView) {
        let set = NSSelectorFromString("_setRubberBandingEnabled:")
        guard web.responds(to: set) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, UInt) -> Void
        // _WKRectEdge: one bit per CGRectEdge (_WKRectEdge.h) — the edges
        // that keep their bounce. Left and right only.
        let left: UInt = 1 << 0, right: UInt = 1 << 2   // CGRectMinXEdge, CGRectMaxXEdge
        unsafeBitCast(web.method(for: set), to: Setter.self)(web, set, left | right)
    }

    /// Whether a sideways swipe here would scroll something. Said once per
    /// change of mind, and at most ten times a second, so the page is never
    /// made to shout.
    static let watch = """
    (function () {
      if (window.__officeSwipe) return;
      window.__officeSwipe = true;

      var was = null, said = 0;

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
          if (root) {
            can = rootCanScroll();
            left = window.scrollX || 0;
            max = document.documentElement.scrollWidth - window.innerWidth;
          } else {
            var ox = getComputedStyle(el).overflowX;
            can = ox === 'auto' || ox === 'scroll';
            left = el.scrollLeft;
            max = el.scrollWidth - el.clientWidth;
          }
          if (can && max > 1) {
            if (e.deltaX > 0 ? left < max - 1 : left > 1) return true;
          }
          el = el.parentElement;
        }
        return false;
      }

      function say(t) {
        var now = Date.now();
        if (t === was && now - said < 100) return;
        was = t; said = now;
        window.webkit.messageHandlers.officeScroll.postMessage({ side: t ? 'taken' : 'free' });
      }

      window.addEventListener('wheel', function (e) {
        if (Math.abs(e.deltaX) <= Math.abs(e.deltaY)) return;
        if (taken(e)) return say(true);
        // A whiteboard or a map pans with its own wheel handler and nothing
        // under it has overflow to scroll. Its preventDefault is its claim,
        // as Safari and Chrome read it; it can only be seen once every
        // handler has run, and this one runs first.
        setTimeout(function () { say(e.defaultPrevented); }, 0);
      }, { passive: true, capture: true });
    })();
    """
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
}

/// A page in the list a held swipe shows.
struct Stop: Equatable {
    var title: String
    var url: URL
}
