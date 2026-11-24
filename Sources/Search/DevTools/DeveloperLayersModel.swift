import Foundation
import SwiftUI

/// The Layers drawer tool's state: the page's layers, read again whenever
/// WebKit says the layer tree changed, and the selected layer's
/// compositing reasons. One per DevTools session, kept while the drawer
/// tab is closed and reopened.
@MainActor
final class DeveloperLayers: ObservableObject {
    @Published private(set) var layers: [DeveloperLayer] = []
    /// Each layer's parent layer, by DOM nesting.
    @Published private(set) var parents: [String: String] = [:]
    /// Each node's label, by node id.
    @Published private(set) var labels: [Int: String] = [:]
    @Published var selection: String? { didSet { if selection != oldValue { loadReasons() } } }
    /// Hovered in the list or the diagram; drawn on the page too.
    @Published private(set) var hovered: String?
    @Published private(set) var reasons: [String: [String]] = [:]
    @Published private(set) var problem: String?
    @Published private(set) var loading = false
    @Published private(set) var loaded = false

    static let install = DevToolsResources.script("DeveloperLayers-install.js")
    private static let objectGroup = "perch-layers"
    /// More layers than this aren't labelled one by one.
    private static let labelLimit = 600

    private weak var session: DeveloperToolsSession?
    private var poll: Task<Void, Never>?
    private var fetching: Task<Void, Never>?
    private var enabledTarget: String??
    private var address: URL?
    private var seenChanges = -1
    /// No frontend hook (an older WebKit): read the layers every few seconds instead.
    private var hookless = false
    private var lastFetch = Date.distantPast
    private var lastRoot: Int?

    static func model(for session: DeveloperToolsSession) -> DeveloperLayers {
        DeveloperSessionModels.model(for: session, make: DeveloperLayers.init)
    }

    private init(session: DeveloperToolsSession) {
        self.session = session
    }

    var selectedLayer: DeveloperLayer? { layers.first { $0.id == selection } }

    func label(_ layer: DeveloperLayer) -> String {
        DeveloperLayerTree.label(layer, node: labels[layer.nodeId])
    }

    // MARK: Listening

    func start() {
        guard poll == nil else { return }
        // Ends with the model, not only on stop().
        poll = developerPoll(every: .milliseconds(400)) { [weak self] in await self?.tick() != nil }
    }

    func stop() {
        poll?.cancel()
        poll = nil
        hover(nil)
    }

    private func tick() async {
        guard let session, session.ready else { return }
        if session.address != address {
            if address != nil { reset() }
            address = session.address
        }
        let target = session.domTargetID
        if enabledTarget != .some(target) {
            if enabledTarget != nil { reset() }
            // WebKit's own frontend enables the domain too; a refusal of a
            // second enable is no problem.
            _ = try? await session.command("LayerTree.enable", targetID: target)
            enabledTarget = .some(target)
            seenChanges = -1
        }
        var changed = !loaded
        // The document read again renumbers its nodes: label them afresh.
        if session.root != lastRoot {
            lastRoot = session.root
            labels = [:]
            changed = true
        }
        if !hookless {
            do {
                let raw = try await session.evaluateInFrontend(
                    Self.install + "\nreturn {fresh, changes: perchLayers.changes()};") as? [String: Any] ?? [:]
                if raw["fresh"] as? Bool == true {
                    _ = try? await session.command("LayerTree.enable", targetID: target)
                    changed = true
                }
                let count = (raw["changes"] as? NSNumber)?.intValue ?? 0
                if count != seenChanges { changed = true; seenChanges = count }
            } catch is CancellationError {
                return
            } catch {
                hookless = true
            }
        }
        if hookless, Date().timeIntervalSince(lastFetch) > 2.5 { changed = true }
        // Changes come in bursts while a page animates: at most twice a second.
        if changed, fetching == nil, Date().timeIntervalSince(lastFetch) > 0.5 { read() }
    }

    /// Reads every layer again, now, and the selected one's reasons:
    /// the toolbar's Refresh.
    func refresh() {
        reasons = [:]
        if fetching == nil { loadReasons() }
        read()
    }

    private func read() {
        guard let session, session.ready, fetching == nil else { return }
        loading = true
        lastFetch = Date()
        fetching = Task { [weak self] in
            defer {
                self?.fetching = nil
                self?.loading = false
            }
            do {
                try await self?.fetch(session)
                self?.problem = nil
            } catch is CancellationError {
            } catch {
                self?.problem = error.localizedDescription
            }
        }
    }

    private func fetch(_ session: DeveloperToolsSession) async throws {
        let target = session.domTargetID
        guard let document = try await documentNode(session) else {
            throw DeveloperPanelError("The page’s document isn’t available yet. Open the Elements panel and try again.")
        }
        let reply = try await session.command("LayerTree.layersForNode", ["nodeId": document], targetID: target)
        let found = DeveloperLayerTree.layers(reply["layers"] as? [[String: Any]] ?? [])
        let changedNodes = Set(found.map(\.nodeId)) != Set(layers.map(\.nodeId))
        var info: (labels: [Int: String], parents: [String: String])?
        if changedNodes || labels.isEmpty {
            info = await describe(found, session: session)
        }
        guard !Task.isCancelled else { return }
        if let info {
            labels = info.labels
            parents = info.parents
        } else {
            // Same nodes: the nesting is the same, but layer ids may not be.
            parents = DeveloperLayerTree.parents(found, nodes: nodeInfo, order: nodeOrder)
        }
        if found != layers {
            layers = found
            // A layer gone has no reasons; the rest keep theirs until Refresh.
            let present = Set(found.map(\.id))
            reasons = reasons.filter { present.contains($0.key) }
            if let selection, !found.contains(where: { $0.id == selection }) { self.selection = nil }
            if let selection, reasons[selection] == nil { loadReasons() }
        }
        loaded = true
    }

    /// The document's node id: the Elements panel's, else asked for by
    /// the page's own `document`.
    private func documentNode(_ session: DeveloperToolsSession) async throws -> Int? {
        if let root = session.root { return root }
        let evaluated = try await session.command("Runtime.evaluate", [
            "expression": "document", "objectGroup": Self.objectGroup,
        ], targetID: session.runtimeTargetID)
        guard let object = evaluated["result"] as? [String: Any], let id = object["objectId"] as? String else { return nil }
        let node = try? await session.command("DOM.requestNode", ["objectId": id], targetID: session.domTargetID)
        _ = try? await session.command("Runtime.releaseObject", ["objectId": id], targetID: session.runtimeTargetID)
        guard let nodeID = (node?["nodeId"] as? NSNumber)?.intValue, nodeID > 0 else { return nil }
        return nodeID
    }

    private var nodeInfo: [Int: DeveloperLayerNodeInfo] = [:]
    private var nodeOrder: [Int] = []

    /// Every layer's node labelled, and which of them contains which, in
    /// one call to the page.
    private func describe(_ layers: [DeveloperLayer], session: DeveloperToolsSession) async -> (labels: [Int: String], parents: [String: String]) {
        let target = session.domTargetID
        var order: [Int] = []
        var seen = Set<Int>()
        for layer in layers where layer.nodeId > 0 && seen.insert(layer.nodeId).inserted { order.append(layer.nodeId) }
        order = Array(order.prefix(Self.labelLimit))
        var objects: [(node: Int, object: String)] = []
        for node in order {
            if let reply = try? await session.command("DOM.resolveNode", ["nodeId": node, "objectGroup": Self.objectGroup], targetID: target),
               let object = (reply["object"] as? [String: Any])?["objectId"] as? String {
                objects.append((node, object))
            }
        }
        var info: [Int: DeveloperLayerNodeInfo] = [:]
        if let first = objects.first {
            let reply = try? await session.command("Runtime.callFunctionOn", [
                "objectId": first.object, "functionDeclaration": Self.describeFunction,
                "arguments": objects.map { ["objectId": $0.object] }, "returnByValue": true,
            ], targetID: target)
            let values = (reply?["result"] as? [String: Any])?["value"] as? [[String: Any]] ?? []
            for (index, value) in values.enumerated() where index < objects.count {
                let parent = (value["parent"] as? NSNumber)?.intValue
                info[objects[index].node] = DeveloperLayerNodeInfo(label: value["label"] as? String ?? "",
                                                                  parent: parent.flatMap { $0 >= 0 ? $0 : nil })
            }
        }
        _ = try? await session.command("Runtime.releaseObjectGroup", ["objectGroup": Self.objectGroup], targetID: target)
        // Parents are indices into the objects that resolved.
        let resolvedOrder = objects.map(\.node)
        var labels: [Int: String] = [:]
        for node in order {
            if let label = info[node]?.label, !label.isEmpty {
                labels[node] = label
            } else if let name = session.nodes[node]?.name {
                labels[node] = name.lowercased()
            }
        }
        nodeInfo = info
        nodeOrder = resolvedOrder
        return (labels, DeveloperLayerTree.parents(layers, nodes: info, order: resolvedOrder))
    }

    // MARK: Selection and hover

    private func loadReasons() {
        guard let session, let id = selection, reasons[id] == nil else { return }
        let target = session.domTargetID
        Task { [weak self] in
            do {
                let reply = try await session.command("LayerTree.reasonsForCompositingLayer", ["layerId": id], targetID: target)
                self?.reasons[id] = DeveloperLayerReasons.labels(reply["compositingReasons"] as? [String: Any] ?? [:])
            } catch {
                self?.reasons[id] = []
            }
        }
    }

    /// A layer hovered in the list or the diagram: its node drawn on the
    /// page as Elements draws a hovered node; nil hides it.
    func hover(_ id: String?) {
        guard id != hovered else { return }
        hovered = id
        guard let session else { return }
        if let id, let layer = layers.first(where: { $0.id == id }), layer.nodeId > 0 {
            session.highlightNode(layer.nodeId)
        } else {
            session.hideHighlight()
        }
    }

    func reveal(_ layer: DeveloperLayer) {
        guard let session, layer.nodeId > 0 else { return }
        session.select(.elements)
        session.selectNode(layer.nodeId)
    }

    /// The page moved on: what was read belongs to the old one.
    private func reset() {
        fetching?.cancel()
        fetching = nil
        layers = []
        parents = [:]
        labels = [:]
        reasons = [:]
        selection = nil
        hovered = nil
        nodeInfo = [:]
        nodeOrder = []
        loaded = false
        enabledTarget = nil
        seenChanges = -1
    }

    /// Run with the layers' nodes as arguments: each one's label and the
    /// index of its nearest ancestor among them (crossing shadow roots).
    private static let describeFunction = """
        function(...nodes) {
            const index = new Map();
            nodes.forEach((node, i) => { if (node && !index.has(node)) index.set(node, i); });
            const label = (node) => {
                if (!node) return "";
                if (node.nodeType === 9) return "#document";
                if (node.nodeType !== 1) return (node.nodeName || "").toLowerCase();
                let text = (node.localName || node.nodeName || "").toLowerCase();
                if (node.id) text += "#" + node.id;
                const classes = node.classList ? Array.from(node.classList).slice(0, 3) : [];
                if (classes.length) text += "." + classes.join(".");
                return text.slice(0, 160);
            };
            return nodes.map((node) => {
                let parent = -1;
                let up = node ? (node.parentNode || node.host || null) : null;
                for (let steps = 0; up && steps < 10000; steps++) {
                    if (index.has(up)) { parent = index.get(up); break; }
                    up = up.parentNode || up.host || (up.defaultView && up.defaultView.frameElement) || null;
                }
                return {label: label(node), parent};
            });
        }
        """
}
