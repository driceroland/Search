import AppKit
import WebKit

// What the bench (Bench.swift) and coding agents (AgentControl.swift) share
// for working a page: the scripts that read it and touch one element of a
// read, real clicks and keys handed to its view, a picture of it, a window
// off every screen for a page nobody is looking at, and the keychain mark a
// switch in Settings leaves. Nothing here decides who may do what: each of
// the two callers does that for itself, and the agent's rules are the
// stricter ones.

// MARK: - the scripts

/// Scripts run in Search's own content world (Web.world): the page's DOM,
/// none of its globals, so the elements kept between calls are out of the
/// page's reach. They came from bench-mcp, which now asks the bench to run
/// them, so the two speak of a page in the same words. Every value given
/// to one goes in as JSON, never as script.
enum PageScripts {
    /// Shared by every script below.
    static let helpers = #"""
    var ROLES = {button:1, link:1, checkbox:1, radio:1, switch:1, tab:1, menuitem:1, menuitemcheckbox:1,
      menuitemradio:1, option:1, combobox:1, textbox:1, searchbox:1, slider:1, spinbutton:1, listbox:1,
      heading:1, dialog:1, alertdialog:1, alert:1, treeitem:1, gridcell:1, iframe:1};
    var SEL = 'a[href],area[href],button,input:not([type=hidden]),select,textarea,summary,[contenteditable],' +
      '[role],[tabindex],h1,h2,h3,h4,h5,h6,iframe';
    // Fields once seen as secret stay secret: a "show password" button
    // turning one into a text field doesn't hand its value over.
    var SECRETS = globalThis.__searchSecrets || (globalThis.__searchSecrets = new WeakSet());
    function squash(s) { return String(s == null ? '' : s).replace(/\s+/g, ' ').trim().slice(0, 160); }
    function visible(el) {
      var r = el.getBoundingClientRect();
      if (r.width === 0 && r.height === 0) return false;
      if (el.checkVisibility && !el.checkVisibility({ checkOpacity: true, checkVisibilityCSS: true })) return false;
      return !el.closest('[aria-hidden=true],[inert]');
    }
    function role(el) {
      var r = (el.getAttribute('role') || '').trim().split(/\s+/)[0];
      if (r && r !== 'none' && r !== 'presentation') return r;
      var t = el.tagName.toLowerCase();
      if (t === 'a' || t === 'area') return el.hasAttribute('href') ? 'link' : 'generic';
      if (t === 'button' || t === 'summary') return 'button';
      if (t === 'select') return el.multiple || el.size > 1 ? 'listbox' : 'combobox';
      if (t === 'textarea') return 'textbox';
      if (/^h[1-6]$/.test(t)) return 'heading';
      if (t === 'iframe') return 'iframe';
      if (t === 'input') {
        return {checkbox: 'checkbox', radio: 'radio', range: 'slider', number: 'spinbutton', search: 'searchbox',
          submit: 'button', button: 'button', reset: 'button', image: 'button', file: 'button',
          color: 'button'}[(el.type || 'text').toLowerCase()] || 'textbox';
      }
      if (el.isContentEditable) return 'textbox';
      return 'generic';
    }
    function name(el) {
      var by = el.getAttribute('aria-labelledby'), t = el.tagName.toLowerCase(), s;
      if (by) {
        s = squash(by.split(/\s+/).map(function (id) {
          var n = document.getElementById(id); return n ? n.innerText || n.textContent : '';
        }).join(' '));
        if (s) return s;
      }
      if ((s = squash(el.getAttribute('aria-label')))) return s;
      if (/^(input|textarea|select)$/.test(t) && el.labels && el.labels.length &&
          (s = squash(Array.prototype.map.call(el.labels, function (l) { return l.innerText; }).join(' ')))) return s;
      if (t === 'input' && /^(submit|button|reset)$/i.test(el.type)) return squash(el.value || el.type);
      if (t === 'input' && /^image$/i.test(el.type)) return squash(el.alt || el.value);
      if (t === 'area') return squash(el.alt);
      if (t === 'iframe') return squash(el.title || el.src);
      if (!/^(input|textarea|select)$/.test(t)) {
        if ((s = squash(el.innerText))) return s;
        var img = el.querySelector('img[alt]');
        if (img && (s = squash(img.alt))) return s;
      }
      return squash(el.getAttribute('placeholder') || el.getAttribute('title'));
    }
    // A password, a card's number or code, a one-time code: by its type,
    // its autocomplete, or what its name and label say it is. Wrong the
    // safe way: a "passport" field is kept back too.
    function secret(el) {
      if (el.tagName !== 'INPUT' && el.tagName !== 'TEXTAREA') return false;
      if (SECRETS.has(el)) return true;
      var ac = (el.getAttribute('autocomplete') || '').toLowerCase();
      var said = [el.name, el.id, el.getAttribute('aria-label'), el.getAttribute('placeholder'),
        el.labels && el.labels.length ? el.labels[0].innerText : ''].join(' ');
      var yes = (el.type || '').toLowerCase() === 'password' ||
        /(^|\s)(cc-|one-time-code|current-password|new-password)/.test(ac) ||
        /pass|pwd|otp|one.?time|2fa|totp|verification.?code|security.?code|cvc|cvv|csc|card.?(number|num|no)|cc.?num|\bpin\b/i.test(said);
      if (yes) SECRETS.add(el);
      return yes;
    }
    function editable(el) {
      if (el.isContentEditable) return true;
      if (el.tagName === 'TEXTAREA') return true;
      return el.tagName === 'INPUT' &&
        !/^(checkbox|radio|submit|button|reset|image|file|range|color|hidden)$/i.test(el.type || 'text');
    }
    function wanted(el) {
      var r = role(el);
      if (ROLES[r]) return r;
      var ti = el.getAttribute('tabindex');
      return ti !== null && +ti >= 0 ? r : null;
    }
    function candidates() {
      // The document's, then each open shadow root's: a closed one is the
      // page's own business.
      var out = [], roots = [document];
      while (roots.length) {
        var root = roots.shift();
        Array.prototype.push.apply(out, root.querySelectorAll(SEL));
        var all = root.querySelectorAll('*');
        for (var i = 0; i < all.length; i++) if (all[i].shadowRoot) roots.push(all[i].shadowRoot);
      }
      return out;
    }
    function described(el) {
      var s = el.tagName.toLowerCase();
      if (el.id) s += '#' + el.id;
      if (typeof el.className === 'string' && el.className.trim()) s += '.' + el.className.trim().split(/\s+/).slice(0, 2).join('.');
      return s;
    }

    """#

    private static let readBody = #"""
    (function (key, snap, most, longest, withText) {
      var found = candidates(), els = [], nodes = [], cut = false, vw = innerWidth, vh = innerHeight;
      for (var i = 0; i < found.length; i++) {
        var el = found[i], r0 = wanted(el);
        if (!r0 || !visible(el)) continue;
        if (nodes.length >= most) { cut = true; break; }
        var r = el.getBoundingClientRect(), n = { e: els.length, role: r0, name: name(el) };
        if (r0 === 'heading') n.level = +(el.getAttribute('aria-level') || el.tagName.slice(1)) || 2;
        if (/^(INPUT|TEXTAREA|SELECT)$/.test(el.tagName) && !/^(submit|button|reset|image|checkbox|radio)$/i.test(el.type || '')) {
          if (secret(el)) { n.redacted = true; n.filled = !!el.value; } else n.value = String(el.value).slice(0, 500);
        } else if (el.isContentEditable) n.value = String(el.innerText).slice(0, 500);
        if (/^(checkbox|radio)$/i.test(el.type || '') && el.tagName === 'INPUT') n.checked = el.checked;
        ['checked', 'expanded', 'selected', 'pressed'].forEach(function (k) {
          var v = el.getAttribute('aria-' + k); if (v === 'true' || v === 'false') n[k] = v === 'true';
        });
        if (el.disabled || el.getAttribute('aria-disabled') === 'true') n.disabled = true;
        if (el.readOnly) n.readonly = true;
        if (el.tagName === 'A' && el.href) n.href = String(el.href).slice(0, 300);
        if (el.getRootNode() !== document) n.shadow = true;
        n.box = [Math.round(r.left), Math.round(r.top), Math.round(r.width), Math.round(r.height)];
        n.inView = r.bottom > 0 && r.right > 0 && r.top < vh && r.left < vw;
        els.push(el); nodes.push(n);
      }
      globalThis[key] = { snap: snap, els: els };
      var out = { url: location.href, title: document.title, nodes: nodes, nodesTruncated: cut,
        viewport: { width: vw, height: vh, scrollY: Math.round(scrollY),
          scrollHeight: document.documentElement ? document.documentElement.scrollHeight : 0 } };
      if (withText) {
        var text = document.body ? document.body.innerText : '';
        out.textTruncated = text.length > longest;
        out.text = text.slice(0, longest);
      }
      return JSON.stringify(out);
    })
    """#

    private static let touchBody = #"""
    (function (key, snap, i, how, text, replace, strict) {
      function no(code, message) { return JSON.stringify({ error: code, message: message }); }
      var kept = globalThis[key];
      if (!kept || kept.snap !== snap) return no('stale_element', 'The page has changed since that read_page');
      var el = kept.els[i];
      if (!el || !el.isConnected) return no('detached', 'That element is no longer in the page');
      // Choosing a file is a person's to do: never from here.
      if (strict && el.tagName === 'INPUT' && /^file$/i.test(el.type || '')) return no('file_input', 'Choosing files is left to you');
      if (how === 'click') {
        if (el.disabled) return no('disabled', 'That element is disabled');
        el.scrollIntoView({ block: 'center', inline: 'center' });
        var r = el.getBoundingClientRect();
        if (!r.width || !r.height || !visible(el)) return no('not_visible', 'That element is hidden');
        var x = r.left + r.width / 2, y = r.top + r.height / 2;
        if (x < 0 || y < 0 || x >= innerWidth || y >= innerHeight) return no('out_of_view', 'That element cannot be scrolled into view');
        var hit = document.elementFromPoint(x, y);
        while (hit && hit.shadowRoot) {
          var deeper = hit.shadowRoot.elementFromPoint(x, y);
          if (!deeper || deeper === hit) break;
          hit = deeper;
        }
        var label = hit && hit.closest ? hit.closest('label') : null;
        if (!hit || !(hit === el || el.contains(hit) || (label && label.control === el)))
          return no('obscured', 'Covered by ' + (hit ? described(hit) : 'nothing at its middle'));
        if (strict && label && label.control && label.control.tagName === 'INPUT' && /^file$/i.test(label.control.type || ''))
          return no('file_input', 'Choosing files is left to you');
        // A selector naming exactly this element, for the bench's real click;
        // none inside a shadow root, which a selector can't reach.
        var q = null;
        if (el.getRootNode() === document) {
          var parts = [];
          for (var n = el; n && n !== document.documentElement; n = n.parentElement) {
            var k = 1;
            for (var p = n.previousElementSibling; p; p = p.previousElementSibling) if (p.tagName === n.tagName) k++;
            parts.unshift(n.tagName.toLowerCase() + ':nth-of-type(' + k + ')');
          }
          parts.unshift('html');
          q = parts.join(' > ');
          if (document.querySelector(q) !== el) q = null;
        }
        return JSON.stringify({ ok: true, selector: q, at: [Math.round(x), Math.round(y)] });
      }
      if (how === 'press') { el.click(); return JSON.stringify({ ok: true }); }
      if (how === 'scroll') {
        el.scrollIntoView({ block: 'center', inline: 'nearest' });
        return JSON.stringify({ ok: true, scrollY: Math.round(scrollY) });
      }
      if (!editable(el)) return no('not_editable', 'That element is not a text field');
      if (el.disabled || el.readOnly) return no('not_editable', 'That field is disabled or read-only');
      var before = el.isContentEditable ? el.textContent : el.value;
      var want = replace ? text : before + text;
      if (how === 'focus') {
        el.scrollIntoView({ block: 'center', inline: 'nearest' });
        el.focus();
        if (replace) {
          if (el.isContentEditable) getSelection().selectAllChildren(el);
          else if (el.select) el.select();
        } else if (!el.isContentEditable && el.setSelectionRange) {
          try { el.setSelectionRange(el.value.length, el.value.length); } catch (e) {}
        }
        // What the field should hold once typed into, kept here when it is
        // secret: what it held before is not for whoever asked.
        if (secret(el)) { kept.want = want; return JSON.stringify({ ok: true, want: null }); }
        return JSON.stringify({ ok: true, want: want });
      }
      if (how === 'set') {
        el.focus();
        // Through the field's own setter, with the events a keystroke fires,
        // as ./bench type does, so frameworks notice.
        if (el.isContentEditable) {
          el.textContent = want;
          el.dispatchEvent(new InputEvent('input', { bubbles: true, data: text, inputType: 'insertText' }));
        } else {
          var proto = el.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
          var setter = Object.getOwnPropertyDescriptor(proto, 'value');
          if (setter && setter.set) setter.set.call(el, want); else el.value = want;
          el.dispatchEvent(new Event('input', { bubbles: true }));
          el.dispatchEvent(new Event('change', { bubbles: true }));
        }
      }
      if (how === 'submit') {
        var form = el.form || el.closest('form');
        if (!form) return no('no_form', 'That field is in no form');
        if (form.requestSubmit) form.requestSubmit(); else form.submit();
        return JSON.stringify({ ok: true });
      }
      var got = el.isContentEditable ? el.textContent : el.value;
      var expected = how === 'verify' ? (text === null ? kept.want : text) : want;
      var out = { ok: true, verified: got === expected };
      if (!out.verified && !secret(el)) out.holds = String(got).slice(0, 500);
      return JSON.stringify(out);
    })
    """#

    private static let checkBody = #"""
    (function (c) {
      var ok = true;
      try {
        if (c.text != null) ok = ok && !!document.body && document.body.innerText.indexOf(c.text) !== -1;
        if (c.url != null) ok = ok && location.href.indexOf(c.url) !== -1;
        if (c.selector != null) { var e = document.querySelector(c.selector); ok = ok && !!e && visible(e); }
        if (c.role != null || c.name != null) {
          var want = c.name == null ? null : String(c.name).toLowerCase();
          ok = ok && candidates().some(function (el) {
            var r = wanted(el);
            return r && (c.role == null || r === c.role) &&
              (want == null || name(el).toLowerCase().indexOf(want) !== -1) && visible(el);
          });
        }
      } catch (e) {
        return JSON.stringify({ error: 'bad_condition', message: String(e && e.message || e) });
      }
      return JSON.stringify({ met: c.gone ? !ok : ok, url: location.href, title: document.title });
    })
    """#

    /// What a picture of the page must not show: every secret field (by
    /// what it says it is, or because Search filled it or saw it as a
    /// password: the shared secret set), and everything whose inside isn't
    /// read here and so can't be vouched for — every frame, whoever's it
    /// is, every embed and object, and an element that draws something but
    /// shows no inside to read, as one with a closed shadow root does. A
    /// custom element that does so is always counted; a standard one that
    /// can carry a shadow root (div, span, section…) only up to a field's or
    /// a widget's size, or every empty background would go too. A closed
    /// root on a standard element larger than that, or one whose host also
    /// has children of its own, is not told apart from an ordinary element.
    private static let maskedHelper = #"""
    function masked() {
      var out = [], roots = [document];
      var hosts = /^(ARTICLE|ASIDE|BLOCKQUOTE|DIV|FOOTER|H[1-6]|HEADER|MAIN|NAV|P|SECTION|SPAN)$/;
      while (roots.length) {
        var root = roots.shift(), all = root.querySelectorAll('*');
        for (var i = 0; i < all.length; i++) {
          var el = all[i], t = el.tagName;
          if (el.shadowRoot) roots.push(el.shadowRoot);
          if (/^(IFRAME|FRAME|EMBED|OBJECT|PORTAL|FENCEDFRAME)$/.test(t)) { out.push(el); continue; }
          if ((t === 'INPUT' || t === 'TEXTAREA') && secret(el)) { out.push(el); continue; }
          if (el.shadowRoot || el.children.length || (el.textContent || '').trim()) continue;
          var r = el.getBoundingClientRect();
          if (!r.width || !r.height) continue;
          if (t.indexOf('-') > 0 || (hosts.test(t) && r.width <= 800 && r.height <= 300)) out.push(el);
        }
      }
      return out;
    }
    function boxes(els) {
      var out = [];
      els.forEach(function (el) {
        var r = el.getBoundingClientRect();
        if (r.width && r.height) out.push([r.left - 2, r.top - 2, r.width + 4, r.height + 4]);
      });
      return out;
    }

    """#

    /// Where a picture must be blacked out, in CSS pixels of the viewport.
    static var secrets: String {
        helpers + maskedHelper
            + "JSON.stringify({ boxes: boxes(masked()), width: innerWidth, height: innerHeight })"
    }

    /// What a picture must not show, made invisible for the time the picture
    /// is taken (opacity, which nothing inside can undo), and where it was.
    /// Kept under `key` for `shown`, which puts each back as it was.
    static func hidden(key: String) -> String {
        call(maskedHelper + #"""
        (function (key) {
          var els = masked(), kept = [];
          els.forEach(function (el) {
            kept.push([el, el.style.getPropertyValue('opacity'), el.style.getPropertyPriority('opacity')]);
            el.style.setProperty('opacity', '0', 'important');
          });
          globalThis[key] = kept;
          return JSON.stringify({ boxes: boxes(els), width: innerWidth, height: innerHeight });
        })
        """#, [key])
    }

    static func shown(key: String) -> String {
        call(#"""
        (function (key) {
          var kept = globalThis[key] || [];
          kept.forEach(function (k) {
            if (k[1]) k[0].style.setProperty('opacity', k[1], k[2]); else k[0].style.removeProperty('opacity');
          });
          globalThis[key] = null;
          return JSON.stringify({ shown: kept.length });
        })
        """#, [key])
    }

    static func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value], options: [.fragmentsAllowed]),
              let text = String(data: data, encoding: .utf8) else { return "null" }
        return String(text.dropFirst().dropLast())
    }

    static func call(_ body: String, _ args: [Any]) -> String {
        helpers + body + "(" + args.map(json).joined(separator: ", ") + ")"
    }

    /// The page's visible controls and headings, with the element list kept
    /// under `key` for touch.
    static func read(key: String, snap: Int, most: Int, longest: Int, text: Bool) -> String {
        call(readBody, [key, snap, most, longest, text])
    }

    /// One element of the last read under `key`: "click", "press", "scroll",
    /// "focus", "set", "submit", "verify" or "check". `strict` refuses file
    /// fields. A nil text for "verify" checks against what "focus" kept.
    static func touch(key: String, snap: Int, index: Int, how: String, text: String?,
                      replace: Bool, strict: Bool = false) -> String {
        call(touchBody, [key, snap, index, how, text ?? NSNull(), replace, strict])
    }

    static func check(_ condition: [String: Any]) -> String {
        call(checkBody, [condition])
    }


    /// The page scrolled by so many CSS pixels, or to its "top" or "bottom".
    static func scroll(dx: Double, dy: Double, to end: String?) -> String {
        call(#"""
        (function (dx, dy, to) {
          if (to === 'top') scrollTo(scrollX, 0);
          else if (to === 'bottom') scrollTo(scrollX, document.documentElement.scrollHeight);
          else scrollBy(dx, dy);
          return JSON.stringify({ scrollX: Math.round(scrollX), scrollY: Math.round(scrollY), height: innerHeight,
            scrollHeight: document.documentElement ? document.documentElement.scrollHeight : 0 });
        })
        """#, [dx, dy, end ?? NSNull()])
    }
}

// MARK: - hands

/// Input handed straight to a page's view, as the hand's would be: never
/// through the app's own event queue, so none of Search's shortcuts or
/// menus hears it, and never moving the pointer.
@MainActor
enum PageHands {
    /// A click at a point in the view's own top-left points. "middle" for
    /// the middle button.
    @discardableResult
    static func click(_ view: WKWebView, at point: [Double], held: NSEvent.ModifierFlags = [], middle: Bool = false) -> Bool {
        guard point.count == 2, let window = view.window else { return false }
        // The page measures in its own CSS pixels; zoomed (View › Zoom In,
        // a site's own zoom, Settings' page zoom) each is that many of the
        // view's points. Taken as points, a click at 125% landed a quarter
        // short, above most links (#1464).
        let zoom = view.pageZoom > 0 ? Double(view.pageZoom) : 1
        let x = point[0] * zoom, y = point[1] * zoom
        let local = NSPoint(x: x, y: view.isFlipped ? y : view.bounds.height - y)
        let spot = view.convert(local, to: nil)
        let types: [NSEvent.EventType] = middle ? [.otherMouseDown, .otherMouseUp] : [.leftMouseDown, .leftMouseUp]
        for type in types {
            guard var event = NSEvent.mouseEvent(
                with: type, location: spot, modifierFlags: held,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: type == types[0] ? 1 : 0
            ) else { continue }
            if middle, let raw = event.cgEvent {
                raw.setIntegerValueField(.mouseEventButtonNumber, value: 2)
                if let again = NSEvent(cgEvent: raw) { event = again }
            }
            switch type {
            case .leftMouseDown: view.mouseDown(with: event)
            case .otherMouseDown: view.otherMouseDown(with: event)
            case .otherMouseUp: view.otherMouseUp(with: event)
            default: view.mouseUp(with: event)
            }
        }
        return true
    }

    /// One key, down and up. Returns the key-down event handed over;
    /// `before` hears it just before the view does.
    @discardableResult
    static func key(_ view: WKWebView, code: UInt16, characters: String, flags: NSEvent.ModifierFlags = [],
                    before: (NSEvent) -> Void = { _ in }) -> NSEvent? {
        var down: NSEvent?
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: view.window?.windowNumber ?? 0, context: nil,
                characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: code
            ) else { continue }
            if type == .keyDown { down = event; before(event); view.keyDown(with: event) } else { view.keyUp(with: event) }
        }
        return down
    }

    /// Text typed a character at a time. Returns the key-down events.
    @discardableResult
    static func type(_ text: String, into view: WKWebView, before: (NSEvent) -> Void = { _ in }) -> [NSEvent] {
        text.compactMap { character in
            key(view, code: Bench.keyCode(for: character), characters: String(character), before: before)
        }
    }

    /// A picture of the page as it is laid out.
    static func snapshot(_ web: WKWebView, width: Double?, _ done: @escaping (Result<NSBitmapImageRep, Error>) -> Void) {
        let shot = WKSnapshotConfiguration()
        shot.afterScreenUpdates = true
        if let width { shot.snapshotWidth = NSNumber(value: width) }
        web.takeSnapshot(with: shot) { image, error in
            MainActor.assumeIsolated {
                guard let image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else {
                    done(.failure(error ?? NSError(domain: "Search", code: 1, userInfo: [NSLocalizedDescriptionKey: "no picture"])))
                    return
                }
                done(.success(rep))
            }
        }
    }
}

// MARK: - a room off every screen

/// A page nobody is looking at has to be somewhere to be laid out at all:
/// WebKit lays out and paints a page only when it has a size and a window.
/// The stage takes it back the moment you pick its tab, and it comes here
/// again when the bench or an agent next needs it.
@MainActor
final class PageRoom {
    static let shared = PageRoom()
    private(set) var window: NSWindow?

    /// The room, made the first time it is needed.
    func made() -> NSWindow {
        if let window { return window }
        // Off every screen, and never key or main: it exists so that a web
        // view has a window, and for nothing else.
        let window = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: 1280, height: 800),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        window.collectionBehavior = [.transient, .ignoresCycle, .stationary]
        window.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
        window.hasShadow = false
        // Clicks reach its pages straight from Search (PageHands.click):
        // the window itself never takes one, even if it is ever seen.
        window.ignoresMouseEvents = true
        window.orderBack(nil)
        self.window = window
        // A screen plugged in or out moves windows that are off every
        // screen, and pulls them onto the one left: the room showed as a
        // grey rectangle on the desktop until Search quit (#1421). Put back
        // far off each time the screens change.
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { PageRoom.shared.putBack() }
            // And once the window server has settled the new layout.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { PageRoom.shared.putBack() }
        }
        return window
    }

    static let far = NSPoint(x: -20000, y: -20000)

    /// The room off every screen again, where it was made.
    func putBack() {
        guard let window, window.frame.origin != Self.far else { return }
        window.setFrameOrigin(Self.far)
    }

    /// Only a script's or an agent's tab, and only while it has no window.
    func house(_ tab: Tab) {
        guard tab.bench, tab.web.window == nil else { return }
        let window = made()
        tab.web.frame = window.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        tab.web.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(tab.web)
    }
}

// MARK: - a switch's mark

/// The mark a switch in Settings leaves, beside the setting itself. The
/// setting lives in the defaults, which any program you run can write; the
/// mark is in the keychain's data protection half, where only apps signed
/// as Search with its profile can read or write, under the app's own access
/// group. A setting found on at launch without its mark is put back to off.
@MainActor
struct SwitchMark {
    let service: String

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecUseDataProtectionKeychain as String: true,
         kSecAttrService as String: service,
         kSecAttrAccount as String: Store.world.map { "consent (\($0))" } ?? "consent"]
    }

    /// The mark is there — or there is nowhere to keep one: a copy built
    /// without Search's provisioning profile has no access group, and
    /// keeps the switch as it always was.
    var given: Bool {
        var asked = query
        asked[kSecReturnAttributes as String] = true
        let status = SecItemCopyMatching(asked as CFDictionary, nil)
        return status == errSecSuccess || status == errSecMissingEntitlement
    }

    func grant() {
        var item = query
        item[kSecValueData as String] = Data("on".utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        if status != errSecSuccess, status != errSecDuplicateItem, status != errSecMissingEntitlement {
            NSLog("%@: the switch left no mark (%d)", service, status)
        }
    }

    func revoke() {
        SecItemDelete(query as CFDictionary)
    }
}
