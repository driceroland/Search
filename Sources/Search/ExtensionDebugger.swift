import AppKit
import Combine
import WebKit

// chrome.debugger for an extension's worker: the part of the DevTools
// protocol an extension needs to read a page, click in it, type in it, take
// its picture and send it elsewhere.
//
// WebKit has no protocol of this kind to hand over, so each command is
// carried out here: JavaScript in the page for what the page's own objects
// answer (ExtensionDebuggerPage), and the events a hand would make for
// everything else, so a click or a key is trusted by the page as a real
// one is. A command this file doesn't know is answered the way Chrome
// answers one it doesn't: with the protocol's own error, not an exception.
//
// Who may: only an extension whose manifest asks for `debugger`, only after
// the person at the keyboard allowed it (once per launch, as a sheet naming
// the extension), and never on one of Search's own pages, an extension's
// page or a file. A tab being debugged shows it on its row for as long as
// it lasts.
//
// What an extension's worker can't be called into with is carried by a long
// poll: the shim asks for what has happened (`poll`), and the answer comes
// when something does, or after a few seconds with nothing.

@available(macOS 15.4, *)
@MainActor
final class ExtensionDebugger {
    static let shared = ExtensionDebugger()

    /// A protocol error, in the text Chrome gives a script for one:
    /// `{"code":-32601,"message":"…"}`.
    struct Failure: LocalizedError {
        let code: Int
        let message: String
        var errorDescription: String? {
            let data = try? JSONSerialization.data(withJSONObject: ["code": code, "message": message], options: [.sortedKeys])
            return data.map { String(decoding: $0, as: UTF8.self) } ?? message
        }
        static func missing(_ method: String) -> Failure { Failure(code: -32601, message: "'\(method)' wasn't found") }
        static func invalid(_ what: String) -> Failure { Failure(code: -32602, message: "Invalid parameters: \(what)") }
        static func server(_ message: String) -> Failure { Failure(code: -32000, message: message) }
    }

    final class Session {
        let id = UUID().uuidString.lowercased()
        let extensionID: String
        let name: String
        weak var tab: Tab?
        weak var context: WKWebExtensionContext?
        let tabID: Tab.ID
        /// The name the page helper has on the page's global object: made up
        /// for this session, so no page and no other session knows it.
        let key = "sh" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        /// The domains switched on with `<Domain>.enable`.
        var enabled: Set<String> = []
        /// Worlds made by Page.createIsolatedWorld, by execution context id,
        /// and the names they were asked for.
        var isolated: [Int: WKContentWorld] = [:]
        var contextNames: [Int: String] = [:]
        var nextContext = 2
        /// Counts the documents the tab has shown while attached.
        var loader = 1
        /// Tab.commits when the last document was told of.
        var commits = 0
        var pointer = CGPoint.zero
        /// The buttons held, as the protocol numbers them (1 left, 2 right, 4 middle).
        var held = 0
        var bag = Set<AnyCancellable>()
        /// Page.setLifecycleEventsEnabled.
        var lifecycle = false
        /// Where a page's console, errors and requests, and its scripts, reach
        /// the session (ExtensionDebuggerEvents).
        var channel = ""
        var relay: DebuggerRelay?
        /// The worlds the relay is the handler in.
        var relayWorlds: [WKContentWorld] = []
        var sensor: WKUserScript?
        var scripts: [WKUserScript] = []
        var documentScripts: [String: WKUserScript] = [:]
        var bindings: [Binding] = []
        var nextScript = 1
        var nextException = 1
        /// Page.startScreencast: the loop sending pictures, and the last one the extension has.
        var casting: Task<Void, Never>?
        var castAcked = 0

        init(extensionID: String, name: String, tab: Tab, context: WKWebExtensionContext?, commits: Int) {
            self.extensionID = extensionID
            self.name = name
            self.tab = tab
            self.context = context
            self.tabID = tab.id
            self.commits = commits
        }
        var frame: String { tabID.uuidString.replacingOccurrences(of: "-", with: "") }
        var loaderID: String { ExtensionDebugger.loaderID(frame: frame, loader) }
    }

    /// What has happened for one extension and not yet been asked for.
    private final class Queue {
        var items: [[String: Any]] = []
        var wake: (() -> Void)?
    }

    private var sessions: [String: Session] = [:]
    private var queues: [String: Queue] = [:]
    /// Extensions the person allowed since the app started.
    private var allowed: Set<String> = []
    private var watching: Task<Void, Never>?

    // MARK: - who may attach

    /// Whether a page may be debugged: the web, and a blank tab to take
    /// somewhere. Not Search's own pages, an extension's, a file, or a
    /// private tab the extension isn't let into (that is checked where the
    /// tab is found).
    static func mayDebug(_ tab: Tab) -> Bool {
        guard tab.page == nil else { return false }
        guard let address = tab.address else { return true }
        return mayDebug(address)
    }

    /// Fetch patterns that only ask to hear of documents as they arrive.
    static func onlyFinishedDocuments(_ patterns: [[String: Any]]) -> Bool {
        patterns.allSatisfy { $0["requestStage"] as? String == "Response" && $0["resourceType"] as? String == "Document" }
    }

    static func mayDebug(_ address: URL) -> Bool {
        guard let scheme = address.scheme?.lowercased() else { return false }
        return ["http", "https"].contains(scheme) || address.absoluteString.lowercased() == "about:blank"
    }

    /// Why a session has to end, as chrome.debugger.onDetach words it, or nil
    /// when the tab is still one it may debug. Asked again on every command
    /// and whenever the tab moves: the tab can go from a page it may debug
    /// to one it may not (history, a link, a redirect), and a private tab's
    /// extension can be shut out after it attached.
    static func detachReason(private shy: Bool, access: Bool, ownPage: Bool, addresses: [URL?]) -> String? {
        if shy && !access { return "canceled_by_user" }
        if ownPage { return "target_closed" }
        if addresses.contains(where: { $0.map { !mayDebug($0) } ?? false }) { return "target_closed" }
        return nil
    }

    private func violation(_ session: Session, _ tab: Tab) -> String? {
        Self.detachReason(private: tab.shy, access: session.context?.hasAccessToPrivateData == true, ownPage: tab.page != nil,
                          addresses: [tab.address, tab.committed, tab.built?.url])
    }

    /// An extension lost something it attached with (private tabs): sessions
    /// that are no longer allowed end.
    func recheck(extension id: String) {
        for session in sessions.values where session.extensionID == id {
            if let tab = session.tab, let reason = violation(session, tab) { end(session, reason: reason) }
        }
    }

    nonisolated static func loaderID(frame: String, _ number: Int) -> String { frame + String(format: "%04d", number) }

    /// Whether two addresses are one document: the same but for a fragment.
    nonisolated static func sameDocument(_ from: URL?, _ to: URL) -> Bool {
        guard let from, var a = URLComponents(url: from, resolvingAgainstBaseURL: false),
              var b = URLComponents(url: to, resolvingAgainstBaseURL: false), b.fragment != nil || a.fragment != nil else { return false }
        a.fragment = nil
        b.fragment = nil
        return a == b
    }

    /// The name of a world only this extension's session can ask for: two
    /// extensions (or two sessions) asking for "agent" get two worlds.
    nonisolated static func worldName(extensionID: String, sessionID: String, name: String) -> String {
        "search.debugger.\(extensionID).\(sessionID).\(name.isEmpty ? "world" : name)"
    }

    func attach(to tab: Tab, context: WKWebExtensionContext, owner: Extensions) async throws -> [String: Any] {
        let id = context.uniqueIdentifier
        guard Self.mayDebug(tab), !tab.shy || context.hasAccessToPrivateData else {
            throw ExtensionShims.Unsupported(what: "Cannot access a chrome:// URL")
        }
        if let known = sessions.values.first(where: { $0.extensionID == id && $0.tabID == tab.id }) {
            throw ExtensionShims.Unsupported(what: "Another debugger is already attached to the tab with id: \(known.frame).")
        }
        if !allowed.contains(id) {
            guard await owner.ask(debugging: context) else {
                throw ExtensionShims.Unsupported(what: "Cannot attach to this target.")
            }
            allowed.insert(id)
        }
        // The page may have gone elsewhere while the sheet was up.
        guard Self.mayDebug(tab), !tab.shy || context.hasAccessToPrivateData else {
            throw ExtensionShims.Unsupported(what: "Cannot access a chrome:// URL")
        }

        let session = Session(extensionID: id, name: context.webExtension.displayName ?? "An extension", tab: tab, context: context, commits: tab.commits)
        sessions[session.id] = session
        follow(session, tab)
        mark(tab)
        keepWatching()
        return ["session": session.id]
    }

    /// The session an extension has on a tab, if it has.
    func session(on tab: Tab?, for extensionID: String) -> String? {
        guard let tab else { return nil }
        return sessions.values.first { $0.extensionID == extensionID && $0.tabID == tab.id }?.id
    }

    /// The extension let go. Nothing is told to it: Chrome doesn't.
    func detach(_ id: String, extensionID: String) {
        guard let session = sessions[id], session.extensionID == extensionID else { return }
        end(session, reason: nil)
    }

    /// Every session an extension has, when it is switched off, removed or
    /// taken up again.
    func detachAll(extension id: String, reason: String = "canceled_by_user") {
        for session in sessions.values where session.extensionID == id { end(session, reason: reason) }
        allowed.remove(id)
        queues[id] = nil
    }

    private func end(_ session: Session, reason: String?) {
        sessions[session.id] = nil
        release(session)
        session.bag.removeAll()
        if let reason {
            emit(session, "Inspector.detached", ["reason": reason])
            enqueue(session.extensionID, ["session": session.id, "detach": reason])
        }
        if let tab = session.tab { mark(tab) }
    }

    /// The tab's row says who is driving it.
    private func mark(_ tab: Tab) {
        let names = sessions.values.filter { $0.tabID == tab.id }.map(\.name)
        let sorted = Array(Set(names)).sorted()
        if tab.debuggedBy != sorted { tab.debuggedBy = sorted }
    }

    /// A tab that is closed ends its sessions; checked now and then, as a
    /// tab leaving a row has no one signal.
    private func keepWatching() {
        guard watching == nil else { return }
        watching = Task { [weak self] in
            while let self, !self.sessions.isEmpty {
                try? await Task.sleep(for: .seconds(1))
                let open = Set(Browsers.all.flatMap(\.tabs).map(\.id))
                for session in self.sessions.values where !open.contains(session.tabID) {
                    self.end(session, reason: "target_closed")
                }
            }
            self?.watching = nil
        }
    }

    // MARK: - what the page does, told

    private func follow(_ session: Session, _ tab: Tab) {
        // Where the tab is going or has arrived: a page the extension may not
        // debug ends the session, wherever it came from.
        tab.$address.sink { [weak self, weak session] address in
            guard let self, let session, let address, !Self.mayDebug(address) else { return }
            self.end(session, reason: "target_closed")
        }.store(in: &session.bag)
        tab.$page.sink { [weak self, weak session] page in
            guard let self, let session, page != nil else { return }
            self.end(session, reason: "target_closed")
        }.store(in: &session.bag)
        // A document arrived (Tab.didCommit sets `committed`, after counting
        // it). `committed` also moves, with no new document, for a fragment
        // or history.pushState: that is the same document at a new address.
        tab.$committed.dropFirst().sink { [weak self, weak session, weak tab] address in
            guard let self, let session, let tab, let address else { return }
            if !Self.mayDebug(address) { self.end(session, reason: "target_closed"); return }
            if tab.commits != session.commits {
                session.commits = tab.commits
                self.documentCommitted(session, address)
            } else if session.enabled.contains("Page") {
                self.emit(session, "Page.navigatedWithinDocument", ["frameId": session.frame, "url": address.absoluteString])
            }
        }.store(in: &session.bag)
        tab.$loading.removeDuplicates().dropFirst().sink { [weak self, weak session] loading in
            guard let self, let session, session.enabled.contains("Page") else { return }
            if loading {
                self.emit(session, "Page.frameStartedLoading", ["frameId": session.frame])
                self.lifecycle(session, ["init"], loader: session.loader + 1)
            } else {
                let stamp = Date().timeIntervalSince1970
                self.emit(session, "Page.domContentEventFired", ["timestamp": stamp])
                self.emit(session, "Page.loadEventFired", ["timestamp": stamp])
                self.emit(session, "Page.frameStoppedLoading", ["frameId": session.frame])
                self.lifecycleLoaded(session)
            }
        }.store(in: &session.bag)
    }

    /// A new document: the old one's execution contexts are gone, whatever
    /// its address, and the new one has its own.
    private func documentCommitted(_ session: Session, _ address: URL) {
        let gone = [1] + session.isolated.keys.sorted()
        let before = session.loader
        session.loader += 1
        session.isolated.removeAll()
        session.contextNames.removeAll()
        dropContextBindings(session)
        if session.enabled.contains("Runtime") {
            for id in gone {
                emit(session, "Runtime.executionContextDestroyed", [
                    "executionContextId": id, "executionContextUniqueId": Self.loaderID(frame: session.frame, before) + ".\(id)"])
            }
            emit(session, "Runtime.executionContextsCleared", [:])
        }
        if session.enabled.contains("Page") {
            emit(session, "Page.frameNavigated", ["frame": frameInfo(session, url: address.absoluteString)])
        }
        if session.enabled.contains("Runtime") {
            emit(session, "Runtime.executionContextCreated", ["context": contextInfo(session, address: address)])
        }
    }

    private func frameInfo(_ session: Session, url: String) -> [String: Any] {
        let origin = URL(string: url).flatMap { u in u.scheme.flatMap { s in u.host().map { "\(s)://\($0)" } } } ?? ""
        return ["id": session.frame, "loaderId": session.loaderID, "url": url, "domainAndRegistry": "",
                "securityOrigin": origin, "mimeType": "text/html", "secureContextType": "Secure",
                "crossOriginIsolatedContextType": "NotIsolated", "gatedAPIFeatures": [String]()]
    }

    private func contextInfo(_ session: Session, address: URL?) -> [String: Any] {
        let origin = address.flatMap { u in u.scheme.flatMap { s in u.host().map { "\(s)://\($0)" } } } ?? ""
        return ["id": 1, "origin": origin, "name": "", "uniqueId": session.loaderID + ".1",
                "auxData": ["isDefault": true, "type": "default", "frameId": session.frame]]
    }

    func emit(_ session: Session, _ method: String, _ params: [String: Any]) {
        enqueue(session.extensionID, ["session": session.id, "method": method, "params": params])
    }

    private func enqueue(_ id: String, _ item: [String: Any]) {
        let queue = queues[id] ?? Queue()
        queues[id] = queue
        // Nobody listening for a long time must not fill memory.
        if queue.items.count >= 2000 { queue.items.removeFirst(500) }
        queue.items.append(item)
        queue.wake?()
    }

    /// What has happened since the last call; waits up to `seconds` when
    /// nothing has. A second caller takes over from the first.
    func poll(extensionID id: String, seconds: Double) async -> [[String: Any]] {
        let queue = queues[id] ?? Queue()
        queues[id] = queue
        if queue.items.isEmpty {
            queue.wake?()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                var finished = false
                let finish = {
                    guard !finished else { return }
                    finished = true
                    continuation.resume()
                }
                queue.wake = finish
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(min(max(seconds, 1), 30)))
                    finish()
                }
            }
            queue.wake = nil
        }
        let taken = Array(queue.items.prefix(200))
        queue.items.removeFirst(taken.count)
        return taken
    }

    // MARK: - commands

    func send(session id: String, extensionID: String, method: String, params: [String: Any], sessionId: String) async throws -> Any {
        guard let session = sessions[id], session.extensionID == extensionID, let tab = session.tab else {
            throw ExtensionShims.Unsupported(what: "Debugger is not attached to the tab.")
        }
        if let reason = violation(session, tab) {
            end(session, reason: reason)
            throw ExtensionShims.Unsupported(what: "Debugger is not attached to the tab.")
        }
        if !sessionId.isEmpty { throw Failure(code: -32001, message: "Session with given id not found.") }
        let domain = String(method.prefix(while: { $0 != "." }))
        switch method {
        // Switched on and off; most have nothing to switch.
        case "Page.enable", "Runtime.enable", "DOM.enable", "Network.enable", "Log.enable":
            session.enabled.insert(domain)
            if method == "Runtime.enable" || method == "Network.enable" { watch(session, tab) }
            if method == "Runtime.enable" {
                emit(session, "Runtime.executionContextCreated", ["context": contextInfo(session, address: tab.address)])
            }
            return [String: Any]()
        case "Page.disable", "Runtime.disable", "DOM.disable", "Network.disable", "Log.disable":
            session.enabled.remove(domain)
            return [String: Any]()
        case "Page.setInterceptFileChooserDialog", "Page.stopLoading",
             "Emulation.setFocusEmulationEnabled", "Emulation.clearDeviceMetricsOverride", "Input.cancelDragging",
             "Target.setAutoAttach", "Target.setDiscoverTargets", "Fetch.disable", "Security.enable", "Security.disable",
             "Performance.enable", "Performance.disable", "Runtime.runIfWaitingForDebugger", "Runtime.discardConsoleEntries",
             "Accessibility.enable", "Accessibility.disable", "DOMSnapshot.enable", "DOMSnapshot.disable":
            if method == "Page.stopLoading" { tab.stop() }
            return [String: Any]()
        case "Page.setLifecycleEventsEnabled":
            session.lifecycle = params["enabled"] as? Bool ?? false
            // A page already shown has been through its lifecycle: told as it
            // would be from the start, so one waiting for the page to load sees it.
            if session.lifecycle, !tab.loading {
                lifecycle(session, ["init", "commit"])
                lifecycleLoaded(session)
            }
            return [String: Any]()
        case "Emulation.setDeviceMetricsOverride":
            throw Failure.server("Search can't resize a tab's viewport")
        case "Fetch.enable":
            // Pausing requests isn't something WebKit lets a browser do. What
            // an extension asks only to be told of finished documents it can
            // do without; a request it means to hold or change it can't.
            guard Self.onlyFinishedDocuments(params["patterns"] as? [[String: Any]] ?? []) else {
                throw Failure.server("Search can't pause requests")
            }
            return [String: Any]()
        case "Target.getTargets":
            return ["targetInfos": [["targetId": "tab-" + session.frame, "type": "page", "title": tab.title,
                                     "url": tab.address?.absoluteString ?? "about:blank", "attached": true, "canAccessOpener": false]]]
        case "Page.addScriptToEvaluateOnNewDocument":
            return try addScript(session, tab, params)
        case "Page.removeScriptToEvaluateOnNewDocument":
            try removeScript(session, tab, params)
            return [String: Any]()
        case "Runtime.addBinding":
            try addBinding(session, tab, params)
            return [String: Any]()
        case "Runtime.removeBinding":
            try removeBinding(session, tab, params)
            return [String: Any]()
        case "Page.startScreencast":
            startScreencast(session, tab, params)
            return [String: Any]()
        case "Page.stopScreencast":
            session.casting?.cancel()
            session.casting = nil
            return [String: Any]()
        case "Page.screencastFrameAck":
            session.castAcked = max(session.castAcked, params["sessionId"] as? Int ?? 0)
            return [String: Any]()
        case "Browser.getVersion":
            return ["protocolVersion": "1.3", "product": "Search", "revision": "", "userAgent": "", "jsVersion": ""]
        case "Target.getTargetInfo":
            return ["targetInfo": ["targetId": "tab-" + session.frame, "type": "page", "title": tab.title,
                                   "url": tab.address?.absoluteString ?? "about:blank", "attached": true, "canAccessOpener": false]]
        case "Page.handleJavaScriptDialog":
            throw Failure.server("No dialog is showing")

        case "Page.getFrameTree":
            return ["frameTree": ["frame": frameInfo(session, url: tab.address?.absoluteString ?? "about:blank"),
                                  "childFrames": [Any]()]]
        case "Page.createIsolatedWorld":
            let name = (params["worldName"] as? String) ?? ""
            let context = session.nextContext
            session.nextContext += 1
            let world = isolatedWorld(session, name)
            session.isolated[context] = world
            session.contextNames[context] = name
            bindContext(session, tab, context: context, name: name)
            if session.enabled.contains("Runtime") {
                emit(session, "Runtime.executionContextCreated", ["context": [
                    "id": context, "origin": "", "name": name, "uniqueId": session.loaderID + ".\(context)",
                    "auxData": ["isDefault": false, "type": "isolated", "frameId": session.frame]]])
            }
            return ["executionContextId": context]
        case "Page.navigate":
            return try navigate(session, tab, params)
        case "Page.reload":
            tab.reload(fromOrigin: params["ignoreCache"] as? Bool ?? false)
            return [String: Any]()
        case "Page.getNavigationHistory":
            return history(tab)
        case "Page.navigateToHistoryEntry":
            guard let entry = params["entryId"] as? Int, let list = tab.built?.backForwardList else { throw Failure.invalid("entryId") }
            let items = list.backList + (list.currentItem.map { [$0] } ?? []) + list.forwardList
            guard items.indices.contains(entry) else { throw Failure.server("No entry with passed id") }
            // History reaches pages the session could not have attached to.
            guard Self.mayDebug(items[entry].url) else { throw Failure.server("Cannot navigate to invalid URL") }
            tab.go(to: items[entry])
            return [String: Any]()
        case "Page.getLayoutMetrics":
            return try await layoutMetrics(session, tab)
        case "Page.captureScreenshot":
            return try await screenshot(tab, params)
        case "Page.bringToFront":
            return [String: Any]()

        case "Runtime.evaluate":
            return try await evaluate(session, tab, params)
        case "Runtime.callFunctionOn":
            return try await callFunction(session, tab, params)
        case "Runtime.releaseObject":
            let (world, context) = try inside(object: params["objectId"] as? String, session)
            return try await op(session, tab, world, context, "release", params)
        case "Runtime.releaseObjectGroup":
            for (context, world) in [(1, WKContentWorld.page)] + session.isolated.map({ ($0.key, $0.value) }) {
                _ = try await op(session, tab, world, context, "releaseGroup", params)
            }
            return [String: Any]()

        case "DOM.describeNode", "DOM.resolveNode", "DOM.getBoxModel", "DOM.getContentQuads", "DOM.scrollIntoViewIfNeeded":
            let name = ["DOM.describeNode": "describeNode", "DOM.resolveNode": "resolveNode", "DOM.getBoxModel": "boxModel",
                        "DOM.getContentQuads": "quads", "DOM.scrollIntoViewIfNeeded": "scrollIntoView"][method] ?? ""
            if method == "DOM.resolveNode", params["objectId"] == nil, let wanted = (params["executionContextId"] as? NSNumber)?.intValue, wanted != 1 {
                return try await resolve(session, tab, params, in: wanted)
            }
            let (world, context) = try inside(object: params["objectId"] as? String, session)
            return try await op(session, tab, world, context, name, params)
        case "Accessibility.getFullAXTree", "DOMSnapshot.captureSnapshot", "DOM.getDocument", "DOM.getNodeForLocation":
            let name = ["Accessibility.getFullAXTree": "axTree", "DOMSnapshot.captureSnapshot": "snapshot",
                        "DOM.getDocument": "document", "DOM.getNodeForLocation": "nodeAt"][method] ?? ""
            var asked = params
            asked["mainFrame"] = session.frame
            return try await op(session, tab, .page, 1, name, asked)
        case "Network.getCookies":
            let urls = (params["urls"] as? [String])?.compactMap(URL.init(string:)) ?? tab.address.map { [$0] }
            return await cookies(tab, urls: urls)
        case "Network.getAllCookies", "Storage.getCookies":
            return await cookies(tab, urls: nil)
        case "Network.setCookie":
            return try await setCookie(tab, params)
        case "Network.deleteCookies":
            try await deleteCookies(tab, params)
            return [String: Any]()
        case "DOM.getFrameOwner":
            throw Failure.server("Frame with the given id does not belong to the target.")

        case "Input.dispatchMouseEvent":
            try mouse(session, tab, params)
            return [String: Any]()
        case "Input.synthesizeScrollGesture":
            // The distances count toward the top and the left; a wheel's, toward the bottom and the right.
            guard let x = (params["x"] as? NSNumber)?.doubleValue, let y = (params["y"] as? NSNumber)?.doubleValue else {
                throw Failure.invalid("x and y")
            }
            try mouse(session, tab, ["type": "mouseWheel", "x": x, "y": y,
                                     "deltaX": -((params["xDistance"] as? NSNumber)?.doubleValue ?? 0),
                                     "deltaY": -((params["yDistance"] as? NSNumber)?.doubleValue ?? 0)])
            return [String: Any]()
        case "Input.dispatchKeyEvent":
            try key(tab, params)
            return [String: Any]()
        case "Input.insertText":
            try await insert(tab, params["text"] as? String ?? "")
            return [String: Any]()
        default:
            throw Failure.missing(method)
        }
    }

    // MARK: - the page

    /// The world of a context the session made, under a name no other
    /// extension or session can ask for.
    func isolatedWorld(_ session: Session, _ name: String) -> WKContentWorld {
        .world(name: Self.worldName(extensionID: session.extensionID, sessionID: session.id, name: name))
    }

    /// DOM.resolveNode into a context other than the page's own: the node is
    /// named by where it is in the document, which every world shares.
    private func resolve(_ session: Session, _ tab: Tab, _ params: [String: Any], in context: Int) async throws -> [String: Any] {
        let (world, number) = try inside(context: context, session)
        let located = try await op(session, tab, .page, 1, "nodePath", params)
        var asked = params
        asked["path"] = located["path"]
        return try await op(session, tab, world, number, "resolvePath", asked)
    }

    func web(_ tab: Tab) -> PageView { tab.web }

    /// An objectId begins with the number of the world that made it.
    private func inside(object objectId: String?, _ session: Session) throws -> (WKContentWorld, Int) {
        // A node named by its id alone lives in the page's own world.
        guard let objectId else { return try inside(context: nil, session) }
        guard let number = objectId.split(separator: ".").first.flatMap({ Int($0) }) else {
            throw Failure.server("Could not find object with given id")
        }
        return try inside(context: number, session)
    }

    private func inside(context: Int?, _ session: Session) throws -> (WKContentWorld, Int) {
        let number = context ?? 1
        if number == 1 { return (.page, 1) }
        guard let world = session.isolated[number] else { throw Failure.server("Cannot find context with specified id") }
        return (world, number)
    }

    /// Runs `body` in a world, after the helper. What it answers is the
    /// helper's JSON: `{"result": …}` or `{"error": {code, message}}`.
    private func page(_ session: Session, _ tab: Tab, _ world: WKContentWorld, _ context: Int, body: String, payload: [String: Any]) async throws -> [String: Any] {
        var full = payload
        full["tag"] = context
        let text = String(decoding: try JSONSerialization.data(withJSONObject: full), as: UTF8.self)
        let answer: Any?
        do {
            answer = try await web(tab).callAsyncJavaScript(ExtensionDebuggerPage.prelude(key: session.key) + body, arguments: ["payload": text],
                                                            in: nil, contentWorld: world)
        } catch {
            throw Failure.server(Self.scriptMessage(error))
        }
        // Whatever the page's own script made of the helper, only JSON text
        // that parses counts, and a number is read as the number it is.
        guard let json = answer as? String, let parsed = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        else { throw Failure.server("The page gave no answer") }
        if let error = parsed["error"] as? [String: Any] {
            throw Failure(code: (error["code"] as? NSNumber).flatMap { Self.whole($0.doubleValue) } ?? -32000,
                          message: error["message"] as? String ?? "")
        }
        return parsed
    }

    nonisolated static func scriptMessage(_ error: Error) -> String {
        let info = (error as NSError).userInfo
        return info["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
    }

    func op(_ session: Session, _ tab: Tab, _ world: WKContentWorld, _ context: Int, _ name: String, _ params: [String: Any]) async throws -> [String: Any] {
        let reply = try await page(session, tab, world, context, body: "return await cdp.run(p.name, p.params);",
                                   payload: ["name": name, "params": params])
        return reply["result"] as? [String: Any] ?? [:]
    }

    private func evaluate(_ session: Session, _ tab: Tab, _ params: [String: Any]) async throws -> [String: Any] {
        guard let expression = params["expression"] as? String else { throw Failure.invalid("expression") }
        let (world, context) = try inside(context: params["contextId"] as? Int, session)
        var options = Self.options(params)
        let wantsAwait = options["awaitPromise"] as? Bool == true || params["replMode"] as? Bool == true || expression.contains("await ")
        // As an expression first, which needs no eval, so a page whose
        // policy forbids eval can still be read; then as a script.
        var attempts = [("return await cdp.finish(() => (\n\(expression)\n), p.options);", false)]
        if wantsAwait { attempts.append(("return await cdp.finish(async () => (\n\(expression)\n), p.options);", true)) }
        attempts.append(("return await cdp.finish(() => (0, eval)(p.expression), p.options);", false))
        var last: [String: Any] = [:]
        for (body, awaits) in attempts {
            if awaits { options["awaitPromise"] = true }
            do {
                let reply = try await page(session, tab, world, context, body: body, payload: ["expression": expression, "options": options])
                return reply
            } catch let failure as Failure where failure.message.hasPrefix("SyntaxError") {
                last = ["result": ["type": "object", "subtype": "error", "className": "SyntaxError", "description": failure.message],
                        "exceptionDetails": ["exceptionId": 0, "text": "Uncaught", "lineNumber": 0, "columnNumber": 0,
                                             "exception": ["type": "object", "subtype": "error", "className": "SyntaxError",
                                                           "description": failure.message]]]
            }
        }
        return last
    }

    private func callFunction(_ session: Session, _ tab: Tab, _ params: [String: Any]) async throws -> [String: Any] {
        guard let declaration = params["functionDeclaration"] as? String else { throw Failure.invalid("functionDeclaration") }
        let found: (WKContentWorld, Int)
        if let objectId = params["objectId"] as? String {
            found = try inside(object: objectId, session)
        } else {
            found = try inside(context: params["executionContextId"] as? Int, session)
        }
        var options = Self.options(params)
        options["objectId"] = params["objectId"] as? String
        options["arguments"] = params["arguments"] as? [[String: Any]] ?? []
        do {
            let reply = try await page(session, tab, found.0, found.1, body: "return await cdp.callOn((\n\(declaration)\n), p.options);",
                                       payload: ["options": options])
            return reply
        } catch let failure as Failure where failure.message.hasPrefix("SyntaxError") {
            throw Failure.server(failure.message)
        }
    }

    nonisolated static func options(_ params: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for name in ["returnByValue", "awaitPromise", "objectGroup"] {
            if let value = params[name] { out[name] = value }
        }
        return out
    }

    private func layoutMetrics(_ session: Session, _ tab: Tab) async throws -> [String: Any] {
        let reply = try await op(session, tab, .page, 1, "viewport", [:])
        // The page's script wrote these numbers, or could have: each is read
        // as a finite number in range, or not at all.
        let width = Self.finite(reply["clientWidth"]) ?? 0, height = Self.finite(reply["clientHeight"]) ?? 0
        let innerWidth = Self.finite(reply["innerWidth"]) ?? width, innerHeight = Self.finite(reply["innerHeight"]) ?? height
        let x = Self.finite(reply["scrollX"]) ?? 0, y = Self.finite(reply["scrollY"]) ?? 0
        let contentWidth = Self.finite(reply["scrollWidth"]) ?? width, contentHeight = Self.finite(reply["scrollHeight"]) ?? height
        let layout: [String: Any] = ["pageX": Self.whole(x), "pageY": Self.whole(y),
                                     "clientWidth": Self.whole(width), "clientHeight": Self.whole(height)]
        let visual: [String: Any] = ["offsetX": 0, "offsetY": 0, "pageX": x, "pageY": y,
                                     "clientWidth": innerWidth, "clientHeight": innerHeight, "scale": 1, "zoom": 1]
        let content: [String: Any] = ["x": 0, "y": 0, "width": contentWidth, "height": contentHeight]
        return ["layoutViewport": layout, "visualViewport": visual, "contentSize": content,
                "cssLayoutViewport": layout, "cssVisualViewport": visual, "cssContentSize": content]
    }

    /// A number that can be trusted to convert: finite, and kept within a
    /// range no page or screen reaches. Anything else is not a number here.
    nonisolated static func finite(_ value: Any?) -> Double? {
        guard let number = (value as? NSNumber)?.doubleValue, number.isFinite else { return nil }
        return min(max(number, -1e9), 1e9)
    }

    /// A whole number from any Double, without the trap `Int(_:)` has for NaN
    /// and for what is out of range.
    nonisolated static func whole(_ value: Double) -> Int {
        value.isFinite ? Int(min(max(value, -1e9), 1e9)) : 0
    }

    /// What came from a page, as JSON can carry it: a number that is NaN or
    /// infinite, a key that is not a string, or anything but text, numbers,
    /// lists and records becomes null, so serialising it can't raise.
    nonisolated static func plain(_ value: Any, depth: Int = 0) -> Any {
        guard depth < 64 else { return NSNull() }
        switch value {
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number }
            return number.doubleValue.isFinite ? number : NSNull()
        case let text as String: return text
        case let list as [Any]: return list.map { plain($0, depth: depth + 1) }
        case let record as [String: Any]: return record.mapValues { plain($0, depth: depth + 1) }
        default: return NSNull()
        }
    }

    private func navigate(_ session: Session, _ tab: Tab, _ params: [String: Any]) throws -> [String: Any] {
        guard let text = params["url"] as? String, let url = URL(string: text) else { throw Failure.invalid("url") }
        // Not onto Search's own pages, an extension's, or a file: the same
        // line as for attaching.
        guard Self.mayDebug(url) else { throw Failure.server("Cannot navigate to invalid URL") }
        // The loader is counted where the document arrives (follow), not here:
        // this is the number it will have. A move within the document has no
        // loader of its own.
        let sameDocument = Self.sameDocument(tab.address, url)
        tab.go(to: url)
        return sameDocument ? ["frameId": session.frame] : ["frameId": session.frame, "loaderId": Self.loaderID(frame: session.frame, session.loader + 1)]
    }

    private func history(_ tab: Tab) -> [String: Any] {
        guard let list = tab.built?.backForwardList else { return ["currentIndex": 0, "entries": [Any]()] }
        let items = list.backList + (list.currentItem.map { [$0] } ?? []) + list.forwardList
        let entries = items.enumerated().map { index, item -> [String: Any] in
            ["id": index, "url": item.url.absoluteString, "userTypedURL": item.initialURL.absoluteString,
             "title": item.title ?? "", "transitionType": "link"]
        }
        return ["currentIndex": list.backList.count, "entries": entries]
    }

    // MARK: - the picture

    /// The page as a picture, as the protocol asks: `format`, `quality`, and
    /// `clip` in the page's own pixels. One picture pixel to a page pixel
    /// (times the clip's scale), not the screen's two.
    func screenshot(_ tab: Tab, _ params: [String: Any]) async throws -> [String: Any] {
        let view = web(tab)
        guard view.window != nil else { throw Failure.server("Unable to capture screenshot: the tab isn't on screen") }
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = true
        var scale = 1.0
        var width = Double(view.bounds.width), height = Double(view.bounds.height)
        if let clip = params["clip"] as? [String: Any],
           let x = Self.finite(clip["x"]), let y = Self.finite(clip["y"]),
           let w = Self.finite(clip["width"]), let h = Self.finite(clip["height"]), w > 0, h > 0 {
            configuration.rect = CGRect(x: x, y: y, width: w, height: h)
            scale = min(max(Self.finite(clip["scale"]) ?? 1, 0.01), 8)
            width = w
            height = h
        }
        guard width > 0, height > 0 else { throw Failure.server("Unable to capture screenshot") }
        let pixels = (width: min(16384, max(1, Self.whole((width * scale).rounded()))),
                      height: min(16384, max(1, Self.whole((height * scale).rounded()))))
        configuration.snapshotWidth = NSNumber(value: Double(pixels.width))
        let image: NSImage
        do { image = try await view.takeSnapshot(configuration: configuration) }
        catch { throw Failure.server("Unable to capture screenshot") }
        let format = params["format"] as? String ?? "png"
        let quality = min(max((params["quality"] as? Double ?? 80) / 100, 0.01), 1)
        guard let data = Self.encode(image, pixels: pixels, jpeg: format == "jpeg", quality: quality) else {
            throw Failure.server("Unable to capture screenshot")
        }
        return ["data": data.base64EncodedString()]
    }

    nonisolated static func encode(_ image: NSImage, pixels: (width: Int, height: Int), jpeg: Bool, quality: Double) -> Data? {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels.width, pixelsHigh: pixels.height,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: pixels.width, height: pixels.height))
        return jpeg
            ? bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality])
            : bitmap.representation(using: .png, properties: [:])
    }

    // MARK: - the hand

    nonisolated static func modifiers(_ bits: Int) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if bits & 1 != 0 { flags.insert(.option) }
        if bits & 2 != 0 { flags.insert(.control) }
        if bits & 4 != 0 { flags.insert(.command) }
        if bits & 8 != 0 { flags.insert(.shift) }
        return flags
    }

    /// A mouse event handed to the page's view, as a pointer's is, so the
    /// page sees it trusted. The view has to be in a window: a page with
    /// none is not laid out, and has nothing to click.
    func mouse(_ session: Session, _ tab: Tab, _ params: [String: Any]) throws {
        let view = web(tab)
        guard let window = view.window else { throw Failure.server("The tab isn't on screen to take input") }
        guard let type = params["type"] as? String, let x = Self.finite(params["x"]),
              let y = Self.finite(params["y"]) else { throw Failure.invalid("type, x and y") }
        let local = NSPoint(x: x, y: view.isFlipped ? y : view.bounds.height - y)
        let spot = view.convert(local, to: nil)
        let flags = Self.modifiers((params["modifiers"] as? NSNumber)?.intValue ?? 0)
        let button = params["button"] as? String ?? "none"
        let clicks = max(1, (params["clickCount"] as? NSNumber)?.intValue ?? 1)
        session.pointer = CGPoint(x: x, y: y)

        func make(_ type: NSEvent.EventType, clicks: Int, pressure: Swift.Float) -> NSEvent? {
            guard var event = NSEvent.mouseEvent(
                with: type, location: spot, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: pressure
            ) else { return nil }
            if button == "middle", let raw = event.cgEvent {
                raw.setIntegerValueField(.mouseEventButtonNumber, value: 2)
                event = NSEvent(cgEvent: raw) ?? event
            }
            return event
        }
        // The window the page is in is not asked to be key: the person may
        // be typing elsewhere. The page's view takes the keys only when it
        // is clicked (below), as a click does.
        switch type {
        case "mousePressed":
            let kind: NSEvent.EventType = button == "right" ? .rightMouseDown : button == "middle" ? .otherMouseDown : .leftMouseDown
            session.held |= button == "right" ? 2 : button == "middle" ? 4 : 1
            if let event = make(kind, clicks: clicks, pressure: 1) {
                window.makeFirstResponder(view)
                switch kind {
                case .rightMouseDown: view.rightMouseDown(with: event)
                case .otherMouseDown: view.otherMouseDown(with: event)
                default: view.mouseDown(with: event)
                }
            }
        case "mouseReleased":
            let kind: NSEvent.EventType = button == "right" ? .rightMouseUp : button == "middle" ? .otherMouseUp : .leftMouseUp
            session.held &= ~(button == "right" ? 2 : button == "middle" ? 4 : 1)
            if let event = make(kind, clicks: clicks, pressure: 0) {
                switch kind {
                case .rightMouseUp: view.rightMouseUp(with: event)
                case .otherMouseUp: view.otherMouseUp(with: event)
                default: view.mouseUp(with: event)
                }
            }
        case "mouseMoved":
            if session.held & 1 != 0, let event = make(.leftMouseDragged, clicks: 1, pressure: 1) {
                view.mouseDragged(with: event)
            } else if session.held & 2 != 0, let event = make(.rightMouseDragged, clicks: 1, pressure: 1) {
                view.rightMouseDragged(with: event)
            } else if let event = make(.mouseMoved, clicks: 0, pressure: 0) {
                view.mouseMoved(with: event)
            }
        case "mouseWheel":
            let dx = Self.finite(params["deltaX"]) ?? 0, dy = Self.finite(params["deltaY"]) ?? 0
            // Where the pointer is, in the screen's own terms: an event made
            // here has no window, so AppKit takes this point as the page's.
            let onScreen = window.convertPoint(toScreen: spot)
            let over = CGPoint(x: onScreen.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - onScreen.y)
            func scroll(_ phase: Int64, _ x: Double, _ y: Double) {
                guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                       wheel1: Int32(Self.whole(-y)), wheel2: Int32(Self.whole(-x)), wheel3: 0) else { return }
                cg.location = over
                cg.setIntegerValueField(CGEventField(rawValue: 88)!, value: 1)  // kCGScrollWheelEventIsContinuous
                cg.setIntegerValueField(CGEventField(rawValue: 99)!, value: phase)  // kCGScrollWheelEventScrollPhase
                cg.setIntegerValueField(CGEventField(rawValue: 96)!, value: Int64(Self.whole(-y)))  // kCGScrollWheelEventPointDeltaAxis1
                cg.setIntegerValueField(CGEventField(rawValue: 97)!, value: Int64(Self.whole(-x)))  // kCGScrollWheelEventPointDeltaAxis2
                if let event = NSEvent(cgEvent: cg) { view.scrollWheel(with: event) }
            }
            scroll(1, 0, 0)
            scroll(2, dx, dy)
            scroll(4, 0, 0)
        default:
            throw Failure.invalid("type")
        }
    }

    /// Keys that have a name rather than a character: the Mac's key code,
    /// and the character AppKit gives the press.
    nonisolated static let named: [String: (code: UInt16, characters: String)] = [
        "Enter": (36, "\r"), "Tab": (48, "\t"), "Backspace": (51, "\u{7f}"), "Escape": (53, "\u{1b}"),
        "Delete": (117, "\u{f728}"), "ArrowLeft": (123, "\u{f702}"), "ArrowRight": (124, "\u{f703}"),
        "ArrowDown": (125, "\u{f701}"), "ArrowUp": (126, "\u{f700}"), "Home": (115, "\u{f729}"),
        "End": (119, "\u{f72b}"), "PageUp": (116, "\u{f72c}"), "PageDown": (121, "\u{f72d}"), " ": (49, " "),
    ]

    /// The Mac's key code for a character on a US keyboard.
    nonisolated static let codes: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
        "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25,
        "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38,
        "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50,
    ]

    nonisolated static func keyCode(key: String, text: String?) -> (code: UInt16, characters: String)? {
        if let known = named[key] { return known }
        let characters = (text?.isEmpty == false ? text : nil) ?? key
        guard characters.count == 1, let character = characters.lowercased().first else { return nil }
        return (codes[character] ?? 0, characters)
    }

    /// Keys whose press does something with no character to type.
    nonisolated static let commandKeys: Set<String> = [
        "Backspace", "Delete", "Escape", "ArrowLeft", "ArrowRight", "ArrowDown", "ArrowUp", "Home", "End", "PageUp", "PageDown",
    ]

    /// What one Input.dispatchKeyEvent does, as Chrome's four types mean it:
    /// `keyDown` is a key going down, and types its `text` if it has any;
    /// `rawKeyDown` is the key going down and nothing more; `char` types its
    /// `text` and is no key; `keyUp` lets the key go. So a character is typed
    /// once by `keyDown` with text, or by `rawKeyDown` then `char`.
    struct KeyPlan: Equatable {
        var event: (code: UInt16, characters: String, base: String, down: Bool)?
        var insert: String?
        static func == (a: KeyPlan, b: KeyPlan) -> Bool {
            a.insert == b.insert && a.event?.code == b.event?.code && a.event?.characters == b.event?.characters && a.event?.down == b.event?.down
        }
    }

    nonisolated static func keyPlan(type: String, key: String, text: String?) -> KeyPlan? {
        let typed = text?.isEmpty == false ? text : nil
        let info = keyCode(key: key, text: text)
        switch type {
        case "char":
            return KeyPlan(event: nil, insert: typed)
        case "keyUp":
            return KeyPlan(event: info.map { ($0.code, $0.characters, $0.characters, false) }, insert: nil)
        case "keyDown", "rawKeyDown":
            guard let info else { return KeyPlan(event: nil, insert: type == "keyDown" ? typed : nil) }
            if type == "keyDown", let typed { return KeyPlan(event: (info.code, typed, info.characters, true), insert: nil) }
            // The view types what its key event carries, so a press that
            // types nothing carries nothing, unless it is a command.
            return KeyPlan(event: (info.code, commandKeys.contains(key) ? info.characters : "", info.characters, true), insert: nil)
        default:
            return nil
        }
    }

    /// A key pressed or let go on the page's view.
    private func key(_ tab: Tab, _ params: [String: Any]) throws {
        let view = web(tab)
        guard let window = view.window else { throw Failure.server("The tab isn't on screen to take input") }
        guard let type = params["type"] as? String else { throw Failure.invalid("type") }
        let flags = Self.modifiers((params["modifiers"] as? NSNumber)?.intValue ?? 0)
        let text = params["text"] as? String
        guard let plan = Self.keyPlan(type: type, key: params["key"] as? String ?? text ?? "", text: text) else {
            throw Failure.invalid("type")
        }
        if let press = plan.event {
            guard let event = NSEvent.keyEvent(
                with: press.down ? .keyDown : .keyUp, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: press.characters, charactersIgnoringModifiers: press.base,
                isARepeat: params["autoRepeat"] as? Bool ?? false, keyCode: press.code
            ) else { return }
            if (window.firstResponder as? NSView)?.isDescendant(of: view) != true {
                window.makeFirstResponder(view)
            }
            if press.down { view.keyDown(with: event) } else { view.keyUp(with: event) }
        }
        if let typed = plan.insert { Task { try? await insert(tab, typed) } }
    }

    /// Text typed as one piece, as an input method hands it over.
    private func insert(_ tab: Tab, _ text: String) async throws {
        let view = web(tab)
        guard let window = view.window else { throw Failure.server("The tab isn't on screen to take input") }
        if let client = window.firstResponder as? NSTextInputClient, (window.firstResponder as? NSView)?.isDescendant(of: view) == true {
            client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
            return
        }
        // The view isn't what has the keys: the page's focused field gets it.
        _ = try await view.callAsyncJavaScript("return document.execCommand('insertText', false, text);",
                                               arguments: ["text": text], in: nil, contentWorld: .page)
    }
}
