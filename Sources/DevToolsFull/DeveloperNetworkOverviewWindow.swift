import AppKit
import SwiftUI

/// The part of the Network overview chosen with the mouse, as in Chrome
/// DevTools: drag across the overview to choose a span of time, and the list
/// keeps the requests in it while the waterfall column shows just that span.
/// Drag a handle to move one edge, drag inside to slide the whole span, and
/// double-click to go back to the whole recording.
struct DeveloperNetworkOverviewWindow: View {
    @Binding var window: ClosedRange<Double>?
    let timing: DeveloperNetworkTiming
    /// The overview's chart starts this far from each side.
    let inset: CGFloat
    /// The ruler's labels sit above this, out of the dimming.
    let top: CGFloat

    @State private var drag: Drag?

    /// What the drag under way is doing, with where things stood at its start.
    enum Drag: Equatable {
        case choose(from: CGFloat)
        case lower, upper
        case slide(start: ClosedRange<CGFloat>, from: CGFloat)
    }

    /// How close to an edge counts as its handle.
    static let grip: CGFloat = 5
    /// A drag shorter than this is a click, and leaves the span as it was.
    static let least: CGFloat = 3

    var body: some View {
        GeometryReader { space in
            let width = max(1, space.size.width - inset * 2)
            let span = window.map { positions($0, width: width) }
            ZStack(alignment: .topLeading) {
                if let span {
                    shade(span, size: space.size)
                }
            }
            .frame(width: space.size.width, height: space.size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(dragGesture(width: width))
            .simultaneousGesture(TapGesture(count: 2).onEnded { window = nil })
            .onContinuousHover { phase in
                guard drag == nil else { return }
                switch phase {
                case .active(let point):
                    if let span, Self.handle(at: point.x - inset, span: span) != nil {
                        NSCursor.resizeLeftRight.set()
                    } else {
                        NSCursor.arrow.set()
                    }
                case .ended:
                    NSCursor.arrow.set()
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Overview time selection")
        .accessibilityValue(window.map { range in
            let from = (range.lowerBound - timing.origin) * 1_000
            let to = (range.upperBound - timing.origin) * 1_000
            return "\(Int(from.rounded())) ms to \(Int(to.rounded())) ms"
        } ?? "Whole recording")
        .accessibilityAction(named: "Show whole recording") { window = nil }
    }

    /// Where `range` falls across a chart `width` wide, from the chart's left.
    private func positions(_ range: ClosedRange<Double>, width: CGFloat) -> ClosedRange<CGFloat> {
        let low = timing.fraction(range.lowerBound) * width
        let high = timing.fraction(range.upperBound) * width
        return min(low, high)...max(low, high)
    }

    /// Grey over what is left out, the chosen span's edges, and a handle on
    /// each, as Chrome draws them.
    private func shade(_ span: ClosedRange<CGFloat>, size: CGSize) -> some View {
        let dim = Color.primary.opacity(0.08)
        let left = inset + span.lowerBound
        let right = inset + span.upperBound
        let height = size.height - top
        return ZStack(alignment: .topLeading) {
            dim.frame(width: max(0, left), height: height).offset(y: top)
            dim.frame(width: max(0, size.width - right), height: height).offset(x: right, y: top)
            ForEach([left, right], id: \.self) { x in
                Rectangle().fill(DeveloperToolsStyle.tint.opacity(0.65))
                    .frame(width: 1, height: height)
                    .offset(x: x - 0.5, y: top)
                RoundedRectangle(cornerRadius: 2)
                    .fill(DeveloperToolsStyle.tint)
                    .frame(width: 5, height: 14)
                    .offset(x: x - 2.5, y: top + (height - 14) / 2)
            }
        }
        .allowsHitTesting(false)
    }

    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let start = value.startLocation.x - inset
                let x = min(width, max(0, value.location.x - inset))
                if drag == nil {
                    let span = window.map { positions($0, width: width) }
                    if let span, let edge = Self.handle(at: start, span: span) {
                        drag = edge
                    } else if let span, span.contains(start) {
                        drag = .slide(start: span, from: start)
                    } else {
                        drag = .choose(from: min(width, max(0, start)))
                    }
                }
                guard let drag else { return }
                let moved = abs(value.location.x - value.startLocation.x)
                switch drag {
                case .choose(let from):
                    guard moved >= Self.least else { return }
                    window = range(min(from, x), max(from, x), width: width)
                case .lower, .upper:
                    guard let current = window.map({ positions($0, width: width) }) else { return }
                    let other = drag == .lower ? current.upperBound : current.lowerBound
                    window = range(min(other, x), max(other, x), width: width)
                case .slide(let start, let from):
                    let length = start.upperBound - start.lowerBound
                    let low = min(width - length, max(0, start.lowerBound + (value.location.x - inset - from)))
                    window = range(low, low + length, width: width)
                }
            }
            .onEnded { _ in
                drag = nil
            }
    }

    /// The times between `low` and `high` across a chart `width` wide. A
    /// span that would show nothing stays at a pixel at least.
    private func range(_ low: CGFloat, _ high: CGFloat, width: CGFloat) -> ClosedRange<Double> {
        let from = timing.time(at: low / width)
        let to = timing.time(at: max(high, low + 1) / width)
        return from...max(to, from + timing.span / Double(width))
    }

    /// The edge whose handle is at `x`, from the chart's left, if any; the
    /// nearer one when the span is narrow.
    static func handle(at x: CGFloat, span: ClosedRange<CGFloat>) -> Drag? {
        let low = abs(x - span.lowerBound)
        let high = abs(x - span.upperBound)
        guard min(low, high) <= grip else { return nil }
        return low <= high ? .lower : .upper
    }
}
