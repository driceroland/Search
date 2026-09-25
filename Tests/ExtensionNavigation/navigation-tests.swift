import AppKit
import WebKit

/// Native WebKit integration fixture. Uses an ephemeral extension and only
/// synthetic callback data; never opens the user's profile or NordPass.
@MainActor
final class NavigationTests: NSObject, WKNavigationDelegate {
    private var view: WKWebView!
    private var controller: WKWebExtensionController!
    private var context: WKWebExtensionContext!
    private var provenance = ExtensionReturnNavigation()
    private var handovers = 0
    private let expected = CommandLine.arguments[3] == "allow"
    private let baseline = CommandLine.arguments[3] == "baseline"

    func start() async {
        do {
            WKWebExtension.MatchPattern.registerCustomURLScheme("chrome-extension")
            let configuration = WKWebExtensionController.Configuration.nonPersistent()
            configuration.defaultWebsiteDataStore = .nonPersistent()
            controller = WKWebExtensionController(configuration: configuration)
            let resource = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            let extensionBundle = try await WKWebExtension(resourceBaseURL: resource)
            context = WKWebExtensionContext(for: extensionBundle)
            context.baseURL = URL(string: "chrome-extension://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/")!
            try controller.load(context)
            let web = WKWebViewConfiguration()
            web.websiteDataStore = configuration.defaultWebsiteDataStore
            web.webExtensionController = controller
            load(URL(string: CommandLine.arguments[2])!, configuration: web)
        } catch { complete(false, "fixture setup failed: \(error)") }
    }

    private func load(_ url: URL, configuration: WKWebViewConfiguration) {
        provenance = ExtensionReturnNavigation()
        view = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        view.navigationDelegate = self
        view.load(URLRequest(url: url))
    }

    private func handOver(_ target: URL, source: URL, from oldView: WKWebView) -> Bool {
        guard !baseline, ExtensionRedirectPolicy.allows(target: target, sourceOrigin: source, manifest: context.webExtension.manifest),
              let configuration = context.webViewConfiguration else { return false }
        let revision = provenance.revision
        DispatchQueue.main.async { [self] in
            guard view === oldView, provenance.revision == revision else { return }
            handovers += 1
            oldView.stopLoading()
            load(target, configuration: configuration)
        }
        return true
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let source = provenance.source(for: action)
        if let target = action.request.url, target.scheme == "chrome-extension", let source,
           handOver(target, source: source, from: webView) {
            decisionHandler(.cancel)
        } else { decisionHandler(.allow) }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        provenance.started(navigation, at: webView.url)
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        if let redirect = provenance.redirected(navigation, to: webView.url),
           handOver(redirect.target, source: redirect.source, from: webView) {
            webView.stopLoading()
        }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        provenance.finished(navigation)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView.url?.scheme == "chrome-extension" else { return }
        let target = "chrome-extension://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/callback.html?code=TEST-ONLY#state=TEST-ONLY"
        complete(expected && handovers == 1 && webView.url?.absoluteString == target,
                 "extension callback loaded; handovers=\(handovers); callback preserved=\(webView.url?.absoluteString == target)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail(webView, navigation, error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fail(webView, navigation, error) }
    private func fail(_ webView: WKWebView, _ navigation: WKNavigation?, _ error: Error) {
        guard view === webView else { return }
        provenance.finished(navigation)
        let error = error as NSError
        if error.code == NSURLErrorCancelled { return }
        let refused = error.domain == NSURLErrorDomain && [NSURLErrorResourceUnavailable, NSURLErrorNoPermissionsToReadFile].contains(error.code)
        let reproduced = !baseline || error.code == NSURLErrorResourceUnavailable
        complete(!expected && handovers == 0 && refused && reproduced,
                 "navigation refused: \(error.domain), \(error.code); handovers=\(handovers)")
    }

    // Only this loopback fixture accepts its temporary self-signed certificate.
    // Production Browser certificate handling is never changed.
    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if ["127.0.0.1", "localhost"].contains(challenge.protectionSpace.host),
           challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else { completionHandler(.performDefaultHandling, nil) }
    }

    private func complete(_ passed: Bool, _ detail: String) -> Never {
        print("\(passed ? "PASS" : "FAIL") \(detail)")
        exit(passed ? 0 : 1)
    }
}

@main
struct Runner {
    @MainActor static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        let tests = NavigationTests()
        Task { await tests.start() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { print("FAIL fixture timed out"); exit(2) }
        application.run()
    }
}
