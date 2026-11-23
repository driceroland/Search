import Foundation

/// What Summary lists, from Chrome's menu beside the class filter: the
/// objects allocated in a range of ids, or one of the filters below.
enum DeveloperHeapSummaryScope: Hashable, Sendable {
    case range(DeveloperHeapIDRange)
    /// Strings whose value another string in the snapshot has too, grouped by value.
    case duplicatedStrings
    /// Objects only detached DOM nodes keep alive, and those nodes.
    case retainedByDetachedNodes
    /// Objects only the console keeps alive: values it logged or evaluated.
    case retainedByConsole
}

/// A Duplicated strings filter's reading: each string's value, by node,
/// and how many strings were read of how many the snapshot has.
struct DeveloperHeapStringScan: Sendable {
    let values: [Int: String]
    let checked: Int
    let total: Int
    var truncated: Bool { checked < total }
}

/// Summary's filters over a parsed snapshot. JavaScriptCore's snapshots
/// carry neither strings' values nor whether a DOM node is in the
/// document, so the panel reads those from the page first (DeveloperMemory)
/// and what's here is the pure part: which objects each filter keeps and
/// how Summary groups them.
extension DeveloperHeapSnapshot {
    /// JavaScriptCore's classes for string cells.
    static let stringClassNames: Set<String> = ["string", "RopeString"]
    /// The most strings a Duplicated strings filter reads from the page.
    static let stringProbeLimit = 20_000

    /// WebKit's injected script (InjectedScriptSource.js) keeps what the
    /// console hands the frontend in these properties: objects by remote
    /// object id, and the `$1`… saved results.
    static let consoleHolderNames = ["_idToWrappedObject", "_savedResults"]

    /// The string nodes to read, largest first, at most `limit`, and how
    /// many there were in all.
    func stringCandidates(limit: Int = Self.stringProbeLimit) -> (nodes: [Int], total: Int) {
        let strings = Set(classNames.indices.filter { Self.stringClassNames.contains(classNames[$0]) })
        let all = (0..<nodeCount).filter { $0 != root && strings.contains(classIndexes[$0]) }
        let sorted = all.sorted { sizes[$0] != sizes[$1] ? sizes[$0] > sizes[$1] : ids[$0] < ids[$1] }
        return (Array(sorted.prefix(max(0, limit))), all.count)
    }

    /// Chrome's "Duplicated strings": a row per value two or more strings
    /// share, named by the value in quotes, holding those strings.
    func duplicatedStrings(_ values: [Int: String]) -> DeveloperHeapGrouping {
        var byValue: [String: [Int]] = [:]
        for (node, value) in values where ids.indices.contains(node) && node != root {
            byValue[value, default: []].append(node)
        }
        let shared = byValue.filter { $0.value.count > 1 }.sorted { $0.key < $1.key }
        var classes: [DeveloperHeapClass] = []
        var instances: [[Int]] = []
        for (index, (value, nodes)) in shared.enumerated() {
            let sorted = nodes.sorted { retained[$0] != retained[$1] ? retained[$0] > retained[$1] : $0 < $1 }
            classes.append(DeveloperHeapClass(
                name: Self.quoted(value), index: index, count: nodes.count,
                shallowSize: nodes.reduce(0) { $0 + sizes[$1] }, retainedSize: nodes.reduce(0) { $0 + retained[$1] }))
            instances.append(sorted)
        }
        return DeveloperHeapGrouping(classes: classes, instances: instances)
    }

    /// A string as a row names it: in quotes, on one line, cut at `limit`.
    static func quoted(_ value: String, limit: Int = 100) -> String {
        let flat = value.replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        let cut = flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
        return "\"" + cut + "\""
    }

    /// Chrome's "Objects retained by detached DOM nodes": the detached
    /// nodes, and every object the GC roots reach only through one of them.
    func retained(byDetached detached: Set<Int>) -> DeveloperHeapGrouping {
        var stop = [Bool](repeating: false, count: nodeCount)
        for node in detached where stop.indices.contains(node) && node != root { stop[node] = true }
        let reached = reachableFromRoot(stoppingAt: stop)
        return grouping { node in isReachable(node) && (stop[node] || !reached[node]) }
    }

    /// The objects holding what the console keeps: the injected script's
    /// maps of wrapped objects and saved results.
    func consoleHolders() -> [Int] {
        let scripts = Set(references(named: Self.consoleHolderNames[0]).map(\.from))
        guard !scripts.isEmpty else { return [] }
        return Self.consoleHolderNames.flatMap { references(named: $0) }
            .filter { scripts.contains($0.from) }.map(\.to)
    }

    /// Chrome's "Objects retained by the DevTools console": what the GC
    /// roots reach only through the console's holders, not the holders.
    func retainedByConsole() -> DeveloperHeapGrouping {
        var stop = [Bool](repeating: false, count: nodeCount)
        for node in consoleHolders() where stop.indices.contains(node) { stop[node] = true }
        guard stop.contains(true) else { return DeveloperHeapGrouping(classes: [], instances: []) }
        let reached = reachableFromRoot(stoppingAt: stop)
        return grouping { node in isReachable(node) && !reached[node] }
    }

    /// Summary's classes and instances for the objects `including` keeps.
    private func grouping(_ including: (Int) -> Bool) -> DeveloperHeapGrouping {
        let mask = (0..<nodeCount).map(including)
        let (classes, instances) = Self.summarize(classIndexes: classIndexes, names: classNames, sizes: sizes,
                                                  retained: retained, dominators: dominators, root: root,
                                                  including: mask)
        return DeveloperHeapGrouping(classes: classes, instances: instances)
    }
}
