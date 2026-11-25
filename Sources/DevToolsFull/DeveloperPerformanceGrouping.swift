import Foundation

/// Chrome's grouping menu over Bottom-up and Call tree.
enum DeveloperPerformanceGrouping: String, CaseIterable, Identifiable {
    case none = "No grouping"
    case activity = "Group by activity"
    case category = "Group by category"
    case domain = "Group by domain"
    case subdomain = "Group by subdomain"
    case url = "Group by URL"
    case frame = "Group by frame"

    var id: String { rawValue }

    /// Chrome's name for what has no URL or frame.
    static let unattributed = "[unattributed]"

    /// The site a host belongs to: "example.com" for "cdn.example.com",
    /// "example.co.uk" for "www.example.co.uk"; an address or a one-label
    /// host as it is.
    static func domain(of host: String) -> String {
        let labels = host.split(separator: ".").map(String.init)
        guard labels.count > 2, !labels.allSatisfy({ Int($0) != nil }) else { return host }
        let second = labels[labels.count - 2]
        let generic: Set<String> = ["co", "com", "org", "net", "gov", "ac", "edu", "ne", "or"]
        let keep = labels[labels.count - 1].count == 2 && generic.contains(second) ? 3 : 2
        return labels.suffix(keep).joined(separator: ".")
    }
}

/// The Filter box over Bottom-up and Call tree, with Match case and Use
/// regular expression: a row stays when it or a row beneath it matches.
struct DeveloperPerformanceTextFilter: Equatable {
    var text = ""
    var matchCase = false
    var regex = false

    var isEmpty: Bool { text.isEmpty }

    /// Whether a regular expression typed is one; a broken one filters nothing.
    var isValid: Bool { !regex || text.isEmpty || expression != nil }

    private var expression: NSRegularExpression? {
        try? NSRegularExpression(pattern: text, options: matchCase ? [] : [.caseInsensitive])
    }

    func matches(_ value: String) -> Bool {
        guard !text.isEmpty else { return true }
        if regex {
            guard let expression else { return true }
            return expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
        }
        return matchCase ? value.contains(text) : value.localizedCaseInsensitiveContains(text)
    }

    /// The rows that match and those above them, the rest pruned.
    func apply(to nodes: [DeveloperPerformanceNode]) -> [DeveloperPerformanceNode] {
        guard !text.isEmpty, isValid else { return nodes }
        if regex, let expression {
            return Self.prune(nodes) { value in
                expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
            }
        }
        return Self.prune(nodes) { matches($0) }
    }

    private static func prune(_ nodes: [DeveloperPerformanceNode],
                              _ match: (String) -> Bool) -> [DeveloperPerformanceNode] {
        nodes.compactMap { node in
            let children = prune(node.children, match)
            guard match(node.activity) || !children.isEmpty else { return nil }
            var kept = node
            kept.children = children
            return kept
        }
    }
}

/// A frame of Bottom-up's heaviest stack: root first, the row chosen
/// marked.
struct DeveloperPerformanceStackFrame: Identifiable, Equatable {
    let id: Int
    let activity: String
    let category: DeveloperPerformanceCategory
    let totalTime: Double
    let isSelected: Bool
}

extension DeveloperPerformanceProfile {
    /// The groupings the recording's records support: by URL, domain and
    /// subdomain when some have an address, by frame when some name one.
    var groupings: [DeveloperPerformanceGrouping] {
        let addressed = events.contains { Self.address(of: $0) != nil }
        let framed = events.contains { !($0.data["frame"] ?? "").isEmpty }
        return DeveloperPerformanceGrouping.allCases.filter { grouping in
            switch grouping {
            case .none, .activity, .category: true
            case .domain, .subdomain, .url: addressed
            case .frame: framed
            }
        }
    }

    private static func address(of event: DeveloperPerformanceEvent) -> String? {
        for key in ["url", "scriptName"] {
            if let value = event.data[key], !value.isEmpty { return value }
        }
        return nil
    }

    /// Each record's group under `grouping`: its own address or frame, or
    /// the nearest record around it with one.
    func groupKeys(_ grouping: DeveloperPerformanceGrouping) -> [String] {
        var keys = Array(repeating: DeveloperPerformanceGrouping.unattributed, count: events.count)
        switch grouping {
        case .none:
            return keys
        case .activity:
            return events.map { $0.type == "JavaScriptFrame" ? "Function call" : $0.title }
        case .category:
            return events.map(\.category.rawValue)
        case .frame:
            var inherited = Array(repeating: String?.none, count: events.count)
            for event in events {
                let own = event.data["frame"].flatMap { $0.isEmpty ? nil : $0 }
                let above = event.parent.flatMap { inherited[$0] }
                inherited[event.id] = own ?? above
                if let value = inherited[event.id] { keys[event.id] = value }
            }
            return keys
        case .domain, .subdomain, .url:
            var inherited = Array(repeating: String?.none, count: events.count)
            for event in events {
                let above = event.parent.flatMap { inherited[$0] }
                inherited[event.id] = Self.address(of: event) ?? above
                guard let address = inherited[event.id] else { continue }
                let host = URL(string: address)?.host
                switch grouping {
                case .url: keys[event.id] = address
                case .subdomain: keys[event.id] = host ?? address
                default: keys[event.id] = host.map(DeveloperPerformanceGrouping.domain(of:)) ?? address
                }
            }
            return keys
        }
    }

    /// Call tree under a grouping: a row per group holding the top-level
    /// activities in it.
    func callTree(in range: ClosedRange<Double>, groupedBy grouping: DeveloperPerformanceGrouping) -> [DeveloperPerformanceNode] {
        guard grouping != .none else { return callTree(in: range) }
        let keys = groupKeys(grouping)
        let roots = shown.filter { !$0.isHidden && $0.parent == nil && overlap($0, range) > 0 }.map(\.id)
        return grouped(roots, keys: keys) { key, members in
            let path = "#" + key
            return DeveloperPerformanceNode(
                id: path, activity: key, category: shown[members[0]].category,
                selfTime: members.reduce(0) { $0 + selfTime(shown[$1], in: range) },
                totalTime: members.reduce(0) { $0 + overlap(shown[$1], range) },
                children: tree(members, path: path, in: range, depth: 1), isGroup: true)
        }
        .sorted { $0.totalTime != $1.totalTime ? $0.totalTime > $1.totalTime : $0.activity < $1.activity }
    }

    /// Bottom-up under a grouping: a row per group holding the activities
    /// in it, each opening on its callers.
    func bottomUp(in range: ClosedRange<Double>, groupedBy grouping: DeveloperPerformanceGrouping) -> [DeveloperPerformanceNode] {
        guard grouping != .none else { return bottomUp(in: range) }
        let keys = groupKeys(grouping)
        let leaves = shown.filter { !$0.isHidden && overlap($0, range) > 0 }.map(\.id)
        return grouped(leaves, keys: keys) { key, members in
            let path = "#" + key
            // A record inside another of the same group is already in that
            // one's total.
            let total = members.reduce(0.0) { sum, id in
                var parent = shown[id].parent
                while let index = parent {
                    if keys[index] == key { return sum }
                    parent = shown[index].parent
                }
                return sum + overlap(shown[id], range)
            }
            return DeveloperPerformanceNode(
                id: path, activity: key, category: shown[members[0]].category,
                selfTime: members.reduce(0) { $0 + selfTime(shown[$1], in: range) }, totalTime: total,
                children: callers(members.map { (leaf: $0, at: $0) }, path: path, in: range, depth: 1), isGroup: true)
        }
        .sorted { $0.selfTime != $1.selfTime ? $0.selfTime > $1.selfTime : $0.activity < $1.activity }
    }

    private func grouped(_ ids: [Int], keys: [String],
                         _ make: (String, [Int]) -> DeveloperPerformanceNode) -> [DeveloperPerformanceNode] {
        var groups: [String: [Int]] = [:]
        var order: [String] = []
        for id in ids {
            let key = keys.indices.contains(id) ? keys[id] : DeveloperPerformanceGrouping.unattributed
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(id)
        }
        return order.map { make($0, groups[$0, default: []]) }
    }

    /// Bottom-up's heaviest stack for a row: `path` is the rows from the
    /// top-level one down to the row chosen (each a caller of the one
    /// before). Root first: the heaviest callers above the chosen row,
    /// the rows of `path`, then the heaviest callees of the top-level
    /// activity below it.
    func heaviestStack(through path: [DeveloperPerformanceNode],
                       in range: ClosedRange<Double>) -> [DeveloperPerformanceStackFrame] {
        let rows = path.filter { !$0.isGroup }
        guard let chosen = rows.last, let leaf = rows.first else { return [] }
        var above: [DeveloperPerformanceNode] = []
        var node = chosen
        while above.count < 64, let caller = node.children.max(by: { a, b in
            a.totalTime != b.totalTime ? a.totalTime < b.totalTime : a.activity > b.activity
        }) {
            above.append(caller)
            node = caller
        }
        var frames: [(activity: String, category: DeveloperPerformanceCategory, total: Double, chosen: Bool)] = []
        for caller in above.reversed() {
            frames.append((activity: caller.activity, category: caller.category, total: caller.totalTime, chosen: false))
        }
        for (index, row) in rows.enumerated().reversed() {
            frames.append((activity: row.activity, category: row.category, total: row.totalTime, chosen: index == rows.count - 1))
        }
        // Below: what the top-level activity's outermost records called most.
        var current = shown.filter {
            !$0.isHidden && $0.activity == leaf.activity && overlap($0, range) > 0 && !hasAncestor($0, activity: leaf.activity)
        }.map(\.id)
        var depth = 0
        while depth < 64 {
            var totals: [String: Double] = [:]
            var members: [String: [Int]] = [:]
            for id in current {
                for child in shown[id].children where overlap(shown[child], range) > 0 {
                    totals[shown[child].activity, default: 0] += overlap(shown[child], range)
                    members[shown[child].activity, default: []].append(child)
                }
            }
            guard let heaviest = totals.max(by: { a, b in a.value != b.value ? a.value < b.value : a.key > b.key }),
                  let ids = members[heaviest.key], let first = ids.first else { break }
            frames.append((activity: heaviest.key, category: shown[first].category, total: heaviest.value, chosen: false))
            current = ids
            depth += 1
        }
        return frames.enumerated().map { index, frame in
            DeveloperPerformanceStackFrame(id: index, activity: frame.activity, category: frame.category,
                                           totalTime: frame.total, isSelected: frame.chosen)
        }
    }

    /// The rows from the top level down to the row with `id`, or nil.
    static func path(to id: String, in nodes: [DeveloperPerformanceNode]) -> [DeveloperPerformanceNode]? {
        for node in nodes {
            if node.id == id { return [node] }
            guard id.hasPrefix(node.id + "/") else { continue }
            if let rest = path(to: id, in: node.children) { return [node] + rest }
        }
        return nil
    }
}
