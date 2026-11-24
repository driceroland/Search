import Foundation

/// Tabs shown side by side, sharing one place in the row. The first tab is
/// the split's place among the others; the rest follow it, next to it.
///
/// Two to four pages, side by side (`most`). The shape is a list with an
/// axis, so one above the other needs no other file format later: the file
/// keeps these as they are (see Session.Split), and a file written with two
/// reads as it always did.
struct TabSplit: Identifiable, Equatable {
    enum Axis: String, Codable {
        /// Side by side, the first on the left.
        case horizontal
        /// One above the other, the first on top.
        case vertical
    }

    /// The most pages one split holds, as Arc's: past four side by side,
    /// each is too narrow to read in most windows.
    static let most = 4

    let id: UUID
    /// In the order they are shown.
    var tabs: [Tab.ID]
    var axis: Axis
    /// Each page's share of the stage, in the same order, adding up to 1.
    var sizes: [Double]
    /// The page last focused, to come back to.
    var focused: Tab.ID?
    /// The divider's menu › Sync Scrolling: one page scrolled, the others
    /// go by as much (see Browser.syncScroll).
    var syncsScroll: Bool

    init(id: UUID = UUID(), tabs: [Tab.ID], axis: Axis = .horizontal,
         sizes: [Double]? = nil, focused: Tab.ID? = nil, syncsScroll: Bool = false) {
        self.id = id
        self.tabs = tabs
        self.axis = axis
        self.syncsScroll = syncsScroll
        self.sizes = TabSplit.even(tabs.count)
        self.focused = focused.flatMap { tabs.contains($0) ? $0 : nil }
        if let sizes, sizes.count == tabs.count { self.sizes = TabSplit.clamp(sizes) }
    }

    init(left: Tab.ID, right: Tab.ID, fraction: Double = 0.5) {
        self.init(tabs: [left, right], sizes: [fraction, 1 - fraction])
    }

    /// The first page: the split's place in the row.
    var left: Tab.ID { tabs[0] }
    /// The last page.
    var right: Tab.ID { tabs[tabs.count - 1] }

    /// The first page's share.
    var fraction: Double {
        get { sizes.first ?? 0.5 }
        set { sizes = TabSplit.clamp([newValue, 1 - newValue]) }
    }

    /// No room for another page.
    var isFull: Bool { tabs.count >= TabSplit.most }

    func contains(_ tab: Tab.ID) -> Bool { tabs.contains(tab) }

    /// The page beside this one: the next to its right, or, for the last,
    /// the one to its left. Of two, the other one. Where the keys go when
    /// this one leaves.
    func partner(of tab: Tab.ID) -> Tab.ID? {
        guard let index = tabs.firstIndex(of: tab), tabs.count > 1 else { return nil }
        return index + 1 < tabs.count ? tabs[index + 1] : tabs[index - 1]
    }

    /// Whether `tab` stands before `other` in it (to the left, side by side).
    func isBefore(_ tab: Tab.ID, _ other: Tab.ID?) -> Bool {
        guard let other, let a = tabs.firstIndex(of: tab), let b = tabs.firstIndex(of: other) else { return false }
        return a < b
    }

    /// Every page but this one, in order.
    func others(than tab: Tab.ID) -> [Tab.ID] { tabs.filter { $0 != tab } }

    mutating func replace(_ old: Tab.ID, with new: Tab.ID) {
        tabs = tabs.map { $0 == old ? new : $0 }
        if focused == old { focused = new }
    }

    /// A page added beside `neighbour` (after it, or before it), or at the
    /// end. The pages are made even, as each one coming in is given an
    /// equal share. Nothing when full, or already in it.
    @discardableResult
    mutating func insert(_ tab: Tab.ID, beside neighbour: Tab.ID? = nil, before: Bool = false) -> Bool {
        guard !isFull, !contains(tab) else { return false }
        let at = neighbour.flatMap { tabs.firstIndex(of: $0) }.map { before ? $0 : $0 + 1 } ?? tabs.count
        tabs.insert(tab, at: at)
        sizes = TabSplit.even(tabs.count)
        return true
    }

    /// A page out of it: the others keep their order, and its share goes
    /// to them in proportion. Whether two or more are left — one alone is
    /// no split, and the caller lets it go.
    @discardableResult
    mutating func remove(_ tab: Tab.ID) -> Bool {
        guard let index = tabs.firstIndex(of: tab) else { return tabs.count >= 2 }
        tabs.remove(at: index)
        if sizes.count > index { sizes.remove(at: index) }
        if sizes.count != tabs.count { sizes = TabSplit.even(tabs.count) }
        let total = sizes.reduce(0, +)
        if !tabs.isEmpty, total.isFinite, total > 0 { sizes = TabSplit.clamp(sizes.map { $0 / total }) }
        if focused == tab { focused = nil }
        return tabs.count >= 2
    }

    /// The narrowest share a page has, of `count`: a fifth of the stage
    /// for two, as it always was; a tenth for three or four.
    static func least(_ count: Int) -> Double { count <= 2 ? 0.2 : 0.1 }

    /// No page narrower than its least share; shares that add up to 1.
    static func clamp(_ sizes: [Double]) -> [Double] {
        if sizes.count == 2 {
            let first = min(0.8, max(0.2, sizes[0].isFinite ? sizes[0] : 0.5))
            return [first, 1 - first]
        }
        let finite = sizes.map { $0.isFinite && $0 > 0 ? $0 : 1 }
        let total = finite.reduce(0, +)
        guard total > 0 else { return even(sizes.count) }
        var shares = finite.map { $0 / total }
        guard shares.count > 2 else { return shares }
        // Raise any page under its least share, taking the difference from
        // the pages above it in proportion to what they have over theirs.
        let least = least(shares.count)
        let short = shares.reduce(0) { $0 + max(0, least - $1) }
        guard short > 0 else { return shares }
        let spare = shares.reduce(0) { $0 + max(0, $1 - least) }
        shares = shares.map { share in
            share < least ? least : share - (share - least) / spare * short
        }
        return shares
    }

    static func even(_ count: Int) -> [Double] {
        Array(repeating: 1 / Double(max(1, count)), count: count)
    }
}
