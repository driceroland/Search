import Foundation
import WebKit

/// The Application panel's early script (DeveloperApplication-probe.js):
/// put into each page the inspected tab loads while DevTools is open, in
/// the page's own world ahead of its scripts, so that the Back/forward
/// cache view can count unload handlers and open sockets and the Reporting
/// API view has the reports a ReportingObserver saw. As the Recorder's
/// does, it goes back in as each navigation begins, since the tab puts its
/// own scripts back then (Tab.arm), and is run once in the page already up.
@MainActor
final class DeveloperApplicationProbe {
    static let shared = DeveloperApplicationProbe()
    static let script = DevToolsResources.script("DeveloperApplication-probe.js")
    static let key = "perch.devtools.application"

    private weak var web: WKWebView?
    private var userScript: WKUserScript?
    private var observation: NSKeyValueObservation?

    private static func source(early: Bool) -> String { "(\n" + script + "\n)(\(early));" }

    /// Follows the page DevTools inspects; a different page stops the last.
    func watch(_ web: WKWebView?) {
        if let web, web === self.web {
            ensure(web)
            return
        }
        stop()
        guard let web else { return }
        self.web = web
        userScript = WKUserScript(source: Self.source(early: true), injectionTime: .atDocumentStart,
                                  forMainFrameOnly: true, in: .page)
        ensure(web)
        runLate(in: web)
        observation = web.observe(\.isLoading, options: [.new]) { [weak self] web, _ in
            MainActor.assumeIsolated { self?.loadingChanged(web) }
        }
    }

    func stop() {
        observation?.invalidate()
        observation = nil
        if let script = userScript { ArmedRiders.remove(script) }
        if let web, let script = userScript { web.configuration.userContentController.developerRemove(script) }
        userScript = nil
        web = nil
    }

    private func ensure(_ web: WKWebView) {
        guard let script = userScript else { return }
        // Kept by Tab.arm at each navigation, as the tab's own scripts are:
        // a load or reload says it is loading before Tab.arm takes them out.
        web.configuration.userContentController.developerArm(script)
    }

    /// Already there, it does nothing; otherwise it starts now, marked late.
    private func runLate(in web: WKWebView) {
        web.evaluateJavaScript(Self.source(early: false), in: nil, in: .page, completionHandler: nil)
    }

    private func loadingChanged(_ web: WKWebView) {
        guard web === self.web else { return }
        guard DeveloperTools.shared.session?.web === web else {
            stop()
            return
        }
        if web.isLoading { ensure(web) } else { runLate(in: web) }
    }

    /// What the script has counted and collected so far, or nil when it is not in the page.
    static func snapshot(in web: WKWebView) async -> [String: Any]? {
        let source = """
            const probe = window[Symbol.for(key)];
            if (!probe || typeof probe.snapshot !== 'function') return null;
            try { return JSON.parse(JSON.stringify(probe.snapshot())); } catch { return null; }
            """
        return (try? await web.callAsyncJavaScript(source, arguments: ["key": key], in: nil, contentWorld: .page))
            as? [String: Any]
    }

    static func clearReports(in web: WKWebView) async {
        _ = try? await web.callAsyncJavaScript("window[Symbol.for(key)]?.clearReports?.(); return true;",
                                               arguments: ["key": key], in: nil, contentWorld: .page)
    }
}

/// Background services › Notifications' recording: hooks in the page's own
/// world (DeveloperApplicationScript-notifications.js), put in when
/// recording starts and taken out, the page's globals restored, when it
/// stops. The events are kept here, so they outlast the panel's views and
/// the page's navigations; a document loaded while recording is hooked too.
@MainActor
final class DeveloperNotificationRecorder: ObservableObject {
    static let shared = DeveloperNotificationRecorder()
    static let key = "perch.devtools.notifications"
    static let script = DevToolsResources.script("DeveloperApplicationScript-notifications.js")
    private static let limit = 5000

    @Published private(set) var recording = false
    @Published private(set) var events: [DeveloperNotificationEvent] = []
    /// False when the page has neither Notification nor ServiceWorkerRegistration.
    @Published private(set) var supported = true

    private weak var web: WKWebView?
    /// How many of the current document's events are already in `events`.
    private var taken = 0
    private var poll: Task<Void, Never>?

    func start(in web: WKWebView) async {
        if let old = self.web, old !== web, recording { await run("stop", in: old) }
        self.web = web
        recording = true
        taken = 0
        absorb(await run("start", in: web))
        poll?.cancel()
        poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                await self.sync()
            }
        }
    }

    func stop() async {
        poll?.cancel()
        poll = nil
        guard recording else { return }
        recording = false
        if let web { absorb(await run("stop", in: web)) }
        taken = 0
    }

    func clear() async {
        events = []
        if let web, recording { await run("clear", in: web) }
        taken = 0
    }

    /// Takes the page's new events; a document that has no hooks yet gets them.
    func sync() async {
        guard recording else { return }
        guard let web else {
            await stop()
            return
        }
        guard !web.isLoading else { return }
        let reply = await run("read", in: web)
        if let reply, reply["recording"] as? Bool != true {
            taken = 0
            absorb(await run("start", in: web))
        } else {
            absorb(reply)
        }
    }

    private func absorb(_ reply: [String: Any]?) {
        guard let reply else { return }
        if let supported = reply["supported"] as? Bool { self.supported = supported }
        let raw = reply["events"] as? [Any] ?? []
        if raw.count > taken {
            let fresh = DeveloperNotificationEvent.parse(Array(raw[taken...]), first: events.count)
            taken = raw.count
            events.append(contentsOf: fresh.prefix(max(0, Self.limit - events.count)))
        } else {
            taken = raw.count
        }
    }

    @discardableResult
    private func run(_ action: String, in web: WKWebView) async -> [String: Any]? {
        let source = "return (\n" + Self.script + "\n)(action, key);"
        return (try? await web.callAsyncJavaScript(source, arguments: ["action": action, "key": Self.key], in: nil,
                                                    contentWorld: .page)) as? [String: Any]
    }
}

/// The result of Chrome's "Test back/forward cache".
struct DeveloperBackForwardCacheOutcome: Equatable {
    let url: String
    let restored: Bool
    let signals: DeveloperBackForwardCacheSignals
    let reasons: [DeveloperBackForwardCacheReason]
    let caveats: [String]
    let date: Date
}

/// The Application panel's additions that act on the page beyond reading
/// it: the back/forward cache test, the frame view's owner element and
/// links, and extension storage.
@MainActor
enum DeveloperApplicationMore {
    enum Issue: LocalizedError {
        case pageChanged, couldNotLeave, couldNotReturn, unavailable, saveFailed
        case message(String)

        var errorDescription: String? {
            switch self {
            case .pageChanged: "Wait for the current website to finish loading, then try again."
            case .couldNotLeave: "Search could not navigate away from the page to test it."
            case .couldNotReturn: "Search could not come back to the page. Use Back to return to it."
            case .unavailable: "The inspected page could not provide this information."
            case .saveFailed: "The extension did not save the change."
            case .message(let text): text
            }
        }
    }

    private static let testKey = "perch.devtools.bfcacheTest"

    // MARK: Back/forward cache

    /// Leaves the page for a blank one and goes back, then asks the page
    /// whether it is the same document, restored from the cache: a token
    /// left in it survives only then, and its pageshow says persisted.
    static func testBackForwardCache(in session: DeveloperToolsSession, address: URL) async throws -> DeveloperBackForwardCacheOutcome {
        guard let web = session.web, web.url == address, !web.isLoading,
              DeveloperApplication.origin(of: address) != nil else { throw Issue.pageChanged }
        DeveloperApplicationProbe.shared.watch(web)
        let token = UUID().uuidString
        let marked = try? await web.callAsyncJavaScript("""
            const state = { token, persisted: null };
            globalThis[Symbol.for(key)] = state;
            addEventListener('pageshow', (event) => {
                if (event.isTrusted && globalThis[Symbol.for(key)] === state) state.persisted = event.persisted;
            }, true);
            return true;
            """, arguments: ["token": token, "key": testKey], in: nil, contentWorld: Web.world)
        guard marked as? Bool == true else { throw Issue.unavailable }

        let probe = await DeveloperApplicationProbe.snapshot(in: web)
        let page = (try? await web.callAsyncJavaScript("""
            let media = 0;
            try { media = Array.from(document.querySelectorAll('video, audio')).filter((m) => !m.paused && !m.ended).length; } catch {}
            return { onunload: typeof window.onunload === 'function', media, opener: !!window.opener };
            """, arguments: [:], in: nil, contentWorld: .page)) as? [String: Any]
        let document = await documentDetails(address.absoluteString, in: session)
        let signals = DeveloperBackForwardCacheSignals(probe: probe, page: page, document: document)

        guard session.web === web, web.url == address else { throw Issue.pageChanged }
        // Leave through a real navigation to the same address with a marker
        // query. about:blank and loadHTMLString don't serve: the tab treats a
        // view on about:blank as one that lost its page and loads the
        // address into it again, which drops the history the test goes
        // back through.
        var parts = URLComponents(url: address, resolvingAgainstBaseURL: false)
        let query = (parts?.queryItems ?? []) + [URLQueryItem(name: "perch-bfcache-test", value: token)]
        parts?.queryItems = query
        guard let away = parts?.url else { throw Issue.couldNotLeave }
        web.load(URLRequest(url: away))
        guard await wait(seconds: 8, until: { web.url == away && !web.isLoading }) else { throw Issue.couldNotLeave }
        guard web.canGoBack else { throw Issue.couldNotReturn }
        web.goBack()
        guard await wait(seconds: 12, until: { web.url == address && !web.isLoading }) else { throw Issue.couldNotReturn }
        let reply = (try? await web.callAsyncJavaScript("""
            const state = globalThis[Symbol.for(key)];
            return { same: !!state && state.token === token, persisted: state ? state.persisted : null };
            """, arguments: ["token": token, "key": testKey], in: nil, contentWorld: Web.world)) as? [String: Any]
        let restored = reply?["same"] as? Bool == true && reply?["persisted"] as? Bool != false
        return DeveloperBackForwardCacheOutcome(
            url: address.absoluteString, restored: restored, signals: signals,
            reasons: restored ? [] : DeveloperBackForwardCacheAdvisor.reasons(signals),
            caveats: restored ? [] : DeveloperBackForwardCacheAdvisor.caveats(signals), date: Date())
    }

    private static func wait(seconds: Double, until condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    // MARK: Network records

    /// The document's response as Network recorded it, when it did.
    static func documentDetails(_ url: String, in session: DeveloperToolsSession) async -> DeveloperRequestDetails? {
        guard let request = session.requests.last(where: { $0.url == url && $0.type == "Document" })
            ?? session.requests.last(where: { $0.url == url }) else { return nil }
        return await session.requestDetails(request.id)
    }

    /// Network, with the request for `url` selected. False when Network has none.
    @discardableResult
    static func revealInNetwork(_ url: String, in session: DeveloperToolsSession) -> Bool {
        guard let request = session.requests.last(where: { $0.url == url }) else { return false }
        let id = request.id
        session.select(.network)
        // The Network view may only now be appearing (as the Issues panel's link does).
        Task { @MainActor in
            NotificationCenter.default.post(name: DeveloperIssuesModel.revealRequestNotification, object: session,
                                            userInfo: ["id": id])
            try? await Task.sleep(for: .milliseconds(150))
            NotificationCenter.default.post(name: DeveloperIssuesModel.revealRequestNotification, object: session,
                                            userInfo: ["id": id])
        }
        return true
    }

    /// A frame resource: scripts, stylesheets and documents in Sources, the rest in Network.
    static func open(_ resource: DeveloperFrameNode.Resource, in session: DeveloperToolsSession) {
        if DeveloperFrameDetails.opensInSources(resource.type) || !revealInNetwork(resource.url, in: session) {
            session.revealSource(url: resource.url, line: 1)
        }
    }

    // MARK: Frames

    /// Reaches a frame's window by its index path from the top, as
    /// window.frames numbers subframes, and the element that holds it.
    private static let frameWalk = """
        let w = window, owner = null;
        for (const index of path) {
            const child = w.frames[index];
            if (!child) return null;
            owner = null;
            try {
                owner = Array.from(w.document.querySelectorAll('iframe, frame, object, embed'))
                    .find((element) => element.contentWindow === child) || null;
            } catch {}
            w = child;
        }
        """

    /// What the frame says of itself where Search may ask it: a cross-origin
    /// frame answers nothing, and its owner only while its parent is reachable.
    static func frameContext(path: [Int], in session: DeveloperToolsSession, address: URL) async -> DeveloperFrameDetails.Context {
        var context = DeveloperFrameDetails.Context()
        guard let web = session.web, web.url == address else { return context }
        let source = frameWalk + "\n" + """
            const describe = (element) => {
                if (!element) return null;
                let text = '<' + element.localName;
                for (const name of ['id', 'name', 'src', 'sandbox', 'allow']) {
                    const value = element.getAttribute(name);
                    if (value !== null) text += ' ' + name + '="' + value.slice(0, 160) + '"';
                }
                return text + '>';
            };
            const result = { owner: describe(owner), secure: null, isolated: null, features: null };
            try {
                result.secure = !!w.isSecureContext;
                result.isolated = !!w.crossOriginIsolated;
                const policy = w.document.featurePolicy || w.document.permissionsPolicy;
                if (policy && typeof policy.allowedFeatures === 'function') result.features = Array.from(policy.allowedFeatures()).map(String);
            } catch {}
            return result;
            """
        guard let reply = (try? await web.callAsyncJavaScript(source, arguments: ["path": path], in: nil,
                                                               contentWorld: Web.world)) as? [String: Any] else { return context }
        context.owner = reply["owner"] as? String
        context.secure = reply["secure"] as? Bool
        context.crossOriginIsolated = reply["isolated"] as? Bool
        context.allowedFeatures = reply["features"] as? [String]
        return context
    }

    /// Elements, with the frame's owner element selected. Entering Elements
    /// reads the document afresh, which renumbers WebKit's nodes, so the node
    /// is asked for once that is done (as the Issues panel's reveal does).
    static func revealOwner(path: [Int], in session: DeveloperToolsSession) {
        guard !path.isEmpty, let json = try? JSONSerialization.data(withJSONObject: path) else { return }
        let expression = "(() => { const path = \(String(decoding: json, as: UTF8.self)); "
            + frameWalk + "\n"
            + " return owner; })()"
        let switching = session.panel != .elements
        let before = session.root
        session.select(.elements)
        Task { @MainActor in
            for _ in 0..<40 where switching {
                guard session.root == before || session.root == nil else { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            let target = session.runtimeTargetID
            guard let reply = try? await session.command("Runtime.evaluate", [
                "expression": expression, "objectGroup": "perch-application",
                "doNotPauseOnExceptionsAndMuteConsole": true, "includeCommandLineAPI": false,
            ], targetID: target),
                let object = (reply["result"] as? [String: Any])?["objectId"] as? String else { return }
            let node = try? await session.command("DOM.requestNode", ["objectId": object], targetID: session.domTargetID)
            _ = try? await session.command("Runtime.releaseObject", ["objectId": object], targetID: target)
            guard let id = (node?["nodeId"] as? NSNumber)?.intValue, id > 0 else { return }
            for _ in 0..<40 where session.nodes[id] == nil {
                try? await Task.sleep(for: .milliseconds(50))
            }
            session.selectNode(id)
        }
    }

    // MARK: Extension storage

    struct ExtensionArea: Equatable {
        let name: String
        /// Key and JSON value pairs, or nil when the extension has no such area.
        let items: [[String]]?
        let problem: String?
    }

    /// chrome.storage.local, sync and session of the extension whose page
    /// is inspected, read through the page's own chrome.storage.
    static func extensionStorage(in session: DeveloperToolsSession, address: URL) async throws -> [ExtensionArea] {
        guard let web = session.web, web.url == address, !web.isLoading,
              DeveloperExtensionStorage.extensionID(of: address) != nil else { throw Issue.pageChanged }
        let reply = try? await web.callAsyncJavaScript("""
            if (location.href !== address) return { changed: true };
            const api = (globalThis.chrome && chrome.storage) || (globalThis.browser && browser.storage);
            if (!api) return { missing: true };
            const out = {};
            for (const area of areas) {
                const store = api[area];
                if (!store || typeof store.get !== 'function') { out[area] = { absent: true }; continue; }
                try {
                    const items = await store.get(null);
                    const keys = Object.keys(items || {}).sort();
                    out[area] = { items: keys.slice(0, 1000).map((name) => {
                        let text;
                        try { text = JSON.stringify(items[name]); } catch { text = String(items[name]); }
                        if (text === undefined) text = 'undefined';
                        return [name, text.length > 65536 ? text.slice(0, 65536) + '…' : text];
                    }), count: keys.length };
                } catch (error) {
                    out[area] = { error: String((error && error.message) || error) };
                }
            }
            return out;
            """, arguments: ["address": address.absoluteString, "areas": DeveloperExtensionStorage.areas],
            in: nil, contentWorld: .page)
        guard let result = reply as? [String: Any] else { throw Issue.unavailable }
        if result["changed"] as? Bool == true { throw Issue.pageChanged }
        if result["missing"] as? Bool == true {
            throw Issue.message("This extension page has no chrome.storage. Add the \"storage\" permission to its manifest.")
        }
        return DeveloperExtensionStorage.areas.map { name in
            let area = result[name] as? [String: Any]
            if area?["absent"] as? Bool == true { return ExtensionArea(name: name, items: nil, problem: "Not available") }
            if let error = area?["error"] as? String { return ExtensionArea(name: name, items: nil, problem: error) }
            return ExtensionArea(name: name, items: area?["items"] as? [[String]] ?? [], problem: nil)
        }
    }

    /// Sets a key to a value written as JSON (text that isn't JSON is kept
    /// as a string), renaming `previousKey` when it differs; or removes keys.
    static func writeExtensionStorage(area: String, set key: String?, value: String?, previousKey: String? = nil,
                                      remove keys: [String] = [], clear: Bool = false,
                                      in session: DeveloperToolsSession, address: URL) async throws {
        guard DeveloperExtensionStorage.areas.contains(area), let web = session.web, web.url == address,
              !web.isLoading else { throw Issue.pageChanged }
        let reply = try? await web.callAsyncJavaScript("""
            if (location.href !== address) return { changed: true };
            const api = (globalThis.chrome && chrome.storage) || (globalThis.browser && browser.storage);
            const store = api && api[area];
            if (!store) return { issue: 'unavailable' };
            try {
                if (clear) { await store.clear(); return { saved: true }; }
                if (key !== null) {
                    let parsed;
                    if (value === null) {
                        const old = await store.get(previousKey);
                        if (!(previousKey in old)) return { issue: 'stale' };
                        parsed = old[previousKey];
                    } else {
                        try { parsed = JSON.parse(value); } catch { parsed = value; }
                    }
                    await store.set({ [key]: parsed });
                    if (previousKey !== null && previousKey !== key) await store.remove(previousKey);
                }
                if (keys.length) await store.remove(keys);
                return { saved: true };
            } catch (error) {
                return { issue: String((error && error.message) || error) };
            }
            """, arguments: [
                "address": address.absoluteString, "area": area, "key": key as Any? ?? NSNull(),
                "value": value as Any? ?? NSNull(), "previousKey": previousKey as Any? ?? NSNull(),
                "keys": keys, "clear": clear,
            ], in: nil, contentWorld: .page)
        guard let result = reply as? [String: Any] else { throw Issue.unavailable }
        if result["changed"] as? Bool == true { throw Issue.pageChanged }
        if let issue = result["issue"] as? String {
            throw issue == "stale" ? Issue.message("This entry changed since it was read. Refresh and try again.")
                : issue == "unavailable" ? Issue.unavailable : Issue.message(issue)
        }
        guard result["saved"] as? Bool == true else { throw Issue.saveFailed }
    }
}
