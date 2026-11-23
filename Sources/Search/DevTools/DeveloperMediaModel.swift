import Foundation
import WebKit

/// The Media drawer tool's state: every player the page scripts found, by
/// document, with its event log. WebKit has no Media domain, so two scripts
/// go into the tab while the tool is open: DeveloperMedia-observe.js in
/// Search's own world (listening, describing, out of the page's reach) and
/// DeveloperMedia-hooks.js in the page's world (the prototype hooks only
/// it can make). The observer posts its players about twice a second while
/// the handler is there; one per DevTools session.
@MainActor
final class DeveloperMediaModel: ObservableObject {
    @Published private(set) var players: [DeveloperMediaPlayer] = []
    @Published private(set) var logs: [String: DeveloperMediaEventLog<DeveloperMediaEvent>] = [:]
    @Published var selection: String?
    @Published private(set) var problem: String?
    @Published private(set) var listening = false

    static let world = WKContentWorld.world(name: "PerchMedia")
    static let handlerName = "perchMedia"
    static let observeScript = DevToolsResources.script("DeveloperMedia-observe.js")
    static let hooksScript = DevToolsResources.script("DeveloperMedia-hooks.js")
    static let eventLimit = 1_000
    private static let objectGroup = "perch-media"

    private weak var session: DeveloperToolsSession?
    private weak var observedWeb: WKWebView?
    private var relay: DeveloperMediaRelay?
    private var scripts: [WKUserScript] = []
    private var loading: NSKeyValueObservation?
    /// Each document's frame, for calling back into its observer.
    private var frames: [String: WKFrameInfo] = [:]
    private var topDocument: String?
    private var lastSeq: [String: Int] = [:]
    private var hoverTask: Task<Void, Never>?

    private static var models: [ObjectIdentifier: (session: WeakSession, model: DeveloperMediaModel)] = [:]
    struct WeakSession { weak var value: DeveloperToolsSession? }

    static func model(for session: DeveloperToolsSession) -> DeveloperMediaModel {
        for (key, entry) in models where entry.session.value == nil {
            entry.model.stop()
            models[key] = nil
        }
        let key = ObjectIdentifier(session)
        if let found = models[key], found.session.value === session { return found.model }
        let model = DeveloperMediaModel(session: session)
        models[key] = (WeakSession(value: session), model)
        return model
    }

    private init(session: DeveloperToolsSession) {
        self.session = session
    }

    var selected: DeveloperMediaPlayer? {
        players.first { $0.id == selection } ?? players.first
    }

    func log(_ id: String) -> [DeveloperMediaEvent] { logs[id]?.entries ?? [] }

    /// The Messages tab: the player's MediaError and the Console's
    /// warnings and errors about media.
    func messages(for player: DeveloperMediaPlayer) -> [DeveloperMediaMessage] {
        let errorTime = log(player.id).last { $0.name == "error" }?.time
        let console = (session?.console ?? []).map { (level: $0.level, text: $0.text) }
        return DeveloperMediaMessages.messages(for: player, errorTime: errorTime, console: console)
    }

    // MARK: Listening

    /// The tool opened: the scripts go into the tab (and into the page
    /// already loaded), and the handler starts taking their reports.
    func start() {
        guard let session, let web = session.web else {
            problem = "The inspected page isn’t available."
            return
        }
        if observedWeb !== web { stop() }
        guard !listening else { return }
        problem = nil
        let controller = web.configuration.userContentController
        let relay = DeveloperMediaRelay { [weak self] body, frame, from in
            guard let self, let from, from === self.observedWeb else { return }
            self.received(body, frame: frame)
        }
        controller.removeScriptMessageHandler(forName: Self.handlerName, contentWorld: Self.world)
        controller.add(relay, contentWorld: Self.world, name: Self.handlerName)
        let hooks = WKUserScript(source: Self.hooksScript, injectionTime: .atDocumentStart, forMainFrameOnly: false,
                                 in: .page)
        let observe = WKUserScript(source: Self.observeScript, injectionTime: .atDocumentStart, forMainFrameOnly: false,
                                   in: Self.world)
        scripts = [hooks, observe]
        scripts.forEach(controller.addUserScript)
        self.relay = relay
        observedWeb = web
        listening = true
        // The tab puts its own scripts back as each navigation begins,
        // taking these with them: they go back in before the page commits.
        loading = web.observe(\.isLoading, options: [.new]) { [weak self] web, _ in
            MainActor.assumeIsolated {
                guard let self, web.isLoading else { return }
                let controller = web.configuration.userContentController
                for script in self.scripts where !controller.userScripts.contains(where: { $0 === script }) {
                    controller.addUserScript(script)
                }
            }
        }
        // The page already up: the main frame gets both now (already there,
        // the observer just sends everything again). Frames already loaded
        // are found on their next navigation.
        web.evaluateJavaScript(Self.hooksScript, in: nil, in: .page, completionHandler: nil)
        web.evaluateJavaScript(Self.observeScript, in: nil, in: Self.world, completionHandler: nil)
    }

    /// The tool put away: the reports stop and the scripts come out of the
    /// tab. The observer already in the page keeps logging, so reopening
    /// the tool picks up what happened meanwhile.
    func stop() {
        hoverTask?.cancel()
        loading?.invalidate()
        loading = nil
        if let web = observedWeb {
            let controller = web.configuration.userContentController
            controller.removeScriptMessageHandler(forName: Self.handlerName, contentWorld: Self.world)
            if controller.userScripts.contains(where: { script in scripts.contains { $0 === script } }) {
                // WebKit takes user scripts out all at once; the tab's go back.
                let others = controller.userScripts.filter { script in !scripts.contains { $0 === script } }
                controller.removeAllUserScripts()
                others.forEach(controller.addUserScript)
            }
            if hovered != nil { session?.hideHighlight() }
        }
        hovered = nil
        scripts = []
        relay = nil
        observedWeb = nil
        listening = false
    }

    private func received(_ body: Any, frame: WKFrameInfo) {
        guard let message = body as? [String: Any], let doc = message["doc"] as? String else { return }
        let top = (message["top"] as? NSNumber)?.boolValue ?? frame.isMainFrame
        switch message["kind"] as? String {
        case "hello":
            frames[doc] = frame
            if top, doc != topDocument {
                // A new page: what was found belongs to the old one.
                topDocument = doc
                let kept = players.filter { $0.document == doc }
                let ids = Set(kept.map(\.id))
                players = kept
                logs = logs.filter { ids.contains($0.key) }
                lastSeq = lastSeq.filter { ids.contains($0.key) }
                frames = frames.filter { $0.key == doc }
                if let selection, !ids.contains(selection) { self.selection = nil }
            }
        case "gone":
            guard !top else { return }
            remove(document: doc)
        case "players":
            frames[doc] = frame
            if top, topDocument == nil { topDocument = doc }
            for raw in message["players"] as? [[String: Any]] ?? [] {
                guard let id = raw["id"] as? String else { continue }
                var player = players.first { $0.id == id } ?? DeveloperMediaPlayer(id: id, document: doc)
                player.update(raw)
                if let index = players.firstIndex(where: { $0.id == id }) {
                    if players[index] != player { players[index] = player }
                } else {
                    players.append(player)
                }
                let fresh = (raw["events"] as? [[String: Any]] ?? []).compactMap(DeveloperMediaEvent.init)
                    .filter { $0.seq > (lastSeq[id] ?? 0) }
                if !fresh.isEmpty {
                    var log = logs[id] ?? DeveloperMediaEventLog(capacity: Self.eventLimit)
                    log.append(contentsOf: fresh)
                    logs[id] = log
                    lastSeq[id] = fresh.map(\.seq).max()
                }
            }
        default:
            return
        }
    }

    private func remove(document doc: String) {
        let gone = Set(players.filter { $0.document == doc }.map(\.id))
        guard !gone.isEmpty else { frames[doc] = nil; return }
        players.removeAll { gone.contains($0.id) }
        logs = logs.filter { !gone.contains($0.key) }
        lastSeq = lastSeq.filter { !gone.contains($0.key) }
        frames[doc] = nil
        if let selection, gone.contains(selection) { self.selection = nil }
    }

    /// The toolbar's clear: the selected player's events.
    func clearEvents(_ id: String) {
        logs[id]?.removeAll()
    }

    /// Players forgotten until the page reports them again.
    func clearPlayers() {
        players = []
        logs = [:]
        selection = nil
    }

    // MARK: Elements

    private var hovered: String?

    /// The player's element as an inspector node: the observer marks it
    /// with an attribute, the page's world finds it (in the document or a
    /// same-origin frame), and the mark comes off.
    private func node(_ id: String) async -> Int? {
        guard let session, session.ready, let web = observedWeb ?? session.web,
              let player = players.first(where: { $0.id == id }), player.connected,
              let frame = frames[player.document] else { return nil }
        let marked = try? await web.callAsyncJavaScript(
            "const m = window[Symbol.for('perch.media')]; return m ? m.mark(id) : false;",
            arguments: ["id": id], in: frame, contentWorld: Self.world)
        guard let token = marked as? String,
              let quoted = try? JSONSerialization.data(withJSONObject: [token]),
              let literal = String(data: quoted, encoding: .utf8) else { return nil }
        defer {
            web.callAsyncJavaScript("const m = window[Symbol.for('perch.media')]; return m ? m.unmark() : false;",
                                    arguments: [:], in: frame, in: Self.world, completionHandler: nil)
        }
        let expression = """
            (() => { const token = \(literal)[0]; const look = (d) => {
                const el = d.querySelector('[data-perch-media="' + token + '"]'); if (el) return el;
                for (const f of d.querySelectorAll('iframe, frame')) {
                    try { const found = f.contentDocument && look(f.contentDocument); if (found) return found; } catch (e) {}
                }
                return null; }; return look(document); })()
            """
        let target = session.runtimeTargetID
        guard let reply = try? await session.command("Runtime.evaluate", [
            "expression": expression, "objectGroup": Self.objectGroup,
            "doNotPauseOnExceptionsAndMuteConsole": true, "includeCommandLineAPI": false,
        ], targetID: target),
            let object = (reply["result"] as? [String: Any])?["objectId"] as? String else { return nil }
        let node = try? await session.command("DOM.requestNode", ["objectId": object], targetID: session.domTargetID)
        _ = try? await session.command("Runtime.releaseObject", ["objectId": object], targetID: target)
        guard let nodeID = (node?["nodeId"] as? NSNumber)?.intValue, nodeID > 0 else { return nil }
        return nodeID
    }

    /// A player hovered in the list: its element drawn on the page as
    /// Elements draws a hovered node; nil hides it.
    func hover(_ id: String?) {
        guard id != hovered else { return }
        hovered = id
        hoverTask?.cancel()
        guard let session else { return }
        guard let id else { session.hideHighlight(); return }
        hoverTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled, let node = await self?.node(id), !Task.isCancelled else { return }
            session.highlightNode(node)
        }
    }

    /// Shows the player's element in the Elements panel, once the panel
    /// has read the document afresh (as the CSS overview's reveal does).
    func reveal(_ id: String) {
        guard let session else { return }
        hoverTask?.cancel()
        hovered = nil
        session.hideHighlight()
        let switching = session.panel != .elements
        let before = session.root
        session.select(.elements)
        Task { [weak self] in
            for _ in 0..<40 where switching {
                guard session.root == before || session.root == nil else { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard let node = await self?.node(id) else {
                self?.problem = "This player’s element isn’t in a document DevTools can reach."
                return
            }
            for _ in 0..<40 where session.nodes[node] == nil {
                try? await Task.sleep(for: .milliseconds(50))
            }
            session.selectNode(node)
        }
    }

    func dismissProblem() { problem = nil }
}

/// The page scripts' reports, to the model, from every frame; WebKit
/// holds this strongly.
final class DeveloperMediaRelay: NSObject, WKScriptMessageHandler {
    private let receive: @MainActor (Any, WKFrameInfo, WKWebView?) -> Void

    init(_ receive: @escaping @MainActor (Any, WKFrameInfo, WKWebView?) -> Void) {
        self.receive = receive
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body
        let frame = message.frameInfo
        let web = message.webView
        MainActor.assumeIsolated { receive(body, frame, web) }
    }
}
