import AppKit
import WebKit

// The questions a page is allowed to ask, and the answers it gets.
//
// WebKit does nothing with alert(), confirm(), prompt(), a file input or a
// password-protected site unless somebody answers for them — and "nothing"
// means confirm() is always false, so "leave without saving?" leaves, and a
// file picker that never opens. Each one here is the system's own sheet on the
// window the page is in, which is what every other browser on this Mac shows.

/// A question held for a tab in the background. WebKit wants every one of
/// them answered; one let go without being shown answers as dismissed.
@MainActor
final class HeldQuestion {
    private let show: () -> Void
    private var drop: (() -> Void)?

    init(show: @escaping () -> Void, drop: @escaping () -> Void) {
        self.show = show
        self.drop = drop
    }

    func present() {
        drop = nil
        show()
    }

    func dismiss() {
        let drop = drop
        self.drop = nil
        drop?()
    }

    deinit { drop?() }
}

extension Browser {
    // MARK: - alert, confirm, prompt

    /// A page's question goes over its own page only. One from a tab in the
    /// background — or in another space — waits until you go to that tab, as
    /// in Safari and Chrome: over the tab in front, a prompt() asking for a
    /// password would pass for that page's. A tab closed first gets the
    /// answer a dismissed dialog gives.
    func ask(from webView: WKWebView, show: @escaping () -> Void, drop: @escaping () -> Void) {
        let known = tabs + parkedTabs
        // Questions from tabs that have gone some other way than close(_:).
        for id in heldDialogs.keys where !known.contains(where: { $0.id == id }) {
            heldDialogs.removeValue(forKey: id)?.forEach { $0.dismiss() }
        }
        guard let tab = known.first(where: { $0.built === webView }), tab.id != activeID else {
            show()
            return
        }
        heldDialogs[tab.id, default: []].append(HeldQuestion(show: show, drop: drop))
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        ask(from: webView, show: {
            let alert = Dialogs.alert(from: frame, saying: message)
            alert.addButton(withTitle: "OK")
            Dialogs.show(alert, over: webView) { _ in completionHandler() }
        }, drop: completionHandler)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        ask(from: webView, show: {
            let alert = Dialogs.alert(from: frame, saying: message)
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")
            Dialogs.show(alert, over: webView) { answer in
                completionHandler(answer == .alertFirstButtonReturn)
            }
        }, drop: { completionHandler(false) })
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        ask(from: webView, show: {
            let alert = Dialogs.alert(from: frame, saying: prompt)
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")
            let field = NSTextField(string: defaultText ?? "")
            field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
            alert.accessoryView = field
            alert.window.initialFirstResponder = field
            Dialogs.show(alert, over: webView) { answer in
                completionHandler(answer == .alertFirstButtonReturn ? field.stringValue : nil)
            }
        }, drop: { completionHandler(nil) })
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
    /// it holds up. When it doesn't: this Mac itself — localhost and its
    /// loopback addresses, which nothing on the network can stand in for —
    /// is taken on trust; anything else, a .local name or a private address
    /// on the same Wi-Fi included, is asked about, once per site per launch,
    /// and only for the page itself, never for something a page pulled in.
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
        if Dialogs.isLoopback(host) || Dialogs.excused.contains(host) {
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
        // Over its own tab only, as a page's own questions are (see ask).
        ask(from: webView, show: {
            let alert = NSAlert()
            alert.messageText = "\(host) can't prove who it is"
            alert.informativeText = "Its certificate isn't trusted by this Mac. Someone could be reading what you send. Continue only if you know why it looks like this."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Go Back")
            alert.addButton(withTitle: "Continue Anyway")
            Dialogs.show(alert, over: webView) { answer in
                guard answer == .alertSecondButtonReturn else {
                    completionHandler(.cancelAuthenticationChallenge, nil)
                    return
                }
                Dialogs.excused.insert(host)
                completionHandler(.useCredential, URLCredential(trust: trust))
            }
        }, drop: { completionHandler(.cancelAuthenticationChallenge, nil) })
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
        // A tab behind yours asking for a name and a password would put the
        // question over the page you are looking at, where it would pass for
        // that page's. It waits for its own tab, as a page's questions do.
        ask(from: webView, show: { [weak self] in
            self?.askSignIn(webView, challenge, completionHandler)
        }, drop: { completionHandler(.cancelAuthenticationChallenge, nil) })
    }

    private func askSignIn(
        _ webView: WKWebView,
        _ challenge: URLAuthenticationChallenge,
        _ completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let space = challenge.protectionSpace
        let alert = NSAlert()
        alert.messageText = "\(space.host) asks you to sign in"
        alert.informativeText = space.realm.map { "“\($0)”" } ?? "The site wants a name and a password."
        if challenge.previousFailureCount > 0 {
            alert.informativeText += "\nThat wasn't accepted — try again."
        }
        alert.addButton(withTitle: "Sign In")
        alert.addButton(withTitle: "Cancel")

        let box = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 56))
        let name = NSTextField(frame: NSRect(x: 0, y: 32, width: 260, height: 24))
        name.placeholderString = "Name"
        let pass = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        pass.placeholderString = "Password"
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
        alert.messageText = host.isEmpty ? "This page says" : host
        alert.informativeText = message
        alert.alertStyle = .informational
        return alert
    }

    /// The window the page is in, or the browser's window for a tab that
    /// isn't on stage right now.
    static func window(for webView: WKWebView) -> NSWindow? {
        webView.window ?? NSApp.mainWindow ?? NSApp.windows.first { $0.contentView != nil && $0.isVisible }
    }

    /// A test run's questions, in the order they would have been shown.
    static var askedInTest: [String] = []

    static func show(
        _ alert: NSAlert,
        over webView: WKWebView,
        then finish: @escaping (NSApplication.ModalResponse) -> Void
    ) {
        // A test run never shows one — a sheet, or a window of its own for a
        // page without one, would be on the screen of whoever is working
        // beside it. What it would have asked is written down (bench probe),
        // and it is answered as if cancelled.
        if Store.testing {
            askedInTest.append(alert.messageText)
            finish(.cancel)
            return
        }
        if let window = window(for: webView) {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }

    /// This Mac itself: a certificate here can only have been made here.
    /// Only the names that can't mean anything else: localhost, and the
    /// loopback addresses written as addresses — four numbers and nothing
    /// more, so 127.0.0.1.example.com is a website like any other.
    static func isLoopback(_ host: String) -> Bool {
        if host == "localhost" || host == "::1" || host == "[::1]" { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({ UInt8($0) != nil }) else { return false }
        return parts[0] == "127"
    }
}
