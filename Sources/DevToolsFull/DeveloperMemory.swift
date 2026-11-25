import Foundation

/// A heap snapshot as the Memory panel shows it, read from the JSON that
/// WebKit's `Heap.snapshot` returns (JavaScriptCore's HeapSnapshotBuilder):
///
///     {"version": 2, "type": "Inspector",
///      "nodes": [id, size, classNameIndex, flags, ...],
///      "nodeClassNames": [...],
///      "edges": [fromId, toId, edgeTypeIndex, edgeNameOrIndex, ...],
///      "edgeTypes": [...], "edgeNames": [...]}
///
/// The first node, id 0 and class "<root>", stands for the GC roots, with
/// an edge to each. A GCDebugging snapshot has three more fields per node
/// (label, cell address, wrapped address). Node ids are JavaScriptCore's
/// object identifiers, the same for an object in every snapshot of a
/// page, which is what Comparison matches on.
///
/// Parsing also builds the dominator tree, as Chrome does, so each object
/// has a retained size: its own size plus that of everything only it keeps
/// alive. Parse off the main thread; a big page has millions of nodes.
struct DeveloperHeapSnapshot: Sendable {
    let timestamp: Double
    /// Per node, in the snapshot's order.
    let ids: [Int]
    let sizes: [Int]
    let classIndexes: [Int]
    let flags: [Int]
    let classNames: [String]
    /// The node that stands for the GC roots.
    let root: Int
    /// Each node's immediate dominator; the root's is itself. Objects the
    /// roots can't reach are counted as held by the root, as Chrome does.
    let dominators: [Int]
    let retained: [Int]
    /// The summary, one row per class, in no order.
    let classes: [DeveloperHeapClass]
    /// Each class's nodes, by class index, largest retained size first.
    let instances: [[Int]]
    let indexByID: [Int: Int]
    /// The largest object id: what "Objects allocated before/between"
    /// compares other snapshots' objects with.
    let maxObjectID: Int
    private let retainerOffsets: [Int]
    private let retainerNodes: [Int]
    private let retainerLabels: [Int]
    /// Outgoing references in compressed rows, for Containment.
    private let childOffsets: [Int]
    private let childNodes: [Int]
    private let childLabels: [Int]
    private let edgeLabels: [String]
    private let distances: [Int]
    /// Version 3 or later: element wrappers carry `elementSubtypeFlag`.
    let hasElementSubtypes: Bool

    /// Every object's size: what Summary's percentages are of.
    var totalSize: Int { root < retained.count ? retained[root] : 0 }
    var nodeCount: Int { ids.count }

    enum ParseError: LocalizedError, Equatable {
        case malformed(String)
        /// A V8 snapshot saved from Chrome, which describes objects differently.
        case chromeFormat
        var errorDescription: String? {
            switch self {
            case .malformed(let why): "The heap snapshot couldn’t be read: \(why)."
            case .chromeFormat:
                "This heap snapshot was saved from Chrome. Search reads snapshots in WebKit’s format, such as ones saved from Search’s Memory panel."
            }
        }
    }

    /// Enough of a Chrome (V8) .heapsnapshot to recognise one:
    /// {"snapshot": {"meta": {...}, ...}, "nodes": [...], "strings": [...]}.
    private struct ChromeProbe: Decodable {
        struct Header: Decodable {
            struct Meta: Decodable {
                let nodeFields: [String]
                enum CodingKeys: String, CodingKey { case nodeFields = "node_fields" }
            }
            let meta: Meta
        }
        let snapshot: Header
    }

    /// The JSON's fields. Older snapshots may omit the edge labels.
    private struct Raw: Decodable {
        let version: Int?
        let type: String?
        let nodes: [Int]
        let nodeClassNames: [String]
        let edges: [Int]
        let edgeTypes: [String]?
        let edgeNames: [String]?
    }

    static let nodeFields = 4
    static let edgeFields = 4
    /// JavaScriptCore's node flags: bit 0 marks an internal object (one
    /// the engine made, not the page's script).
    static let internalFlag = 1
    /// Version 3 sets bit 2 on a DOM element.
    static let elementSubtypeFlag = 1 << 2

    init(json: String, timestamp: Double = 0) throws {
        try self.init(data: Data(json.utf8), timestamp: timestamp)
    }

    init(data: Data, timestamp: Double = 0) throws {
        let raw: Raw
        do { raw = try JSONDecoder().decode(Raw.self, from: data) }
        catch {
            if (try? JSONDecoder().decode(ChromeProbe.self, from: data)) != nil { throw ParseError.chromeFormat }
            throw ParseError.malformed("it isn’t JSON in JavaScriptCore’s format")
        }
        let stride = raw.type == "GCDebugging" ? 7 : Self.nodeFields
        guard raw.nodes.count % stride == 0 else { throw ParseError.malformed("its nodes are cut short") }
        let count = raw.nodes.count / stride
        guard count > 0 else { throw ParseError.malformed("it has no nodes") }
        var ids = [Int](repeating: 0, count: count)
        var sizes = [Int](repeating: 0, count: count)
        var classes = [Int](repeating: 0, count: count)
        var flags = [Int](repeating: 0, count: count)
        var indexByID = [Int: Int](minimumCapacity: count)
        let names = raw.nodeClassNames.isEmpty ? ["(unknown)"] : raw.nodeClassNames
        var maxID = 0
        for node in 0..<count {
            let at = node * stride
            ids[node] = raw.nodes[at]
            maxID = max(maxID, raw.nodes[at])
            sizes[node] = max(0, raw.nodes[at + 1])
            let name = raw.nodes[at + 2]
            classes[node] = names.indices.contains(name) ? name : 0
            flags[node] = raw.nodes[at + 3]
            indexByID[raw.nodes[at]] = node
        }
        let root = indexByID[0] ?? 0

        // Successors in compressed rows: node n's are targets[offsets[n]..<offsets[n + 1]].
        let edgeCount = raw.edges.count / Self.edgeFields
        var from = [Int](), to = [Int](), labels = [Int]()
        from.reserveCapacity(edgeCount)
        to.reserveCapacity(edgeCount)
        labels.reserveCapacity(edgeCount)
        let edgeTypes = raw.edgeTypes ?? []
        let edgeNames = raw.edgeNames ?? []
        let labelTable = edgeNames + edgeTypes + ["Internal"]
        for edge in 0..<edgeCount {
            let at = edge * Self.edgeFields
            guard let source = indexByID[raw.edges[at]], let target = indexByID[raw.edges[at + 1]] else { continue }
            from.append(source)
            to.append(target)
            let kind = raw.edges[at + 2], name = raw.edges[at + 3]
            guard edgeTypes.indices.contains(kind) else {
                labels.append(labelTable.count - 1)
                continue
            }
            switch edgeTypes[kind] {
            case "Index" where name >= 0:
                // The complement distinguishes an array index from a label.
                labels.append(~name)
            case "Property", "Variable":
                labels.append(edgeNames.indices.contains(name) ? name : edgeNames.count + kind)
            default:
                labels.append(edgeNames.count + kind)
            }
        }
        let graph = DeveloperHeapGraph(count: count, from: from, to: to)
        let (dominators, postorder) = graph.dominators(root: root)
        let retained = Self.retainedSizes(sizes: sizes, dominators: dominators, order: postorder, root: root)
        let summary = Self.summarize(classIndexes: classes, names: names, sizes: sizes,
                                     retained: retained, dominators: dominators, root: root)

        self.timestamp = timestamp
        self.ids = ids
        self.sizes = sizes
        self.classIndexes = classes
        self.flags = flags
        self.classNames = names
        self.root = root
        self.dominators = dominators
        self.retained = retained
        self.indexByID = indexByID
        self.maxObjectID = maxID
        self.classes = summary.0
        self.instances = summary.1
        self.retainerOffsets = graph.predecessorOffsets
        self.retainerNodes = graph.predecessors
        self.retainerLabels = graph.orderByRetainedNode(targets: to, values: labels)
        self.childOffsets = graph.successorOffsets
        self.childNodes = graph.successors
        self.childLabels = graph.orderBySource(sources: from, values: labels)
        self.edgeLabels = labelTable
        self.distances = graph.distances(from: root)
        self.hasElementSubtypes = (raw.version ?? 0) >= 3
    }

    /// A node's own size plus its dominator subtree's, adding each node to
    /// its dominator in postorder (a node always comes before its dominator).
    static func retainedSizes(sizes: [Int], dominators: [Int], order: [Int], root: Int) -> [Int] {
        var retained = sizes
        for node in order where node != root {
            let dominator = dominators[node]
            if dominator >= 0, dominator != node { retained[dominator] += retained[node] }
        }
        return retained
    }

    /// Count, shallow and retained size per class. As in Chrome, a class's
    /// retained size counts an object only when no object of the same class
    /// dominates it, so nested instances aren't counted twice.
    static func summarize(classIndexes: [Int], names: [String], sizes: [Int], retained: [Int],
                          dominators: [Int], root: Int, including: [Bool]? = nil) -> ([DeveloperHeapClass], [[Int]]) {
        let count = classIndexes.count
        var counts = [Int](repeating: 0, count: names.count)
        var shallow = [Int](repeating: 0, count: names.count)
        var classRetained = [Int](repeating: 0, count: names.count)
        var instances = [[Int]](repeating: [], count: names.count)
        for node in 0..<count where node != root && including?[node] != false {
            let name = classIndexes[node]
            counts[name] += 1
            shallow[name] += sizes[node]
            instances[name].append(node)
        }

        // The dominator tree's children, then a walk down it that knows
        // which classes are already on the path from the root.
        var childCounts = [Int](repeating: 0, count: count + 1)
        for node in 0..<count where node != root && dominators[node] >= 0 { childCounts[dominators[node] + 1] += 1 }
        for node in 0..<count { childCounts[node + 1] += childCounts[node] }
        var children = [Int](repeating: 0, count: max(childCounts[count], 0))
        var fill = childCounts
        for node in 0..<count where node != root && dominators[node] >= 0 {
            children[fill[dominators[node]]] = node
            fill[dominators[node]] += 1
        }
        var onPath = [Int](repeating: 0, count: names.count)
        var stack: [(node: Int, next: Int)] = [(root, childCounts[root])]
        while let top = stack.last {
            if top.next < childCounts[top.node + 1] {
                stack[stack.count - 1].next += 1
                let child = children[top.next]
                if including?[child] != false {
                    let name = classIndexes[child]
                    if onPath[name] == 0 { classRetained[name] += retained[child] }
                    onPath[name] += 1
                }
                stack.append((child, childCounts[child]))
            } else {
                stack.removeLast()
                if top.node != root, including?[top.node] != false { onPath[classIndexes[top.node]] -= 1 }
            }
        }

        var rows: [DeveloperHeapClass] = []
        for index in names.indices where counts[index] > 0 {
            rows.append(DeveloperHeapClass(name: names[index], index: index, count: counts[index],
                                           shallowSize: shallow[index], retainedSize: classRetained[index]))
            instances[index].sort { retained[$0] != retained[$1] ? retained[$0] > retained[$1] : $0 < $1 }
        }
        return (rows, instances)
    }

    func isInternal(_ node: Int) -> Bool { flags[node] & Self.internalFlag != 0 }

    /// Version 3 distinguishes element wrappers from their prototypes, even
    /// when both have the same constructor name. Older snapshots fall back
    /// to names, with the Runtime subtype checked before revealing a node.
    func suggestsDOMNode(_ node: Int) -> Bool {
        if flags[node] & Self.elementSubtypeFlag != 0 { return true }
        let raw = classNames[classIndexes[node]]
        let name = raw.hasPrefix("JS") ? String(raw.dropFirst(2)) : raw
        if name.hasSuffix("Element") { return !hasElementSubtypes }
        switch name {
        case "Node", "Text", "Comment", "CDATASection", "ProcessingInstruction", "Attr",
             "Document", "HTMLDocument", "XMLDocument", "SVGDocument", "DocumentType",
             "DocumentFragment", "ShadowRoot": return true
        default: return false
        }
    }

    /// An edge's name: a property or variable name, "[3]" for an index,
    /// or the edge's type.
    private func edgeLabel(_ label: Int) -> String {
        label < 0 ? "[\(~label)]" : edgeLabels.indices.contains(label) ? edgeLabels[label] : "Internal"
    }

    /// Direct incoming references, nearest the GC roots first. A node may
    /// have several references from the same object, each with its own label.
    func retainers(of node: Int) -> [DeveloperHeapRetainer] {
        guard hasRetainers(node) else { return [] }
        return (retainerOffsets[node]..<retainerOffsets[node + 1]).map { edge in
            let owner = retainerNodes[edge]
            let distance = distances[owner]
            return DeveloperHeapRetainer(id: edge, node: owner, label: edgeLabel(retainerLabels[edge]),
                                         distance: distance < 0 ? nil : distance)
        }.sorted {
            let lhs = $0.distance ?? Int.max, rhs = $1.distance ?? Int.max
            return lhs == rhs ? $0.id < $1.id : lhs < rhs
        }
    }

    func hasRetainers(_ node: Int) -> Bool {
        ids.indices.contains(node) && node != root && retainerOffsets[node] < retainerOffsets[node + 1]
    }

    /// Direct outgoing references, the objects a node holds: Containment's
    /// rows, largest retained size first. Each reference's distance is the
    /// held object's.
    func children(of node: Int) -> [DeveloperHeapRetainer] {
        guard hasChildren(node) else { return [] }
        return (childOffsets[node]..<childOffsets[node + 1]).map { edge in
            let target = childNodes[edge]
            let distance = distances[target]
            return DeveloperHeapRetainer(id: edge, node: target, label: edgeLabel(childLabels[edge]),
                                         distance: distance < 0 ? nil : distance)
        }.sorted {
            let lhs = retained[$0.node], rhs = retained[$1.node]
            return lhs == rhs ? $0.id < $1.id : lhs > rhs
        }
    }

    func hasChildren(_ node: Int) -> Bool {
        ids.indices.contains(node) && childOffsets[node] < childOffsets[node + 1]
    }

    /// Whether any path of references leads to `node` from the GC roots.
    func isReachable(_ node: Int) -> Bool {
        distances.indices.contains(node) && distances[node] >= 0
    }

    /// The nodes reached from the GC roots when nothing past a node marked
    /// in `stop` is followed; those nodes are reached themselves.
    func reachableFromRoot(stoppingAt stop: [Bool]) -> [Bool] {
        var seen = [Bool](repeating: false, count: nodeCount)
        guard seen.indices.contains(root) else { return seen }
        seen[root] = true
        var queue = [root]
        var next = 0
        while next < queue.count {
            let node = queue[next]
            next += 1
            if node != root, stop.indices.contains(node), stop[node] { continue }
            for edge in childOffsets[node]..<childOffsets[node + 1] {
                let target = childNodes[edge]
                guard !seen[target] else { continue }
                seen[target] = true
                queue.append(target)
            }
        }
        return seen
    }

    /// The references named `name` (a property or variable), as the
    /// holding and held nodes.
    func references(named name: String) -> [(from: Int, to: Int)] {
        let labels = Set(edgeLabels.indices.filter { edgeLabels[$0] == name })
        guard !labels.isEmpty else { return [] }
        var found: [(from: Int, to: Int)] = []
        for node in 0..<nodeCount {
            for edge in childOffsets[node]..<childOffsets[node + 1] where labels.contains(childLabels[edge]) {
                found.append((from: node, to: childNodes[edge]))
            }
        }
        return found
    }

    /// How many of a node's retainers are listed before "Show more".
    static let retainerPageSize = 100

    /// The Retainers tree for `node`, flattened: each open branch's
    /// references follow it, at most `limits[path]` (or a page) of them,
    /// then a "Show more" row. A row's id is its path of edges from
    /// `node`, so an object reached two ways gets two rows.
    func retainerRows(of node: Int, expanded: Set<String>, limits: [String: Int] = [:],
                      pageSize: Int = Self.retainerPageSize,
                      retainers: (Int) -> [DeveloperHeapRetainer]) -> [DeveloperHeapRetainerRow] {
        var rows: [DeveloperHeapRetainerRow] = []
        appendReferenceRows(of: node, path: "", ancestors: [node], depth: 0, expanded: expanded,
                            limits: limits, pageSize: pageSize, references: retainers,
                            canExpand: { self.hasRetainers($0) }, into: &rows)
        return rows
    }

    /// Containment, flattened the same way: from the GC roots down through
    /// what each object holds, a page of references per open branch.
    func containmentRows(expanded: Set<String>, limits: [String: Int] = [:],
                         pageSize: Int = Self.retainerPageSize,
                         children: (Int) -> [DeveloperHeapRetainer]) -> [DeveloperHeapRetainerRow] {
        var rows: [DeveloperHeapRetainerRow] = []
        appendReferenceRows(of: root, path: "", ancestors: [root], depth: 0, expanded: expanded,
                            limits: limits, pageSize: pageSize, references: children,
                            canExpand: { self.hasChildren($0) }, into: &rows)
        return rows
    }

    private func appendReferenceRows(of node: Int, path: String, ancestors: Set<Int>, depth: Int,
                                     expanded: Set<String>, limits: [String: Int], pageSize: Int,
                                     references next: (Int) -> [DeveloperHeapRetainer],
                                     canExpand: (Int) -> Bool,
                                     into rows: inout [DeveloperHeapRetainerRow]) {
        let references = next(node)
        let limit = limits[path] ?? pageSize
        for reference in references.prefix(limit) {
            let id = path + "/" + String(reference.id)
            let other = reference.node
            let expandable = !ancestors.contains(other) && canExpand(other)
            let open = expandable && expanded.contains(id)
            rows.append(DeveloperHeapRetainerRow(id: id, parent: path, depth: depth, reference: reference,
                                                 expandable: expandable, expanded: open, remaining: 0))
            if open {
                appendReferenceRows(of: other, path: id, ancestors: ancestors.union([other]), depth: depth + 1,
                                    expanded: expanded, limits: limits, pageSize: pageSize,
                                    references: next, canExpand: canExpand, into: &rows)
            }
        }
        if references.count > limit {
            rows.append(DeveloperHeapRetainerRow(id: path + "/more", parent: path, depth: depth, reference: nil,
                                                 expandable: false, expanded: false,
                                                 remaining: references.count - limit))
        }
    }

    /// Summary's classes and instances counting only objects whose ids are
    /// in `range`, for "Objects allocated between…".
    func allocated(in range: DeveloperHeapIDRange) -> DeveloperHeapGrouping {
        let including = ids.map { range.contains($0) }
        let (classes, instances) = Self.summarize(classIndexes: classIndexes, names: classNames, sizes: sizes,
                                                  retained: retained, dominators: dominators, root: root,
                                                  including: including)
        return DeveloperHeapGrouping(classes: classes, instances: instances)
    }

    /// The summary for a class filter, sorted as the table's header says.
    func summary(filter: String = "", sort: DeveloperHeapSort = DeveloperHeapSort(),
                 groups: [DeveloperHeapClass]? = nil) -> [DeveloperHeapClass] {
        let classes = groups ?? classes
        let query = filter.trimmingCharacters(in: .whitespaces)
        let rows = query.isEmpty ? classes : classes.filter { $0.name.localizedCaseInsensitiveContains(query) }
        return rows.sorted { sort.ordered($0, $1) }
    }

    /// A class's objects, sorted as the summary is.
    func instances(of classIndex: Int, sort: DeveloperHeapSort = DeveloperHeapSort(),
                   in groups: [[Int]]? = nil) -> [Int] {
        let instances = groups ?? instances
        guard instances.indices.contains(classIndex) else { return [] }
        let nodes = instances[classIndex]
        switch sort.column {
        case .retained where !sort.ascending: return nodes
        case .retained: return Array(nodes.reversed())
        case .shallow:
            return nodes.sorted { sizes[$0] != sizes[$1] ? (sort.ascending ? sizes[$0] < sizes[$1] : sizes[$0] > sizes[$1]) : ids[$0] < ids[$1] }
        case .name, .count:
            return nodes.sorted { sort.ascending ? ids[$0] < ids[$1] : ids[$0] > ids[$1] }
        }
    }

    /// Chrome's Comparison: per class, the objects in this snapshot that
    /// `base` didn't have (# New, Alloc. size) and the ones it had that are
    /// gone (# Deleted, Freed size). Classes with neither are left out.
    func comparison(from base: DeveloperHeapSnapshot) -> [DeveloperHeapDelta] {
        var rows: [String: DeveloperHeapDelta] = [:]
        for node in 0..<nodeCount where node != root && base.indexByID[ids[node]] == nil {
            let name = classNames[classIndexes[node]]
            rows[name, default: DeveloperHeapDelta(name: name)].added += 1
            rows[name, default: DeveloperHeapDelta(name: name)].allocatedSize += sizes[node]
        }
        for node in 0..<base.nodeCount where node != base.root && indexByID[base.ids[node]] == nil {
            let name = base.classNames[base.classIndexes[node]]
            rows[name, default: DeveloperHeapDelta(name: name)].deleted += 1
            rows[name, default: DeveloperHeapDelta(name: name)].freedSize += base.sizes[node]
        }
        return Array(rows.values)
    }
}

/// The two snapshots bracket live allocations. An object allocated and
/// collected between them has no instance row, but the collection is marked.
///
/// Classes and instances are the end snapshot's objects that the start
/// didn't have. Retained sizes are the end snapshot's, as in Chrome's
/// allocation summary, so a new object's can include older objects that
/// only it now keeps alive.
struct DeveloperHeapAllocationProfile: Sendable {
    struct Collection: Sendable {
        let start: Double
        let end: Double
        let full: Bool
    }

    /// A collection's place on the strip, as fractions of its width.
    struct Mark: Equatable, Sendable {
        let offset: Double
        let width: Double
        let full: Bool
    }

    let start: DeveloperHeapSnapshot
    /// Every collection reported while recording, in arrival order.
    let collections: [Collection]
    let classes: [DeveloperHeapClass]
    let instances: [[Int]]

    init(start: DeveloperHeapSnapshot, end: DeveloperHeapSnapshot, collections: [Collection]) {
        self.start = start
        // Only collections between trackingStart and trackingComplete are
        // recorded, so none are dropped here even when WebKit's clock for
        // them doesn't match the snapshots'.
        self.collections = collections
        let new = end.ids.map { start.indexByID[$0] == nil }
        (classes, instances) = DeveloperHeapSnapshot.summarize(
            classIndexes: end.classIndexes, names: end.classNames, sizes: end.sizes,
            retained: end.retained, dominators: end.dominators, root: end.root, including: new
        )
    }

    /// Where each collection goes on the strip: by time when they fall
    /// within the recording; by their own span when WebKit's stopwatch for
    /// them doesn't line up with the snapshots' timestamps (or those don't
    /// advance); evenly in arrival order when they have no span either.
    func marks(end: Double) -> [Mark] {
        guard !collections.isEmpty else { return [] }
        let begin = start.timestamp, duration = end - begin
        let slack = max(0, duration) * 0.01
        let inRange = duration > 0 && collections.allSatisfy { $0.start >= begin - slack && $0.end <= end + slack }
        let low = collections.map(\.start).min() ?? 0, high = collections.map(\.end).max() ?? 0
        let (origin, span) = inRange ? (begin, duration) : (low, high - low)
        guard span > 0, span.isFinite else {
            let count = Double(collections.count)
            return collections.enumerated().map { index, event in
                Mark(offset: (Double(index) + 0.5) / count, width: 0, full: event.full)
            }
        }
        return collections.map { event in
            Mark(offset: min(1, max(0, (event.start - origin) / span)),
                 width: min(1, max(0, (event.end - event.start) / span)), full: event.full)
        }
    }
}

/// A reference to an object (Retainers) or from one (Containment): the
/// edge's index, the object at its other end and the edge's name.
struct DeveloperHeapRetainer: Identifiable, Equatable, Sendable {
    let id: Int
    let node: Int
    let label: String
    /// Shortest number of references from a GC root.
    let distance: Int?
}

/// One line of the Retainers tree: a reference, or "Show more" (no
/// reference) for the rest of `parent`'s.
struct DeveloperHeapRetainerRow: Identifiable, Equatable, Sendable {
    /// The path of edge indexes from the selected object.
    let id: String
    let parent: String
    let depth: Int
    let reference: DeveloperHeapRetainer?
    let expandable: Bool
    let expanded: Bool
    let remaining: Int
}

/// Object ids after `after` (if any) up to and including `through`.
///
/// JavaScriptCore numbers objects from one counter that only goes up
/// (HeapProfiler's next object identifier), giving an object its number
/// the first time a snapshot sees it and keeping it in later snapshots.
/// So every object in snapshot N has an id no larger than N's largest,
/// and one first seen by a later snapshot has a larger id: Chrome's
/// "Objects allocated between Snapshot N and M" is the ids in
/// (max of N, max of M].
struct DeveloperHeapIDRange: Hashable, Sendable {
    let after: Int?
    let through: Int

    func contains(_ id: Int) -> Bool {
        id <= through && (after.map { id > $0 } ?? true)
    }
}

/// Summary's choice of objects, as Chrome's menu beside the class filter.
/// Snapshots are named by their entry ids. Detached DOM nodes have their
/// own profile, Detached elements (DeveloperHeapDetachedReport).
enum DeveloperHeapAllocationFilter: Hashable, Sendable {
    case all
    case before(Int)
    case between(Int, Int)
    case duplicatedStrings
    case retainedByDetachedNodes
    case retainedByConsole
}

/// A summary's classes with the objects of each, for a subset of a snapshot.
struct DeveloperHeapGrouping: Sendable {
    let classes: [DeveloperHeapClass]
    let instances: [[Int]]
}

/// One Summary row: a class (JavaScriptCore's class name, Chrome's
/// "Constructor") and its objects' count and sizes.
struct DeveloperHeapClass: Identifiable, Equatable, Sendable {
    let name: String
    /// Into the snapshot's class names and instances.
    let index: Int
    let count: Int
    let shallowSize: Int
    let retainedSize: Int
    var id: Int { index }
}

/// One Comparison row.
struct DeveloperHeapDelta: Identifiable, Equatable, Sendable {
    let name: String
    var added = 0
    var deleted = 0
    var allocatedSize = 0
    var freedSize = 0
    var id: String { name }
    var delta: Int { added - deleted }
    var sizeDelta: Int { allocatedSize - freedSize }
}

/// The column a Memory table is sorted by. Sizes sort largest first by
/// default, names A to Z, as in Chrome.
struct DeveloperHeapSort: Equatable, Sendable {
    enum Column: Equatable, Sendable { case name, count, shallow, retained }
    var column = Column.retained
    var ascending = false

    /// Clicking a header: the same column turns the order around, another
    /// starts from its usual order.
    mutating func toggle(_ column: Column) {
        if self.column == column { ascending.toggle() }
        else { self.column = column; ascending = column == .name }
    }

    func ordered(_ a: DeveloperHeapClass, _ b: DeveloperHeapClass) -> Bool {
        let (x, y): (Int, Int)
        switch column {
        case .name:
            let order = a.name.localizedStandardCompare(b.name)
            if order != .orderedSame { return ascending ? order == .orderedAscending : order == .orderedDescending }
            return a.index < b.index
        case .count: (x, y) = (a.count, b.count)
        case .shallow: (x, y) = (a.shallowSize, b.shallowSize)
        case .retained: (x, y) = (a.retainedSize, b.retainedSize)
        }
        if x != y { return ascending ? x < y : x > y }
        return a.name.localizedStandardCompare(b.name) == .orderedAscending
    }
}

/// Comparison's columns; the count and size columns sort largest first.
struct DeveloperHeapDeltaSort: Equatable, Sendable {
    enum Column: Equatable, Sendable { case name, added, deleted, delta, allocated, freed, sizeDelta }
    var column = Column.sizeDelta
    var ascending = false

    mutating func toggle(_ column: Column) {
        if self.column == column { ascending.toggle() }
        else { self.column = column; ascending = column == .name }
    }

    func sorted(_ rows: [DeveloperHeapDelta], filter: String = "") -> [DeveloperHeapDelta] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        let rows = query.isEmpty ? rows : rows.filter { $0.name.localizedCaseInsensitiveContains(query) }
        return rows.sorted { a, b in
            let (x, y): (Int, Int)
            switch column {
            case .name:
                let order = a.name.localizedStandardCompare(b.name)
                return ascending ? order == .orderedAscending : order == .orderedDescending
            case .added: (x, y) = (a.added, b.added)
            case .deleted: (x, y) = (a.deleted, b.deleted)
            case .delta: (x, y) = (a.delta, b.delta)
            case .allocated: (x, y) = (a.allocatedSize, b.allocatedSize)
            case .freed: (x, y) = (a.freedSize, b.freedSize)
            case .sizeDelta: (x, y) = (a.sizeDelta, b.sizeDelta)
            }
            if x != y { return ascending ? x < y : x > y }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
}

/// A heap's object graph by node index, and its dominator tree by
/// Cooper, Harvey and Kennedy's iterative algorithm ("A Simple, Fast
/// Dominance Algorithm"), which is what Chrome's heap profiler uses too.
struct DeveloperHeapGraph {
    let count: Int
    /// Successors and predecessors in compressed rows.
    let successorOffsets: [Int]
    let successors: [Int]
    let predecessorOffsets: [Int]
    let predecessors: [Int]

    init(count: Int, from: [Int], to: [Int]) {
        self.count = count
        let forward = Self.rows(count: count, keys: from, values: to)
        let backward = Self.rows(count: count, keys: to, values: from)
        successorOffsets = forward.0
        successors = forward.1
        predecessorOffsets = backward.0
        predecessors = backward.1
    }

    private static func rows(count: Int, keys: [Int], values: [Int]) -> ([Int], [Int]) {
        var offsets = [Int](repeating: 0, count: count + 1)
        for key in keys { offsets[key + 1] += 1 }
        for node in 0..<count { offsets[node + 1] += offsets[node] }
        return (offsets, order(offsets: offsets, keys: keys, values: values))
    }

    private static func order(offsets: [Int], keys: [Int], values: [Int]) -> [Int] {
        var fill = offsets
        var items = [Int](repeating: 0, count: values.count)
        for (key, value) in zip(keys, values) {
            items[fill[key]] = value
            fill[key] += 1
        }
        return items
    }

    func orderByRetainedNode(targets: [Int], values: [Int]) -> [Int] {
        Self.order(offsets: predecessorOffsets, keys: targets, values: values)
    }

    /// Per-edge values in the order of `successors`.
    func orderBySource(sources: [Int], values: [Int]) -> [Int] {
        Self.order(offsets: successorOffsets, keys: sources, values: values)
    }

    func distances(from root: Int) -> [Int] {
        var distances = [Int](repeating: -1, count: count)
        guard distances.indices.contains(root) else { return distances }
        distances[root] = 0
        var queue = [root]
        var next = 0
        while next < queue.count {
            let node = queue[next]
            next += 1
            for edge in successorOffsets[node]..<successorOffsets[node + 1] {
                let target = successors[edge]
                guard distances[target] < 0 else { continue }
                distances[target] = distances[node] + 1
                queue.append(target)
            }
        }
        return distances
    }

    /// Each node's immediate dominator from `root`; the root's is itself.
    /// A node the root can't reach is treated as if the root pointed at
    /// it, so the whole heap ends up in one tree. Also returns the
    /// postorder walked, root last, in which a node always comes before
    /// its dominator.
    func dominators(root: Int) -> (dominators: [Int], postorder: [Int]) {
        guard count > 0 else { return ([], []) }
        let successorOffsets = successorOffsets, successors = successors
        let predecessorOffsets = predecessorOffsets, predecessors = predecessors
        // Depth-first from the root, then from each node still unvisited
        // (each such start counts as a successor of the root).
        var visited = [Bool](repeating: false, count: count)
        var order: [Int] = []
        order.reserveCapacity(count)
        var extraRoots: [Int] = []
        var stack: [(node: Int, next: Int)] = []
        func walk(from start: Int) {
            visited[start] = true
            stack.append((start, successorOffsets[start]))
            while let top = stack.last {
                if top.next < successorOffsets[top.node + 1] {
                    stack[stack.count - 1].next += 1
                    let next = successors[top.next]
                    if !visited[next] {
                        visited[next] = true
                        stack.append((next, successorOffsets[next]))
                    }
                } else {
                    stack.removeLast()
                    if top.node != root { order.append(top.node) }
                }
            }
        }
        walk(from: root)
        for node in 0..<count where !visited[node] {
            extraRoots.append(node)
            walk(from: node)
        }
        // The root comes last in postorder, as if it were visited first.
        order.append(root)

        var number = [Int](repeating: -1, count: count)
        for (index, node) in order.enumerated() { number[node] = index }
        var extra = [Bool](repeating: false, count: count)
        for node in extraRoots { extra[node] = true }

        var dominators = [Int](repeating: -1, count: count)
        dominators[root] = root
        func intersect(_ a: Int, _ b: Int) -> Int {
            var a = a, b = b
            while a != b {
                while number[a] < number[b] { a = dominators[a] }
                while number[b] < number[a] { b = dominators[b] }
            }
            return a
        }
        var changed = true
        while changed {
            changed = false
            // Reverse postorder, skipping the root.
            for index in stride(from: order.count - 2, through: 0, by: -1) {
                let node = order[index]
                var chosen = extra[node] ? root : -1
                for at in predecessorOffsets[node]..<predecessorOffsets[node + 1] {
                    let predecessor = predecessors[at]
                    guard dominators[predecessor] != -1 else { continue }
                    chosen = chosen == -1 ? predecessor : intersect(predecessor, chosen)
                }
                if chosen != -1, dominators[node] != chosen {
                    dominators[node] = chosen
                    changed = true
                }
            }
        }
        return (dominators, order)
    }
}

/// The Memory panel's snapshots for one DevTools session. They outlive
/// the panel's view, so switching to another panel and back keeps them,
/// as Chrome's profiles sidebar does.
@MainActor
final class DeveloperMemory: ObservableObject {
    struct Entry: Identifiable {
        let id: Int
        var title: String {
            if let fileName { return fileName }
            if detached != nil { return "Detached elements \(id)" }
            return allocations == nil ? "Snapshot \(id)" : "Allocations \(id)"
        }
        let snapshot: DeveloperHeapSnapshot
        let allocations: DeveloperHeapAllocationProfile?
        let objectGeneration: Int
        /// The JSON WebKit returned, kept so Save profile writes it as is.
        var json: String? = nil
        /// The file a loaded snapshot came from, without its extension.
        var fileName: String? = nil
        /// A Detached elements profile: the snapshot's DOM nodes that the
        /// page said are out of the document.
        var detached: DeveloperHeapDetachedReport? = nil

        /// Loaded from a file: its heap ids aren't the inspected page's.
        var loaded: Bool { fileName != nil }
        var canSave: Bool { json != nil && allocations == nil }
    }

    /// A loaded snapshot's generation, which never matches the page's, so
    /// object actions stay off for it.
    static let loadedGeneration = -1

    private struct Boundary: Sendable {
        let timestamp: Double
        let json: String

        init?(_ params: [String: Any]) {
            guard let timestamp = params["timestamp"] as? Double,
                  let json = params["snapshotData"] as? String else { return nil }
            self.timestamp = timestamp
            self.json = json
        }

        func parse() throws -> DeveloperHeapSnapshot {
            try DeveloperHeapSnapshot(json: json, timestamp: timestamp)
        }
    }

    private struct Recording {
        let serial: Int
        var targetID: String?
        var start: Boundary?
        var stopping = false
        var collections: [DeveloperHeapAllocationProfile.Collection] = []
    }

    @Published private(set) var snapshots: [Entry] = []
    @Published var selected: Int?
    /// What the panel is waiting for: "Snapshotting…", "Building the dominator tree…".
    @Published private(set) var progress: String?
    @Published private(set) var recordingAllocations = false
    @Published private(set) var objectGeneration = 0
    @Published var message: String?
    private var next = 1
    private weak var session: DeveloperToolsSession?
    private var enabled = false

    /// Each entry's sorted retainers by node, so opening an object with
    /// many references sorts them once, not on every redraw.
    private var retainerCache: [Int: [Int: [DeveloperHeapRetainer]]] = [:]
    /// The same for Containment's outgoing references.
    private var childrenCache: [Int: [Int: [DeveloperHeapRetainer]]] = [:]

    private var recording: Recording? {
        didSet {
            // Heap's events reach the app only while a recording reads them.
            guard (oldValue == nil) != (recording == nil), let session else { return }
            Task { try? await session.updateEventDomains() }
        }
    }
    private var recordingSerial = 0

    /// An allocation recording is starting, running or finishing.
    var tracking: Bool { recording != nil }
    private var trackingCommand: Task<Void, Never>?

    /// The store for this session; a new session starts with none.
    static func store(for session: DeveloperToolsSession) -> DeveloperMemory {
        session.memory
    }

    init(session: DeveloperToolsSession) { self.session = session }

    var selectedEntry: Entry? { snapshots.first { $0.id == selected } }

    /// Heap.snapshot runs a full collection first, then hands over the
    /// whole heap as one JSON string; reading it happens off the main thread.
    func takeSnapshot() {
        guard progress == nil, recording == nil, let session, session.ready else { return }
        progress = "Snapshotting…"
        message = nil
        let generation = objectGeneration
        Task {
            defer { progress = nil }
            do {
                await enable(session)
                let result = try await session.command("Heap.snapshot")
                guard let json = result["snapshotData"] as? String else {
                    throw DeveloperHeapSnapshot.ParseError.malformed("WebKit sent no snapshot")
                }
                let timestamp = result["timestamp"] as? Double ?? Date().timeIntervalSince1970
                progress = "Building the dominator tree…"
                let snapshot = try await Task.detached(priority: .userInitiated) {
                    try DeveloperHeapSnapshot(json: json, timestamp: timestamp)
                }.value
                append(snapshot, generation: generation, json: json)
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func append(_ snapshot: DeveloperHeapSnapshot, allocations: DeveloperHeapAllocationProfile? = nil,
                        generation: Int, json: String? = nil, fileName: String? = nil,
                        detached: DeveloperHeapDetachedReport? = nil) {
        let entry = Entry(id: next, snapshot: snapshot, allocations: allocations, objectGeneration: generation,
                          json: json, fileName: fileName, detached: detached)
        next += 1
        snapshots.append(entry)
        selected = entry.id
    }

    // MARK: Detached elements

    /// How many nodes are asked about at once.
    static let detachedProbeConcurrency = 16

    /// Chrome's Detached elements: a snapshot, then each of its DOM nodes
    /// (up to DeveloperHeapSnapshot.detachedProbeLimit, largest first)
    /// resolved on the page and asked whether it's connected. The ones
    /// that aren't are listed by description, each with its retainers.
    func findDetachedElements() {
        guard progress == nil, recording == nil, let session, session.ready else { return }
        progress = "Snapshotting…"
        message = nil
        let generation = objectGeneration
        Task {
            defer { progress = nil }
            do {
                await enable(session)
                let result = try await session.command("Heap.snapshot")
                guard let json = result["snapshotData"] as? String else {
                    throw DeveloperHeapSnapshot.ParseError.malformed("WebKit sent no snapshot")
                }
                let timestamp = result["timestamp"] as? Double ?? Date().timeIntervalSince1970
                progress = "Building the dominator tree…"
                let (snapshot, candidates) = try await Task.detached(priority: .userInitiated) {
                    let snapshot = try DeveloperHeapSnapshot(json: json, timestamp: timestamp)
                    return (snapshot, snapshot.detachedCandidates())
                }.value
                progress = "Checking \(candidates.nodes.count.formatted()) DOM nodes…"
                let probes = await probeDOMNodes(candidates.nodes, of: snapshot, session: session)
                guard generation == objectGeneration else { throw ObjectActionError.stale }
                let report = snapshot.detachedReport(probes: probes, checked: candidates.nodes.count,
                                                     candidates: candidates.total)
                append(snapshot, generation: generation, json: json, detached: report)
            } catch {
                message = error.localizedDescription
            }
        }
    }

    /// The page's answer for each node it could resolve, a few at a time,
    /// all in one object group released at the end.
    private func probeDOMNodes(_ nodes: [Int], of snapshot: DeveloperHeapSnapshot,
                               session: DeveloperToolsSession) async -> [Int: DeveloperHeapDOMProbe] {
        guard !nodes.isEmpty else { return [:] }
        let target = session.runtimeTargetID
        let group = "search-heap-detached-" + UUID().uuidString
        let queue = ProbeQueue<DeveloperHeapDOMProbe>(nodes: nodes)
        let ids = snapshot.ids
        let workers = (0..<min(Self.detachedProbeConcurrency, nodes.count)).map { _ in
            Task { @MainActor in
                while let node = queue.take() {
                    guard session.ready else { return }
                    if let probe = await Self.probeDOMNode(heapID: ids[node], session: session,
                                                           group: group, target: target) {
                        queue.found[node] = probe
                    }
                }
            }
        }
        for worker in workers { await worker.value }
        _ = try? await session.command("Runtime.releaseObjectGroup", ["objectGroup": group], targetID: target)
        return queue.found
    }

    /// The nodes still to ask the page about, shared by a few workers, and
    /// what it said of each.
    @MainActor
    private final class ProbeQueue<Value> {
        private let nodes: [Int]
        private var next = 0
        var found: [Int: Value] = [:]

        init(nodes: [Int]) { self.nodes = nodes }

        func take() -> Int? {
            guard next < nodes.count else { return nil }
            defer { next += 1 }
            return nodes[next]
        }
    }

    /// Nil when the object was collected since or isn't a node.
    private static func probeDOMNode(heapID: Int, session: DeveloperToolsSession, group: String,
                                     target: String?) async -> DeveloperHeapDOMProbe? {
        guard let reply = try? await session.command("Heap.getRemoteObject", [
            "heapObjectId": heapID, "objectGroup": group,
        ], targetID: target),
            let object = reply["result"] as? [String: Any],
            let objectID = object["objectId"] as? String,
            let called = try? await session.command("Runtime.callFunctionOn", [
                "objectId": objectID, "functionDeclaration": DeveloperHeapDOMProbe.function,
                "returnByValue": true, "objectGroup": group,
            ], targetID: target),
            called["wasThrown"] as? Bool != true
        else { return nil }
        return DeveloperHeapDOMProbe((called["result"] as? [String: Any])?["value"])
    }

    // MARK: Summary filters that read the page

    /// Each snapshot's detached DOM nodes and string values, by entry id,
    /// read from the page the first time a filter needs them.
    private var detachedNodesByEntry: [Int: Set<Int>] = [:]
    private var stringsByEntry: [Int: DeveloperHeapStringScan] = [:]

    /// "Objects retained by detached DOM nodes": which of the snapshot's
    /// DOM nodes are out of the document, asked of the page as Detached
    /// elements asks, once per snapshot. `status` says what it's doing.
    func detachedNodes(in entry: Entry, status: (String) -> Void) async throws -> Set<Int> {
        if let known = detachedNodesByEntry[entry.id] { return known }
        let session = try pageSession(for: entry)
        let snapshot = entry.snapshot
        let candidates = await Task.detached(priority: .userInitiated) { snapshot.detachedCandidates() }.value
        status("Checking \(candidates.nodes.count.formatted()) DOM nodes…")
        let probes = await probeDOMNodes(candidates.nodes, of: snapshot, session: session)
        guard entry.objectGeneration == objectGeneration else { throw ObjectActionError.stale }
        let detached = Set(probes.filter { !$0.value.connected }.map(\.key))
        detachedNodesByEntry[entry.id] = detached
        return detached
    }

    /// "Duplicated strings": the snapshot's strings' values, read from the
    /// page (`Heap.getPreview`), the largest first and at most
    /// DeveloperHeapSnapshot.stringProbeLimit of them, once per snapshot.
    func stringValues(in entry: Entry, status: (String) -> Void) async throws -> DeveloperHeapStringScan {
        if let known = stringsByEntry[entry.id] { return known }
        let session = try pageSession(for: entry)
        let snapshot = entry.snapshot
        let candidates = await Task.detached(priority: .userInitiated) { snapshot.stringCandidates() }.value
        status("Reading \(candidates.nodes.count.formatted()) strings…")
        let values = await probeStrings(candidates.nodes, of: snapshot, session: session)
        guard entry.objectGeneration == objectGeneration else { throw ObjectActionError.stale }
        let scan = DeveloperHeapStringScan(values: values, checked: candidates.nodes.count, total: candidates.total)
        stringsByEntry[entry.id] = scan
        return scan
    }

    /// The session to ask about `entry`'s objects, when they are still the page's.
    private func pageSession(for entry: Entry) throws -> DeveloperToolsSession {
        guard !entry.loaded else { throw ObjectActionError.loaded }
        guard entry.objectGeneration == objectGeneration else { throw ObjectActionError.stale }
        guard let session, session.ready else { throw ObjectActionError.unavailable }
        return session
    }

    /// Each string's value, a few at a time; a string collected since the
    /// snapshot is left out.
    private func probeStrings(_ nodes: [Int], of snapshot: DeveloperHeapSnapshot,
                              session: DeveloperToolsSession) async -> [Int: String] {
        guard !nodes.isEmpty else { return [:] }
        let queue = ProbeQueue<String>(nodes: nodes)
        let ids = snapshot.ids
        let workers = (0..<min(Self.detachedProbeConcurrency, nodes.count)).map { _ in
            Task { @MainActor in
                while let node = queue.take() {
                    guard session.ready else { return }
                    if let reply = try? await session.command("Heap.getPreview", ["heapObjectId": ids[node]]),
                       let value = reply["string"] as? String {
                        queue.found[node] = value
                    }
                }
            }
        }
        for worker in workers { await worker.value }
        return queue.found
    }

    // MARK: Summary filter

    struct AllocationFilterOption: Identifiable, Hashable {
        let filter: DeveloperHeapAllocationFilter
        let title: String
        /// Nil for all objects.
        let range: DeveloperHeapIDRange?
        var id: DeveloperHeapAllocationFilter { filter }

        /// What Summary lists for this choice; nil for all objects.
        var scope: DeveloperHeapSummaryScope? {
            switch filter {
            case .all: return nil
            case .before, .between: return range.map { .range($0) }
            case .duplicatedStrings: return .duplicatedStrings
            case .retainedByDetachedNodes: return .retainedByDetachedNodes
            case .retainedByConsole: return .retainedByConsole
            }
        }
    }

    /// Chrome's other Summary filters, after the allocation ones. A
    /// loaded snapshot's strings and nodes aren't on the page to read, so
    /// it has only the console's; an allocation recording has none.
    nonisolated static func retentionFilters(for entry: Entry) -> [AllocationFilterOption] {
        guard entry.allocations == nil, entry.detached == nil else { return [] }
        let console = AllocationFilterOption(filter: .retainedByConsole,
                                             title: "Objects retained by the DevTools console", range: nil)
        guard !entry.loaded else { return [console] }
        return [
            AllocationFilterOption(filter: .duplicatedStrings, title: "Duplicated strings", range: nil),
            AllocationFilterOption(filter: .retainedByDetachedNodes, title: "Objects retained by detached DOM nodes",
                                   range: nil),
            console,
        ]
    }

    /// Chrome's choices for `entry`'s Summary: all objects, those
    /// allocated before the first snapshot, then those between each
    /// snapshot and the next, up to `entry`. Only snapshots taken of this
    /// page count; a loaded snapshot or allocation recording has only
    /// All objects.
    nonisolated static func allocationFilters(for entry: Entry, in entries: [Entry]) -> [AllocationFilterOption] {
        var options = [AllocationFilterOption(filter: .all, title: "All objects", range: nil)]
        guard entry.allocations == nil, !entry.loaded else { return options }
        let taken = entries.filter { $0.allocations == nil && !$0.loaded && $0.id <= entry.id }
        for (index, current) in taken.enumerated() {
            if index == 0 {
                options.append(AllocationFilterOption(
                    filter: .before(current.id), title: "Objects allocated before \(current.title)",
                    range: DeveloperHeapIDRange(after: nil, through: current.snapshot.maxObjectID)))
            } else {
                let previous = taken[index - 1]
                options.append(AllocationFilterOption(
                    filter: .between(previous.id, current.id),
                    title: "Objects allocated between \(previous.title) and \(current.title)",
                    range: DeveloperHeapIDRange(after: previous.snapshot.maxObjectID,
                                                through: current.snapshot.maxObjectID)))
            }
        }
        return options
    }

    // MARK: Save and load

    /// Save profile: the snapshot's JSON exactly as WebKit returned it.
    func save(_ entry: Entry, to url: URL) {
        guard let json = entry.json else { return }
        do { try Data(json.utf8).write(to: url, options: .atomic) }
        catch { message = error.localizedDescription }
    }

    /// Load profile: read and parse off the main thread, as a snapshot
    /// taken here is, then list it under its file's name.
    func load(from url: URL) {
        guard progress == nil else { return }
        progress = "Loading profile…"
        message = nil
        let name = url.deletingPathExtension().lastPathComponent
        Task {
            defer { progress = nil }
            do {
                let (snapshot, json) = try await Task.detached(priority: .userInitiated) {
                    try Self.readSnapshotFile(Data(contentsOf: url))
                }.value
                append(snapshot, generation: Self.loadedGeneration, json: json, fileName: name)
            } catch {
                message = error.localizedDescription
            }
        }
    }

    /// A saved snapshot's contents, parsed, with the JSON kept for saving again.
    nonisolated static func readSnapshotFile(_ data: Data) throws -> (DeveloperHeapSnapshot, String) {
        let snapshot = try DeveloperHeapSnapshot(data: data)
        return (snapshot, String(decoding: data, as: UTF8.self))
    }

    /// Chrome's name for a saved snapshot: Heap-20261122T101500.heapsnapshot.
    nonisolated static func snapshotFileName(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        return "Heap-\(formatter.string(from: date)).heapsnapshot"
    }

    // MARK: Allocation tracking

    func startAllocations() {
        guard progress == nil, recording == nil, let session, session.ready else { return }
        message = nil
        progress = "Starting allocation recording…"
        recordingSerial += 1
        let capture = Recording(serial: recordingSerial)
        recording = capture
        track("Heap.startTracking", capture: capture)
    }

    func stopAllocations() {
        guard progress == nil, var capture = recording, capture.start != nil else { return }
        capture.stopping = true
        recording = capture
        progress = "Stopping allocation recording…"
        track("Heap.stopTracking", capture: capture)
    }

    private func track(_ command: String, capture: Recording) {
        trackingCommand?.cancel()
        let serial = capture.serial, target = capture.targetID
        trackingCommand = Task { [weak self] in
            guard let self, let session else { return }
            do {
                await enable(session)
                try Task.checkCancellation()
                // Heap.trackingStart comes right after the command: listen first.
                try? await session.updateEventDomains()
                _ = try await session.command(command, targetID: target)
                try await Task.sleep(for: .seconds(20))
                if recording?.serial == serial {
                    failTracking("WebKit didn’t send the allocation snapshot.")
                }
            } catch is CancellationError {
            } catch {
                if recording?.serial == serial { failTracking(error.localizedDescription) }
            }
        }
    }

    func handle(_ method: String, params: [String: Any], targetID: String?) {
        guard recording != nil else { return }
        if let target = recording?.targetID, let targetID, target != targetID { return }
        switch method {
        case "Heap.trackingStart":
            guard recording?.start == nil else { return }
            guard let start = Boundary(params) else {
                failTracking("WebKit didn’t send the starting heap snapshot.")
                return
            }
            trackingCommand?.cancel()
            recording?.start = start
            recording?.targetID = targetID
            progress = nil
            recordingAllocations = true
        case "Heap.garbageCollected":
            guard recording?.start != nil, (recording?.collections.count ?? 0) < 10_000,
                  let data = params["collection"] as? [String: Any],
                  let start = data["startTime"] as? Double, let end = data["endTime"] as? Double else { return }
            recording?.collections.append(.init(start: start, end: end, full: data["type"] as? String == "full"))
        case "Heap.trackingComplete":
            guard let capture = recording, capture.stopping, let start = capture.start else { return }
            guard let end = Boundary(params) else {
                failTracking("WebKit didn’t send the ending heap snapshot.")
                return
            }
            trackingCommand?.cancel()
            recording = nil
            recordingAllocations = false
            progress = "Building the allocation profile…"
            let collections = capture.collections
            let generation = objectGeneration
            Task {
                defer { progress = nil }
                do {
                    let (snapshot, profile) = try await Task.detached(priority: .userInitiated) {
                        let before = try start.parse(), after = try end.parse()
                        return (after, DeveloperHeapAllocationProfile(start: before, end: after, collections: collections))
                    }.value
                    append(snapshot, allocations: profile, generation: generation)
                } catch { message = error.localizedDescription }
            }
        default: break
        }
    }

    private func failTracking(_ description: String, resetBackend: Bool = true) {
        trackingCommand?.cancel()
        let target = recording?.targetID
        recording = nil
        recordingAllocations = false
        progress = nil
        message = description
        guard resetBackend, let session, session.ready else { return }
        progress = "Stopping allocation recording…"
        trackingCommand = Task { [weak self] in
            _ = try? await session.command("Heap.stopTracking", targetID: target)
            self?.progress = nil
        }
    }

    func targetChanged() {
        invalidateObjectIDs()
        enabled = false
        if recording != nil { failTracking("The inspected page changed before the recording finished.", resetBackend: false) }
    }

    func invalidateObjectIDs() { objectGeneration += 1 }

    func collectGarbage() {
        guard let session, session.ready else { return }
        Task {
            do {
                await enable(session)
                _ = try await session.command("Heap.gc")
            } catch { message = error.localizedDescription }
        }
    }

    func remove(_ id: Int) {
        snapshots.removeAll { $0.id == id }
        retainerCache[id] = nil
        childrenCache[id] = nil
        detachedNodesByEntry[id] = nil
        stringsByEntry[id] = nil
        if selected == id { selected = snapshots.last?.id }
    }

    func clear() {
        snapshots = []
        retainerCache = [:]
        childrenCache = [:]
        detachedNodesByEntry = [:]
        stringsByEntry = [:]
        selected = nil
        message = nil
    }

    func retainers(of node: Int, in entry: Entry) -> [DeveloperHeapRetainer] {
        if let cached = retainerCache[entry.id]?[node] { return cached }
        let references = entry.snapshot.retainers(of: node)
        retainerCache[entry.id, default: [:]][node] = references
        return references
    }

    func children(of node: Int, in entry: Entry) -> [DeveloperHeapRetainer] {
        if let cached = childrenCache[entry.id]?[node] { return cached }
        let references = entry.snapshot.children(of: node)
        childrenCache[entry.id, default: [:]][node] = references
        return references
    }

    // MARK: Snapshot object actions

    func storeAsGlobal(_ node: Int, in entry: Entry) async -> String? {
        await withRemoteObject(node, in: entry) { session, object, target in
            // As the console's Store as global variable, but with WebKit's
            // reason when it fails.
            guard let id = object.objectId else { throw ObjectActionError.unavailable }
            let stored = try await session.bridge("return await searchConsole.storeAsGlobal(objectId, target);", [
                "objectId": id, "target": target as Any? ?? NSNull(),
            ])
            guard let name = stored as? String else { throw ObjectActionError.unavailable }
            session.evaluateInConsole(name)
            return name
        }
    }

    @discardableResult
    func revealInElements(_ node: Int, in entry: Entry) async -> Bool {
        await withRemoteObject(node, in: entry) { session, object, target in
            guard object.isNode else { throw ObjectActionError.notNode }
            guard let id = object.objectId, let revealed = session.revealConsoleNode(object, targetID: target)
            else { throw ObjectActionError.unavailable }
            if await revealed.value { return true }
            // The reveal doesn't say why it failed; asking again does, and
            // selects the node if it can be found now that Elements is open.
            let found = try await session.bridge("return await searchConsole.nodeId(objectId, null);", ["objectId": id])
            guard let nodeID = found as? Int, nodeID > 0 else { throw ObjectActionError.unavailable }
            session.selectNode(nodeID)
            return true
        } ?? false
    }

    private enum ObjectActionError: LocalizedError {
        case unavailable, notNode, stale, loaded

        var errorDescription: String? {
            switch self {
            case .loaded: "This snapshot was loaded from a file, so its objects aren’t on the inspected page."
            case .unavailable: "This object is no longer available on the inspected page."
            case .notNode: "This object is not a DOM node."
            case .stale: "The inspected page has changed since this snapshot was taken."
            }
        }
    }

    private func withRemoteObject<T>(_ node: Int, in entry: Entry,
                                     action: (DeveloperToolsSession, ConsoleRemoteObject, String?) async throws -> T) async -> T? {
        guard let session, session.ready,
              entry.snapshot.ids.indices.contains(node), node != entry.snapshot.root else { return nil }
        guard !entry.loaded else {
            message = ObjectActionError.loaded.localizedDescription
            return nil
        }
        guard entry.objectGeneration == objectGeneration else {
            message = ObjectActionError.stale.localizedDescription
            return nil
        }
        message = nil
        let target = session.runtimeTargetID
        let group = "search-heap-action-" + UUID().uuidString
        defer { Task { _ = try? await session.command("Runtime.releaseObjectGroup", ["objectGroup": group], targetID: target) } }
        do {
            let reply = try await session.command("Heap.getRemoteObject", [
                "heapObjectId": entry.snapshot.ids[node], "objectGroup": group,
            ], targetID: target)
            guard entry.objectGeneration == objectGeneration else { throw ObjectActionError.stale }
            guard session.ready, let raw = reply["result"] as? [String: Any] else { throw ObjectActionError.unavailable }
            return try await action(session, ConsoleRemoteObject(raw), target)
        } catch {
            message = error.localizedDescription
            return nil
        }
    }

    /// What `Heap.getPreview` says about an object: a string's text, a
    /// function's name, or an object's description and first properties.
    func preview(_ id: Int) async -> String {
        guard let session, session.ready else { return "" }
        do {
            let result = try await session.command("Heap.getPreview", ["heapObjectId": id])
            return Self.previewText(result)
        } catch {
            // WebKit says this when the object was collected since.
            return "No preview: the object may have been collected since the snapshot."
        }
    }

    nonisolated static func previewText(_ result: [String: Any]) -> String {
        if let string = result["string"] as? String {
            let cut = string.count > 400 ? String(string.prefix(400)) + "…" : string
            return "\"\(cut)\""
        }
        if let function = result["functionDetails"] as? [String: Any] {
            let name = (function["displayName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (function["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "anonymous"
            return "function \(name)()"
        }
        if let preview = result["preview"] as? [String: Any] {
            let description = preview["description"] as? String ?? preview["type"] as? String ?? "Object"
            let properties = (preview["properties"] as? [[String: Any]] ?? []).map { property in
                let name = property["name"] as? String ?? ""
                let value = property["value"] as? String ?? property["type"] as? String ?? ""
                return "\(name): \(property["type"] as? String == "string" ? "\"\(value)\"" : value)"
            }
            if properties.isEmpty { return description }
            let more = preview["overflow"] as? Bool == true ? ", …" : ""
            return "\(description) {\(properties.joined(separator: ", "))\(more)}"
        }
        return "No preview for this object."
    }

    private func enable(_ session: DeveloperToolsSession) async {
        guard !enabled else { return }
        // WebKit's own frontend may have enabled it already; that's fine.
        _ = try? await session.command("Heap.enable")
        enabled = true
    }
}
