import AppKit
import WebKit

/// chrome.identity.launchWebAuthFlow: a tab for the provider's sign-in, and
/// the moment it tries to go to https://<id>.chromiumapp.org/, that address
/// is the answer and the tab goes. Browser asks `intercept` about every
/// navigation; nothing is ever loaded from chromiumapp.org.
@MainActor
enum ExtensionAuth {
    private static var waiting: [String: (tab: Tab.ID, finish: (Result<URL, Error>) -> Void)] = [:]
    /// One per flow: whether its tab is still somewhere.
    private static var watches: [String: Timer] = [:]

    struct Declined: LocalizedError {
        var errorDescription: String? { "The user did not approve access." }
    }

    static func run(_ url: URL, extension id: String, browser: Browser) async throws -> URL {
        if #available(macOS 15.4, *) { try Extensions.mayOpen(url) }
        return try await withCheckedThrowingContinuation { continuation in
            waiting[id]?.finish(.failure(Declined()))
            let tab = browser.open(url, foreground: true)
            waiting[id] = (tab.id, { result in continuation.resume(with: result) })
            // Closing the tab is saying no. Moved to another window, or to
            // a space not on screen, it is still there.
            watches[id]?.invalidate()
            let started = Date()
            watches[id] = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                MainActor.assumeIsolated {
                    guard let entry = waiting[id], entry.tab == tab.id else {
                        watches.removeValue(forKey: id)?.invalidate()
                        return
                    }
                    // So is ten minutes with nobody finishing: its address is
                    // no longer watched for.
                    guard !exists(entry.tab) || Date().timeIntervalSince(started) > 600 else { return }
                    waiting[id] = nil
                    watches.removeValue(forKey: id)?.invalidate()
                    entry.finish(.failure(Declined()))
                }
            }
        }
    }

    /// A non-interactive flow, as Chrome runs one: the provider's page loads
    /// in a view that is never on screen, signed in as the tabs are, and the
    /// flow ends the moment it heads for this extension's own
    /// https://<id>.chromiumapp.org/ — or fails, without a word to anyone,
    /// once the page has loaded (unless the extension asked to wait) or the
    /// time is up. Claude in Chrome restores its sign-in this way each time
    /// the browser starts; until now it got a tab in front instead.
    ///
    /// What it allows, no more than a tab opened behind would (which any
    /// extension may do, with no permission): an extension with "identity"
    /// has an http(s) page load out of sight, with the cookies of the
    /// extension's own profile, for at most a minute. It learns only the address it is sent
    /// to on its own chromiumapp.org, never the page. The page gets no other
    /// extension, no popup, dialog, download or app launch, and no other
    /// scheme. One flow per extension at a time; a new one ends the last.
    static func quietly(_ url: URL, extension id: String, store: WKWebsiteDataStore,
                        abortOnLoad: Bool, timeout: TimeInterval?) async throws -> URL {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            throw Quiet.failure("Authorization page could not be loaded.")
        }
        let limit = min(max(timeout ?? Quiet.longest, 0.5), Quiet.longest)
        return try await withCheckedThrowingContinuation { continuation in
            quiet[id]?.end(.failure(Quiet.failure("User interaction required.")))
            let flow = Quiet(extensionID: id, abortOnLoad: abortOnLoad) { result in
                quiet[id] = nil
                continuation.resume(with: result)
            }
            quiet[id] = flow
            flow.start(url, limit: limit, store: store)
        }
    }

    private static var quiet: [String: Quiet] = [:]

    /// The view and its watcher for one non-interactive flow.
    @MainActor
    final class Quiet: NSObject, WKNavigationDelegate, WKUIDelegate {
        /// The longest a flow may run out of sight, whatever it asks.
        static let longest: TimeInterval = 60

        static func failure(_ why: String) -> Error {
            NSError(domain: "Shy", code: 1, userInfo: [NSLocalizedDescriptionKey: why])
        }

        let extensionID: String
        let abortOnLoad: Bool
        private var finish: ((Result<URL, Error>) -> Void)?
        private var view: WKWebView?
        private var timer: Timer?

        init(extensionID: String, abortOnLoad: Bool, finish: @escaping (Result<URL, Error>) -> Void) {
            self.extensionID = extensionID.lowercased()
            self.abortOnLoad = abortOnLoad
            self.finish = finish
        }

        func start(_ url: URL, limit: TimeInterval, store: WKWebsiteDataStore) {
            let config = WKWebViewConfiguration()
            // The sign-ins of the extension's own profile, as the tab an
            // interactive flow opens would have — never the space in front,
            // which may be another profile's; no extension's scripts, and the
            // same user agent as every other view (see Web.userAgentName).
            config.websiteDataStore = store
            config.processPool = Web.pool
            config.applicationNameForUserAgent = Web.userAgentName
            config.preferences.javaScriptCanOpenWindowsAutomatically = false
            // No sound or video from nowhere: nobody can click here.
            config.mediaTypesRequiringUserActionForPlayback = .all
            // WebKit's own passkey operation is never opened (see Passkeys.swift):
            // the page is told there are none, as with passkeys off.
            config.userContentController.addUserScript(
                WKUserScript(source: FormRelay.withoutPasskeys, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
            )
            // In no window, ever: there is nothing to show.
            let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
            view.navigationDelegate = self
            // Without a UI delegate WebKit puts up its own question for the
            // camera, the microphone or the screen; here every one is no.
            view.uiDelegate = self
            Muter.set(true, on: view)
            self.view = view
            timer = Timer.scheduledTimer(withTimeInterval: limit, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.end(.failure(Quiet.failure("User interaction required."))) }
            }
            view.load(URLRequest(url: url))
        }

        /// The extension's own redirect address, and nobody else's.
        private func answer(_ url: URL?) -> Bool {
            guard let url, url.scheme?.lowercased() == "https",
                  url.host()?.lowercased() == extensionID + ".chromiumapp.org" else { return false }
            end(.success(url))
            return true
        }

        /// Any other chromiumapp.org address — another extension's, or this
        /// one's over http — never loads: what it carries (a code, a token)
        /// would go out over the network instead of to nobody.
        private static func chromiumapp(_ url: URL?) -> Bool {
            guard let host = url?.host()?.lowercased() else { return false }
            let bare = host.hasSuffix(".") ? String(host.dropLast()) : host
            return bare == "chromiumapp.org" || bare.hasSuffix(".chromiumapp.org")
        }

        func end(_ result: Result<URL, Error>) {
            guard let finish else { return }
            self.finish = nil
            timer?.invalidate(); timer = nil
            if let view {
                view.navigationDelegate = nil
                view.uiDelegate = nil
                view.stopLoading()
            }
            view = nil
            finish(result)
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            let main = action.targetFrame?.isMainFrame ?? true
            if main, answer(action.request.url) { return decisionHandler(.cancel) }
            if Self.chromiumapp(action.request.url) {
                decisionHandler(.cancel)
                if main { end(.failure(Quiet.failure("Authorization page could not be loaded."))) }
                return
            }
            let scheme = action.request.url?.scheme?.lowercased() ?? ""
            let fine = main ? ["http", "https"] : ["http", "https", "about", "data", "blob"]
            guard !action.shouldPerformDownload, action.targetFrame != nil, fine.contains(scheme) else {
                return decisionHandler(.cancel)
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                     decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
            decisionHandler(response.canShowMIMEType ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
            if answer(webView.url) { webView.stopLoading(); return }
            if Self.chromiumapp(webView.url) {
                webView.stopLoading()
                end(.failure(Quiet.failure("Authorization page could not be loaded.")))
            }
        }

        // A site asking who you are, or holding out a client certificate,
        // gets no answer here: that is interaction. Only the certificate
        // check goes on as usual (and fails the load if it fails).
        func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                     completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
                completionHandler(.performDefaultHandling, nil)
            } else {
                completionHandler(.rejectProtectionSpace, nil)
            }
        }

        // MARK: nothing to show, nothing to ask

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }

        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
            completionHandler()
        }

        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
            completionHandler(false)
        }

        func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
            completionHandler(nil)
        }

        func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
            completionHandler(nil)
        }

        func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                     initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                     decisionHandler: @escaping (WKPermissionDecision) -> Void) {
            decisionHandler(.deny)
        }

        @objc(_webView:requestDisplayCapturePermissionForOrigin:initiatedByFrame:withSystemAudio:decisionHandler:)
        func displayCapture(_ web: WKWebView, origin: WKSecurityOrigin, frame: WKFrameInfo, systemAudio: Bool,
                            decisionHandler: @escaping (Int) -> Void) {
            decisionHandler(0)
        }

        @objc(_webView:requestGeolocationPermissionForOrigin:initiatedByFrame:decisionHandler:)
        func location(_ webView: WKWebView, origin: WKSecurityOrigin, frame: WKFrameInfo,
                      decisionHandler: @escaping (WKPermissionDecision) -> Void) {
            decisionHandler(.deny)
        }

        @objc(_webView:requestNotificationPermissionForSecurityOrigin:decisionHandler:)
        func notifications(_ webView: WKWebView, origin: WKSecurityOrigin, decisionHandler: @escaping (Bool) -> Void) {
            decisionHandler(false)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // A page meant to be seen: Chrome's non-interactive flow ends
            // here unless the extension asked to wait for a script to move on.
            if abortOnLoad { end(.failure(Quiet.failure("User interaction required."))) }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            failed(error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            failed(error)
        }

        private func failed(_ error: Error) {
            // A navigation cancelled here, or replaced by the page's next one,
            // isn't the page failing.
            let error = error as NSError
            if error.domain == NSURLErrorDomain, error.code == NSURLErrorCancelled { return }
            if error.domain == "WebKitErrorDomain", error.code == 102 { return }
            end(.failure(Quiet.failure("Authorization page could not be loaded.")))
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            end(.failure(Quiet.failure("Authorization page could not be loaded.")))
        }
    }

    private static func exists(_ id: Tab.ID) -> Bool {
        Browsers.all.contains { browser in
            browser.tabs.contains { $0.id == id } || browser.parked.values.contains { $0.tabs.contains { $0.id == id } }
        }
    }

    /// True when the address is an extension's OAuth redirect arriving in
    /// the tab that began the sign-in, which is then handed over and never
    /// loaded. Any page can go to an address shaped like one of these, and
    /// what it carries would be delivered as the flow's answer: only the
    /// tab the flow was started in may finish it, or a window that tab's
    /// page opened, since some providers finish the sign-in in a popup.
    static func intercept(_ url: URL, browser: Browser, from webView: WKWebView) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host()?.lowercased(), host.hasSuffix(".chromiumapp.org") else { return false }
        let id = String(host.dropLast(".chromiumapp.org".count))
        guard let entry = waiting[id], let from = browser.tab(for: webView),
              from.id == entry.tab || from.opener == entry.tab
        else { return false }
        waiting.removeValue(forKey: id)
        entry.finish(.success(url))
        // The popup, when the answer came in one, goes with the flow's tab:
        // left behind, it would hold a redirect that never loads.
        watches.removeValue(forKey: id)?.invalidate()
        if from.id != entry.tab { browser.close(from) }
        // The flow's tab, in whichever window it is now.
        for home in Browsers.all {
            if let tab = home.tabs.first(where: { $0.id == entry.tab }) { home.close(tab) }
        }
        return true
    }

    /// The same redirect with no launchWebAuthFlow waiting for it. Some
    /// extensions open the provider's page with tabs.create and watch that
    /// tab's address until it reaches their chromiumapp.org one, then close
    /// the tab (Figma's does). In Chrome the navigation fails onto an error
    /// page that still carries the address, and tabs.onUpdated reports it;
    /// in WebKit a failed load never commits, so nothing would. The tab takes
    /// the address without loading anything, for an installed extension
    /// that asked for identity. What each extension sees of it is WebKit's
    /// call, as for any address: tabs or host access, as in Chrome. Left
    /// open, the tab says what Chrome's would.
    static func handOver(_ url: URL, mainFrame: Bool, browser: Browser, from webView: WKWebView) -> Bool {
        guard mainFrame, url.scheme?.lowercased() == "https", let host = url.host()?.lowercased(),
              host.hasSuffix(".chromiumapp.org") else { return false }
        let id = String(host.dropLast(".chromiumapp.org".count))
        guard #available(macOS 15.4, *), let context = Extensions.owner(of: webView.configuration.webExtensionController)?.contexts[id],
              ExtensionShims.allowed(id, context: context).contains("identity"),
              let tab = browser.tab(for: webView)
        else { return false }
        tab.hold(url)
        Task { @MainActor [weak tab] in
            try? await Task.sleep(for: .seconds(4))
            guard let tab, tab.held == url else { return }
            tab.failure = "No site at that address."
        }
        return true
    }
}
