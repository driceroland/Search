import WebKit

/// A DOM owned by an extension, never a browser tab. Creation, discovery and
/// teardown use the same record, including while its first page is loading.
@available(macOS 15.4, *)
@MainActor
final class ExtensionOffscreen: NSObject, WKNavigationDelegate, WKWebExtensionTab {
    private static var documents: [String: ExtensionOffscreen] = [:]

    static func create(_ path: String, for context: WKWebExtensionContext) async throws {
        let id = context.uniqueIdentifier
        guard documents[id] == nil else {
            throw ExtensionShims.Unsupported(what: "Only a single offscreen document may be created.")
        }
        let base = context.baseURL
        guard let url = URL(string: path, relativeTo: base)?.absoluteURL,
              url.scheme == base.scheme, url.host == base.host, url.port == base.port,
              url.user == nil, url.password == nil,
              let configuration = context.webViewConfiguration,
              let preferences = configuration.preferences.copy() as? WKPreferences
        else { throw ExtensionShims.Unsupported(what: "The offscreen document must belong to this extension.") }

        // This page has no window by design. Let its DOM and message replies
        // keep working, with WebKit's background CPU throttling still in place.
        preferences.inactiveSchedulingPolicy = .throttle
        configuration.preferences = preferences
        let document = ExtensionOffscreen(context: context, url: url, configuration: configuration)
        // Reserve the slot before yielding, so simultaneous creates cannot
        // leave two pages alive for one extension.
        documents[id] = document
        // WebKit needs a tab adapter to identify content scripts in this
        // page's iframes. Only its owner knows it, and it is never inserted
        // into Browser.tabs or the window's list of visible tabs.
        context.didOpenTab(document)
        try await document.load()
    }

    static func close(for id: String) {
        documents[id]?.close(error: ExtensionShims.Unsupported(what: "The offscreen document was closed."))
    }

    static func hasDocument(for id: String) -> Bool { documents[id] != nil }

    static func send(_ message: Any, sender: [String: Any], token: String, for id: String) async throws -> Any {
        guard let document = documents[id], document.ready, !token.isEmpty, token.count <= 128,
              let frame = sender["frameId"] as? Int, frame > 0,
              let tab = sender["tab"] as? [String: Any],
              let tabID = document.tabID, tab["id"] as? Int == tabID,
              tab["url"] as? String == document.url.absoluteString else { return ["handled": false] }
        // A worker and several extension pages may hear the same relay.
        // They share one delivery and one reply, never repeat its side effects.
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any, Error>) in
            if var existing = document.deliveries[token] {
                if let reply = existing.reply { continuation.resume(with: reply) }
                else {
                    existing.waiters.append(continuation)
                    document.deliveries[token] = existing
                }
                return
            }
            document.deliveries[token] = Delivery(waiters: [continuation])
            // A callback with a weak owner lets close release the view and
            // reject all callers immediately, even if page code never replies.
            document.web.callAsyncJavaScript(
                "return await globalThis.__searchOffscreenDispatch(message, sender);",
                arguments: ["message": message, "sender": sender], in: nil, in: .page
            ) { [weak document] result in
                MainActor.assumeIsolated { document?.replied(to: token, with: result) }
            }
        }
    }

    static func contexts(for id: String, matching filter: [String: Any]) -> [[String: Any]] {
        guard let document = documents[id], document.ready else { return [] }
        let value = document.context
        let fields = ["contextIds": "contextId", "contextTypes": "contextType",
                      "documentIds": "documentId", "documentOrigins": "documentOrigin",
                      "documentUrls": "documentUrl", "frameIds": "frameId",
                      "tabIds": "tabId", "windowIds": "windowId"]
        for (plural, singular) in fields {
            guard let asked = filter[plural] else { continue }
            guard let choices = asked as? NSArray, let actual = value[singular], choices.contains(actual) else { return [] }
        }
        if let incognito = filter["incognito"] as? Bool, incognito { return [] }
        return [value]
    }

    private let extensionID: String
    private let extensionContext: WKWebExtensionContext
    private let url: URL
    private let contextID = UUID().uuidString
    private let documentID = UUID().uuidString
    private let web: WKWebView
    private var loading: CheckedContinuation<Void, Error>?
    private var deadline: Task<Void, Never>?
    private var closed = false
    private var ready = false
    private var tabID: Int?
    private struct Delivery {
        var reply: Result<Any, Error>?
        var waiters: [CheckedContinuation<Any, Error>]
    }
    private var deliveries: [String: Delivery] = [:]
    private var deliveryOrder: [String] = []

    private func replied(to token: String, with result: Result<Any, Error>) {
        guard let pending = deliveries[token], pending.reply == nil else { return }
        deliveries[token] = Delivery(reply: result, waiters: [])
        deliveryOrder.append(token)
        // Pending deliveries must stay indexed until settled; otherwise a
        // second relay could repeat their side effects while the first waits.
        if deliveryOrder.count > 128 { deliveries[deliveryOrder.removeFirst()] = nil }
        pending.waiters.forEach { $0.resume(with: result) }
    }

    private var context: [String: Any] {
        ["contextId": contextID, "contextType": "OFFSCREEN_DOCUMENT",
         "documentId": documentID, "documentUrl": url.absoluteString,
         "documentOrigin": "\(url.scheme ?? "")://\(url.host ?? "")\(url.port.map { ":\($0)" } ?? "")",
         "frameId": 0, "tabId": -1, "windowId": -1, "incognito": false]
    }

    private init(context: WKWebExtensionContext, url: URL, configuration: WKWebViewConfiguration) {
        extensionContext = context
        extensionID = context.uniqueIdentifier
        self.url = url
        web = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        super.init()
        web.navigationDelegate = self
    }

    private func load() async throws {
        try await withCheckedThrowingContinuation { continuation in
            loading = continuation
            deadline = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                self?.close(error: ExtensionShims.Unsupported(what: "The offscreen document did not finish loading."))
            }
            web.load(URLRequest(url: url))
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        deadline?.cancel()
        deadline = nil
        let continuation = loading
        loading = nil
        continuation?.resume(with: result)
    }

    private func close(error: Error) {
        guard !closed else { return }
        closed = true
        if Self.documents[extensionID] === self { Self.documents[extensionID] = nil }
        extensionContext.didCloseTab(self, windowIsClosing: false)
        web.navigationDelegate = nil
        web.stopLoading()
        let waiters = deliveries.values.flatMap(\.waiters)
        deliveries.removeAll()
        deliveryOrder.removeAll()
        waiters.forEach { $0.resume(throwing: error) }
        finish(.failure(error))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !closed, !ready else { return }
        // Use the native method: the popup compatibility shim deliberately
        // hides current tabs with no index. An ID distinguishes this page
        // from a visible tab at the same URL, and from a previous document.
        web.callAsyncJavaScript(
            "return (await Object.getPrototypeOf(chrome.tabs).getCurrent.call(chrome.tabs)).id;",
            in: nil, in: .page
        ) { [weak self] result in
            guard let self, !self.closed else { return }
            switch result {
            case .success(let value):
                guard let id = value as? Int else {
                    self.close(error: ExtensionShims.Unsupported(what: "The offscreen document has no page identifier."))
                    return
                }
                self.tabID = id
                self.ready = true
                self.finish(.success(()))
            case .failure(let error): self.close(error: error)
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        close(error: error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        close(error: error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        close(error: ExtensionShims.Unsupported(what: "The offscreen document's web process exited."))
    }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { nil }
    func indexInWindow(for context: WKWebExtensionContext) -> Int { NSNotFound }
    func webView(for context: WKWebExtensionContext) -> WKWebView? { web }
    func title(for context: WKWebExtensionContext) -> String? { web.title }
    func url(for context: WKWebExtensionContext) -> URL? { web.url }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !web.isLoading }
    func isSelected(for context: WKWebExtensionContext) -> Bool { false }
    func close(for context: WKWebExtensionContext) async throws { Self.close(for: extensionID) }
}
