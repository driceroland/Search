import WebKit

/// The source of an extension return cannot be inferred from WKWebView.url:
/// during a server redirect that property already contains the destination.
/// Keep native navigation provenance for a redirect from a still-blank tab.
@MainActor
final class ExtensionReturnNavigation {
    private var navigation: WKNavigation?
    private var serverOrigin: URL?
    private var candidate: URL?
    private(set) var revision = 0

    /// Returns the document's native HTTPS origin for ordinary navigations.
    /// An opaque blank document needs a subsequent server-redirect callback.
    func source(for action: WKNavigationAction) -> URL? {
        guard action.targetFrame?.isMainFrame == true else { return nil }
        revision &+= 1
        candidate = nil
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
