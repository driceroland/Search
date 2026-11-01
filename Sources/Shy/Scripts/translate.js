if (!Object.prototype.hasOwnProperty.call(window, '__shyTr')) (function () {
  // Left as they are, with everything in them.
  var SKIP = { script:1, style:1, noscript:1, textarea:1, input:1, select:1, option:1, code:1, pre:1,
               kbd:1, samp:1, 'var':1, svg:1, math:1, canvas:1, template:1, iframe:1, frame:1,
               object:1, embed:1, video:1, audio:1, head:1 };
  // Inline: a sentence goes on through them.
  var INLINE = { a:1, abbr:1, b:1, bdi:1, bdo:1, big:1, cite:1, data:1, del:1, dfn:1, em:1, font:1,
                 i:1, ins:1, label:1, mark:1, nobr:1, q:1, s:1, small:1, span:1, strike:1, strong:1,
                 sub:1, sup:1, time:1, tt:1, u:1, img:1, wbr:1, code:1, kbd:1, samp:1, 'var':1 };
  // Read as part of the sentence around them, never written.
  var FIXED = { code:1, kbd:1, samp:1, 'var':1 };
  var ATTRS = ['title', 'alt', 'placeholder', 'aria-label'];
  var LETTER = /\p{L}/u, SPACE = /\S/;
  var texts = new Map();      // text node -> { orig, ours, sent, kept }
  var attrs = new Map();      // element -> { name: the same }
  var units = [];             // id -> { targets }
  var watched = [], touched = [], whole = true;
  var applying = false, timer = 0;
  var run = null, out = null;

  function post(m) { try { webkit.messageHandlers.officeTranslate.postMessage(m); } catch (e) {} }
  function pending(rec, v) { return rec.ours !== v && rec.sent !== v && rec.kept !== v; }
  function closed(el) {
    if (el.getAttribute('translate') === 'no') return true;
    if (el.classList && el.classList.contains('notranslate')) return true;
    var c = el.getAttribute('contenteditable');
    return c !== null && c !== 'false';
  }
  function blockOf(n) {
    var el = n.parentNode;
    while (el && el.nodeType === 1 && INLINE[el.localName]) el = el.parentNode;
    return el;
  }
  function close() {
    if (run && run.targets.some(function (t) { return !t.fixed; })) {
      var id = units.length;
      units.push({ targets: run.targets });
      out.push({ id: id, parts: run.parts, gaps: run.gaps, fixed: run.targets.map(function (t) { return !!t.fixed; }), at: run.at });
    }
    run = null;
  }
  function part(text, target, at, block, lead) {
    if (run && (run.block !== block || run.parts.length >= 16 || run.chars + text.length > 1500)) close();
    if (!run) run = { block: block, parts: [], gaps: [], targets: [], chars: 0, space: false, at: at };
    run.gaps.push(run.parts.length > 0 && (run.space || lead));
    run.parts.push(text.trim());
    run.targets.push(target);
    run.chars += text.length;
    run.space = /\s$/.test(text);
  }
  function fixedPart(el) {
    var t = el.textContent;
    if (!SPACE.test(t)) { if (run) run.space = true; return; }
    part(t, { fixed: true }, el, blockOf(el), /^\s/.test(t));
  }
  function attributes(el) {
    var name = el.localName;
    for (var i = 0; i < ATTRS.length; i++) {
      var a = ATTRS[i];
      if (a === 'alt' && name !== 'img' && name !== 'area' && name !== 'input') continue;
      if (a === 'placeholder' && name !== 'input' && name !== 'textarea') continue;
      var v = el.getAttribute(a);
      if (!v || !LETTER.test(v)) continue;
      var map = attrs.get(el);
      if (!map) { map = {}; attrs.set(el, map); }
      var rec = map[a];
      if (rec && !pending(rec, v)) continue;
      if (!rec) { rec = map[a] = { orig: v }; } else if (rec.ours !== v) { rec.orig = v; rec.ours = null; }
      rec.kept = null; rec.sent = v;
      var id = units.length;
      units.push({ targets: [{ el: el, attr: a, rec: rec }] });
      out.push({ id: id, parts: [v.trim()], gaps: [false], fixed: [false], at: el });
    }
  }
  // An element as the walk meets it: what it says about the sentence
  // being read, and whether to go into it.
  function element(el) {
    var name = el.localName;
    if (name === 'br') { close(); return NodeFilter.FILTER_SKIP; }
    if (closed(el)) {
      if (INLINE[name]) fixedPart(el); else close();
      return NodeFilter.FILTER_REJECT;
    }
    if (el.hasAttribute('title') || el.hasAttribute('alt') || el.hasAttribute('placeholder') || el.hasAttribute('aria-label')) attributes(el);
    if (SKIP[name]) {
      if (FIXED[name]) fixedPart(el); else close();
      return NodeFilter.FILTER_REJECT;
    }
    if (el.shadowRoot) { close(); watch(el.shadowRoot); walk(el.shadowRoot); close(); }
    if (!INLINE[name]) close();
    return NodeFilter.FILTER_SKIP;
  }
  function text(n) {
    var v = n.nodeValue;
    if (!v || !SPACE.test(v)) { if (run) run.space = true; return; }
    var block = blockOf(n);
    if (!LETTER.test(v)) { part(v, { fixed: true }, n.parentNode, block, /^\s/.test(v)); return; }
    var rec = texts.get(n);
    if (rec && !pending(rec, v)) { close(); return; }
    if (!rec) { rec = { orig: v }; texts.set(n, rec); }
    else if (rec.ours !== v) { rec.orig = v; rec.ours = null; }
    rec.kept = null; rec.sent = v;
    part(v, { node: n, rec: rec }, n.parentNode, block, /^\s/.test(v));
  }
  function walk(root) {
    var doc = root.ownerDocument || root;
    var w = doc.createTreeWalker(root, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT, {
      acceptNode: function (n) { return n.nodeType === 1 ? element(n) : NodeFilter.FILTER_ACCEPT; }
    });
    for (var n = w.nextNode(); n; n = w.nextNode()) if (n.nodeType === 3) text(n);
    close();
  }
  // Whether something changed is somewhere the walk goes.
  function open(el) {
    for (var e = el; e; ) {
      if (e.nodeType === 11) { e = e.host; continue; }
      if (e.nodeType !== 1) { e = e.parentNode; continue; }
      if (SKIP[e.localName] || closed(e)) return false;
      e = e.parentNode;
    }
    return true;
  }
  function top(el) {
    if (!el || !el.getBoundingClientRect) return 1e9;
    var r = el.getBoundingClientRect();
    if (r.width === 0 && r.height === 0) return 1e8;
    return r.bottom < 0 ? 1e7 - r.bottom : r.top;
  }
  function changed(node) {
    if (!whole) touched.push(node);
    if (touched.length > 200) { whole = true; touched = []; }
    if (!timer) timer = setTimeout(function () { timer = 0; post({ dirty: 1 }); }, 300);
  }
  var observer = new MutationObserver(function (records) {
    if (applying) return;
    for (var i = 0; i < records.length; i++) {
      var r = records[i], t = r.target;
      if (r.type === 'characterData') {
        var k = texts.get(t);
        if (k && (k.ours === t.nodeValue || k.sent === t.nodeValue)) continue;
        changed(t.parentNode);
      } else if (r.type === 'attributes') {
        var m = attrs.get(t), rec = m && m[r.attributeName];
        if (rec && (rec.ours === t.getAttribute(r.attributeName) || rec.sent === t.getAttribute(r.attributeName))) continue;
        changed(t);
      } else {
        var real = false;
        for (var j = 0; j < r.addedNodes.length; j++) {
          var a = r.addedNodes[j];
          if (a.nodeType === 1 || (a.nodeType === 3 && LETTER.test(a.nodeValue))) { real = true; break; }
        }
        if (real) changed(t);
      }
    }
  });
  function watch(root) {
    if (watched.indexOf(root) >= 0) return;
    watched.push(root);
    observer.observe(root, { childList: true, subtree: true, characterData: true, attributes: true, attributeFilter: ATTRS });
  }
  window.__shyTr = {
    // Every unit not yet sent: [id, parts, gaps, fixed], on screen first.
    collect: function () {
      if (document.designMode === 'on') return [];
      out = [];
      watch(document);
      var title = window === window.top && document.querySelector('title');
      if (title && title.firstChild && title.firstChild.nodeType === 3 && LETTER.test(title.textContent)) {
        text(title.firstChild); close();
      }
      var roots = whole ? [document.body || document.documentElement] : touched;
      whole = false; touched = [];
      var seen = [];
      for (var i = 0; i < roots.length; i++) {
        var root = roots[i];
        if (!root || !root.isConnected || seen.some(function (s) { return s.contains(root); })) continue;
        if (root.nodeType === 1 && root !== document.body && !open(root)) continue;
        seen.push(root);
        if (root.nodeType === 1 && root !== document.body && root !== document.documentElement) {
          if (element(root) !== NodeFilter.FILTER_SKIP) { close(); continue; }
        }
        walk(root);
      }
      if (texts.size > 20000) texts.forEach(function (rec, node) { if (!node.isConnected) texts.delete(node); });
      var list = out; out = null;
      var tops = list.map(function (u) { return top(u.at && u.at.nodeType === 1 ? u.at : u.at && u.at.parentElement); });
      var order = list.map(function (u, i) { return i; }).sort(function (a, b) { return tops[a] - tops[b] || a - b; });
      return order.map(function (i) { var u = list[i]; return [u.id, u.parts, u.gaps, u.fixed]; });
    },
    // [id, parts or null]: each part back in its own node; null keeps
    // the unit as it is (already in your language, or can't be done).
    apply: function (pairs) {
      applying = true;
      var n = 0;
      for (var i = 0; i < pairs.length; i++) {
        var u = units[pairs[i][0]], parts = pairs[i][1];
        if (!u) continue;
        units[pairs[i][0]] = null;
        for (var j = 0; j < u.targets.length; j++) {
          var t = u.targets[j];
          if (t.fixed) continue;
          var cur = t.node ? t.node.nodeValue : t.el.getAttribute(t.attr);
          if (cur !== t.rec.sent) continue;          // changed meanwhile: the next round has it
          t.rec.sent = null;
          var p = parts && parts[j];
          if (p == null || !SPACE.test(p)) { t.rec.kept = cur; continue; }
          var o = t.rec.orig, v = o.match(/^\s*/)[0] + p.trim() + o.match(/\s*$/)[0];
          t.rec.ours = v;
          if (t.node) t.node.nodeValue = v; else t.el.setAttribute(t.attr, v);
          n++;
        }
      }
      observer.takeRecords();
      applying = false;
      return n;
    },
    // Show Original: each value back exactly as it was, where the page
    // hasn't put something else there since.
    restore: function () {
      observer.disconnect();
      clearTimeout(timer);
      var n = 0;
      texts.forEach(function (rec, node) { if (rec.ours != null && node.nodeValue === rec.ours) { node.nodeValue = rec.orig; n++; } });
      attrs.forEach(function (map, el) {
        for (var a in map) { var rec = map[a]; if (rec.ours != null && el.getAttribute(a) === rec.ours) { el.setAttribute(a, rec.orig); n++; } }
      });
      delete window.__shyTr;
      return n;
    }
  };
})();
