import AppKit
import SwiftUI

/// Where a popover hangs, its arrow kept clear of the popover's corners.
///
/// A popover is centred on its button along the side it hangs from. With
/// the button near an edge of the screen there is no room to centre it:
/// AppKit slides the popover along until it fits, the arrow stays on the
/// button, and the arrow ends up in the popover's rounded corner, drawn
/// bent into the curve. Beside a button at the column's foot, with the
/// window down to the foot of the screen, that's the bottom corner; above
/// or under a button near the screen's left or right edge, a side corner.
/// NSPopover has no way to move the arrow, and only turns to another side
/// when the one asked for has no room at all.
///
/// So the point the popover hangs from is moved along its side, away from
/// the screen's edge, just far enough for the arrow to stand clear of the
/// corner. Beside a button, that's only while the arrow still points at
/// the button; further, and the popover hangs above it instead (under it,
/// at the top of the screen), moved sideways the same way if it has to be.
enum PopoverSide {
    /// Nearer than this, from the edge of the screen to the arrow, the
    /// arrow meets the corner. Measured with plain NSPopovers on macOS 27,
    /// from the foot of the screen and from its left edge alike: bent at 20
    /// to 44, clean from 48.
    static let clearance: CGFloat = 52

    /// A popover asked for beside its button hung above or under it instead.
    enum Turn: Equatable { case none, above, under }

    struct Placement: Equatable {
        var turn: Turn
        /// How far to move the point it hangs from, in screen points, y up.
        var move: CGVector
    }

    /// How far to move an arrow pointing at `middle` so it stands at least
    /// `clearance` inside `low...high`, the screen's extent along the
    /// popover's side. Zero when it is clear already, or the screen is too
    /// small to be clear of both ends.
    static func shift(_ middle: CGFloat, low: CGFloat, high: CGFloat) -> CGFloat {
        guard high - low >= 2 * clearance else { return 0 }
        return min(max(middle, low + clearance), high - clearance) - middle
    }

    /// Where a popover hangs from `frame`, on a screen whose usable part is
    /// `room`, both in screen points: on a side of it (`beside`), or above
    /// or under it.
    static func placement(of frame: NSRect, in room: NSRect, beside: Bool) -> Placement {
        let across = Placement(turn: .none, move: CGVector(dx: shift(frame.midX, low: room.minX, high: room.maxX), dy: 0))
        guard beside else { return across }
        let up = shift(frame.midY, low: room.minY, high: room.maxY)
        // Moved no further than the button's own edge, the arrow still
        // points at the button.
        if abs(up) <= frame.height / 2 { return Placement(turn: .none, move: CGVector(dx: 0, dy: up)) }
        return Placement(turn: up > 0 ? .above : .under, move: across.move)
    }

    /// The same for `rect` in `view`, measured on the screen the rect is on,
    /// which needn't be the one most of the window is on. As asked while the
    /// view is in no window.
    static func placement(of rect: NSRect, in view: NSView, beside: Bool) -> Placement {
        guard let window = view.window else { return Placement(turn: .none, move: .zero) }
        let frame = window.convertToScreen(view.convert(rect, to: nil))
        let middle = NSPoint(x: frame.midX, y: frame.midY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(middle) }) ?? window.screen
        else { return Placement(turn: .none, move: .zero) }
        return placement(of: frame, in: screen.visibleFrame, beside: beside)
    }

    /// NSPopover.show(relativeTo:of:preferredEdge:), hung as above.
    static func show(_ popover: NSPopover, relativeTo rect: NSRect, of view: NSView, preferredEdge edge: NSRectEdge) {
        let place = placement(of: rect, in: view, beside: edge == .minX || edge == .maxX)
        let flipped = view.isFlipped
        let side: NSRectEdge
        switch place.turn {
        case .none: side = edge
        case .above: side = flipped ? .minY : .maxY
        case .under: side = flipped ? .maxY : .minY
        }
        let moved = rect.offsetBy(dx: place.move.dx, dy: flipped ? -place.move.dy : place.move.dy)
        // Moved off every view that could hold it, the popover hangs from
        // the button itself, its arrow in the corner as before.
        let hung = holder(of: moved, in: view, edge: side) ?? (view, rect, side)
        popover.show(relativeTo: hung.rect, of: hung.view, preferredEdge: hung.edge)
    }

    /// The view a popover is shown from, for a rect that may have been
    /// moved off `view`: `view` itself while the rect still touches it,
    /// else the nearest view above that it touches, with the rect, and the
    /// side, as that view counts them. Nil when no view above holds it.
    ///
    /// NSPopover shows nothing, and says nothing, when the rect it is to
    /// hang from lies wholly outside the view it is given (macOS 27.0 and
    /// 27.2: shown with one point of the rect on the view, not with none).
    /// A button is 26 points wide and the arrow can move up to `clearance`:
    /// an extension's popup whose button stood first at the column's foot,
    /// in a window against the screen's left edge, was moved 29 points and
    /// never opened — the click loaded its page in a view no window held.
    static func holder(of rect: NSRect, in view: NSView, edge: NSRectEdge) -> (view: NSView, rect: NSRect, edge: NSRectEdge)? {
        if view.bounds.intersects(rect) { return (view, rect, edge) }
        var above = view.superview
        while let host = above {
            let there = host.convert(rect, from: view)
            if host.bounds.intersects(there) {
                // A side is named in the view's own coordinates: top is
                // maxY in one that counts y upwards, minY in a flipped one.
                let turned = host.isFlipped != view.isFlipped
                let side: NSRectEdge = !turned ? edge : edge == .minY ? .maxY : edge == .maxY ? .minY : edge
                return (host, there, side)
            }
            above = host.superview
        }
        return nil
    }
}

extension View {
    /// `.popover(isPresented:arrowEdge:)`, hung as PopoverSide says. It
    /// opens once this view is in its window, so there is something to
    /// measure: a popover asked for with the view, as a group's name is with
    /// the group, would otherwise be placed before the view had a place.
    func popover<Content: View>(isPresented: Binding<Bool>, hangingFrom edge: Edge,
                                @ViewBuilder content: @escaping () -> Content) -> some View {
        modifier(HangingPopover(isPresented: isPresented, edge: edge, popup: content))
    }
}

private struct HangingPopover<Popup: View>: ViewModifier {
    @Binding var isPresented: Bool
    let edge: Edge
    let popup: () -> Popup
    @State private var spot = Spot()
    @State private var placed = false

    func body(content: Content) -> some View {
        let open = isPresented && placed
        let hang = spot.hang(open: open, asked: edge)
        return content
            .background(Holder(spot: spot, placed: $placed))
            .popover(isPresented: Binding(get: { open }, set: { isPresented = $0 }),
                     attachmentAnchor: hang.anchor, arrowEdge: hang.edge, content: popup)
    }

    /// The view measured, and where the popover hangs, chosen as it opened:
    /// held while it's up, so a window moved under it doesn't send it
    /// sliding or round to another side.
    final class Spot {
        weak var view: NSView?
        private var held: (anchor: PopoverAttachmentAnchor, edge: Edge)?

        func hang(open: Bool, asked: Edge) -> (anchor: PopoverAttachmentAnchor, edge: Edge) {
            guard open else { held = nil; return (.rect(.bounds), asked) }
            if let held { return held }
            var hang: (anchor: PopoverAttachmentAnchor, edge: Edge) = (.rect(.bounds), asked)
            if let view, view.window != nil, view.bounds.width > 0, view.bounds.height > 0 {
                let place = PopoverSide.placement(of: view.bounds, in: view, beside: asked == .leading || asked == .trailing)
                switch place.turn {
                case .none: break
                case .above: hang.edge = .top
                case .under: hang.edge = .bottom
                }
                // In screen points, y up; SwiftUI's own are y down.
                if place.move != .zero {
                    hang.anchor = .rect(.rect(CGRect(origin: CGPoint(x: place.move.dx, y: -place.move.dy), size: view.bounds.size)))
                }
            }
            held = hang
            return hang
        }
    }

    private struct Holder: NSViewRepresentable {
        let spot: Spot
        @Binding var placed: Bool

        func makeNSView(context: Context) -> Watched {
            let view = Watched()
            spot.view = view
            view.moved = { [weak view] in
                // After this pass, laid out by then: the popover opens on
                // the next, measured.
                DispatchQueue.main.async { if let view { placed = view.window != nil } }
            }
            return view
        }

        func updateNSView(_ view: Watched, context: Context) { spot.view = view }
    }

    final class Watched: NSView {
        var moved: (() -> Void)?
        /// Only there to be measured: a click, a right-click above all,
        /// goes to what it sits behind (a group's name has its menu).
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            moved?()
        }
    }
}
