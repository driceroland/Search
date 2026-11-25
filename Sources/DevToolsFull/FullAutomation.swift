import AppKit
import WebKit

/// The tools driven by name (SearchDevToolsPlugin.perform): what tests use.
/// Every answer is a property list; each command waits, at most a few
/// seconds, for what it asked to be read.
@MainActor
enum FullAutomation {
    static func perform(_ command: String, _ arguments: [String: Any], _ web: WKWebView?, plugin: FullPlugin,
                        completion: @escaping ([String: Any]) -> Void) {
        guard let web else { return completion(["error": "no page"]) }
        Task { @MainActor in completion(await run(command, arguments, web, plugin: plugin)) }
    }

    private static func run(_ command: String, _ arguments: [String: Any], _ web: WKWebView,
                            plugin: FullPlugin) async -> [String: Any] {
        let tools = DeveloperTools.shared
        func session() -> DeveloperToolsSession? { tools.session?.web === web ? tools.session : nil }
        switch command {
        case "open":
            plugin.open(arguments["item"] as? String ?? "devtools", webView: web)
            return ["open": plugin.isOpen(webView: web)]
        case "close":
            plugin.close(webView: web)
            return [:]
        case "state":
            let session = session()
            return ["open": plugin.isOpen(webView: web), "ready": session?.ready ?? false,
                    "failed": session?.connectionFailed ?? false, "message": session?.message ?? "",
                    "panel": session?.panel.rawValue ?? "", "scripts": plugin.scripts(webView: web).count,
                    "dock": plugin.dockView(webView: web) != nil]
        case "ready":
            guard let session = session() else { return ["error": "not open"] }
            let ready = await wait(10) { session.ready || session.connectionFailed }
            return ["ready": ready && session.ready, "message": session.message ?? ""]
        case "dock":
            if let position = DeveloperDockPosition(rawValue: arguments["position"] as? String ?? "") { tools.dockPosition = position }
            return ["position": tools.dockPosition.rawValue]
        case "select":
            guard let session = session(), let panel = DeveloperPanel(rawValue: arguments["panel"] as? String ?? "") else {
                return ["error": "no such panel"]
            }
            session.select(panel)
            return ["panel": session.panel.rawValue]

        // Elements
        case "elements.tree":
            guard let session = session() else { return ["error": "not open"] }
            session.select(.elements)
            _ = await wait(10) { session.root != nil && session.nodes.count > 3 }
            return ["nodes": session.nodes.values.filter { $0.type == 1 }.map { ["name": $0.name, "attributes": $0.attributes] }]
        case "elements.select":
            guard let session = session(), let selector = arguments["selector"] as? String else { return ["error": "not open"] }
            session.select(.elements)
            _ = await wait(10) { session.root != nil }
            guard let document = session.root,
                  let found = try? await session.command("DOM.querySelector", ["nodeId": document, "selector": selector],
                                                         targetID: session.domTargetID),
                  let id = (found["nodeId"] as? NSNumber)?.intValue, id > 0 else { return ["error": "no node"] }
            _ = await wait(5) { session.nodes[id] != nil }
            session.selectNode(id)
            _ = await wait(10) { session.selectedNode == id && !session.matchedStyles.isEmpty }
            return ["node": id, "rules": session.matchedStyles.map { rule in
                ["selector": rule.selector, "properties": rule.properties.map { $0.name + ": " + $0.value }]
            }]

        // Console
        case "console.evaluate":
            guard let session = session(), let expression = arguments["expression"] as? String else { return ["error": "not open"] }
            let before = session.console.count
            session.evaluate(expression)
            _ = await wait(10) { session.console.count >= before + 2 }
            return ["lines": session.console.suffix(4).map { ["level": $0.level, "text": $0.text] }]
        case "console.messages":
            guard let session = session() else { return ["error": "not open"] }
            session.select(.console)
            if let text = arguments["contains"] as? String {
                _ = await wait(10) { session.console.contains { $0.text.contains(text) } }
            }
            return ["lines": session.console.map { ["level": $0.level, "text": $0.text] }]

        // Network
        case "network.requests":
            guard let session = session() else { return ["error": "not open"] }
            session.select(.network)
            if let path = arguments["contains"] as? String {
                _ = await wait(10) { session.requests.contains { $0.url.contains(path) && $0.status != nil } }
            }
            return ["requests": session.requests.map {
                ["id": $0.id, "url": $0.url, "method": $0.method, "status": $0.status ?? 0, "type": $0.type]
            }]
        case "network.headers":
            guard let session = session(), let id = arguments["id"] as? String,
                  let details = await session.requestDetails(id) else { return ["error": "no request"] }
            return ["request": details.requestHeaders.map { [$0.name, $0.value] },
                    "response": details.responseHeaders.map { [$0.name, $0.value] }]

        // Sources
        case "sources.list":
            guard let session = session() else { return ["error": "not open"] }
            session.select(.sources)
            _ = await wait(10) { !session.resources.isEmpty }
            return ["files": session.resources.map(\.url)]
        case "sources.breakpoint":
            guard let session = session(), let url = arguments["url"] as? String, let line = arguments["line"] as? Int,
                  let resource = session.resources.first(where: { $0.url == url }) else { return ["error": "no file"] }
            session.openSource(resource)
            _ = await wait(10) { session.sourceResource?.url == url && session.source != nil }
            session.setBreakpoint(line: line)
            _ = await wait(10) { session.debugger.breakpoints.first?.protocolID != nil }
            if let trigger = arguments["trigger"] as? String {
                // Not awaited: the page stops at the breakpoint.
                web.evaluateJavaScript(trigger, in: nil, in: .page, completionHandler: nil)
            }
            let paused = await wait(10) { session.paused }
            let frames = session.callStack
            if paused {
                session.debugger.step("resume")
                _ = await wait(10) { !session.paused }
            }
            return ["breakpoints": session.breakpoints.sorted(), "paused": paused, "stack": frames]

        // Application
        case "application.read":
            guard let session = session(), let address = web.url,
                  let section = DeveloperApplicationSection(rawValue: arguments["section"] as? String ?? "") else {
                return ["error": "not open"]
            }
            session.select(.storage)
            var query = DeveloperApplicationQuery()
            query.section = section
            do {
                let snapshot = try await DeveloperApplication.read(query, in: session, address: address)
                return ["columns": snapshot.columns, "rows": snapshot.rows.map(\.values)]
            } catch {
                return ["error": error.localizedDescription]
            }

        // Performance
        case "performance.record":
            guard let session = session() else { return ["error": "not open"] }
            session.select(.performance)
            session.toggleTimeline()
            _ = await wait(5) { session.recordingTimeline }
            if let during = arguments["during"] as? String {
                _ = try? await web.evaluateJavaScript(during, in: nil, contentFor: .page)
            }
            try? await Task.sleep(for: .milliseconds(Int(arguments["milliseconds"] as? Int ?? 800)))
            session.toggleTimeline()
            _ = await wait(10) { !session.recordingTimeline }
            _ = await wait(5) { !session.timeline.isEmpty }
            return ["records": session.timeline.count, "types": Array(Set(session.timeline.map(\.type))).sorted()]

        // Memory
        case "memory.snapshot":
            guard let session = session() else { return ["error": "not open"] }
            session.select(.memory)
            let memory = session.memory
            let before = memory.snapshots.count
            memory.takeSnapshot()
            _ = await wait(30) { memory.snapshots.count > before || memory.message != nil }
            guard let entry = memory.snapshots.last, memory.snapshots.count > before else {
                return ["error": memory.message ?? "no snapshot"]
            }
            return ["nodes": entry.snapshot.nodeCount]

        default:
            return ["error": "unknown command"]
        }
    }

    /// Until `condition`, at most `seconds`; whether it came.
    private static func wait(_ seconds: Double, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }
}

private extension WKWebView {
    func evaluateJavaScript(_ source: String, in frame: WKFrameInfo?, contentFor world: WKContentWorld) async throws -> Any? {
        try await callAsyncJavaScript(source, arguments: [:], in: frame, contentWorld: world)
    }
}
