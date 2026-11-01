(function () {
  if (Object.prototype.hasOwnProperty.call(window, '__officeSwipe')) return;
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
      var vv = window.visualViewport;
      if (root && vv && vv.scale > 1.01) {
        // Pinched in: what is on screen pans across the page even where
        // the page itself can't scroll sideways (overflow-x: hidden), so
        // that is taken until the edge, as in Safari.
        can = true;
        left = vv.pageLeft;
        max = (rootCanScroll() ? document.documentElement.scrollWidth : document.documentElement.clientWidth) - vv.width;
      } else if (root) {
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
