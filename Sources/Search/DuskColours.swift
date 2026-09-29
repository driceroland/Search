import Foundation

// Dark pages, in the site's own colours (see Dusk.swift for when and why).
//
// For every rule of the page's that sets a colour, a twin: the same
// selector, in the same order, with the colour taken to dark. The twins go
// in after the page's own sheets, so the cascade settles every element
// exactly as it did for the site, only in dark colours. Nothing is turned
// over, so a picture is never touched and a colour keeps its gamut.
//
// The browser does the arithmetic. A twin is written in relative colour
// syntax, `oklch(from <the site's colour> <new lightness> c h / alpha)`,
// which takes any colour the site names: hex, oklch, a P3 colour, a
// system colour, or a variable whose value is only known on the element.
// Lightness is moved along one of three curves, by the part a colour
// plays; hue and chroma are kept.
//
// WebKit has had relative colour syntax since Safari 18 (macOS 15); before
// that, the filter (Dusk.swift) does the darkening on its own.

enum DuskColours {
    /// Where the engine goes in the page script (Dusk.script).
    static let slot = "/*COLOURS*/"

    /// A function of the page script's, called once per page with the
    /// document and the page script's own sheets, which aren't the page's.
    /// Nil where the browser can't do relative colours.
    static let engine = #"""
    function (doc, others) {
      // Each curve gives way to the site's own lightness by as much as
      // --office-dusk-keep says: 1 on what is laid over a picture (see the
      // page script's frames), where dark writing on a light photo must
      // stay dark, and nothing everywhere else.
      var curve = function (to) {
        return function (v) { return 'oklch(from ' + v + ' calc(' + to + ' + (l - (' + to + ')) * var(--office-dusk-keep, 0)) c h / alpha)'; };
      };
      // Writing: dark goes light, light stays light. Black lands at 0.87.
      var fg = 'max(0.25 + l * 0.75, 0.87 - l * 0.5)';
      // A ground: light goes dark, dark stays dark. White lands at 0.2. A
      // strong colour keeps more of its lightness, so a brand's orange bar
      // stays orange rather than going brown; never lighter than it was.
      // An icon drawn through a mask is painted by its ground, and is
      // writing however it is made: --office-dusk-mask, set by the twin of
      // any rule that gives a mask, turns its ground into writing, whichever
      // rule the colour came from.
      var bg = 'min(l, min(l * 0.8, 0.6 - l * 0.4) + c * 1.2)';
      var BG = curve('(' + bg + ' + (' + fg + ' - ' + bg + ') * var(--office-dusk-mask, 0))');
      var FG = curve(fg);
      // A line: between the two, so a border still shows on its ground.
      var LINE = curve('min(l * 0.9, 0.75 - l * 0.45)');
      // The mask's mark is the element's own: its children aren't icons.
      try { CSS.registerProperty({ name: '--office-dusk-mask', syntax: '<number>', inherits: false, initialValue: '0' }); } catch (e) {}
      if (!CSS.supports('color', BG('red'))) return null;

      var roles = {
        'color': FG, '-webkit-text-fill-color': FG, '-webkit-text-stroke-color': FG,
        'text-decoration-color': FG, 'caret-color': FG, 'fill': FG, 'stroke': FG,
        'background-color': BG,
        'border-top-color': LINE, 'border-right-color': LINE, 'border-bottom-color': LINE, 'border-left-color': LINE,
        'border-block-start-color': LINE, 'border-block-end-color': LINE,
        'border-inline-start-color': LINE, 'border-inline-end-color': LINE,
        'outline-color': LINE, 'column-rule-color': LINE
      };
      // A shorthand written with var() has longhands the CSSOM can't say
      // until the value is known: `border: 1px solid var(--line)` reads as
      // an empty border-top-color. The colour is found in the shorthand.
      var shorthands = {
        'background': ['background-color', BG], 'border': ['border-color', LINE], 'border-color': ['border-color', LINE],
        'border-top': ['border-top-color', LINE], 'border-right': ['border-right-color', LINE],
        'border-bottom': ['border-bottom-color', LINE], 'border-left': ['border-left-color', LINE],
        'border-block': ['border-block-color', LINE], 'border-inline': ['border-inline-color', LINE],
        'outline': ['outline-color', LINE], 'column-rule': ['column-rule-color', LINE],
        'text-decoration': ['text-decoration-color', FG]
      };
      // Values that aren't a colour of the rule's own to move.
      var leave = /^(inherit|initial|unset|revert|revert-layer|currentcolor|transparent|none|auto|context-fill|context-stroke)$/i;

      // The top-level words of a value, a function whole.
      var words = function (v) {
        var out = [], depth = 0, word = '';
        for (var i = 0; i < v.length; i++) {
          var ch = v[i];
          if (ch === '(') depth++;
          if (ch === ')') depth--;
          if (depth === 0 && /\s/.test(ch)) { if (word) out.push(word); word = ''; } else word += ch;
        }
        if (word) out.push(word);
        return out;
      };
      var colourish = /^(var\(|#|rgba?\(|hsla?\(|hwb\(|lab\(|lch\(|oklab\(|oklch\(|color\(|light-dark\()/i;
      // Every colour in a gradient, as a ground. A var() that turns out to
      // be a length makes the twin invalid, and the site's gradient stays.
      var stops = /#[0-9a-f]{3,8}\b|(?:rgba?|hsla?|hwb|lab|lch|oklab|oklch|color)\([^()]*\)|var\([^()]*(?:\([^()]*\)[^()]*)*\)|\b(?:white|black)\b/gi;
      var gradient = function (v) { return v.replace(stops, function (c) { return BG(c); }); };
      var inShorthand = function (v) {
        var found = null;
        words(v).forEach(function (w) { if (colourish.test(w)) found = w; });
        return found;
      };

      // One rule's colours, twinned. `always`: important whatever the
      // original was, for a style attribute, which beats any sheet.
      var twin = function (style, always) {
        var out = '', pending = false;
        var mask = (style.getPropertyValue('-webkit-mask-image') || style.getPropertyValue('mask-image') || '').trim();
        if (mask && !/^none$/i.test(mask)) out += '--office-dusk-mask:1;';
        for (var i = 0; i < style.length; i++) {
          var p = style[i], make = roles[p];
          var v;
          if (p === 'background-image') {
            v = style.getPropertyValue(p).trim();
            if (v.indexOf('gradient(') >= 0 && v.indexOf('url(') < 0) {
              out += p + ':' + gradient(v) + (always || style.getPropertyPriority(p) ? ' !important;' : ';');
            }
            continue;
          }
          if (p === 'mix-blend-mode' || p === 'background-blend-mode') {
            // Multiply and its kin darken by what is under them: meant to
            // lose a photo's white on a light tile, onto a dark one they
            // take the picture and everything on it down to black.
            if (/^(multiply|darken|color-burn)$/i.test(style.getPropertyValue(p).trim()))
              out += p + ':normal' + (always || style.getPropertyPriority(p) ? ' !important;' : ';');
            continue;
          }
          if (!make) continue;
          v = style.getPropertyValue(p).trim();
          if (!v) { pending = true; continue; }
          if (leave.test(v) || v.indexOf('url(') >= 0 || v.indexOf('gradient(') >= 0) continue;
          out += p + ':' + make(v) + (always || style.getPropertyPriority(p) ? ' !important;' : ';');
        }
        if (pending) {
          for (var s in shorthands) {
            var whole = style.getPropertyValue(s);
            if (!whole || whole.indexOf('var(') < 0) continue;
            var c = inShorthand(whole);
            if (c) out += shorthands[s][0] + ':' + shorthands[s][1](c) + (always || style.getPropertyPriority(s) ? ' !important;' : ';');
          }
        }
        return out;
      };

      // A list of rules, twinned, with every group they sit in kept around
      // them: a twin must match only where its original does, and in a
      // cascade layer it must lose and win where its original would.
      var rules = function (list, base) {
        var out = '';
        for (var i = 0; i < list.length; i++) {
          var r = list[i], inner;
          if (r instanceof CSSStyleRule) {
            var own = twin(r.style, false);
            inner = r.cssRules && r.cssRules.length ? rules(r.cssRules, base) : '';
            if (own || inner) out += r.selectorText + '{' + own + inner + '}';
          } else if (r instanceof CSSImportRule) {
            var from = null;
            try { from = r.styleSheet && r.styleSheet.cssRules; } catch (e) {}
            if (from) {
              inner = rules(from, r.href);
              var media = r.media && r.media.mediaText;
              if (inner) out += media && media !== 'all' ? '@media ' + media + '{' + inner + '}' : inner;
            } else {
              unreadable = true;
            }
          } else if (r instanceof CSSMediaRule) {
            inner = rules(r.cssRules, base);
            if (inner) out += '@media ' + r.media.mediaText + '{' + inner + '}';
          } else if (r instanceof CSSSupportsRule) {
            inner = rules(r.cssRules, base);
            if (inner) out += '@supports ' + r.conditionText + '{' + inner + '}';
          } else if (window.CSSLayerBlockRule && r instanceof CSSLayerBlockRule) {
            inner = rules(r.cssRules, base);
            if (inner) out += '@layer ' + r.name + '{' + inner + '}';
          } else if (r.cssRules && r.cssRules.length && !(r instanceof CSSKeyframesRule)) {
            // @container, @scope and whatever comes next: the rule's own
            // opening, as the browser writes it.
            inner = rules(r.cssRules, base);
            var text = r.cssText;
            if (inner) out += text.slice(0, text.indexOf('{')) + '{' + inner + '}';
          }
        }
        return out;
      };

      // Each of the page's sheets has a twin sheet of its own, kept in the
      // same order after all of them, so one that changes is twinned again
      // alone. A sheet from another site can't be read from here, and it
      // isn't asked for again: that would be a request the page never
      // made. What such a sheet colours is read off the elements it lands on
      // instead (see paint).
      var twins = new Map();
      var ground = new CSSStyleSheet(), marks = new CSSStyleSheet();
      ground.disabled = marks.disabled = true;
      // While our sheets come and go under the page (to measure it, or to
      // show it darkened), a site's transitions would animate every colour
      // they change: a field fading to white and back each time the page
      // is measured. Held still for that moment, and let go once the page's
      // style has settled where it was.
      var still = new CSSStyleSheet();
      still.replaceSync('*, *::before, *::after { transition: none !important; }');
      still.disabled = true;
      var settle = function () { void doc.documentElement.offsetWidth; };
      var quietly = function (change) {
        still.disabled = false;
        settle();
        change();
        settle();
        still.disabled = true;
      };
      var started = false, showing = false, readyAt = 0, spent = 0, onReady = null, unreadable = false;
      // Where the time goes, for the bench: twinning sheets, painting what
      // they can't reach, and marking what the markup colours.
      var took = { twins: 0, paint: 0, paints: 0, markups: 0, refreshes: 0, paintRead: 0, paintWrite: 0, painted: 0 };

      var mine = new Set([ground, marks, still].concat(others));
      // The document, and every open shadow root in it. A shadow root's
      // sheets style only what is inside it, and the document's twins don't
      // reach in there either: each root gets twins of its own, beside its
      // own sheets, and our ground, marks and stillness too.
      var roots = [doc], rooted = new WeakSet();
      var sources = function (root) {
        var list = [].slice.call(root.styleSheets);
        root.adoptedStyleSheets.forEach(function (s) { if (!mine.has(s)) list.push(s); });
        return list;
      };

      var twinOf = function (s) {
        var t = twins.get(s);
        if (!t) {
          t = { sheet: new CSSStyleSheet(), count: -1, text: null };
          t.sheet.disabled = !showing;
          twins.set(s, t);
          mine.add(t.sheet);
        }
        var list = null;
        try { list = s.cssRules; } catch (e) {}
        if (!list) { unreadable = true; return t; }
        if (list.length === t.count) return t;
        t.count = list.length;
        var start = performance.now();
        var text = rules(list, s.href);
        spent += performance.now() - start;
        took.twins += performance.now() - start;
        var media = s.media && s.media.mediaText;
        if (text && media && media !== 'all') text = '@media ' + media + '{' + text + '}';
        if (text !== t.text) {
          t.text = text;
          t.sheet.replaceSync(text);
        }
        return t;
      };

      // Colours a page gives in its markup rather than a sheet: bgcolor,
      // <font color>, <body text>, and an SVG's fill and stroke. Each value
      // is matched by the attribute holding it, at no specificity at all, so
      // any rule of the page's (and its twin) still wins over it, as the
      // attribute itself always lost to them.
      var PAINT = 'data-office-dusk-paint';
      var sides = [['backgroundColor', 'background-color', BG, null, 'bg'], ['color', 'color', FG, null, 'fg'],
                   ['borderTopColor', 'border-top-color', LINE, 'borderTopWidth', 'bt'],
                   ['borderRightColor', 'border-right-color', LINE, 'borderRightWidth', 'br'],
                   ['borderBottomColor', 'border-bottom-color', LINE, 'borderBottomWidth', 'bb'],
                   ['borderLeftColor', 'border-left-color', LINE, 'borderLeftWidth', 'bl'],
                   ['fill', 'fill', FG, null, 'fill'], ['stroke', 'stroke', FG, null, 'stroke']];
      var base = ':root { color-scheme: dark !important; }'
        + '[data-office-dusk-over] { --office-dusk-keep: 1; }'
        + 'img[data-office-dusk-icon] { filter: invert(1) hue-rotate(180deg) !important; }'
        // What paint finds, one rule a part, written once: the colour itself
        // sits on the element (see paint).
        + sides.map(function (side) {
          return '[' + PAINT + '~="' + side[4] + '"]{' + side[1] + ':var(--office-dusk-' + side[4] + ') !important}';
        }).join('');
      var given = {};
      var legacy = [['bgcolor', 'background-color', BG], ['text', 'color', FG], ['color', 'color', FG],
                    ['fill', 'fill', FG], ['stroke', 'stroke', FG]];
      var legacyFind = '[bgcolor], body[text], font[color], svg[fill], svg [fill], svg [stroke]';
      var hex = /^[0-9a-f]{3}([0-9a-f]{3})?$/i;
      var noteLegacy = function (el) {
        legacy.forEach(function (l) {
          var v = el.getAttribute(l[0]);
          if (!v || l[0] === 'text' && el.tagName !== 'BODY' || l[0] === 'color' && el.tagName !== 'FONT') return;
          v = v.trim();
          var key = l[0] + '=' + v;
          if (given[key] || leave.test(v) || v.indexOf('url(') >= 0) return;
          var colour = hex.test(v) ? '#' + v : v;
          var match = '[' + l[0] + '="' + v.replace(/["\\]/g, '\\$&') + '"]';
          given[key] = { match: match, rule: ':where(' + match + '){' + l[1] + ':' + l[2](colour) + '}' };
          try { ground.insertRule(given[key].rule, ground.cssRules.length); } catch (e) {}
        });
      };

      // Colours set on one element rather than by a rule: the element is
      // marked with the twin's number, and the twin is a rule for that
      // mark. Elements with the same colours share one.
      var marker = function (attr, sheet) {
        var numbered = {}, count = 0;
        var put = function (el, decls) {
          if (!decls) { if (el.hasAttribute(attr)) el.removeAttribute(attr); return; }
          var n = numbered[decls];
          if (!n) {
            n = numbered[decls] = String(++count);
            sheet.insertRule('[' + attr + '="' + n + '"]{' + decls + '}', sheet.cssRules.length);
          }
          if (el.getAttribute(attr) !== n) el.setAttribute(attr, n);
        };
        // Only the numbers some element still carries, in any root.
        var prune = function () {
          var text = '';
          Object.keys(numbered).forEach(function (decls) {
            var sel = '[' + attr + '="' + numbered[decls] + '"]';
            if (anywhere(sel)) text += sel + '{' + decls + '}';
            else delete numbered[decls];
          });
          sheet.replaceSync(text);
        };
        return { put: put, prune: prune, count: function () { return Object.keys(numbered).length; } };
      };
      var anywhere = function (sel) { return roots.some(function (r) { return !!r.querySelector(sel); }); };

      // A style attribute's colours.
      var styled = marker('data-office-dusk-style', marks);
      var markStyle = function (el) {
        styled.put(el, el.style && el.style.length ? twin(el.style, true) : '');
      };

      // What a sheet that can't be read colours, read off the elements it
      // lands on: each one's computed ground, writing and lines that no twin
      // has taken (a twin's colour computes to oklch), taken to dark. Read
      // for every element first and written after, so the page's style is
      // worked out once. Only on a page with such a sheet. Writing an element
      // only inherits isn't its own, and is left to its parent's.
      //
      // The dark colour goes on the element itself, as a custom property,
      // and one of the rules above (a rule a part, written once) puts it to
      // use. A rule per colour would change our sheet with every colour
      // found, and a changed sheet has the whole page's style worked out
      // again: 180 ms a time on a news front page.
      var untwinned = function (v) {
        return v && v.indexOf('oklch(') !== 0 && v !== 'transparent' && v !== 'none' && !/^rgba\(.*,\s*0\)$/.test(v) && !/^url\(/.test(v);
      };
      var paint = function (tops) {
        if (!unreadable) return;
        var t = performance.now();
        var all = [];
        tops.forEach(function (top) {
          if (!top || top.nodeType !== 1 && top.nodeType !== 11) return;
          // Inside another of the batch, it is read with that one.
          if (tops.some(function (other) { return other !== top && other.contains && other.contains(top); })) return;
          if (top.nodeType === 1) all.push(top);
          all.push.apply(all, top.querySelectorAll('*'));
        });
        var found = [];
        for (var i = 0; i < all.length; i++) {
          var el = all[i];
          if (skip[el.tagName] || el.hasAttribute('data-office-dusk-style')) continue;
          var cs = getComputedStyle(el), parent = el.parentElement ? getComputedStyle(el.parentElement) : null, parts = [];
          // fill and stroke are an SVG's: an HTML element reports the black
          // they start as, which is no colour of its own.
          var svg = el instanceof SVGElement;
          for (var j = 0; j < sides.length; j++) {
            var side = sides[j];
            if (side[3] && parseFloat(cs[side[3]]) === 0) continue;
            if ((side[0] === 'fill' || side[0] === 'stroke') && !svg) continue;
            var v = cs[side[0]];
            // Inherited, it is the parent's to change.
            if ((side[0] === 'color' || side[0] === 'fill' || side[0] === 'stroke') && parent && parent[side[0]] === v) continue;
            if (untwinned(v)) parts.push([side[4], side[2](v)]);
          }
          if (parts.length) found.push([el, parts]);
        }
        var w = performance.now();
        took.paintRead += w - t;
        found.forEach(function (f) {
          var keys = (f[0].getAttribute(PAINT) || '').split(' ').filter(Boolean);
          f[1].forEach(function (part) {
            f[0].style.setProperty('--office-dusk-' + part[0], part[1]);
            if (keys.indexOf(part[0]) < 0) keys.push(part[0]);
          });
          f[0].setAttribute(PAINT, keys.join(' '));
        });
        took.paintWrite += performance.now() - w;
        took.painted += found.length;
        spent += performance.now() - t;
        took.paint += performance.now() - t;
        took.paints++;
      };
      var skip = { SCRIPT: 1, STYLE: 1, NOSCRIPT: 1, TEMPLATE: 1, HEAD: 1, LINK: 1, META: 1, TITLE: 1, BR: 1 };

      // A logo or an icon drawn dark on nothing: invisible on a dark ground.
      // Small pictures are looked at, drawn into a few pixels: mostly clear,
      // and what isn't clear dark, it is turned over. Only what the page can
      // read already: a picture from another site can't be drawn and read,
      // and isn't asked for again. Kept by address, so each is looked at
      // once.
      var ICON = 'data-office-dusk-icon', verdicts = {}, lens = doc.createElement('canvas').getContext('2d', { willReadFrequently: true });
      var judge = function (source, w, h) {
        var cw = Math.max(1, Math.min(48, Math.round(w))), ch = Math.max(1, Math.min(48, Math.round(h)));
        lens.canvas.width = cw; lens.canvas.height = ch;
        lens.clearRect(0, 0, cw, ch);
        lens.drawImage(source, 0, 0, cw, ch);
        var d = lens.getImageData(0, 0, cw, ch).data, clear = 0, seen = 0, dark = 0;
        for (var i = 0; i < d.length; i += 4) {
          if (d[i + 3] < 26) { clear++; continue; }
          seen++;
          if (0.2126 * d[i] + 0.7152 * d[i + 1] + 0.0722 * d[i + 2] < 90) dark++;
        }
        return clear >= (clear + seen) * 0.3 && seen > 0 && dark >= seen * 0.6;
      };
      // Logos and icons come as SVG, PNG or GIF; a photo as JPEG, WebP or
      // AVIF, and decoding one to look at it is most of what this costs on
      // a page of thumbnails.
      var drawn = /(\.(svg|png|gif)([?#]|$))|^data:image\/(svg|png|gif)/i;
      var lookAt = function (img) {
        if (img.hasAttribute(ICON)) return;
        var src = img.currentSrc || img.src;
        if (!src || !drawn.test(src)) return;
        if (!img.complete || !img.naturalWidth) return;
        var w = img.width, h = img.height;
        if (w * h > 400 * 200 || w < 8 || h < 8) return;
        if (!(src in verdicts)) {
          try { verdicts[src] = judge(img, w, h); } catch (e) { verdicts[src] = false; }
        }
        if (verdicts[src] && !img.closest('[data-office-dusk-over]')) img.setAttribute(ICON, '');
      };

      var markups = function (top) {
        if (!top || top.nodeType !== 1 && top.nodeType !== 11) return;
        var t = performance.now();
        if (top.nodeType === 1) {
          if (top.tagName === 'IMG') lookAt(top);
          if (top.hasAttribute('style')) markStyle(top);
          if (top.matches(legacyFind)) noteLegacy(top);
        }
        top.querySelectorAll('img').forEach(lookAt);
        top.querySelectorAll('[style]').forEach(markStyle);
        top.querySelectorAll(legacyFind).forEach(noteLegacy);
        took.markups += performance.now() - t;
      };

      // The page's scheme dark: its default colours, its form controls and
      // its scrollbars, which no rule of its own ever names.
      ground.replaceSync(base);

      // Ours after all of the page's, in the page's order: the ground first,
      // then each sheet's twin, then the elements' own.
      var place = function (root) {
        var theirs = root.adoptedStyleSheets.filter(function (s) { return !mine.has(s) || others.indexOf(s) >= 0; });
        var ordered = [ground];
        sources(root).forEach(function (s) { var t = twins.get(s); if (t) ordered.push(t.sheet); });
        ordered.push(marks, still);
        var now = root.adoptedStyleSheets, want = theirs.concat(ordered);
        if (now.length !== want.length || want.some(function (s, i) { return now[i] !== s; })) root.adoptedStyleSheets = want;
      };

      // A shadow root is made without a mutation to say so: looked for in
      // what is added, and swept for while the page is watched.
      var shadows = function (top) {
        if (!top || !top.querySelectorAll) return;
        if (top.shadowRoot && !rooted.has(top.shadowRoot)) adopt(top.shadowRoot);
        var all = top.querySelectorAll('*');
        for (var i = 0; i < all.length; i++) {
          var sr = all[i].shadowRoot;
          if (sr && !rooted.has(sr)) adopt(sr);
        }
      };
      var adopt = function (sr) {
        rooted.add(sr);
        roots.push(sr);
        if (awake) watch(sr);
        markups(sr);
        shadows(sr);
      };

      var refresh = function () {
        if (!started) return;
        took.refreshes++;
        var t = performance.now();
        // A root whose host has left the page goes with it.
        roots = roots.filter(function (r) { return r === doc || r.host.isConnected; });
        roots.forEach(function (root) {
          sources(root).forEach(twinOf);
          place(root);
        });
        spent += performance.now() - t;
        if (!readyAt) {
          readyAt = performance.now();
          if (onReady) onReady();
        }
      };

      // What no longer has anything to colour goes, so our sheets shrink
      // with the page as well as grow with it: the twin of a sheet the page
      // took out, the marks no element carries, and the attribute colours
      // no element has.
      var prune = function () {
        var present = new Set();
        roots.forEach(function (r) { sources(r).forEach(function (s) { present.add(s); }); });
        twins.forEach(function (t, s) { if (!present.has(s)) { twins.delete(s); mine.delete(t.sheet); } });
        roots.forEach(place);
        styled.prune();
        var text = base;
        Object.keys(given).forEach(function (key) {
          if (anywhere(given[key].match)) text += given[key].rule;
          else delete given[key];
        });
        ground.replaceSync(text);
      };

      // Watched for a while, not for the page's life: from the start until
      // ten seconds after the page has loaded, and ten seconds again when it
      // moves to another address of its own (again). Rules a script adds
      // without touching the markup are looked for once a second in that
      // time. What stays for the page's life is small: the <head>, for a
      // new sheet, and a sheet's load.
      var observers = [], ticker = 0, until = 0, awake = false, SPELL = 10000;
      var wake = function () {
        until = performance.now() + SPELL;
        if (awake) return;
        awake = true;
        roots.forEach(watch);
        ticker = setInterval(function () {
          if (performance.now() > until) return rest();
          if (!showing) return;
          roots.slice().forEach(shadows);
          refresh();
        }, 1000);
      };
      var rest = function () {
        awake = false;
        clearInterval(ticker);
        observers.forEach(function (o) { o.disconnect(); });
        observers = [];
        prune();
      };

      var changed = function (records) {
        var sheets = false;
        records.forEach(function (r) {
          if (r.type === 'attributes') {
            if (r.attributeName === 'style') markStyle(r.target);
            else noteLegacy(r.target);
            return;
          }
          var node = r.target;
          if (node.nodeName === 'STYLE' || node.parentNode && node.parentNode.nodeName === 'STYLE') sheets = true;
          for (var i = 0; i < r.addedNodes.length; i++) {
            var one = r.addedNodes[i];
            if (one.nodeName === 'STYLE' || one.nodeName === 'LINK') sheets = true;
            if (one.nodeType === 1) later(one);
          }
          for (var j = 0; j < r.removedNodes.length; j++) {
            var gone = r.removedNodes[j].nodeName;
            if (gone === 'STYLE' || gone === 'LINK') sheets = true;
          }
        });
        // Before the frame is drawn: a new sheet's colours are never seen.
        if (sheets) refresh();
      };

      // What is added is taken in a batch, once a frame and before it is
      // drawn, rather than as each piece arrives: marked, swept for shadow
      // roots, and painted with every element read first and written after,
      // so the page's style is worked out once for all of it. A page adding
      // a thousand things as it loads was worked out a thousand times.
      var queued = [], flushing = false;
      var later = function (node) {
        queued.push(node);
        if (flushing) return;
        flushing = true;
        var frame = 0, timer = 0;
        var go = function () {
          cancelAnimationFrame(frame);
          clearTimeout(timer);
          if (flushing) flush();
        };
        frame = requestAnimationFrame(go);
        timer = setTimeout(go, 100);
      };
      var flush = function () {
        flushing = false;
        var batch = queued.filter(function (n) { return n.isConnected; });
        queued = [];
        batch.forEach(function (n) { markups(n); if (started) shadows(n); });
        if (showing && unreadable) { toPaint.push.apply(toPaint, batch); paintSoon(); }
      };
      // Painting reads every new element's colours, which has the page's
      // style worked out first; on a page that changes its own style all the
      // time that is 50 ms a read. So it waits a little and takes what came
      // meanwhile in one go: the twins have what the readable sheets colour
      // at once, and only what an unreadable one colours waits.
      var toPaint = [], paintTimer = 0;
      var paintSoon = function () {
        if (paintTimer) return;
        paintTimer = setTimeout(function () {
          paintTimer = 0;
          var batch = toPaint.filter(function (n) { return n.isConnected; });
          toPaint = [];
          if (showing && batch.length) paint(batch);
        }, 300);
      };
      var watch = function (root) {
        var o = new MutationObserver(changed);
        o.observe(root, { childList: true, subtree: true, characterData: true,
                          attributes: true, attributeFilter: ['style', 'bgcolor', 'text', 'color', 'fill', 'stroke'] });
        observers.push(o);
      };

      var start = function (ready) {
        if (started) return;
        started = true;
        onReady = ready;
        markups(doc.body);
        shadows(doc);
        wake();
        // A new sheet in the <head> wakes it again, for the page's life.
        if (doc.head) new MutationObserver(function (records) {
          if (records.some(function (r) { return r.target.nodeName === 'STYLE' || [].some.call(r.addedNodes, function (n) { return n.nodeName === 'STYLE' || n.nodeName === 'LINK'; }); })) {
            refresh();
            wake();
          }
        }).observe(doc.head, { childList: true, subtree: true, characterData: true });
        if (doc.readyState !== 'complete') addEventListener('load', function () { wake(); refresh(); if (showing) paint([doc.body]); }, { once: true });
        refresh();
        // A <link> is only a sheet once it has loaded, and a picture can
        // only be looked at once it has.
        doc.addEventListener('load', function (e) {
          if (e.target.nodeName === 'LINK') refresh();
          if (e.target.nodeName === 'IMG') lookAt(e.target);
        }, true);
      };

      var own = function () {
        var list = [ground, marks];
        twins.forEach(function (t) { list.push(t.sheet); });
        return list;
      };

      return {
        start: start,
        ready: function () { return readyAt > 0; },
        started: function () { return started; },
        showing: function () { return showing; },
        show: function (on) {
          if (on === showing) return;
          showing = on;
          if (on) roots.forEach(place);
          quietly(function () { own().forEach(function (s) { s.disabled = !on; }); });
          // Read with the twins in place, so what they took is left alone.
          if (on) paint([doc.body]);
        },
        // The page has moved to another address of its own: watched again.
        again: function () {
          if (!started) return;
          wake();
          refresh();
          markups(doc.body);
          if (showing) paint([doc.body]);
        },
        // The page's own colours, read with ours set aside for a moment.
        aside: function (read) {
          if (!showing) return read();
          var result;
          quietly(function () {
            own().forEach(function (s) { s.disabled = true; });
            result = read();
            own().forEach(function (s) { s.disabled = false; });
          });
          return result;
        },
        stats: function () {
          var n = 0;
          twins.forEach(function (t) { if (t.text) n += t.sheet.cssRules.length; });
          return { sheets: twins.size, twins: n, marked: styled.count(), painted: doc.querySelectorAll('[' + PAINT + ']').length, unreadable: unreadable,
                   ms: Math.round(spent), shadows: roots.length - 1, watching: awake,
                   took: { twins: Math.round(took.twins), paint: Math.round(took.paint), paints: took.paints,
                           markups: Math.round(took.markups), refreshes: took.refreshes,
                           paintRead: Math.round(took.paintRead), paintWrite: Math.round(took.paintWrite), painted: took.painted } };
        }
      };
    }
    """#
}
