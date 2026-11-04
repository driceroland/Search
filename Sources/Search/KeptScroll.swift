import WebKit

// Back to a page that keeps its own scroll comes back where you left it.
//
// A page can tell the browser it will put its scroll back itself
// (history.scrollRestoration = 'manual'). GitHub's issue and pull request
// pages do. In Chrome that page comes back from the back-forward cache where
// it was left: it was never unloaded, so there was nothing to put back.
// WebKit brings the same page back at the very top, Safari included. Going
// from an issue to someone's profile and back lost your place in a long
// thread (measured: 1009 points down in Chrome, 0 here, in Safari, and in a
// plain WKWebView with nothing of Search's).
//
// So, in Search's world and only for the main frame: a page going into the
// cache in manual mode leaves its position here, and when it comes back out
// still at the very top, it goes back there. The page's own pageshow handlers
// run after this one, so a page that does scroll itself somewhere has the
// last word. A page that came back anywhere but the top, or that wasn't
// cached (a reload, a page from a fresh load), is never touched.
enum KeptScroll {
    static let script = """
    (function () {
      var kept = null;
      addEventListener('pagehide', function (e) {
        kept = e.persisted && history.scrollRestoration === 'manual'
          ? [window.scrollX, window.scrollY] : null;
      });
      addEventListener('pageshow', function (e) {
        var was = kept;
        kept = null;
        if (!e.persisted || !was || !(was[0] || was[1])) return;
        if (window.scrollX === 0 && window.scrollY === 0) window.scrollTo(was[0], was[1]);
      });
    })();
    """
}
