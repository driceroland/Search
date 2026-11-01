(function () {
  if (Object.prototype.hasOwnProperty.call(window, '__officeImages')) return;
  window.__officeImages = true;
  document.addEventListener('contextmenu', function (e) {
    // A right-click of yours only: a page can dispatch one itself, and
    // would open this menu whenever it liked — under your next click.
    if (!e.isTrusted) return;
    var el = e.target;
    while (el && el.tagName !== 'IMG') el = el.parentElement;
    if (!el || !el.currentSrc || el.naturalWidth < 2) return;
    // Only an address this menu will act on takes WebKit's own menu
    // away; any other scheme keeps it, rather than getting nothing.
    if (!/^(https?|data|blob):/i.test(el.currentSrc)) return;
    // WebKit's own menu only steps aside when there is a way to ask for
    // this one — otherwise a right-click shows nothing at all.
    var relay = window.webkit && webkit.messageHandlers && webkit.messageHandlers.officeImages;
    if (!relay) return;
    e.preventDefault();
    relay.postMessage({ src: el.currentSrc });
  }, true);
})();
