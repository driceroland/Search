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

    /// A short name for the selector, for the page to say "not this one"
    /// (see Curtain.rule). FNV-1a, so it is the same on every launch.
    var key: String {
        var hash: UInt32 = 2_166_136_261
        for byte in selector.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return String(hash, radix: 36)
    }
}

@MainActor
final class Curtain: ObservableObject {
    @Published private(set) var byHost: [String: [Veil]] = [:]
    private var saving = false

    init() {
        load()
        compile()
    }

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
        changed()
    }

    /// Put one back.
    func restore(_ veil: Veil, on host: String) {
        byHost[host] = (byHost[host] ?? []).filter { $0.selector != veil.selector }
        if byHost[host]?.isEmpty == true { byHost[host] = nil }
        changed()
    }

    /// Put the last one back — ⌘Z, while you are still pointing at things.
    @discardableResult
    func undo(on host: String) -> Veil? {
        guard var list = byHost[host], let last = list.popLast() else { return nil }
        byHost[host] = list.isEmpty ? nil : list
        changed()
        return last
    }

    func restoreAll(on host: String) {
        byHost[host] = nil
        changed()
    }

    /// The stylesheet for a site. Each selector stands alone in its own rule:
    /// one selector the browser can't parse would otherwise take the whole
    /// list down with it.
    /// One selector may be left out — that is how a row in the list shows you
    /// what it is offering to bring back, without bringing it back.
    func css(on host: String?, without spared: String? = nil) -> String {
        veils(on: host)
            .filter { $0.selector != spared }
            .map { "\($0.selector) { display: none !important; }" }
            .joined(separator: "\n")
    }

    // MARK: - the compiled list

    /// Every site's veils as one content rule list. WebKit hides them as
    /// each page loads, before its first style pass, with no script in the
    /// page. Kept apart from Shield's list, so pausing the blocker on a site
    /// never brings back what you hid there.
    private(set) var list: WKContentRuleList?
    /// What `list` was compiled from. A site whose veils differ gets the
    /// stylesheet instead (see loadingCSS).
    private var compiled: [String: [Veil]] = [:]
    /// Bumped on every change, so a compile that finishes after a newer
    /// change is thrown away.
    private var generation = 0
    /// Every tab's controller, so a new list reaches them all.
    private let dressed = NSHashTable<WKUserContentController>.weakObjects()

    /// What a page about to load needs on top of the compiled list: this
    /// site's whole stylesheet while the list doesn't cover it (a hide not
    /// compiled yet, a host WebKit can't take, a compile that failed),
    /// nothing once it does.
    func loadingCSS(on host: String?) -> String {
        guard let host, (compiled[host] ?? []) != veils(on: host) else { return "" }
        return css(on: host)
    }

    /// Every tab asks for the list when it is made.
    func dress(_ controller: WKUserContentController) {
        dressed.add(controller)
        if let list { controller.add(list) }
    }

    /// One veil as a rule. WebKit puts a list on a page only as it loads, and
    /// its hide outranks any stylesheet the page has, so the selector leaves
    /// itself a way out: a key on <html> lets this document show the element
    /// again, put back for good or peeked at from the list.
    static func rule(for veil: Veil, on host: String) -> [String: Any] {
        let out = "[data-office-spare~=\"\(veil.key)\"], [data-office-peek=\"\(veil.key)\"]"
        return [
            "trigger": [
                "url-filter": ".*",
                // Exactly this site, as the stylesheet was: `*host` would
                // reach its subdomains too.
                "if-domain": [host, "www." + host],
                // And only the page itself, not the frames inside it.
                "load-context": ["top-frame"],
            ],
            "action": ["type": "css-display-none", "selector": ":is(\(veil.selector)):not(:is(\(out)) *)"],
        ]
    }

    /// Any change: the old list comes off every tab at once, so a page that
    /// loads before the new one is ready gets the stylesheet, never a list
    /// that still hides what was just put back.
    private func changed() {
        generation += 1
        if let list { dressed.allObjects.forEach { $0.remove(list) } }
        list = nil
        compiled = [:]
        save()
    }

    private func compile() {
        let mine = generation
        // WebKit refuses a whole list over one domain that isn't lowercase
        // ASCII; such a site keeps the stylesheet.
        let snapshot = byHost.filter { host, _ in host.allSatisfy { $0.isASCII && !$0.isUppercase } }
        let rules = snapshot.flatMap { host, veils in veils.map { Curtain.rule(for: $0, on: host) } }
        guard !rules.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: rules),
              let json = String(data: data, encoding: .utf8),
              // In this world's own folder, not WebKit's default store: every
              // Search shares that one, test worlds included, and each has
              // its own hidden.json to compile under the same name.
              let store = WKContentRuleListStore(url: Store.file("Rules"))
        else { return }
        // A failed compile leaves `compiled` empty, so every site keeps the
        // stylesheet it had before this list existed.
        store.compileContentRuleList(forIdentifier: "office-curtain", encodedContentRuleList: json) { [weak self] list, _ in
            MainActor.assumeIsolated {
                guard let self, mine == self.generation, let list else { return }
                self.list = list
                self.compiled = snapshot
                self.dressed.allObjects.forEach { $0.add(list) }
            }
        }
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
            compile()
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
          var sheet = document.getElementById('office-veil');
          if (!sheet) {
            sheet = document.createElement('style');
            sheet.id = 'office-veil';
            (document.head || document.documentElement).appendChild(sheet);
          }
          sheet.textContent = `\(escaped)`;
        })();
        """
    }

    /// The pointing mode. Loaded on every page but asleep: it costs one closure
    /// and a few functions until somebody actually asks for it.
    static let picker = """
    (function () {
      if (window.__officeVeil) return;
      var frame = null, tag = null, target = null, live = false;

      function sheet(id) {
        var s = document.getElementById(id);
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
          ? el.className.trim().split(/\\s+/).filter(steady) : [];
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
        // fighting it with another rule, and the compiled list is told to
        // let it through, so the element comes back with the layout it
        // actually had.
        peek: function (css, sel, key) {
          sheet('office-veil').textContent = css;
          document.documentElement.setAttribute('data-office-peek', key);
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
          document.documentElement.removeAttribute('data-office-peek');
        },
        // Put back for good: the compiled list this page loaded with still
        // names them, so the page is told to let them through.
        spare: function (css, keys) {
          sheet('office-veil').textContent = css;
          var root = document.documentElement;
          var have = (root.getAttribute('data-office-spare') || '').split(' ').filter(Boolean);
          keys.forEach(function (k) { if (have.indexOf(k) < 0) have.push(k); });
          root.setAttribute('data-office-spare', have.join(' '));
        }
      };
    })();
    """
}
