import WebKit

/// The source of an extension return cannot be inferred from WKWebView.url:
/// during a server redirect that property already contains the destination.
/// Keep native navigation provenance for a redirect from a still-blank tab.
@MainActor
final class ExtensionReturnNavigation {
    private var navigation: WKNavigation?
    private var serverOrigin: URL?
    private var candidate: URL?
    /// The http(s) site the page was last sent to, for a rule's redirect.
    private var requested: URL?
    private(set) var revision = 0

    /// An extension's declarativeNetRequest rule sent the page from a site
    /// to one of its files: WebKit drops the site's navigation and starts
    /// one to the file, with no page behind it to name the site. The site
    /// is the one this tab was just asked to go to, read before anything
    /// else is decided — once, and only for WebKit's own rule redirect
    /// (see Browser.routeRuleRedirect).
    func ruleSource(for action: WKNavigationAction) -> URL? {
        defer { requested = nil }
        guard action.targetFrame?.isMainFrame == true else { return nil }
        return requested
    }

    /// Returns the document's native HTTPS origin for ordinary navigations.
    /// An opaque blank document needs a subsequent server-redirect callback.
    func source(for action: WKNavigationAction) -> URL? {
        guard action.targetFrame?.isMainFrame == true else { return nil }
        revision &+= 1
        candidate = nil
        requested = Self.webOrigin(action.request.url)
        guard action.sourceFrame.isMainFrame,
              (action.request.httpMethod ?? "GET") == "GET",
              action.request.httpBody == nil, action.request.httpBodyStream == nil
        else { return nil }

        let origin = action.sourceFrame.securityOrigin
        if origin.protocol.lowercased() == "https", !origin.host.isEmpty {
            var source = URLComponents()
            source.scheme = "https"
            source.host = origin.host
            source.path = "/"
            if origin.port > 0 { source.port = origin.port }
            return source.url
        }

        let document = action.sourceFrame.request.url
        if origin.protocol.isEmpty, origin.host.isEmpty,
           document == nil || document?.absoluteString == "about:blank",
           let target = action.request.url,
           ["chrome-extension", "webkit-extension"].contains(target.scheme?.lowercased() ?? "") {
            candidate = target
        }
        return nil
    }

    func started(_ navigation: WKNavigation, at url: URL?) {
        self.navigation = navigation
        serverOrigin = Self.httpsOrigin(url)
        candidate = nil
    }

    /// Called only by WebKit's main-frame server-redirect delegate, for the
    /// same provisional navigation. Never infer a redirect from an error,
    /// a Referer header, the address bar, or a previously visited page.
    func redirected(_ navigation: WKNavigation, to url: URL?) -> (target: URL, source: URL)? {
        guard self.navigation === navigation else { return nil }
        let source = serverOrigin
        serverOrigin = Self.httpsOrigin(url)
        defer { candidate = nil }
        guard let url, candidate == url, let source else { return nil }
        return (url, source)
    }

    func finished(_ navigation: WKNavigation?) {
        guard self.navigation === navigation else { return }
        self.navigation = nil
        serverOrigin = nil
        candidate = nil
    }

    /// An http or https site's origin, for ruleSource only.
    private static func webOrigin(_ url: URL?) -> URL? {
        guard let url, let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
        var origin = URLComponents()
        origin.scheme = scheme
        origin.host = host
        origin.port = url.port
        origin.path = "/"
        return origin.url
    }

    private static func httpsOrigin(_ url: URL?) -> URL? {
        guard let url, url.scheme?.lowercased() == "https", let host = url.host,
              url.user == nil, url.password == nil else { return nil }
        var origin = URLComponents()
        origin.scheme = "https"
        origin.host = host
        origin.port = url.port
        origin.path = "/"
        return origin.url
    }
}
