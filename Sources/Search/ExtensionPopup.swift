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
    /// The popup a click on its own button just closed: the popover goes
    /// on that click's mouse-down, and the button's press comes after, on
    /// its mouse-up — which would open it again.
    private var closedByButton: (id: String, at: Date)?

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
        let popover = NSPopover()
        popover.contentViewController = host
        popover.contentSize = stage.frame.size
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        self.web = web
        self.popover = popover
        extensionID = context.uniqueIdentifier
        button = anchor != nil && anchor === Extensions.shared.anchors[context.uniqueIdentifier]?.view ? anchor : nil
        let page = PopupPage(web: web)
        self.page = page
        Extensions.shared.controller.didOpenTab(page)

        shown = false
        if let anchor, anchor.window != nil {
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        } else if let content = (NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain && $0.frame.minX > -10_000 }))?.contentView {
            let spot = NSRect(x: content.bounds.maxX - 60, y: content.bounds.maxY - 40, width: 1, height: 1)
            popover.show(relativeTo: spot, of: content, preferredEdge: .minY)
        }
        // Sized once loaded — or after a moment regardless, for a page that
        // never finishes loading.
        // Measured when the document is built (see below) or has loaded;
        // a page slow to do either is measured anyway after a moment, and
        // shown regardless a little later.
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
        button = nil
    }

    /// A press on the button of an extension whose popup is up closes it,
    /// as in Chrome — whether the popover is still there (a click on the
    /// view it hangs from doesn't close it) or went on this click's
    /// mouse-down. Closed, it is not opened again.
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

    /// Closing on a mouse-down over the popup's own button.
    func popoverWillClose(_ notification: Notification) {
        guard (notification.object as? NSPopover) === popover, let id = extensionID,
              let button, let window = button.window, NSEvent.pressedMouseButtons & 1 != 0 else { return }
        let spot = button.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
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

