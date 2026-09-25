import SwiftUI

/// Two existing tabs that can be shown together. The order is the page order,
/// not the order of their titles in the tab row.
struct SplitPair: Identifiable, Equatable {
    let id = UUID()
    var left: Tab.ID
    var right: Tab.ID
    var fraction: Double

    init(left: Tab.ID, right: Tab.ID, fraction: Double = 0.5) {
        self.left = left
        self.right = right
        self.fraction = min(0.75, max(0.25, fraction))
    }

    func contains(_ id: Tab.ID) -> Bool { left == id || right == id }
    func other(than id: Tab.ID) -> Tab.ID? {
        if left == id { return right }
        if right == id { return left }
        return nil
    }
}

enum SplitSide: Equatable { case left, right }

extension Browser {
    var activePair: SplitPair? {
        guard prefs.splitViews, let activeID else { return nil }
        return splitPairs.first { $0.contains(activeID) }
    }

    var visiblePair: SplitPair? {
        splitCanShow && pendingSplit == nil ? activePair : nil
    }

    func pair(for tab: Tab) -> SplitPair? { splitPairs.first { $0.contains(tab.id) } }

    func startSplit(_ tab: Tab) {
        guard prefs.splitViews, pair(for: tab) == nil, tabs.contains(where: { $0.id == tab.id }) else { return }
        select(tab)
        pendingSplit = tab.id
    }

    func finishSplit(with id: Tab.ID) {
        guard let right = pendingSplit, right != id,
              tabs.contains(where: { $0.id == right }), tabs.contains(where: { $0.id == id }) else { return }
        if floating == right || floating == id { land() }
        splitPairs.removeAll { $0.contains(id) || $0.contains(right) }
        splitPairs.append(SplitPair(left: id, right: right))
        pendingSplit = nil
        activeID = right
        wakeSplitPartner()
        writeSession(now: true)
    }

    func put(_ id: Tab.ID, on side: SplitSide, of pairID: UUID) {
        guard let target = splitPairs.firstIndex(where: { $0.id == pairID }),
              tabs.contains(where: { $0.id == id }) else { return }
        let old = side == .left ? splitPairs[target].left : splitPairs[target].right
        guard id != old, !splitPairs[target].contains(id) else { return }
        if floating == id { land() }
        splitPairs.removeAll { $0.id != pairID && $0.contains(id) }
        guard let index = splitPairs.firstIndex(where: { $0.id == pairID }) else { return }
        if side == .left { splitPairs[index].left = id } else { splitPairs[index].right = id }
        activeID = id
        if let tab = tabs.first(where: { $0.id == id }) { if !tab.wake() { tab.revive() } }
        writeSession(now: true)
    }

    func unsplit(_ tab: Tab) {
        guard let pair = pair(for: tab) else { return }
        let mostRecent = tabs.filter { pair.contains($0.id) }.max { $0.touched < $1.touched }
        let fill = activeID.flatMap { id in pair.contains(id) ? tabs.first(where: { $0.id == id }) : nil }
        splitPairs.removeAll { $0.id == pair.id }
        if let fill = fill ?? mostRecent { select(fill) }
        writeSession(now: true)
    }

    /// Returns the surviving member, for Close Tab and the pinned tab's rest.
    @discardableResult
    func removeFromSplit(_ id: Tab.ID) -> Tab.ID? {
        if pendingSplit == id { pendingSplit = nil }
        guard let pair = splitPairs.first(where: { $0.contains(id) }) else { return nil }
        splitPairs.removeAll { $0.id == pair.id }
        return pair.other(than: id)
    }

    func replaceSplitTab(_ old: Tab.ID, with new: Tab.ID) {
        if pendingSplit == old { pendingSplit = new }
        for index in splitPairs.indices {
            if splitPairs[index].left == old { splitPairs[index].left = new }
            if splitPairs[index].right == old { splitPairs[index].right = new }
        }
    }

    func wakeSplitPartner() {
        guard let pair = activePair, let activeID, let other = pair.other(than: activeID),
              let tab = tabs.first(where: { $0.id == other }) else { return }
        if !tab.wake() { tab.revive() }
    }

    func setSplitFraction(_ fraction: Double, for id: UUID, save: Bool = false) {
        guard let index = splitPairs.firstIndex(where: { $0.id == id }) else { return }
        splitPairs[index].fraction = min(0.75, max(0.25, fraction))
        if save { writeSession(now: true) }
    }

    func focusSplitPage(at event: NSEvent) {
        guard let pair = visiblePair, let window = event.window else { return }
        for id in [pair.left, pair.right] {
            guard let tab = tabs.first(where: { $0.id == id }), let web = tab.built,
                  web.window === window else { continue }
            if web.bounds.contains(web.convert(event.locationInWindow, from: nil)) {
                select(tab)
                return
            }
        }
    }
}

/// A tab drag carries its identity, never its address or private page data.
enum SplitDrag {
    static let type = "public.utf8-plain-text"

    static func provider(_ id: Tab.ID) -> NSItemProvider {
        return NSItemProvider(object: id.uuidString as NSString)
    }

    static func receive(_ providers: [NSItemProvider], use: @escaping (Tab.ID) -> Void) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(type) }) else { return false }
        provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
            guard let data, let text = String(data: data, encoding: .utf8), let id = UUID(uuidString: text) else { return }
            DispatchQueue.main.async { use(id) }
        }
        return true
    }
}

struct SplitSource: ViewModifier {
    @ObservedObject var browser: Browser
    let tab: Tab

    func body(content: Content) -> some View {
        if browser.prefs.splitViews && !tab.bench {
            content.onDrag { SplitDrag.provider(tab.id) }
        } else {
            content
        }
    }
}
