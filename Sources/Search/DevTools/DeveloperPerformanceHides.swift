import Foundation

/// What the flame chart's context menu has hidden, as Chrome's Main track
/// hides entries: whole functions merged into their callers, an entry's
/// children, or its repeating children. View state over a recording's
/// records, which it never changes; a new recording starts with none.
struct DeveloperFlameHides: Equatable {
    /// Hide function: activities whose entries merge into their parents.
    var functions: Set<String> = []
    /// Entries that Reset children brought back from a hidden function.
    var revealed: Set<Int> = []
    /// Hide children: entries whose descendants are collapsed into them.
    var children: Set<Int> = []
    /// Hide repeating children: entries whose descendants of the same
    /// function merge into it.
    var repeating: Set<Int> = []

    var isEmpty: Bool { functions.isEmpty && children.isEmpty && repeating.isEmpty }

    /// `events` as the flame chart, Call tree and Bottom-up show them with
    /// these hides: the same ids, a hidden record marked `isHidden` with
    /// row -1, and each shown one with its nearest shown ancestor as parent,
    /// its row among shown ancestors, and its self time including what was
    /// merged into it. Records come parents first, as the profile builds them.
    func apply(to events: [DeveloperPerformanceEvent]) -> [DeveloperPerformanceEvent] {
        guard !isEmpty else { return events }
        var hidden = Array(repeating: false, count: events.count)
        /// Under an entry whose children are hidden.
        var collapsed = Array(repeating: false, count: events.count)
        /// The functions of entries above that hide their repeating children.
        var repeats = Array(repeating: Set<String>(), count: events.count)
        var parents = Array(repeating: Int?.none, count: events.count)
        var rows = Array(repeating: -1, count: events.count)
        var hasHidden = Array(repeating: false, count: events.count)
        for event in events {
            let id = event.id
            if let parent = event.parent, events.indices.contains(parent) {
                collapsed[id] = collapsed[parent] || children.contains(parent)
                repeats[id] = repeats[parent]
                if repeating.contains(parent) { repeats[id].insert(events[parent].activity) }
            }
            hidden[id] = collapsed[id] || repeats[id].contains(event.activity)
                || (functions.contains(event.activity) && !revealed.contains(id))
            // The nearest ancestor shown.
            var parent = event.parent
            while let index = parent, events.indices.contains(index), hidden[index] { parent = events[index].parent }
            if hidden[id] {
                if let parent { hasHidden[parent] = true }
            } else {
                parents[id] = parent
                rows[id] = parent.map { rows[$0] + 1 } ?? 0
            }
        }
        var laidOut = events.map { event in
            DeveloperPerformanceEvent(
                id: event.id, type: event.type, title: event.title, detail: event.detail, category: event.category,
                start: event.start, end: event.end, row: rows[event.id], parent: parents[event.id],
                children: [], selfTime: 0, data: event.data, stack: event.stack,
                isHidden: hidden[event.id], hidesChildren: hasHidden[event.id], frames: event.frames)
        }
        for event in laidOut where !event.isHidden {
            if let parent = event.parent { laidOut[parent].children.append(event.id) }
        }
        for index in laidOut.indices where !laidOut[index].isHidden {
            let event = laidOut[index]
            let nested = event.children.reduce(0) { total, child in
                total + max(0, min(laidOut[child].end, event.end) - max(laidOut[child].start, event.start))
            }
            laidOut[index].selfTime = max(0, event.duration - nested)
        }
        return laidOut
    }

    /// Hide function: every entry of `activity` merges into its parent.
    mutating func hideFunction(_ activity: String, in events: [DeveloperPerformanceEvent]) {
        functions.insert(activity)
        revealed = revealed.filter { events.indices.contains($0) && events[$0].activity != activity }
    }

    /// Reset children: the hides under `id` undone, and `id` itself no
    /// longer collapsing what it holds.
    mutating func resetChildren(of id: Int, in events: [DeveloperPerformanceEvent]) {
        guard events.indices.contains(id) else { return }
        children.remove(id)
        repeating.remove(id)
        var stack = events[id].children
        while let next = stack.popLast() {
            guard events.indices.contains(next) else { continue }
            children.remove(next)
            repeating.remove(next)
            if functions.contains(events[next].activity) { revealed.insert(next) }
            stack.append(contentsOf: events[next].children)
        }
    }
}
