import SwiftUI
import WebKit
import Combine

// MARK: - WebKit

extension Browser: WKNavigationDelegate, WKUIDelegate {
    /// Every navigation is decided in `decide` below; this form of the
    /// question also hands over the page's preferences, the only place a
    /// site allowed to play sound by itself can say so (see Autoplay). Only
    /// a page that is allowed to load, in the tab's own frame, is touched.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor action: WKNavigationAction,
        preferences: WKWebpagePreferences,
        decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
    ) {
        decide(webView, action) { [weak self] policy in
            // Revoke before WebKit can run the old document's unload handlers.
            // A nil target is a new window, not this tab leaving its document.
            if policy == .allow, action.targetFrame?.isMainFrame == true {
                self?.popupTab(for: webView)?.popupGesture.clear()
            }
            if policy == .allow, action.targetFrame?.isMainFrame ?? true, let url = action.request.url {
                // The page's own store says whose sites may play: a peek or a
                // little window is in no row (see scoped).
                let store = webView.configuration.websiteDataStore
                let profile = self?.tab(for: webView)?.shy == true || !store.isPersistent ? nil : Profiles.owner(of: store)
                Autoplay.apply(to: preferences, for: url, profile: profile,
                               made: webView.configuration.mediaTypesRequiringUserActionForPlayback)
            }
            decisionHandler(policy, preferences)
        }
    }

    /// Links the window has no business showing — mail, calls, an app's own
    /// scheme — are handed to whoever does own them.
    private func decide(
        _ webView: WKWebView,
        _ action: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        // "Download Image" from the page's own context menu and a link with
        // the `download` attribute arrive as an ordinary-looking action with
        // this one flag set. ("Download Linked File" doesn't come this way:
        // see contextMenuDidCreateDownload below.) Answered
        // with `.allow`, as anything else here was, WebKit tries to load it
        // as if it were the next page — nowhere for that to go, so nothing
        // happens and nothing says why. `.download` is what turns it into
        // the `WKDownload` that `didBecome download:` below already knows
        // what to do with.
        guard !action.shouldPerformDownload else {
            decisionHandler(.download)
            return
        }
        guard let url = action.request.url, let scheme = url.scheme?.lowercased() else {
            decisionHandler(.allow)
            return
        }

        // An extension's OAuth sign-in coming back: the address is the
        // answer, handed to the extension, and never loaded.
        if ExtensionAuth.intercept(url, browser: self, from: webView)
            || ExtensionAuth.handOver(url, mainFrame: action.targetFrame?.isMainFrame == true, browser: self, from: webView) {
            decisionHandler(.cancel)
            return
        }

        // 0.0.0.0, as a dev server prints it: this Mac, as localhost (see
        // Address.reachable). Only the page itself; a frame goes nowhere.
        if action.targetFrame?.isMainFrame == true, let local = Address.reachable(url) {
            decisionHandler(.cancel)
            webView.load(URLRequest(url: local))
            return
        }

        // An extension's rule sending a site to one of its pages (Norma's
        // block page): that page needs another view too.
        if #available(macOS 15.4, *), routeRuleRedirect(action, from: webView) {
            decisionHandler(.cancel)
            return
        }

        // A website returning to a public extension page needs another view.
        if #available(macOS 15.4, *), routeExtensionReturn(action, from: webView) {
            decisionHandler(.cancel)
            return
        }

        // An extension's page sending its own tab to a website (see
        // replace(_:going:)).
        if #available(macOS 15.4, *), ["http", "https"].contains(scheme),
           action.targetFrame?.isMainFrame ?? true,
           webView.url?.scheme == Extensions.scheme,
           let tab = tab(for: webView) {
            decisionHandler(.cancel)
            DispatchQueue.main.async { [weak self] in self?.replace(tab, going: url) }
            return
        }

        // ⌘-click opens beside this tab and leaves you where you are; ⌘⇧-click
        // takes you with it.
        //
        // The middle button is not judged here. WebKit hands the browser a
        // navigation action for a ⌘-click and none at all for a middle one,
        // and where it does report a button it answers with a mask — 1 left,
        // 2 right, 4 middle — so a check for 2 here would have meant the right
        // button, not the middle (see MiddleRelay, which is where the middle
        // button is answered).
        //
        // Should a WebKit ever hand one over for the middle button after all,
        // it is cancelled: MiddleRelay has already opened the link in a tab of
        // its own, and letting this one through would take the page there too.
        if action.navigationType == .linkActivated, action.buttonNumber == 4 {
            decisionHandler(.cancel)
            return
        }
        // The chosen modified click: a peek at the link, over this
        // page (see Peek.swift). Only from a tab in the row — within a peek,
        // a link just goes.
        if action.navigationType == .linkActivated, action.byPerson,
           ["http", "https"].contains(scheme),
           action.modifierFlags.intersection([.shift, .command, .option, .control]) == prefs.peekClick.flags,
           let from = tab(for: webView), peekTab == nil {
            decisionHandler(.cancel)
            DispatchQueue.main.async { [weak self] in self?.peek(url, from: from) }
            return
        }
        // A plain click in a pin, on a link to another site: a peek too, when
        // Settings says so (see peeksFromPin). Links into the page's frames
        // are the page's own business. A link the site sends out by way of
        // itself, as Google's results go by google.com/goto, is asked about
        // again at the redirect, still as a click — by then webView.url is
        // already where it is going, so the page it was on is the one in the
        // history.
        if action.navigationType == .linkActivated, action.targetFrame?.isMainFrame == true,
           action.modifierFlags.intersection([.shift, .command, .option, .control]).isEmpty,
           let from = tab(for: webView), peeksFromPin(url, in: from, on: webView.backForwardList.currentItem?.url) {
            decisionHandler(.cancel)
            DispatchQueue.main.async { [weak self] in self?.peek(url, from: from) }
            return
        }
        if action.navigationType == .other, action.targetFrame?.isMainFrame == true,
           let from = tab(for: webView), followsPeek(url, in: from) {
            decisionHandler(.cancel)
            return
        }
        // A ⌘-click a person made. WebKit reports a click a script made up
        // (dispatchEvent with metaKey) as a link activated with ⌘ too, and
        // a page looping one would open tab after tab behind your back.
        if action.navigationType == .linkActivated, action.byPerson,
           ["http", "https"].contains(scheme),
           action.modifierFlags.contains(.command) {
            openClicked(url, foreground: action.modifierFlags.contains(.shift), from: tab(for: webView), view: webView)
            decisionHandler(.cancel)
            return
        }

        // The next document gets this site's stylesheet of hidden things,
        // decided here because here is the last moment before it loads.
        // The tab's own main frame only: a nil target is a new window, and a
        // window.open (even a refused one) must not retune the opener.
        if action.targetFrame?.isMainFrame == true, let tab = tab(for: webView) {
            let host = curtain.host(of: url)
            tab.arm(hiding: Profiles.curtain(tab.profile).css(on: host), to: url)
            // And the blocker, on or off for where it is going.
            Shield.shared.tune(webView.configuration.userContentController, for: host, in: tab.shy ? nil : tab.profile)
            // And the frames that played, and the count to the media keys.
            tab.leaving()
        }

        // chrome-extension: an extension's own pages — options, a side
        // panel, a tab it opened. WebKit serves them; nothing else here does.
        if ["http", "https", "file", "about", "data", "blob", "chrome-extension", "webkit-extension"].contains(scheme) {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
            handOff(url, scheme: scheme, action: action, from: webView)
        }
    }

    /// Unlike tabs.update(), a website's navigation must be checked against
    /// web_accessible_resources before using an extension view.
    @available(macOS 15.4, *)
    private func routeExtensionReturn(_ action: WKNavigationAction, from webView: WKWebView) -> Bool {
        guard let tab = tab(for: webView) else { return false }
        let source = tab.extensionReturn.source(for: action)
        guard let requested = action.request.url else { return false }
        let target = Extensions.current(requested)
        guard target.scheme == Extensions.scheme, let source else { return false }
        return handOverExtensionReturn(target, source: source, from: webView, tab: tab)
    }

    /// WebKit marks the navigation it starts for a content rule's redirect
    /// (`_isContentExtensionRedirect`); a page can't. What a page could reach
    /// is still all it gets: the file must be one the extension exposes to
    /// the site the tab was going to, as Chrome requires of a redirect to an
    /// extension's file.
    @available(macOS 15.4, *)
    private func routeRuleRedirect(_ action: WKNavigationAction, from webView: WKWebView) -> Bool {
        guard action.targetFrame?.isMainFrame == true,
              action.responds(to: NSSelectorFromString("_isContentExtensionRedirect")),
              (action.value(forKey: "_isContentExtensionRedirect") as? Bool) == true,
              let tab = tab(for: webView), let requested = action.request.url
        else { return false }
        let source = tab.extensionReturn.ruleSource(for: action)
        let target = Extensions.current(ExtensionRedirectPolicy.ruleTarget(requested))
        guard target.scheme == Extensions.scheme, let source else { return false }
        return handOverExtensionReturn(target, source: source, from: webView, tab: tab, fromRule: true)
    }

    @available(macOS 15.4, *)
    private func handOverExtensionReturn(_ target: URL, source: URL, from webView: WKWebView, tab: Tab, fromRule: Bool = false) -> Bool {
        guard !tab.shy,
              let context = tab.extensionController?.extensionContext(for: target),
              context.isLoaded, context.webViewConfiguration != nil,
              ExtensionRedirectPolicy.allows(target: target, sourceOrigin: source, manifest: context.webExtension.manifest, fromRule: fromRule)
        else { return false }
        let revision = tab.extensionReturn.revision
        DispatchQueue.main.async { [weak self, weak tab, weak webView] in
            guard let self, let tab, let webView,
                  self.tab(for: webView)?.id == tab.id,
                  tab.extensionReturn.revision == revision else { return }
            self.replace(tab, going: target)
        }
        return true
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        cancelDisplay(for: webView)
        guard let navigation else { return }
        tab(for: webView)?.extensionReturn.started(navigation, at: webView.url)
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        guard let navigation, let tab = tab(for: webView) else { return }
        let redirect = tab.extensionReturn.redirected(navigation, to: webView.url)
        guard let redirect, #available(macOS 15.4, *),
              handOverExtensionReturn(Extensions.current(redirect.target), source: redirect.source, from: webView, tab: tab)
        else { return }
        webView.stopLoading()
    }

    /// An address for another app — mail, a call, a meeting. The page itself
    /// may ask, or a frame of the page's own site — Zoom's, Teams' and
    /// Slack's "open the app" pages load it into a frame of their own from a
    /// script — or a click inside any frame. A frame from another site that
    /// asks on its own (an advertisement, say) is ignored. And the other app
    /// opens only once you have said so, as in Safari — except a mail or
    /// phone link you just clicked on, which is exactly what it says.
    private func handOff(_ url: URL, scheme: String, action: WKNavigationAction, from webView: WKWebView) {
        // A click a person made: a script's made-up click is the page asking.
        let clicked = action.navigationType == .linkActivated && action.byPerson
        let source: WKFrameInfo? = action.sourceFrame
        // The page on screen, not one only on its way: a page that starts
        // loading another site and then asks would be named as that site.
        let onScreen = tab(for: webView)?.pageAddress ?? webView.url
        let top = onScreen?.host()?.lowercased() ?? ""
        let asker = source?.securityOrigin.host.lowercased() ?? ""
        let ownSite = source?.isMainFrame == true
            || (!top.isEmpty && !asker.isEmpty && Vault.registrable(asker) == Vault.registrable(top))
        // No target frame is a new window asked for: the frame asking is
        // judged, as for any other frame.
        guard action.targetFrame?.isMainFrame ?? false || clicked || ownSite else {
            if Store.testing { Browser.handedOff.append("\(scheme): ignored") }
            return
        }
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: url) else {
            if Store.testing { Browser.handedOff.append("\(scheme): no app") }
            return
        }
        // A test run can't show the question (see Dialogs): it says it would.
        if Store.testing {
            Browser.handedOff.append("\(scheme): asked")
            return
        }
        if clicked, ["mailto", "tel"].contains(scheme) {
            NSWorkspace.shared.open(url)
            return
        }
        let name = FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
        // One question at a time: a page asking in a loop would otherwise
        // queue a sheet for every time it asked.
        let page = webView as? PageView
        guard page?.askingForApp != true else { return }
        page?.askingForApp = true
        // Over its own tab only, as a page's own questions are (see ask).
        ask(from: webView, show: {
            let alert = NSAlert()
            alert.messageText = "Open \u{201C}\(name)\u{201D}?"
            alert.informativeText = "\(top.isEmpty ? "This page" : top) wants to open \(name)."
            alert.addButton(withTitle: "Open")
            alert.addButton(withTitle: "Cancel")
            Dialogs.show(alert, over: webView) { answer in
                page?.askingForApp = false
                guard answer == .alertFirstButtonReturn else { return }
                NSWorkspace.shared.open(url)
            }
        }, drop: { page?.askingForApp = false })
    }

    /// A link that asks for a new window gets a new tab. The configuration
    /// WebKit hands over has to be the one the new view is built with, or the
    /// opener and the opened can't talk to each other.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for action: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard let opener = popupTab(for: webView) else { return nil }
        let clicked = opener.popupGesture.take(origin: PopupGesture.origin(action.sourceFrame), mainFrame: action.sourceFrame.isMainFrame)
        if !clicked {
            // A second window for a click that already had its one: the
            // duplicate one click must not make, said nowhere.
            if opener.popupGesture.spent() { return nil }
            // No click just before: refused, and the tab says so (see
            // BlockedPopups.swift), unless you allowed pop-ups from this site
            // and it is the site's own page or frame asking.
            guard popupsAllowed(opener, from: action.sourceFrame, top: opener.committed ?? webView.url) else {
                opener.noteBlocked(action.request.url)
                return nil
            }
        }
        let from = opener.id
        // The link menu's Open Link in New Tab, asked for in the last second.
        // Read once: reading it takes it.
        let behind = (webView as? PageView)?.takeBehind() == true
        let popup = windowFeatures.width != nil || windowFeatures.height != nil
            || windowFeatures.toolbarsVisibility?.boolValue == false
        // WebKit's copy of the opener's configuration still holds the
        // opener's user content controller — its scripts and its message
        // handlers. Shared, the new tab claimed the opener's handlers as its
        // own, and closing or sleeping it took them off the opener's page:
        // right-click on a picture on X, after following a link out of it,
        // did nothing at all. Each tab gets a controller of its own.
        configuration.userContentController = WKUserContentController()
        // The opener's copy is what its view was made with, maybe before
        // Settings › Videos wait for a click last moved.
        configuration.mediaTypesRequiringUserActionForPlayback = Web.playback
        // A new window a pin's page asked for on a click — a target="_blank"
        // link, or window.open from the click, as Gmail's links and many
        // sites' do, often by way of a redirect on their own site — opens in
        // the peek rather than the row (see peekWindow). Only on a click:
        // a window the page opens by itself, even from a site allowed
        // pop-ups, takes the tab path as before. A window sized by the page,
        // "Sign in with…", is left alone, as is a modified click, and so is
        // anything that isn't a web page (about:blank, data:, blob:).
        if clicked, !behind, !popup, peekTab == nil, opener.pin != nil,
           [.linkActivated, .other].contains(action.navigationType),
           action.modifierFlags.intersection([.shift, .command, .option, .control]).isEmpty,
           let url = action.request.url, Browser.peekable(url) {
            let page = peekWindow(configuration, from: opener, going: url)
            opener.popupGesture.opened(page.id)
            return page.web
        }
        let tab = Tab(shy: opener.shy, configuration: configuration)
        tab.popup = popup
        tab.opener = from
        if clicked { opener.popupGesture.opened(tab.id) }
        if prefs.popupWindows, windowFeatures.width != nil || windowFeatures.height != nil {
            let sourceSpace = parked.first { $0.value.tabs.contains { $0 === opener } }?.key ?? spaceID
            let popup = Browser(record: WindowRecord(space: sourceSpace), websitePopup: true)
            popup.prepare(tab)
            popup.tabs = [tab]
            popup.activeID = tab.id
            if let url = action.request.url { tab.setAddressOptimistically(url) }
            let screen = (webView.window?.screen ?? NSScreen.main)?.visibleFrame
            let frame = screen.map { Browsers.popupFrame(width: windowFeatures.width?.doubleValue,
                                                        height: windowFeatures.height?.doubleValue, on: $0) }
            Browsers.open(popup, frame: frame)
            return tab.web
        }
        // The link menu's Open Link in New Tab: behind this tab, where a
        // ⌘-click's goes (see open(_:foreground:)).
        let destination = tabDestination
        destination.prepare(tab)
        if behind {
            destination.tabs.insert(tab, at: destination.placeForNew())
        } else {
            destination.tabs.insert(tab, at: destination.placeForFront())
            destination.activeID = tab.id
            destination.editing = false
        }
        // Returning the view is what makes it the target. WebKit loads the
        // request into it itself when the action carries one.
        if let url = action.request.url { tab.setAddressOptimistically(url) }
        return tab.web
    }

    /// A link clicked open in a tab by Shy itself (⌘-click, the middle
    /// button): one click, one tab. When the page's own script already
    /// opened a window for that click, it is the tab — put where the click
    /// asked, behind unless ⇧ was held — and no second one opens. Otherwise
    /// the click is spent, and a window.open after it gets nothing.
    func openClicked(_ url: URL, foreground: Bool, from source: Tab?, view: WKWebView?) {
        let opener = view.flatMap { popupTab(for: $0) }
        if let made = opener?.popupGesture.claim(),
           let tab = Browsers.all.lazy.flatMap(\.tabs).first(where: { $0.id == made }) {
            if !foreground, activeID == tab.id, let source, tabs.contains(where: { $0.id == source.id }) {
                activeID = source.id
            }
            return
        }
        open(url, foreground: foreground, from: source, mayWait: true)
    }

    /// Anything the window can't show is something to keep instead.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor response: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        // What the page answered, for Developer Mode's bar.
        if response.isForMainFrame, let http = response.response as? HTTPURLResponse, let tab = tab(for: webView) {
            DevTools.shared.answered(http.statusCode, in: webView, for: tab, at: http.url)
        }
        // A redirect (3xx) has nowhere to be shown and carries no content of
        // its own, but must be followed rather than downloaded — even if its
        // headers say `application/binary` or `application/octet-stream`, as
        // youtube.com and some servers do on their redirects.
        if let http = response.response as? HTTPURLResponse, (300...399).contains(http.statusCode) {
            decisionHandler(.allow)
            return
        }
        // A server that says "attachment" means a file to keep, even one
        // WebKit could show. Gmail's download button loads the attachment
        // into a hidden frame and counts on exactly that: a PDF shown there
        // instead was the button doing nothing at all.
        if let http = response.response as? HTTPURLResponse,
           let disposition = http.value(forHTTPHeaderField: "Content-Disposition"),
           disposition.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("attachment") {
            decisionHandler(.download)
            return
        }
        // A text file already on this Mac that WebKit has no type for — a
        // hosts file, a .yaml, a Dockerfile — is shown as text, as in Safari
        // and Chrome, rather than copied into Downloads (#525). And one it
        // does show as text is read as UTF-8: WebKit took a file's text for
        // Windows-1252, and every accent in it came out as two letters.
        // Read off the main thread, a file on a slow share included; the
        // decision waits for it, and the window doesn't.
        let plain = response.response.mimeType?.lowercased() == "text/plain"
        if !response.canShowMIMEType || plain, response.isForMainFrame,
           let url = response.response.url, url.isFileURL {
            let showable = response.canShowMIMEType
            Task.detached(priority: .userInitiated) {
                let text = LocalText.contents(of: url)
                await MainActor.run {
                    guard let text else {
                        decisionHandler(showable ? .allow : .download)
                        return
                    }
                    decisionHandler(.cancel)
                    webView.load(text, mimeType: "text/plain", characterEncodingName: "utf-8", baseURL: url)
                }
            }
            return
        }
        decisionHandler(response.canShowMIMEType ? .allow : .download)
    }

    func webView(
        _ webView: WKWebView,
        navigationAction: WKNavigationAction,
        didBecome download: WKDownload
    ) {
        keep(download, from: webView)
        dropEmpty(webView)
    }

    func webView(
        _ webView: WKWebView,
        navigationResponse: WKNavigationResponse,
        didBecome download: WKDownload
    ) {
        keep(download, from: webView)
        dropEmpty(webView)
    }

    /// Download Linked File in the right-click menu. WebKit starts the
    /// download and hands it to a delegate that answers this name, outside
    /// the public framework; unanswered, the file was fetched and went nowhere.
    @objc(_webView:contextMenuDidCreateDownload:)
    func webView(_ webView: WKWebView, contextMenuDidCreateDownload download: WKDownload) {
        keep(download, from: webView)
    }

    /// A tab that has shown nothing, and whose first page turned out to be a
    /// file: a download link that opens in a new tab, as a course site's
    /// attachments do. The file goes on arriving without it. Kept, the tab
    /// held the file's address, came back with the session, and downloaded
    /// the file again each time it was opened. It forgets the address; and
    /// when a page's link opened it, it closes, as in Safari and Chrome, and
    /// you are back on that page. A tab you opened yourself stays, as a new
    /// tab, and so does a window's only tab: closing it would close the
    /// window.
    private func dropEmpty(_ webView: WKWebView) {
        guard let tab = tab(for: webView), tab.committed == nil, tab.pin == nil else { return }
        // Without its address, it is not offered back by ⇧⌘T either.
        tab.forget()
        guard let opener = tab.opener, tabs.count > 1 else { return }
        if tab.id == activeID, let home = tabs.first(where: { $0.id == opener }) {
            select(home)
        }
        close(tab)
    }

    /// Every download this window has going, heard from until it ends — and
    /// counted, so a tab still sending one to disk is never put to sleep.
    func keep(
        _ download: WKDownload,
        from suppliedWebView: WKWebView? = nil,
        continuing entry: FetchEntry? = nil,
        operationID: UUID? = nil,
        helper: WKWebView? = nil
    ) {
        let webView = suppliedWebView ?? download.webView
        // Find privacy before publishing the entry. A private transfer is
        // still tracked internally so its delegate and Finder progress clean
        // up correctly, but it never enters the shared Downloads panel.
        let isPrivate = entry == nil && webView.map {
            !$0.configuration.websiteDataStore.isPersistent || anyTab(for: $0)?.shy == true
        } == true
        download.delegate = self
        if !downloading.contains(where: { $0 === download }) { downloading.append(download) }
        if isPrivate { unlisted.insert(ObjectIdentifier(download)) }
        else { unlisted.remove(ObjectIdentifier(download)) }
        guard fetches.start(
            download,
            owner: self,
            webView: webView,
            listed: !isPrivate,
            entry: entry,
            operationID: operationID,
            helper: helper
        ) else {
            relinquish(download)
            download.cancel { _ in }
            return
        }
        // A true resume may continue the preserved target without asking its
        // delegate for a destination again. Publish Finder progress as soon
        // as the resumed WKDownload is attached; `going` coalesces a later
        // destination callback for the same URL.
        if entry != nil, let destination = entry?.destination {
            fetches.going(download, to: destination, cancel: finderCancellation(for: download))
        }
    }

    /// Pause an active download. WebKit's cancellation callback is the
    /// authoritative source of resume data and also owns cleanup if no
    /// delegate failure callback arrives.
    func pauseDownload(_ entry: FetchEntry) {
        guard entry.canPause, let operation = fetches.beginStop(entry, action: .pause) else { return }
        stopDownload(operation)
    }

    func resumeDownload(_ entry: FetchEntry) {
        guard let operation = fetches.beginResume(entry), let data = operation.resumeData else { return }
        operation.webView.resumeDownload(fromResumeData: data) { download in
            self.continueDownload(download, operation)
        }
    }

    /// From the start, to the folder it went to, under the name it was asked
    /// for: numbered afresh, " 2" and on, past whatever is there now, the
    /// last attempt's half-written file let go first.
    func retryDownload(_ entry: FetchEntry) {
        let folder = entry.destination?.deletingLastPathComponent() ?? downloadsFolder
        guard let operation = fetches.beginRetry(entry, destination: { Self.free(entry.retryName, in: folder) }),
              let request = operation.request else { return }
        operation.webView.startDownload(using: request) { download in
            self.continueDownload(download, operation)
        }
    }

    private func continueDownload(_ download: WKDownload, _ operation: Fetches.StartOperation) {
        guard fetches.accepts(operation) else {
            download.cancel { _ in }
            return
        }
        keep(
            download, from: operation.webView, continuing: operation.entry, operationID: operation.operationID,
            helper: operation.helper ? operation.webView : nil
        )
    }

    /// Active rows stop; paused and failed rows are removed and release their
    /// in-memory resume data and the store they were asked with.
    func cancelDownload(_ entry: FetchEntry) {
        switch entry.state {
        case .downloading:
            guard let operation = fetches.beginStop(entry, action: .cancel) else { return }
            stopDownload(operation)
        case .pausing:
            _ = fetches.upgradeStopToCancel(entry)
        case .resuming:
            fetches.removeStarting(entry)
        case .paused, .failed:
            fetches.removeStopped(entry)
        }
    }

    /// A space deleted: its downloads go with it, whatever they were doing,
    /// as Cancel or Remove would take them, and with them the store they
    /// kept and any view made to ask with it. Its cookies can then be
    /// erased, and nothing is asked with them again.
    func forgetDownloads(of store: WKWebsiteDataStore) {
        for entry in fetches.entries where entry.store === store { cancelDownload(entry) }
    }

    private func stopDownload(_ operation: Fetches.StopOperation) {
        let fetches = self.fetches
        operation.download.cancel { resumeData in
            DispatchQueue.main.async {
                guard let ended = fetches.stopped(operation, resumeData: resumeData) else { return }
                ended.owner.relinquish(operation.download)
            }
        }
    }

    /// Called for both delegate completion and WKDownload.cancel completion;
    /// idempotence handles WebKit choosing either callback order.
    func relinquish(_ download: WKDownload) {
        downloading.removeAll { $0 === download }
        unlisted.remove(ObjectIdentifier(download))
    }

    private func finderCancelled(_ download: WKDownload) {
        guard let operation = fetches.beginFinderStop(download) else { return }
        stopDownload(operation)
    }

    func finderCancellation(for download: WKDownload) -> @Sendable () -> Void {
        { [weak self, weak download] in
            DispatchQueue.main.async {
                guard let self, let download else { return }
                self.finderCancelled(download)
            }
        }
    }

    /// Without this WebKit refuses every request out of hand, and a page that
    /// asks for the camera simply never gets an answer.
    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        askedForCapture(webView, origin: origin, frame: frame, type: type, decisionHandler: decisionHandler)
    }

    /// The camera or microphone, for a tab's page or an extension's popup.
    ///
    /// Remembered for the origin that asked — http://site and https://site,
    /// or another port, are other sites — and never for a private tab, which
    /// leaves nothing behind. An extension's page asking — its popup, or a
    /// frame of its own inside a website (a recorder's camera bubble) — is
    /// named as the extension and remembered for it, never for the site it
    /// sits in: allowing the bubble must not give the site the camera.
    func askedForCapture(_ webView: WKWebView, origin: WKSecurityOrigin, frame: WKFrameInfo, type: WKMediaCaptureType,
                         decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        // An extension capturing, however it went about it: the pill says so.
        if #available(macOS 15.4, *) { ExtensionCapture.shared.watchCapture(webView, frame: frame) }
        let asker = frame.securityOrigin
        let host: String
        let site: String
        if Browser.extensionScheme(asker.protocol) {
            host = Browser.extensionName(asker.host)
            site = "\(asker.protocol.lowercased())://\(asker.host.lowercased())"
        } else {
            host = origin.host.isEmpty ? (tab(for: webView)?.address?.host() ?? "This page") : origin.host
            site = origin.host.isEmpty ? host : "\(origin.protocol)://\(origin.host)" + (origin.port == 0 ? "" : ":\(origin.port)")
        }
        // A page with no host of its own — a file, a data: page — is never
        // remembered: every one of them would share the one answer, and a
        // yes for one local page would hand the camera to the next.
        let key = !Browser.extensionScheme(asker.protocol) && origin.host.isEmpty
            ? nil : scoped("\(site)|\(type.rawValue)", for: webView)

        if let key, let remembered = Store.settings.object(forKey: "capture." + key) as? Bool {
            decisionHandler(remembered ? .grant : .deny)
            return
        }
        // Asked over its own page only, as a page's other questions are (see
        // ask): a tab behind, or the other page of a pair, waits until you go
        // to it, and is asked then — never over the page you are on.
        ask(from: webView, show: { [weak self] in
            guard let self else { return decisionHandler(.deny) }
            // One question at a time. A second page asking while the first is
            // still waiting is refused rather than queued behind it.
            guard !permissionBusy else { return decisionHandler(.deny) }
            decide = decisionHandler
            askedAbout = key ?? ""
            asking = CaptureAsk(host: host, wants: Browser.name(for: type))
        }, drop: { decisionHandler(.deny) })
    }

    /// WebKit's private delegate lets Shy ask before opening the system picker.
    /// Extension pages use separate delegates.
    @objc(_webView:requestDisplayCapturePermissionForOrigin:initiatedByFrame:withSystemAudio:decisionHandler:)
    func askedToShareScreen(_ webView: WKWebView, origin: WKSecurityOrigin, frame: WKFrameInfo,
                            systemAudio: Bool, decisionHandler: @escaping (Int) -> Void) {
        guard !permissionBusy, let tab = (tabs + parkedTabs).first(where: { $0.built === webView })
        else { return decisionHandler(0) }
        let request = UUID()
        displayRequest = request
        displayTab = tab
        decideDisplay = decisionHandler
        let asker = frame.securityOrigin
        let host = origin.host.isEmpty ? (tab.address?.host() ?? "This page") : origin.host
        let named = Browser.extensionScheme(asker.protocol) ? Browser.extensionName(asker.host) : host
        // Recheck ownership when a background tab's question is shown.
        displayHeld = ask(from: webView, show: { [weak self, weak webView] in
            guard let self, displayRequest == request else { return }
            guard let webView, activeID == tab.id, tab.built === webView else { return cancelDisplay() }
            asking = CaptureAsk(host: named, wants: "screen", screen: true, sound: systemAudio)
        }, drop: { [weak self] in
            guard let self, displayRequest == request else { return }
            cancelDisplay()
        })
    }

    /// An extension's own scheme, today's or the one it had before.
    static func extensionScheme(_ scheme: String) -> Bool {
        ["chrome-extension", "webkit-extension"].contains(scheme.lowercased())
    }

    /// An extension by the name it shows, for a question it asks.
    static func extensionName(_ id: String) -> String {
        if #available(macOS 15.4, *), let found = Extensions.shared.installed.first(where: { $0.id.lowercased() == id.lowercased() }) {
            return found.name
        }
        return "An extension"
    }

    /// A page asking where you are. WebKit asks this through a delegate
    /// method that isn't public on the Mac; unanswered, every page is refused.
    ///
    /// Only the page on screen, and only for itself: the tab in front, and
    /// the page's own origin or a frame of that same origin. WebKit already
    /// keeps frames from elsewhere out unless the page lets them in
    /// (allow="geolocation"); here they don't get to borrow the page's
    /// answer at all. Remembered per origin, as the camera is, and never for
    /// a private tab.
    @objc(_webView:requestGeolocationPermissionForOrigin:initiatedByFrame:decisionHandler:)
    func askedForLocation(
        _ webView: WKWebView,
        origin: WKSecurityOrigin,
        frame: WKFrameInfo,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        let give: (WKPermissionDecision) -> Void = { decision in
            guard Store.testing else { return decisionHandler(decision) }
            Browser.locationAnswered = decision == .grant ? "granted" : "denied"
            decisionHandler(.deny)
        }
        // WebKit names the page's origin for a frame it let in, whoever the
        // frame is: the frame's own is what counts.
        let site = Browser.origin(origin.protocol, origin.host, origin.port)
        let asker = frame.securityOrigin
        guard let tab = tab(for: webView), tab.id == activeID, !origin.host.isEmpty,
              let page = webView.url, let scheme = page.scheme, let host = page.host(),
              site == Browser.origin(scheme, host, page.port ?? 0),
              Browser.origin(asker.protocol, asker.host, asker.port) == site
        else { return give(.deny) }
        let key = tab.shy ? nil : scoped("\(site)|location", for: webView)
        if let key, let remembered = Store.settings.object(forKey: "capture." + key) as? Bool {
            return give(remembered ? .grant : .deny)
        }
        // One question at a time, as for the camera.
        guard !permissionBusy else { return give(.deny) }
        decide = give
        askedAbout = key ?? ""
        let named = Browser.extensionScheme(origin.protocol) ? Browser.extensionName(origin.host) : origin.host
        asking = CaptureAsk(host: named, wants: "location", once: true, keeps: key != nil)
    }

    /// A page asking to send notifications. Asked over its own page, as the
    /// camera is, and only for the page's own origin; kept per origin under
    /// the same "capture." keys, so Forget choices takes it back. A private
    /// tab, or Settings › Privacy's switch off, is refused without a card.
    @objc(_webView:requestNotificationPermissionForSecurityOrigin:decisionHandler:)
    func askedForNotifications(_ webView: WKWebView, origin: WKSecurityOrigin, decisionHandler: @escaping (Bool) -> Void) {
        let site = Browser.origin(origin.protocol, origin.host, origin.port)
        guard prefs.siteNotifications, let tab = tab(for: webView), !tab.shy, webView.configuration.websiteDataStore.isPersistent,
              !origin.host.isEmpty,
              let page = webView.url, let scheme = page.scheme, let host = page.host(),
              Browser.origin(scheme, host, page.port ?? 0) == site
        else { return decisionHandler(false) }
        if let remembered = SiteNotifications.choices(in: profile(of: tab))[site] { return decisionHandler(remembered) }
        ask(from: webView, show: { [weak self] in
            guard let self else { return decisionHandler(false) }
            guard !permissionBusy else { return decisionHandler(false) }
            decide = { decision in
                if decision == .grant { SiteNotifications.shared.authorize() }
                decisionHandler(decision == .grant)
                SiteNotifications.shared.objectWillChange.send()
            }
            askedAbout = scoped("\(site)|notifications", for: webView) ?? ""
            asking = CaptureAsk(host: origin.host, wants: "notifications")
        }, drop: { decisionHandler(false) })
    }

    /// "scheme://host[:port]", the way an origin is kept for its answers.
    static func origin(_ scheme: String, _ host: String, _ port: Int) -> String {
        let scheme = scheme.lowercased(), host = host.lowercased()
        let standard = (scheme == "https" && port == 443) || (scheme == "http" && port == 80)
        return "\(scheme)://\(host)" + (port == 0 || standard ? "" : ":\(port)")
    }

    private static func name(for type: WKMediaCaptureType) -> String {
        switch type {
        case .camera: return "camera"
        case .microphone: return "microphone"
        case .cameraAndMicrophone: return "camera and microphone"
        @unknown default: return "camera and microphone"
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        tab(for: webView)?.extensionReturn.finished(navigation)
        fail(webView, error)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        tab(for: webView)?.extensionReturn.finished(navigation)
        fail(webView, error)
    }

    /// A page asking to close itself.
    ///
    /// Signing in with Google — or with anything using OAuth — happens in a
    /// window the page opens, and that window calls close() when it is done.
    /// With nobody listening for it, what is left behind is a tab holding the
    /// blank page the flow ended on: nothing to look at, and nothing for
    /// reload to fetch, because there is no longer an address to fetch.
    func webViewDidClose(_ webView: WKWebView) {
        guard let tab = tab(for: webView) else { return }
        // A popup window is the one page it opened: when that
        // page closes itself (a sign-in, once done), the
        // window goes too, as in Chrome, instead of staying on a blank tab.
        if isPopup, tabs.count == 1 {
            window?.close()
            return
        }
        // Back to whoever opened it, so you land where you started the sign-in
        // rather than wherever the row happens to put you.
        if let opener = tab.opener, let home = tabs.first(where: { $0.id == opener }) {
            select(home)
        }
        tab.pin = nil
        close(tab)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if websitePopup { cancelCapture() }
        popupTab(for: webView)?.popupGesture.clear()
        guard let tab = tab(for: webView) else {
            // A small window's page came: what failed before it is over.
            littleTab(for: webView)?.failure = nil
            // A peek or a small window opens at the size the site has, or
            // the one in Settings, as a tab does: neither is in the row,
            // and both opened at 100% (#691).
            if let page = peekTab?.built === webView ? peekTab : littleTab(for: webView) {
                page.applyRememberedZoom()
            }
            return
        }
        tab.didCommit()
        tab.extensionReturn.finished(navigation)
        if tab.id == activeID {
            invalidateFindPage(retryOnActiveTab: false)
            linkStatus.dismiss()
        }
        tab.failure = nil
        tab.typing = false
        // Whatever you last set this site to, before it draws a single frame
        // at the wrong size.
        tab.applyRememberedZoom()
        // A tab waking from sleep: the new document is in, and a moment
        // after it is on screen the picture of the old one can go.
        tab.uncover(after: 0.45)
    }

    /// Picture in picture's button that sends the video back: its tab
    /// comes forward first, from another space if it is parked there, as
    /// Safari brings back its tab. WebKit waits for the page to be on
    /// screen before it puts the video back; left in a tab nobody was
    /// looking at, it waited, put the video into the unseen page anyway,
    /// and the video stopped there.
    @objc(_webViewFullscreenMayReturnToInline:)
    func webViewFullscreenMayReturnToInline(_ webView: WKWebView) {
        guard let tab = anyTab(for: webView) else { return }
        // WebKit is bringing it back already: going to the tab mustn't ask again.
        if pictured == tab.id { pictured = nil }
        if let space = parked.first(where: { $0.value.tabs.contains { $0 === tab } })?.key {
            switchSpace(to: space)
        }
        if tabs.contains(where: { $0 === tab }), activeID != tab.id { select(tab, floatPrevious: false) }
        guard !Store.testing else { return }
        Browsers.show(self)
        NSApp.activate()
    }

    /// Out of picture in picture, by whatever way: nothing is to be brought
    /// back on return to its tab any more.
    @objc(_webView:hasVideoInPictureInPictureDidChange:)
    func webView(_ webView: WKWebView, hasVideoInPictureInPictureDidChange inPicture: Bool) {
        guard !inPicture, let tab = anyTab(for: webView), pictured == tab.id else { return }
        pictured = nil
    }

    /// The page has drawn something: a view kept out of sight until now, so
    /// as not to show the white it starts as, comes in. WebKit calls this only
    /// on a view asked to — see `PageView.holdForFirstFrame()`.
    @objc(_webView:renderingProgressDidChange:)
    func webView(_ webView: WKWebView, renderingProgressDidChange events: UInt) {
        guard events & PageView.firstFrame != 0 else { return }
        (webView as? PageView)?.showFirstFrame()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // A page with nothing to lay out never has a first frame. Done is
        // done, and it is shown.
        (webView as? PageView)?.showFirstFrame()
        guard let tab = anyTab(for: webView), let url = tab.address else { return }
        tab.uncover()
        // The find bar still open over a page that has just come in: look
        // for the same words on it.
        if tab.id == activeID, finding, findSpec == nil,
           !needle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            look(forward: true)
        }
        tellStore(tab)
        // A page that arrived after a password went out: did the sign-in take?
        tab.settleSignIn()
        // A page in a language you always translate, or one that slept
        // translated (Translate.swift). Nothing at all while it's off.
        tab.translateIfWanted()
        // The icon is asked for whether or not the tab is showing one: it may
        // be turned on a moment later, and a tab that then has to wait for a
        // fetch looks broken.
        Favicons.of(tab.profile).fetch(for: tab)
        guard !tab.shy, !tab.bench else { return }
        let profile = tab.profile
        Profiles.history(profile).record(url, title: tab.title)
        // A site's home page that says where its search is (OpenSearch):
        // with Search a site on, it joins the list (see SiteSearch.learn).
        if url.scheme == "https", url.path.isEmpty || url.path == "/" {
            webView.evaluateInShy(SiteSearch.lookup) { value in
                guard let text = value as? String, let description = URL(string: text) else { return }
                MainActor.assumeIsolated { SiteSearch.learn(from: url, description: description, in: profile) }
            }
        }
    }

    private func fail(_ webView: WKWebView, _ error: Error) {
        let tab = tab(for: webView) ?? littleTab(for: webView)
        tab?.uncover()
        let nsError = error as NSError
        let code = nsError.code
        // Cancelled is not a failure: it's what a redirect, a stopped load, or
        // a second Return in quick succession looks like from here.
        guard code != NSURLErrorCancelled else { return }
        // Nor is a page that turned into a download: WebKit ends that
        // navigation with "frame load interrupted" (102) while the file goes
        // on arriving. Answered as a failure, it covered the page with "The
        // page didn't load" over a download that had worked — clicked again,
        // it downloaded again.
        guard !(nsError.domain == "WebKitErrorDomain" && code == 102) else { return }
        // Nor is a video or sound file opened as a page: WebKit's own player
        // takes it over and ends the load with "plug-in handled load" (204),
        // as in Safari, while the video plays. Answered as a failure, it
        // covered the playing video with "The page didn't load".
        guard !(nsError.domain == "WebKitErrorDomain" && code == 204) else { return }
        tab?.failure = message(for: code)
    }

    private func message(for code: Int) -> String {
        switch code {
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            return "No site at that address."
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
            return "No connection."
        case NSURLErrorTimedOut:
            return "The site took too long to answer."
        case NSURLErrorCannotConnectToHost:
            return "The site refused the connection."
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted:
            return "The connection isn't secure."
        default:
            return "The page didn't load."
        }
    }

    func tab(for webView: WKWebView) -> Tab? {
        tabs.first { $0.built === webView }
    }

    /// A small window's tab (see Little.swift). This browser looks after its
    /// pages without it being one of its tabs, so tab(for:) never finds it,
    /// and a link that failed to load there left the window blank.
    private func littleTab(for webView: WKWebView) -> Tab? {
        LittleWindow.all.first { $0.tab.built === webView }?.tab
    }

    /// Popups belong to the view that received the gesture, including pages
    /// in a Peek or Little window that have no row in this browser yet.
    func popupTab(for webView: WKWebView) -> Tab? {
        guard webView.navigationDelegate === self else { return nil }
        return anyTab(for: webView)
            ?? (peekTab?.built === webView ? peekTab : nil)
            ?? littleTab(for: webView)
    }

    /// The tab a page belongs to, in the space on screen or another: a page
    /// still loading when you went to another space finishes there, and
    /// still goes into History with its icon.
    func anyTab(for webView: WKWebView) -> Tab? {
        tab(for: webView) ?? parkedTabs.first { $0.built === webView }
    }
}

extension WKNavigationAction {
    /// Whether a person's click or key is behind this navigation, as WebKit
    /// knows it, rather than a script's made-up event. Where WebKit doesn't
    /// say, as before: taken as a person's.
    var byPerson: Bool {
        guard responds(to: NSSelectorFromString("_isUserInitiated")) else { return true }
        return (value(forKey: "_isUserInitiated") as? Bool) ?? true
    }
}
