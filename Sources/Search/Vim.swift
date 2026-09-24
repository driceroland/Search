import SwiftUI
import WebKit

/// Handles Vim commands in an isolated WebKit content world.
@MainActor
final class Vim: NSObject, WKScriptMessageHandlerWithReply {
    static let name = "searchVim"
    static let world: WKContentWorld = {
        if #available(macOS 27.0, *) {
            let configuration = WKContentWorld.Configuration()
            configuration.allowAccessingClosedShadowRoots = true
            return WKContentWorld(configuration: configuration)
        }
        return .world(name: "Search.Vim")
    }()
    private weak var browser: Browser?
    private var revision = 0

    private final class Page {
        weak var web: WKWebView?
        var epoch = 0
        var navigating = false
        var frames: [String: WKFrameInfo] = [:]
        init(_ web: WKWebView) { self.web = web }
    }
    private var pages: [ObjectIdentifier: Page] = [:]

    init(browser: Browser) { self.browser = browser }

    func attach(_ web: WKWebView) {
        pages[ObjectIdentifier(web)] = Page(web)
        let controller = web.configuration.userContentController
        controller.removeScriptMessageHandler(forName: Self.name, contentWorld: Self.world)
        controller.addScriptMessageHandler(self, contentWorld: Self.world, name: Self.name)
    }

    func detach(_ web: WKWebView) {
        pages.removeValue(forKey: ObjectIdentifier(web))
        let controller = web.configuration.userContentController
        if !pages.values.contains(where: { $0.web?.configuration.userContentController === controller }) {
            controller.removeScriptMessageHandler(forName: Self.name, contentWorld: Self.world)
        }
    }

    private func enabled(_ web: WKWebView) -> Bool {
        guard let browser, browser.prefs.vimEnabled, !browser.vimBlocked,
              let tab = browser.active, tab.built === web, !tab.floating, !browser.vimExcluded(tab),
              !["chrome-extension", "webkit-extension"].contains(tab.address?.scheme ?? "")
        else { return false }
        return true
    }

    private func settings(_ page: Page) -> [String: Any] {
        guard let web = page.web else { return ["enabled": false] }
        let inspectClosedRoots: Bool
        if #available(macOS 27.0, *) { inspectClosedRoots = true } else { inspectClosedRoots = false }
        return ["enabled": enabled(web) && !page.navigating,
                "paused": browser?.tab(for: web)?.vimPaused ?? false,
                "inspectClosedRoots": inspectClosedRoots,
                "epoch": page.epoch, "revision": revision]
    }

    func update() {
        revision += 1
        for page in pages.values {
            guard let web = page.web else { continue }
            if browser?.prefs.vimEnabled == false { browser?.tab(for: web)?.vimPaused = false }
            for (document, frame) in page.frames {
                web.callAsyncJavaScript("""
                    if (window.__searchVim?.identity().document !== document) return false;
                    window.__searchVim.configure(settings); return true;
                    """, arguments: ["document": document, "settings": settings(page)],
                    in: frame, in: Self.world) { [weak page] result in
                        if (try? result.get()) as? Bool != true { page?.frames.removeValue(forKey: document) }
                    }
            }
        }
    }

    func invalidate(_ web: WKWebView) {
        guard let page = pages[ObjectIdentifier(web)] else { return }
        page.epoch += 1
        page.navigating = true
        browser?.tab(for: web)?.vimPaused = false
        update()
    }

    func settled(_ web: WKWebView) {
        pages[ObjectIdentifier(web)]?.navigating = false
        web.evaluateJavaScript("window.__searchVim?.ready()", in: nil, in: Self.world) { _ in }
        update()
    }

    func cancelTransient(_ web: WKWebView) {
        guard let page = pages[ObjectIdentifier(web)] else { return }
        for (document, frame) in page.frames {
            web.callAsyncJavaScript("""
                if (window.__searchVim?.identity().document === document) window.__searchVim.cancel();
                """, arguments: ["document": document], in: frame, in: Self.world) { _ in }
        }
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard let web = message.webView, let page = pages[ObjectIdentifier(web)],
              let body = message.body as? [String: Any],
              let kind = body["kind"] as? String,
              let document = body["document"] as? String, document.count <= 100
        else { replyHandler(["accepted": false], nil); return }
        let epoch = page.epoch
        if kind != "ready" {
            guard body["epoch"] as? Int == epoch, page.frames[document] != nil,
                  !page.navigating, enabled(web)
            else { replyHandler(["accepted": false], nil); return }
        }
        // WKFrameInfo can outlive its document. Verify the token in the frame
        // itself, including for ready, before letting it acquire a fresh epoch.
        web.callAsyncJavaScript("""
            return window.__searchVim?.identity().document === document && (ready || window.document.hasFocus());
            """, arguments: ["document": document, "ready": kind == "ready"],
            in: message.frameInfo, in: Self.world) { [weak self, weak web] result in
                guard let self, let web, self.pages[ObjectIdentifier(web)] === page,
                      page.epoch == epoch, (try? result.get()) as? Bool == true,
                      let browser = self.browser
                else { replyHandler(["accepted": false], nil); return }
                if kind == "ready" {
                    page.frames[document] = message.frameInfo
                    replyHandler(self.settings(page), nil)
                    return
                }
                guard self.enabled(web), !page.navigating, let tab = browser.tab(for: web)
                else { replyHandler(["accepted": false], nil); return }
                switch kind {
                case "paused":
                    guard let paused = body["paused"] as? Bool else {
                        replyHandler(["accepted": false], nil); return
                    }
                    tab.vimPaused = paused
                    self.update()
                case "action":
                    switch body["action"] as? String {
                    case "back": browser.back()
                    case "forward": browser.forward()
                    case "reload": browser.reload()
                    case "previousTab": browser.step(-1)
                    case "nextTab": browser.step(1)
                    case "closeTab": browser.close(tab)
                    case "newTab": browser.newTab()
                    default: replyHandler(["accepted": false], nil); return
                    }
                case "openLink":
                    guard let raw = body["url"] as? String, let url = URL(string: raw),
                          ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                          let host = url.host, !host.isEmpty else {
                        replyHandler(["accepted": false], nil); return
                    }
                    browser.openVimLink(url, from: tab)
                case "emptyHints": browser.announce("No links here")
                default: replyHandler(["accepted": false], nil); return
                }
                replyHandler(["accepted": true], nil)
            }
    }

    // onclick properties belong to the page's JS world. This helper only marks
    // DOM candidates on request; the page never receives a native command bridge.
    static let clickTargetsScript = #"""
    (() => {
      if (window.__searchVimClicks) return;
      window.__searchVimClicks = true;
      document.addEventListener('__searchVimDiscoverClicks', () => {
        function scan(root) {
          for (const el of root.querySelectorAll('*')) {
            el.toggleAttribute('data-search-vim-click', typeof el.onclick === 'function');
            if (el.shadowRoot) scan(el.shadowRoot);
          }
        }
        scan(document);
      }, true);
    })();
    """#

    static let script = #"""
    (() => {
      if (window.__searchVim) return;
      const token = Array.from(crypto.getRandomValues(new Uint32Array(4)), n => n.toString(16)).join('-');
      const stepPixels = 60;
      const sequenceMilliseconds = 1000;
      const browserKeys = {H:'back', L:'forward', r:'reload', q:'previousTab', w:'nextTab', x:'closeTab', t:'newTab'};
      let enabled = false, paused = false, composing = false, inspectClosedRoots = false, epoch = -1, revision = -1, prefixAt = 0;
      let hintsID = '__searchVimHints';
      let hints = null;
      function cancel() {
        prefixAt = 0;
        if (!hints) return;
        hints.mutations.disconnect();
        cancelAnimationFrame(hints.frame);
        hints.host.remove();
        hints = null;
      }
      function configure(settings) {
        if (!settings || typeof settings.revision !== 'number' || settings.revision < revision) return;
        if (!settings.enabled || settings.epoch !== epoch) cancel();
        revision = settings.revision;
        epoch = settings.epoch;
        enabled = settings.enabled && ['text/html', 'application/xhtml+xml'].includes(document.contentType);
        paused = settings.paused;
        inspectClosedRoots = settings.inspectClosedRoots;
      }
      function send(kind, extra = {}) {
        return window.webkit.messageHandlers.searchVim.postMessage({kind, document: token, epoch, ...extra})
          .catch(() => { enabled = false; cancel(); return {accepted: false}; });
      }
      function ready() { return send('ready').then(configure); }
      window.__searchVim = {identity: () => ({document: token, epoch, enabled}), configure, cancel, ready};
      function active() {
        let el = document.activeElement;
        while (el?.shadowRoot?.activeElement) el = el.shadowRoot.activeElement;
        return el;
      }
      function parent(el) { return el.parentElement || el.getRootNode()?.host; }
      function editable(el) {
        return el instanceof Element && (el.matches('input, textarea, select, [role="textbox"], [role="searchbox"], [role="combobox"], [role="spinbutton"]') ||
          el.isContentEditable || (el.localName.includes('-') && el.shadowRoot?.mode !== 'open'));
      }
      function editing(event) {
        const el = active();
        // On macOS 14, a focused generic host may contain an editor in a closed
        // shadow root, so let its keystrokes pass through.
        const opaque = !inspectClosedRoots && el instanceof Element && !el.shadowRoot && el.matches(':focus-within') &&
          el.matches('article, aside, blockquote, body, div, footer, h1, h2, h3, h4, h5, h6, header, main, nav, p, section, span');
        return opaque || event.composedPath().some(editable) || editable(el);
      }
      const controls = 'a[href], button, input, textarea, select, summary, [role="button"], [role="link"], [role="checkbox"], [role="radio"], [role="switch"], [role="textbox"], [role="searchbox"], [role="combobox"], [contenteditable=""], [contenteditable="true"], [onclick], [data-search-vim-click]';
      function control(el) { return el.matches(controls); }
      function writable(el) {
        return !el.readOnly && (el.isContentEditable || el.matches('textarea, [role="textbox"], [role="searchbox"], input:not([type="button"]):not([type="submit"]):not([type="reset"]):not([type="checkbox"]):not([type="radio"]):not([type="range"]):not([type="file"]):not([type="color"]):not([type="image"]):not([type="hidden"])'));
      }
      function webLink(el) {
        return el.matches('a[href]:not([download])') && /^https?:$/.test(el.protocol);
      }
      function elements(root = document) {
        const result = [];
        for (const el of root.querySelectorAll('*')) {
          if (control(el)) result.push(el);
          if (el.shadowRoot?.mode === 'open') result.push(...elements(el.shadowRoot));
        }
        return result;
      }
      function visibleRect(el) {
        if (!el.isConnected || el.matches(':disabled, [aria-disabled="true"], input[type="hidden"]')) return null;
        const ancestors = [];
        for (let p = el; p; p = parent(p)) {
          const style = getComputedStyle(p);
          if (p.inert || p.getAttribute('aria-disabled') === 'true' || style.visibility !== 'visible' ||
              style.display === 'none' || Number(style.opacity) === 0) return null;
          if (p !== el) ancestors.push([p, style]);
        }
        for (const rect of el.getClientRects()) {
          let left = Math.max(0, rect.left), top = Math.max(0, rect.top);
          let right = Math.min(innerWidth, rect.right), bottom = Math.min(innerHeight, rect.bottom);
          for (const [p, style] of ancestors) {
            const box = p.getBoundingClientRect();
            if (/(auto|scroll|hidden|clip|overlay)/.test(style.overflowX)) {
              left = Math.max(left, box.left); right = Math.min(right, box.right);
            }
            if (/(auto|scroll|hidden|clip|overlay)/.test(style.overflowY)) {
              top = Math.max(top, box.top); bottom = Math.min(bottom, box.bottom);
            }
          }
          if (right - left < 2 || bottom - top < 2) continue;
          for (const [x, y] of [[(left+right)/2, (top+bottom)/2], [left+1, top+1], [right-1, bottom-1]]) {
            let hit = document.elementFromPoint(x, y);
            while (hit?.shadowRoot) {
              const inner = hit.shadowRoot.elementFromPoint(x, y);
              if (!inner || inner === hit) break;
              hit = inner;
            }
            for (; hit; hit = parent(hit)) {
              if (hit === el) return {left, top, right, bottom};
              if (control(hit)) break;
            }
          }
        }
        return null;
      }
      function showHints(background) {
        cancel();
        if (!background) document.dispatchEvent(new Event('__searchVimDiscoverClicks'));
        const targets = elements().filter(el => !background || webLink(el))
          .map(el => ({el, rect: visibleRect(el), bounds: el.getBoundingClientRect(), href: el.getAttribute('href')})).filter(t => t.rect);
        if (!targets.length) { send('emptyHints'); return; }
        const alphabet = 'asdfghjkl';
        let width = 1;
        while (alphabet.length ** width < targets.length) width++;
        const host = document.createElement('div');
        host.id = hintsID;
        host.style.cssText = 'all:initial!important;position:fixed!important;inset:0!important;z-index:2147483647!important;pointer-events:none!important';
        host.setAttribute('aria-hidden', 'true');
        const root = host.attachShadow({mode:'open'});
        const style = document.createElement('style');
        style.textContent = ':host{pointer-events:none}span{position:absolute;box-sizing:border-box;background:#ffe58a;color:#171717;border:1px solid #40371d;border-radius:3px;padding:1px 4px;font:bold 12px/16px ui-monospace,monospace;box-shadow:0 1px 3px #0006;pointer-events:none}';
        root.append(style);
        targets.forEach((target, index) => {
          let value = index, label = '';
          for (let n = 0; n < width; n++) { label = alphabet[value % alphabet.length] + label; value = Math.floor(value / alphabet.length); }
          const badge = document.createElement('span');
          badge.dataset.hint = label; badge.textContent = label;
          badge.style.left = Math.max(0, Math.min(target.rect.left, innerWidth - 8 - width * 9)) + 'px';
          badge.style.top = Math.max(0, Math.min(target.rect.top, innerHeight - 20)) + 'px';
          root.append(badge);
          Object.assign(target, {label, badge});
        });
        function changed() {
          if (targets.some(t => {
            const rect = visibleRect(t.el);
            return !rect || t.el.getAttribute('href') !== t.href ||
              Object.keys(rect).some(k => Math.abs(rect[k] - t.rect[k]) > 1);
          })) cancel();
        }
        const mutations = new MutationObserver(changed);
        document.documentElement.append(host);
        hints = {host, targets, prefix:'', background, mutations, frame:0};
        mutations.observe(document.documentElement, {subtree:true, childList:true, attributes:true});
        for (const t of targets) {
          const root = t.el.getRootNode();
          if (root instanceof ShadowRoot) mutations.observe(root, {subtree:true, childList:true, attributes:true});
        }
        // Position-only animation does not fire a resize or DOM mutation.
        // Watch bounds only while hints are visible; hit-test on mutations/selection.
        function track() {
          if (hints?.host !== host) return;
          if (targets.some(t => moved(t.bounds, t.el.getBoundingClientRect()))) cancel();
          else hints.frame = requestAnimationFrame(track);
        }
        hints.frame = requestAnimationFrame(track);
      }
      function moved(before, after) {
        return ['left','top','right','bottom'].some(k => Math.abs(before[k] - after[k]) > 1);
      }
      function hintKey(key, repeat) {
        if (repeat) return;
        if (key === 'Backspace') hints.prefix = hints.prefix.slice(0, -1);
        else if (hints.targets.some(t => t.label.startsWith(hints.prefix + key))) hints.prefix += key;
        else return;
        const chosen = hints.targets.find(t => t.label === hints.prefix);
        if (chosen) {
          const background = hints.background;
          const rect = visibleRect(chosen.el);
          const valid = rect && !moved(chosen.rect, rect) && chosen.el.getAttribute('href') === chosen.href;
          cancel();
          if (!valid) return;
          if (background) { if (webLink(chosen.el)) send('openLink', {url:chosen.el.href}); }
          else if (writable(chosen.el) || chosen.el.matches('select')) chosen.el.focus();
          else chosen.el.click();
        } else {
          for (const t of hints.targets) t.badge.hidden = !t.label.startsWith(hints.prefix);
        }
      }
      function scroll(key) {
        const horizontal = key === 'h' || key === 'l';
        let el = active();
        while (el && el !== document.body && el !== document.documentElement) {
          const style = getComputedStyle(el);
          if (/(auto|scroll|overlay)/.test(horizontal ? style.overflowX : style.overflowY) &&
              (horizontal ? el.scrollWidth > el.clientWidth : el.scrollHeight > el.clientHeight)) break;
          el = parent(el);
        }
        if (!el || el === document.body || el === document.documentElement) el = document.scrollingElement;
        if (!el) return;
        if (key === 'gg' || key === 'G') {
          el.scrollTo({top: key === 'gg' ? 0 : el.scrollHeight, behavior: 'instant'});
        } else {
          const distance = (key === 'u' || key === 'd') ? el.clientHeight / 2 : stepPixels;
          const sign = ['h', 'k', 'u'].includes(key) ? -1 : 1;
          el.scrollBy({left: horizontal ? distance * sign : 0,
                       top: horizontal ? 0 : distance * sign, behavior: 'instant'});
        }
      }
      window.addEventListener('keydown', event => {
        if (!event.isTrusted || !enabled || !document.hasFocus()) return;
        if (event.isComposing || composing || event.keyCode === 229) return;
        if (event.metaKey || event.altKey || (event.ctrlKey && event.key !== '[')) { cancel(); return; }
        const key = event.key;
        const escape = key === 'Escape' || (event.ctrlKey && key === '[');
        const typing = editing(event);
        if (escape) {
          if (!hints && !prefixAt && !paused && !typing) return;
          if (hints || prefixAt) cancel();
          else {
            paused = false;
            if (typing) active()?.blur();
            send('paused', {paused: false});
          }
        } else if (hints) {
          hintKey(key, event.repeat);
        } else {
          if (paused || typing) { cancel(); return; }
          const prefix = prefixAt && performance.now() - prefixAt <= sequenceMilliseconds;
          prefixAt = 0;
          if (key === 'g') {
            if (!event.repeat) {
              if (prefix) scroll('gg'); else prefixAt = performance.now();
            }
          } else if (['h','j','k','l','u','d','G'].includes(key)) {
            scroll(key);
          } else if (key === 'i') {
            if (!event.repeat) {
              if (prefix) elements().find(el => writable(el) && visibleRect(el))?.focus();
              else { paused = true; send('paused', {paused: true}); }
            }
          } else if (key === 'f' || key === 'F') {
            if (!event.repeat) showHints(key === 'F');
          } else if (browserKeys[key]) {
            if (!event.repeat) send('action', {action: browserKeys[key]});
          } else return;
        }
        event.preventDefault();
        event.stopImmediatePropagation();
      }, true);
      window.addEventListener('compositionstart', () => { composing = true; cancel(); }, true);
      window.addEventListener('compositionend', () => { composing = false; }, true);
      window.addEventListener('focusin', cancel, true);
      window.addEventListener('blur', cancel);
      window.addEventListener('scroll', cancel, true);
      window.addEventListener('resize', cancel);
      window.addEventListener('pagehide', () => { enabled = false; cancel(); });
      window.addEventListener('pageshow', () => { cancel(); ready(); });
      ready();
    })();
    """#
}

struct VimStatus: View {
    @ObservedObject var tab: Tab
    var body: some View {
        if tab.vimPaused {
            Text("Vim paused · Esc to resume")
                .font(.system(size: 12))
                .foregroundStyle(Palette.ink)
                .padding(.horizontal, 16).padding(.vertical, 9)
                .background(Palette.ground, in: Capsule())
                .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
                .allowsHitTesting(false)
        }
    }
}
