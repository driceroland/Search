import Foundation

// A paused tab gives the media keys back (#512).
//
// As soon as a page plays sound, WebKit makes the app the Mac's Now Playing
// app: the play/pause keys, and a tap on AirPods, come here. It keeps that
// after the video is paused, for good, so a tab paused and forgotten took the
// keys from Spotify or Music until they played something again. WebKit has no
// setting for it. What it does go by is whether the media could be heard: a
// muted element is never the Now Playing one, and with none left the Mac
// hands the keys back to the app before.
//
// So a video or a sound paused for a while is muted, which a paused one can't
// be heard to be anyway, and unmuted again before it plays, by the page or by
// a click on its controls. The page never sees it: `muted` reads back what the
// page set, and the volume change it would hear is stopped first. A page that
// muted it itself keeps it muted. Paused a moment, as with the play/pause key
// pressed twice, it stays the Now Playing one, so the second press resumes it.
//
// While something is playing, the keys are WebKit's to give, and stay here.
// A page that added its own volume listener to a loose element (new Audio())
// before playing it, or to one in a shadow root, can hear a volume change
// when it is given back; it reads nothing changed.

enum MediaKeys {
    /// In the page's own world, before any of its scripts, in every frame: the
    /// page reads `muted` and calls `play()` through these very properties.
    static let script = """
    (function () {
      var proto = HTMLMediaElement.prototype;
      var plain = Object.getOwnPropertyDescriptor(proto, 'muted');
      var plainPlay = Object.getOwnPropertyDescriptor(proto, 'play');
      if (!plain || !plain.get || !plain.set || !plainPlay || typeof plainPlay.value !== 'function') return;
      // How long a pause keeps the keys here, in milliseconds.
      var keep = 10000;
      // Muted by this script, with what the page last set itself; the timers
      // counting a pause down; how many of our own volume changes are still
      // to come, to be stopped before the page hears them.
      var hushed = new WeakMap(), timers = new WeakMap(), quiet = new WeakMap(), watched = new WeakSet();
      function still(el) { quiet.set(el, (quiet.get(el) || 0) + 1) }
      function hush(el) {
        timers.delete(el);
        if (!el.paused || hushed.has(el) || plain.get.call(el)) return;
        // Out of the page, its volume change passes no window: only one
        // watched itself is muted, so the page never hears it.
        if (!el.isConnected && !watched.has(el)) return;
        hushed.set(el, false);
        still(el); plain.set.call(el, true);
      }
      function wake(el) {
        clearTimeout(timers.get(el)); timers.delete(el);
        if (!hushed.has(el)) return;
        var wants = hushed.get(el);
        hushed.delete(el);
        if (!wants && plain.get.call(el)) { still(el); plain.set.call(el, false); }
      }
      function paused(el) {
        clearTimeout(timers.get(el));
        timers.set(el, setTimeout(function () { hush(el) }, keep));
      }
      function hide(e) {
        var el = e.target, n = quiet.get(el);
        if (n) {
          if (n > 1) quiet.set(el, n - 1); else quiet.delete(el);
          e.stopImmediatePropagation();
          return;
        }
        // Unmuted some other way while given back (the video's own
        // controls, which read the real value): that answer wins.
        if (el instanceof HTMLMediaElement && hushed.has(el) && !plain.get.call(el)) hushed.delete(el);
      }
      // Media events don't bubble, but they pass the window on the way down
      // to an element in the page, ahead of any listener the page adds.
      addEventListener('pause', function (e) {
        if (e.target instanceof HTMLMediaElement) paused(e.target);
      }, true);
      addEventListener('play', function (e) {
        if (e.target instanceof HTMLMediaElement) wake(e.target);
      }, true);
      addEventListener('volumechange', hide, true);
      // One the window never sees, out of the page (new Audio()) or inside a
      // shadow root, is watched itself from the first time it plays. Twice
      // over is no harm: what the window's listener takes, it stops.
      function watch(el) {
        if (watched.has(el)) return;
        watched.add(el);
        el.addEventListener('pause', function () { paused(el) });
        el.addEventListener('play', function () { wake(el) });
        el.addEventListener('volumechange', hide);
      }
      var own = {
        get muted() { return hushed.has(this) ? hushed.get(this) : plain.get.call(this) },
        set muted(value) {
          // Given back: the page's answer is kept for when it plays, and a
          // change it makes is heard as WebKit would tell it, a moment later
          // and only when something changed.
          if (hushed.has(this)) {
            var el = this, was = hushed.get(el), now = !!value;
            hushed.set(el, now);
            if (was !== now) setTimeout(function () { el.dispatchEvent(new Event('volumechange')) }, 0);
            return;
          }
          plain.set.call(this, value);
        },
        play() {
          // Its sound back first, so it starts as it would have.
          watch(this); wake(this);
          var started = plainPlay.value.apply(this, arguments);
          // Refused (no click yet): still paused, so it counts down again.
          if (this.paused) paused(this);
          return started;
        }
      };
      var made = Object.getOwnPropertyDescriptor(own, 'muted');
      try {
        Object.defineProperty(proto, 'muted', {
          get: made.get, set: made.set, enumerable: plain.enumerable, configurable: true
        });
        Object.defineProperty(proto, 'play', {
          value: own.play, writable: plainPlay.writable, enumerable: plainPlay.enumerable, configurable: true
        });
      } catch (e) {}
    })();
    """
}
