import AppKit
import Combine
import WebKit

// The agent's pages: made, described, closed, and what runs in them.
extension Agent {
    func make() -> Page {
        let config = WKWebViewConfiguration()
        // Its own, forgotten with the page.
        config.websiteDataStore = .nonPersistent()
        config.applicationNameForUserAgent = Web.userAgentName
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.preferences.isElementFullscreenEnabled = false
        config.mediaTypesRequiringUserActionForPlayback = .all
        Web.fileIsolation(config)
        let window = room ?? makeRoom()
        let web = WKWebView(frame: window.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 1280, height: 800), configuration: config)
        web.navigationDelegate = self
        web.uiDelegate = self
        web.autoresizingMask = [.width, .height]
        // Never a sound on your speakers from a page you can't see.
        let mute = NSSelectorFromString("_setPageMuted:")
        if web.responds(to: mute), let imp = web.method(for: mute) {
            typealias Muting = @convention(c) (AnyObject, Selector, UInt) -> Void
            unsafeBitCast(imp, to: Muting.self)(web, mute, 1)
        }
        window.contentView?.addSubview(web)
        let page = Page(id: String(UUID().uuidString.prefix(8)).lowercased(), web: web)
        pages.append(page)
        return page
    }

    /// Back in the room off screen, when no window is showing it: a page
    /// out of every window draws nothing to take a picture of.
    func drawn(_ page: Page) {
        guard page.web.window == nil else { return }
        let window = room ?? makeRoom()
        page.web.frame = window.contentView?.bounds ?? page.web.frame
        window.contentView?.addSubview(page.web)
    }

    /// Every page out of every window put back in the room, a turn after a
    /// window stopped showing one.
    func reroom() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pages.forEach(self.drawn)
        }
    }

    func drop(_ page: Page) {
        page.web.stopLoading()
        page.web.navigationDelegate = nil
        page.web.uiDelegate = nil
        page.web.removeFromSuperview()
        page.acting = nil
    }

    private func makeRoom() -> NSWindow {
        // Off every screen, and never key or main, as the bench's.
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
        window.orderBack(nil)
        room = window
        return window
    }

    /// The page scrolled as a wheel over that point would: the nearest box
    /// under it that scrolls, or the page.
    static let scrolling = Scripts.load("agent-scrolling")

    /// Where the page is scrolled to.
    static let scrolledTo = "return [window.scrollX, window.scrollY]"

    /// The words on the page, as it shows them.
    static let reading = "return document.body ? document.body.innerText : ''"

    /// The element a selector names — a CSS one, or `text=Sign in` for a
    /// button, link or label by its words — found apart from the page.
    private static let finding = Scripts.load("agent-finding")

    static let clicking = finding + Scripts.load("agent-clicking")

    /// Through the field's own setter, with the events a keystroke fires,
    /// so the page's framework notices.
    static let typing = finding + Scripts.load("agent-typing")
}
