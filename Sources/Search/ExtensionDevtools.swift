import AppKit
import Combine
import WebKit

// WebKit supplies the installed extension's ordinary APIs. Search adds
// chrome.devtools only to its devtools page and the panel frames it creates.
// Keeping the panel in a frame gives onShown the actual panel window.

/// A panel an extension's devtools page made with panels.create.
struct ExtensionPanelItem: Identifiable, Equatable {
    let id: String
    let extensionID: String
    let title: String
    /// As the extension gave them, relative to its folder.
    let icon: String
    let page: String
}

/// The extension panels, in the order they were made: after the built-in
/// ones in the panel strip.
struct ExtensionPanelRegistry: Equatable {
    /// Each extension's at most: a page asking in a loop fills no strip.
    static let limit = 8
    private(set) var items: [ExtensionPanelItem] = []
    private var made = 0

    /// Nil for a page that isn't one of the extension's own files, or past
    /// the limit.
    mutating func add(extensionID: String, title: String, icon: String, page: String) -> ExtensionPanelItem? {
        guard ExtensionDevtools.ownPage(page) != nil,
              items.filter({ $0.extensionID == extensionID }).count < Self.limit else { return nil }
        made += 1
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let item = ExtensionPanelItem(id: "\(extensionID):\(made)", extensionID: extensionID,
                                      title: name.isEmpty ? "Panel" : String(name.prefix(40)), icon: icon, page: page)
        items.append(item)
        return item
    }

    mutating func remove(extensionID: String) {
        items.removeAll { $0.extensionID == extensionID }
    }

    func item(_ id: String?) -> ExtensionPanelItem? {
        guard let id else { return nil }
        return items.first { $0.id == id }
    }
}

enum ExtensionDevtools {
    /// The blank page a devtools page's view loads first (see the top).
    static let probeFile = "search-devtools.html"
    static let probePage = "<!doctype html><meta charset=\"utf-8\"><title></title>\n"

    /// The manifest's `devtools_page`, when it names an HTML file inside the
    /// extension: relative, without "." or ".." parts.
    static func page(in manifest: [String: Any]) -> String? {
        guard let raw = manifest["devtools_page"] as? String else { return nil }
        return ownPage(raw)
    }

    /// A page of the extension's own, as a path inside its folder, query and
    /// fragment left as given. Nil for an address elsewhere.
    static func ownPage(_ raw: String) -> String? {
        let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, !path.hasPrefix("//") else { return nil }
        let file = String(path.prefix { $0 != "?" && $0 != "#" })
        guard let normalized = ExtensionDevtools.normalized(file),
              ["html", "htm"].contains((normalized as NSString).pathExtension.lowercased()) else { return nil }
        return normalized + String(path.dropFirst(file.count))
    }

    /// A path inside the folder: decoded, no empty, "." or ".." part, no NUL
    /// or backslash (as ExtensionPageScript.normalized, which needs 15.4).
    static func normalized(_ path: String) -> String? {
        guard let decoded = path.removingPercentEncoding else { return nil }
        var parts = decoded.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if parts.first == "" { parts.removeFirst() }
        guard !parts.isEmpty, !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0.contains(where: { "\0\\:?#".contains($0) }) })
        else { return nil }
        return parts.joined(separator: "/")
    }

    static func failure(_ message: String) -> [Any] {
        [NSNull(), ["isError": true, "code": "E_FAILED", "description": message, "details": [] as [Any]] as [String: Any]]
    }

    static func reply(error: Error) -> [Any] {
        if let message = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String {
            return [NSNull(), ["isException": true, "value": String(message.prefix(8_192))] as [String: Any]]
        }
        return failure(error.localizedDescription)
    }

    /// WebKit doesn't expose the numeric tab ID to its native delegate.
    /// Read it through the extension's own tabs API and match its position.
    static let probeScript = """
    const tabs = chrome.tabs, windows = chrome.windows;
    const query = Object.getPrototypeOf(tabs).query || tabs.query;
    const [all, open] = await Promise.all([
      query.call(tabs, {}),
      windows && typeof windows.getAll === "function" ? Promise.resolve(windows.getAll()).catch(() => []) : [],
    ]);
    const frames = new Map((open || []).map((w) => [w.id, { left: w.left, top: w.top, width: w.width, height: w.height }]));
    return (all || []).map((t) => ({ id: t.id, i: t.index, w: frames.get(t.windowId) || null, u: t.url || t.pendingUrl || "" }));
    """
}

@available(macOS 15.4, *)
extension ExtensionDevtools {
    @MainActor
    static func run(_ api: String, _ args: [Any], context: WKWebExtensionContext, owner: Extensions) async throws -> Any? {
        guard let token = args.first as? String, let host = ExtensionDevtoolsHost.active(token),
              host.context === context, let panels = host.panels, let target = host.target(owner: owner) else {
            throw ExtensionShims.Unsupported(what: "DevTools is unavailable for this extension and inspected page.")
        }
        let rest = Array(args.dropFirst())
        switch api {
        case "devtools.inspectedWindow.eval":
            guard let expression = rest.first as? String, expression.utf8.count <= 131_072 else {
                return failure("Missing or oversized DevTools expression.")
            }
            let options = rest.dropFirst().first as? [String: Any] ?? [:]
            guard options.keys.allSatisfy({ $0 == "useContentScriptContext" }), options["useContentScriptContext"] as? Bool != true else {
                return failure("DevTools evaluation supports the inspected tab's main page world.")
            }
            return await evaluate(expression, host: host, target: target, owner: owner)
        case "devtools.inspectedWindow.reload":
            let options = rest.first as? [String: Any] ?? [:]
            guard options.keys.allSatisfy({ $0 == "ignoreCache" }) else {
                throw ExtensionShims.Unsupported(what: "DevTools reload supports only the ignoreCache option.")
            }
            if options["ignoreCache"] as? Bool == true { _ = target.web.reloadFromOrigin() }
            else { _ = target.web.reload() }
            return nil
        case "devtools.panels.create":
            guard rest.count == 3, let title = rest[0] as? String, let icon = rest[1] as? String,
                  let page = rest[2] as? String, let item = panels.add(from: host, title: title, icon: icon, page: page) else {
                throw ExtensionShims.Unsupported(what: "Could not add the panel. Select an HTML file from this extension and check the panel limit.")
            }
            return item.id
        case "devtools.panels.show":
            guard let id = rest.first as? String, panels.item(id)?.extensionID == host.extensionID else {
                throw ExtensionShims.Unsupported(what: "Unknown extension panel.")
            }
            panels.select(id)
            return nil
        default:
            throw ExtensionShims.Unsupported(what: "\(api) isn't supported.")
        }
    }

    @MainActor
    private static func evaluate(_ expression: String, host: ExtensionDevtoolsHost, target: ExtensionDevtoolsHost.Target,
                                 owner: Extensions) async -> [Any] {
        // The public evaluation defaults to a user gesture. Use the same
        // no-gesture entry point as ExtensionPageScript.
        let selector = NSSelectorFromString("_evaluateJavaScript:withSourceURL:inFrame:inContentWorld:withUserGesture:completionHandler:")
        guard target.web.responds(to: selector),
              let encoded = try? JSONEncoder().encode([target.address, expression]),
              let input = String(data: encoded, encoding: .utf8) else { return failure("DevTools evaluation is unavailable.") }
        let script = """
        (([address, source]) => {
          if (location.origin + location.pathname + location.search !== address) throw new Error('The inspected document changed.');
          return (0, eval)(source);
        })(\(input))
        """
        typealias Evaluate = @convention(c) (AnyObject, Selector, NSString, NSURL?, WKFrameInfo?, WKContentWorld, Bool,
                                             @escaping @convention(block) (Any?, Error?) -> Void) -> Void
        let call = unsafeBitCast(target.web.method(for: selector), to: Evaluate.self)
        let (value, error): (Any?, Error?) = await withCheckedContinuation { done in
            call(target.web, selector, script as NSString, nil, nil, .page, false) { value, error in
                done.resume(returning: (value, error))
            }
        }
        guard let current = host.target(owner: owner), current.web === target.web,
              current.generation == target.generation, current.address == target.address else {
            return failure("The inspected document changed.")
        }
        if let error { return reply(error: error) }
        let result = value ?? NSNull()
        guard JSONSerialization.isValidJSONObject([result]),
              let encoded = try? JSONSerialization.data(withJSONObject: [result]), encoded.count <= 1_048_576 else {
            return failure("DevTools evaluation must return a JSON value no larger than 1 MB.")
        }
        return [result, NSNull()]
    }

    @MainActor
    static func icon(_ path: String, for context: WKWebExtensionContext) -> NSImage? {
        let size = CGSize(width: 16, height: 16)
        if let relative = normalized(path),
           let file = ExtensionPageScript.file(relative, in: Extensions.folder(for: context.uniqueIdentifier)),
           let image = NSImage(contentsOf: file), image.isValid {
            image.size = size
            return image
        }
        return context.webExtension.icon(for: size)
    }
}

@available(macOS 15.4, *)
@MainActor
final class ExtensionDevtoolsHost: NSObject, WKNavigationDelegate {
    struct Target {
        let web: WKWebView
        let address: String
        let generation: UInt64
    }

    private static let activeHosts = NSMapTable<NSString, ExtensionDevtoolsHost>.strongToWeakObjects()
    static func active(_ token: String) -> ExtensionDevtoolsHost? { activeHosts.object(forKey: token as NSString) }

    let context: WKWebExtensionContext
    let web: WKWebView
    var extensionID: String { context.uniqueIdentifier }
    private(set) weak var panels: DeveloperExtensionPanels?
    private let token = UUID().uuidString
    private let page: URL
    private let probe: URL
    private let theme: String
    private weak var inspected: Tab?
    private weak var browser: Browser?
    private weak var inspectedWeb: WKWebView?
    private enum Phase { case probing, loading, ready, closed }
    private var phase = Phase.probing
    private var deadline: Task<Void, Never>?

    init?(context: WKWebExtensionContext, path: String, inspecting tab: Tab, browser: Browser,
          theme: String, panels: DeveloperExtensionPanels) {
        let filePath = String(path.prefix { $0 != "?" && $0 != "#" })
        guard ExtensionPageScript.file(filePath, in: Extensions.folder(for: context.uniqueIdentifier)) != nil,
              let page = ExtensionShims.page(path, in: context), page.user == nil, page.password == nil,
              let probe = ExtensionShims.page(ExtensionDevtools.probeFile, in: context),
              let configuration = context.webViewConfiguration,
              let preferences = configuration.preferences.copy() as? WKPreferences else { return nil }
        preferences.inactiveSchedulingPolicy = .none
        configuration.preferences = preferences
        self.context = context
        self.page = page
        self.probe = probe
        self.theme = theme
        self.inspected = tab
        self.browser = browser
        self.inspectedWeb = tab.built
        self.panels = panels
        web = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        super.init()
        web.navigationDelegate = self
    }

    static func authorized(context: WKWebExtensionContext, for tab: Tab, in browser: Browser, owner: Extensions) -> Target? {
        guard context.isLoaded, owner.contexts[context.uniqueIdentifier] === context,
              !tab.shy, tab.held == nil, browser.tabs.contains(where: { $0 === tab }), owner.seen(tab, for: context),
              let web = tab.built, let url = tab.committed, let address = ExtensionPageScript.pageAddress(url),
              web.url.flatMap(ExtensionPageScript.pageAddress) == address,
              context.hasAccess(to: url, in: owner.adapter(for: tab)), let site = SiteAccess.site(of: url) else { return nil }
        // The click grant is held in WebKit for the origin, while Search
        // tracks which tab was actually granted access.
        let access = owner.siteAccess(context.uniqueIdentifier)
        guard access.covers(site) || owner.clickGrants[context.uniqueIdentifier]?[tab.id]?.host == site else { return nil }
        return Target(web: web, address: address, generation: tab.documentGeneration)
    }

    func target(owner: Extensions) -> Target? {
        guard phase == .loading || phase == .ready,
              let inspected, let browser, let inspectedWeb,
              let target = Self.authorized(context: context, for: inspected, in: browser, owner: owner),
              target.web === inspectedWeb else { return nil }
        return target
    }

    func matches(_ context: WKWebExtensionContext, tab: Tab) -> Bool {
        phase != .closed && self.context === context && tab.built === inspectedWeb
    }

    func start() {
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            self?.close()
        }
        web.load(URLRequest(url: probe))
    }

    func show(_ panel: String) {
        call("globalThis.__searchDevtools?.show(id);", ["id": panel])
    }

    func hide() { call("globalThis.__searchDevtools?.hide();") }

    func navigated(_ url: String) { call("globalThis.__searchDevtools?.navigated(url);", ["url": url]) }

    private func call(_ source: String, _ arguments: [String: Any] = [:]) {
        guard phase == .ready else { return }
        web.callAsyncJavaScript(source, arguments: arguments, in: nil, in: .page, completionHandler: nil)
    }

    func close() {
        guard phase != .closed else { return }
        phase = .closed
        Self.activeHosts.removeObject(forKey: token as NSString)
        deadline?.cancel()
        deadline = nil
        web.navigationDelegate = nil
        web.stopLoading()
        web.removeFromSuperview()
        // Unloading the devtools page also closes its runtime ports.
        if let blank = URL(string: "about:blank") { web.load(URLRequest(url: blank)) }
        panels?.hostClosed(self)
    }

    private func findInspectedTab() {
        web.callAsyncJavaScript(ExtensionDevtools.probeScript, arguments: [:], in: nil, in: .page) { [weak self] result in
            guard let self, self.phase == .probing else { return }
            let owner = Extensions.shared
            guard case .success(let value) = result, let tabs = value as? [[String: Any]],
                  let inspected = self.inspected, let browser = self.browser,
                  Self.authorized(context: self.context, for: inspected, in: browser, owner: owner)?.web === self.inspectedWeb,
                  let found = tabs.first(where: { ExtensionShims.located($0, context: self.context, owner: owner) === inspected })?["id"] as? Int,
                  var parts = URLComponents(url: self.page, resolvingAgainstBaseURL: true) else { return self.close() }
            let fields = [URLQueryItem(name: "searchDevtools", value: self.token),
                          URLQueryItem(name: "searchDevtoolsTab", value: String(found)),
                          URLQueryItem(name: "searchDevtoolsTheme", value: self.theme)]
            parts.queryItems = (parts.queryItems ?? []).filter { item in !fields.contains { $0.name == item.name } } + fields
            guard let address = parts.url else { return self.close() }
            self.phase = .loading
            Self.activeHosts.setObject(self, forKey: self.token as NSString)
            self.web.load(URLRequest(url: address))
        }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard phase == .ready else { return }
        phase = .loading
        panels?.pageReloaded(self)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        switch phase {
        case .probing: findInspectedTab()
        case .loading:
            phase = .ready
            deadline?.cancel()
            deadline = nil
            if let selected = panels?.selectedItem, selected.extensionID == extensionID { show(selected.id) }
        case .ready, .closed: break
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if phase != .ready { close() }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { close() }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { close() }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let frame = navigationAction.targetFrame, let url = navigationAction.request.url,
              !navigationAction.shouldPerformDownload else { return decisionHandler(.cancel) }
        if !frame.isMainFrame {
            decisionHandler(url.scheme == page.scheme && url.host == page.host || url.absoluteString == "about:blank" ? .allow : .cancel)
            return
        }
        let allowed = phase == .probing ? probe : page
        decisionHandler(url.scheme == allowed.scheme && url.host == allowed.host && url.path == allowed.path ? .allow : .cancel)
    }
}

/// The extension pages and panels of one open DevTools session.
@MainActor
final class DeveloperExtensionPanels {
    private var registry = ExtensionPanelRegistry()
    private(set) var selected: String?
    private(set) var icons: [String: NSImage] = [:]
    var changed: (() -> Void)?
    // WebKit extensions are available starting in macOS 15.4.
    private var hosts: [String: AnyObject] = [:]
    private var watch: AnyCancellable?
    private var permissionWatch: AnyCancellable?
    private weak var inspected: Tab?
    private weak var browser: Browser?
    private var theme = "default"

    var items: [ExtensionPanelItem] { registry.items }
    var selectedItem: ExtensionPanelItem? { registry.item(selected) }
    func item(_ id: String?) -> ExtensionPanelItem? { registry.item(id) }

    func start(inspecting tab: Tab, browser: Browser, theme: String) {
        stop()
        guard #available(macOS 15.4, *), !tab.shy else { return }
        self.inspected = tab
        self.browser = browser
        self.theme = theme
        watch = Extensions.shared.$contexts.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcile() }
        }
        let notices = [WKWebExtensionContext.permissionMatchPatternsWereGrantedNotification,
                       WKWebExtensionContext.permissionMatchPatternsWereDeniedNotification,
                       WKWebExtensionContext.grantedPermissionMatchPatternsWereRemovedNotification,
                       WKWebExtensionContext.deniedPermissionMatchPatternsWereRemovedNotification]
        permissionWatch = Publishers.MergeMany(notices.map { NotificationCenter.default.publisher(for: $0) })
            .receive(on: DispatchQueue.main).sink { [weak self] _ in
                MainActor.assumeIsolated { self?.reconcile() }
            }
        reconcile()
    }

    func stop() {
        let hadPanels = !items.isEmpty
        watch = nil
        permissionWatch = nil
        inspected = nil
        browser = nil
        let all = Array(hosts.values)
        hosts = [:]
        registry = ExtensionPanelRegistry()
        icons = [:]
        selected = nil
        if #available(macOS 15.4, *) {
            for case let host as ExtensionDevtoolsHost in all { host.hide(); host.close() }
        }
        if hadPanels { changed?() }
    }

    func select(_ id: String?) {
        guard #available(macOS 15.4, *), selected != id else { return }
        let after = registry.item(id)
        if let id, after?.id != id { return }
        if let before = selectedItem, before.extensionID != after?.extensionID { host(before.extensionID)?.hide() }
        selected = id
        if let after { host(after.extensionID)?.show(after.id) }
        changed?()
    }

    func web(for item: ExtensionPanelItem) -> WKWebView? {
        guard #available(macOS 15.4, *), registry.item(item.id) == item,
              let host = host(item.extensionID), host.target(owner: Extensions.shared) != nil else { return nil }
        return host.web
    }

    func documentChanged() {
        guard #available(macOS 15.4, *) else { return }
        reconcile()
        guard let url = inspected?.committed else { return }
        for case let host as ExtensionDevtoolsHost in Array(hosts.values) { host.navigated(url.absoluteString) }
    }

    @available(macOS 15.4, *)
    private func reconcile() {
        guard let inspected, let browser else { return }
        let owner = Extensions.shared
        var eligible: [(String, WKWebExtensionContext, String)] = []
        for (id, context) in owner.contexts.sorted(by: { $0.key < $1.key }) {
            guard let path = ExtensionDevtools.page(in: context.webExtension.manifest),
                  ExtensionDevtoolsHost.authorized(context: context, for: inspected, in: browser, owner: owner) != nil else { continue }
            eligible.append((id, context, path))
        }
        for case let host as ExtensionDevtoolsHost in Array(hosts.values) {
            if !eligible.contains(where: { $0.0 == host.extensionID && host.matches($0.1, tab: inspected) }) { host.close() }
        }
        for (id, context, path) in eligible where hosts[id] == nil {
            guard let host = ExtensionDevtoolsHost(context: context, path: path, inspecting: inspected, browser: browser,
                                                   theme: theme, panels: self) else { continue }
            hosts[id] = host
            host.start()
        }
    }

    @available(macOS 15.4, *)
    private func host(_ id: String) -> ExtensionDevtoolsHost? { hosts[id] as? ExtensionDevtoolsHost }

    @available(macOS 15.4, *)
    func add(from host: ExtensionDevtoolsHost, title: String, icon: String, page: String) -> ExtensionPanelItem? {
        guard hosts[host.extensionID] === host, let own = ExtensionDevtools.ownPage(page),
              ExtensionShims.page(own, in: host.context) != nil,
              ExtensionPageScript.file(String(own.prefix { $0 != "?" && $0 != "#" }), in: Extensions.folder(for: host.extensionID)) != nil,
              let item = registry.add(extensionID: host.extensionID, title: title, icon: icon, page: page) else { return nil }
        icons[item.id] = ExtensionDevtools.icon(icon, for: host.context)
        changed?()
        return item
    }

    @available(macOS 15.4, *)
    func hostClosed(_ host: ExtensionDevtoolsHost) {
        guard hosts[host.extensionID] === host else { return }
        hosts[host.extensionID] = nil
        forget(host.extensionID)
    }

    @available(macOS 15.4, *)
    func pageReloaded(_ host: ExtensionDevtoolsHost) {
        if hosts[host.extensionID] === host { forget(host.extensionID) }
    }

    private func forget(_ id: String) {
        let removed = items.filter { $0.extensionID == id }
        guard !removed.isEmpty else { return }
        if selectedItem?.extensionID == id { selected = nil }
        for item in removed { icons[item.id] = nil }
        registry.remove(extensionID: id)
        changed?()
    }
}

extension ExtensionDevtools {
    static let shim = #"""
    // Only the hosted devtools page receives a token. A panel frame uses
    // its parent's API and receives its own window in onShown.
    if (!worker && !inContent && !chrome.devtools && typeof window !== "undefined") {
      const devtools = (() => {
        try {
          if (window.parent !== window) return window.parent.__searchDevtools || null;
        } catch (_) { return null; }

        const keys = ["searchDevtools", "searchDevtoolsTab", "searchDevtoolsTheme"];
        let given;
        try {
          const params = new URLSearchParams(location.search);
          if (params.has(keys[0])) {
            given = { token: params.get(keys[0]), tabId: Number(params.get(keys[1])), theme: params.get(keys[2]) };
            for (const key of keys) params.delete(key);
            const search = params.toString();
            try { history.replaceState(history.state, "", location.pathname + (search ? "?" + search : "") + location.hash); } catch (_) {}
            try { sessionStorage.setItem("__searchDevtools", JSON.stringify(given)); } catch (_) {}
          } else {
            given = JSON.parse(sessionStorage.getItem("__searchDevtools") || "null");
          }
        } catch (_) {}
        if (!given || typeof given.token !== "string" || !Number.isInteger(given.tabId)) return null;

        const ask = (api, args) => native("devtools." + api, [given.token, ...args]);
        const fire = (ev, ...args) => {
          for (const listener of [...ev.listeners]) {
            try { listener(...args); } catch (error) { console.error(error); }
          }
        };
        const withCallback = (promise, callback) => {
          if (typeof callback !== "function") return promise;
          promise.then(callback, (error) => withLastError(error, () => callback(undefined)));
        };
        const unsupported = (name, callback) => withCallback(Promise.reject(new Error("chrome.devtools." + name + " is not supported by Search.")), callback);
        const failed = (error) => [null, { isError: true, code: "E_FAILED", description: String(error && error.message || error), details: [] }];

        const inspectedWindow = {
          tabId: given.tabId,
          eval(expression, options, callback) {
            if (typeof options === "function") { callback = options; options = undefined; }
            const response = ask("inspectedWindow.eval", [String(expression), options || {}])
              .then((reply) => Array.isArray(reply) ? reply : failed("No reply from the inspected page"), failed);
            if (typeof callback !== "function") return response.then(([value, info]) => {
              if (info) throw new Error(info.value || info.description);
              return value;
            });
            response.then(([value, info]) => callback(info ? undefined : value, info || undefined));
          },
          reload(options) { return ask("inspectedWindow.reload", [options || {}]); },
          getResources(callback) { return unsupported("inspectedWindow.getResources", callback); },
          onResourceAdded: event(),
          onResourceContentCommitted: event(),
        };
        const network = {
          onNavigated: event(),
          onRequestFinished: event(),
          getHAR(callback) { return unsupported("network.getHAR", callback); },
        };
        const made = new Map();
        let shown = null, waiting = null;
        const panels = {
          themeName: given.theme === "dark" ? "dark" : "default",
          elements: { onSelectionChanged: event() },
          sources: { onSelectionChanged: event() },
          create(title, iconPath, pagePath, callback) {
            const page = String(pagePath || "");
            const created = ask("panels.create", [String(title || ""), String(iconPath || ""), page]).then((id) => {
              const panel = {
                onShown: event(), onHidden: event(), onSearch: event(),
                createStatusBarButton() { throw new Error("DevTools status bar buttons are not supported by Search."); },
                show() { return ask("panels.show", [id]); },
              };
              made.set(id, { panel, page: page.replace(/^\//, ""), frame: null, loaded: false });
              return panel;
            });
            return withCallback(created.then((panel) => {
              if (waiting !== null && made.has(waiting)) setTimeout(() => { if (waiting !== null) hub.show(waiting); }, 0);
              return panel;
            }), callback);
          },
          openResource(url, line, column, callback) { return unsupported("panels.openResource", typeof column === "function" ? column : callback); },
        };
        const api = { inspectedWindow, panels, network };
        const hub = {
          api,
          show(id) {
            const entry = made.get(id);
            if (!entry) { waiting = id; return; }
            waiting = null;
            if (shown === id) return;
            if (shown !== null) hub.hide();
            shown = id;
            if (!entry.frame) {
              const frame = document.createElement("iframe");
              frame.referrerPolicy = "no-referrer";
              frame.style.cssText = "position:fixed;inset:0;width:100%;height:100%;border:0;z-index:2147483647;background:Canvas";
              frame.addEventListener("load", () => {
                entry.loaded = true;
                if (shown === id) fire(entry.panel.onShown, frame.contentWindow);
              });
              frame.src = runtime.getURL(entry.page);
              entry.frame = frame;
              (document.body || document.documentElement).appendChild(frame);
              return;
            }
            entry.frame.style.display = "block";
            if (entry.loaded) fire(entry.panel.onShown, entry.frame.contentWindow);
          },
          hide() {
            const entry = shown === null ? null : made.get(shown);
            shown = waiting = null;
            if (!entry) return;
            if (entry.frame) entry.frame.style.display = "none";
            if (entry.loaded) fire(entry.panel.onHidden);
          },
          navigated(url) { fire(network.onNavigated, String(url)); },
        };
        try { Object.defineProperty(root, "__searchDevtools", { value: hub }); } catch (_) {}
        return hub;
      })();
      if (devtools && devtools.api) {
        put(chrome, "devtools", devtools.api);
        if (root.browser && root.browser !== chrome && !root.browser.devtools) put(root.browser, "devtools", devtools.api);
      }
    }
    """#
}
