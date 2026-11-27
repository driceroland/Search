// A frame that loads while hidden is drawn at the page's zoom once shown.
//
// At a zoom other than 100%, WebKit leaves the zoom off a frame whose
// document loads while its `<iframe>` is `display: none`, or inside
// something that is. Shown later, the frame is sized for the zoom but its
// content is drawn at 100%. Prompts and dropdowns over a page are often
// made this way, and a plain WKWebView does the same.
//
// Every frame gets the script below. One that starts with no size compares,
// the first time it has one, its root's drawn width with its laid-out
// width. If they differ it adopts an empty style sheet and removes it,
// which makes WebKit restyle the frame with the zoom. Only that frame is
// restyled (about 1 ms for a hundred elements); the page around it sees
// nothing. Tests/frame_zoom.py fails without this for as long as WebKit
// does it.
enum FrameZoom {
    /// Every frame, in Search's world, before its document.
    static let script = """
    (function () {
      if (window === top || (innerWidth && innerHeight)) return;
      function look() {
        var root = document.documentElement;
        var laid = root && root.offsetWidth;
        if (!innerWidth || !innerHeight || !laid) return;
        removeEventListener('resize', look);
        var drawn = root.getBoundingClientRect().width;
        // 0.004 is what Tab tells two zooms apart by: closer than that,
        // nothing was missed.
        if (Math.abs(drawn / laid - 1) <= 0.004) return;
        // A copy: the list itself changes as it is set.
        var own = [].slice.call(document.adoptedStyleSheets);
        document.adoptedStyleSheets = own.concat([new CSSStyleSheet()]);
        document.adoptedStyleSheets = own;
      }
      addEventListener('resize', look);
    })();
    """
}
