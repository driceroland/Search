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
// up to 600 tall; the page is measured after it loads and again as it
// changes, and the popover follows. window.close() closes it.
//
// The popover is seen only once the page has settled on a size. Most popups
// fill themselves in from a script a moment after the document is built, so
// the first measure is a sliver: shown then, the popover came in narrow and
// short and stretched down and then across as the measures caught up. It
// stands unseen instead — up, so the page runs and paints as it would — is
// measured again quickly until two measures agree, and then fades in.

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

    /// The popup's web view, while one is up — for the bench.
    var view: WKWebView? { web }

    func show(_ url: URL, for context: WKWebExtensionContext, from anchor: NSView?) {
        close()
        guard let configuration = context.webViewConfiguration else { return }
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
        // it stands as a sliver whatever it was told.
        host.preferredContentSize = stage.frame.size
        let popover = NSPopover()
        popover.contentViewController = host
        popover.contentSize = stage.frame.size
        popover.behavior = .transient
        // Nothing animates while it is unseen: a resize still under way when
        // it fades in would be seen finishing.
        popover.animates = false
        popover.delegate = self

        self.web = web
        self.popover = popover
        extensionID = context.uniqueIdentifier
        let page = PopupPage(web: web)
        self.page = page
        Extensions.shared.controller.didOpenTab(page)

        shown = false
        presented = false
        opened = Date()
        button = anchor.flatMap { $0 === Extensions.shared.anchors[context.uniqueIdentifier]?.view ? $0 : nil }
        if let anchor, anchor.window != nil {
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        } else if let content = (NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain && $0.frame.minX > -10_000 }))?.contentView {
            let spot = NSRect(x: content.bounds.maxX - 60, y: content.bounds.maxY - 40, width: 1, height: 1)
            popover.show(relativeTo: spot, of: content, preferredEdge: .minY)
        }
        stage.window?.alphaValue = 0
        // Measured when the document is built (see below) or has loaded, and
        // seen once the size holds (see settle); a page slow to get that far
        // is seen anyway after a moment, at the size it had last time, is
        // measured regardless a little later, and shown regardless after that.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self, weak popover] in
            guard let self, let popover, popover === self.popover else { return }
            self.present()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self, weak popover] in
            guard let self, let popover, popover === self.popover else { return }
            self.firstMeasure()
            self.follow()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self, weak popover] in
            guard let self, let popover, popover === self.popover else { return }
            self.reveal()
        }
    }

    /// Each extension's popup size, so the next opening starts there.
    private static var lastSize: [String: NSSize] = [:]
    private var shown = false

    /// Whether the popover has been let be seen, rather than still standing
    /// unseen while its page is measured.
    private var presented = false
    private var opened = Date()

    /// The popover faded in, and from then on animating as popovers do.
    private func present() {
        guard !presented, let popover, let window = popover.contentViewController?.view.window else { return }
        presented = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            window.animator().alphaValue = 1
        }, completionHandler: { [weak popover] in
            MainActor.assumeIsolated { popover?.animates = true }
        })
    }

    /// The page, at the popover's size, in view.
    private func reveal() {
        guard !shown, let web, let stage = popover?.contentViewController?.view else { return }
        shown = true
        web.frame = NSRect(origin: .zero, size: popover?.contentSize ?? stage.bounds.size)
        web.autoresizingMask = [.width, .height]
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            web.animator().alphaValue = 1
        }
    }

    /// From the page's first load: sized, then followed as it grows — a
    /// list filled in by a reply from the worker — for a few seconds.
    private func follow() {
        guard measuring == nil else { return }
        if !shown { firstMeasure() }
        ticks = 0
        var ticks = 0
        measuring = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                ticks += 1
                self?.grow()
                if ticks > 24 { timer.invalidate() }
            }
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
    }


    /// The size Chrome would give the popup (Blink's auto-size, between
    /// 25 × 25 and 800 × 600), worked out in the page while its view is
    /// still the 25-point square: the width the page names for itself if it
    /// names one, else its narrowest (min-content — what is positioned off
    /// to the side doesn't count), else, for a page with next to no width
    /// of its own, what its content spans; then, laid out at that width,
    /// the height it names or spans. Nothing of it is left on the page.
    static let preferred = """
    () => {
      const d = document.documentElement;
      if (!d) return null;
      const m = window.__searchSizing || (window.__searchSizing = {});
      const saved = d.getAttribute("style");
      const back = () => saved === null ? d.removeAttribute("style") : d.setAttribute("style", saved);
      const box = d.getBoundingClientRect();
      // A width the page sets for itself shows as one the view doesn't
      // have; one equal to the view is either filling it or the width it
      // was given last time, remembered.
      let w;
      if (Math.abs(box.width - innerWidth) > 1) w = m.w = box.width;
      else if (m.w && Math.abs(m.w - innerWidth) <= 1) w = m.w;
      else {
        d.style.setProperty("width", "min-content", "important");
        const narrowest = d.getBoundingClientRect().width;
        back();
        w = narrowest >= 100 ? narrowest : Math.max(narrowest, d.scrollWidth);
      }
      w = Math.min(800, Math.max(25, Math.ceil(w)));
      d.style.setProperty("width", w + "px", "important");
      let h = d.getBoundingClientRect().height;
      if (Math.abs(h - innerHeight) > 1) m.h = h;
      else if (m.h && Math.abs(m.h - innerHeight) <= 1) h = m.h;
      else {
        d.style.setProperty("height", "auto", "important");
        d.style.setProperty("min-height", "0", "important");
        h = d.getBoundingClientRect().height;
      }
      back();
      return [w, Math.min(600, Math.max(25, Math.ceil(h)))];
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
        firstMeasure()
    }

    /// Measured while still the 25-point square and unseen, then shown at
    /// the size found.
    private func firstMeasure() {
        guard let web, !shown else { return }
        web.evaluateJavaScript("(\(ExtensionPopup.preferred))()") { [weak self] value, _ in
            MainActor.assumeIsolated {
                guard let self, web === self.web, !self.shown else { return }
                guard let pair = value as? [Double], pair.count == 2 else { return }
                self.apply(NSSize(width: pair[0], height: pair[1]))
                self.settle(last: nil)
            }
        }
    }

    /// Measured again, quickly, while the popover is unseen, and let be
    /// seen once two measures agree and the page has loaded — or, for one
    /// that keeps changing, after a moment regardless.
    private func settle(last: NSSize?) {
        guard !presented, let web, let popover else { return }
        web.evaluateJavaScript("(\(ExtensionPopup.preferred))()") { [weak self] value, _ in
            MainActor.assumeIsolated {
                guard let self, web === self.web, !self.presented else { return }
                var size = popover.contentSize
                if let pair = value as? [Double], pair.count == 2 {
                    size = NSSize(width: pair[0], height: pair[1])
                    if abs(size.width - popover.contentSize.width) > 2 || abs(size.height - popover.contentSize.height) > 2 { self.apply(size) }
                }
                let holds = last.map { abs($0.width - size.width) <= 2 && abs($0.height - size.height) <= 2 } ?? false
                if (holds && !web.isLoading) || Date().timeIntervalSince(self.opened) > 0.6 {
                    self.present()
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { self.settle(last: size) }
                }
            }
        }
    }

    private func apply(_ size: NSSize) {
        guard let popover else { return }
        if abs(size.width - popover.contentSize.width) > 1 || abs(size.height - popover.contentSize.height) > 1 {
            // The popover takes its size from its view controller, and goes
            // back to it: both are told.
            popover.contentViewController?.preferredContentSize = size
            popover.contentSize = size
            popover.contentViewController?.view.setFrameSize(size)
            if shown { web?.frame = NSRect(origin: .zero, size: size) }
        }
        if let id = extensionID { ExtensionPopup.lastSize[id] = size }
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
      const d = document.documentElement;
      if (!d) return null;
      if (key === "height") return d.scrollHeight;
      const own = d.getBoundingClientRect().width;
      if (own > innerWidth + 1) return own;
      const saved = d.getAttribute("style");
      d.style.setProperty("width", "min-content", "important");
      const narrowest = d.getBoundingClientRect().width;
      saved === null ? d.removeAttribute("style") : d.setAttribute("style", saved);
      return narrowest >= 100 ? narrowest : Math.max(narrowest, d.scrollWidth);
    })
    """

    /// Measured again as the page builds itself, the way Chrome measures on
    /// each layout: for its first two seconds the popup follows it either
    /// way, after that it only grows — so a page that settles doesn't set
    /// it rocking.
    private var ticks = 0
    private func grow() {
        guard shown, let web, let popover else { return }
        ticks += 1
        if ticks <= 8 {
            web.evaluateJavaScript("(\(ExtensionPopup.preferred))()") { [weak self] value, _ in
                MainActor.assumeIsolated {
                    guard let self, let pair = value as? [Double], pair.count == 2 else { return }
                    let wanted = NSSize(width: pair[0], height: pair[1])
                    let now = popover.contentSize
                    if abs(wanted.width - now.width) > 2 || abs(wanted.height - now.height) > 2 { self.apply(wanted) }
                }
            }
            return
        }
        web.evaluateJavaScript("[\(ExtensionPopup.reach)('width'), (() => { const d = document.documentElement; return d && d.scrollHeight > d.clientHeight ? d.scrollHeight : 0; })()]") { value, _ in
            MainActor.assumeIsolated {
                guard let pair = value as? [Double], pair.count == 2 else { return }
                let now = popover.contentSize
                let wanted = NSSize(width: min(800, max(now.width, pair[0])), height: min(600, max(now.height, pair[1])))
                if wanted != now { self.apply(wanted) }
            }
        }
    }

    // MARK: - the page asking

    func webViewDidClose(_ webView: WKWebView) { close() }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { follow() }

    /// A link that asks for a new window becomes a tab, and the popup goes —
    /// the way it does in Chrome when you follow a link out of one.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url { Extensions.shared.browser?.open(url, foreground: true) }
        close()
        return nil
    }

    /// A popover that closes on a click outside it closes on the press —
    /// and a press on its own button is outside it. The button's release
    /// then comes to press(), which would open it straight back up: the
    /// popup could never be closed from the button that opened it, as it
    /// can in Chrome. So the press that closed it is noted when it lands on
    /// that button, and the release that follows opens nothing.
    private var closedFromButton: (id: String, at: TimeInterval)?
    /// The extension's own button, when the popover hangs from it — not the
    /// puzzle button, whose click opens the list instead.
    private weak var button: NSView?

    func popoverWillClose(_ notification: Notification) {
        guard let popover = notification.object as? NSPopover, popover === self.popover, let extensionID,
              let event = NSApp.currentEvent, event.type == .leftMouseDown,
              let anchor = button, let window = anchor.window, event.window === window,
              anchor.bounds.contains(anchor.convert(event.locationInWindow, from: nil))
        else { return }
        closedFromButton = (extensionID, event.timestamp)
    }

    /// Whether a press on an extension's button is only there to close its
    /// popup: the one up now, or one this same click has just closed. A
    /// press that never came up again on the button — dragged off it — is
    /// forgotten after a moment, so it doesn't swallow the next one.
    func pressCloses(_ id: String) -> Bool {
        defer { closedFromButton = nil }
        if extensionID == id, popover != nil {
            close()
            return true
        }
        guard let closed = closedFromButton, closed.id == id else { return false }
        let now = NSApp.currentEvent?.timestamp ?? ProcessInfo.processInfo.systemUptime
        return now - closed.at < 1
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

    init(web: WKWebView) { self.web = web }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { Extensions.shared.window }
    func indexInWindow(for context: WKWebExtensionContext) -> Int { NSNotFound }
    func webView(for context: WKWebExtensionContext) -> WKWebView? { web }
    func title(for context: WKWebExtensionContext) -> String? { web?.title }
    func url(for context: WKWebExtensionContext) -> URL? { web?.url }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !(web?.isLoading ?? false) }
    func isSelected(for context: WKWebExtensionContext) -> Bool { false }
    func close(for context: WKWebExtensionContext) async throws { ExtensionPopup.shared.close() }
}

