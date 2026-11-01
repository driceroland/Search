import AppKit
import SwiftUI
import WebKit
import Combine

// MARK: - WebKit asks, the browser answers

@available(macOS 15.4, *)
extension Extensions: WKWebExtensionControllerDelegate {
    /// Every window, oldest first — the order Security's shim counts on.
    func webExtensionController(_ controller: WKWebExtensionController, openWindowsFor extensionContext: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
        Browsers.all.map(window(of:))
    }

    func webExtensionController(_ controller: WKWebExtensionController, focusedWindowFor extensionContext: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        window
    }

    /// Where an extension may send a tab. Not to javascript:, which would run
    /// its code in whatever page the tab shows — an extension with no access
    /// to that site at all — nor to a file on this Mac. Chrome refuses both.
    static func mayOpen(_ url: URL) throws {
        let scheme = url.scheme?.lowercased() ?? ""
        guard scheme != "javascript", scheme != "file" else {
            throw NSError(domain: "Shy", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot navigate to a \(scheme): URL."])
        }
    }

    func webExtensionController(_ controller: WKWebExtensionController, openNewTabUsing configuration: WKWebExtension.TabConfiguration, for extensionContext: WKWebExtensionContext) async throws -> (any WKWebExtensionTab)? {
        // In the window asked for, or the one in front.
        guard let browser = (configuration.window as? ExtensionWindow)?.browser ?? browser else { return nil }
        let url = configuration.url ?? URL(string: "about:blank")!
        try Extensions.mayOpen(url)
        let tab = browser.open(url, foreground: configuration.shouldBeActive, atEnd: true)
        if configuration.shouldBePinned { browser.pin(tab) }
        return adapter(for: tab)
    }

    /// windows.create: a window of its own, with the pages asked for, in
    /// the space of the window in front (see Windows.swift). A popup-type
    /// window is a window like the others here.
    func webExtensionController(_ controller: WKWebExtensionController, openNewWindowUsing configuration: WKWebExtension.WindowConfiguration, for extensionContext: WKWebExtensionContext) async throws -> (any WKWebExtensionWindow)? {
        // A private window isn't something an extension can have here: made
        // as a normal one, its pages would land in the normal space's store
        // and History while the extension believed them private. Refused,
        // as Chrome refuses when incognito isn't allowed (Security).
        if configuration.shouldBePrivate {
            throw NSError(domain: "Shy", code: 2, userInfo: [NSLocalizedDescriptionKey: "Private windows can't be opened by extensions."])
        }
        for url in configuration.tabURLs { try Extensions.mayOpen(url) }
        // A popup has no address bar, only the site over the page: a website,
        // or this extension's own page. Not a data: or blob: page, which
        // could draw anything and name no site, nor another extension's.
        if configuration.windowType == .popup {
            for url in configuration.tabURLs {
                let scheme = url.scheme?.lowercased() ?? ""
                let own = [Extensions.scheme, Extensions.formerScheme].contains(scheme)
                    && url.host()?.lowercased() == extensionContext.uniqueIdentifier.lowercased()
                guard scheme == "https" || scheme == "http" || own || url.absoluteString == "about:blank" else {
                    throw NSError(domain: "Shy", code: 3, userInfo: [NSLocalizedDescriptionKey: "A popup window shows a website or the extension's own page."])
                }
            }
        }
        let fresh = Browser(record: WindowRecord(space: browser?.spaceID ?? Space.firstID))
        // A popup, as a password manager's vault or a sign-in opens: a small
        // window of the page, not another browser window.
        if configuration.windowType == .popup {
            fresh.extensionPopup = contexts.first { $0.value === extensionContext }?.key ?? extensionContext.uniqueIdentifier
        }
        for (index, url) in configuration.tabURLs.enumerated() {
            fresh.open(url, foreground: index == 0, atEnd: true)
        }
        // The empty tab a new window starts with goes once there are pages.
        if !configuration.tabURLs.isEmpty {
            for blank in fresh.tabs where blank.isBlank && !blank.bench { fresh.close(blank) }
        }
        // The frame asked for, when it is one: parts left unset come as
        // numbers that aren't (NaN), and AppKit traps on a frame made of them.
        let asked = configuration.frame
        let usable = !asked.isNull && [asked.minX, asked.minY, asked.width, asked.height].allSatisfy(\.isFinite)
            && asked.width >= 200 && asked.height >= 150
        var frame: NSRect? = usable ? Extensions.onScreen(asked) : nil
        if frame == nil, fresh.extensionPopup != nil, let screen = (browser?.window?.screen ?? NSScreen.main)?.visibleFrame {
            frame = Self.popupFrame(asked: asked, on: screen)
        }
        Browsers.open(fresh, frame: frame)
        if !configuration.shouldBeFocused { Browsers.front?.window?.makeKeyAndOrderFront(nil) }
        return window(of: fresh)
    }

    /// A popup given its size without a place (Affinity's sign-in): that
    /// size, in the middle of the screen. Nil when the size isn't one either.
    /// A frame an extension asked for, kept where you can see it: no larger
    /// than the screen it is mostly on, and with a good part of it on one —
    /// never a window pushed off every screen, or one bigger than all of them.
    @MainActor
    static func onScreen(_ asked: NSRect) -> NSRect {
        let screens = NSScreen.screens.map(\.visibleFrame)
        guard let home = screens.max(by: { $0.intersection(asked).area < $1.intersection(asked).area })
                ?? NSScreen.main?.visibleFrame
        else { return asked }
        var frame = asked
        frame.size.width = min(frame.width, home.width)
        frame.size.height = min(frame.height, home.height)
        let seen = screens.map { $0.intersection(frame) }.max { $0.area < $1.area } ?? .zero
        if seen.width < min(160, frame.width) || seen.height < min(120, frame.height) {
            frame.origin.x = min(max(frame.minX, home.minX), home.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, home.minY), home.maxY - frame.height)
        }
        return frame
    }

    nonisolated static func popupFrame(asked: CGRect, on screen: CGRect) -> CGRect? {
        guard !asked.isNull, asked.width.isFinite, asked.height.isFinite, asked.width >= 200, asked.height >= 150 else { return nil }
        let width = min(asked.width, screen.width), height = min(asked.height, screen.height)
        return CGRect(x: screen.midX - width / 2, y: screen.midY - height / 2, width: width, height: height)
    }

    func webExtensionController(_ controller: WKWebExtensionController, openOptionsPageFor extensionContext: WKWebExtensionContext) async throws {
        guard let url = extensionContext.optionsPageURL else { return }
        browser?.open(url, foreground: true)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissions permissions: Set<WKWebExtension.Permission>, in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext) async -> (Set<WKWebExtension.Permission>, Date?) {
        let detail = permissions.map(\.rawValue).sorted().joined(separator: ", ")
        return await ask("asks for more access", detail: detail, context: extensionContext) ? (permissions, nil) : ([], nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionToAccess urls: Set<URL>, in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext) async -> (Set<URL>, Date?) {
        // WebKit asks this the way Safari does: whenever an extension reaches
        // for a page it has no host permission for — listing tabs, running a
        // script in one — often with nobody having touched anything. Chrome
        // never asks there: the extension has the sites its manifest named,
        // the page it was clicked on (activeTab), and the ones it asked for
        // through permissions.request. So neither does Shy.
        asked.append("(refused) \(extensionContext.webExtension.displayName ?? "?") → \(Set(urls.compactMap { $0.host() }).sorted().joined(separator: ", "))")
        return ([], nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>, in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext) async -> (Set<WKWebExtension.MatchPattern>, Date?) {
        // Extension pages and files are never given, so never asked about.
        let wanted = matchPatterns.filter { !Extensions.withheld($0) }
        guard !wanted.isEmpty else { return ([], nil) }
        let all = wanted.contains { $0.matchesAllHosts || $0.matchesAllURLs }
        let what = all ? "every website" : wanted.map(\.string).sorted().joined(separator: ", ")
        guard await ask("wants to read and change \(what)", detail: "Until you remove the extension.", context: extensionContext) else { return ([], nil) }
        // Given only once this returns: fenced again right after.
        DispatchQueue.main.async { Extensions.fence(extensionContext) }
        return (wanted, nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, didUpdate action: WKWebExtension.Action, forExtensionContext context: WKWebExtensionContext) {
        actionsChanged += 1
    }

    /// The popup page, in a popover of the browser's own (ExtensionPopup
    /// says why): WebKit's view is only asked which page it would show.
    func webExtensionController(_ controller: WKWebExtensionController, presentActionPopup action: WKWebExtension.Action, for context: WKWebExtensionContext) async throws {
        let url = action.popupWebView?.url ?? Extensions.popupURL(for: context)
        action.closePopup()
        guard let url else { return }
        ExtensionPopup.shared.show(url, for: context, from: anchor(for: context.uniqueIdentifier))
    }

    // WebKit supplies this before loading each new background view, including
    // a worker woken inside the same extension context. No timer or JS probe.
    @objc(_webExtensionController:didCreateBackgroundWebView:forExtensionContext:)
    func createdBackground(_ controller: WKWebExtensionController, webView: WKWebView, context: WKWebExtensionContext) {
        ExtensionWorkerRecovery.shared.created(webView, in: context)
    }

    /// `runtime.sendNativeMessage`. To "shy" — the APIs WebKit doesn't
    /// have, answered by this app. To anything else — a Chrome native
    /// messaging host installed on this Mac, spoken to the way Chrome would.
    func webExtensionController(_ controller: WKWebExtensionController, sendMessage message: Any, toApplicationWithIdentifier applicationIdentifier: String?, for extensionContext: WKWebExtensionContext) async throws -> Any? {
        if applicationIdentifier == nil || applicationIdentifier == ExtensionShims.application {
            return try await ExtensionShims.answer(message, from: extensionContext, owner: self)
        }
        let id = extensionContext.uniqueIdentifier, host = applicationIdentifier!
        // WebKit's nativeMessaging is granted to every extension, for the
        // line to Shy above; an app on this Mac only to one whose
        // manifest asks for it, as in Chrome.
        guard Extensions.asksForNative(extensionContext) else {
            throw ExtensionNative.Refused(why: "Access to native messaging requires the nativeMessaging permission.")
        }
        do {
            return try await ExtensionNative.send(message, to: host, from: id)
        } catch {
            // An extension asking an app that isn't there, over and over —
            // a retry loop — is answered slowly once it has asked a dozen
            // times in a second, so it can't swamp the browser.
            let key = id + "→" + host, now = Date()
            failures[key] = (failures[key] ?? []).filter { now.timeIntervalSince($0) < 1 } + [now]
            if (failures[key]?.count ?? 0) > 12 { try? await Task.sleep(for: .seconds(1)) }
            throw error
        }
    }

    func webExtensionController(_ controller: WKWebExtensionController, connectUsing port: WKWebExtension.MessagePort, for extensionContext: WKWebExtensionContext) async throws {
        let id = extensionContext.uniqueIdentifier
        let ports = nativePorts[id] ?? NSHashTable<WKWebExtension.MessagePort>.weakObjects()
        ports.add(port)
        nativePorts[id] = ports
        if port.applicationIdentifier == ExtensionSocket.name {
            ExtensionSocket.connect(port, from: extensionContext.uniqueIdentifier)
            return
        }
        // The port a worker's shim opens only to find what ports share; it
        // lets go at once.
        if port.applicationIdentifier == ExtensionShims.application { return }
        guard Extensions.asksForNative(extensionContext) else {
            throw ExtensionNative.Refused(why: "Access to native messaging requires the nativeMessaging permission.")
        }
        try ExtensionNative.connect(port, from: extensionContext.uniqueIdentifier)
    }
}
