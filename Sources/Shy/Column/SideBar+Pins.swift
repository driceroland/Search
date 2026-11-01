import SwiftUI

// The pinned squares.
extension SideBar {
    private var pinnedTabs: [Tab] { browser.squarePins }

    var looseTabs: [Tab] {
        browser.displayedTabs.filter { $0.pin == nil }
    }

    /// The line between what is kept and what comes and goes: over the tabs
    /// Clear would close, or under rows and folders with nothing below them
    /// yet. Not with nothing on either side of it.
    func showsLine(kept: Int, loose: Int) -> Bool {
        kept + loose > 0
    }

    /// How many squares go in each row: at most four — fewer only when the
    /// column is too narrow for four of the classic width — and as even as
    /// they go, the fuller rows first. Five are three and two, seven four
    /// and three, nine three, three and three, ten four, three and three.
    static func pinRows(_ count: Int, most: Int) -> [Int] {
        guard count > 0 else { return [] }
        let most = max(1, most)
        let rows = (count + most - 1) / most
        let base = count / rows
        let extra = count % rows
        return (0..<rows).map { $0 < extra ? base + 1 : base }
    }

    /// Where each square goes, in the order of the row. Each row splits the
    /// column's width between its own squares — the row fills edge to edge,
    /// not each cell on its own — and every row is as tall as the narrowest
    /// cell allows, never taller than the classic square: past that a cell
    /// turns into a wide, short button rather than a bigger icon.
    func pinCells(_ count: Int) -> [CGRect] {
        let room = prefs.sideWidth - 20
        let gap = SideBar.pinGap
        let square = prefs.sideSquare
        let fits = Int((room + gap) / (square + gap))
        let rows = SideBar.pinRows(count, most: min(4, max(1, fits)))
        // However few, the squares share the column's width, as in Arc: two
        // are half of it each, one all of it.
        let widths = rows.map { max(20, (room - CGFloat($0 - 1) * gap) / CGFloat($0)) }
        let height = min(square, widths.min() ?? square)
        var cells: [CGRect] = []
        for (row, n) in rows.enumerated() {
            for col in 0..<n {
                cells.append(CGRect(x: CGFloat(col) * (widths[row] + gap),
                                    y: CGFloat(row) * (height + gap),
                                    width: widths[row], height: height))
            }
        }
        return cells
    }

    /// The grid itself: each row's cells sharing the column's width.
    var pinned: some View {
        let tabs = pinnedTabs
        // A tab carried over the grid: one cell more, and the one it
        // would take left open for it.
        let ghost = ghostSquare
        let all = pinCells(tabs.count + (ghost == nil ? 0 : 1))
        let cells = ghost.map { open in all.indices.filter { $0 != open }.map { all[$0] } } ?? all
        let placed = cells + (ghost.map { [all[$0]] } ?? [])
        // Measured in the grid's own space, not the square's: a square that
        // has just been moved to a new cell would otherwise report the drag
        // from where it now is, the target would jump back, and the square
        // would shuttle between two cells for as long as the finger stayed.
        return VStack(spacing: 0) { PinGrid(cells: placed) {
            ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                PinSquare(
                    browser: browser,
                    prefs: prefs,
                    tab: tab,
                    live: tab.id == browser.shownID,
                    pill: pill,
                    width: cells[index].width,
                    height: cells[index].height
                )
                // The hand's travel is the square's own, as a row's is
                // (Carried): a move redraws the one square being carried,
                // not the column (idea 31).
                .modifier(PinCarried(index: index, cells: cells,
                                     cross: { cross(tab, $0, from: .pins) },
                                     land: { land(tab, $0) }) { browser.move(tab, to: $0) })
            }
            if let ghost, let tab = crossingTab {
                PinGhost(tab: tab, width: all[ghost].width, height: all[ghost].height)
            }
        } }
        .coordinateSpace(name: "pins")
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named("column")) }) { [frames] in frames.grid = $0 }
    }
}
