(function () {
  if (Object.prototype.hasOwnProperty.call(window, '__officeMiddle')) return;
  window.__officeMiddle = true;
  // Heard on the way down, before the page's own handlers, since some
  // stop the event there — YouTube's links did, and a middle-click on
  // them opened nothing, only some of the time. Whether the page wanted
  // the click for itself is asked once they have all run: a page that
  // prevented it keeps it, as in Chrome.
  // The link is found now: once the event is over its path is empty.
  window.addEventListener('auxclick', function (e) {
    if (e.button !== 1 || !e.isTrusted) return;
    var href = link(e);
    if (!href) return;
    setTimeout(function () {
      if (!e.defaultPrevented) window.webkit.messageHandlers.officeMiddle.postMessage({ href: href });
    }, 0);
  }, true);
  // A page on this Mac linking to another file. WebKit lets a file page
  // read only its own folder, and drops a click on a link out of it
  // before Shy is asked: the page stayed where it was, and only the
  // address typed in opened it. Shy opens it the way it opens a typed
  // one. A plain click the page hasn't claimed, to a file, not a jump
  // within the page and not a download.
  if (location.protocol === 'file:') window.addEventListener('click', function (e) {
    if (e.button !== 0 || !e.isTrusted || e.defaultPrevented) return;
    if (e.metaKey || e.ctrlKey || e.altKey || e.shiftKey) return;
    var a = anchor(e);
    if (!a || a.hasAttribute('download')) return;
    var target = (a.getAttribute('target') || '').toLowerCase();
    if (['', '_self', '_top', '_parent', '_blank'].indexOf(target) < 0) return;
    var href = a.href;
    if (typeof href !== 'string' || href.indexOf('file:') !== 0) return;
    if (href.split('#')[0] === location.href.split('#')[0]) return;
    e.preventDefault();
    window.webkit.messageHandlers.officeMiddle.postMessage({ file: href, blank: target === '_blank' });
  }, false);
  function anchor(e) {
    var path = e.composedPath();
    for (var i = 0; i < path.length; i++) {
      var tag = path[i].tagName ? path[i].tagName.toLowerCase() : '';
      if (tag === 'a' || tag === 'area') return path[i];
    }
    return null;
  }
  function link(e) {
    // The path, not the parents: a link inside an open shadow root is
    // on it too. An <area> of an image map is a link, and so is an SVG
    // <a>, whose href is an object that holds the address as written.
    var path = e.composedPath();
    for (var i = 0; i < path.length; i++) {
      var el = path[i];
      var tag = el.tagName ? el.tagName.toLowerCase() : '';
      if (tag !== 'a' && tag !== 'area') continue;
      var href = el.href;
      if (href && typeof href === 'object') {
        try { href = href.baseVal ? new URL(href.baseVal, el.baseURI).href : ''; } catch (_) { href = ''; }
      }
      if (!href) continue;
      return href;
    }
    return '';
  }
})();
