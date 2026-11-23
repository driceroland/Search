import Foundation

/// Chrome's "Detached elements" profile: DOM nodes no longer in the
/// document that something still keeps alive. WebKit's heap snapshots
/// don't say whether a node is detached, so the Memory panel takes a
/// snapshot, picks the objects whose class is a DOM wrapper, resolves
/// each on the page (`Heap.getRemoteObject`) and asks it `isConnected`.
/// What's here is the pure part: which objects to ask about, what the
/// page's answer means, and grouping the detached ones as Chrome lists them.

/// What the page said about one DOM node of a snapshot.
struct DeveloperHeapDOMProbe: Equatable, Sendable {
    let connected: Bool
    /// The node's nodeName: "DIV", "svg", "#text".
    let nodeName: String
    let elementID: String
    /// The class attribute as written.
    let classes: String

    init(connected: Bool, nodeName: String = "", elementID: String = "", classes: String = "") {
        self.connected = connected
        self.nodeName = nodeName
        self.elementID = elementID
        self.classes = classes
    }

    /// The value `function` returns by value, or nil when it said the
    /// object isn't a node.
    init?(_ value: Any?) {
        guard let value = value as? [String: Any], let connected = value["connected"] as? Bool else { return nil }
        self.init(connected: connected, nodeName: value["name"] as? String ?? "",
                  elementID: value["id"] as? String ?? "", classes: value["classes"] as? String ?? "")
    }

    /// Run on each candidate with `this` the object: null for anything not
    /// a node (an element's prototype throws on `isConnected`), else
    /// whether it's in a document and, when it isn't, how to describe it.
    static let function = """
    function() {
        try {
            if (typeof this.isConnected !== "boolean" || typeof this.nodeType !== "number") return null;
            if (this.isConnected) return {connected: true};
            const element = this.nodeType === 1;
            return {
                connected: false,
                name: String(this.nodeName || ""),
                id: element ? String(this.id || "") : "",
                classes: element && this.getAttribute ? String(this.getAttribute("class") || "") : ""
            };
        } catch (e) { return null; }
    }
    """

    var description: String { Self.describe(nodeName: nodeName, id: elementID, classes: classes) }

    /// Chrome's way of naming a node: tag#id.class1.class2, the tag in
    /// lower case (an HTML element's nodeName is upper case), and
    /// "#text", "#comment" or "#document-fragment" for the rest.
    static func describe(nodeName: String, id: String, classes: String) -> String {
        let name = nodeName.isEmpty ? "(node)" : nodeName.hasPrefix("#") ? nodeName : nodeName.lowercased()
        var text = name
        let id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        if !id.isEmpty { text += "#" + id }
        for name in classes.split(whereSeparator: { $0.isWhitespace }) { text += "." + name }
        return text
    }
}

/// One row of Detached elements: the detached nodes that share a description.
struct DeveloperHeapDetachedGroup: Identifiable, Equatable, Sendable {
    let description: String
    /// Node indexes, largest retained size first.
    let nodes: [Int]
    /// What the group keeps alive, counting a node only when no other
    /// detached node already does (a detached subtree's children are
    /// dominated by its root), so nothing is counted twice.
    let retainedSize: Int
    var id: String { description }
    var count: Int { nodes.count }
}

/// A Detached elements profile: the groups, and how many nodes were asked.
struct DeveloperHeapDetachedReport: Sendable {
    let groups: [DeveloperHeapDetachedGroup]
    /// DOM nodes asked about.
    let checked: Int
    /// DOM nodes the snapshot had; more than `checked` when capped.
    let candidates: Int

    var detachedCount: Int { groups.reduce(0) { $0 + $1.count } }
    var truncated: Bool { checked < candidates }

    /// The detached nodes, by node index with their description, grouped
    /// by description: the most nodes first, then the largest retained.
    static func group(_ descriptions: [Int: String], retained: [Int], dominators: [Int],
                      root: Int) -> [DeveloperHeapDetachedGroup] {
        var byDescription: [String: [Int]] = [:]
        for (node, description) in descriptions { byDescription[description, default: []].append(node) }
        func retainedSize(_ node: Int) -> Int { retained.indices.contains(node) ? retained[node] : 0 }
        // A node another detached node dominates is inside what that one retains.
        func covered(_ node: Int) -> Bool {
            guard dominators.indices.contains(node) else { return false }
            var current = dominators[node], steps = 0
            while current >= 0, current != root, dominators.indices.contains(current), steps < dominators.count {
                if descriptions[current] != nil { return true }
                let next = dominators[current]
                if next == current { break }
                current = next
                steps += 1
            }
            return false
        }
        let groups = byDescription.map { description, nodes in
            let sorted = nodes.sorted { retainedSize($0) != retainedSize($1) ? retainedSize($0) > retainedSize($1) : $0 < $1 }
            let size = sorted.reduce(0) { $0 + (covered($1) ? 0 : retainedSize($1)) }
            return DeveloperHeapDetachedGroup(description: description, nodes: sorted, retainedSize: size)
        }
        return groups.sorted { a, b in
            if a.count != b.count { return a.count > b.count }
            if a.retainedSize != b.retainedSize { return a.retainedSize > b.retainedSize }
            return a.description.localizedStandardCompare(b.description) == .orderedAscending
        }
    }

    /// The groups whose description contains `filter`.
    func filtered(_ filter: String) -> [DeveloperHeapDetachedGroup] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        return query.isEmpty ? groups : groups.filter { $0.description.localizedCaseInsensitiveContains(query) }
    }
}

extension DeveloperHeapSnapshot {
    /// The most DOM nodes a Detached elements profile asks the page about.
    static let detachedProbeLimit = 4000

    /// Whether objects of a JavaScriptCore class are DOM node wrappers that
    /// can be detached: elements (HTML*, SVG*, MathML*, Element), text,
    /// comments, fragments and shadow roots. Documents are never detached.
    static func isDOMWrapperClassName(_ raw: String) -> Bool {
        let name = raw.hasPrefix("JS") && raw.count > 2 ? String(raw.dropFirst(2)) : raw
        if name == "Element" { return true }
        if name.hasSuffix("Element"), name.count > "Element".count,
           name.hasPrefix("HTML") || name.hasPrefix("SVG") || name.hasPrefix("MathML") { return true }
        switch name {
        case "Text", "Comment", "CDATASection", "ProcessingInstruction", "DocumentFragment", "ShadowRoot": return true
        default: return false
        }
    }

    /// Whether to ask the page if `node` is detached. Version 3 flags each
    /// element wrapper (custom elements included), so an unflagged
    /// "HTMLDivElement" there is the prototype and is skipped; older
    /// snapshots go by class name and the page sorts out prototypes.
    func isDetachedCandidate(_ node: Int) -> Bool {
        guard ids.indices.contains(node), node != root else { return false }
        if flags[node] & Self.elementSubtypeFlag != 0 { return true }
        let raw = classNames[classIndexes[node]]
        guard Self.isDOMWrapperClassName(raw) else { return false }
        return !(hasElementSubtypes && raw.hasSuffix("Element"))
    }

    /// The nodes to ask about, largest retained size first, at most
    /// `limit`, and how many there were in all.
    func detachedCandidates(limit: Int = Self.detachedProbeLimit) -> (nodes: [Int], total: Int) {
        let all = (0..<nodeCount).filter(isDetachedCandidate)
        let sorted = all.sorted { retained[$0] != retained[$1] ? retained[$0] > retained[$1] : ids[$0] < ids[$1] }
        return (Array(sorted.prefix(max(0, limit))), all.count)
    }

    /// The report for the page's answers, by node index.
    func detachedReport(probes: [Int: DeveloperHeapDOMProbe], checked: Int, candidates: Int) -> DeveloperHeapDetachedReport {
        var descriptions: [Int: String] = [:]
        for (node, probe) in probes where !probe.connected && ids.indices.contains(node) {
            descriptions[node] = probe.description
        }
        let groups = DeveloperHeapDetachedReport.group(descriptions, retained: retained, dominators: dominators, root: root)
        return DeveloperHeapDetachedReport(groups: groups, checked: checked, candidates: candidates)
    }
}
