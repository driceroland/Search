import SwiftUI

/// A tab carried across the line between the pins and the tabs, as in Arc:
/// a tab let go over the grid becomes a pin there, a pin let go among the
/// tabs becomes a tab there, and the block it is over makes room for it on
/// the way — a place opened in the grid, a line opened among the rows —
/// so where it will land is seen before it is let go.
///
/// The gestures stay each row's and each square's own (Carried,
/// PinCarried); this is only where in the column the hand is, worked out
/// in one space every block is measured in (the page's, "column").
enum PinDrop {
    /// Where a carried tab would land.
    enum Target: Equatable {
        /// Among the squares, at this place.
        case squares(Int)
        /// Among the pinned rows (Settings › Tabs › Pinned rows).
        case listed(Int)
        /// Among the tabs in no group.
        case loose(Int)
        /// Into a group, over its heading.
        case group(UUID)
    }

    /// The tab being carried and where it would land: what the column
    /// shows while it is over a block that would take it.
    struct Crossing: Equatable {
        let tab: Tab.ID
        let target: Target
    }

    enum Zone: Equatable { case squares, listed, loose, none }

    /// The half of the margin under the grid that still counts as the
    /// grid, so the hand needn't reach a square to aim between two.
    static let gridSlack: CGFloat = 5
    /// How far beside the column the hand may stray and still be in it.
    static let sideSlack: CGFloat = 10

    /// Which block a point is over, in the column's space: the grid's —
    /// everything above its bottom edge, the band of the window's buttons
    /// included, which is where a first pin is made when there is none —
    /// then the pinned rows, then the tabs. Beside the column, none.
    /// `gridBottom` nil: no grid drawn, and its block is above the page.
    static func zone(_ point: CGPoint, width: CGFloat, gridBottom: CGFloat?, listed: CGRect?) -> Zone {
        guard point.x >= -sideSlack, point.x <= width + sideSlack else { return .none }
        let edge = gridBottom.map { $0 + gridSlack } ?? 0
        if point.y < edge { return .squares }
        if let listed, listed.height > 0, point.y < listed.maxY + 1 { return .listed }
        return .loose
    }

    /// The place among the squares a point is over, once the grid has made
    /// room for one more: the nearest of `cells`, laid out for that many.
    /// The place opened is one of them, so the hand over it keeps it.
    static func gridSlot(_ point: CGPoint, cells: [CGRect]) -> Int {
        func distance(_ cell: CGRect) -> CGFloat { hypot(cell.midX - point.x, cell.midY - point.y) }
        return cells.indices.min { distance(cells[$0]) < distance(cells[$1]) } ?? 0
    }

    /// The place among rows of `heights` (top to bottom, `gap` between) a
    /// point `y` down from the first is over: before the first row whose
    /// middle it is above. `ghost`: the line already opened, at its place
    /// and of its height — the hand anywhere on it keeps it, and the rows
    /// after it are measured where they now are, below it.
    static func rowSlot(y: CGFloat, heights: [CGFloat], gap: CGFloat, ghost: (at: Int, height: CGFloat)?) -> Int {
        var top: CGFloat = 0
        for (index, height) in heights.enumerated() {
            if let ghost, ghost.at == index {
                if y < top + ghost.height { return index }
                top += ghost.height + gap
            }
            if y < top + height / 2 { return index }
            top += height + gap
        }
        return heights.count
    }
}

/// Where the column's blocks are, in its space. Kept out of SwiftUI's
/// state on purpose: measured on every layout and every scroll, and read
/// only while a tab is carried, it must not draw the column again.
final class ColumnFrames {
    var grid: CGRect?
    var listed: CGRect?
    var rows: CGRect = .zero
    var loose: CGRect?
}

/// The place opened in the grid for a tab carried there: its mark, faint,
/// on the hover grey.
struct PinGhost: View {
    @Environment(\.greys) private var greys
    @ObservedObject var tab: Tab
    let width: CGFloat
    let height: CGFloat

    private var scale: CGFloat { min(width, height) }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: scale * 9 / 34, style: .continuous)
        shape
            .fill(greys.hover)
            .overlay { shape.strokeBorder(Palette.ink.opacity(0.16), lineWidth: 1) }
            .overlay {
                Mark(icon: tab.icon, letter: tab.pin ?? tab.monogram, size: scale * 16 / 34)
                    .opacity(0.55)
            }
            .frame(width: width, height: height)
            .allowsHitTesting(false)
            .transition(.scale(scale: 0.8).combined(with: .opacity))
    }
}

/// The line opened among the rows for a tab carried there: its mark and
/// name, faint, on the hover grey.
struct RowGhost: View {
    @Environment(\.greys) private var greys
    @ObservedObject var tab: Tab
    let height: CGFloat
    let size: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        HStack(spacing: 8) {
            Mark(icon: tab.icon, letter: tab.monogram, size: 15)
            Text(tab.label)
                .font(.system(size: size))
                .lineLimit(1)
                .foregroundStyle(Palette.muted)
            Spacer(minLength: 0)
        }
        .opacity(0.6)
        .padding(.leading, 10)
        .frame(height: height)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(greys.hover))
        .overlay { shape.strokeBorder(Palette.ink.opacity(0.16), lineWidth: 1) }
        .allowsHitTesting(false)
        .transition(.opacity)
    }
}
