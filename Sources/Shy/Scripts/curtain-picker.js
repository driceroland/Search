(function () {
  if (Object.prototype.hasOwnProperty.call(window, '__officeVeil')) return;
  var frame = null, tag = null, target = null, live = false;

  function sheet(id) {
    // A real stylesheet only: an element of the page's own under the same
    // id would take the rules in as text, and hide nothing.
    var s = document.querySelector('style#' + id);
    if (!s) {
      s = document.createElement('style');
      s.id = id;
      (document.head || document.documentElement).appendChild(s);
    }
    return s;
  }

  function chrome() {
    if (frame) return frame;
    frame = document.createElement('div');
    frame.style.cssText = 'position:fixed;z-index:2147483646;pointer-events:none;' +
      'border:2px solid rgba(23,23,23,.9);background:rgba(23,23,23,.07);' +
      'border-radius:4px;transition:all .07s ease-out;display:none';
    tag = document.createElement('div');
    tag.style.cssText = 'position:absolute;font:500 11px -apple-system,' +
      'BlinkMacSystemFont,sans-serif;color:#fff;background:#171717;padding:2px 7px;' +
      'border-radius:5px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis';
    frame.appendChild(tag);
    document.documentElement.appendChild(frame);
    return frame;
  }

  function place(el) {
    var box = chrome(), r = el.getBoundingClientRect();
    box.style.display = 'block';
    box.style.left = r.left + 'px';
    box.style.top = r.top + 'px';
    box.style.width = r.width + 'px';
    box.style.height = r.height + 'px';
    tag.textContent = name(el);
    // Above the element if there is sky above it, tucked inside its top
    // edge if there isn't — an element flush with the top of the window
    // would otherwise have its name cut off by the window.
    tag.style.top = r.top >= 26 ? '-21px' : '3px';
    // And never off the left or right edge either.
    tag.style.left = Math.max(2, -r.left + 4) + 'px';
    tag.style.maxWidth = Math.max(80, window.innerWidth - Math.max(0, r.left) - 16) + 'px';
  }

  var known = {
    nav: 'Navigation', header: 'Header', footer: 'Footer', aside: 'Sidebar',
    form: 'Form', dialog: 'Dialog', video: 'Video', img: 'Image',
    button: 'Button', iframe: 'Embed', figure: 'Figure', table: 'Table'
  };

  // What it is, in the order a person would answer the question: what it
  // calls itself, then what kind of thing it is, then what it says.
  function name(el) {
    var said = el.getAttribute && (el.getAttribute('aria-label') || el.getAttribute('title'));
    if (said && said.trim()) return clip(said.trim(), 40);
    var tagName = el.tagName.toLowerCase();
    if (known[tagName]) return known[tagName];
    var role = el.getAttribute && el.getAttribute('role');
    if (role) return role.charAt(0).toUpperCase() + role.slice(1);
    var text = (el.innerText || '').trim().replace(/\s+/g, ' ');
    return text ? clip(text, 40) : tagName;
  }

  /// How big, and which corner. Two sidebars read alike; they are rarely
  /// the same shape in the same place.
  function shape(el) {
    var r = el.getBoundingClientRect();
    var cx = r.left + r.width / 2, cy = r.top + r.height / 2;
    var side = cx < window.innerWidth / 3 ? 'left'
             : (cx > window.innerWidth * 2 / 3 ? 'right' : 'centre');
    var band = cy < window.innerHeight / 3 ? 'top'
             : (cy > window.innerHeight * 2 / 3 ? 'bottom' : 'middle');
    return Math.round(r.width) + '×' + Math.round(r.height) + ' · ' + band + ' ' + side;
  }

  function clip(text, n) { return text.length > n ? text.slice(0, n) + '…' : text; }

  // A class worth hanging a rule on: a word, not a build artefact.
  function steady(c) {
    return /^[a-zA-Z][\w-]{2,29}$/.test(c) && !/\d{3,}/.test(c) &&
           !/^(css|sc|jsx|emotion|svelte|styles?)-/.test(c);
  }

  function unique(sel) {
    try { return document.querySelectorAll(sel).length === 1; } catch (e) { return false; }
  }

  function selectorFor(el) {
    if (el.id && unique('#' + CSS.escape(el.id))) return '#' + CSS.escape(el.id);

    var hooks = ['data-testid', 'data-test', 'data-qa', 'data-cy', 'aria-label', 'name', 'role'];
    for (var i = 0; i < hooks.length; i++) {
      var v = el.getAttribute && el.getAttribute(hooks[i]);
      if (v) {
        var s = el.tagName.toLowerCase() + '[' + hooks[i] + '="' + CSS.escape(v) + '"]';
        if (unique(s)) return s;
      }
    }

    var classes = (el.className && typeof el.className === 'string')
      ? el.className.trim().split(/\s+/).filter(steady) : [];
    if (classes.length) {
      var byClass = el.tagName.toLowerCase() + '.' + classes.map(CSS.escape).join('.');
      if (unique(byClass)) return byClass;
    }

    // Last resort: a path, anchored on the nearest thing with a name.
    var parts = [], node = el;
    while (node && node.nodeType === 1 && node !== document.documentElement) {
      if (node.id && unique('#' + CSS.escape(node.id))) {
        parts.unshift('#' + CSS.escape(node.id));
        break;
      }
      var tagName = node.tagName.toLowerCase();
      var parent = node.parentElement;
      if (!parent) { parts.unshift(tagName); break; }
      var kin = Array.prototype.filter.call(parent.children, function (c) {
        return c.tagName === node.tagName;
      });
      parts.unshift(kin.length > 1
        ? tagName + ':nth-of-type(' + (kin.indexOf(node) + 1) + ')'
        : tagName);
      node = parent;
    }
    return parts.join(' > ');
  }

  function onMove(e) {
    if (!live) return;
    var el = document.elementFromPoint(e.clientX, e.clientY);
    if (!el || el === frame || el === document.documentElement || el === document.body) return;
    target = el;
    place(el);
  }

  // Everything a press can be, swallowed. Real pages act on pointerdown or
  // mousedown and are gone before a click ever completes — which looked
  // exactly like nothing happening.
  function swallow(e) {
    if (!live) return;
    e.preventDefault();
    e.stopPropagation();
    e.stopImmediatePropagation();
  }

  function onPress(e) {
    if (!live) return;
    swallow(e);
    // The pointer may have arrived without ever moving — a click on the
    // very first element under it, or a trackpad tap.
    var el = target || document.elementFromPoint(e.clientX, e.clientY);
    if (!el || el === frame || el === document.documentElement || el === document.body) return;
    try {
      window.webkit.messageHandlers.officeVeil.postMessage({
        selector: selectorFor(el),
        label: name(el),
        note: shape(el)
      });
    } catch (err) {
      window.webkit.messageHandlers.officeVeil.postMessage({ trouble: String(err) });
    }
    target = null;
    if (frame) frame.style.display = 'none';
  }

  var presses = ['pointerdown', 'mousedown', 'pointerup', 'mouseup', 'click',
                 'dblclick', 'contextmenu', 'touchstart'];

  window.__officeVeil = {
    on: function () {
      if (live) return;
      live = true;
      chrome();
      document.documentElement.style.cursor = 'crosshair';
      document.addEventListener('mousemove', onMove, true);
      document.addEventListener('pointermove', onMove, true);
      presses.forEach(function (kind) {
        document.addEventListener(kind, kind === 'pointerdown' ? onPress : swallow, true);
      });
    },
    off: function () {
      if (!live) return;
      live = false;
      target = null;
      if (frame) frame.style.display = 'none';
      document.documentElement.style.cursor = '';
      document.removeEventListener('mousemove', onMove, true);
      document.removeEventListener('pointermove', onMove, true);
      presses.forEach(function (kind) {
        document.removeEventListener(kind, kind === 'pointerdown' ? onPress : swallow, true);
      });
      window.webkit.messageHandlers.officeVeil.postMessage({ off: true });
    },
    // Show one hidden thing for as long as the pointer rests on its row.
    // The stylesheet is rebuilt without that one selector rather than
    // fighting it with another rule, so the element comes back with the
    // layout it actually had.
    peek: function (css, sel) {
      sheet('office-veil').textContent = css;
      sheet('office-peek').textContent = sel +
        ' { outline: 2px solid rgba(23,23,23,.9) !important; outline-offset: 2px !important; }';
      try {
        var el = document.querySelector(sel);
        if (el) el.scrollIntoView({ block: 'center', behavior: 'smooth' });
      } catch (e) {}
    },
    unpeek: function (css) {
      sheet('office-veil').textContent = css;
      sheet('office-peek').textContent = '';
    }
  };
})();
