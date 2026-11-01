import AppKit
import SwiftUI
import WebKit
import Combine

// MARK: - adapters

/// A weak hold on an NSView, for the anchors.
final class WeakView {
    weak var view: NSView?
    init(_ view: NSView) { self.view = view }
}

@available(macOS 15.4, *)
@MainActor
final class ExtensionTab: NSObject, WKWebExtensionTab {
    weak var tab: Tab?
    unowned let owner: Extensions
    private weak var lastWindow: ExtensionWindow?

    init(tab: Tab, owner: Extensions) {
        self.tab = tab
        self.owner = owner
    }

    /// The window this tab is in.
    private var browser: Browser? { tab.flatMap(owner.browser(of:)) }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        // WebKit asks a closed tab for its window after it has left the row,
        // and with none, onRemoved said window -1 and the shim dropped it.
        if let browser { lastWindow = owner.window(of: browser) }
        return lastWindow
    }

    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        guard let tab, let browser else { return NSNotFound }
        return owner.visibleTabs(of: browser, for: context).firstIndex { $0.id == tab.id } ?? NSNotFound
    }

    /// A tab showing another extension's page gives an extension nothing of
    /// it: no view to run a script in, no address, no picture — whatever it
    /// was granted (see Extensions.reachesExtensions).
    private func sealed(_ context: WKWebExtensionContext) -> Bool {
        hidden(context) || Extensions.othersPage(tab?.built?.url, for: context) || Extensions.othersPage(tab?.address, for: context)
    }

    /// A private tab, to an extension not let into private tabs: blank, title
    /// included, and refused anything done to it. WebKit takes a tab's
    /// privacy from its window, and here a window holds both kinds.
    private func hidden(_ context: WKWebExtensionContext) -> Bool {
        tab?.shy == true && !context.hasAccessToPrivateData
    }

    private func checkAccess(_ context: WKWebExtensionContext) throws {
        guard !hidden(context) else {
            throw NSError(domain: "Shy", code: 1, userInfo: [NSLocalizedDescriptionKey: "No tab with that id."])
        }
    }

    func webView(for context: WKWebExtensionContext) -> WKWebView? { sealed(context) ? nil : tab?.built }
    func title(for context: WKWebExtensionContext) -> String? { hidden(context) ? nil : tab?.title }
    func url(for context: WKWebExtensionContext) -> URL? { sealed(context) ? nil : tab?.address }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !(tab?.loading ?? false) }
    func isSelected(for context: WKWebExtensionContext) -> Bool { tab?.id == browser?.activeID }
    func isPinned(for context: WKWebExtensionContext) -> Bool { tab?.pin != nil }
    func isPlayingAudio(for context: WKWebExtensionContext) -> Bool { tab?.noisy ?? false }
    func zoomFactor(for context: WKWebExtensionContext) -> Double { Double(tab?.built?.pageZoom ?? 1) }
    func size(for context: WKWebExtensionContext) -> CGSize { tab?.built?.bounds.size ?? .zero }
    func shouldGrantPermissionsOnUserGesture(for context: WKWebExtensionContext) -> Bool { !hidden(context) }

    func setPinned(_ pinned: Bool, for context: WKWebExtensionContext) async throws {
        try checkAccess(context)
        guard let tab, let browser else { return }
        if pinned, tab.pin == nil { browser.pin(tab) }
        if !pinned, tab.pin != nil { browser.unpin(tab) }
    }

    func setZoomFactor(_ zoomFactor: Double, for context: WKWebExtensionContext) async throws {
        try checkAccess(context)
        tab?.magnify(to: CGFloat(zoomFactor))
    }

    func loadURL(_ url: URL, for context: WKWebExtensionContext) async throws {
        try checkAccess(context)
        guard let tab else { return }
        try Extensions.mayOpen(url)
        // A website's tab sent to one of an extension's own pages — 1Password
        // does, once a sign-in in its tab has added the account. The page
        // can only be served to a view built from that extension's
        // configuration, so the tab is swapped for one that is, as an
        // extension's page sent to a website is (see Browser.replace).
        let url = Extensions.current(url)
        let here = tab.built?.url ?? tab.address
        if url.scheme == Extensions.scheme, here?.scheme != Extensions.scheme || here?.host != url.host, let browser {
            browser.replace(tab, going: url)
            return
        }
        tab.go(to: url)
    }
    func reload(fromOrigin: Bool, for context: WKWebExtensionContext) async throws { try checkAccess(context); tab?.reload(fromOrigin: fromOrigin) }
    func goBack(for context: WKWebExtensionContext) async throws { try checkAccess(context); tab?.back() }
    func goForward(for context: WKWebExtensionContext) async throws { try checkAccess(context); tab?.forward() }

    func activate(for context: WKWebExtensionContext) async throws {
        try checkAccess(context)
        guard let tab, let browser else { return }
        browser.activateForExtension(tab)
    }

    func close(for context: WKWebExtensionContext) async throws {
        try checkAccess(context)
        guard let tab, let browser else { return }
        // A tab in a folder is a pin, which ⌘W only puts down; an extension
        // that closes one, as Claude in Chrome closes the tabs of the group
        // it worked in, means it gone, as Chrome would have it. Its folder
        // goes too once nothing is left in it (see Browser.dropIfEmpty).
        if let folder = browser.folder(of: tab) {
            browser.unpin(tab)
            browser.close(tab)
            browser.dropIfEmpty([folder.id])
        } else {
            browser.close(tab)
        }
    }

    func takeSnapshot(using configuration: WKSnapshotConfiguration, for context: WKWebExtensionContext) async throws -> NSImage? {
        guard let web = tab?.built, !sealed(context) else { return nil }
        return try await web.takeSnapshot(configuration: configuration)
    }
}

@available(macOS 15.4, *)
@MainActor
final class ExtensionWindow: NSObject, WKWebExtensionWindow {
    unowned let owner: Extensions
    /// The window's browser (see Windows.swift).
    weak var browser: Browser?
    init(owner: Extensions, browser: Browser) {
        self.owner = owner
        self.browser = browser
    }

    private var nsWindow: NSWindow? { browser?.window }

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        guard let browser else { return [] }
        return owner.visibleTabs(of: browser, for: context).map(owner.adapter(for:))
    }

    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        browser.flatMap { owner.activeAdapter(of: $0, for: context) }
    }
    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType {
        browser?.isPopup == true ? .popup : .normal
    }
    /// A window here holds private tabs and others, and WebKit would take
    /// this answer for all of them. The shim marks the private ones instead
    /// (`privacy` in ExtensionShims), until WebKit can be told per tab. A
    /// website's pop-up window holds its one page, so it can say.
    func isPrivate(for context: WKWebExtensionContext) -> Bool {
        browser?.websitePopup == true && browser?.active?.shy == true
    }

    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        guard let window = nsWindow else { return .normal }
        if window.isMiniaturized { return .minimized }
        if window.styleMask.contains(.fullScreen) { return .fullscreen }
        return window.isZoomed ? .maximized : .normal
    }

    func frame(for context: WKWebExtensionContext) -> CGRect { nsWindow?.frame ?? .null }
    func screenFrame(for context: WKWebExtensionContext) -> CGRect { nsWindow?.screen?.frame ?? NSScreen.main?.frame ?? .null }

    func focus(for context: WKWebExtensionContext) async throws {
        guard let browser else { return }
        Browsers.show(browser)
    }

    /// windows.remove.
    func close(for context: WKWebExtensionContext) async throws {
        guard context.hasAccessToPrivateData || browser?.tabs.contains(where: { $0.shy }) != true else {
            throw NSError(domain: "Shy", code: 1, userInfo: [NSLocalizedDescriptionKey: "The window contains private tabs this extension cannot access."])
        }
        browser?.window?.performClose(nil)
    }

    /// windows.update with a position or size; unset parts come as NaN and
    /// stay as they are, and the window never goes below its smallest size.
    func setFrame(_ frame: CGRect, for context: WKWebExtensionContext) async throws {
        guard let window = nsWindow else { return }
        let now = window.frame
        func or(_ value: CGFloat, _ current: CGFloat) -> CGFloat { value.isFinite ? value : current }
        let size = NSSize(width: max(window.minSize.width, or(frame.size.width, now.width)),
                          height: max(window.minSize.height, or(frame.size.height, now.height)))
        let origin = NSPoint(x: or(frame.origin.x, now.origin.x), y: or(frame.origin.y, now.origin.y))
        window.setFrame(Extensions.onScreen(NSRect(origin: origin, size: size)), display: true, animate: false)
    }
}
