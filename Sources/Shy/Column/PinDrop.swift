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
        /// Among the pinned rows.
        case listed(Int)
        /// Among the tabs that aren't pins.
        case loose(Int)
        /// Into a folder, at this place among its tabs; nil, at their end.
        case folder(UUID, at: Int?)
    }

    /// The tab being carried and where it would land: what the column
    /// shows while it is over a block that would take it.
    struct Crossing: Equatable {
        let tab: Tab.ID
        let target: Target
    }

    enum Zone: Equatable { case squares, listed, folders, loose, none }

    /// Where a folder carried by its row would go: among the folders in
    /// `parent` (nil, the top), at `at`, counted without it.
    struct Place: Equatable {
        let folder: UUID
        let parent: UUID?
        let at: Int
    }

    /// The half of the margin under the grid that still counts as the
    /// grid, so the hand needn't reach a square to aim between two.
    static let gridSlack: CGFloat = 5
    /// How far beside the column the hand may stray and still be in it.
    static let sideSlack: CGFloat = 10

    /// Which block a point is over, in the column's space: the grid's —
    /// everything above its bottom edge, the band of the window's buttons
    /// included, which is where a first pin is made when there is none —
    /// then the pinned rows, then the folders, then the tabs. Beside the
    /// column, none. `gridBottom` nil: no grid drawn, and its block is
    /// above the page.
    static func zone(_ point: CGPoint, width: CGFloat, gridBottom: CGFloat?, listed: CGRect?, folders: CGRect? = nil) -> Zone {
        guard point.x >= -sideSlack, point.x <= width + sideSlack else { return .none }
        let edge = gridBottom.map { $0 + gridSlack } ?? 0
        if point.y < edge { return .squares }
        if let listed, listed.height > 0, point.y < listed.maxY + 1 { return .listed }
        if let folders, folders.height > 0, point.y < folders.maxY + 1 { return .folders }
        return .loose
    }

    /// Where a folder carried over the folders' lines would go, with the hand
    /// at `y`. Over another folder's row: before it, or after it below its
    /// middle — or, over the middle half of a folder at the top, into it at
    /// the end, when the carried one holds no folder of its own (one level
    /// down is as far as folders go). Over a tab in a folder: among that
    /// folder's own folders, first, or beside it when it can't go in. A
    /// folder holding folders stays at the top. Its own lines don't count.
    static func folderPlace(y: CGFloat, lines: [(line: FolderLine, frame: CGRect)],
                            carried: Folder, folders: [Folder]) -> Place? {
        let inner = Set(folders.filter { $0.parent == carried.id }.map(\.id))
        let own = inner.union([carried.id])
        let nests = inner.isEmpty
        let tops = Folders.tops(folders)
        func siblings(_ parent: UUID?) -> [UUID] {
            (parent == nil ? tops : folders.filter { $0.parent == parent }).map(\.id).filter { $0 != carried.id }
        }
        func place(_ parent: UUID?, _ at: Int) -> Place { Place(folder: carried.id, parent: parent, at: at) }
        /// After the top folder `id`, at the top.
        func after(_ id: UUID) -> Place { place(nil, (siblings(nil).firstIndex(of: id) ?? siblings(nil).count) + 1) }
        let others = lines.filter { entry in
            switch entry.line {
            case .folder(let folder, _): !own.contains(folder.id)
            case .tab(_, _, let folder): !own.contains(folder)
            }
        }
        let over = others.first { y >= $0.frame.minY && y < $0.frame.maxY }
            ?? others.min { abs($0.frame.midY - y) < abs($1.frame.midY - y) }
        guard let over else { return nil }
        let isTop: (UUID) -> Bool = { id in tops.contains { $0.id == id } }
        switch over.line {
        case .folder(let folder, _):
            let frame = over.frame
            if isTop(folder.id) {
                if nests, y >= frame.minY + frame.height / 4, y < frame.maxY - frame.height / 4 {
                    return place(folder.id, siblings(folder.id).count)
                }
                let at = siblings(nil).firstIndex(of: folder.id) ?? 0
                return place(nil, y < frame.midY ? at : at + 1)
            }
            guard let parent = folder.parent else { return nil }
            guard nests else { return after(parent) }
            let at = siblings(parent).firstIndex(of: folder.id) ?? 0
            return place(parent, y < frame.midY ? at : at + 1)
        case .tab(_, _, let id):
            guard let holder = folders.first(where: { $0.id == id }) else { return nil }
            if isTop(holder.id) { return nests ? place(holder.id, 0) : after(holder.id) }
            guard let parent = holder.parent else { return nil }
            guard nests else { return after(parent) }
            return place(parent, (siblings(parent).firstIndex(of: holder.id) ?? 0) + 1)
        }
    }

    /// Where among the folders' lines (top to bottom, each with its frame)
    /// a point `y` is: the line it is over, or the nearest. Over a folder's
    /// own line, into that folder at the end; over a tab in one, into that
    /// folder before the tab, or after it below its middle; over the
    /// carried tab itself, where it is. `peers` gives a folder's tabs in
    /// their order; the places are counted without the carried one.
    static func folderSlot(y: CGFloat, lines: [(line: FolderLine, frame: CGRect)], carried: Tab.ID,
                           peers: (UUID) -> [Tab.ID]) -> Target? {
        let over = lines.first { y >= $0.frame.minY && y < $0.frame.maxY }
            ?? lines.min { abs($0.frame.midY - y) < abs($1.frame.midY - y) }
        guard let over else { return nil }
        switch over.line {
        case .folder(let folder, _):
            return .folder(folder.id, at: nil)
        case .tab(let tab, _, let folder):
            let all = peers(folder)
            if tab.id == carried { return .folder(folder, at: all.firstIndex(of: carried)) }
            guard let at = all.filter({ $0 != carried }).firstIndex(of: tab.id) else { return .folder(folder, at: nil) }
            return .folder(folder, at: y < over.frame.midY ? at : at + 1)
        }
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
    var folders: CGRect?
    /// Each of the folders' lines, by its id, and the place opened among
    /// them under `ghost`.
    var lines: [UUID: CGRect] = [:]
    var rows: CGRect = .zero
    var loose: CGRect?

    static let ghost = UUID()
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
                Mark(icon: tab.icon, size: scale * 16 / 34)
                    .opacity(0.55)
            }
            .frame(width: width, height: height)
            .allowsHitTesting(false)
            .transition(.scale(scale: 0.8).combined(with: .opacity))
    }
}

/// The line opened among the folders for a folder carried there: its
/// chevron and name, faint, on the hover grey.
struct FolderGhost: View {
    @Environment(\.greys) private var greys
    let name: String
    let height: CGFloat
    let size: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .frame(width: 15)
            Text(name)
                .font(.system(size: size, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Palette.muted)
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
            Mark(icon: tab.icon, size: 15)
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
