import AppKit
import Combine
import WebKit

// MARK: - what a page may do

extension Agent: WKNavigationDelegate, WKUIDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard !action.shouldPerformDownload, let url = action.request.url, let scheme = url.scheme?.lowercased() else {
            return decisionHandler(.cancel)
        }
        // The page itself: the web, or nothing. A frame in it may also be
        // made of what the page has in hand.
        let main = action.targetFrame?.isMainFrame ?? true
        let allowed = main ? ["http", "https", "about"] : ["http", "https", "about", "data", "blob"]
        guard allowed.contains(scheme), scheme != "about" || url.absoluteString == "about:blank" || !main else {
            return decisionHandler(.cancel)
        }
        // A page with your sign-in in it stays on its site. Leaving it, the
        // copy is deleted before the request goes, so it can't be carried
        // anywhere else; the page goes on, signed out.
        // Back or forward once the copy is gone is a fresh load: a page
        // kept whole from before could still hold your sign-in in memory.
        if main, action.navigationType == .backForward,
           let page = pages.first(where: { $0.web === webView }), page.handover?.over != nil {
            decisionHandler(.cancel)
            webView.load(URLRequest(url: url))
            return
        }
        if let page = pages.first(where: { $0.web === webView }) { expire(page) }
        guard let page = pages.first(where: { $0.web === webView }), let handover = page.live,
              ["http", "https"].contains(scheme)
        else { return decisionHandler(.allow) }
        let host = url.host()?.lowercased() ?? ""
        // A frame in the page may go elsewhere — an embedded video, an ad —
        // and the sign-in stays: the copy is only ever sent to its site. A
        // form sent from a frame is a form all the same, and below it is
        // held to the same rules as the page's own.
        // Leaving the site, the page stays where it was: the address it was
        // sent to may carry what the sign-in just got (a sign-in code a
        // redirect hands another site), and the copy is taken back first.
        // The agent can go there itself afterwards, signed out.
        guard !main || Vault.registrable(host) == handover.site else {
            return end(page, "the page tried to leave \(handover.site) for \(host)") { decisionHandler(.cancel) }
        }
        // A form sent with your sign-in: never on a read-only handover, and
        // asked about first unless you said not to.
        guard action.request.httpMethod?.uppercased() == "POST" else { return decisionHandler(.allow) }
        guard handover.acts else {
            page.note("Blocked a form sent to \(host) (read only)")
            return decisionHandler(.cancel)
        }
        guard handover.asks else { return decisionHandler(.allow) }
        ask(page, handover, "Send a form to \(host)\(url.path())") { yes in
            page.note(yes ? "You allowed a form sent to \(host)" : "You refused a form sent to \(host)")
            decisionHandler(yes ? .allow : .cancel)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let page = pages.first(where: { $0.web === webView }) else { return }
        seeded(page)
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        // What can't be shown would be a download.
        decisionHandler(response.canShowMIMEType ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.cancel { _ in }
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.cancel { _ in }
    }

    /// No window of its own: a link meant for one opens in the same page,
    /// when it is a link to the web someone could have followed.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if action.navigationType == .linkActivated, let url = Agent.web(action.request.url?.absoluteString) {
            webView.load(URLRequest(url: url))
        }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void) {
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void) {
        completionHandler(false)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (String?) -> Void) {
        completionHandler(nil)
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor ([URL]?) -> Void) {
        completionHandler(nil)
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) {
        decisionHandler(.deny)
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

    /// A page whose process went away is closed rather than left blank.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard let page = pages.first(where: { $0.web === webView }) else { return }
        close(page)
    }
}
