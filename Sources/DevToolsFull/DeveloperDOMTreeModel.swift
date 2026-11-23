import AppKit
import Combine
import SwiftUI

/// The Elements tree as the rows it shows: the expanded nodes flattened in
/// document order, rebuilt only when the mirror, the root or the expanded
/// set changes, and at most once per frame however many DOM events arrive.
/// The list renders just the rows near the viewport (a LazyVStack over
/// `rows`), and each row's text is built once per node change.
@MainActor
final class DeveloperDOMTreeModel: ObservableObject {
    struct Row: Identifiable, Equatable {
        let node: DeveloperToolsSession.DOMNode
        let depth: Int
        let expanded: Bool
        /// The element's only child, a short text node, shown on this row
        /// (`<li>text</li>`) instead of as a row of its own.
        var inline: String? = nil
        var id: Int { node.id }
        /// Has children to open: not one already shown inline.
        var expandable: Bool { node.count > 0 && inline == nil }
    }

    /// Rows in tree order; replaced only when they differ.
    @Published private(set) var rows: [Row] = []
    /// Node id → its index in `rows`, for scrolling and arrow keys.
    private(set) var index: [Int: Int] = [:]
    /// Bumped with each change to `rows`, for views that act on a change.
    private(set) var revision = 0
    /// The deepest row's depth, and the longest row in characters at its
    /// depth, for the tree's width in its sideways scroll (a LazyVStack
    /// doesn't measure rows it hasn't built).
    private(set) var deepest = 0
    private(set) var widest: (depth: Int, columns: Int) = (0, 0)
    /// How many times the rows were flattened, for tests and diagnostics.
    private(set) var rebuilds = 0

    /// A safety cap far above any page DevTools is used on; Chrome itself
    /// shows the first children of a huge node and a "Show all" row.
    static let rowLimit = 250_000
    static let depthLimit = 400

    private weak var session: DeveloperToolsSession?
    private var subscription: AnyCancellable?
    private var lines: [Int: (key: LineKey, text: AttributedString)] = [:]

    init(session: DeveloperToolsSession?) {
        attach(session)
    }

    /// Follows `session` (a reopened DevTools brings a new one).
    func attach(_ session: DeveloperToolsSession?) {
        guard session !== self.session || subscription == nil else { return }
        self.session = session
        subscription = nil
        lines = [:]
        guard let session else {
            rows = []
            index = [:]
            return
        }
        // @Published sends before the value changes; reading the session on
        // the next main-queue turn sees the new values, and debounce folds a
        // burst of edits (a mutation-heavy page's drain, an expand and its
        // details) into one rebuild per frame.
        subscription = Publishers.Merge3(
            session.$nodes.map { _ in () },
            session.$root.map { _ in () },
            session.$expanded.map { _ in () }
        )
        .debounce(for: .milliseconds(16), scheduler: DispatchQueue.main)
        .sink { [weak self] in self?.rebuild() }
        rebuild()
    }

    /// Rebuilds now, without waiting for the next frame.
    func rebuild() {
        guard let session else { return }
        let next = Self.flatten(nodes: session.nodes, root: session.root, expanded: session.expanded,
                                comments: DeveloperElementsSettings.showHTMLComments)
        rebuilds += 1
        guard next != rows else { return }
        var positions: [Int: Int] = [:]
        positions.reserveCapacity(next.count)
        for (position, row) in next.enumerated() { positions[row.id] = position }
        index = positions
        var deepest = 0, widest: (depth: Int, columns: Int) = (0, 0), widestExtent = 0
        for row in next {
            deepest = max(deepest, row.depth)
            let columns = Self.columns(row)
            // Indent counts as columns too: 12 pt is about two.
            let extent = row.depth * 2 + columns
            if extent > widestExtent { widestExtent = extent; widest = (row.depth, columns) }
        }
        self.deepest = deepest
        self.widest = widest
        revision += 1
        rows = next
        // Lines for nodes no longer in the mirror go; the rest stay cached.
        if lines.count > next.count * 2 + 512 {
            lines = lines.filter { session.nodes[$0.key] != nil }
        }
    }

    /// Visible rows, depth first, without recursion (a deep page can't
    /// overflow the stack) and without blank text nodes (nor comments, with
    /// Settings › Preferences › Elements › "Show HTML comments" off).
    static func flatten(nodes: [Int: DeveloperToolsSession.DOMNode], root: Int?,
                        expanded: Set<Int>, comments: Bool = true) -> [Row] {
        guard let root, nodes[root] != nil else { return [] }
        var rows: [Row] = []
        var visited = Set<Int>()
        var stack: [(id: Int, depth: Int)] = [(root, 0)]
        while let item = stack.popLast(), rows.count < rowLimit {
            let id = item.id, depth = item.depth
            guard let node = nodes[id], visited.insert(id).inserted, comments || node.type != 8 else { continue }
            let inline = node.inlineText(in: nodes)
            let open = inline == nil && expanded.contains(id)
            if !isBlank(node) { rows.append(Row(node: node, depth: depth, expanded: open, inline: inline)) }
            if open, depth < depthLimit {
                for child in node.children.reversed() { stack.append((child, depth + 1)) }
            }
        }
        return rows
    }

    /// Whitespace-only text, which the tree leaves out as DevTools does.
    static func isBlank(_ node: DeveloperToolsSession.DOMNode) -> Bool {
        switch node.type {
        case 3, 4: node.text.allSatisfy(\.isWhitespace)
        case 1, 8, 9, 10, 11: false
        default: node.display.isEmpty
        }
    }

    // MARK: Keys

    /// A key that moves the selection, as Chrome DevTools' tree has them.
    enum Move: Equatable {
        case up, down, home, end, pageUp, pageDown

        init?(_ key: KeyEquivalent) {
            switch key {
            case .upArrow: self = .up
            case .downArrow: self = .down
            case .home: self = .home
            case .end: self = .end
            case .pageUp: self = .pageUp
            case .pageDown: self = .pageDown
            default: return nil
            }
        }
    }

    /// The row a move lands on, from the selected row's index (nil: none
    /// selected, or not shown), kept within the rows; `page` is how many
    /// rows Page Up and Page Down go.
    static func target(_ move: Move, from index: Int?, count: Int, page: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let index, index < count else { return move == .end ? count - 1 : 0 }
        let step = max(1, page)
        let next: Int
        switch move {
        case .up: next = index - 1
        case .down: next = index + 1
        case .home: next = 0
        case .end: next = count - 1
        case .pageUp: next = index - step
        case .pageDown: next = index + step
        }
        return min(max(next, 0), count - 1)
    }

    // MARK: Search

    /// A row's text with each place it matches `query` marked, as Chrome
    /// DevTools marks a search's matches (not the whole row); nil when the
    /// text holds no match, as for a selector or XPath query.
    static func marked(_ line: AttributedString, _ query: String) -> AttributedString? {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return nil }
        var output = line
        var found = false
        var start = output.startIndex
        while start < output.endIndex,
              let range = output[start...].range(of: needle, options: [.caseInsensitive]), !range.isEmpty {
            output[range].backgroundColor = searchMark
            output[range].foregroundColor = .black
            found = true
            start = range.upperBound
        }
        return found ? output : nil
    }

    /// Chrome's search highlight.
    static let searchMark = Color(red: 1, green: 1, blue: 0, opacity: 0.8)

    // MARK: Row text

    /// What a row's text depends on; a row is rebuilt only when this changes.
    struct LineKey: Equatable {
        let type: Int
        let name: String
        /// A pseudo-element's or shadow root's kind.
        let kind: String?
        let text: String
        let attributes: [String]
        let closed: Bool
        let inline: String?
    }

    /// The row's text, styled as the tree shows it, cached per node until the
    /// node itself changes. Hover and selection don't touch it.
    /// A closed element's "…</tag>" is left to the row, which draws the
    /// ellipsis as something to click (see `closedTag(for:)`).
    func line(for row: Row) -> AttributedString {
        let node = row.node
        let key = LineKey(type: node.type, name: node.name, kind: node.pseudoType ?? node.shadowRootType,
                          text: node.type == 1 ? "" : node.text,
                          attributes: node.type == 1 ? node.attributes : [],
                          closed: false, inline: row.inline)
        if let cached = lines[node.id], cached.key == key { return cached.text }
        let text = Self.styledLine(node, closed: key.closed, inline: row.inline)
        lines[node.id] = (key, text)
        return text
    }

    /// About how many characters a row's line runs to unwrapped: the tag
    /// and its attributes (the tree shows the first 12), an inline text,
    /// a closing tag. A text node's line is cut at 400, as long text is a
    /// line no one reads sideways.
    static func columns(_ row: Row) -> Int {
        let node = row.node
        guard node.type == 1 else { return min(400, node.type == 3 ? node.text.count + 2 : node.text.count + 9) }
        var count = node.name.count * 2 + 6
        var index = 0
        while index + 1 < node.attributes.count, index < 24 {
            count += node.attributes[index].count + node.attributes[index + 1].count + 4
            index += 2
        }
        if let inline = row.inline { count += inline.count }
        return min(count + 8, 2000)
    }

    /// The closing tag a collapsed element's row ends with, after its
    /// clickable "…"; nil for a row that has none.
    static func closedTag(for row: Row) -> String? {
        guard row.node.type == 1, row.node.pseudoType == nil, row.expandable, !row.expanded else { return nil }
        return "</\(row.node.name)>"
    }

    static func styledLine(_ node: DeveloperToolsSession.DOMNode, closed: Bool,
                           inline: String? = nil) -> AttributedString {
        func piece(_ string: String, _ color: Color) -> AttributedString {
            var part = AttributedString(string)
            part.foregroundColor = color
            return part
        }
        // ::before and #shadow-root (open), as Chrome DevTools names them.
        if node.pseudoType != nil { return piece(node.display, DeveloperToolsStyle.tint) }
        if node.shadowRootType != nil { return piece(node.display, .secondary) }
        switch node.type {
        case 1:
            var line = piece("<" + node.name, DeveloperToolsStyle.tint)
            for index in stride(from: 0, to: max(0, node.attributes.count - 1), by: 2).prefix(12) {
                line += piece(" " + node.attributes[index] + "=\"", .secondary)
                line += piece(node.attributes[index + 1], .purple)
                line += piece("\"", .secondary)
            }
            line += piece(">", DeveloperToolsStyle.tint)
            if let inline {
                line += AttributedString(inline)
                line += piece("</\(node.name)>", DeveloperToolsStyle.tint)
            } else if closed {
                line += piece("…", .secondary)
                line += piece("</\(node.name)>", DeveloperToolsStyle.tint)
            }
            return line
        case 3:
            return AttributedString("\"" + node.display + "\"")
        case 8:
            return piece("<!--" + node.text + "-->", .green)
        default:
            return piece(node.display, .secondary)
        }
    }
}

/// What a plain (not selected, not being edited) row does when used; the
/// tree view supplies these so the row itself holds only values.
struct DeveloperDOMRowActions {
    var toggle: (DeveloperToolsSession.DOMNode) -> Void
    var select: (Int) -> Void
    var hover: (Int?) -> Void
    var overlay: (Int, Bool) -> Void
    var drop: (Int, DeveloperToolsSession.DOMNode, Bool) -> Void
    var target: (Int, Bool) -> Void
    /// A container or scroll-snap badge clicked: that overlay on or off.
    var pageOverlay: (Int, String, Bool) -> Void = { _, _, _ in }
    /// An anchor-positioned element's anchor badge clicked: its anchor
    /// is selected.
    var anchor: (Int) -> Void = { _ in }
}

/// A row that isn't selected or being edited: its cached text in one Text,
/// so drawing it is a lookup. `==` compares only what it shows, and the list
/// wraps it in `.equatable()`, so a session update that leaves a row as it
/// was doesn't evaluate the row again.
struct DeveloperDOMPlainRow<Menu: View>: View, Equatable {
    let row: DeveloperDOMTreeModel.Row
    let line: AttributedString
    let found: Bool
    let hidden: Bool
    let layout: String?
    /// Chrome's container, scroll-snap, slot, top-layer, scroll and event
    /// badges; container and scroll-snap switch an overlay.
    let badges: [String]
    /// The container and scroll-snap overlays shown for this node.
    var pageOverlays: Set<String> = []
    let overlayShown: Bool
    let dropTarget: Bool
    let wraps: Bool
    /// The tree's visible width (DeveloperDOMTreeView.rowFrame).
    let width: CGFloat
    let actions: DeveloperDOMRowActions
    @ViewBuilder let menu: () -> Menu
    /// Grey under the pointer, as Chrome's rows. (Not private: the tree
    /// view builds the row with its memberwise initializer.)
    @State var hovering = false

    private static func closingText(_ closing: String) -> AttributedString {
        var ellipsis = AttributedString("…")
        ellipsis.foregroundColor = .secondary
        var tag = AttributedString(closing)
        tag.foregroundColor = DeveloperToolsStyle.tint
        return ellipsis + tag
    }

    /// A container or scroll-snap badge's click: its overlay switches,
    /// as on the selected row.
    func toggleOverlay(_ kind: String) {
        actions.pageOverlay(row.id, kind, !pageOverlays.contains(kind))
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.row == rhs.row && lhs.line == rhs.line && lhs.found == rhs.found && lhs.hidden == rhs.hidden
            && lhs.layout == rhs.layout && lhs.badges == rhs.badges && lhs.pageOverlays == rhs.pageOverlays
            && lhs.overlayShown == rhs.overlayShown
            && lhs.dropTarget == rhs.dropTarget && lhs.wraps == rhs.wraps && lhs.width == rhs.width
    }

    var body: some View {
        DeveloperDOMRowCounter.rendered += 1
        return HStack(alignment: .top, spacing: 1) {
            disclosure
            text
            layoutBadge
            ForEach(badges, id: \.self) { name in
                badge(name)
            }
            Spacer(minLength: 0)
            if row.expanded, row.node.children.count == 800, row.node.count > 800 {
                Text("First 800 children").foregroundStyle(.secondary).frame(height: height)
            }
        }
        .frame(minHeight: height, maxHeight: wraps ? nil : height, alignment: .top)
        .padding(.leading, DeveloperDOMTreeView.leading(row.depth))
        .padding(.trailing, DeveloperToolsStyle.gutter)
        .modifier(DeveloperDOMRowWidth(depth: row.depth, wraps: wraps, width: width))
        .background(fill)
        .overlay(alignment: .top) {
            if dropTarget { Rectangle().fill(DeveloperToolsStyle.tint).frame(height: 2) }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            // A double-click opens or closes the node, as in Chrome.
            if (NSApp.currentEvent?.clickCount ?? 1) >= 2, row.expandable { actions.toggle(row.node) }
            else { actions.select(row.id) }
        }
        .onHover { inside in
            hovering = inside
            if row.node.type == 1 { actions.hover(inside ? row.id : nil) }
        }
        .contextMenu { menu() }
        .draggable("search-node:\(row.id)") {
            Text(row.node.display).font(DeveloperToolsStyle.code).padding(4)
        }
        .dropDestination(for: String.self) { items, location in
            actions.target(row.id, false)
            guard let item = items.first, item.hasPrefix("search-node:"),
                  let id = Int(item.dropFirst("search-node:".count)) else { return false }
            actions.drop(id, row.node, location.y < height / 2)
            return true
        } isTargeted: { inside in
            actions.target(row.id, inside)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.node.display)
    }

    private var height: CGFloat { DeveloperDOMTreeView.rowHeight }

    private var fill: Color {
        if found { return Color.yellow.opacity(0.18) }
        return hovering ? Palette.ink.opacity(0.06) : Color.clear
    }

    @ViewBuilder
    private var disclosure: some View {
        if row.expandable {
            Image(systemName: row.expanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: height, height: height)
                .contentShape(Rectangle())
                .onTapGesture { actions.toggle(row.node) }
                .help(row.expanded ? "Collapse node" : "Expand node")
                .accessibilityLabel(row.expanded ? "Collapse node" : "Expand node")
                .accessibilityAddTraits(.isButton)
        } else {
            Color.clear.frame(width: height, height: height)
        }
    }

    /// The row's text, and the "…</tag>" of a closed node.
    @ViewBuilder
    private var text: some View {
        let closing: String? = DeveloperDOMTreeModel.closedTag(for: row)
        // Wrapped, the "…</tag>" ends the text itself, after its last
        // word, as Chrome sets it; beside a wrapped block it stood
        // apart at the first line's end.
        let shown: AttributedString = wraps && closing != nil ? line + Self.closingText(closing!) : line
        Text(shown)
            .font(DeveloperToolsStyle.code)
            .lineLimit(wraps ? nil : 1)
            .frame(minHeight: height, alignment: .topLeading)
            .opacity(hidden ? 0.5 : 1)
        if !wraps, let closing {
            // As in Chrome, a click on the ellipsis opens the node.
            Text("…").foregroundStyle(.secondary)
                .font(DeveloperToolsStyle.code)
                .frame(height: height)
                .contentShape(Rectangle())
                .onTapGesture { actions.toggle(row.node) }
                .help("Expand node")
            Text(closing).foregroundStyle(DeveloperToolsStyle.tint)
                .font(DeveloperToolsStyle.code)
                .lineLimit(1).fixedSize()
                .frame(height: height)
                .opacity(hidden ? 0.5 : 1)
        }
    }

    /// The grid or flex badge, which switches the node's layout overlay.
    @ViewBuilder
    private var layoutBadge: some View {
        if let layout, row.node.type == 1 {
            Button { actions.overlay(row.id, !overlayShown) } label: {
                Text(layout).developerBadgeCapsule(on: overlayShown)
            }
            .buttonStyle(.plain)
            .frame(height: height)
            .help(overlayShown ? "Hide the \(layout) overlay" : "Show the \(layout) overlay")
        }
    }

    @ViewBuilder
    private func badge(_ name: String) -> some View {
        if DeveloperDOMTreeView.overlayBadges.contains(name) {
            DeveloperDOMOverlayBadge(name: name, on: pageOverlays.contains(name)) { toggleOverlay(name) }
                .frame(height: height)
        } else if let anchor = DeveloperDOMTreeView.anchorName(name) {
            DeveloperDOMAnchorBadge(name: anchor) { actions.anchor(row.id) }
                .frame(height: height)
        } else {
            DeveloperDOMBadge(name: name).frame(height: height)
        }
    }
}

/// A badge that only says something about the node: Chrome's "scroll"
/// (it scrolls), WebKit's "event" (it has event listeners).
struct DeveloperDOMBadge: View {
    let name: String

    var body: some View {
        Text(name)
            .developerBadgeCapsule(on: false)
            .help(name == "scroll" ? "This element scrolls" : name == "event" ? "This element has event listeners" : name)
            .accessibilityLabel("\(name) badge")
    }
}

/// An anchor-positioned element's badge, an anchor sign and the anchor
/// name its position-anchor gives, as Chrome's: a click selects the anchor.
struct DeveloperDOMAnchorBadge: View {
    let name: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("\u{2693} " + name)
                .developerBadgeCapsule(ink: DeveloperToolsStyle.tint, fill: DeveloperToolsStyle.raised)
        }
        .buttonStyle(.plain)
        .help("Reveal the anchor \(name)")
        .accessibilityLabel("Reveal anchor \(name)")
    }
}

/// A container or scroll-snap badge: a click shows or hides the overlay the
/// page draws for it, as Chrome's do, on any row.
struct DeveloperDOMOverlayBadge: View {
    let name: String
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(name).developerBadgeCapsule(on: on)
        }
        .buttonStyle(.plain)
        .help(on ? "Hide the \(name) overlay" : "Show the \(name) overlay")
        .accessibilityLabel("\(name) overlay")
        .accessibilityValue(on ? "On" : "Off")
    }
}

extension View {
    /// The capsule every badge in the tree is drawn in.
    func developerBadgeCapsule(ink: Color, fill: Color) -> some View {
        font(.system(size: 9, weight: .medium))
            .padding(.horizontal, 4).frame(height: 14)
            .foregroundStyle(ink)
            .background(fill, in: Capsule())
            .overlay { Capsule().strokeBorder(Palette.ink.opacity(0.18)) }
    }

    /// A badge that switches an overlay: filled with the tint while it shows.
    func developerBadgeCapsule(on: Bool) -> some View {
        developerBadgeCapsule(ink: on ? Color.white : Palette.ink.opacity(0.75),
                              fill: on ? DeveloperToolsStyle.tint : DeveloperToolsStyle.raised)
    }
}

/// Counts tree row bodies evaluated (plain and interactive), so tests can
/// check that only rows near the viewport are rendered.
@MainActor
enum DeveloperDOMRowCounter {
    static var rendered = 0
}

/// A tree row's width in the tree's two-way scroll view. Unwrapped, a row
/// is as long as its line (none truncated; the tree scrolls sideways to
/// it) and at least the visible width, for its selection and hover. With
/// Wrap lines, a row is the visible width, but never leaves its text less
/// than DeveloperDOMTreeView.wrapMinimum however deep it is nested: deeper
/// rows run past the right edge, where the tree scrolls, rather than
/// breaking into a column a word or two wide.
struct DeveloperDOMRowWidth: ViewModifier {
    let depth: Int
    let wraps: Bool
    let width: CGFloat

    func body(content: Content) -> some View {
        if wraps {
            content.frame(width: DeveloperDOMTreeView.wrappedWidth(depth: depth, visible: width), alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            content.fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: width, maxWidth: .infinity, alignment: .leading)
        }
    }
}
