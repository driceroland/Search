import AppKit
import SwiftUI

/// The pure parts of the Application panel's tables: sorting, column
/// widths and moving the selection, as Chrome DevTools' DataGrid does them.
enum DeveloperTableLayout {
    /// The column a table is sorted by, and which way.
    struct Order: Equatable {
        var column: Int
        var ascending: Bool
    }

    /// As in Chrome DevTools: clicking the sorted column's header turns the
    /// order round; clicking another sorts by it, ascending.
    static func toggled(_ order: Order?, column: Int) -> Order {
        guard let order, order.column == column else { return Order(column: column, ascending: true) }
        return Order(column: column, ascending: !order.ascending)
    }

    /// `items` in `order`, comparing the column's text as Finder does, so
    /// "9" comes before "10". Equal cells keep the rows' own order.
    static func sorted<Item>(_ items: [Item], by order: Order?, values: (Item) -> [String]) -> [Item] {
        guard let order else { return items }
        func cell(_ item: Item) -> String {
            let row = values(item)
            return row.indices.contains(order.column) ? row[order.column] : ""
        }
        return items.enumerated().sorted { a, b in
            let result = cell(a.element).localizedStandardCompare(cell(b.element))
            if result == .orderedSame { return a.offset < b.offset }
            return order.ascending ? result == .orderedAscending : result == .orderedDescending
        }.map(\.element)
    }

    /// Dragging a column's right border: that column alone grows or shrinks,
    /// never below `minimum`.
    static func resized(_ widths: [CGFloat], column: Int, by delta: CGFloat, minimum: CGFloat = 30) -> [CGFloat] {
        guard widths.indices.contains(column) else { return widths }
        var widths = widths
        widths[column] = max(minimum, widths[column] + delta)
        return widths
    }

    /// Up and Down: the row before or after the selected one, the first or
    /// last with none selected, stopping at the ends.
    static func moved(_ selection: Int?, in ids: [Int], by offset: Int) -> Int? {
        guard !ids.isEmpty else { return nil }
        guard let selection, let index = ids.firstIndex(of: selection) else {
            return offset >= 0 ? ids.first : ids.last
        }
        return ids[min(ids.count - 1, max(0, index + offset))]
    }
}

/// What a table remembers while its section is shown: the sort and the
/// widths the user dragged columns to.
struct DeveloperTableState: Equatable {
    var order: DeveloperTableLayout.Order?
    var widths: [CGFloat]?
}

/// Chrome DevTools' DataGrid as the Application panel's storage and cookie
/// tables use it: click a header to sort and drag its border to resize,
/// Up and Down to move the selection and Delete to remove the selected
/// row, double-click a cell to edit it in place (Tab to the next cell,
/// Return to save, Escape to cancel), and double-click the blank row at the
/// end to add an entry.
struct DeveloperApplicationTable<RowMenu: View>: View {
    typealias Row = DeveloperApplicationSnapshot.Row

    let columns: [String]
    let rows: [Row]
    let defaultWidths: [CGFloat]
    @Binding var state: DeveloperTableState
    @Binding var selection: Int?
    /// Columns that can be edited as text, in the order Tab visits them.
    var editable: [Int] = []
    /// Columns a double-click turns on or off (Chrome's HttpOnly and Secure).
    var toggles: Set<Int> = []
    /// Whether a row can be edited at all.
    var canEdit: (Row) -> Bool = { _ in false }
    /// Whether the blank row at the end adds an entry.
    var addsRows = false
    /// A single click on a row.
    var activate: (Row) -> Void = { _ in }
    /// The cell's whole text, when the table shows it cut short.
    var fullText: (Row, Int) async -> String? = { _, _ in nil }
    /// Saves the edited cells of a row, or of the new row when nil. Returns
    /// what went wrong, or nil.
    var commit: (Row?, [Int: String]) async -> String? = { _, _ in nil }
    var delete: (Row) -> Void = { _ in }
    @ViewBuilder var menu: (Row) -> RowMenu

    private struct CellEdit: Equatable {
        /// Nil for the new row at the end.
        var row: Int?
        var column: Int
    }

    @State private var edit: CellEdit?
    @State private var text = ""
    /// The edited row's cells so far, and what each held when editing began.
    @State private var drafts: [Int: String] = [:]
    @State private var originals: [Int: String] = [:]
    @State private var loadingCell = false
    @State private var saving = false
    @State private var problem: String?
    @State private var resizeStart: [CGFloat]?
    @FocusState private var fieldFocused: Bool
    @FocusState private var tableFocused: Bool

    private var widths: [CGFloat] {
        let saved = state.widths ?? []
        return defaultWidths.indices.map { saved.indices.contains($0) ? saved[$0] : defaultWidths[$0] }
    }

    private var shown: [Row] {
        DeveloperTableLayout.sorted(rows, by: state.order, values: \.values)
    }

    var body: some View {
        let widths: [CGFloat] = widths
        let shown: [Row] = shown
        VStack(spacing: 0) {
            if let problem { problemBar(problem) }
            grid(shown, widths: widths)
        }
        .focusable()
        .focused($tableFocused)
        .focusEffectDisabled()
        .onKeyPress(keys: [.upArrow, .downArrow]) { press in
            guard edit == nil else { return .ignored }
            selection = DeveloperTableLayout.moved(selection, in: shown.map(\.id), by: press.key == .upArrow ? -1 : 1)
            if let row = shown.first(where: { $0.id == selection }) { activate(row) }
            return .handled
        }
        .onKeyPress(keys: [.delete, .deleteForward]) { _ in
            guard edit == nil, let row = selectedRow else { return .ignored }
            delete(row)
            return .handled
        }
        .onKeyPress(.return) {
            guard edit == nil, let row = selectedRow, canEdit(row), let first = editable.first else { return .ignored }
            begin(row, column: first)
            return .handled
        }
        .onDeleteCommand {
            guard edit == nil, let row = selectedRow else { return }
            delete(row)
        }
        .onChange(of: fieldFocused) { _, focused in
            // Clicking elsewhere saves the row, as Chrome's grid does on blur.
            guard !focused, let watched = edit else { return }
            Task {
                try? await Task.sleep(for: .milliseconds(150))
                if !fieldFocused, edit == watched, !loadingCell { finishRow() }
            }
        }
    }

    /// What went wrong saving, above the table until dismissed.
    private func problemBar(_ problem: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.circle").accessibilityHidden(true)
            Text(problem).textSelection(.enabled).lineLimit(3)
            Spacer(minLength: 0)
            Button { self.problem = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).accessibilityLabel("Dismiss message")
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, DeveloperToolsStyle.gutter)
        .padding(.vertical, DeveloperToolsStyle.controlSpacing)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func grid(_ shown: [Row], widths: [CGFloat]) -> some View {
        ScrollView(.horizontal) {
            ScrollViewReader { (scroller: ScrollViewProxy) in
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                        Section {
                            ForEach(Array(shown.enumerated()), id: \.element.id) { index, row in
                                rowView(row, index: index, widths: widths)
                                    .id(row.id)
                            }
                            if addsRows { newRow(widths: widths) }
                        } header: {
                            header(widths)
                        }
                    }
                }
                .onChange(of: selection) { _, id in
                    if let id { withAnimation(nil) { scroller.scrollTo(id) } }
                }
            }
            .frame(width: widths.reduce(0, +))
        }
        .overlay(alignment: .bottomTrailing) {
            if saving { ProgressView().controlSize(.mini).padding(6).accessibilityLabel("Saving") }
        }
    }

    private var selectedRow: Row? {
        guard let selection else { return nil }
        return rows.first { $0.id == selection }
    }

    // MARK: Header

    private func header(_ widths: [CGFloat]) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(widths.enumerated()), id: \.offset) { index, width in
                let name = columns.indices.contains(index) ? columns[index] : ""
                let sorted = state.order?.column == index ? state.order : nil
                HStack(spacing: 3) {
                    Text(name)
                        .font(.system(size: 10.5, weight: .semibold))
                        .lineLimit(1)
                    if let sorted {
                        Image(systemName: sorted.ascending ? "chevron.up" : "chevron.down")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, DeveloperToolsStyle.gutter)
                .frame(width: width, height: DeveloperToolsStyle.rowHeight, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { state.order = DeveloperTableLayout.toggled(state.order, column: index) }
                .overlay(alignment: .trailing) { border(index, widths: widths) }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(name)
                .accessibilityValue(sorted.map { $0.ascending ? "Sorted ascending" : "Sorted descending" } ?? "")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { state.order = DeveloperTableLayout.toggled(state.order, column: index) }
            }
        }
        .background(DeveloperToolsStyle.chrome)
        .overlay(alignment: .bottom) { Divider() }
    }

    /// A column's right border, which drags to resize it.
    private func border(_ index: Int, widths: [CGFloat]) -> some View {
        Rectangle().fill(DeveloperToolsStyle.rule).frame(width: 1)
            .frame(width: 7)
            .contentShape(Rectangle())
            .onHover { over in
                if over { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    if resizeStart == nil { resizeStart = widths }
                    state.widths = DeveloperTableLayout.resized(resizeStart ?? widths, column: index,
                                                                by: value.translation.width)
                }
                .onEnded { _ in resizeStart = nil })
            .offset(x: 3)
            .accessibilityHidden(true)
    }

    // MARK: Rows

    private func rowView(_ row: Row, index: Int, widths: [CGFloat]) -> some View {
        let selected = selection == row.id
        return HStack(spacing: 0) {
            ForEach(Array(widths.enumerated()), id: \.offset) { column, width in
                cell(row: row, column: column, width: width)
            }
        }
        .background(selected ? DeveloperToolsStyle.selected
                    : index.isMultiple(of: 2) ? DeveloperToolsStyle.raised.opacity(0.25) : .clear)
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded {
            if let current = edit, current.row != row.id { finishRow() }
            if edit == nil { tableFocused = true }
            activate(row)
        })
        .contextMenu { menu(row) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? AccessibilityTraits([.isSelected, .isButton]) : .isButton)
        .accessibilityAction { activate(row) }
    }

    @ViewBuilder
    private func cell(row: Row?, column: Int, width: CGFloat) -> some View {
        let editing = edit == CellEdit(row: row?.id, column: column)
        let shownText: String = {
            if edit?.row == row?.id, edit != nil, let draft = drafts[column] { return draft }
            guard let row else { return "" }
            return row.values.indices.contains(column) ? row.values[column] : "—"
        }()
        Group {
            if editing {
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .font(DeveloperToolsStyle.code)
                    .focused($fieldFocused)
                    .disabled(loadingCell)
                    .onSubmit { finishRow() }
                    .onKeyPress(.tab) {
                        advance()
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        cancel()
                        return .handled
                    }
                    .padding(.horizontal, DeveloperToolsStyle.gutter - 2)
                    .frame(width: width, height: DeveloperToolsStyle.rowHeight, alignment: .leading)
                    .background(DeveloperToolsStyle.surface)
                    .overlay { Rectangle().strokeBorder(DeveloperToolsStyle.tint, lineWidth: 1) }
                    .accessibilityLabel(columns.indices.contains(column) ? columns[column] : "Value")
            } else {
                Text(shownText)
                    .font(DeveloperToolsStyle.code)
                    .lineLimit(1)
                    .padding(.horizontal, DeveloperToolsStyle.gutter)
                    .frame(width: width, height: DeveloperToolsStyle.rowHeight, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { doubleClicked(row, column: column) }
            }
        }
        .overlay(alignment: .trailing) { Rectangle().fill(DeveloperToolsStyle.rule).frame(width: 1) }
    }

    /// The blank row at the end, which a double-click turns into a new entry.
    private func newRow(widths: [CGFloat]) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(widths.enumerated()), id: \.offset) { column, width in
                cell(row: nil, column: column, width: width)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("New entry")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { if let first = editable.first { begin(nil, column: first) } }
    }

    private func doubleClicked(_ row: Row?, column: Int) {
        guard let row else {
            if let first = editable.first { begin(nil, column: editable.contains(column) ? column : first) }
            return
        }
        guard canEdit(row) else { return }
        if toggles.contains(column) {
            let on = (row.values.indices.contains(column) ? row.values[column] : "").isEmpty
            save(row, [column: on ? "✓" : ""])
        } else if editable.contains(column) {
            begin(row, column: column)
        }
    }

    // MARK: Editing

    private func rowFor(_ id: Int?) -> Row? {
        guard let id else { return nil }
        return rows.first { $0.id == id }
    }

    private func begin(_ row: Row?, column: Int) {
        if let current = edit, current.row != row?.id { finishRow() }
        let target = CellEdit(row: row?.id, column: column)
        edit = target
        problem = nil
        if let row { selection = row.id }
        if let draft = drafts[column] {
            text = draft
            fieldFocused = true
            return
        }
        let shown = row.map { $0.values.indices.contains(column) ? $0.values[column] : "" } ?? ""
        text = shown
        originals[column] = shown
        guard let row else { fieldFocused = true; return }
        loadingCell = true
        Task {
            let full = await fullText(row, column)
            guard edit == target else { return }
            if let full {
                text = full
                originals[column] = full
            }
            loadingCell = false
            fieldFocused = true
        }
    }

    /// Tab: keep this cell and go on to the next editable one; past the last, save the row.
    private func advance() {
        guard let current = edit else { return }
        drafts[current.column] = text
        guard let index = editable.firstIndex(of: current.column), index + 1 < editable.count else {
            finishRow()
            return
        }
        begin(rowFor(current.row), column: editable[index + 1])
    }

    /// Return, or leaving the row: save what changed.
    private func finishRow() {
        guard let current = edit else { return }
        if !loadingCell { drafts[current.column] = text }
        let changes = drafts.filter { originals[$0.key] != $0.value }
        let row = rowFor(current.row)
        edit = nil
        drafts = [:]
        originals = [:]
        loadingCell = false
        tableFocused = true
        if current.row != nil, row == nil { return }
        guard !changes.isEmpty, row != nil || changes.values.contains(where: { !$0.isEmpty }) else { return }
        save(row, changes)
    }

    private func cancel() {
        edit = nil
        drafts = [:]
        originals = [:]
        loadingCell = false
        tableFocused = true
    }

    private func save(_ row: Row?, _ changes: [Int: String]) {
        saving = true
        Task {
            let issue = await commit(row, changes)
            saving = false
            problem = issue
        }
    }
}
