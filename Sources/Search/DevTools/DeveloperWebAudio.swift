import Foundation
import WebKit

// Chrome DevTools' More tools › WebAudio: the page's audio contexts, each
// one's properties and its graph of nodes. WebKit's inspector protocol has
// no WebAudio domain, so DeveloperWebAudio-hooks.js goes into the page's
// world while the tool is open and reports what the page builds.

/// One AudioParam of a node, as the graph draws it: an input a source can
/// connect to.
struct DeveloperWebAudioParam: Equatable, Identifiable {
    var id: String { name }
    let name: String
    var value: Double?
    var defaultValue: Double?
    var minValue: Double?
    var maxValue: Double?
    var rate: String
}

struct DeveloperWebAudioNode: Equatable, Identifiable {
    let id: String
    var type: String
    var channelCount: Int?
    var channelCountMode: String
    var channelInterpretation: String
    var inputs: Int
    var outputs: Int
    var params: [DeveloperWebAudioParam]

    init(id: String, type: String, channelCount: Int? = 2, channelCountMode: String = "max",
         channelInterpretation: String = "speakers", inputs: Int = 1, outputs: Int = 1,
         params: [DeveloperWebAudioParam] = []) {
        self.id = id
        self.type = type
        self.channelCount = channelCount
        self.channelCountMode = channelCountMode
        self.channelInterpretation = channelInterpretation
        self.inputs = inputs
        self.outputs = outputs
        self.params = params
    }
}

/// A connection: from a source node's output to a destination node's
/// input, or, with `param`, to one of the destination's AudioParams.
struct DeveloperWebAudioEdge: Hashable {
    let source: String
    let output: Int
    let destination: String
    let input: Int
    let param: String?

    init(source: String, output: Int = 0, destination: String, input: Int = 0, param: String? = nil) {
        self.source = source
        self.output = output
        self.destination = destination
        self.input = param == nil ? input : 0
        self.param = param
    }
}

/// A context's nodes and connections, kept as AudioNode.connect and
/// disconnect change them.
struct DeveloperWebAudioGraph: Equatable {
    static let nodeLimit = 2_000
    private(set) var nodes: [DeveloperWebAudioNode] = []
    private(set) var edges: [DeveloperWebAudioEdge] = []

    func node(_ id: String) -> DeveloperWebAudioNode? { nodes.first { $0.id == id } }

    /// A node the page made, or the same node described again.
    mutating func add(_ node: DeveloperWebAudioNode) {
        if let index = nodes.firstIndex(where: { $0.id == node.id }) {
            nodes[index] = node
        } else if nodes.count < Self.nodeLimit {
            nodes.append(node)
        }
    }

    /// A node's parameter values read again.
    mutating func update(_ id: String, values: [String: Double]) {
        guard let index = nodes.firstIndex(where: { $0.id == id }) else { return }
        for (offset, param) in nodes[index].params.enumerated() {
            if let value = values[param.name] { nodes[index].params[offset].value = value }
        }
    }

    /// A node the page let go of, with its connections.
    mutating func remove(_ id: String) {
        nodes.removeAll { $0.id == id }
        edges.removeAll { $0.source == id || $0.destination == id }
    }

    /// node.connect(destination, output, input) or node.connect(param,
    /// output). A second identical connection is the same one, as in Web
    /// Audio; one to a node or param not in the graph is left out.
    mutating func connect(_ edge: DeveloperWebAudioEdge) {
        guard node(edge.source) != nil, let destination = node(edge.destination) else { return }
        if let param = edge.param, !destination.params.contains(where: { $0.name == param }) { return }
        if !edges.contains(edge) { edges.append(edge) }
    }

    /// node.disconnect(…) in each of its forms: no arguments takes every
    /// connection from the node; an output alone, those from that output;
    /// a destination (node or param), those to it, narrowed by output and
    /// then input when they're given.
    mutating func disconnect(source: String, output: Int? = nil, destination: String? = nil,
                             input: Int? = nil, param: String? = nil) {
        edges.removeAll { edge in
            guard edge.source == source else { return false }
            if let output, edge.output != output { return false }
            guard let destination else { return true }
            guard edge.destination == destination, edge.param == param else { return false }
            if param == nil, let input, edge.input != input { return false }
            return true
        }
    }

    /// Where each node goes when drawn: left to right by how far it is from
    /// a node nothing feeds (a feedback loop doesn't push it further out),
    /// top to bottom in the order the page made them.
    func columns() -> [[DeveloperWebAudioNode]] {
        let ids = Set(nodes.map(\.id))
        var outgoing: [String: [String]] = [:]
        for edge in edges where edge.source != edge.destination && ids.contains(edge.source) && ids.contains(edge.destination) {
            outgoing[edge.source, default: []].append(edge.destination)
        }
        // A depth-first walk from the sources: an edge back to a node still
        // being walked closes a loop and is left out of the depths.
        var visiting = Set<String>()
        var done = Set<String>()
        var finished: [String] = []
        var forward: [String: [String]] = [:]
        func visit(_ id: String) {
            visiting.insert(id)
            for next in outgoing[id] ?? [] where !visiting.contains(next) {
                forward[id, default: []].append(next)
                if !done.contains(next) { visit(next) }
            }
            visiting.remove(id)
            done.insert(id)
            finished.append(id)
        }
        let fed = Set(outgoing.values.joined())
        for node in nodes where !fed.contains(node.id) && !done.contains(node.id) { visit(node.id) }
        for node in nodes where !done.contains(node.id) { visit(node.id) }
        // Reversed, the walk's finishing order puts every node after those
        // that feed it.
        var depth: [String: Int] = [:]
        for id in finished.reversed() {
            let next = (depth[id] ?? 0) + 1
            for destination in forward[id] ?? [] { depth[destination] = max(depth[destination] ?? 0, next) }
        }
        var columns: [[DeveloperWebAudioNode]] = []
        for node in nodes {
            let column = depth[node.id] ?? 0
            while columns.count <= column { columns.append([]) }
            columns[column].append(node)
        }
        return columns.filter { !$0.isEmpty }
    }
}

struct DeveloperWebAudioContext: Equatable, Identifiable {
    let id: String
    /// "realtime" or "offline".
    var type: String
    var state: String
    var sampleRate: Double?
    var currentTime: Double?
    var baseLatency: Double?
    var outputLatency: Double?
    var maxChannelCount: Int?
    var graph = DeveloperWebAudioGraph()

    var title: String {
        (type == "offline" ? "OfflineAudioContext" : "AudioContext") + " (" + String(id.suffix(6)) + ")"
    }
}

/// The WebAudio tool's state for one DevTools session. From the first time
/// the tool opens until DevTools closes, the hooks are in the tab (kept
/// through navigations, in every frame) and their reports come here.
@MainActor
final class DeveloperWebAudioModel: ObservableObject {
    @Published private(set) var contexts: [DeveloperWebAudioContext] = []
    @Published var selection: String?
    @Published private(set) var problem: String?
    @Published private(set) var listening = false
    /// Frames whose capture has reported in (for tests).
    private(set) var reportedFrames = 0

    static let handlerName = "perchWebAudio"
    static let hooksScript = DevToolsResources.script("DeveloperWebAudio-hooks.js")
    private static let contextLimit = 64
    private static let frameLimit = 64

    static func source(token: UUID) -> String { "(\(hooksScript))('\(token.uuidString)')" }

    private weak var session: DeveloperToolsSession?
    private weak var observedWeb: WKWebView?
    private var script: WKUserScript?
    /// New for each start, so a capture left in a frame from before is
    /// replaced rather than taken for this one.
    private var token = UUID()
    private var frames: [String: WKFrameInfo] = [:]
    private var frameOrder: [String] = []
    private var mainDocument: String?
    /// Which context each node is in.
    private var nodeContexts: [String: String] = [:]

    private static var models: [ObjectIdentifier: (session: WeakSession, model: DeveloperWebAudioModel)] = [:]
    struct WeakSession { weak var value: DeveloperToolsSession? }
    /// One message handler per content controller, shared by the models on
    /// it: adding a second handler with the same name raises.
    private static var relays: [ObjectIdentifier: Relay] = [:]

    static func model(for session: DeveloperToolsSession) -> DeveloperWebAudioModel {
        for (key, entry) in models where entry.session.value == nil {
            entry.model.stop()
            models[key] = nil
        }
        let key = ObjectIdentifier(session)
        if let found = models[key], found.session.value === session { return found.model }
        let model = DeveloperWebAudioModel(session: session)
        models[key] = (WeakSession(value: session), model)
        return model
    }

    /// DevTools closed: the hooks come out of the tab.
    static func closed(_ session: DeveloperToolsSession) {
        guard let found = models.removeValue(forKey: ObjectIdentifier(session)) else { return }
        found.model.stop()
    }

    private init(session: DeveloperToolsSession) { self.session = session }

    var selected: DeveloperWebAudioContext? {
        contexts.first { $0.id == selection } ?? contexts.first
    }

    // MARK: Listening

    func start() {
        guard let web = session?.web else {
            problem = "The inspected page isn’t available."
            return
        }
        if observedWeb !== web { stop() }
        guard script == nil else { return }
        problem = nil
        token = UUID()
        let content = web.configuration.userContentController
        let source = Self.source(token: token)
        let script = WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
        self.script = script
        observedWeb = web
        Self.relay(for: content).owners[token] = Owner(value: self)
        content.addUserScript(script)
        ArmedRiders.add(script, to: content)
        listening = true
        // The current document gets the hooks now. Existing subframes get them
        // at their next navigation, since WKWebView doesn't list their frames.
        web.evaluateJavaScript(source, in: nil, in: .page, completionHandler: nil)
    }

    private static func relay(for content: WKUserContentController) -> Relay {
        let id = ObjectIdentifier(content)
        if let relay = relays[id], relay.content === content { return relay }
        let relay = Relay(content)
        relays[id] = relay
        content.add(relay, contentWorld: .page, name: handlerName)
        return relay
    }

    func stop() {
        guard let script else { return }
        self.script = nil
        ArmedRiders.remove(script)
        let token = self.token
        defer {
            frames.removeAll()
            frameOrder.removeAll()
            mainDocument = nil
            nodeContexts.removeAll()
            contexts = []
            selection = nil
            observedWeb = nil
            listening = false
        }
        guard let web = observedWeb else { return }
        let content = web.configuration.userContentController
        let id = ObjectIdentifier(content)
        if let relay = Self.relays[id], relay.content === content {
            relay.owners[token] = nil
            if relay.owners.values.allSatisfy({ $0.value == nil }) {
                Self.relays[id] = nil
                content.removeScriptMessageHandler(forName: Self.handlerName, contentWorld: .page)
            }
        }
        if content.userScripts.contains(where: { $0 === script }) {
            // WebKit takes user scripts out all at once; the tab's go back.
            let kept = content.userScripts.filter { $0 !== script }
            content.removeAllUserScripts()
            kept.forEach(content.addUserScript)
        }
        let cleanup = """
            { const capture = globalThis[Symbol.for('perch.webAudioCapture')];
              if (capture?.owns?.('\(token.uuidString)')) capture.stop(); }
            """
        web.evaluateJavaScript(cleanup, in: nil, in: .page, completionHandler: nil)
        for frame in frames.values where !frame.isMainFrame {
            web.evaluateJavaScript(cleanup, in: frame, in: .page, completionHandler: nil)
        }
    }

    func dismissProblem() { problem = nil }

    // MARK: Reports

    private func receive(_ message: WKScriptMessage) {
        guard script != nil, let web = observedWeb, message.webView === web,
              let body = message.body as? [String: Any], body["session"] as? String == token.uuidString,
              let frame = body["frame"] as? String, frame.count <= 40,
              let events = body["events"] as? [[String: Any]] else { return }
        remember(frame, message.frameInfo)
        apply(events, frame: frame, isMainFrame: message.frameInfo.isMainFrame)
    }

    /// The frames to take the hooks out of when DevTools closes, kept by
    /// document, most recent last. A new page document takes the old one's
    /// contexts and subframes with it.
    private func remember(_ frame: String, _ info: WKFrameInfo) {
        if info.isMainFrame { return }
        if frames[frame] != nil { frameOrder.removeAll { $0 == frame } }
        frames[frame] = info
        frameOrder.append(frame)
        if frameOrder.count > Self.frameLimit {
            for id in frameOrder.prefix(frameOrder.count - Self.frameLimit) { frames[id] = nil }
            frameOrder.removeFirst(frameOrder.count - Self.frameLimit)
        }
    }

    /// One frame's batch of events, in the order the page made them.
    func apply(_ events: [[String: Any]], frame: String, isMainFrame: Bool) {
        reportedFrames += 1
        var contexts = self.contexts
        if isMainFrame, mainDocument != frame {
            mainDocument = frame
            contexts.removeAll()
            nodeContexts.removeAll()
            frames.removeAll()
            frameOrder.removeAll()
        }
        let prefix = frame + "-"
        func string(_ item: [String: Any], _ key: String) -> String? {
            guard let value = item[key] as? String, value.count <= 120 else { return nil }
            return value
        }
        func double(_ item: [String: Any], _ key: String) -> Double? {
            guard let value = item[key] as? Double, value.isFinite else { return nil }
            return value
        }
        func int(_ item: [String: Any], _ key: String) -> Int? {
            guard let value = double(item, key), value >= 0, value <= 1_000_000 else { return nil }
            return Int(value)
        }
        func ownID(_ item: [String: Any], _ key: String) -> String? {
            guard let id = string(item, key), id.hasPrefix(prefix) else { return nil }
            return id
        }
        func contextIndex(ofNode id: String) -> Int? {
            guard let context = nodeContexts[id] else { return nil }
            return contexts.firstIndex { $0.id == context }
        }
        for item in events.prefix(1_024) {
            switch item["kind"] as? String ?? "" {
            case "context":
                guard let id = ownID(item, "id") else { continue }
                if let index = contexts.firstIndex(where: { $0.id == id }) {
                    contexts[index].state = string(item, "state") ?? contexts[index].state
                    contexts[index].currentTime = double(item, "currentTime")
                    contexts[index].baseLatency = double(item, "baseLatency")
                    contexts[index].outputLatency = double(item, "outputLatency")
                    contexts[index].maxChannelCount = int(item, "maxChannelCount")
                    if let rate = double(item, "sampleRate") { contexts[index].sampleRate = rate }
                } else if contexts.count < Self.contextLimit {
                    contexts.append(DeveloperWebAudioContext(
                        id: id, type: string(item, "type") == "offline" ? "offline" : "realtime",
                        state: string(item, "state") ?? "", sampleRate: double(item, "sampleRate"),
                        currentTime: double(item, "currentTime"), baseLatency: double(item, "baseLatency"),
                        outputLatency: double(item, "outputLatency"), maxChannelCount: int(item, "maxChannelCount")))
                }
            case "contextGone":
                guard let id = ownID(item, "id") else { continue }
                contexts.removeAll { $0.id == id }
                nodeContexts = nodeContexts.filter { $0.value != id }
            case "node":
                guard let id = ownID(item, "id"), let context = ownID(item, "context"),
                      let index = contexts.firstIndex(where: { $0.id == context }) else { continue }
                let params = (item["params"] as? [[String: Any]] ?? []).prefix(64).compactMap { param -> DeveloperWebAudioParam? in
                    guard let name = string(param, "name"), !name.isEmpty else { return nil }
                    return DeveloperWebAudioParam(name: name, value: double(param, "value"),
                                                  defaultValue: double(param, "defaultValue"),
                                                  minValue: double(param, "minValue"), maxValue: double(param, "maxValue"),
                                                  rate: string(param, "rate") ?? "")
                }
                let type = string(item, "type").flatMap { $0.isEmpty ? nil : $0 } ?? "AudioNode"
                contexts[index].graph.add(DeveloperWebAudioNode(
                    id: id, type: type, channelCount: int(item, "channelCount"),
                    channelCountMode: string(item, "channelCountMode") ?? "",
                    channelInterpretation: string(item, "channelInterpretation") ?? "",
                    inputs: int(item, "inputs") ?? 0, outputs: int(item, "outputs") ?? 0, params: Array(params)))
                if contexts[index].graph.node(id) != nil { nodeContexts[id] = context }
            case "params":
                guard let id = ownID(item, "id"), let index = contextIndex(ofNode: id),
                      let raw = item["values"] as? [String: Any] else { continue }
                var values: [String: Double] = [:]
                for (name, value) in raw.prefix(64) {
                    if let number = (value as? NSNumber)?.doubleValue, number.isFinite { values[name] = number }
                }
                contexts[index].graph.update(id, values: values)
            case "nodeGone":
                guard let id = ownID(item, "id"), let index = contextIndex(ofNode: id) else { continue }
                contexts[index].graph.remove(id)
                nodeContexts[id] = nil
            case "connect":
                guard let source = ownID(item, "source"), let destination = ownID(item, "destination"),
                      let index = contextIndex(ofNode: source) else { continue }
                contexts[index].graph.connect(DeveloperWebAudioEdge(
                    source: source, output: int(item, "output") ?? 0, destination: destination,
                    input: int(item, "input") ?? 0, param: string(item, "param")))
            case "disconnect":
                guard let source = ownID(item, "source"), let index = contextIndex(ofNode: source) else { continue }
                contexts[index].graph.disconnect(source: source, output: int(item, "output"),
                                                 destination: ownID(item, "destination"),
                                                 input: int(item, "input"), param: string(item, "param"))
            default:
                continue
            }
        }
        if contexts != self.contexts { self.contexts = contexts }
        if let selection, !contexts.contains(where: { $0.id == selection }) { self.selection = nil }
    }

    private struct Owner {
        weak var value: DeveloperWebAudioModel?
    }

    private final class Relay: NSObject, WKScriptMessageHandler {
        weak var content: WKUserContentController?
        var owners: [UUID: Owner] = [:]
        init(_ content: WKUserContentController) { self.content = content }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            MainActor.assumeIsolated {
                for owner in owners.values { owner.value?.receive(message) }
            }
        }
    }
}
