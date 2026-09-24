import AppKit
import WebKit

// The questions a page is allowed to ask, and the answers it gets.
//
// WebKit does nothing with alert(), confirm(), prompt(), a file input or a
// password-protected site unless somebody answers for them — and "nothing"
// means confirm() is always false, so "leave without saving?" leaves, and a
// file picker that never opens. Each one here is the system's own sheet on the
// window the page is in, which is what every other browser on this Mac shows.

extension Browser {
    // MARK: - alert, confirm, prompt

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        let alert = Dialogs.alert(from: frame, saying: message)
        alert.addButton(withTitle: L("OK"))
        Dialogs.show(alert, over: webView) { _ in completionHandler() }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        let alert = Dialogs.alert(from: frame, saying: message)
        alert.addButton(withTitle: L("OK"))
        alert.addButton(withTitle: L("Cancel"))
        Dialogs.show(alert, over: webView) { answer in
            completionHandler(answer == .alertFirstButtonReturn)
        }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        let alert = Dialogs.alert(from: frame, saying: prompt)
        alert.addButton(withTitle: L("OK"))
        alert.addButton(withTitle: L("Cancel"))
        let field = NSTextField(string: defaultText ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        Dialogs.show(alert, over: webView) { answer in
            completionHandler(answer == .alertFirstButtonReturn ? field.stringValue : nil)
        }
    }

    // MARK: - choosing a file

    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping ([URL]?) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.resolvesAliases = true
        let finish: (NSApplication.ModalResponse) -> Void = { answer in
            completionHandler(answer == .OK ? panel.urls : nil)
        }
        if let window = Dialogs.window(for: webView) {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }

    // MARK: - a site that asks who you are, or can't prove who it is

    func webView(
        _ webView: WKWebView,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let space = challenge.protectionSpace
        switch space.authenticationMethod {
        case NSURLAuthenticationMethodServerTrust:
            trust(webView, challenge, completionHandler)
        case NSURLAuthenticationMethodHTTPBasic,
             NSURLAuthenticationMethodHTTPDigest,
             NSURLAuthenticationMethodNTLM:
            signIn(webView, challenge, completionHandler)
        default:
            completionHandler(.performDefaultHandling, nil)
        }
    }

    /// Every https connection comes through here, not only the broken ones,
    /// so the certificate is checked first and the system is left to it when
    /// it holds up. When it doesn't: something on this Mac — localhost, a
    /// .local name, a private address — is taken on trust, because that is
    /// where self-signed certificates live; anything else is asked about,
    /// once per site per launch, and only for the page itself, never for
    /// something a page pulled in.
    private func trust(
        _ webView: WKWebView,
        _ challenge: URLAuthenticationChallenge,
        _ completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        if SecTrustEvaluateWithError(trust, nil) {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let host = challenge.protectionSpace.host.lowercased()
        if Dialogs.isLocal(host) || Dialogs.excused.contains(host) {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }
        // A picture, a script, a font from a site with a bad certificate is
        // simply not loaded. Only the page you asked for is worth a question.
        guard let tab = tab(for: webView),
              (tab.address?.host() ?? tab.pending?.host())?.lowercased() == host
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let alert = NSAlert()
        alert.messageText = L("%@ can't prove who it is", "\(host)")
        alert.informativeText = L("Its certificate isn't trusted by this Mac. Someone could be reading what you send. Continue only if you know why it looks like this.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("Go Back"))
        alert.addButton(withTitle: L("Continue Anyway"))
        Dialogs.show(alert, over: webView) { answer in
            guard answer == .alertSecondButtonReturn else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            Dialogs.excused.insert(host)
            completionHandler(.useCredential, URLCredential(trust: trust))
        }
    }

    /// A site behind a name and a password — a staging server, a router. One
    /// wrong answer gets another go; the second is taken as "not for me".
    private func signIn(
        _ webView: WKWebView,
        _ challenge: URLAuthenticationChallenge,
        _ completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.previousFailureCount < 2 else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let space = challenge.protectionSpace
        let alert = NSAlert()
        alert.messageText = L("%@ asks you to sign in", "\(space.host)")
        alert.informativeText = space.realm.map { "“\($0)”" } ?? L("The site wants a name and a password.")
        if challenge.previousFailureCount > 0 {
            alert.informativeText += L("\nThat wasn't accepted — try again.")
        }
        alert.addButton(withTitle: L("Sign In"))
        alert.addButton(withTitle: L("Cancel"))

        let box = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 56))
        let name = NSTextField(frame: NSRect(x: 0, y: 32, width: 260, height: 24))
        name.placeholderString = L("Name")
        let pass = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        pass.placeholderString = L("Password")
        name.nextKeyView = pass
        box.addSubview(name)
        box.addSubview(pass)
        alert.accessoryView = box
        alert.window.initialFirstResponder = name

        Dialogs.show(alert, over: webView) { answer in
            guard answer == .alertFirstButtonReturn else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            completionHandler(
                .useCredential,
                URLCredential(user: name.stringValue, password: pass.stringValue, persistence: .forSession)
            )
        }
    }

    // MARK: - a page whose process went away

    /// WebKit runs each page in a process of its own, and the system kills
    /// those under memory pressure — background tabs first. Left alone, the
    /// tab shows white until somebody thinks to reload. Saying so, with the
    /// one thing worth offering, is what the failure view is for.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard let tab = tab(for: webView) else { return }
        // In front of you: straight back, a reload beats a white page with a
        // button on it. Behind another tab: the moment you come back to it.
        if tab.id == activeID, !tab.isBlank {
            tab.recoverFromCrash()
        } else {
            tab.stale = true
        }
    }
}

enum Dialogs {
    /// Sites with bad certificates that were accepted, for this launch only.
    static var excused = Set<String>()

    static func alert(from frame: WKFrameInfo, saying message: String) -> NSAlert {
        let alert = NSAlert()
        // The site's name as the title, so a page can't dress its message up
        // as one from the system or from the browser.
        let host = frame.securityOrigin.host
        alert.messageText = host.isEmpty ? L("This page says") : host
        alert.informativeText = message
        alert.alertStyle = .informational
        return alert
    }

    /// The window the page is in, or the browser's window for a tab that
    /// isn't on stage right now.
    static func window(for webView: WKWebView) -> NSWindow? {
        webView.window ?? NSApp.mainWindow ?? NSApp.windows.first { $0.contentView != nil && $0.isVisible }
    }

    static func show(
        _ alert: NSAlert,
        over webView: WKWebView,
        then finish: @escaping (NSApplication.ModalResponse) -> Void
    ) {
        if let window = window(for: webView) {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }

    /// Where a self-signed certificate is an ordinary thing to meet.
    static func isLocal(_ host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".local") || host.hasSuffix(".localhost") { return true }
        if host == "127.0.0.1" || host == "::1" || host == "0.0.0.0" { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        if parts[0] == 10 { return true }
        if parts[0] == 192, parts[1] == 168 { return true }
        if parts[0] == 172, (16...31).contains(parts[1]) { return true }
        return false
    }
}
