(function () {
  if (Object.prototype.hasOwnProperty.call(window, '__officeMedia')) return;
  // Played here at some point: only these were ever the Now Playing one.
  // Held: muted here, to be unmuted when they play.
  var played = new WeakSet(), held = new WeakSet(), watched = new WeakSet(), told = false;
  function plays(e) {
    // Only the element's own play counts: a page's synthetic 'play'
    // event neither marks it as played nor unmutes what Shy holds.
    if (!e.isTrusted) return;
    var el = e.target;
    played.add(el);
    if (held.has(el)) { held.delete(el); el.muted = false; }
  }
  function changed(e) {
    // Unmuted by the page, or its controls, while held: theirs wins.
    if (held.has(e.target) && !e.target.muted) held.delete(e.target);
  }
  window.__officeMedia = function () {
    document.querySelectorAll('audio, video').forEach(function (el) {
      if (!el.paused || el.muted || held.has(el) || !played.has(el)) return;
      held.add(el);
      // Its own ears too: taken out of the page, or the page's listeners
      // wiped by document.open(), it still hears its play.
      if (!watched.has(el)) {
        watched.add(el);
        el.addEventListener('play', plays, true);
        el.addEventListener('volumechange', changed, true);
      }
      el.muted = true;
    });
  };
  document.addEventListener('play', function (e) {
    if (!e.isTrusted) return;
    plays(e);
    // A frame below the page says once that it plays, to be looked in.
    if (!told && window.top !== window) {
      told = true;
      var relay = window.webkit && webkit.messageHandlers && webkit.messageHandlers.officeMedia;
      if (relay) relay.postMessage('plays');
    }
  }, true);
  document.addEventListener('volumechange', changed, true);
})();
