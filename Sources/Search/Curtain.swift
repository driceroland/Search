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

    var id: String { selector }
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

    func hide(_ selector: String, label: String, note: String, on host: String) {
        var list = byHost[host] ?? []
        guard !list.contains(where: { $0.selector == selector }) else { return }
        list.append(Veil(selector: selector, label: label, note: note, date: Date()))
        byHost[host] = list
        save()
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
            .map { Curtain.rule($0.selector) }
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
                tab?.picked(
                    selector: selector,
                    label: body["label"] as? String ?? selector,
                    note: body["note"] as? String ?? ""
                )
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
          window.__officeSheet('office-veil', `\(escaped)`);
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

    /// The pointing mode. Loaded on every page but asleep: it costs one closure
    /// and a few functions until somebody actually asks for it.
    static let picker = """
    (function () {
      if (window.__officeVeil) return;
      var frame = null, tag = null, target = null, live = false;
      // What the pointer is over, and the things ↓ steps back into once ↑
      // has made the outline wider than that.
      var under = null, trail = [];

      \(sheets)

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

      // The most specific name that still survives the page's next visit:
      // its own steady id; a hook the site put there for its own tests;
      // else its place. Each checked to name exactly this element, or none
      // is given and nothing is hidden. Words a page reuses (a role, an
      // aria-label, a class on its own) once named the only one there
      // was, and on a later visit every one of them (idea 1133).
      function selectorFor(el) {
        if (el.id && steadyId(el.id) && only('#' + CSS.escape(el.id), el)) return '#' + CSS.escape(el.id);

        var hooks = ['data-testid', 'data-test', 'data-qa', 'data-cy'];
        for (var i = 0; i < hooks.length; i++) {
          var v = el.getAttribute && el.getAttribute(hooks[i]);
          if (v) {
            var s = el.tagName.toLowerCase() + '[' + hooks[i] + '="' + CSS.escape(v) + '"]';
            if (only(s, el)) return s;
          }
        }

        var anchored = path(el, true);
        if (only(anchored, el)) return anchored;
        var whole = path(el, false);
        return only(whole, el) ? whole : null;
      }

      function onMove(e) {
        if (!live) return;
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
        try {
          var sel = selectorFor(el);
          if (!sel) throw 'it has no name of its own on this page';
          window.webkit.messageHandlers.officeVeil.postMessage({
            selector: sel,
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

      function off() {
        if (!live) return;
        live = false;
        target = null;
        under = null;
        trail = [];
        if (frame) frame.style.display = 'none';
        document.documentElement.style.cursor = '';
        document.removeEventListener('mousemove', onMove, true);
        document.removeEventListener('pointermove', onMove, true);
        document.removeEventListener('keydown', onKey, true);
        window.removeEventListener('pagehide', off);
        presses.forEach(function (kind) {
          document.removeEventListener(kind, kind === 'pointerdown' ? onPress : swallow, true);
        });
        window.webkit.messageHandlers.officeVeil.postMessage({ off: true });
      }

      window.__officeVeil = {
        on: function () {
          if (live) return;
          live = true;
          chrome();
          document.documentElement.style.cursor = 'crosshair';
          document.addEventListener('mousemove', onMove, true);
          document.addEventListener('pointermove', onMove, true);
          document.addEventListener('keydown', onKey, true);
          // The page going away ends the pointing with it. Kept for Back,
          // it would have come back still swallowing every click, with
          // Search no longer pointing at anything.
          window.addEventListener('pagehide', off);
          presses.forEach(function (kind) {
            document.addEventListener(kind, kind === 'pointerdown' ? onPress : swallow, true);
          });
        },
        off: off,
        // Show one hidden thing for as long as the pointer rests on its row.
        // The stylesheet is rebuilt without that one selector rather than
        // fighting it with another rule, so the element comes back with the
        // layout it actually had.
        peek: function (css, sel) {
          window.__officeSheet('office-veil', css);
          window.__officeSheet('office-peek', sel +
            ' { outline: 2px solid rgba(23,23,23,.9) !important; outline-offset: 2px !important; }');
          try {
            var el = document.querySelector(sel);
            if (el) el.scrollIntoView({ block: 'center', behavior: 'smooth' });
          } catch (e) {}
        },
        unpeek: function (css) {
          window.__officeSheet('office-veil', css);
          window.__officeSheet('office-peek', '');
        }
      };
    })();
    """
}
