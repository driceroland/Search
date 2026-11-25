import AppKit
import WebKit

// An extension's popup, in a popover of the browser's own.
//
// WebKit offers a popover of its own for this, and it works for most
// extensions — but not all: for some, messages from WebKit's popup never
// reach the extension's worker, and the popup waits on a spinner for ever,
// while the very same page loaded in a view built from the extension's
// configuration talks to its worker perfectly well. So the popup page is
// loaded here, in such a view, in a popover that hangs from the button.
//
// Chrome sizes a popup to its content, between 25 and 800 points wide and
// up to 600 tall; the page is measured once its document is built and again
// whenever it changes, and the popover follows, both ways. window.close()
// closes it.

@available(macOS 15.4, *)
@MainActor
final class ExtensionPopup: NSObject, WKUIDelegate, WKNavigationDelegate, NSPopoverDelegate {
    static let shared = ExtensionPopup()

    private var popover: NSPopover?
    private var web: WKWebView?
    /// The popup as WebKit is told about it: a page it can find, belonging
    /// to the browser's window — Chrome gives a popup no window of its own,
    /// so "the current window" from a popup is the browser's, and so is the
    /// last focused one.
    private var page: PopupPage?
    private var measuring: Timer?
    private(set) var extensionID: String?
    /// The extension's own button, when the popup hangs from it.
    private weak var button: NSView?
    /// The popup a click on its own button just closed: the popover can go
    /// on mouse-down or mouse-up, before the button's press arrives — which
    /// would open it again.
    private var closedByButton: (id: String, at: Date)?

    /// The popup's web view, while one is up — for the bench.
    var view: WKWebView? { web }

    /// The window this extension's popup was opened from, while it is open.
    func browser(for id: String) -> Browser? { extensionID == id ? page?.browser : nil }

    /// The popup asking for the camera or microphone: asked on the card of
    /// the window in front, named as the extension and remembered for it,
    /// as for any of its pages (see Browser.askedForCapture) — never
    /// WebKit's own dialog, and never without asking.
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        guard let browser = Browsers.front else { return decisionHandler(.deny) }
        browser.askedForCapture(webView, origin: origin, frame: frame, type: type, decisionHandler: decisionHandler)
    }

    /// Recording the screen from the popup: only Search's own call
    /// (ExtensionCapture), never the extension's on its own.
    @objc(_webView:requestDisplayCapturePermissionForOrigin:initiatedByFrame:withSystemAudio:decisionHandler:)
    func displayCapture(_ web: WKWebView, origin: WKSecurityOrigin, frame: WKFrameInfo, systemAudio: Bool,
                        decisionHandler: @escaping (Int) -> Void) {
        decisionHandler(ExtensionCapture.shared.displayDecision(for: web))
    }

    /// On screen now.
    var isUp: Bool { popover?.isShown == true }

    /// The popup as its extension's worker finds it in clients.matchAll().
    func client(of id: String) -> [String: Any]? {
        guard extensionID == id, let url = web?.url else { return nil }
        return ["id": "popup", "url": url.absoluteString, "visible": isUp, "focused": isUp && web?.window?.isKeyWindow == true]
    }

    func show(_ url: URL, for context: WKWebExtensionContext, from anchor: NSView?, in browser: Browser? = nil) {
        close()
        guard let configuration = context.webViewConfiguration else { return }
        ExtensionSandbox.attach(configuration, for: context)
        // Sized the way Chrome sizes a popup (see preferred), unseen, while
        // the popover already stands at the size this popup had last time;
        // then shown. It has to be in the window meanwhile: WebKit suspends
        // a page that is in none.
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 25, height: 25), configuration: configuration)
        web.uiDelegate = self
        web.navigationDelegate = self
        // White behind the page, as Chrome paints a popup: many leave their
        // background unset, and their dark text over the popover's dark
        // material would vanish.
        web.alphaValue = 0
        web.load(URLRequest(url: url))

        let stage = NSView(frame: NSRect(origin: .zero, size: ExtensionPopup.lastSize[context.uniqueIdentifier] ?? NSSize(width: 360, height: 240)))
        stage.addSubview(web)
        let host = NSViewController()
        host.view = stage
        // The popover takes its size from its view controller: left at zero,
        // it comes in as a sliver and grows to the size it was given,
        // instead of standing at that size from the start.
        host.preferredContentSize = stage.frame.size
        let popover = NSPopover()
        popover.contentViewController = host
        popover.contentSize = stage.frame.size
        popover.behavior = .transient
        popover.animates = !Motion.instant
        popover.delegate = self

        self.web = web
        self.popover = popover
        extensionID = context.uniqueIdentifier
        button = anchor != nil && Extensions.shared.isOwnButton(anchor, for: context.uniqueIdentifier) ? anchor : nil
        let targetBrowser = browser ?? anchor?.window.flatMap(Browsers.browser(for:))
        let page = PopupPage(web: web, browser: targetBrowser)
        self.page = page
        Extensions.shared.controller.didOpenTab(page)

        shown = false
        placement = anchor.map(ExtensionPopup.describe) ?? ["from": "window"]
        if let anchor, anchor.window != nil {
            // Above or under the button, its arrow kept clear of the
            // popover's corners near the screen's sides, and left out when
            // that would take it off the button (PopoverSide).
            PopoverSide.show(popover, relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY, pointed: true)
        } else if let content = (targetBrowser?.window ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain && $0.frame.minX > -10_000 }))?.contentView {
            // No button to hang from — the column or the strip folded away:
            // where the buttons would be, the column's foot or the strip's
            // far end. The window's content is SwiftUI's, a flipped view,
            // whose top is at minY: measured from maxY, "the top right" was
            // the bottom right, across the window from the column's buttons.
            // The column's foot is on the side the column is on, and the
            // popup hangs inward from it.
            let bounds = content.bounds, flipped = content.isFlipped
            let prefs = (targetBrowser ?? Extensions.shared.browser)?.prefs
            let column = prefs?.sidebar == true, right = prefs?.sidePosition == .right
            let spot = column
                ? NSRect(x: right ? bounds.maxX - 24 : bounds.minX + 24, y: flipped ? bounds.maxY - 24 : bounds.minY + 24, width: 1, height: 1)
                : NSRect(x: bounds.maxX - 60, y: flipped ? bounds.minY + 40 : bounds.maxY - 40, width: 1, height: 1)
            let edge: NSRectEdge = column ? (right ? .minX : .maxX) : (flipped ? .maxY : .minY)
            PopoverSide.show(popover, relativeTo: spot, of: content, preferredEdge: edge)
        }
        // Sized once loaded — or after a moment regardless, for a page that
        // never finishes loading.
        // Measured when the document is built (see below) or has loaded;
        // a page slow to do either is measured anyway after a moment, and
        // shown regardless a little later.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self, weak popover] in
            guard let self, let popover, popover === self.popover else { return }
            self.follow()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self, weak popover] in
            guard let self, let popover, popover === self.popover else { return }
            self.measure(force: true)
            self.reveal()
        }
    }

    /// Where the last popup was hung from, for the bench.
    private(set) var placement: [String: Any] = [:]

    static func describe(_ view: NSView) -> [String: Any] {
        guard let window = view.window, let content = window.contentView else { return ["from": "view", "inWindow": false] }
        let r = view.convert(view.bounds, to: nil)
        var alpha = view.alphaValue
        var up = view.superview
        while let v = up { alpha *= v.alphaValue; up = v.superview }
        return ["from": "view", "inWindow": true, "hidden": view.isHiddenOrHasHiddenAncestor, "alpha": Double(alpha),
                "rect": [Int(r.minX), Int(r.minY), Int(r.width), Int(r.height)],
                "content": [Int(content.bounds.width), Int(content.bounds.height)],
                "onWindow": content.convert(content.bounds, to: nil).intersects(r)]
    }

    /// Each extension's popup size, so the next opening starts there, after
    /// a relaunch too.
    static var lastSize: [String: NSSize] {
        get {
            let kept = Store.settings.dictionary(forKey: "extensionPopupSizes") as? [String: [Double]] ?? [:]
            return kept.compactMapValues { $0.count == 2 ? bounded(NSSize(width: $0[0], height: $0[1])) : nil }
        }
        set {
            Store.settings.set(newValue.mapValues { [Double($0.width), Double($0.height)] }, forKey: "extensionPopupSizes")
        }
    }
    private var shown = false

    /// A size within a popup's limits (25 × 25 to 800 × 600), or nil for
    /// one that isn't a number: what is kept, or measured, is never trusted
    /// to be one the popover may take.
    static func bounded(_ size: NSSize) -> NSSize? {
        guard size.width.isFinite, size.height.isFinite else { return nil }
        return NSSize(width: min(800, max(25, size.width.rounded(.up))), height: min(600, max(25, size.height.rounded(.up))))
    }

    /// Forgotten with its extension.
    static func forget(_ id: String) { lastSize[id] = nil }

    /// The popover's size and whether the page is in view, for the bench.
    var drawn: [String: Any] {
        guard let popover else { return [:] }
        return ["size": [Double(popover.contentSize.width), Double(popover.contentSize.height)], "shown": shown]
    }

    /// The page, at the popover's size, in view.
    private func reveal() {
        guard !shown, let web, let stage = popover?.contentViewController?.view else { return }
        shown = true
        web.frame = NSRect(origin: .zero, size: popover?.contentSize ?? stage.bounds.size)
        web.autoresizingMask = [.width, .height]
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.seconds(0.12)
            web.animator().alphaValue = 1
        }
    }

    /// From the document being built: sized, then followed as it changes —
    /// a width set by its script, a list filled in by a reply from the
    /// worker, then cut short — for as long as it's open. Measured only
    /// when something changed (see watch), so a page that settles is left
    /// alone.
    private func follow() {
        measure()
        guard measuring == nil else { return }
        measuring = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.measure() }
        }
    }

    func close() {
        measuring?.invalidate()
        measuring = nil
        let closing = popover
        forget()
        closing?.performClose(nil)
    }

    /// Tells WebKit the popup's window and tab are gone.
    private func forget() {
        if let page { Extensions.shared.controller.didCloseTab(page, windowIsClosing: false) }
        page = nil
        popover = nil
        web = nil
        extensionID = nil
        button = nil
    }

    /// A press on the button of an extension whose popup is up closes it,
    /// as in Chrome — whether the popover is still there (a click on the
    /// view it hangs from doesn't close it) or went on this click's
    /// mouse-down or mouse-up. Closed, it is not opened again.
    func closes(_ id: String) -> Bool {
        defer { closedByButton = nil }
        if popover != nil, extensionID == id {
            close()
            return true
        }
        guard let closed = closedByButton, closed.id == id else { return false }
        return Date().timeIntervalSince(closed.at) < 1.5
    }


    /// The size Chrome would give the popup (Blink's auto-size, between
    /// 25 × 25 and 800 × 600), worked out in the page while its view is
    /// still the 25-point square: the width the page names for itself if it
    /// names one, else its narrowest (min-content — what is positioned off
    /// to the side doesn't count), else, for a page with next to no width
    /// of its own, what its content spans; then, laid out at that width,
    /// the height it names or spans. Nothing of it is left on the page.
    ///
    /// A scroll bar counts only when the page asks for one (overflow:
    /// scroll), or when it is taller than the popup can be and will scroll.
    /// With System Settings › Appearance › Show scroll bars set to Always,
    /// the content overflowing the little square (or the popup's size before
    /// it grew) put classic scroll bars up while it was measured, and their
    /// room was added each way: popups came out 17 points too large (#1311).
    static let preferred = """
    () => {
      const d = document.documentElement, v = document.compatMode === "BackCompat" ? document.body : d;
      if (!v) return null;
      const m = window.__searchSizing || (window.__searchSizing = {});
      const saved = d.getAttribute("style");
      const back = () => saved === null ? d.removeAttribute("style") : d.setAttribute("style", saved);
      // The overflow the view takes: the root's, or the body's handed up.
      const root = getComputedStyle(d), body = document.body && getComputedStyle(document.body);
      const view = root.overflowX === "visible" && root.overflowY === "visible" && body ? body : root;
      const bar = innerWidth - v.clientWidth, barAcross = innerHeight - v.clientHeight;
      const across = view.overflowX === "scroll" ? barAcross : 0;
      let gutter = view.overflowY === "scroll" ? bar : 0;
      const box = d.getBoundingClientRect();
      // A width the page sets for itself shows as one the view doesn't
      // have, excluding its scrollbar; one equal to the view is either
      // filling it or the width it was given last time, remembered.
      let w;
      if (Math.abs(box.width - v.clientWidth) > 1) w = m.w = box.width;
      else if (m.w && Math.abs(m.w - v.clientWidth) <= 1) w = m.w;
      else {
        d.style.setProperty("width", "min-content", "important");
        const narrowest = d.getBoundingClientRect().width;
        back();
        w = narrowest >= 100 ? narrowest : Math.max(narrowest, d.scrollWidth);
      }
      const below = (root) => {
        let bottom = 0, n = 0;
        const walk = (el) => {
          for (const c of el.children) {
            if (++n > 3000) return;
            const s = getComputedStyle(c);
            if (s.display === "none") continue;
            const r = c.getBoundingClientRect();
            if (r.width > 0 && r.height > 0) bottom = Math.max(bottom, r.bottom);
            if (s.overflowY === "visible" && s.overflowX === "visible") walk(c);
          }
        };
        walk(root);
        return bottom + scrollY;
      };
      let width;
      const lay = () => {
        back();
        width = Math.min(800, Math.max(25, Math.ceil(w + gutter)));
        d.style.setProperty("width", (width - gutter) + "px", "important");
        // The height it names for itself, if it names one: one that is
        // not what its content spans. Equal to the view, it either fills
        // the view (100%; WebKit fills an extension page's view anyway) or
        // is the height it named last time, remembered. Its content's
        // height alone is never remembered: the popup, grown to it, kept
        // it when the content got shorter.
        let h = d.getBoundingClientRect().height;
        d.style.setProperty("height", "auto", "important");
        d.style.setProperty("min-height", "0", "important");
        const content = d.getBoundingClientRect().height;
        if (Math.abs(h - content) <= 1) { m.h = 0; h = content; }
        else if (Math.abs(h - innerHeight) > 1) m.h = h;
        else h = m.h && Math.abs(m.h - innerHeight) <= 1 ? m.h : content;
        // What hangs out of the body below it (a list positioned under a
        // body of fixed height) counts too, as in Chrome's measure; not
        // what a box that scrolls or clips keeps inside it.
        if (document.body && v === d) h = Math.max(h, below(document.body));
        return h;
      };
      let h = lay();
      // Taller than the popup: it scrolls, and a scroll bar shown always
      // takes its room across.
      if (gutter !== bar && h + across > 600) { gutter = bar; h = lay(); }
      back();
      return [width, Math.min(600, Math.max(25, Math.ceil(h + across)))];
    }
    """

    /// The document is built — DOMContentLoaded, the moment Chrome sizes a
    /// popup, before the page's scripts look at the room they have (Proton
    /// Pass takes whatever size it finds then for good). WebKit tells a
    /// navigation delegate that has this method; the configuration
    /// extension pages share can't be given a script of our own.
    @objc(_webView:navigationDidFinishDocumentLoad:)
    func webView(_ webView: WKWebView, navigationDidFinishDocumentLoad navigation: WKNavigation?) {
        guard webView === web else { return }
        follow()
    }

    /// Where the popup is watched and measured: a world of Search's own,
    /// so nothing of it is the page's to see or to touch.
    static let world = WKContentWorld.world(name: "search-popup-size")

    /// Counts the page's changes, from the first call: its boxes' sizes
    /// (ResizeObserver on the root and the body), its nodes and attributes,
    /// and an image or a font loading. Then, if it changed since the last
    /// measure (or `force`), measures it (preferred) and gives up the
    /// records its own measuring left, so measuring isn't a change.
    static func watch(force: Bool) -> String {
        """
        (() => {
          const w = window.__searchWatch || (window.__searchWatch = { n: 1, seen: 0 });
          if (!w.mo) {
            const bump = () => { w.n++; };
            w.mo = new MutationObserver(bump);
            w.mo.observe(document, { subtree: true, childList: true, attributes: true, characterData: true });
            try {
              w.ro = new ResizeObserver(bump);
              w.ro.observe(document.documentElement);
              if (document.body) w.ro.observe(document.body);
            } catch (e) {}
            addEventListener("load", bump, true);
            try { document.fonts.addEventListener("loadingdone", bump); } catch (e) {}
          }
          if (w.ro && document.body && w.body !== document.body) { w.body = document.body; w.ro.observe(document.body); }
          if (!\(force) && w.seen === w.n) return null;
          w.seen = w.n;
          const size = (\(preferred))();
          w.mo.takeRecords();
          return size;
        })()
        """
    }

    /// Measured, while unseen as the 25-point square and then as it is
    /// shown; the popover takes the size found. Unseen, a page with
    /// nothing in it yet (both ways the least a popup can be: its script
    /// hasn't built it) is left unseen, the popover standing at its last
    /// size, rather than shown as a strip that then widens.
    private func measure(force: Bool = false) {
        guard let web else { return }
        web.evaluateJavaScript(Self.watch(force: force), in: nil, in: Self.world) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self, web === self.web, let popover = self.popover,
                      case .success(let value) = result, let pair = value as? [Double], pair.count == 2 else { return }
                let wanted = NSSize(width: pair[0], height: pair[1])
                if !self.shown, !force, max(wanted.width, wanted.height) <= 25 { return }
                let now = popover.contentSize
                if !self.shown || abs(wanted.width - now.width) > 1 || abs(wanted.height - now.height) > 1 { self.apply(wanted) }
            }
        }
    }

    private func apply(_ measured: NSSize) {
        guard let popover, let size = ExtensionPopup.bounded(measured) else { return }
        if abs(size.width - popover.contentSize.width) > 1 || abs(size.height - popover.contentSize.height) > 1 {
            // The popover takes its size from its view controller, and goes
            // back to it: both are told.
            popover.contentViewController?.preferredContentSize = size
            popover.contentSize = size
            popover.contentViewController?.view.setFrameSize(size)
            if shown { web?.frame = NSRect(origin: .zero, size: size) }
        }
        if let id = extensionID, ExtensionPopup.lastSize[id] != size { ExtensionPopup.lastSize[id] = size }
        reveal()
    }

    /// How far the page reaches, as a function of "width" or "height":
    /// its own width if it names one wider than the view, else its
    /// narrowest (min-content — what is positioned off to the side doesn't
    /// count, as in Chrome's measure), else, for a page that only fills the
    /// view and has next to no width of its own, what its content spans.
    /// Height: all it spans.
    static let reach = """
    ((key) => {
      const d = document.documentElement, v = document.compatMode === "BackCompat" ? document.body : d;
      if (!v) return null;
      if (key === "height") return d.scrollHeight;
      const own = d.getBoundingClientRect().width, gutter = innerWidth - v.clientWidth;
      if (own > v.clientWidth + 1) return own + gutter;
      const saved = d.getAttribute("style");
      d.style.setProperty("width", "min-content", "important");
      const narrowest = d.getBoundingClientRect().width;
      saved === null ? d.removeAttribute("style") : d.setAttribute("style", saved);
      return (narrowest >= 100 ? narrowest : Math.max(narrowest, d.scrollWidth)) + gutter;
    })
    """

    // MARK: - the page asking

    func webViewDidClose(_ webView: WKWebView) { close() }

    /// Loaded: followed, and shown a moment later whatever it has, for a
    /// popup that really is next to nothing.
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === web else { return }
        follow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self, weak webView] in
            guard let self, let webView, webView === self.web, !self.shown else { return }
            self.measure(force: true)
        }
    }

    /// A link that asks for a new window becomes a tab, and the popup goes —
    /// the way it does in Chrome when you follow a link out of one.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        leave(for: action.request.url)
        return nil
    }

    /// A link with target="_blank" (or a form aimed at a new window): in a
    /// view built from an extension's configuration WebKit asks for its
    /// policy and then never asks for the new view, so the click did
    /// nothing — Raindrop.io's Sign in (idea 972). It's taken here instead.
    /// window.open still comes through createWebViewWith above.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard action.targetFrame == nil, webView === web else { return decisionHandler(.allow) }
        decisionHandler(.cancel)
        leave(for: action.request.url)
    }

    private func leave(for url: URL?) {
        // The same rule as tabs.create: never a file on this Mac, never javascript:.
        if let url, (try? Extensions.mayOpen(url)) != nil {
            Extensions.shared.browser?.open(url, foreground: true)
        }
        close()
    }

    /// The click being handled, not the live mouse state: AppKit can close
    /// the popover on mouse-up, when no button is pressed any more. The
    /// event also keeps its location if the pointer has since moved.
    func popoverWillClose(_ notification: Notification) {
        guard (notification.object as? NSPopover) === popover, let id = extensionID,
              let button, let window = button.window, let event = NSApp.currentEvent,
              event.window === window, event.type == .leftMouseDown || event.type == .leftMouseUp else { return }
        let spot = button.convert(event.locationInWindow, from: nil)
        if button.bounds.contains(spot) { closedByButton = (id, Date()) }
    }

    /// Only for the popover that is up: closing the last one animates, and
    /// its notification can land after the next one has opened.
    func popoverDidClose(_ notification: Notification) {
        guard (notification.object as? NSPopover) === popover else { return }
        measuring?.invalidate()
        measuring = nil
        forget()
    }
}

/// The popup page, as WebKit finds it: in the browser's window, but not
/// among its tabs — which is where Chrome puts a popup too.
@available(macOS 15.4, *)
@MainActor
final class PopupPage: NSObject, WKWebExtensionTab {
    weak var web: WKWebView?
    weak var browser: Browser?

    init(web: WKWebView, browser: Browser? = nil) {
        self.web = web
        self.browser = browser
    }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        (browser ?? Extensions.shared.browser).map(Extensions.shared.window(of:))
    }
    func indexInWindow(for context: WKWebExtensionContext) -> Int { NSNotFound }
    func webView(for context: WKWebExtensionContext) -> WKWebView? { web }
    func title(for context: WKWebExtensionContext) -> String? { web?.title }
    func url(for context: WKWebExtensionContext) -> URL? { web?.url }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !(web?.isLoading ?? false) }
    func isSelected(for context: WKWebExtensionContext) -> Bool { false }
    func close(for context: WKWebExtensionContext) async throws { ExtensionPopup.shared.close() }
}

