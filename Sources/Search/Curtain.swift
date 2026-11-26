import Foundation
import WebKit

// Taking things off a page and keeping them off.
//
// Point at a cookie bar, a newsletter overlay, a sidebar of related nonsense —
// it goes, and it is still gone next time. Everything is remembered by site, as
// a list of selectors, and put back on by a stylesheet injected before the page
// has drawn a single frame, so nothing is ever seen appearing and vanishing.

struct Veil: Codable, Identifiable, Equatable {
    var selector: String
    /// What it was, in words, so the list of what you have hidden reads like
    /// something rather than like a stylesheet.
    var label: String
    /// How big it was and where it sat — measured when you hid it, because a
    /// hidden thing has no size to measure later. Two elements can easily read
    /// the same; they rarely have the same shape in the same corner.
    var note: String?
    var date: Date
    /// What it was, as words: its kind, the picture it carried, what it
    /// said (Veiling.marks). Kept for a thing named by where it sat or by
    /// a product id rather than by an id of its own, and checked on every
    /// later visit before it is hidden: on a page built by script after it
    /// loads, the same place held another thing, a cart's product instead
    /// of the card that was hidden (idea 1194). Nil for a steady id or a
    /// test hook, and for every rule saved before, which are worn as they
    /// always were.
    var print: String?
    /// Where else to look for it when its place holds something else: its
    /// kind and steady classes, with no place (`div.card`). Only an exact
    /// match, and only one, is hidden there.
    var family: String?
    /// Moved or resized rather than taken off: a drag on what is outlined,
    /// or on its right or bottom edge, with Settings › Browsing › Pages ›
    /// Move and resize with Hide Elements on. Nil: hidden.
    var shape: Shape?

    var id: String { selector }

    /// Where a thing was moved to and how big it was made, in CSS pixels:
    /// only what was changed.
    struct Shape: Codable, Equatable {
        var width: Double?
        var height: Double?
        var dx: Double?
        var dy: Double?

        /// This one's changes over an earlier one's.
        func over(_ old: Shape?) -> Shape {
            Shape(width: width ?? old?.width, height: height ?? old?.height,
                  dx: dx ?? old?.dx, dy: dy ?? old?.dy)
        }

        var moved: Bool { dx != nil || dy != nil }
        var resized: Bool { width != nil || height != nil }

        /// What was done, in words, for the list of what was changed here.
        var done: String { moved && resized ? "Moved and resized" : moved ? "Moved" : "Resized" }
    }

    /// The name the page's marks give it (data-office-veiled), the same
    /// from one launch to the next.
    var key: String {
        var hash: UInt32 = 2_166_136_261
        for byte in (selector + "\n" + (print ?? "")).utf8 {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
        return "v" + String(hash, radix: 36)
    }

    /// What finds it on the page as hidden: the mark for one that is
    /// checked, the selector for one that isn't.
    var target: String { print == nil ? selector : "[data-office-veiled~=\"\(key)\"]" }

    /// Its rule in the site's stylesheet. One that is checked hides only
    /// what the page script marked as it (Veiling.marks), and carries what
    /// to check in a comment the script reads from the same sheet.
    var rule: String {
        func rule(_ selector: String) -> String {
            shape.map { Curtain.shapeRule(selector, $0) } ?? Curtain.rule(selector)
        }
        guard let print else { return rule(selector) }
        let guarded: [String: String] = ["k": key, "s": selector, "p": print, "f": family ?? ""]
        // JSONEncoder writes "/" as "\/", so no "*/" ends the comment early.
        let json = (try? JSONEncoder().encode(guarded)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return "/*office-guard \(json)*/\n" + rule(target)
    }
}

@MainActor
final class Curtain: ObservableObject {
    @Published private(set) var byHost: [String: [Veil]] = [:]
    private var saving = false

    init() { load() }

    func host(of url: URL?) -> String? {
        guard let host = url?.host()?.lowercased() else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    func veils(on host: String?) -> [Veil] {
        guard let host else { return [] }
        return byHost[host] ?? []
    }

    func hide(_ veil: Veil, on host: String) {
        var list = byHost[host] ?? []
        guard !list.contains(where: { $0.selector == veil.selector }) else { return }
        list.append(veil)
        byHost[host] = list
        save()
    }

    /// One thing moved or resized (Curtain.reshaped).
    func shape(_ veil: Veil, on host: String) {
        guard let list = Curtain.reshaped(veil, in: byHost[host] ?? []) else { return }
        byHost[host] = list
        save()
    }

    /// `veil` moved or resized, kept with what was done to it before and
    /// last in `list`, so ⌘Z takes this change back first. Nil when `list`
    /// hides it already: there is nothing on the page to move.
    nonisolated static func reshaped(_ veil: Veil, in list: [Veil]) -> [Veil]? {
        guard let shape = veil.shape else { return nil }
        let old = list.first { $0.selector == veil.selector }
        if let old, old.shape == nil { return nil }
        var made = veil
        made.shape = shape.over(old?.shape)
        made.label = (made.shape?.done ?? "Moved") + " · " + veil.label
        return list.filter { $0.selector != veil.selector } + [made]
    }

    /// Put one back.
    func restore(_ veil: Veil, on host: String) {
        byHost[host] = (byHost[host] ?? []).filter { $0.selector != veil.selector }
        if byHost[host]?.isEmpty == true { byHost[host] = nil }
        save()
    }

    /// Put the last one back — ⌘Z, while you are still pointing at things.
    @discardableResult
    func undo(on host: String) -> Veil? {
        guard var list = byHost[host], let last = list.popLast() else { return nil }
        byHost[host] = list.isEmpty ? nil : list
        save()
        return last
    }

    func restoreAll(on host: String) {
        byHost[host] = nil
        save()
    }

    /// The stylesheet for a site. Each selector stands alone in its own rule:
    /// one selector the browser can't parse would otherwise take the whole
    /// list down with it.
    /// One selector may be left out — that is how a row in the list shows you
    /// what it is offering to bring back, without bringing it back.
    func css(on host: String?, without spared: String? = nil) -> String {
        veils(on: host)
            .filter { $0.selector != spared }
            .map(\.rule)
            .joined(separator: "\n")
    }

    /// One thing taken off. A page that wants its banner seen says so with
    /// `!important` too, and the more particular of two such rules wins:
    /// `#consent #banner { display: block !important }` kept `#banner` on
    /// screen while the list said it was hidden (#1270). Three ids no
    /// element has lift this rule above any a page is likely to write; only
    /// a page's own `style="… !important"` still outranks it. `:is()` keeps
    /// what you picked whole, and one it can't read matches nothing rather
    /// than taking the rule down.
    nonisolated static func rule(_ selector: String) -> String {
        ":is(\(selector)):not(#office-veiled):not(#office-veiled):not(#office-veiled) { display: none !important; }"
    }

    /// One thing moved or resized, with the same weight as a hiding rule.
    /// Moved with `translate`, which leaves the page's own layout where it
    /// was, so nothing around it jumps.
    nonisolated static func shapeRule(_ selector: String, _ shape: Veil.Shape) -> String {
        func px(_ value: Double) -> String { "\(Int(value.rounded()))px" }
        var parts: [String] = []
        if shape.resized { parts.append("box-sizing: border-box !important") }
        if let width = shape.width {
            parts += ["width: \(px(width)) !important", "max-width: none !important",
                      "min-width: 0 !important", "flex: none !important"]
        }
        if let height = shape.height {
            parts += ["height: \(px(height)) !important", "max-height: none !important", "min-height: 0 !important"]
        }
        if shape.moved { parts.append("translate: \(px(shape.dx ?? 0)) \(px(shape.dy ?? 0)) !important") }
        return ":is(\(selector)):not(#office-veiled):not(#office-veiled):not(#office-veiled) { \(parts.joined(separator: "; ")); }"
    }

    // MARK: - the file

    private static var file: URL { Store.file("hidden.json") }

    private func load() {
        guard let data = try? Data(contentsOf: Curtain.file),
              let stored = try? JSONDecoder().decode([String: [Veil]].self, from: data)
        else { return }
        byHost = stored
    }

    private func save() {
        guard !saving else { return }
        saving = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            saving = false
            let snapshot = byHost
            let file = Curtain.file
            DispatchQueue.global(qos: .utility).async {
                guard let data = try? JSONEncoder().encode(snapshot) else { return }
                try? FileManager.default.createDirectory(
                    at: file.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try? data.write(to: file, options: .atomic)
            }
        }
    }
}

/// Carries a chosen element back from the page.
final class VeilRelay: NSObject, WKScriptMessageHandler {
    static let name = "officeVeil"

    weak var tab: Tab?

    func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any] else { return }
        MainActor.assumeIsolated {
            if let trouble = body["trouble"] as? String {
                tab?.pickingFailed(trouble)
            } else if body["off"] as? Bool == true {
                tab?.pickingEnded()
            } else if let selector = body["selector"] as? String {
                let print = body["print"] as? String, family = body["family"] as? String
                // A drag rather than a click: moved or resized, not hidden.
                let shape = (body["shape"] as? [String: Any]).map {
                    Veil.Shape(width: $0["width"] as? Double, height: $0["height"] as? Double,
                               dx: $0["dx"] as? Double, dy: $0["dy"] as? Double)
                }
                let veil = Veil(
                    selector: selector,
                    label: body["label"] as? String ?? selector,
                    note: body["note"] as? String ?? "",
                    date: Date(),
                    print: print?.isEmpty == false ? print : nil,
                    family: family?.isEmpty == false ? family : nil,
                    shape: shape
                )
                if shape != nil { tab?.shaped(veil) } else { tab?.picked(veil) }
            }
        }
    }
}

enum Veiling {
    /// A stylesheet put in before the document has a body, so nothing is ever
    /// seen arriving and then leaving.
    static func style(_ css: String) -> String {
        let escaped = css
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")
        return """
        (function () {
          \(sheets)
          \(marks)
          window.__officeSheet('office-veil', `\(escaped)`);
          window.__officeGuard(`\(escaped)`);
        })();
        """
    }

    /// Puts `css` in the sheet named `id`, made the first time. A sheet
    /// made by script and adopted by the document, not a <style> element:
    /// a site whose Content-Security-Policy limits styles (style-src) turned
    /// the element away, and everything Hide Elements took off stayed on the
    /// page (#1270). The element is kept only for a WebKit without them.
    static let sheets = """
    if (!window.__officeSheet) window.__officeSheet = function (id, css) {
      var all = window.__officeSheets || (window.__officeSheets = {});
      try {
        var made = all[id] || (all[id] = new CSSStyleSheet());
        made.replaceSync(css);
        var adopted = document.adoptedStyleSheets;
        if (adopted.indexOf(made) < 0) document.adoptedStyleSheets = adopted.concat([made]);
        return;
      } catch (e) {}
      var s = document.getElementById(id);
      if (!s) {
        s = document.createElement('style');
        s.id = id;
        (document.head || document.documentElement).appendChild(s);
      }
      s.textContent = css;
    };
    """

    /// What a thing is, and the marks that say which things on the page are
    /// the ones hidden (idea 1194). A thing named by where it sat, or by a
    /// product id, is hidden only once it is seen to be the same thing:
    /// what it says close enough at the same place, or word for word, the
    /// only one, elsewhere among its kind. Checked again whenever the page
    /// changes, before it is drawn (a MutationObserver's turn comes before
    /// the frame), so a grid built after load, or built in another order,
    /// gets neither a hidden card back nor a cart's product hidden instead.
    /// Nothing the same enough, nothing hidden: a missed hide is put right
    /// with one more pick, a wrong one hides what you came for.
    static let marks = """
    if (!window.__officePrint) (function () {
      // Its kind, the picture it carries, and what it says, from the
      // document rather than the screen, so a hidden thing reads the same.
      window.__officePrint = function (el) {
        var media = /^(IMG|VIDEO|IFRAME)$/.test(el.tagName) ? el : el.querySelector('img,video,iframe');
        var src = media ? (media.getAttribute('src') || '').split('?')[0].slice(0, 200) : '';
        var text = (el.textContent || '').replace(/\\s+/g, ' ').trim().slice(0, 160);
        return el.tagName.toLowerCase() + '\\n' + src + '\\n' + text;
      };
      var parts = function (print) {
        var at = print.indexOf('\\n'), next = print.indexOf('\\n', at + 1);
        return { tag: print.slice(0, at), src: print.slice(at + 1, next), text: print.slice(next + 1) };
      };
      var words = function (text) {
        var set = {};
        text.toLowerCase().split(' ').forEach(function (w) { if (w) set[w] = true; });
        return Object.keys(set);
      };
      // The same thing at the same place: of the same kind, and three
      // quarters of its words in common (a price or a date may move), or,
      // with no words at all, the same picture.
      var alike = function (el, print) {
        var was = parts(print), now = parts(window.__officePrint(el));
        if (was.tag !== now.tag) return false;
        if (!was.text || !now.text) return !was.text && !now.text && was.src === now.src;
        var a = words(was.text), b = words(now.text), shared = 0;
        a.forEach(function (w) { if (b.indexOf(w) >= 0) shared++; });
        return shared / (a.length + b.length - shared) >= 0.75;
      };
      var guards = [], seen = null;
      var mark = function (el, key, on) {
        var list = (el.getAttribute('data-office-veiled') || '').split(' ').filter(function (k) { return k && k !== key; });
        if (on) list.push(key);
        if (list.length) el.setAttribute('data-office-veiled', list.join(' '));
        else el.removeAttribute('data-office-veiled');
      };
      var pass = function () {
        guards.forEach(function (g) {
          var found = [];
          try {
            found = Array.prototype.filter.call(document.querySelectorAll(g.s), function (el) { return alike(el, g.p); });
          } catch (e) {}
          // Not at its place: word for word, and the only one, among its kind.
          var said = parts(g.p).text;
          if (!found.length && g.f && said.length >= 4) {
            try {
              var kin = document.querySelectorAll(g.f);
              for (var i = 0; i < kin.length && i < 1000; i++) {
                if (window.__officePrint(kin[i]) === g.p) found.push(kin[i]);
              }
            } catch (e) {}
          }
          if (found.length !== 1) found = [];
          document.querySelectorAll('[data-office-veiled~="' + g.k + '"]').forEach(function (el) {
            if (found.indexOf(el) < 0) mark(el, g.k, false);
          });
          found.forEach(function (el) { mark(el, g.k, true); });
        });
      };
      // The things to check, read from the comments in the site's sheet.
      window.__officeGuard = function (css) {
        guards = [];
        var re = /\\/\\*office-guard (.*?)\\*\\//g, m;
        while ((m = re.exec(css))) {
          try { guards.push(JSON.parse(m[1])); } catch (e) {}
        }
        if (guards.length && !seen) {
          seen = new MutationObserver(function () { if (guards.length) pass(); });
          seen.observe(document, { childList: true, subtree: true, characterData: true,
                                   attributes: true, attributeFilter: ['src', 'class', 'id'] });
        }
        pass();
      };
    })();
    """

    /// The pointing mode. Loaded on every page but asleep: it costs one closure
    /// and a few functions until somebody actually asks for it.
    static let picker = """
    (function () {
      if (window.__officeVeil) return;
      var frame = null, tag = null, target = null, live = false;
      // What the pointer is over, and the things ↓ steps back into once ↑
      // has made the outline wider than that.
      var under = null, trail = [];
      // ⌥ held: the press takes every element like the one outlined (idea
      // 1195), as Arc's "Zap all related" does, and the outline says how
      // many that is before anything goes.
      var all = false;
      // Moving and resizing on (Settings, off unless turned on): a press on
      // the outlined thing waits for the button to come up, a click hiding
      // it and a drag moving it, or resizing it from near its right or
      // bottom edge. Off, a press hides at once, as it always has.
      var shaping = false, press = null, EDGE = 10;
      // What the hand sets while it drags, put back as the page had it once
      // the site's stylesheet holds the change.
      var HELD = ['translate', 'width', 'height', 'max-width', 'min-width', 'max-height', 'min-height', 'flex', 'box-sizing'];

      \(sheets)
      \(marks)

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
        tag.textContent = name(el) + (all ? ' · ' + likeIt(el) : '');
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
        var text = (el.innerText || '').trim().replace(/\\s+/g, ' ');
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
        return /^[a-zA-Z][\\w-]{2,29}$/.test(c) && !/\\d{3,}/.test(c) &&
               !/^(css|sc|jsx|emotion|svelte|styles?)-/.test(c);
      }

      // What the selector names must be this one thing, now: not one
      // like it, and not several (a list of cards, one of them picked).
      function only(sel, el) {
        try {
          var all = document.querySelectorAll(sel);
          return all.length === 1 && all[0] === el;
        } catch (e) { return false; }
      }

      // An id a person gave it, not one a framework counted out.
      function steadyId(id) {
        return /^[a-zA-Z][\\w-]{0,59}$/.test(id) && !/\\d{3,}/.test(id);
      }

      // Its place among its parent's children of its kind, always written
      // out: a step without it would match every sibling of that kind that
      // a later visit brings (idea 1133).
      function step(node) {
        var tagName = node.tagName.toLowerCase(), parent = node.parentElement;
        if (!parent) return tagName;
        var kin = Array.prototype.filter.call(parent.children, function (c) {
          return c.tagName === node.tagName;
        });
        return tagName + ':nth-of-type(' + (kin.indexOf(node) + 1) + ')';
      }

      // A path of such steps from the nearest thing with a steady id of its
      // own (or from the body), the picked thing's own step with its steady
      // classes too: it can name one element at most, and when the page is
      // laid out otherwise on a later visit it names none rather than the
      // wrong one.
      function path(el, anchored) {
        var parts = [], node = el;
        while (node && node.nodeType === 1 && node !== document.documentElement) {
          if (node === document.body) { parts.unshift('body'); break; }
          if (anchored && node !== el && node.id && steadyId(node.id) && only('#' + CSS.escape(node.id), node)) {
            parts.unshift('#' + CSS.escape(node.id));
            break;
          }
          var here = step(node);
          if (node === el) {
            var classes = (typeof el.className === 'string' ? el.className.trim().split(/\\s+/) : [])
              .filter(steady).slice(0, 2);
            if (classes.length) here = here.replace(/:nth-of-type/, '.' + classes.map(CSS.escape).join('.') + ':nth-of-type');
          }
          parts.unshift(here);
          node = node.parentElement;
        }
        return parts.join(' > ');
      }

      // Its kind and steady classes, with no place: where to look for it
      // when its place holds something else. None without a class, which
      // would be every element of its kind.
      function family(el) {
        var classes = (typeof el.className === 'string' ? el.className.trim().split(/\\s+/) : [])
          .filter(steady).slice(0, 2);
        return classes.length ? el.tagName.toLowerCase() + '.' + classes.map(CSS.escape).join('.') : '';
      }

      // A data-* attribute that names the thing itself (a product's id, a
      // SKU) rather than a state or a place.
      var identities = /(^|-)(id|sku|ean|gtin|ref|product|item|offer)(-|$)/i;

      // The most specific name that still survives the page's next visit:
      // its own steady id; a hook the site put there for its own tests;
      // the product id it carries; else its place. Each checked to name
      // exactly this element, or none is given and nothing is hidden.
      // Words a page reuses (a role, an aria-label, a class on its own)
      // once named the only one there was, and on a later visit every one
      // of them (idea 1133). The last two come with what the thing is, and
      // are hidden on a later visit only once they are seen to be that
      // thing again (Veiling.marks, idea 1194).
      function selectorFor(el) {
        if (el.id && steadyId(el.id) && only('#' + CSS.escape(el.id), el)) return { s: '#' + CSS.escape(el.id) };

        var tagName = el.tagName.toLowerCase();
        var hooks = ['data-testid', 'data-test', 'data-qa', 'data-cy'];
        for (var i = 0; i < hooks.length; i++) {
          var v = el.getAttribute && el.getAttribute(hooks[i]);
          if (v) {
            var s = tagName + '[' + hooks[i] + '="' + CSS.escape(v) + '"]';
            if (only(s, el)) return { s: s };
          }
        }

        var print = window.__officePrint(el);
        var attributes = el.attributes || [];
        for (var j = 0; j < attributes.length; j++) {
          var a = attributes[j];
          if (a.name.indexOf('data-') !== 0 || !identities.test(a.name.slice(5))) continue;
          if (!a.value || a.value.length > 80) continue;
          var named = tagName + '[' + a.name + '="' + CSS.escape(a.value) + '"]';
          if (only(named, el)) return { s: named, p: print };
        }

        var anchored = path(el, true);
        if (only(anchored, el)) return { s: anchored, p: print, f: family(el) };
        var whole = path(el, false);
        return only(whole, el) ? { s: whole, p: print, f: family(el) } : null;
      }

      // How many are like it, in words, for the outline while ⌥ is held.
      function likeIt(el) {
        var n = alike(el);
        return n > 1 ? 'all ' + n + ' like it' : 'nothing else like it';
      }

      function alike(el) {
        var kind = family(el);
        if (!kind) return 0;
        try { return document.querySelectorAll(kind).length; } catch (e) { return 0; }
      }

      function own(el) {
        return HELD.map(function (k) { return [k, el.style.getPropertyValue(k), el.style.getPropertyPriority(k)]; });
      }

      function putBack(p) {
        p.own.forEach(function (o) {
          if (o[1]) p.el.style.setProperty(o[0], o[1], o[2]); else p.el.style.removeProperty(o[0]);
        });
      }

      function edgeOf(el, x, y) {
        var r = el.getBoundingClientRect();
        var right = x <= r.right && x >= r.right - EDGE && y >= r.top && y <= r.bottom;
        var bottom = y <= r.bottom && y >= r.bottom - EDGE && x >= r.left && x <= r.right;
        return right && bottom ? 'both' : right ? 'width' : bottom ? 'height' : null;
      }

      function cursorFor(edge) {
        return edge === 'both' ? 'nwse-resize' : edge === 'width' ? 'ew-resize'
             : edge === 'height' ? 'ns-resize' : 'crosshair';
      }

      // Where the site's stylesheet has moved it already, so a second drag
      // goes on from there.
      function shift(el) {
        var t = getComputedStyle(el).translate;
        if (!t || t === 'none') return { dx: 0, dy: 0 };
        var p = t.split(/\\s+/);
        return { dx: parseFloat(p[0]) || 0, dy: parseFloat(p[1] || '0') || 0 };
      }

      function drag(e) {
        var dx = e.clientX - press.x, dy = e.clientY - press.y;
        // A hand never holds quite still: a few pixels is still a click.
        if (!press.moved && Math.abs(dx) + Math.abs(dy) < 4) return;
        press.moved = true;
        var el = press.el, st = el.style;
        if (press.mode === 'move') {
          press.dx = press.base.dx + dx;
          press.dy = press.base.dy + dy;
          st.setProperty('translate', press.dx + 'px ' + press.dy + 'px', 'important');
        } else {
          st.setProperty('box-sizing', 'border-box', 'important');
          if (press.mode !== 'height') {
            press.width = Math.max(20, press.rect.width + dx);
            st.setProperty('width', press.width + 'px', 'important');
            st.setProperty('max-width', 'none', 'important');
            st.setProperty('min-width', '0', 'important');
            st.setProperty('flex', 'none', 'important');
          }
          if (press.mode !== 'width') {
            press.height = Math.max(20, press.rect.height + dy);
            st.setProperty('height', press.height + 'px', 'important');
            st.setProperty('max-height', 'none', 'important');
            st.setProperty('min-height', '0', 'important');
          }
        }
        place(el);
      }

      function onMove(e) {
        if (!live) return;
        if (press) { e.preventDefault(); return drag(e); }
        all = e.altKey;
        // On the outlined thing's right or bottom edge: it stays outlined,
        // with the cursor that says it can be pulled.
        if (shaping && target) {
          var edge = edgeOf(target, e.clientX, e.clientY);
          document.documentElement.style.cursor = cursorFor(edge);
          if (edge) return place(target);
        }
        var el = document.elementFromPoint(e.clientX, e.clientY);
        if (!el || el === frame || el === document.documentElement || el === document.body) return;
        // Still over the same thing: a wider choice made with ↑ stays,
        // drawn again where it is now.
        if (el === under && target) return place(target);
        under = el;
        trail = [];
        target = el;
        place(el);
      }

      // ↑ the thing around the one outlined, ↓ back in again. The pointer
      // lands on what is innermost — the words of a cookie banner, not the
      // banner — and hiding those left the banner where it was (#1270).
      function onKey(e) {
        if (live && e.key === 'Alt') {
          all = e.type === 'keydown';
          if (target) place(target);
          return;
        }
        if (e.type !== 'keydown') return;
        if (!live || !target || e.metaKey || e.ctrlKey || e.altKey) return;
        if (e.key === 'ArrowUp') {
          var up = target.parentElement;
          if (up && up !== document.body && up !== document.documentElement) {
            trail.push(target);
            target = up;
            place(target);
          }
        } else if (e.key === 'ArrowDown') {
          if (trail.length) {
            target = trail.pop();
            place(target);
          }
        } else {
          return;
        }
        swallow(e);
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
        if (shaping && !e.altKey) {
          press = { el: el, x: e.clientX, y: e.clientY, mode: edgeOf(el, e.clientX, e.clientY) || 'move',
                    rect: el.getBoundingClientRect(), base: shift(el), moved: false, own: own(el) };
          return;
        }
        take(el, e.altKey);
      }

      // The button up after a press held for moving: a drag is kept as a
      // move or a resize, a press that never moved hides, as a click.
      function onUp(e) {
        swallow(e);
        if (!live || !press) return;
        var p = press, el = p.el;
        press = null;
        if (!p.moved) return take(el, false);
        var sel = selectorFor(el);
        if (!sel) {
          putBack(p);
          place(el);
          window.webkit.messageHandlers.officeVeil.postMessage({ trouble: 'it has no name of its own on this page' });
          return;
        }
        var made = p.mode === 'move' ? { dx: Math.round(p.dx), dy: Math.round(p.dy) } : {};
        if (p.width !== undefined) made.width = Math.round(p.width);
        if (p.height !== undefined) made.height = Math.round(p.height);
        window.webkit.messageHandlers.officeVeil.postMessage({
          selector: sel.s, print: sel.p || '', family: sel.f || '',
          label: name(el), note: shape(el), shape: made
        });
        // The site's stylesheet holds it from here; the hand's own styles
        // go once that has come, and the page's own inline ones come back.
        setTimeout(function () { putBack(p); place(el); }, 700);
      }

      function take(el, every) {
        try {
          if (every) {
            // Every one like it, now and on later visits, new ones too: a
            // pattern, not one thing, so it is worn as it is, unchecked.
            var n = alike(el);
            if (n < 2) throw 'nothing else here looks like it';
            window.webkit.messageHandlers.officeVeil.postMessage({
              selector: family(el),
              label: 'All like “' + name(el) + '” (' + n + ')',
              note: shape(el)
            });
            target = null;
            under = null;
            trail = [];
            if (frame) frame.style.display = 'none';
            return;
          }
          var sel = selectorFor(el);
          if (!sel) throw 'it has no name of its own on this page';
          window.webkit.messageHandlers.officeVeil.postMessage({
            selector: sel.s,
            print: sel.p || '',
            family: sel.f || '',
            label: name(el),
            note: shape(el)
          });
        } catch (err) {
          window.webkit.messageHandlers.officeVeil.postMessage({ trouble: String(err) });
        }
        target = null;
        under = null;
        trail = [];
        if (frame) frame.style.display = 'none';
      }

      var presses = ['pointerdown', 'mousedown', 'pointerup', 'mouseup', 'click',
                     'dblclick', 'contextmenu', 'touchstart'];
      function handler(kind) { return kind === 'pointerdown' ? onPress : kind === 'pointerup' ? onUp : swallow; }

      function off() {
        if (!live) return;
        live = false;
        all = false;
        // Let go mid-drag: the page as it was.
        if (press && press.moved) putBack(press);
        press = null;
        target = null;
        under = null;
        trail = [];
        if (frame) frame.style.display = 'none';
        document.documentElement.style.cursor = '';
        document.removeEventListener('mousemove', onMove, true);
        document.removeEventListener('pointermove', onMove, true);
        document.removeEventListener('keydown', onKey, true);
        document.removeEventListener('keyup', onKey, true);
        window.removeEventListener('pagehide', off);
        presses.forEach(function (kind) {
          document.removeEventListener(kind, handler(kind), true);
        });
        window.webkit.messageHandlers.officeVeil.postMessage({ off: true });
      }

      window.__officeVeil = {
        on: function (shapes) {
          if (live) return;
          live = true;
          shaping = !!shapes;
          chrome();
          document.documentElement.style.cursor = 'crosshair';
          document.addEventListener('mousemove', onMove, true);
          document.addEventListener('pointermove', onMove, true);
          document.addEventListener('keydown', onKey, true);
          document.addEventListener('keyup', onKey, true);
          // The page going away ends the pointing with it. Kept for Back,
          // it would have come back still swallowing every click, with
          // Search no longer pointing at anything.
          window.addEventListener('pagehide', off);
          presses.forEach(function (kind) {
            document.addEventListener(kind, handler(kind), true);
          });
        },
        off: off,
        // Show one hidden thing for as long as the pointer rests on its row.
        // The stylesheet is rebuilt without that one selector rather than
        // fighting it with another rule, so the element comes back with the
        // layout it actually had.
        peek: function (css, sel) {
          window.__officeSheet('office-veil', css);
          window.__officeGuard(css);
          window.__officeSheet('office-peek', sel +
            ' { outline: 2px solid rgba(23,23,23,.9) !important; outline-offset: 2px !important; }');
          try {
            var el = document.querySelector(sel);
            if (el) el.scrollIntoView({ block: 'center', behavior: 'smooth' });
          } catch (e) {}
        },
        unpeek: function (css) {
          window.__officeSheet('office-veil', css);
          window.__officeGuard(css);
          window.__officeSheet('office-peek', '');
        }
      };
    })();
    """
}
