import AppKit
import WebKit

// A small, independent web app installed from Search. It deliberately has no
// bridge into Search: its identity, WebKit store, and permissions are its own.

@MainActor
final class SearchSite: NSObject, NSApplicationDelegate, NSWindowDelegate,
    WKNavigationDelegate, WKUIDelegate {
    private let startURL: URL
    private let appTitle: String
    private let browserURL: URL?
    private let browserBundleID: String?
    private var window: NSWindow?
    private var page: WKWebView!
    private var address: NSTextField!

    fileprivate init?(info: [String: Any]) {
        guard let raw = info["SearchSiteURL"] as? String,
              let url = URL(string: raw), Self.isWebURL(url),
              let title = info["CFBundleDisplayName"] as? String,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        startURL = url
        appTitle = title

        browserBundleID = info["SearchBrowserBundleIdentifier"] as? String
        let configured = (info["SearchBrowserPath"] as? String).flatMap { rawPath -> URL? in
            guard !rawPath.isEmpty else { return nil }
            return URL(fileURLWithPath: rawPath, isDirectory: true)
        }
        browserURL = Self.validBrowser(configured, identifier: browserBundleID)
            ?? Self.installedBrowser(identifier: browserBundleID)
        super.init()
    }

    static func isWebURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else { return false }
        return true
    }

    private static func validBrowser(_ url: URL?, identifier: String?) -> URL? {
        guard let url, let identifier, !identifier.isEmpty,
              Bundle(url: url)?.bundleIdentifier == identifier else { return nil }
        return url
    }

    private static func installedBrowser(identifier: String?) -> URL? {
        guard let identifier, !identifier.isEmpty else { return nil }
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)
        return validBrowser(url, identifier: identifier)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        makeMenu()
        makePage()
        showWindow(loadStart: true)
    }

    private func makePage() {
        let configuration = WKWebViewConfiguration()
        // WebKit's default persistent store belongs to this app's bundle id,
        // keeping its cookies and site data separate from Search's.
        page = WKWebView(frame: .zero, configuration: configuration)
        page.navigationDelegate = self
        page.uiDelegate = self
        page.allowsBackForwardNavigationGestures = true
    }

    private func showWindow(loadStart: Bool) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let frame = NSRect(x: 0, y: 0, width: 980, height: 720)
        let window = NSWindow(contentRect: frame,
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = appTitle
        window.minSize = NSSize(width: 420, height: 320)
        // Keep the single window (and its page) for the app's lifetime. A
        // close hides it; a Dock click brings it back. AppKit releasing it
        // as well as Swift is a double release when the close event drains.
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = makeContent()
        self.window = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if loadStart { page.load(URLRequest(url: startURL)) }
    }

    private func makeContent() -> NSView {
        let root = NSView()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false

        let bar = NSStackView()
        bar.orientation = .horizontal
        bar.alignment = .centerY
        bar.spacing = 5
        bar.edgeInsets = NSEdgeInsets(top: 5, left: 8, bottom: 5, right: 8)
        bar.addArrangedSubview(button("‹", "Back", #selector(goBack)))
        bar.addArrangedSubview(button("›", "Forward", #selector(goForward)))
        bar.addArrangedSubview(button("⌂", "Home", #selector(goHome)))
        bar.addArrangedSubview(button("↻", "Reload", #selector(reloadPage)))
        address = NSTextField(labelWithString: "")
        address.font = .systemFont(ofSize: 12)
        address.textColor = .secondaryLabelColor
        address.lineBreakMode = .byTruncatingMiddle
        address.setContentHuggingPriority(.defaultLow, for: .horizontal)
        bar.addArrangedSubview(address)
        if browserURL != nil {
            bar.addArrangedSubview(button("Open in Search", "Open this page in Search", #selector(openInSearch)))
        }

        let rule = NSBox()
        rule.boxType = .separator
        stack.addArrangedSubview(bar)
        stack.addArrangedSubview(rule)
        page.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(page)
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: 38),
            page.heightAnchor.constraint(greaterThanOrEqualToConstant: 100)
        ])
        return root
    }

    private func button(_ title: String, _ help: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .texturedRounded
        button.setButtonType(.momentaryPushIn)
        button.toolTip = help
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    private func makeMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit \(appTitle)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(appTitle)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        appMenu.items.last?.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        for item in appMenu.items where item.action != #selector(NSApplication.terminate(_:)) {
            item.target = NSApp
        }
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: NSSelectorFromString("undo:"), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: NSSelectorFromString("redo:"), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let pageItem = NSMenuItem()
        let pageMenu = NSMenu(title: "Page")
        pageMenu.addItem(menuItem("Back", #selector(goBack), "["))
        pageMenu.addItem(menuItem("Forward", #selector(goForward), "]"))
        pageMenu.addItem(menuItem("Home", #selector(goHome), "h", modifiers: [.command, .shift]))
        pageMenu.addItem(menuItem("Reload", #selector(reloadPage), "r"))
        pageItem.submenu = pageMenu
        main.addItem(pageItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(menuItem("Close Window", #selector(closeWindow), "w"))
        windowMenu.addItem(menuItem("Minimize", #selector(minimizeWindow), "m"))
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = main
    }

    private func menuItem(_ title: String, _ action: Selector, _ key: String,
                          modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    @objc private func goBack() { if page.canGoBack { page.goBack() } }
    @objc private func goForward() { if page.canGoForward { page.goForward() } }
    @objc private func goHome() { page.load(URLRequest(url: startURL)) }
    @objc private func reloadPage() { page.reload() }
    @objc private func closeWindow() { window?.performClose(nil) }
    @objc private func minimizeWindow() { window?.miniaturize(nil) }

    @objc private func openInSearch() {
        guard let url = page.url, Self.isWebURL(url) else { return }
        guard let browserURL = Self.validBrowser(browserURL, identifier: browserBundleID)
                ?? Self.installedBrowser(identifier: browserBundleID) else {
            showBrowserError("Search could not be found. Recreate this web app from Search to restore the link.")
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: browserURL, configuration: config) { _, error in
            guard let error else { return }
            DispatchQueue.main.async { self.showBrowserError(error.localizedDescription) }
        }
    }

    private func showBrowserError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Couldn’t open this page in Search"
        alert.informativeText = message
        alert.alertStyle = .warning
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showWindow(loadStart: page.url == nil) }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func showExternalScheme(_ url: URL) {
        let alert = NSAlert()
        alert.messageText = "Open this link in another app?"
        alert.informativeText = url.absoluteString
        alert.addButton(withTitle: "Open Link")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .informational
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(url)
        }
    }

    private func updateAddress() {
        guard let url = page.url, Self.isWebURL(url), let host = url.host else {
            address?.stringValue = ""
            window?.title = appTitle
            return
        }
        let origin = "\(url.scheme?.lowercased() ?? "https")://\(host)" + (url.port.map { ":\($0)" } ?? "")
        address?.stringValue = origin
        window?.title = "\(appTitle) — \(host)"
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { updateAddress() }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { updateAddress() }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { updateAddress() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        updateAddress()
        showLoadFailure(error)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        updateAddress()
        showLoadFailure(error)
    }

    private func showLoadFailure(_ error: Error) {
        let nsError = error as NSError
        guard nsError.code != NSURLErrorCancelled else { return }
        let alert = NSAlert()
        alert.messageText = "This page couldn’t be loaded"
        alert.informativeText = nsError.localizedDescription
        alert.alertStyle = .warning
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    private func frameName(_ frame: WKFrameInfo) -> String {
        guard let url = frame.request.url, Self.isWebURL(url), let host = url.host else { return "The page" }
        return host
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if Self.isWebURL(url) {
            if navigationAction.targetFrame == nil {
                // A popup target can carry trusted user data such as an OAuth
                // result, but never let a page create one as a side effect.
                if navigationAction.navigationType == .linkActivated,
                   navigationAction.sourceFrame.isMainFrame {
                    webView.load(navigationAction.request)
                }
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
            return
        }
        decisionHandler(.cancel)
        if navigationAction.navigationType == .linkActivated,
           navigationAction.sourceFrame.isMainFrame,
           let scheme = url.scheme?.lowercased(),
           !["http", "https", "javascript", "data", "file", "about"].contains(scheme) {
            DispatchQueue.main.async { self.showExternalScheme(url) }
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = "\(frameName(frame)) says:"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = "\(frameName(frame)) says:"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = "\(frameName(frame)) asks:"
        alert.informativeText = prompt
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: defaultText ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        completionHandler(alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil)
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.deny)
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.resolvesAliases = true
        guard let window else {
            completionHandler(panel.runModal() == .OK ? panel.urls : nil)
            return
        }
        panel.beginSheetModal(for: window) { response in
            completionHandler(response == .OK ? panel.urls : nil)
        }
    }
}

@MainActor
@main
enum SearchSiteMain {
    static func main() {
        let app = NSApplication.shared
        guard let delegate = SearchSite(info: Bundle.main.infoDictionary ?? [:]) else {
            NSAlert(error: NSError(domain: "SearchSite", code: 1,
                                   userInfo: [NSLocalizedDescriptionKey: "This web app has invalid website configuration."]))
                .runModal()
            return
        }
        app.delegate = delegate
        app.run()
    }
}
