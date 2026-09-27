import Foundation

/// Tabs shown side by side, sharing one place in the row. The first tab is
/// the pair's place among the others; the rest follow it, next to it.
///
/// Two in 1.0.5, side by side. The shape is a list with an axis so that one
/// above the other, or a third page, needs no other file format later: the
/// file keeps these as they are (see Session.Split).
struct TabSplit: Identifiable, Equatable {
    enum Axis: String, Codable {
        /// Side by side, the first on the left.
        case horizontal
        /// One above the other, the first on top.
        case vertical
    }

    let id: UUID
    /// In the order they are shown.
    var tabs: [Tab.ID]
    var axis: Axis
    /// Each page's share of the stage, in the same order, adding up to 1.
    var sizes: [Double]
    /// The page last focused, to come back to.
    var focused: Tab.ID?

    init(id: UUID = UUID(), tabs: [Tab.ID], axis: Axis = .horizontal,
         sizes: [Double]? = nil, focused: Tab.ID? = nil) {
        self.id = id
        self.tabs = tabs
        self.axis = axis
        self.sizes = TabSplit.even(tabs.count)
        self.focused = focused.flatMap { tabs.contains($0) ? $0 : nil }
        if let sizes, sizes.count == tabs.count { self.sizes = TabSplit.clamp(sizes) }
    }

    init(left: Tab.ID, right: Tab.ID, fraction: Double = 0.5) {
        self.init(tabs: [left, right], sizes: [fraction, 1 - fraction])
    }

    /// The first page: the pair's place in the row.
    var left: Tab.ID { tabs[0] }
    /// The last page.
    var right: Tab.ID { tabs[tabs.count - 1] }

    /// The first page's share, for two pages.
    var fraction: Double {
        get { sizes.first ?? 0.5 }
        set { sizes = TabSplit.clamp([newValue, 1 - newValue]) }
    }

    func contains(_ tab: Tab.ID) -> Bool { tabs.contains(tab) }

    /// The other page of two.
    func partner(of tab: Tab.ID) -> Tab.ID? {
        guard contains(tab) else { return nil }
        return tabs.first { $0 != tab }
    }

    mutating func replace(_ old: Tab.ID, with new: Tab.ID) {
        tabs = tabs.map { $0 == old ? new : $0 }
        if focused == old { focused = new }
    }

    /// No page narrower than a fifth of the stage; shares that add up to 1.
    static func clamp(_ sizes: [Double]) -> [Double] {
        guard sizes.count == 2 else {
            let finite = sizes.map { $0.isFinite && $0 > 0 ? $0 : 1 }
            let total = finite.reduce(0, +)
            return finite.map { $0 / total }
        }
        let first = min(0.8, max(0.2, sizes[0].isFinite ? sizes[0] : 0.5))
        return [first, 1 - first]
    }

    static func even(_ count: Int) -> [Double] {
        Array(repeating: 1 / Double(max(1, count)), count: count)
    }
}
