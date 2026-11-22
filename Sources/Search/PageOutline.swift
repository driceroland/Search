import Foundation

// The page as an outline, for bench-mcp's outline_page, read_section and
// find_in_page: a small page whole, a big one as what needs attention and
// then its sections with their size and first words, so an agent reads a
// few hundred bytes where read_page gives tens of thousands, and opens
// only the part it needs.
//
// One pass over the rendered page each time it is asked, in Search's own
// world, and nothing left running after. It only reads. The controls it
// prints are kept under the same key as read_page's, as one read: touch
// works on them, and the next read of either kind ends them. A secret
// field's value never leaves the page (the shared `secret`), and a
// frame's inside is not read, as read_page doesn't read one.
//
// The page becomes a tree of sections. A section is a landmark (nav, main,
// a form, a dialog…), a heading and what follows it up to the next heading
// as high, or a list: five or more siblings shaped alike (stories,
// results, comments) folded into one line until it is opened. Each has an
// id made from its words (§pricing), so it is found again after the page
// moves.
extension PageScripts {
    /// options: mode ("see", "read" or "seek"), open (section ids), want
    /// (words), most (lines), depth (levels opened), chars (read's budget),
    /// mark (what brackets an element's number in the text, for the caller
    /// to turn into a handle; the page can't know it).
    static func outline(key: String, snap: Int, options: [String: Any]) -> String {
        call(outlineBody, [key, snap, options])
    }

    private static let outlineBody = #"""
    (function (key, snap, o) {
      'use strict';
      var mode = o.mode || 'see';
      var most = Math.max(1, o.most || 60), depth = Math.max(1, o.depth || 1);
      var want = String(o.want || '').toLowerCase().trim();
      var open_ = (o.open || []).map(function (s) { return String(s).replace(/^§/, ''); });
      var mark = String(o.mark || '');
      // Words match from the start of a word: "search" finds Search and
      // searched, not research.
      var wantRe = want ? new RegExp('(^|[^\\p{L}\\p{N}])' + want.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'iu') : null;
      function has(t) { return !!wantRe && wantRe.test(String(t || '')); }
      var high = innerHeight, wide = innerWidth;
      var PRESS = 'a[href],button,input:not([type=hidden]),select,textarea,summary,[contenteditable=""],[contenteditable=true],' +
        '[role=button],[role=link],[role=tab],[role=menuitem],[role=checkbox],[role=radio],[role=switch],[role=textbox],' +
        '[role=combobox],[role=option],[role=slider]';
      var TAGS = { HEADER: 'banner', NAV: 'nav', MAIN: 'main', ASIDE: 'aside', FOOTER: 'footer', FORM: 'form', DIALOG: 'dialog', SEARCH: 'search' };
      var LANDS = { banner: 'banner', navigation: 'nav', main: 'main', complementary: 'aside', contentinfo: 'footer',
        form: 'form', search: 'search', dialog: 'dialog', alertdialog: 'dialog', region: 'region' };
      var BLOCK = /^(P|DIV|LI|TR|TD|TH|DD|DT|SECTION|ARTICLE|BLOCKQUOTE|PRE|FIGCAPTION|BR|HR|TABLE|UL|OL|DL|FORM|HEADER|FOOTER|NAV|ASIDE|MAIN)$/;
      var SKIP = /^(SCRIPT|STYLE|NOSCRIPT|TEMPLATE|HEAD|META|LINK)$/;
      var LIMIT = 60000, visited = 0;

      // Cut short without splitting a character in two: half of one is a
      // string WebKit won't hand back.
      function trim(t, n) {
        if (t.length <= n) return t;
        t = t.slice(0, n - 1);
        return (/[\uD800-\uDBFF]$/.test(t) ? t.slice(0, -1) : t) + '…';
      }
      // The mark's characters never come from the page.
      function flat(t) { return String(t == null ? '' : t).replace(/[\u0001\u0002]/g, '').replace(/\s+/g, ' ').trim(); }
      function cut(t, n) { return trim(flat(t), n || 70); }
      function count(t) { var m = t.match(/\S+/g); return m ? m.length : 0; }
      function slug(t) {
        var s = flat(t).toLowerCase().normalize('NFKD').replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '');
        return s.slice(0, 24).replace(/-+$/, '');
      }

      // An icon drawn from a font of ligatures: its words are the icon's
      // name ("chevron_right"), not anything the page says.
      var ICON = '.material-icons,.material-icons-outlined,.material-icons-round,.material-icons-sharp,.material-symbols-outlined,' +
        '.material-symbols-rounded,.material-symbols-sharp,.google-material-icons,.google-symbols,mat-icon';
      function icon(el) { return el.matches && el.matches(ICON) && /^[a-z0-9_]+$/.test(flat(el.textContent)); }
      function textOf(el) {
        if (!el.querySelector || !el.querySelector(ICON)) return el.innerText;
        var copy = el.cloneNode(true);
        Array.prototype.forEach.call(copy.querySelectorAll(ICON), function (i) { if (icon(i)) i.remove(); });
        return flat(copy.textContent) || el.innerText;
      }
      function choice(el) {
        var r = el.getAttribute('role');
        return (el.tagName === 'INPUT' && /^(checkbox|radio)$/.test(el.type)) || r === 'checkbox' || r === 'radio';
      }
      function called(el) {
        var t = el.getAttribute('aria-label');
        var by = el.getAttribute('aria-labelledby');
        if (!t && by) t = by.split(/\s+/).map(function (i) { var e = document.getElementById(i); return e ? e.innerText : ''; }).join(' ');
        if (!t && el.labels && el.labels.length) t = textOf(el.labels[0]);
        if (!t && el.tagName === 'INPUT' && /^(submit|button|reset)$/i.test(el.type)) t = el.value;
        if (!t && !/^(INPUT|SELECT|TEXTAREA)$/.test(el.tagName)) t = textOf(el);
        var img = !flat(t) && el.querySelector && el.querySelector('img[alt]');
        return cut(t || el.getAttribute('placeholder') || el.getAttribute('title') || el.getAttribute('alt') || (img && img.alt) || el.getAttribute('name'));
      }

      // The choices asked together, and what they answer: a radiogroup or
      // fieldset by its own name, or else the nearest element around them
      // that also holds the words of a question.
      function group(el) {
        var g = el.closest('[role=radiogroup],[role=group],fieldset');
        if (g) return g;
        var sel = el.type === 'radio' || el.getAttribute('role') === 'radio' ? 'input[type=radio],[role=radio]' : 'input[type=checkbox],[role=checkbox]';
        for (var up = el.parentElement, i = 0; up && i < 6; up = up.parentElement, i++) {
          if (up.querySelectorAll(sel).length > 1) return up;
        }
        return null;
      }
      var questions = [];
      function question(el) {
        var g = group(el);
        if (!g) return null;
        for (var k = 0; k < questions.length; k++) if (questions[k].g === g) return questions[k].text ? questions[k] : null;
        var q = g.getAttribute('aria-label') || '';
        var by = g.getAttribute('aria-labelledby');
        if (!q && by) q = by.split(/\s+/).map(function (i) { var e = document.getElementById(i); return e ? e.innerText : ''; }).join(' ');
        if (!q && g.tagName === 'FIELDSET' && g.querySelector('legend')) q = g.querySelector('legend').innerText;
        for (var up = g, i = 0; !flat(q) && up && i < 5; up = up.parentElement, i++) {
          var asked = (up.innerText || '').split('\n').filter(function (l) { return /\?\s*$/.test(l); });
          if (asked.length) q = asked[asked.length > 1 && up !== g ? 0 : asked.length - 1];
        }
        var found = { g: g, text: cut(q, 110) };
        questions.push(found);
        return found.text ? found : null;
      }
      function kind(el) {
        var r = el.getAttribute('role');
        if (r) return r;
        var tag = el.tagName.toLowerCase();
        if (tag === 'a') return 'link';
        if (tag === 'input') {
          return { checkbox: 'checkbox', radio: 'radio', submit: 'button', button: 'button', reset: 'button', image: 'button',
            range: 'slider', file: 'file', search: 'searchbox' }[(el.type || '').toLowerCase()] || 'textbox';
        }
        if (tag === 'textarea' || el.isContentEditable) return 'textbox';
        if (tag === 'summary') return 'button';
        return tag;
      }
      function family(k) {
        return k === 'link' ? 'links' : /^(textbox|searchbox|select|checkbox|radio|slider|file|combobox|switch)$/.test(k) ? 'fields' : 'buttons';
      }

      // The controls printed, numbered in the order printed: the element
      // list touch works on.
      var printed = [];
      function ref(el) {
        var at = printed.indexOf(el);
        if (at < 0) { at = printed.length; printed.push(el); }
        return '[\u0001' + mark + at + '\u0002]';
      }
      function where(el) {
        var r = el.getBoundingClientRect();
        return r.bottom < 0 ? ' ↑' : r.top > high ? ' ↓' : '';
      }
      function control(el) {
        var k = kind(el), line = ref(el) + ' ' + k + ' "' + called(el) + '"';
        if (/^(INPUT|TEXTAREA|SELECT)$/.test(el.tagName) && !/^(checkbox|radio|submit|button|reset|image)$/i.test(el.type || '')) {
          if (secret(el)) line += el.value ? ' (secret, filled)' : ' (secret, empty)';
          else line += ' =' + JSON.stringify(cut(el.value, 40));
        }
        if (el.checked || el.getAttribute('aria-checked') === 'true' || el.getAttribute('aria-selected') === 'true') line += ' checked';
        if (el.getAttribute('aria-expanded') === 'false') line += ' collapsed';
        if (el.disabled || el.getAttribute('aria-disabled') === 'true') line += ' disabled';
        if (el.tagName === 'A') {
          var to = el.href;
          if (to.indexOf(location.origin) === 0) to = to.slice(location.origin.length);
          line += ' → ' + trim(flat(to), 60);
        }
        return line + where(el);
      }

      // Whether an element has a box on the page: 1 yes, 0 no, 2 for one
      // laid out as display:contents, which has none of its own while its
      // children do. As read_page counts it: see-through is not shown.
      function shown(el) {
        if (el.checkVisibility ? el.checkVisibility({ checkOpacity: true, checkVisibilityCSS: true }) : el.getClientRects().length) return 1;
        return getComputedStyle(el).display === 'contents' ? 2 : 0;
      }

      // ---- the tree

      var ids = { page: 1 };
      function node(type, label, el, level) {
        return { type: type, label: label, el: el, level: level || 0, kids: [], controls: [], text: [], chars: 0,
          words: 0, links: 0, buttons: 0, fields: 0, hidden: 0, collapsed: 0, rows: 0, preview: '', prose: '', samples: [], id: '' };
      }
      var root = node('page', document.title, document.body);
      root.id = 'page';
      var stack = [root];
      function top() { return stack[stack.length - 1]; }
      function adopt(n, base, under) {
        var s = slug(base) || n.type;
        if (ids[s]) { ids[s]++; s += '-' + ids[s]; } else ids[s] = 1;
        n.id = s;
        (under || top()).kids.push(n);
      }
      // A landmark is part of the page or of the landmark around it, never
      // of the heading before it: the footer after the last h2 isn't its.
      function outer() {
        for (var i = stack.length - 1; i > 0; i--) if (stack[i].type !== 'heading') return stack[i];
        return root;
      }
      function say(n, t) {
        if (n.chars < 20000) { n.text.push(t); n.chars += t.length; }
      }

      var attention = [], overlays = [], matches = [];

      // Five or more element children shaped alike (the same tag and first
      // class) that are at least a quarter of them. A row can be more than
      // one element: Hacker News gives each story three table rows. The
      // row starts at the shape that names itself (a class over none) and
      // runs to the next one.
      function shape(k) { return k.tagName + '.' + (k.classList[0] || ''); }
      function listy(el) {
        var kids = el.children;
        // A paragraph full of links is writing, whatever its links say.
        if (kids.length < 5 || /^(P|SELECT|DATALIST|svg)$/.test(el.tagName)) return null;
        var seen = {}, order = [], top_ = 0, paragraphs = 0;
        for (var i = 0; i < kids.length; i++) {
          if (SKIP.test(kids[i].tagName) || shown(kids[i]) !== 1) continue;
          var s = shape(kids[i]);
          // Paragraphs are writing, not rows; a landmark (a named section)
          // is a part of the page.
          if (kids[i].tagName === 'P') { paragraphs++; continue; }
          if (landmark(kids[i])) continue;
          if (!seen[s]) { seen[s] = 0; order.push(s); }
          if (++seen[s] > top_) top_ = seen[s];
        }
        // As many paragraphs as rows, and the rows are an article's parts
        // (a heading's wrapper, a figure) between its writing: sections.
        if (top_ < 5 || top_ < kids.length / 4 || paragraphs >= top_) return null;
        var near = order.filter(function (s) { return seen[s] >= 5 && seen[s] >= top_ * 0.8; });
        return near.filter(function (s) { return !/\.$/.test(s); })[0] || near[0];
      }
      // A list is called what its element is: its label, its id, or its
      // most particular class (the longest).
      function listName(el) {
        function specific(e) {
          return e ? Array.prototype.reduce.call(e.classList, function (a, c) { return c.length > a.length ? c : a; }, '') : '';
        }
        var p = el.parentElement;
        return el.getAttribute('aria-label') || el.id || specific(el) || (p && (p.id || specific(p))) || '';
      }

      function landmark(el) {
        var r = el.getAttribute('role');
        var t = r ? LANDS[r] : TAGS[el.tagName];
        if (!t && el.tagName === 'SECTION') t = 'region';
        if (!t) return null;
        // A region only with a name, a form only with somewhere to type.
        if (t === 'region' && !el.getAttribute('aria-label') && !el.getAttribute('aria-labelledby')) return null;
        if (t === 'form' && !r && !el.getAttribute('aria-label') && !el.querySelector('input:not([type=hidden]),textarea,select')) return null;
        return t;
      }
      function heading(el) {
        if (/^H[1-6]$/.test(el.tagName)) return +el.tagName[1];
        if (el.getAttribute('role') === 'heading') return +(el.getAttribute('aria-level') || 2);
        return 0;
      }

      var inside = 0;   // within a control: its words count, nothing in it is another control
      var rowDepth = 0; // within a list's row: a heading there is the row's words, not a section
      var naming = 0;   // within a heading: its words are its name, not the section's

      function walk(parent) {
        var kids = parent.shadowRoot ? parent.shadowRoot.childNodes :
          parent.tagName === 'SLOT' ? parent.assignedNodes({ flatten: true }) : parent.childNodes;
        for (var i = 0; i < kids.length; i++) visit(kids[i]);
      }

      function visit(el) {
        if (el.nodeType === 3) {
          if (naming) return;
          var t = flat(el.data);
          if (!t) return;
          var here = top();
          here.words += count(t);
          if (!here.preview && t.length > 2) here.preview = t;
          // Sentence-long words outside any link: what a row says, as
          // against who said it.
          if (!inside && !here.prose && count(t) >= 6) here.prose = t;
          say(here, t);
          if (want && !inside && matches.length < 40 && has(t)) matches.push({ n: here, t: t });
          return;
        }
        if (el.nodeType !== 1 || SKIP.test(el.tagName) || ++visited > LIMIT) return;
        var box = shown(el);
        if (!box) return;
        if (icon(el)) return;
        var depthIn = stack.length, wasInside = inside, n;

        // A frame is named, never read: whoever's it is, its inside isn't
        // this page's to hand over.
        if (el.tagName === 'IFRAME' || el.tagName === 'FRAME') {
          var host = '';
          try { host = new URL(el.src, location.href).host; } catch (e) {}
          n = node('frame', host, el);
          adopt(n, 'frame-' + host);
          return;
        }

        // Closed: its words are in the page all the same, and
        // read_section gives them.
        if (el.tagName === 'DETAILS' && !el.open) {
          var summary = el.querySelector('summary');
          n = node('collapsed', summary ? cut(summary.innerText, 80) : 'details', el);
          adopt(n, n.label);
          var inner = Array.prototype.filter.call(el.childNodes, function (c) { return c !== summary; })
            .map(function (c) { return c.nodeType === 1 && /^(SCRIPT|STYLE|TEXTAREA|INPUT)$/.test(c.tagName) ? '' : c.textContent || ''; }).join(' ');
          n.hidden = count(inner);
          if (summary) n.controls.push(summary);
          top().collapsed++;
          say(n, flat(inner));
          if (want && matches.length < 40) {
            if (summary && has(n.label)) matches.push({ n: n, el: summary });
            else if (has(inner)) matches.push({ n: n, t: flat(inner), hidden: true });
          }
          return;
        }

        var land = landmark(el);
        var level = land ? 0 : heading(el);
        if (land) {
          var by = el.getAttribute('aria-labelledby');
          n = node(land, el.getAttribute('aria-label') || (by ? cut(by.split(/\s+/).map(function (i) {
            var e = document.getElementById(i); return e ? e.innerText : ''; }).join(' '), 80) : ''), el);
          if (land === 'dialog' && !n.label) n.label = cut(el.innerText, 60);
          // A section that starts with a heading of its own is that
          // heading's part of the page: it closes the one before as the
          // heading would.
          var first = land === 'region' && el.querySelector('h1,h2,h3,h4,h5,h6');
          if (first) {
            while (top().type === 'heading' && top().level >= +first.tagName[1]) stack.pop();
            depthIn = stack.length;
          }
          // A named section is called by its name: §history.
          var base = !n.label ? land : land === 'region' || slug(n.label) === land ? n.label : land + '-' + n.label;
          adopt(n, base, /^(banner|nav|main|aside|footer|search|dialog)$/.test(land) ? outer() : null);
          stack.push(n);
          if (land === 'dialog') attention.push(n);
        } else if (level && !inside && !rowDepth) {
          while (top().type === 'heading' && top().level >= level) stack.pop();
          n = node('heading', cut(el.innerText, 80), el, level);
          adopt(n, n.label);
          stack.push(n);
          if (want && has(n.label)) matches.push({ n: n, head: true, t: n.label });
          // Its words are its name; a link in it is the section's.
          naming++;
          walk(el);
          naming--;
          return;
        }

        if (!inside && el.matches(PRESS)) {
          var r = el.getBoundingClientRect();
          if (r.width >= 1 && r.height >= 1) {
            top()[family(kind(el))]++;
            top().controls.push(el);
            if (el.getAttribute('aria-expanded') === 'false') top().collapsed++;
            if (want && matches.length < 40 && (has(called(el)) || has(el.href))) matches.push({ n: top(), el: el });
            inside++;
          }
        }
        // What a text field holds is said on its line, never as words.
        if (el.tagName === 'TEXTAREA') { inside = wasInside; return; }

        // Something laid over the page: fixed in place, and either over the
        // middle of the screen (a modal, a sign-up wall) or along the
        // bottom (a cookie notice, a chat). Only boxes already big enough
        // are asked their style.
        if (box === 1 && !inside && land !== 'dialog' && overlays.length < 3) {
          var b = el.getBoundingClientRect();
          var w = Math.max(0, Math.min(b.right, wide) - Math.max(b.left, 0)), h = Math.max(0, Math.min(b.bottom, high) - Math.max(b.top, 0));
          var middle = b.left < wide / 2 && b.right > wide / 2 && b.top < high / 2 && b.bottom > high / 2;
          var bottom = b.top > high * 0.3 && b.bottom >= high * 0.85;
          if (w * h > wide * high * 0.04 && w * h < wide * high * 0.98 && (middle || bottom) &&
              !overlays.some(function (x) { return x.contains(el); })) {
            var style = getComputedStyle(el);
            if (style.position === 'fixed' && style.pointerEvents !== 'none') overlays.push(el);
          }
        }

        var r0 = el.getAttribute('role');
        if ((r0 === 'alert' || el.getAttribute('aria-live') === 'assertive') && flat(el.innerText)) {
          attention.push({ type: 'alert', label: cut(el.innerText, 120) });
        }
        if (el.tagName === 'INPUT' || el.tagName === 'SELECT') {
          var invalid = el.getAttribute('aria-invalid') === 'true';
          try { invalid = invalid || el.matches(':user-invalid'); } catch (e) {}
          if (invalid) attention.push({ type: 'error', el: el, label: el.validationMessage || errorText(el) });
        }

        var rows = !inside && !land && listy(el);
        if (rows) {
          n = node('list', el.getAttribute('aria-label') || '', el);
          adopt(n, listName(el) || (top().id !== 'page' ? top().id + '-list' : 'list'));
          stack.push(n);
          // Every child node, words between rows included: they are the
          // row's before them, or the list's before the first.
          var kids = el.childNodes, item = null;
          for (var j = 0; j < kids.length; j++) {
            var it = kids[j];
            if (it.nodeType === 1 && shape(it) === rows) {
              if (item) close(n, item);
              if (!shown(it)) { item = null; continue; }
              item = node('item', '', it);
              n.kids.push(item);
              n.rows++;
              item.id = n.id + '/' + n.rows;
              stack.length = stack.indexOf(n) + 1;
              stack.push(item);
            }
            if (item) rowDepth++;
            visit(it); // before the first row, into the list; after, into its row
            if (item) rowDepth--;
          }
          if (item) close(n, item);
          stack.length = depthIn;
          inside = wasInside;
          return;
        }

        if (BLOCK.test(el.tagName)) say(top(), '\n');
        walk(el);
        inside = wasInside;
        if (land) stack.length = depthIn;
      }
      // A row is named by what it says first: its first control with
      // words, or its first words.
      function close(list, item) {
        if (!item.words && !controlsIn(item).length) {
          list.kids.splice(list.kids.indexOf(item), 1);
          list.rows--;
          return;
        }
        var named = controlsIn(item).filter(function (c) { return called(c).length > 2; })[0];
        var says = item.prose || '';
        item.label = cut(named ? called(named) + (says && says.indexOf(called(named)) < 0 ? ': ' + says : '') : item.preview, 80);
        item.lead = named || controlsIn(item)[0] || null;
        if (list.samples.length < 2 && item.label) list.samples.push(trim(item.label, 40));
      }
      function errorText(el) {
        var id = el.getAttribute('aria-errormessage') || el.getAttribute('aria-describedby');
        var e = id && document.getElementById(id.split(/\s+/)[0]);
        return e ? cut(e.innerText, 100) : 'invalid';
      }
      function controlsIn(n) {
        return n.kids.reduce(function (all, k) { return all.concat(controlsIn(k)); }, n.controls.slice());
      }

      if (document.body) visit(document.body);

      // Totals: each section with everything under it.
      (function sum(n) {
        n.kids.forEach(function (k) {
          sum(k);
          n.words += k.words; n.links += k.links; n.buttons += k.buttons; n.fields += k.fields;
          if (k.type !== 'item') { n.collapsed += k.collapsed; n.hidden += k.hidden; }
        });
      })(root);
      var byId = {};
      (function index(n) { byId[n.id] = n; n.kids.forEach(index); })(root);

      // ---- saying it

      function size(n) {
        var bits = [];
        if (n.type === 'list') bits.push(n.rows + ' rows');
        if (n.links) bits.push(n.links + (n.links === 1 ? ' link' : ' links'));
        if (n.buttons) bits.push(n.buttons + (n.buttons === 1 ? ' button' : ' buttons'));
        if (n.fields) bits.push(n.fields + (n.fields === 1 ? ' field' : ' fields'));
        if (n.collapsed) bits.push(n.collapsed + ' collapsed');
        if (n.words) bits.push(n.words + ' words');
        if (n.hidden) bits.push(n.hidden + ' hidden');
        return bits.join(', ') || 'empty';
      }
      function title(n) {
        if (n.type === 'frame') return '§' + n.id + ' frame ' + (n.label || '') + ' (not read)' + where(n.el);
        var what = n.type === 'heading' ? 'h' + n.level : n.type === 'item' ? 'row' : n.type;
        var label = n.label ? ' "' + cut(n.label, 60) + '"' : '';
        var peek = n.type === 'list' ? (n.samples.length ? ' · "' + n.samples.join('", "') + '"…' : '') :
          n.preview ? ' · "' + cut(n.preview, 60) + '"' : '';
        var more = n.type !== 'list' && n.kids.length ? ', ' + n.kids.length + ' inside' : '';
        return '§' + n.id + ' ' + what + label + ' — ' + size(n) + more + peek + where(n.el);
      }
      var lines = [], cutoff = 0;
      function line(t) { if (lines.length < most) lines.push(t); else cutoff++; }
      // A control's line, and before the first choice of a question, the
      // question: ? "Is this data processed ephemerally?"
      var asking = null;
      function item(c, pad) {
        if (choice(c)) {
          var q = question(c);
          if (q && q !== asking) line((pad || '') + '? "' + q.text + '"');
          asking = q;
        } else asking = null;
        line((pad || '') + control(c));
      }

      function attend() {
        var out = [];
        attention.forEach(function (a) {
          if (a.type === 'dialog') {
            out.push('! dialog "' + cut(a.label, 80) + '" §' + a.id + ' ' + controlsIn(a).slice(0, 6).map(control).join(' '));
          } else if (a.type === 'alert') {
            out.push('! alert "' + a.label + '"');
          } else if (a.type === 'error') {
            out.push('! error ' + control(a.el) + ': ' + cut(a.label, 100));
          }
        });
        overlays.forEach(function (el) {
          var press = Array.prototype.filter.call(el.querySelectorAll('button,a[href],[role=button]'), function (b) { return b.getClientRects().length; });
          out.push('! over the page: "' + cut(el.innerText, 90) + '" ' + press.slice(0, 4).map(control).join(' '));
        });
        var f = document.activeElement;
        if (f && f !== document.body && f !== document.documentElement && f.matches && f.matches(PRESS)) out.push('! focus ' + control(f));
        return out;
      }

      // A section and, `levels` deep, what is in it. Named outright, every
      // control in it is listed; met on the way, a few, and how to see
      // the rest.
      function open(n, levels, pad, named) {
        if (n.type !== 'page') line(pad + title(n));
        var inner = n.type === 'page' ? pad : pad + '  ';
        if (n.type === 'frame') return;
        if (n.type === 'list') {
          n.kids.forEach(function (it) {
            var c = it.lead;
            var others = controlsIn(it).length - (c ? 1 : 0);
            var says = it.prose && (!c || it.prose.indexOf(called(c)) < 0) ? ' · "' + cut(it.prose, 70) + '"' : '';
            line(inner + (c ? control(c) : 'row "' + cut(it.preview, 80) + '"') + (others > 0 ? ' +' + others : '') + says);
          });
          return;
        }
        if (n.type === 'item') {
          controlsIn(n).forEach(function (c) { item(c, inner); });
          if (n.words) line(inner + 'text — ' + n.words + ' words · "' + cut(n.text.join(' '), 100) + '"');
          return;
        }
        if (n.type === 'collapsed') {
          n.controls.forEach(function (c) { line(inner + control(c) + ' opens it'); });
          line(inner + 'hidden "' + cut(n.text.join(' '), 100) + '" — read_section §' + n.id);
          return;
        }
        var mine = n.controls.filter(function (c) { return said.indexOf(c) < 0; });
        // Named outright, all of them, unless they'd crowd out the sections
        // inside: then a few, and how to narrow them.
        var show = named && mine.length <= most / 2 ? mine.length : Math.min(mine.length, 8);
        mine.slice(0, show).forEach(function (c) { item(c, inner); });
        if (show < mine.length) line(inner + '… ' + (mine.length - show) + ' more to press: outline_page §' + n.id +
          (named ? ' with words, or max_lines ' + mine.length * 2 : ''));
        var own = n.words - n.kids.reduce(function (s, k) { return s + k.words; }, 0);
        if (own > 12) line(inner + 'text — ' + own + ' words · "' + cut(n.preview, 80) + '" — read_section §' + n.id);
        n.kids.forEach(function (k) {
          if (levels > 1) open(k, levels - 1, inner, false);
          else line(inner + title(k));
        });
      }

      function countAll(n) {
        return (n.type === 'heading' || n.type === 'frame' ? 1 : 0) + n.controls.length +
          n.kids.reduce(function (s, k) { return s + countAll(k); }, 0);
      }
      function whole() {
        // Every heading and control in page order; what needs attention
        // has said its own already.
        (function each(n) {
          if (n.type === 'heading') line('h' + n.level + ' "' + cut(n.label, 70) + '"' + where(n.el));
          if (n.type === 'frame') line(title(n));
          if (n.type === 'collapsed') n.controls.forEach(function (c) { line(control(c) + ' opens ' + n.hidden + ' hidden words'); });
          else n.controls.forEach(function (c) { if (said.indexOf(c) < 0) item(c); });
          n.kids.forEach(each);
        })(root);
      }

      function read(n, budget) {
        var out = [];
        (function each(m) {
          if (m.type === 'heading') out.push('\n' + '#'.repeat(Math.min(m.level, 6)) + ' ' + m.label);
          else if (m.type === 'collapsed') out.push('\n' + m.label + ' (hidden until opened)');
          else if (m.type === 'frame') out.push('\n(a frame from ' + (m.label || 'nowhere') + ', not read)');
          var t = m.text.join(' ').replace(/ *\n[\n ]*/g, '\n').replace(/[ \t]+/g, ' ').trim();
          if (t) out.push(t);
          m.kids.forEach(each);
        })(n);
        var all = out.join('\n').replace(/\n{3,}/g, '\n\n').trim();
        if (all.length <= budget) return all || '(no words)';
        return trim(all, budget) + '\n… ' + (all.length - budget) + ' more characters: read_section §' + n.id + ' max_chars ' + budget * 2;
      }

      var head = cut(document.title, 100) + ' — ' + location.href;
      function section(id) { return byId[id]; }
      function gone(id) { return 'no §' + id + ' on the page now: outline_page for what there is'; }

      // Words only: nothing numbered, the last read's handles stand.
      if (mode === 'read') {
        var parts = (open_.length ? open_ : ['page']).map(function (id) {
          var n = section(id);
          return n ? read(n, Math.max(200, o.chars || 4000)) : gone(id);
        });
        return JSON.stringify({ text: head + '\n' + parts.join('\n\n') });
      }

      var attn = attend();
      var said = printed.slice();
      var tail = [];
      function finish(body) {
        globalThis[key] = { snap: snap, els: printed };
        var opened = open_.length ? ' §' + open_.join(' §') : '';
        if (cutoff) tail.unshift('… ' + cutoff + ' more lines: ' + (mode === 'seek' ? 'max_lines ' + most * 2 :
          opened ? 'outline_page' + opened + ' max_lines ' + most * 2 + ', or find_in_page' : 'open a section (outline_page §name), or max_lines ' + most * 2));
        if (visited > LIMIT) tail.push('(a very large page: only its first ' + LIMIT + ' elements were looked at)');
        return JSON.stringify({ text: [head].concat(attn, body, tail).join('\n'), elements: printed.length, cut: cutoff });
      }

      if (mode === 'seek') {
        matches.forEach(function (m) {
          var at = '§' + m.n.id;
          if (m.el) return line(at + ' ' + control(m.el));
          if (m.head) return line(at + ' heading "' + cut(m.t, 80) + '"');
          var i = Math.max(0, m.t.toLowerCase().indexOf(want));
          line(at + (m.hidden ? ' hidden until opened:' : '') + ' "' + (i > 40 ? '…' : '') +
            cut(m.t.slice(Math.max(0, i - 40), i + want.length + 60), 110) + '"');
        });
        if (!want) line('find_in_page needs words');
        else if (!matches.length) line('nothing on the page says "' + want + '"');
        return finish(lines);
      }

      if (open_.length) {
        open_.forEach(function (id) { var n = section(id); if (n) open(n, depth, '', true); else line(gone(id)); });
      } else if (want) {
        // Only what has the words. What a control is called comes first;
        // where a link goes counts only when nothing is called that, so
        // "search" finds the search box, not every link to a search page.
        var byAddress = [], named = 0;
        (function each(n) {
          if (n.type === 'heading' && has(n.label)) line('h' + n.level + ' "' + cut(n.label, 70) + '"' + where(n.el));
          n.controls.forEach(function (c) {
            var q = choice(c) && question(c);
            if (has(called(c)) || (q && has(q.text))) { item(c); named++; }
            else if (c.href && has(c.href)) byAddress.push(c);
          });
          n.kids.forEach(each);
        })(root);
        if (!named) byAddress.forEach(function (c) { item(c); });
        if (!lines.length) line('nothing to press or fill in says "' + want + '": find_in_page looks in the words too');
      } else if (countAll(root) + attn.length <= most) {
        whole();
      } else {
        open(root, depth, '', false);
      }
      return finish(lines);
    })
    """#
}
