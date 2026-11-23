import CryptoKit
import SearchPluginAPI
import SwiftUI
import WebKit

// Developer tools packages: optional downloads beside Web Inspector, which
// stays Search's inspector (Settings › About › Developer). The signed feed
// lists them (build.sh write_devtools); each is a signed bundle with one
// principal class that speaks SearchPluginAPI.
//
// Nothing of a package runs until you use it:
//   - with nothing installed, there is no menu, no script and no cost:
//     every hook below returns at once while nothing is loaded;
//   - installed, its menu items come from what the feed said at install
//     (package.json beside it), and the package is loaded only when one of
//     them is first chosen, never at launch;
//   - loaded, it stays for the rest of the run: code can't be unloaded, so
//     removing it says to restart.
//
// What is downloaded is taken on trust only after checks, as the AI
// engine's is (AIEngine.trusted):
//   - the ZIP's size and SHA-256 are the signed feed's; it is unpacked in a
//     folder of its own inside Store.folder, checked there (one bundle, no
//     links), and only then moved into place in one rename, so a failure
//     leaves nothing half-installed;
//   - before every load: the executable's SHA-256 is the feed's, the bundle's
//     signature holds up, all of it, for Office Commun's Developer ID team
//     and the package's own identifier, and it was built for this Search's
//     API version. Search never asks for disable-library-validation: the
//     system refuses a library another team signed anyway.
// A debug build's tests can stand in a local feed and an ad-hoc signed
// package (`testing`); a release build never can.

struct DevToolsOffer: Equatable, Identifiable {
    struct Item: Equatable, Hashable {
        let id: String
        let title: String
    }

    let id: String
    let name: String
    let summary: String
    /// What it adds over Web Inspector, a few words each.
    let adds: [String]
    let version: Int
    let display: String
    let url: URL
    let sha256: String
    let size: Int64
    /// The SHA-256 of the bundle's executable, checked before every load.
    let binary: String
    let api: Int
    let menu: [Item]

    /// One entry of the feed's "devtools" list, every field checked.
    init?(json: [String: Any], link: (Any?) -> URL?) {
        func text(_ key: String, _ limit: Int) -> String? {
            guard let value = json[key] as? String, !value.isEmpty, value.count <= limit else { return nil }
            return value
        }
        func hash(_ key: String) -> String? {
            guard let value = (json[key] as? String)?.lowercased(), value.count == 64,
                  value.allSatisfy({ $0.isHexDigit }) else { return nil }
            return value
        }
        guard let id = text("id", 40), id.allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }),
              let name = text("name", 60), let summary = text("summary", 200),
              let version = (json["version"] as? Int) ?? Int(json["version"] as? String ?? ""), version > 0,
              let url = link(json["url"]), let sha256 = hash("sha256"), let binary = hash("binary"),
              let size = (json["size"] as? NSNumber)?.int64Value, size > 0, size < 64 << 20,
              let api = json["api"] as? Int,
              let menu = json["menu"] as? [[String: Any]], !menu.isEmpty, menu.count <= 12
        else { return nil }
        let items = menu.compactMap { item -> Item? in
            guard let id = item["id"] as? String, id.count <= 40, let title = item["title"] as? String, title.count <= 40 else { return nil }
            return Item(id: id, title: title)
        }
        guard items.count == menu.count else { return nil }
        self.id = id
        self.name = name
        self.summary = summary
        adds = ((json["adds"] as? [String]) ?? []).prefix(8).map { String($0.prefix(60)) }
        self.version = version
        display = text("display", 20) ?? String(version)
        self.url = url
        self.sha256 = sha256
        self.size = size
        self.binary = binary
        self.api = api
        self.menu = items
    }

    var json: [String: Any] {
        ["id": id, "name": name, "summary": summary, "adds": adds, "version": version, "display": display,
         "url": url.absoluteString, "sha256": sha256, "size": size, "binary": binary, "api": api,
         "menu": menu.map { ["id": $0.id, "title": $0.title] }]
    }

    var identifier: String { DevToolsPackages.identifierPrefix + id }
}

@MainActor
final class DevToolsPackages: ObservableObject {
    static let shared = DevToolsPackages()
    nonisolated static let identifierPrefix = "com.officecommun.search.devtools."

    enum State: Equatable {
        case idle
        case downloading(Double)
        case failed(String)
        /// Removed, but loaded earlier this run.
        case removedLoaded
        /// Updated, but the old one is loaded this run.
        case updatedLoaded
    }

    /// What the feed offers this Mac.
    @Published var offered: [DevToolsOffer] = []
    @Published private(set) var states: [String: State] = [:]
    /// Bumped when a package asks to be drawn again.
    @Published private(set) var revision = 0

    /// Which package View › Developer uses when there are two.
    var primaryID: String? {
        get { Store.settings.string(forKey: "devtools.primary") }
        set {
            objectWillChange.send()
            Store.settings.set(newValue, forKey: "devtools.primary")
            // The other package's tools put away: one package around the
            // page and on the keys at a time.
            let views = tabs.values.compactMap { $0.tab?.built }
            for (id, plugin) in loaded where id != primary?.offer.id {
                for web in views where plugin.isOpen(webView: web) { plugin.close(webView: web) }
            }
            for browser in Browsers.all { browser.objectWillChange.send() }
        }
    }

    /// A debug build's tests only: a local feed's addresses (file://) and
    /// ad-hoc signed packages.
    static var testing: Bool {
        #if DEBUG
        return Store.testing && !requireRelease
        #else
        return false
        #endif
    }

    /// A test asks for the release checks.
    nonisolated(unsafe) static var requireRelease = false

    static var folder: URL { Store.folder.appendingPathComponent("DevTools", isDirectory: true) }

    // MARK: - installed

    struct Installed {
        let offer: DevToolsOffer
        let bundle: URL
        var folder: URL { bundle.deletingLastPathComponent() }
    }

    private var scanned: [String: Installed]?

    /// What is installed: each package's newest version folder with its
    /// package.json. Read from disk once, the first time it's asked.
    var installed: [String: Installed] {
        if let scanned { return scanned }
        var found: [String: Installed] = [:]
        let files = FileManager.default
        for id in (try? files.contentsOfDirectory(atPath: Self.folder.path)) ?? [] where !id.hasPrefix(".") {
            let place = Self.folder.appendingPathComponent(id, isDirectory: true)
            let versions = ((try? files.contentsOfDirectory(atPath: place.path)) ?? []).compactMap(Int.init).sorted()
            guard let newest = versions.last else { continue }
            let version = place.appendingPathComponent(String(newest), isDirectory: true)
            guard let data = try? Data(contentsOf: version.appendingPathComponent("package.json")),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let offer = DevToolsOffer(json: json, link: { ($0 as? String).flatMap(URL.init(string:)) }),
                  offer.id == id, offer.version == newest,
                  let bundle = ((try? files.contentsOfDirectory(atPath: version.path)) ?? []).first(where: { $0.hasSuffix(".bundle") })
            else { continue }
            found[id] = Installed(offer: offer, bundle: version.appendingPathComponent(bundle, isDirectory: true))
        }
        scanned = found
        return found
    }

    private func rescan() {
        scanned = nil
        objectWillChange.send()
        // The View menu is drawn from the windows: they say it changed.
        for browser in Browsers.all { browser.objectWillChange.send() }
    }

    /// Every package to list: offered, installed, or both.
    var listed: [DevToolsOffer] {
        var all = offered
        for (id, kept) in installed.sorted(by: { $0.key < $1.key }) where !all.contains(where: { $0.id == id }) {
            all.append(kept.offer)
        }
        // Removed while loaded: still listed, to say restart.
        for (id, offer) in removed.sorted(by: { $0.key < $1.key }) where !all.contains(where: { $0.id == id }) {
            all.append(offer)
        }
        return all
    }

    /// The package View › Developer uses: the one installed, or the one
    /// picked of two.
    var primary: Installed? {
        let all = installed
        if let id = primaryID, let chosen = all[id] { return chosen }
        return all.values.sorted { $0.offer.id < $1.offer.id }.first
    }

    // MARK: - loaded

    private(set) var loaded: [String: SearchDevToolsPlugin] = [:]
    private var bridges: [String: DevToolsHostBridge] = [:]

    /// Nothing loaded is the usual case: every hook returns at once.
    static var idle: Bool { shared.loaded.isEmpty }

    enum Refused: LocalizedError, Equatable {
        case missing, hash, signature, searchTooOld, packageTooOld, notAPackage, layout

        var errorDescription: String? {
            switch self {
            case .missing: "The package's files are missing."
            case .hash: "The package isn't the one the feed lists."
            case .signature: "The package's signature doesn't hold up."
            case .searchTooOld: "This package needs a newer Search. Update Search."
            case .packageTooOld: "This package is too old for this Search. Update the package."
            case .notAPackage: "This isn't a developer tools package."
            case .layout: "The download isn't laid out as a package should be."
            }
        }
    }

    /// The bundle checked as it is on disk now (see the top of the file).
    nonisolated static func verify(_ bundle: URL, offer: DevToolsOffer, release: Bool) throws {
        let files = FileManager.default
        guard let info = NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")) as? [String: Any],
              let name = info["CFBundleExecutable"] as? String, !name.contains("/") else { throw Refused.missing }
        let executable = bundle.appendingPathComponent("Contents/MacOS/\(name)")
        guard let kind = try? executable.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              kind.isRegularFile == true, kind.isSymbolicLink != true, files.isReadableFile(atPath: executable.path)
        else { throw Refused.missing }
        guard try digest(executable) == offer.binary else { throw Refused.hash }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code else { throw Refused.signature }
        let requirement: SecRequirement?
        if release {
            requirement = Updater.developerID(team: Updater.team, identifier: offer.identifier)
        } else {
            var made: SecRequirement?
            SecRequirementCreateWithString("identifier \"\(offer.identifier)\"" as CFString, [], &made)
            requirement = made
        }
        let strict = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
        guard let requirement, SecStaticCodeCheckValidity(code, strict, requirement) == errSecSuccess else { throw Refused.signature }
        guard let api = info[SearchDevToolsAPI.infoKey] as? Int, api == offer.api else { throw Refused.notAPackage }
        if api > SearchDevToolsAPI.version { throw Refused.searchTooOld }
        if api < SearchDevToolsAPI.version { throw Refused.packageTooOld }
    }

    nonisolated static func digest(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var sha = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { sha.update(data: chunk) }
        return sha.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The package, loaded on first use after its checks; nil (and its row
    /// in Settings saying why) if they fail.
    func plugin(_ id: String) -> SearchDevToolsPlugin? {
        if let made = loaded[id] { return made }
        guard let kept = installed[id] else { return nil }
        do {
            try Self.verify(kept.bundle, offer: kept.offer, release: !Self.testing)
            guard let bundle = Bundle(url: kept.bundle), bundle.load(),
                  let kind = bundle.principalClass as? SearchDevToolsPlugin.Type else { throw Refused.notAPackage }
            guard kind.apiVersion == SearchDevToolsAPI.version else {
                throw kind.apiVersion > SearchDevToolsAPI.version ? Refused.searchTooOld : Refused.packageTooOld
            }
            let plugin = kind.init()
            let bridge = DevToolsHostBridge(id: id)
            bridges[id] = bridge
            loaded[id] = plugin
            plugin.start(host: bridge)
            return plugin
        } catch {
            states[id] = .failed(error.localizedDescription)
            return nil
        }
    }

    /// A menu item of the primary package, on the tab in front.
    func open(_ item: String, in browser: Browser) {
        guard let tab = browser.active, tab.isWeb, tab.page == nil, let web = tab.built,
              let id = primary?.offer.id, let plugin = plugin(id) else {
            if let id = primary?.offer.id, case .failed(let why) = states[id] { browser.announce(why) }
            return
        }
        remember(tab, web)
        plugin.open(item, webView: web)
    }

    /// Which tab a page view is, for the package's calls back.
    private struct Held { weak var tab: Tab? }
    private var tabs: [ObjectIdentifier: Held] = [:]

    private func remember(_ tab: Tab, _ web: WKWebView) {
        tabs[ObjectIdentifier(web)] = Held(tab: tab)
    }

    func tab(for web: WKWebView) -> Tab? {
        if let tab = tabs[ObjectIdentifier(web)]?.tab, tab.built === web { return tab }
        return Browsers.all.lazy.compactMap { $0.anyTab(for: web) }.first
    }

    var loadedPrimary: SearchDevToolsPlugin? {
        guard !loaded.isEmpty, let id = primary?.offer.id else { return nil }
        return loaded[id]
    }

    func invalidate() { revision += 1 }

    // MARK: - hooks (Search's side, each a no-op with nothing loaded)

    static func scripts(for tab: Tab) -> [WKUserScript] {
        guard !idle, let web = tab.built else { return [] }
        shared.remember(tab, web)
        return shared.loaded.values.flatMap { $0.scripts(webView: web) }
    }

    static func heard(_ response: URLResponse, for web: WKWebView) {
        guard !idle else { return }
        shared.loaded.values.forEach { $0.didReceiveResponse(response, webView: web) }
    }

    static func unload(_ web: WKWebView) {
        guard !idle else { return }
        shared.bridges.values.forEach { $0.awake.remove(ObjectIdentifier(web)) }
        shared.tabs[ObjectIdentifier(web)] = nil
        shared.loaded.values.forEach { $0.tabWillUnload(webView: web) }
    }

    static func busy(_ tab: Tab) -> Bool {
        guard !idle, let web = tab.built else { return false }
        return shared.loaded.values.contains { $0.isOpen(webView: web) }
            || shared.bridges.values.contains { $0.awake.contains(ObjectIdentifier(web)) }
    }

    /// Search's inspector keys a package that inspects takes while it is the
    /// one View › Developer uses: its menu item id, and Search's command for
    /// the key. Read from package.json: nothing is loaded for a menu.
    static let inspectorKeys = ["devtools": "view.inspector", "console": "view.console", "pick": "view.inspect"]

    var takenKeys: [String: String] {
        guard let package = primary, usable(package.offer.id) else { return [:] }
        return Self.inspectorKeys.filter { id, _ in package.offer.menu.contains { $0.id == id } }
    }

    /// ⌥⌘I, ⌥⌘J or ⌥⌘C, for the package that takes it: true if it did.
    func take(_ item: String, in browser: Browser) -> Bool {
        guard takenKeys[item] != nil else { return false }
        open(item, in: browser)
        return true
    }

    /// Inspect Element from a page's menu: the package that inspects, if it
    /// takes the keys, shows that element; otherwise Web Inspector does.
    static func inspect(at point: NSPoint, in web: WKWebView, browser: Browser) -> Bool {
        let packages = shared
        guard packages.takenKeys["devtools"] != nil, let tab = browser.anyTab(for: web), tab.isWeb,
              let id = packages.primary?.offer.id, let plugin = packages.plugin(id) else { return false }
        packages.remember(tab, web)
        return plugin.inspect(at: point, webView: web)
    }

    /// Web Inspector is about to open on this page: a package inspecting it
    /// lets go first, since a page has one inspector.
    static func yieldInspector(_ web: WKWebView) {
        guard !idle else { return }
        for (id, plugin) in shared.loaded where shared.installed[id]?.offer.menu.contains(where: { $0.id == "devtools" }) == true
            || shared.removed[id]?.menu.contains(where: { $0.id == "devtools" }) == true {
            if plugin.isOpen(webView: web) { plugin.close(webView: web) }
        }
    }

    static func keyDown(_ event: NSEvent, in browser: Browser) -> Bool {
        guard !idle, let plugin = shared.loadedPrimary, let web = browser.active?.built else { return false }
        return plugin.keyDown(event, webView: web)
    }

    // MARK: - installing

    private var installing: [String: Task<Void, Never>] = [:]
    private var removed: [String: DevToolsOffer] = [:]

    func install(_ id: String) {
        guard installing[id] == nil, let offer = offered.first(where: { $0.id == id }) else { return }
        guard offer.api == SearchDevToolsAPI.version else {
            states[id] = .failed(offer.api > SearchDevToolsAPI.version ? Refused.searchTooOld.errorDescription!
                                 : Refused.packageTooOld.errorDescription!)
            return
        }
        let wasLoaded = loaded[id] != nil
        states[id] = .downloading(0)
        installing[id] = Task { @MainActor in
            defer { installing[id] = nil }
            do {
                try await place(offer) { done in self.states[id] = .downloading(done) }
                rescan()
                states[id] = wasLoaded ? .updatedLoaded : .idle
            } catch where error is CancellationError || Task.isCancelled {
                states[id] = .idle
            } catch {
                states[id] = .failed(error.localizedDescription)
            }
        }
    }

    func cancel(_ id: String) { installing[id]?.cancel() }

    /// Downloaded, checked and moved into Store.folder/DevTools/<id>/<version>.
    private func place(_ offer: DevToolsOffer, progress: @escaping @MainActor (Double) -> Void) async throws {
        let files = FileManager.default
        try files.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        let staging = Self.folder.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: staging) }
        let zip = try await Self.download(offer, into: staging, progress: progress)
        let release = !Self.testing
        let out = staging.appendingPathComponent("out", isDirectory: true)
        try await Task.detached(priority: .utility) {
            try Self.unzip(zip, into: out)
            let found = try files.contentsOfDirectory(atPath: out.path).filter { !$0.hasPrefix(".") }
            guard found.count == 1, let name = found.first, name.hasSuffix(".bundle") else { throw Refused.layout }
            // Every file inside is a plain file or folder: no link that could
            // lead out of the package.
            if let walk = files.enumerator(at: out, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
                for case let file as URL in walk.allObjects where (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
                    throw Refused.layout
                }
            }
            try Self.verify(out.appendingPathComponent(name, isDirectory: true), offer: offer, release: release)
        }.value
        try JSONSerialization.data(withJSONObject: offer.json, options: [.sortedKeys])
            .write(to: out.appendingPathComponent("package.json"), options: .atomic)
        let home = Self.folder.appendingPathComponent(offer.id, isDirectory: true)
        try files.createDirectory(at: home, withIntermediateDirectories: true)
        let target = home.appendingPathComponent(String(offer.version), isDirectory: true)
        try? files.removeItem(at: target)
        try files.moveItem(at: out, to: target)
        for old in (try? files.contentsOfDirectory(atPath: home.path)) ?? [] where old != String(offer.version) {
            try? files.removeItem(at: home.appendingPathComponent(old))
        }
    }

    /// The ZIP, its size and SHA-256 the feed's. https only; a debug
    /// build's tests may use a file of their own.
    private static func download(_ offer: DevToolsOffer, into folder: URL,
                                 progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        let file = folder.appendingPathComponent("package.zip")
        let scheme = offer.url.scheme?.lowercased()
        if scheme == "file", testing {
            try FileManager.default.copyItem(at: offer.url, to: file)
        } else {
            guard scheme == "https" else { throw AIDownload.Failure("Not a secure address.") }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil
            configuration.urlCache = nil
            configuration.timeoutIntervalForRequest = 60
            ProxyNetwork.stamp(configuration)
            let session = URLSession(configuration: configuration)
            defer { session.finishTasksAndInvalidate() }
            let (temporary, response) = try await session.download(from: offer.url)
            guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false else {
                try? FileManager.default.removeItem(at: temporary)
                throw AIDownload.Failure("The download was refused.")
            }
            try FileManager.default.moveItem(at: temporary, to: file)
        }
        progress(0.9)
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? -1
        let hash = try await Task.detached(priority: .utility) { try digest(file) }.value
        guard size == offer.size, hash == offer.sha256 else {
            throw AIDownload.Failure("What arrived isn't what the feed lists, so it was deleted.")
        }
        return file
    }

    /// ditto, as the updater unpacks: links come out as links, and are
    /// refused after.
    nonisolated static func unzip(_ zip: URL, into folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, folder.path]
        ditto.standardOutput = FileHandle.nullDevice
        ditto.standardError = FileHandle.nullDevice
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else { throw Refused.layout }
    }

    /// Every file of the package goes. Loaded this run, it stays in memory
    /// until Search restarts, put back to doing nothing.
    func remove(_ id: String) {
        installing[id]?.cancel()
        if let plugin = loaded[id] {
            plugin.shutdown()
            states[id] = .removedLoaded
            removed[id] = installed[id]?.offer
        } else {
            states[id] = .idle
        }
        try? FileManager.default.removeItem(at: Self.folder.appendingPathComponent(id, isDirectory: true))
        // Its settings go too, from memory and from disk.
        let suite = DevToolsHostBridge.suite(id)
        bridges[id]?.defaults.removePersistentDomain(forName: suite)
        UserDefaults().removePersistentDomain(forName: suite)
        if primaryID == id { primaryID = nil }
        rescan()
    }

    /// A package loaded but removed or replaced: what's loaded stays out of
    /// the way until the restart.
    func usable(_ id: String) -> Bool {
        installed[id] != nil && states[id] != .removedLoaded && states[id] != .updatedLoaded
    }

    // MARK: - the feed

    /// The feed's "devtools" list, each entry checked; one per id.
    static func offers(from json: Any?, link: (Any?) -> URL?) -> [DevToolsOffer] {
        var seen = Set<String>()
        return ((json as? [[String: Any]]) ?? []).prefix(8).compactMap { DevToolsOffer(json: $0, link: link) }
            .filter { seen.insert($0.id).inserted }
    }
}

/// Search, as one package sees it.
@MainActor
final class DevToolsHostBridge: NSObject, SearchDevToolsHost {
    let id: String
    let isolatedWorld: WKContentWorld
    var awake = Set<ObjectIdentifier>()

    init(id: String) {
        self.id = id
        isolatedWorld = WKContentWorld.world(name: "Search Developer \(id)")
    }

    func ephemeralSession() -> URLSession {
        ProxyNetwork.kept("devtools-\(id)") {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.urlCache = nil
            configuration.urlCredentialStorage = nil
            configuration.timeoutIntervalForRequest = 10
            ProxyNetwork.stamp(configuration)
            return URLSession(configuration: configuration, delegate: DevToolsRedirects.shared, delegateQueue: nil)
        }
    }

    func keepAwake(_ on: Bool, webView: WKWebView) {
        if on { awake.insert(ObjectIdentifier(webView)) } else { awake.remove(ObjectIdentifier(webView)) }
    }

    func openURL(_ url: URL) {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        _ = Browsers.front?.open(url, foreground: true)
    }

    /// A store of the package's own, beside Search's settings and never in
    /// them; Remove deletes it.
    lazy var defaults: UserDefaults = UserDefaults(suiteName: Self.suite(id)) ?? UserDefaults()

    nonisolated static func suite(_ id: String) -> String {
        let base = Store.testing ? "com.officecommun.search.test.\(Store.world ?? "test")" : (Bundle.main.bundleIdentifier ?? "com.officecommun.search")
        return "\(base).devtools.\(id)"
    }

    func setting(forKey key: String) -> Any? { defaults.object(forKey: String(key.prefix(80))) }

    func setSetting(_ value: Any?, forKey key: String) {
        let key = String(key.prefix(80))
        guard let value, PropertyListSerialization.propertyList(value, isValidFor: .binary) else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(value, forKey: key)
    }

    func isPrivate(_ webView: WKWebView) -> Bool {
        tab(webView)?.shy ?? !webView.configuration.websiteDataStore.isPersistent
    }

    func rearm(_ webView: WKWebView) { tab(webView)?.rearm() }

    func invalidate() { DevToolsPackages.shared.invalidate() }

    private func tab(_ web: WKWebView) -> Tab? { DevToolsPackages.shared.tab(for: web) }
}

/// A package's own requests (source maps, robots.txt, a local dev server's
/// devtools.json): a redirect goes on only to http(s), and never carries the
/// Authorization header across.
final class DevToolsRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = DevToolsRedirects()

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(Self.follow(request))
    }

    static func follow(_ request: URLRequest) -> URLRequest? {
        guard let scheme = request.url?.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        var request = request
        request.setValue(nil, forHTTPHeaderField: "Authorization")
        request.setValue(nil, forHTTPHeaderField: "Cookie")
        return request
    }
}

// MARK: - Around the page

/// What a loaded package puts around the page: a bar over it, the page at a
/// device's size, a panel beside. Nothing loaded, the page as it was.
struct DevToolsStage: ViewModifier {
    @ObservedObject var browser: Browser
    @ObservedObject var packages = DevToolsPackages.shared

    func body(content: Content) -> some View {
        if let plugin = packages.loadedPrimary, let web = browser.active?.built {
            let _ = packages.revision
            let size = plugin.viewportSize(webView: web)?.sizeValue
            let dock = plugin.dockView(webView: web)
            let placement = dock == nil ? nil : plugin.dockPlacement(webView: web)
            let edge = placement?["edge"] as? String ?? "right"
            let length = CGFloat((placement?["size"] as? NSNumber)?.doubleValue ?? 360)
            GeometryReader { room in
                let across = edge == "bottom" ? room.size.height : room.size.width
                // The page keeps a strip it can be dragged back from.
                let docked = dock == nil ? 0 : min(max(length, 120), max(0, across - 80))
                let page = VStack(spacing: 0) {
                    if let bar = plugin.barView(webView: web) {
                        Hosted(view: bar).frame(height: 32)
                        Rectangle().fill(Palette.hairline).frame(height: 1)
                    }
                    GeometryReader { inner in
                        let zoom = web.pageZoom
                        let wanted = size.map { CGSize(width: min($0.width * zoom, inner.size.width), height: min($0.height * zoom, inner.size.height)) }
                        content
                            .frame(width: wanted?.width, height: wanted?.height)
                            .frame(width: inner.size.width, height: inner.size.height)
                    }
                    .background(size == nil ? .clear : Palette.frame)
                }
                Group {
                    if let dock {
                        let seam = DockSeam(vertical: edge == "bottom", sign: edge == "right" || edge == "bottom" ? -1 : 1,
                                            length: docked, resizable: placement != nil) { plugin.setDockSize($0, webView: web) }
                        switch edge {
                        case "bottom":
                            VStack(spacing: 0) { page; seam; Hosted(view: dock).frame(height: docked) }
                        case "left":
                            HStack(spacing: 0) { Hosted(view: dock).frame(width: docked); seam; page }
                        default:
                            HStack(spacing: 0) { page; seam; Hosted(view: dock).frame(width: docked) }
                        }
                    } else {
                        page
                    }
                }
                .frame(width: room.size.width, height: room.size.height)
            }
        } else {
            content
        }
    }

    private struct Hosted: NSViewRepresentable {
        let view: NSView
        func makeNSView(context: Context) -> NSView { view }
        func updateNSView(_ nsView: NSView, context: Context) {}
    }

    /// The line between the page and the panel; a package that places its
    /// panel can have it dragged, with the sidebar's grip.
    private struct DockSeam: View {
        let vertical: Bool
        /// Which way dragging grows the panel.
        let sign: CGFloat
        let length: CGFloat
        let resizable: Bool
        let resize: (Double) -> Void
        @State private var start: CGFloat?
        @State private var over = false

        var body: some View {
            Rectangle().fill(Palette.hairline)
                .frame(width: vertical ? nil : 1, height: vertical ? 1 : nil)
                .overlay {
                    if resizable {
                        Color.clear
                            .frame(width: vertical ? nil : 9, height: vertical ? 9 : nil)
                            .overlay { EdgeGrip(lit: over || start != nil).rotationEffect(.degrees(vertical ? 90 : 0)) }
                            .contentShape(Rectangle())
                            .onHover { inside in
                                over = inside
                                if inside { (vertical ? NSCursor.resizeUpDown : NSCursor.resizeLeftRight).push() } else { NSCursor.pop() }
                            }
                            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                                .onChanged { value in
                                    if start == nil { start = length }
                                    let moved = vertical ? value.translation.height : value.translation.width
                                    resize(Double((start ?? length) + sign * moved))
                                }
                                .onEnded { _ in start = nil })
                            .accessibilityLabel("Resize the developer tools")
                    }
                }
                .zIndex(1)
        }
    }
}

// MARK: - Settings › About › Developer

/// Each package the feed offers or that is installed: what it is, what it
/// adds over Web Inspector, its size and version, and what to do with it.
struct DevToolsPackageList: View {
    @ObservedObject var packages = DevToolsPackages.shared

    var body: some View {
        let listed = packages.listed
        let installed = packages.installed
        if listed.isEmpty {
            Rule()
            Line("No packages offered right now", "They come with the next check for updates") { EmptyView() }
        }
        ForEach(listed) { offer in
            Rule()
            row(offer, installed: installed[offer.id])
        }
        if installed.count > 1 {
            Rule()
            Line("View › Developer uses", "Its menu and keys") {
                Picker("", selection: Binding(get: { packages.primary?.offer.id ?? "" }, set: { packages.primaryID = $0 })) {
                    ForEach(installed.values.map(\.offer).sorted { $0.id < $1.id }) { Text($0.name).tag($0.id) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
        }
    }

    @ViewBuilder
    private func row(_ offer: DevToolsOffer, installed: DevToolsPackages.Installed?) -> some View {
        let fresh = packages.offered.first { $0.id == offer.id }
        let size = ByteCountFormatter.string(fromByteCount: (fresh ?? offer).size, countStyle: .file)
        let version = installed != nil ? "Installed" : "\(size) download"
        let adds = offer.adds.isEmpty ? "" : "\nAdds: " + offer.adds.joined(separator: ", ")
        switch packages.states[offer.id] ?? .idle {
        case .downloading(let done):
            Line(offer.name, "Downloading… \(Int(done * 100))%") { Pill("Cancel") { packages.cancel(offer.id) } }
        case .failed(let why):
            Line(offer.name, why) {
                HStack(spacing: 6) {
                    if fresh != nil { Pill("Try Again") { packages.install(offer.id) } }
                    if installed != nil { Pill("Remove") { packages.remove(offer.id) } }
                }
            }
        case .removedLoaded:
            Line(offer.name, "Removed. Restart Search to unload it.") { Pill("Restart") { Updater.shared.relaunch() } }
        case .updatedLoaded:
            Line(offer.name, "Updated. Restart Search to use the new version.") { Pill("Restart") { Updater.shared.relaunch() } }
        case .idle:
            Line(offer.name + (installed.map { " \($0.offer.display)" } ?? ""), "\(offer.summary)\(adds)\n\(version)") {
                HStack(spacing: 6) {
                    if let fresh, let installed, fresh.version > installed.offer.version {
                        Pill("Update", filled: true) { packages.install(offer.id) }
                    }
                    if installed != nil {
                        Pill("Remove") { packages.remove(offer.id) }
                    } else if fresh != nil {
                        Pill("Download", filled: true) { packages.install(offer.id) }
                    }
                }
            }
        }
    }
}
