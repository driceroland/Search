import Foundation

// Full screen in the window: a page's full screen fills the browser's
// window, not the whole screen (Settings › Videos › Keep full screen in the
// window). Off unless turned on: then the page goes to WebKit's own window
// and macOS full screen, as in Safari.
//
// WebKit has no way of its own to do this. So, with the setting on, every
// frame of a page gets, in the page's own world and ahead of its scripts, a
// Fullscreen API of Search's: requestFullscreen and the webkit- names,
// exitFullscreen, document.fullscreenElement, fullscreenchange, and a
// video's webkitEnterFullscreen. The element asked for is put in the top
// layer (as a manual popover, which WebKit lays out above everything and
// out of any ancestor's transform or overflow) and stretched over the
// viewport; the window then takes its chrome away as it always did for a
// page filling the screen (Tab.immersed, said by the page's fullscreenchange
// in FormRelay.script), so the viewport is the whole window.
//
// A frame's full screen goes up to its parent, which fills the window with
// that iframe, and on up to the top. Esc, ⌃Tab, ⌘T and ⌘1–⌘9 leave, as
// they leave WebKit's. As WebKit asks, it takes a click or a key: without
// one the request is refused, and the window's chrome only steps aside for
// a page that was clicked (see `immersed()` in FormRelay.script).
//
// What is left to WebKit: the full-screen button of a video showing the
// browser's own controls, which WebKit's controls press in a world of
// their own, and a site's `:fullscreen` styles, which match only WebKit's.

enum PageFullScreen {
    /// Settings › Videos › Keep full screen in the window.
    @MainActor static var inWindow = false

    /// A page's full screen ended, WebKit's or Search's, from Search's world.
    static let leave = """
    if (document.fullscreenElement) document.exitFullscreen();
    document.dispatchEvent(new Event('__searchleavefullscreen'));
    void 0
    """

    /// In the page's own world, in every frame, before any of its scripts.
    static let script = #"""
    (function () {
      if (window.__searchInWindowFullscreen) return;
      window.__searchInWindowFullscreen = true;
      var D = Document.prototype, E = Element.prototype;
      var V = window.HTMLVideoElement && HTMLVideoElement.prototype;
      var S = window.ShadowRoot && ShadowRoot.prototype;
      var MARK = 'data-search-fullscreen', ROOT = 'data-search-fullscreen-root';
      var KIND = '__searchFullscreen';
      var framed = window !== window.top;
      // This document's full-screen element, and how it got there.
      var current = null, presented = false, popped = false, hadPopover = null;
      var sheet = null, kept = null, watch = null;

      function rules() {
        return '[' + MARK + '] {' +
          ' position: fixed !important; inset: 0 !important;' +
          ' width: 100% !important; height: 100% !important;' +
          ' min-width: 0 !important; min-height: 0 !important;' +
          ' max-width: none !important; max-height: none !important;' +
          ' margin: 0 !important; box-sizing: border-box !important;' +
          ' transform: none !important; translate: none !important;' +
          ' scale: none !important; rotate: none !important;' +
          ' z-index: 2147483647 !important; object-fit: contain; }' +
          'iframe[' + MARK + '] { border: 0 !important; }' +
          'video[' + MARK + '] { background: black; }' +
          '[' + MARK + ']::backdrop { background: black; }' +
          'html[' + ROOT + '] { overflow: hidden !important; }';
      }
      function style() {
        if (sheet && sheet.isConnected) return;
        sheet = document.createElement('style');
        sheet.textContent = rules();
        (document.head || document.documentElement).appendChild(sheet);
      }

      // What being a popover would change of the element's own look, kept as
      // it was: below every rule of the site's, above the browser's own.
      function keep(el) {
        var was = getComputedStyle(el), props = [
          'border-top', 'border-right', 'border-bottom', 'border-left',
          'padding', 'overflow', 'color', 'background-color'];
        var text = props.map(function (p) { return p + ': ' + was.getPropertyValue(p); }).join('; ');
        kept = document.createElement('style');
        kept.textContent = ':where([' + MARK + ']) { ' + text + ' }';
        (document.head || document.documentElement).appendChild(kept);
      }

      function lift(el) {
        popped = false;
        if (!(el instanceof HTMLElement) || typeof el.showPopover !== 'function') return;
        hadPopover = el.getAttribute('popover');
        try {
          if (hadPopover === null) el.setAttribute('popover', 'manual');
          el.showPopover();
          popped = true;
        } catch (e) {
          if (hadPopover === null) el.removeAttribute('popover');
        }
      }
      function lower(el) {
        if (!popped) return;
        popped = false;
        try { el.hidePopover(); } catch (e) {}
        if (hadPopover === null) el.removeAttribute('popover');
      }

      function fire(el, video, entering) {
        var target = el.isConnected ? el : document;
        ['fullscreenchange', 'webkitfullscreenchange'].forEach(function (type) {
          target.dispatchEvent(new Event(type, { bubbles: true, composed: true }));
        });
        if (video) el.dispatchEvent(new Event(entering ? 'webkitbeginfullscreen' : 'webkitendfullscreen', { bubbles: true }));
      }

      function enter(el, video) {
        if (current === el) return;
        if (current) leave(false, true);
        current = el;
        presented = !!video;
        style();
        keep(el);
        el.setAttribute(MARK, '');
        document.documentElement.setAttribute(ROOT, '');
        lift(el);
        // Taken out of the page: its full screen ends, as WebKit's does.
        watch = new MutationObserver(function () { if (current && !current.isConnected) leave(true); });
        watch.observe(document, { childList: true, subtree: true });
        if (framed) window.parent.postMessage({ __searchFullscreen: 'enter' }, '*');
        setTimeout(function () { fire(el, presented, true); }, 0);
      }

      // `up`: say so to the frame above. `quiet`: no events, another element
      // is taking its place.
      function leave(up, quiet) {
        var el = current;
        if (!el) return;
        var video = presented;
        current = null;
        presented = false;
        if (watch) { watch.disconnect(); watch = null; }
        lower(el);
        el.removeAttribute(MARK);
        if (kept) { kept.remove(); kept = null; }
        if (!quiet) document.documentElement.removeAttribute(ROOT);
        // An iframe filling the window: the frame in it ends too.
        if (el instanceof HTMLIFrameElement && el.contentWindow) {
          try { el.contentWindow.postMessage({ __searchFullscreen: 'exit' }, '*'); } catch (e) {}
        }
        if (up && framed) window.parent.postMessage({ __searchFullscreen: 'exit' }, '*');
        if (!quiet) setTimeout(function () { fire(el, video, false); }, 0);
      }

      function clicked() {
        var ua = navigator.userActivation;
        return !ua || ua.isActive;
      }

      function request(el, video) {
        if (!(el instanceof Element) || !el.isConnected || !clicked()) {
          setTimeout(function () {
            document.dispatchEvent(new Event('fullscreenerror', { bubbles: true }));
            document.dispatchEvent(new Event('webkitfullscreenerror', { bubbles: true }));
          }, 0);
          return Promise.reject(new TypeError('Type error'));
        }
        enter(el, video);
        return new Promise(function (resolve) { setTimeout(resolve, 0); });
      }
      function exit() {
        if (!current) return Promise.reject(new TypeError('Not in fullscreen'));
        leave(true);
        return new Promise(function (resolve) { setTimeout(resolve, 0); });
      }

      // The element as this document or shadow root sees it: a full screen
      // inside a shadow tree is its host, from outside.
      function seen(scope) {
        var node = current;
        while (node) {
          var root = node.getRootNode();
          if (root === scope) return node;
          node = root instanceof ShadowRoot ? root.host : null;
        }
        return null;
      }

      function method(proto, name, fn) {
        if (!proto) return;
        try { Object.defineProperty(proto, name, { value: fn, writable: true, configurable: true, enumerable: true }); } catch (e) {}
      }
      function getter(proto, name, fn) {
        if (!proto) return;
        try { Object.defineProperty(proto, name, { get: fn, configurable: true, enumerable: true }); } catch (e) {}
      }

      method(E, 'requestFullscreen', function () { return request(this, false); });
      method(E, 'webkitRequestFullscreen', function () { request(this, false).catch(function () {}); });
      method(E, 'webkitRequestFullScreen', function () { request(this, false).catch(function () {}); });
      method(D, 'exitFullscreen', function () { return exit(); });
      method(D, 'webkitExitFullscreen', function () { exit().catch(function () {}); });
      method(D, 'webkitCancelFullScreen', function () { exit().catch(function () {}); });
      getter(D, 'fullscreenElement', function () { return seen(this); });
      getter(D, 'webkitFullscreenElement', function () { return seen(this); });
      getter(D, 'webkitCurrentFullScreenElement', function () { return seen(this); });
      getter(D, 'fullscreen', function () { return !!current; });
      getter(D, 'webkitIsFullScreen', function () { return !!current; });
      getter(D, 'fullscreenEnabled', function () { return true; });
      getter(D, 'webkitFullscreenEnabled', function () { return true; });
      getter(S, 'fullscreenElement', function () { return seen(this); });
      if (V) {
        method(V, 'webkitEnterFullscreen', function () { request(this, true).catch(function () {}); });
        method(V, 'webkitEnterFullScreen', function () { request(this, true).catch(function () {}); });
        method(V, 'webkitExitFullscreen', function () { if (current === this) leave(true); });
        method(V, 'webkitExitFullScreen', function () { if (current === this) leave(true); });
        getter(V, 'webkitDisplayingFullscreen', function () { return current === this; });
      }

      // Frames: a child's full screen fills this document with its iframe;
      // a parent's ending ends the child's.
      window.addEventListener('message', function (e) {
        var data = e.data;
        if (!data || typeof data !== 'object' || !(KIND in data)) return;
        if (e.source === window.parent && framed) {
          if (data[KIND] === 'exit' && current) leave(false);
          return;
        }
        var frame = null;
        var frames = document.querySelectorAll('iframe, frame');
        for (var i = 0; i < frames.length; i++) {
          if (frames[i].contentWindow === e.source) { frame = frames[i]; break; }
        }
        if (!frame) return;
        if (data[KIND] === 'enter') {
          var allowed = frame.allowFullscreen || frame.hasAttribute('allowfullscreen') ||
            frame.hasAttribute('webkitallowfullscreen') || /(^|;)\s*fullscreen\b(?!\s+'none')/.test(frame.allow || '');
          // The click that asked counts here too: a frame's activation is
          // its parents' as well.
          if (allowed && clicked()) enter(frame, false);
          else e.source.postMessage({ __searchFullscreen: 'exit' }, '*');
        } else if (data[KIND] === 'exit' && current === frame) {
          leave(true);
        }
      });

      // Esc leaves, as WebKit's does, before the page sees it.
      window.addEventListener('keydown', function (e) {
        if (!current || e.key !== 'Escape') return;
        e.preventDefault();
        e.stopImmediatePropagation();
        leave(true);
      }, true);

      // Search's word, from its own world (PageFullScreen.leave).
      document.addEventListener('__searchleavefullscreen', function () { leave(true); });
    })();
    """#
}
