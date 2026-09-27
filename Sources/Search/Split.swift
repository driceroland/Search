import Foundation

/// Two tabs that share one place in the tab strip. The left tab is the
/// group's position in the ordered row; the right tab follows it.
struct TabSplit: Identifiable, Equatable {
    let id: UUID
    var left: UUID
    var right: UUID
    var fraction: Double

    init(id: UUID = UUID(), left: UUID, right: UUID, fraction: Double = 0.5) {
        self.id = id
        self.left = left
        self.right = right
        self.fraction = min(0.8, max(0.2, fraction.isFinite ? fraction : 0.5))
    }

    func contains(_ tab: UUID) -> Bool { left == tab || right == tab }

    mutating func replace(_ old: UUID, with new: UUID) {
        if left == old { left = new }
        if right == old { right = new }
    }
}
