// Scrolling with the middle button, as on Windows: a click of the wheel on
// a page (not on a link, which it still opens in a new tab) leaves a mark
// where it was, and the page scrolls towards the pointer, faster the
// further away it is. Another click, Escape or the wheel stops it; held down
// and dragged, it stops when the button is let go.
//
// Off unless turned on in Settings › General. Done in the page, which knows
// what is under the pointer and which part of it scrolls.

enum AutoScroll {
    /// Settings › General › Scroll with the middle button.
    @MainActor static var on = false

    /// For a page already up when it is turned off.
    static let off = "window.__searchAutoScrollOff = true;"

    static let script = #"""
    (() => {
      window.__searchAutoScrollOff = false;
      if (window.__searchAutoScroll) return;
      window.__searchAutoScroll = true;
      let active = null;
      // The button whose press just stopped the scrolling. Its click is part
      // of stopping, not a click of its own: landing on a link, it would
      // follow it, or open it in a new tab for the middle button.
      let swallow = -1;

      const scroller = (el) => {
        for (; el && el !== document.body && el !== document.documentElement; el = el.parentElement) {
          const s = getComputedStyle(el);
          if (/(auto|scroll|overlay)/.test(s.overflowY + s.overflowX) &&
              (el.scrollHeight > el.clientHeight + 1 || el.scrollWidth > el.clientWidth + 1)) return el;
        }
        return document.scrollingElement || document.documentElement;
      };

      // The mark: a round badge with its arrows, in a shadow root the page's
      // own styles can't reach.
      const mark = (x, y) => {
        const host = document.createElement('div');
        host.style.cssText = 'all:initial;position:fixed;z-index:2147483647;pointer-events:none;' +
          `left:${x - 15}px;top:${y - 15}px;width:30px;height:30px;`;
        host.attachShadow({ mode: 'closed' }).innerHTML =
          '<svg viewBox="0 0 30 30" width="30" height="30" style="filter:drop-shadow(0 2px 6px rgba(0,0,0,.25))">' +
          '<circle cx="15" cy="15" r="13.5" fill="rgba(255,255,255,.94)" stroke="rgba(0,0,0,.18)"/>' +
          '<path d="M15 6.5l3.5 4.5h-7zM15 23.5l3.5-4.5h-7z" fill="rgba(0,0,0,.62)"/>' +
          '<circle cx="15" cy="15" r="1.6" fill="rgba(0,0,0,.62)"/></svg>';
        document.documentElement.appendChild(host);
        return host;
      };

      const speed = (d) => {
        const a = Math.abs(d) - 12;
        return a > 0 ? Math.sign(d) * Math.min(60, Math.pow(a / 10, 1.4)) : 0;
      };
      const tick = () => {
        if (!active) return;
        active.target.scrollBy(speed(active.dx), speed(active.dy));
        active.frame = requestAnimationFrame(tick);
      };
      const move = (e) => {
        if (!active) return;
        active.dx = e.clientX - active.x;
        active.dy = e.clientY - active.y;
      };
      const stop = () => {
        if (!active) return;
        cancelAnimationFrame(active.frame);
        active.badge.remove();
        document.documentElement.style.cursor = active.cursor;
        removeEventListener('mousemove', move, true);
        active = null;
      };

      addEventListener('mousedown', (e) => {
        swallow = -1;
        if (active) { e.preventDefault(); e.stopPropagation(); stop(); swallow = e.button; return; }
        if (e.button !== 1 || window.__searchAutoScrollOff) return;
        if (e.target.closest && e.target.closest('a[href], area[href], input, textarea, select, button, video, audio, iframe, [contenteditable=""], [contenteditable="true"]')) return;
        e.preventDefault();
        active = {
          x: e.clientX, y: e.clientY, dx: 0, dy: 0, since: performance.now(),
          target: scroller(e.target), badge: mark(e.clientX, e.clientY),
          cursor: document.documentElement.style.cursor,
        };
        document.documentElement.style.cursor = 'all-scroll';
        addEventListener('mousemove', move, true);
        active.frame = requestAnimationFrame(tick);
      }, true);
      // Held down and dragged: let go, and it stops.
      addEventListener('mouseup', (e) => {
        if (active && e.button === 1 && performance.now() - active.since > 250 &&
            (Math.abs(active.dx) > 12 || Math.abs(active.dy) > 12)) { stop(); swallow = 1; }
      }, true);
      const eat = (e) => {
        if (e.button === swallow) { swallow = -1; e.preventDefault(); e.stopPropagation(); }
        else if (e.button === 1 && active) e.preventDefault();
      };
      addEventListener('click', eat, true);
      addEventListener('auxclick', eat, true);
      addEventListener('keydown', (e) => { if (active && e.key === 'Escape') { e.preventDefault(); stop(); } }, true);
      addEventListener('wheel', stop, { capture: true, passive: true });
      addEventListener('blur', stop);
      document.addEventListener('visibilitychange', stop);
    })();
    """#
}
