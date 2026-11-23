import Foundation

/// Accessibility › Source order viewer: the selected element's descendants
/// numbered in the order they come in the DOM, which is the order a screen
/// reader and the Tab key meet them in, whatever the layout does.
enum DeveloperSourceOrder {
    /// The most badges drawn, so a huge subtree can't stall the page.
    static let cap = 1000

    struct Badge: Equatable {
        let node: Int
        let number: Int
    }

    /// The badges, as the page draws them: every element under `root` that
    /// has a box (`numbered`), depth first in document order, numbered from
    /// 1. The root itself is outlined, not numbered.
    static func badges(under root: Int, children: (Int) -> [Int], numbered: (Int) -> Bool,
                       cap: Int = cap) -> [Badge] {
        var badges: [Badge] = []
        var stack = Array(children(root).reversed())
        while let node = stack.popLast(), badges.count < cap {
            if numbered(node) { badges.append(Badge(node: node, number: badges.count + 1)) }
            stack.append(contentsOf: children(node).reversed())
        }
        return badges
    }

    /// What the pane says under the checkbox once the badges are drawn.
    static func summary(shown: Int, capped: Bool) -> String? {
        if shown == 0 { return "No source order information available" }
        if capped { return "Showing source order for the first \(cap) elements" }
        return nil
    }
}

extension DeveloperToolsSession {
    /// Shows source order badges for `node`, or takes them down (nil).
    func showSourceOrder(_ node: Int?) {
        if node == nil, elements.sourceOrder == nil { return }
        elements.sourceOrder = node.map { DeveloperElementsState.SourceOrder(node: $0) }
        run { session in
            let raw = try await session.elementsBridge("return await perchElements.setSourceOrder(node, target, on, cap);", [
                "node": node as Any? ?? NSNull(), "target": session.domTargetID as Any? ?? NSNull(),
                "on": node != nil, "cap": DeveloperSourceOrder.cap,
            ]) as? [String: Any]
            guard let node, session.elements.sourceOrder?.node == node else { return }
            session.elements.sourceOrder = DeveloperElementsState.SourceOrder(
                node: node, shown: raw?["shown"] as? Int, capped: raw?["capped"] as? Bool == true)
        }
    }
}
