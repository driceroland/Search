import Foundation

/// Performance's breadcrumbs, as in Chrome DevTools: each range zoomed
/// into from the overview adds one above it, "Full range (1.2 s)" ›
/// "380 ms" › …; clicking one returns to its range. A range zoomed into
/// from a breadcrumb replaces those after it, and one outside the
/// breadcrumb shown goes under the nearest one around it. A new
/// recording starts again from its full range.
struct DeveloperPerformanceBreadcrumbs: Equatable {
    private(set) var crumbs: [DeveloperFlameWindow]
    /// The breadcrumb shown, in `crumbs`.
    private(set) var active = 0

    init(_ full: ClosedRange<Double> = 0...1) {
        crumbs = [DeveloperFlameWindow(full)]
    }

    var full: DeveloperFlameWindow { crumbs[0] }
    var current: DeveloperFlameWindow { crumbs[active] }

    /// A new recording: only its full range.
    mutating func reset(_ full: ClosedRange<Double>) {
        crumbs = [DeveloperFlameWindow(full)]
        active = 0
    }

    /// A range zoomed into. Nothing is added for the range already shown,
    /// for the full range, or for a range no narrower than its parent.
    mutating func push(_ window: DeveloperFlameWindow) {
        var parent = active
        while parent > 0, !Self.contains(crumbs[parent], window) { parent -= 1 }
        crumbs.removeSubrange((parent + 1)...)
        active = parent
        let around = crumbs[parent]
        guard Self.contains(around, window), !Self.same(around, window) else { return }
        crumbs.append(window)
        active = crumbs.count - 1
    }

    /// A breadcrumb clicked: its range, the ones after it kept until
    /// another range is zoomed into.
    @discardableResult
    mutating func select(_ index: Int) -> DeveloperFlameWindow {
        guard crumbs.indices.contains(index) else { return current }
        active = index
        return crumbs[index]
    }

    /// "Full range (1.2 s)" for the first, the span for the others.
    func label(_ index: Int) -> String {
        guard crumbs.indices.contains(index) else { return "" }
        let span = DeveloperPerformanceRuler.label(crumbs[index].upper - crumbs[index].lower)
        return index == 0 ? "Full range (\(span))" : span
    }

    private static let slack = 0.000_1

    static func contains(_ outer: DeveloperFlameWindow, _ inner: DeveloperFlameWindow) -> Bool {
        inner.lower >= outer.lower - slack && inner.upper <= outer.upper + slack
    }

    static func same(_ a: DeveloperFlameWindow, _ b: DeveloperFlameWindow) -> Bool {
        abs(a.lower - b.lower) <= slack && abs(a.upper - b.upper) <= slack
    }
}
