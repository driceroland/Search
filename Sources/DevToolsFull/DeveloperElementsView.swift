import AppKit
import SwiftUI
import WebKit

struct DeveloperElementsView: View {
    @ObservedObject var session: DeveloperToolsSession
    @State private var sidebar = Sidebar.styles

    enum Sidebar: String, CaseIterable {
        case styles = "Styles", computed = "Computed", layout = "Layout", listeners = "Event Listeners"
        case breakpoints = "DOM Breakpoints", properties = "Properties", accessibility = "Accessibility"
    }

    var body: some View {
        GeometryReader { space in
            if space.size.width >= 555 {
                HSplitView {
                    DeveloperDOMTreeView(session: session, elements: session.elements)
                        .frame(minWidth: 210, maxWidth: .infinity)
                    inspection.frame(minWidth: 210, idealWidth: 290, maxWidth: 460)
                }
            } else {
                VSplitView {
                    DeveloperDOMTreeView(session: session, elements: session.elements)
                        .frame(minHeight: 85, maxHeight: .infinity)
                    inspection.frame(minHeight: 102, idealHeight: 230)
                }
            }
        }
        // Where the panel is, for its ⌘ keys (DeveloperElementsKeys).
        .background(DeveloperElementsKeyRegion())
        .onAppear { session.loadCatalog() }
        // Computed → Styles and back, from links in the other pane.
        .onReceive(session.elements.$requestedSidebar.compactMap { $0 }) { name in
            if let section = Sidebar(rawValue: name) {
                sidebar = section
                session.listenersShown = false
            }
            session.elements.requestedSidebar = nil
        }
    }

    private var inspection: some View {
        VStack(spacing: 0) {
            DeveloperTabBar(Sidebar.allCases, selection: Binding(get: { sidebar }, set: { section in
                sidebar = section
                session.listenersShown = section == .listeners
                if section == .listeners { session.loadListeners() }
                if section == .layout { session.loadLayout() }
            }), title: \.rawValue)
            Divider()
            if sidebar == .breakpoints {
                ScrollView { DeveloperDOMBreakpointsPane(session: session, elements: session.elements) }
                    .font(DeveloperToolsStyle.code)
            } else if sidebar == .layout {
                // The page's grid and flex containers, whatever is selected.
                ScrollView { DeveloperLayoutPane(session: session, elements: session.elements) }
                    .font(DeveloperToolsStyle.code)
            } else if let selected = session.selectedNode, session.nodes[selected]?.type == 1 {
                switch sidebar {
                case .styles:
                    DeveloperStylesPane(session: session, elements: session.elements, node: selected)
                case .computed:
                    DeveloperComputedPane(session: session, elements: session.elements, node: selected)
                case .breakpoints:
                    ScrollView { DeveloperDOMBreakpointsPane(session: session, elements: session.elements) }
                        .font(DeveloperToolsStyle.code)
                case .properties:
                    DeveloperPropertiesPane(session: session, node: selected).font(DeveloperToolsStyle.code)
                case .accessibility:
                    DeveloperAccessibilityPane(session: session, elements: session.elements, node: selected).font(DeveloperToolsStyle.code)
                default:
                    ScrollView { DeveloperEventListenersView(session: session) }.font(DeveloperToolsStyle.code)
                }
            } else {
                Text("Select an element")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

/// Elements' DOM tree, edited as in DevTools: double-click a tag name, an
/// attribute or text to edit it (Tab and ⇧Tab move between them); the
/// context menu, drag to move, ⌘Z, ⌘C, ⌘X, ⌘V, H, F2, Delete; ⌘F finds by
/// string, selector or XPath as you type.
struct DeveloperDOMTreeView: View {
    @ObservedObject var session: DeveloperToolsSession
    @ObservedObject var elements: DeveloperElementsState
    @State private var editing: Edit?
    @State private var draft = ""
    /// Tab is moving the edit to the next field: the one going away losing
    /// the keyboard doesn't end the editing.
    @State private var switching = false
    @State private var searching = false
    @State private var query = ""
    @State private var matches: [Int] = []
    @State private var match = 0
    @State private var searchedFor = ""
    @State private var searchTask: Task<Void, Never>?
    @State private var dropTarget: Int?
    /// The tree's height, for Page Up and Page Down.
    @State private var viewport: CGFloat = 0
    @State private var viewportWidth: CGFloat = 0
    @State private var badgeSettings = false
    /// Chrome's "Switch to accessibility tree view": the page's
    /// accessibility tree shown in the DOM tree's place.
    @State private var accessibilityTree = false
    /// Long nodes wrap onto more lines, or stay on one, as DevTools'
    /// "Word wrap" setting. Off by default, as in Chrome.
    @AppStorage("developerTools.elements.wrapLines", store: DevDefaults.store) private var wrapLines = false
    /// Chrome's Badge settings: which badges the tree shows.
    @AppStorage("developerTools.elements.badges.grid", store: DevDefaults.store) private var gridBadges = true
    @AppStorage("developerTools.elements.badges.flex", store: DevDefaults.store) private var flexBadges = true
    @AppStorage("developerTools.elements.badges.scroll", store: DevDefaults.store) private var scrollBadges = true
    @AppStorage("developerTools.elements.badges.event", store: DevDefaults.store) private var eventBadges = true
    @AppStorage("developerTools.elements.badges.subgrid", store: DevDefaults.store) private var subgridBadges = true
    @AppStorage("developerTools.elements.badges.container", store: DevDefaults.store) private var containerBadges = true
    @AppStorage("developerTools.elements.badges.scrollSnap", store: DevDefaults.store) private var scrollSnapBadges = true
    @AppStorage("developerTools.elements.badges.topLayer", store: DevDefaults.store) private var topLayerBadges = true
    @AppStorage("developerTools.elements.badges.slot", store: DevDefaults.store) private var slotBadges = true
    @AppStorage("developerTools.elements.badges.anchor", store: DevDefaults.store) private var anchorBadges = true
    @FocusState private var focus: Focus?
    /// The visible rows, flattened once per tree change (not per render).
    @StateObject private var tree: DeveloperDOMTreeModel
    /// A row to scroll to once it is in the flattened list (a pick or a
    /// search match inside a subtree that is still expanding).
    @State private var pendingScroll: Int?
    /// The row the last click selected, which needs no scroll.
    @State private var clicked: Int?

    init(session: DeveloperToolsSession, elements: DeveloperElementsState) {
        _session = ObservedObject(wrappedValue: session)
        _elements = ObservedObject(wrappedValue: elements)
        _tree = StateObject(wrappedValue: DeveloperDOMTreeModel(session: session))
    }

    /// Chrome's tree density: 11pt monospaced on 16pt rows.
    static let rowHeight: CGFloat = 16
    static let indent: CGFloat = 12
    /// The narrowest a wrapped row's text gets (DeveloperDOMRowWidth).
    static let wrapMinimum: CGFloat = 220

    /// A row's indent at this depth, past the gutter.
    static func leading(_ depth: Int) -> CGFloat {
        CGFloat(min(60, depth)) * indent + DeveloperToolsStyle.gutter
    }

    /// One character of the tree's monospaced code font.
    static let characterWidth: CGFloat = {
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        return ("M" as NSString).size(withAttributes: [.font: font]).width
    }()

    /// The tree's scrolled width: the panel's, or wider for rows nested past
    /// it (wrapped) or longer than it (unwrapped), with room for a badge
    /// and " == $0" after the longest.
    private var contentWidth: CGFloat {
        if wrapLines { return Self.wrappedWidth(depth: tree.deepest, visible: viewportWidth) }
        let widest = tree.widest
        let line = Self.leading(widest.depth) + Self.rowHeight + CGFloat(widest.columns) * Self.characterWidth + 90
        return max(viewportWidth, line)
    }

    static func wrappedWidth(depth: Int, visible: CGFloat) -> CGFloat {
        max(visible, leading(depth) + rowHeight + wrapMinimum + DeveloperToolsStyle.gutter)
    }

    private enum Focus: Hashable { case tree, search, editor }

    enum Edit: Equatable {
        case tag(Int), attribute(Int, String), newAttribute(Int), text(Int), html(Int)
        var node: Int {
            switch self {
            case .tag(let id), .attribute(let id, _), .newAttribute(let id), .text(let id), .html(let id): id
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if accessibilityTree {
                DeveloperAccessibilityTreeView(session: session)
            } else {
                if searching { searchBar; Divider() }
                ScrollViewReader { reader in
                    // Both ways: lines too long for the panel (or, wrapped,
                    // nested too deep for it) scroll sideways rather than
                    // truncating or squeezing (DeveloperDOMRowWidth).
                    ScrollView([.vertical, .horizontal]) {
                        treeRows
                    }
                    .background {
                        GeometryReader { proxy in
                            Color.clear
                                .onAppear { viewport = proxy.size.height; viewportWidth = proxy.size.width }
                                .onChange(of: proxy.size) { _, size in viewport = size.height; viewportWidth = size.width }
                        }
                    }
                    .focusable()
                    .focusEffectDisabled()
                    .focused($focus, equals: .tree)
                    .onKeyPress(phases: [.down, .repeat], action: key)
                    .onChange(of: selectedInTree) { _, id in
                        // A clicked row is already on screen: scrolling it would
                        // move the row out from under a double-click.
                        if let id, id == clicked { clicked = nil; return }
                        pendingScroll = id
                        scrollToPending(reader)
                    }
                    .onChange(of: tree.revision) { _, _ in scrollToPending(reader) }
                }
            }
            if session.selectedNode != nil { breadcrumbs }
        }
        .onAppear {
            tree.attach(session)
            DeveloperElementsKeys.actions = keyActions
        }
        .onDisappear {
            DeveloperElementsKeys.actions = nil
            DeveloperElementsKeys.treeFocused = false
        }
        .onChange(of: ObjectIdentifier(session)) { _, _ in
            tree.attach(session)
            DeveloperElementsKeys.actions = keyActions
        }
        .onChange(of: focus) { _, now in
            DeveloperElementsKeys.treeFocused = now == .tree
            if now == .editor { switching = false }
        }
    }

    /// Lazy: only rows in or near the viewport are built. Rows that aren't
    /// selected or being edited are plain values compared before their
    /// body runs again.
    private var treeRows: some View {
        let found: Set<Int> = Set(matches)
        return LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(tree.rows) { row in
                treeRow(row, found: found.contains(row.id))
            }
        }
        .frame(width: contentWidth, alignment: .leading)
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private func treeRow(_ row: Row, found: Bool) -> some View {
        let live: Bool = session.selectedNode == row.id || editing?.node == row.id
            || (row.inline != nil && editing?.node == row.node.children.first)
        if live {
            interactiveRow(row).id(row.id)
        } else {
            plainRow(row, found: found).equatable().id(row.id)
        }
    }

    /// Scrolls to the pending row once it is in the list; ScrollViewReader
    /// finds a lazy row by id without building the rows above it.
    private func scrollToPending(_ reader: ScrollViewProxy) {
        guard let id = pendingScroll, tree.index[id] != nil else { return }
        pendingScroll = nil
        reader.scrollTo(id)  // only as far as it takes to show it
    }

    /// The panel's ⌘ keys (DeveloperElementsKeys): ⌘F and ⌘G anywhere in
    /// the panel, ⌘Z and ⇧⌘Z there unless a field is being typed in, and
    /// the clipboard keys while the tree has the keyboard.
    private var keyActions: DeveloperElementsKeys.Actions {
        DeveloperElementsKeys.Actions(
            find: { openSearch() },
            findNext: { backwards in
                guard searching else { return false }
                step(backwards ? -1 : 1)
                return true
            },
            undo: { session.undo() },
            redo: { session.redo() },
            clipboard: { operation in
                guard editing == nil, let id = session.selectedNode, let node = session.nodes[id],
                      node.pseudoType == nil, [1, 3, 8].contains(node.type) else { return false }
                switch operation {
                case .copy: session.copyNode(id)
                case .cut: session.cut(id)
                case .paste:
                    guard node.type == 1, let clip = elements.clipboard, clip.node != id else { return true }
                    session.paste(into: id)
                }
                return true
            }
        )
    }

    private var toolbar: some View {
        HStack(spacing: DeveloperToolsStyle.controlSpacing) {
            DeveloperPanelIcon(symbol: "arrow.clockwise", title: "Refresh DOM tree", action: session.refresh)
            DeveloperPanelIcon(symbol: "magnifyingglass", title: "Search (⌘F)", active: searching) {
                if searching { closeSearch() } else { openSearch() }
            }
            DeveloperPanelIcon(symbol: "arrow.uturn.backward", title: "Undo (⌘Z)", action: session.undo)
            DeveloperPanelIcon(symbol: "arrow.uturn.forward", title: "Redo (⇧⌘Z)", action: session.redo)
            DeveloperPanelIcon(symbol: "arrow.turn.down.left",
                               title: wrapLines ? "Don’t wrap lines" : "Wrap lines", active: wrapLines) {
                wrapLines.toggle()
            }
            .accessibilityIdentifier("developer-elements-wrap")
            .accessibilityValue(wrapLines ? "On" : "Off")
            Spacer(minLength: 0)
            // Chrome's toggle above the tree: the page's accessibility
            // tree in the DOM tree's place, and back.
            DeveloperPanelIcon(symbol: "accessibility",
                               title: accessibilityTree ? "Switch to DOM tree view" : "Switch to accessibility tree view",
                               active: accessibilityTree) {
                if searching { closeSearch() }
                accessibilityTree.toggle()
            }
            .accessibilityIdentifier("developer-elements-accessibility-tree")
        }
        .padding(.horizontal, DeveloperToolsStyle.gutter).frame(height: DeveloperToolsStyle.toolbarHeight)
        .background(DeveloperToolsStyle.chrome)
        .popover(isPresented: $badgeSettings, arrowEdge: .bottom) { badgeSettingsPane }
    }

    /// Chrome's Badge settings: the badges the tree shows beside nodes.
    private var badgeSettingsPane: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Badge settings").font(.system(size: 11, weight: .semibold))
            Toggle("grid", isOn: $gridBadges)
            Toggle("subgrid", isOn: $subgridBadges)
            Toggle("flex", isOn: $flexBadges)
            Toggle("scroll-snap", isOn: $scrollSnapBadges)
            Toggle("container", isOn: $containerBadges)
            Toggle("slot", isOn: $slotBadges)
            Toggle("top-layer", isOn: $topLayerBadges)
            Toggle("anchor", isOn: $anchorBadges)
            Toggle("scroll", isOn: $scrollBadges)
            Toggle("event", isOn: $eventBadges)
        }
        .toggleStyle(.developerCheckbox)
        .font(DeveloperToolsStyle.code)
        .padding(10)
        .accessibilityIdentifier("developer-elements-badge-settings")
    }

    private var searchBar: some View {
        HStack(spacing: DeveloperToolsStyle.controlSpacing) {
            TextField("Find by string, selector, or XPath", text: $query)
                .developerToolsField()
                .focused($focus, equals: .search)
                // Return: the next match; ⇧Return: the one before.
                .onSubmit { step(NSEvent.modifierFlags.contains(.shift) ? -1 : 1) }
                .onExitCommand { closeSearch() }
                .onChange(of: query) { _, typed in searchSoon(typed) }
                .accessibilityIdentifier("developer-dom-search")
            Text(searchedFor.isEmpty ? "" : matches.isEmpty ? "0 results" : "\(match + 1) of \(matches.count)")
                .foregroundStyle(.secondary).monospacedDigit().fixedSize()
            DeveloperPanelIcon(symbol: "chevron.up", title: "Search previous (⇧⌘G)", action: { step(-1) })
            DeveloperPanelIcon(symbol: "chevron.down", title: "Search next (⌘G)", action: { step(1) })
            Button("Cancel") { closeSearch() }.buttonStyle(.borderless)
        }
        .padding(.horizontal, DeveloperToolsStyle.gutter).frame(height: DeveloperToolsStyle.toolbarHeight)
        .background(DeveloperToolsStyle.chrome)
    }

    private func openSearch() {
        // The search finds DOM nodes: the DOM tree comes back to show them.
        accessibilityTree = false
        searching = true
        DispatchQueue.main.async { focus = .search }
    }

    private func closeSearch() {
        searchTask?.cancel()
        searching = false
        matches = []
        searchedFor = ""
        focus = .tree
    }

    /// As in Chrome DevTools, the tree searches as you type, a moment
    /// after the last key.
    private func searchSoon(_ typed: String) {
        searchTask?.cancel()
        searchTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            await search(typed)
        }
    }

    /// The matches for what was typed, the first of them selected.
    private func search(_ typed: String) async {
        guard !typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            matches = []
            searchedFor = ""
            return
        }
        let found = await session.searchDOM(typed)
        guard typed == query, searching else { return }
        searchedFor = typed
        matches = found
        match = 0
        if let first = found.first { session.selectNode(first) }
    }

    /// Return, ⌘G and the arrows walk the matches; a query not searched
    /// yet is searched now.
    private func step(_ direction: Int) {
        if query != searchedFor {
            searchTask?.cancel()
            let typed = query
            searchTask = Task { @MainActor in await search(typed) }
            return
        }
        guard !matches.isEmpty else { return }
        match = (match + direction + matches.count) % matches.count
        session.selectNode(matches[match])
    }

    private func clickSelect(_ id: Int) {
        clicked = id
        session.selectNode(id)
        focus = .tree
    }

    private var selectedInTree: Int? {
        session.selectedNode.flatMap { session.nodes[$0]?.id }
    }

    private typealias Row = DeveloperDOMTreeModel.Row

    // MARK: Rows

    private func plainRow(_ row: Row, found: Bool) -> DeveloperDOMPlainRow<some View> {
        // A match shows the words it matched, as Chrome marks them; a
        // selector or XPath match, the row.
        let line = tree.line(for: row)
        let marked = found ? DeveloperDOMTreeModel.marked(line, searchedFor) : nil
        return DeveloperDOMPlainRow(
            row: row, line: marked ?? line, found: found && marked == nil,
            hidden: elements.hidden.contains(row.id), layout: layoutBadge(row),
            badges: badges(for: row.node),
            pageOverlays: Self.pageOverlays(for: row.id, in: elements.pageOverlays),
            overlayShown: elements.containers.contains { $0.id == row.id && $0.showing },
            dropTarget: dropTarget == row.id, wraps: wrapLines, width: viewportWidth,
            actions: DeveloperDOMRowActions(
                toggle: { toggle($0) },
                select: { clickSelect($0) },
                hover: { session.highlightNode($0) },
                overlay: { session.setOverlay($0, on: $1) },
                drop: { drop($0, on: $1, upper: $2) },
                target: { id, inside in
                    if inside { dropTarget = id } else if dropTarget == id { dropTarget = nil }
                },
                pageOverlay: { session.setPageOverlay($0, kind: $1, on: $2) },
                anchor: { session.revealAnchor(of: $0) }
            ),
            menu: { menu(for: row.node) }
        )
    }

    /// The selected or edited row: attributes are separate pieces there, so
    /// double-clicking one edits it, and wrapping flows them.
    private func interactiveRow(_ row: Row) -> some View {
        DeveloperDOMRowCounter.rendered += 1
        return nodeRow(row)
    }

    /// Expands or collapses; with ⌥, the whole subtree as DevTools does.
    private func toggle(_ node: DeveloperToolsSession.DOMNode) {
        if NSEvent.modifierFlags.contains(.option) {
            if session.expanded.contains(node.id) {
                session.collapseChildren(node.id)
                session.expand(node)
            } else {
                session.expandRecursively(node.id)
            }
        } else {
            session.expand(node)
        }
    }

    private func nodeRow(_ row: Row) -> some View {
        let selected: Bool = session.selectedNode == row.id
        let found: Bool = !matches.isEmpty && matches.contains(row.id)
        let fill: Color = selected ? DeveloperToolsStyle.selected : found ? Color.yellow.opacity(0.18) : Color.clear
        return VStack(alignment: .leading, spacing: 0) {
            nodeLine(row, selected: selected)
                .frame(minHeight: Self.rowHeight, maxHeight: wrapLines ? nil : Self.rowHeight, alignment: .top)
            if editing == .html(row.id) { htmlEditor(row.node) }
        }
        .padding(.leading, Self.leading(row.depth))
        .padding(.trailing, DeveloperToolsStyle.gutter)
        .modifier(DeveloperDOMRowWidth(depth: row.depth, wraps: wrapLines, width: viewportWidth))
        .background(fill)
        .overlay(alignment: .top) {
            if dropTarget == row.id { Rectangle().fill(DeveloperToolsStyle.tint).frame(height: 2) }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            // A double-click beside the text opens or closes the node.
            if (NSApp.currentEvent?.clickCount ?? 1) >= 2, row.expandable { toggle(row.node) }
            else { clickSelect(row.id) }
        }
        .onHover { inside in
            if row.node.type == 1 { session.highlightNode(inside ? row.id : nil) }
        }
        .contextMenu { menu(for: row.node) }
        .draggable("search-node:\(row.id)") {
            Text(row.node.display).font(DeveloperToolsStyle.code).padding(4)
        }
        .dropDestination(for: String.self) { items, location in
            dropTarget = nil
            guard let item = items.first, item.hasPrefix("search-node:"),
                  let id = Int(item.dropFirst("search-node:".count)) else { return false }
            drop(id, on: row.node, upper: location.y < Self.rowHeight / 2)
            return true
        } isTargeted: { inside in
            if inside { dropTarget = row.id } else if dropTarget == row.id { dropTarget = nil }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.node.display)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// A row's first line: its triangle, its text and its badges.
    private func nodeLine(_ row: Row, selected: Bool) -> some View {
        HStack(alignment: .top, spacing: 1) {
            nodeDisclosure(row)
            if editing == .html(row.id) {
                Text(row.node.display).font(DeveloperToolsStyle.code).foregroundStyle(.secondary).lineLimit(1)
                    .frame(minHeight: Self.rowHeight)
            } else {
                content(row.node, inline: row.inline)
                    .font(DeveloperToolsStyle.code)
                    .lineLimit(wrapLines ? nil : 1)
                    .frame(minHeight: Self.rowHeight)
                    .opacity(elements.hidden.contains(row.id) ? 0.5 : 1)
            }
            if let kind = layoutBadge(row) {
                badge(kind, for: row.id).frame(height: Self.rowHeight)
            }
            ForEach(badges(for: row.node), id: \.self) { name in
                nodeBadge(name, row: row)
            }
            if selected && editing == nil {
                Text(" == $0").font(DeveloperToolsStyle.code).foregroundStyle(.secondary).fixedSize()
                    .frame(height: Self.rowHeight)
            }
            Spacer(minLength: 0)
            if session.expanded.contains(row.id), row.node.children.count == 800, row.node.count > 800 {
                Text("First 800 children").foregroundStyle(.secondary).frame(height: Self.rowHeight)
            }
        }
    }

    @ViewBuilder
    private func nodeDisclosure(_ row: Row) -> some View {
        if row.expandable {
            let open: Bool = session.expanded.contains(row.id)
            DeveloperPanelIcon(symbol: open ? "chevron.down" : "chevron.right",
                               title: open ? "Collapse node" : "Expand node",
                               size: Self.rowHeight) {
                toggle(row.node)
            }
            .frame(width: Self.rowHeight)
        } else {
            Color.clear.frame(width: Self.rowHeight, height: Self.rowHeight)
        }
    }

    @ViewBuilder
    private func nodeBadge(_ name: String, row: Row) -> some View {
        if Self.overlayBadges.contains(name) {
            pageOverlayBadge(name, for: row.id).frame(height: Self.rowHeight)
        } else if let anchor = Self.anchorName(name) {
            DeveloperDOMAnchorBadge(name: anchor) { session.revealAnchor(of: row.id) }
                .frame(height: Self.rowHeight)
        } else {
            DeveloperDOMBadge(name: name).frame(height: Self.rowHeight)
        }
    }

    /// Dropped on a row's upper half: before it. Lower half: inside it when
    /// it is open, else after it.
    private func drop(_ id: Int, on node: DeveloperToolsSession.DOMNode, upper: Bool) {
        guard id != node.id, node.pseudoType == nil else { return }
        // Only the DOM's own children: not ::before, nor a shadow root.
        func light(_ ids: [Int]) -> [Int] { ids.filter { !(session.nodes[$0]?.isExtraChild ?? false) } }
        if !upper, node.type == 1, session.expanded.contains(node.id) {
            session.move(id, into: node.id, before: light(node.children).first)
            return
        }
        guard !node.isExtraChild, let parent = node.parent,
              let siblings = session.nodes[parent].map({ light($0.children) }),
              let index = siblings.firstIndex(of: node.id) else { return }
        let before = upper ? node.id : (siblings.indices.contains(index + 1) ? siblings[index + 1] : nil)
        session.move(id, into: parent, before: before)
    }

    /// The grid or flex badge, unless Badge settings turned it off. A
    /// subgrid's reads "subgrid", as in Chrome, and shows the grid overlay.
    private func layoutBadge(_ row: Row) -> String? {
        guard row.node.type == 1, let kind = elements.layout[row.id] else { return nil }
        if kind == "grid", row.node.flags.contains("subgrid") { return subgridBadges ? "subgrid" : nil }
        return (kind == "grid" ? gridBadges : kind == "flex" ? flexBadges : true) ? kind : nil
    }

    /// Chrome's container, scroll-snap, slot, top-layer and scroll badges
    /// and WebKit's event badge, from the node's flags, as Badge settings
    /// has them.
    private func badges(for node: DeveloperToolsSession.DOMNode) -> [String] {
        guard node.type == 1 else { return [] }
        var page = Set<String>()
        if containerBadges { page.insert("container") }
        if scrollSnapBadges { page.insert("scroll-snap") }
        if slotBadges { page.insert("slot") }
        if topLayerBadges { page.insert("top-layer") }
        if anchorBadges { page.insert("anchor") }
        return Self.badges(flags: node.flags, scroll: scrollBadges, event: eventBadges, page: page)
    }

    /// The badges read from the page rather than WebKit's flags, in the
    /// order the tree shows them.
    static let pageBadges = ["container", "scroll-snap", "slot", "top-layer", "anchor"]
    /// An anchor-positioned element's flag, "anchored:" and the name its
    /// position-anchor gives; its badge reveals the anchor, as Chrome's
    /// "⚓ name" does. Shown with the anchor badge.
    static let anchoredPrefix = "anchored:"
    /// Badges that switch an overlay the page draws.
    /// Badges a click draws an overlay for. None: the container and
    /// scroll-snap overlays were drawn in the page itself, which the
    /// package doesn't do (WebKit draws grid and flex itself).
    static let overlayBadges: Set<String> = []

    static func badges(flags: [String], scroll: Bool, event: Bool, page: Set<String> = []) -> [String] {
        var output = pageBadges.filter { page.contains($0) && flags.contains($0) }
        if page.contains("anchor"), let anchored = flags.first(where: { anchorName($0) != nil }) {
            output.append(anchored)
        }
        if scroll, flags.contains("scrollable") { output.append("scroll") }
        if event, flags.contains("event") { output.append("event") }
        return output
    }

    /// The anchor name an "anchored:" flag carries, or nil for any other.
    static func anchorName(_ flag: String) -> String? {
        guard flag.hasPrefix(anchoredPrefix) else { return nil }
        let name = String(flag.dropFirst(anchoredPrefix.count))
        return name.isEmpty ? nil : name
    }

    /// A container or scroll-snap badge on the selected row: a click shows
    /// or hides its overlay, as Chrome's do (plain rows draw the same badge).
    private func pageOverlayBadge(_ kind: String, for id: Int) -> some View {
        let on = elements.pageOverlays.contains(.init(node: id, kind: kind))
        return DeveloperDOMOverlayBadge(name: kind, on: on) { session.setPageOverlay(id, kind: kind, on: !on) }
    }

    /// The overlay kinds shown for one node, for its plain row.
    static func pageOverlays(for id: Int, in shown: Set<DeveloperElementsState.PageOverlay>) -> Set<String> {
        Set(shown.lazy.filter { $0.node == id }.map(\.kind))
    }

    private func badge(_ kind: String, for id: Int) -> some View {
        let on = elements.containers.first { $0.id == id }?.showing == true
        return Button {
            session.setOverlay(id, on: !on)
        } label: {
            Text(kind).developerBadgeCapsule(on: on)
        }
        .buttonStyle(.plain)
        .help(on ? "Hide the \(kind) overlay" : "Show the \(kind) overlay")
        .accessibilityLabel("\(kind) overlay")
    }

    @ViewBuilder
    private func content(_ node: DeveloperToolsSession.DOMNode, inline: String? = nil) -> some View {
        switch node.type {
        // ::before and the like: named, not edited, as in Chrome DevTools.
        case 1 where node.pseudoType != nil:
            Text(node.display).foregroundStyle(DeveloperToolsStyle.tint)
        case 1:
            DeveloperTreeLine(wraps: wrapLines) {
                Text("<").foregroundStyle(DeveloperToolsStyle.tint)
                if editing == .tag(node.id) {
                    inlineField(width: 90) { session.setTagName(node.id, draft) }
                } else {
                    Text(node.name).foregroundStyle(DeveloperToolsStyle.tint)
                        .onEditClick(select: { clickSelect(node.id) }) { start(.tag(node.id), node.name) }
                }
                ForEach(Array(stride(from: 0, to: max(0, node.attributes.count - 1), by: 2).prefix(12)), id: \.self) { index in
                    let name = node.attributes[index], value = node.attributes[index + 1]
                    if editing == .attribute(node.id, name) {
                        Text(" ")
                        inlineField(width: 180) { session.setAttributeText(node.id, original: name, text: draft) }
                    } else {
                        (Text(" " + name).foregroundStyle(Color.secondary)
                         + Text("=\"").foregroundStyle(Color.secondary)
                         + Text(value).foregroundStyle(Color.purple)
                         + Text("\"").foregroundStyle(Color.secondary))
                            .onEditClick(select: { clickSelect(node.id) }) { start(.attribute(node.id, name), "\(name)=\"\(value)\"") }
                    }
                }
                if editing == .newAttribute(node.id) {
                    Text(" ")
                    inlineField(width: 140) { session.setAttributeText(node.id, original: nil, text: draft) }
                }
                Text(">").foregroundStyle(DeveloperToolsStyle.tint)
                    .onEditClick(select: { clickSelect(node.id) }) { start(.newAttribute(node.id), "") }
                if let inline, let child = node.children.first {
                    // Chrome's inline text child: double-click edits the text.
                    if editing == .text(child) {
                        inlineField(width: 220) { session.setText(child, draft) }
                    } else {
                        Text(inline).foregroundStyle(Palette.ink)
                            .onEditClick(select: { clickSelect(node.id) }) {
                                // The element stays selected; its row edits the text.
                                draft = session.nodes[child]?.text ?? inline
                                editing = .text(child)
                                DispatchQueue.main.async { focus = .editor }
                            }
                    }
                    Text("</\(node.name)>").foregroundStyle(DeveloperToolsStyle.tint)
                } else if node.count > 0, !session.expanded.contains(node.id) {
                    // As in Chrome, a click on the ellipsis opens the node.
                    Text("…").foregroundStyle(.secondary)
                        .onTapGesture { session.expand(node) }
                        .help("Expand node")
                    Text("</\(node.name)>").foregroundStyle(DeveloperToolsStyle.tint)
                }
            }
        case 3:
            if editing == .text(node.id) {
                inlineField(width: 220) { session.setText(node.id, draft) }
            } else {
                Text("\"" + node.display + "\"")
                    .onEditClick(select: { clickSelect(node.id) }) { start(.text(node.id), node.text) }
            }
        case 8:
            Text("<!--" + node.text + "-->").foregroundStyle(.green)
        default:
            Text(node.display).foregroundStyle(.secondary)
        }
    }

    private func inlineField(width: CGFloat, commit: @escaping () -> Void) -> some View {
        TextField("", text: $draft)
            .textFieldStyle(.plain)
            .font(DeveloperToolsStyle.code)
            .frame(minWidth: width)
            .fixedSize()
            .padding(.horizontal, 2)
            .background(DeveloperToolsStyle.surface)
            .overlay { Rectangle().strokeBorder(DeveloperToolsStyle.tint.opacity(0.6)) }
            .focused($focus, equals: .editor)
            .onSubmit { finish(commit) }
            .onExitCommand { cancel() }
            // Tab: the next attribute (past the last, a new one); ⇧Tab: the
            // one before, back to the tag name, as in Chrome DevTools.
            .onKeyPress(keys: [.tab, KeyEquivalent("\u{19}")], phases: .down) { press in
                let backwards = press.modifiers.contains(.shift) || press.key == KeyEquivalent("\u{19}")
                return advance(backwards: backwards, commit: commit) ? .handled : .ignored
            }
            .onChange(of: focus) { _, now in
                if now != .editor, editing != nil, !switching { finish(commit) }
            }
    }

    /// The edit committed and the next field of the element's opening tag
    /// opened; false for an edit Tab doesn't move (text, Edit as HTML).
    private func advance(backwards: Bool, commit: () -> Void) -> Bool {
        guard let edit = editing, let node = session.nodes[edit.node] else { return false }
        switch edit {
        case .tag, .attribute, .newAttribute: break
        default: return false
        }
        let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        // A renamed tag is a new node: its fields can't be walked on to.
        let renamed = edit == .tag(node.id) && typed.lowercased() != node.name
        let next = renamed ? nil
            : Self.nextEdit(after: edit, in: node, backwards: backwards, typedSomething: !typed.isEmpty)
        editing = nil
        commit()
        guard let next else {
            focus = .tree
            return true
        }
        switching = true
        draft = Self.draft(for: next, in: node)
        editing = next
        DispatchQueue.main.async {
            focus = .editor
            // Also when the field stayed (a second new attribute).
            DispatchQueue.main.async { switching = false }
        }
        return true
    }

    /// The fields of an opening tag in the order Tab walks them: the tag
    /// name, each attribute shown, then a new attribute. From the new
    /// attribute, Tab opens another only once something was typed in it.
    static func nextEdit(after edit: Edit, in node: DeveloperToolsSession.DOMNode, backwards: Bool,
                         typedSomething: Bool) -> Edit? {
        let names = stride(from: 0, to: max(0, node.attributes.count - 1), by: 2).prefix(12).map { node.attributes[$0] }
        let order: [Edit] = [.tag(node.id)] + names.map { .attribute(node.id, $0) } + [.newAttribute(node.id)]
        guard let at = order.firstIndex(of: edit) else { return nil }
        if edit == .newAttribute(node.id), !backwards { return typedSomething ? .newAttribute(node.id) : nil }
        let next = at + (backwards ? -1 : 1)
        return order.indices.contains(next) ? order[next] : nil
    }

    /// What a field starts with: the tag name, name="value", or nothing.
    static func draft(for edit: Edit, in node: DeveloperToolsSession.DOMNode) -> String {
        switch edit {
        case .tag: return node.name
        case .attribute(_, let name):
            let value = stride(from: 0, to: max(0, node.attributes.count - 1), by: 2)
                .first { node.attributes[$0] == name }.map { node.attributes[$0 + 1] } ?? ""
            return "\(name)=\"\(value)\""
        default: return ""
        }
    }

    /// Return on an element, as in Chrome DevTools: its first attribute,
    /// or a new one when it has none.
    static func enterEdit(for node: DeveloperToolsSession.DOMNode) -> Edit {
        node.attributes.count >= 2 ? .attribute(node.id, node.attributes[0]) : .newAttribute(node.id)
    }

    private func htmlEditor(_ node: DeveloperToolsSession.DOMNode) -> some View {
        VStack(alignment: .trailing, spacing: 3) {
            TextEditor(text: $draft)
                .font(DeveloperToolsStyle.code)
                .frame(minHeight: 60, idealHeight: 120, maxHeight: 220)
                .scrollContentBackground(.hidden)
                .background(DeveloperToolsStyle.surface)
                .overlay { Rectangle().strokeBorder(DeveloperToolsStyle.tint.opacity(0.6)) }
                .focused($focus, equals: .editor)
                .onExitCommand { cancel() }
                .accessibilityIdentifier("developer-edit-as-html")
            HStack {
                Text("⌘↩ to save, Esc to cancel").foregroundStyle(.secondary).font(.system(size: 10))
                Spacer()
                Button("Cancel") { cancel() }.buttonStyle(.borderless)
                Button("Save") { finish { session.setOuterHTML(node.id, draft) } }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(.vertical, 4)
    }

    private func start(_ edit: Edit, _ text: String) {
        session.selectNode(edit.node)
        draft = text
        editing = edit
        DispatchQueue.main.async { focus = .editor }
    }

    private func finish(_ commit: () -> Void) {
        guard editing != nil else { return }
        editing = nil
        commit()
        focus = .tree
    }

    private func cancel() {
        editing = nil
        focus = .tree
    }

    private func editAsHTML(_ id: Int) {
        session.selectNode(id)
        Task {
            guard let html = try? await session.outerHTML(of: id) else { return }
            draft = html
            editing = .html(id)
            DispatchQueue.main.async { focus = .editor }
        }
    }

    // MARK: Context menu

    @ViewBuilder
    /// Chromium's DOMTreeContextMenu, section by section: clipboard (Cut,
    /// Copy ▸, Paste), edit, debug (Hide element, Force state ▸, Break on ▸),
    /// view, save.
    private func menu(for node: DeveloperToolsSession.DOMNode) -> some View {
        let id = node.id
        let isRoot = node.parent.flatMap { session.nodes[$0] }.map { $0.type == 9 } ?? true
        if node.pseudoType != nil {
            // A pseudo-element isn't in the DOM to cut, edit or delete.
            Button("Scroll into view") { session.scrollIntoView(id) }
        } else if node.type == 1 || node.type == 3 || node.type == 8 {
            if node.type == 1, let link = DeveloperElementLink.url(attributes: node.attributes, base: session.address) {
                linkItems(link)
            }
            Button("Cut") { session.cut(id) }
            Menu("Copy") { copyItems(node) }
            Button("Paste") { session.paste(into: id) }
                .disabled(node.type != 1 || elements.clipboard == nil || elements.clipboard?.node == id)
            Divider()
            if node.type == 3 { Button("Edit text") { start(.text(id), node.text) } }
            if node.type == 1 {
                Button("Add attribute") { start(.newAttribute(id), "") }
                editAttributeMenu(node)
            }
            Button("Edit as HTML") { editAsHTML(id) }
            Button("Duplicate element") { session.duplicate(id) }.disabled(isRoot)
            Button("Delete element") { session.deleteNode(id) }
            Divider()
            debugItems(node)
            Divider()
            Button("Expand recursively") { session.expandRecursively(id) }
            Button("Collapse children") { session.collapseChildren(id) }
            if node.type == 1 {
                Button("Capture node screenshot") { session.captureScreenshot(id) }
                Button("Scroll into view") { session.scrollIntoView(id) }
                Button("Focus") { session.focusNode(id) }
            }
            Divider()
            Button("Store as global variable") { session.storeAsGlobal(id) }
        } else {
            Button("Expand recursively") { session.expandRecursively(id) }
            Button("Collapse children") { session.collapseChildren(id) }
        }
        Divider()
        // Chrome's last item: which badges the tree shows.
        Button("Badge settings…") { badgeSettings = true }
    }

    /// Chrome's link items, for an element's href or src.
    @ViewBuilder
    private func linkItems(_ link: URL) -> some View {
        let address: String = link.absoluteString
        Button("Open in new tab") { DevHost.open(link) }
        Button("Copy link address") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(address, forType: .string)
        }
        if session.resources.contains(where: { $0.url == address }) {
            Button("Reveal in Sources panel") { session.revealSource(url: address, line: 1) }
        }
        if session.requests.contains(where: { $0.url == address }) {
            Button("Reveal in Network panel") { DeveloperApplicationMore.revealInNetwork(address, in: session) }
        }
        Divider()
    }

    @ViewBuilder
    private func copyItems(_ node: DeveloperToolsSession.DOMNode) -> some View {
        let id: Int = node.id
        Button("Copy element") { session.copyNode(id) }
        Divider()
        Button("Copy outerHTML") { session.copy(.outerHTML, of: id) }
        if node.type == 1 {
            Button("Copy selector") { session.copy(.selector, of: id) }
            Button("Copy JS path") { session.copy(.jsPath, of: id) }
            Button("Copy styles") { session.copy(.styles, of: id) }
        }
        Button("Copy XPath") { session.copy(.xpath, of: id) }
        Button("Copy full XPath") { session.copy(.fullXPath, of: id) }
    }

    @ViewBuilder
    private func editAttributeMenu(_ node: DeveloperToolsSession.DOMNode) -> some View {
        let id: Int = node.id
        let names: [String] = stride(from: 0, to: max(0, node.attributes.count - 1), by: 2).map { node.attributes[$0] }
        if !names.isEmpty {
            Menu("Edit attribute") {
                ForEach(names, id: \.self) { name in
                    Button(name) {
                        let value: String = session.nodes[id].flatMap { item in
                            stride(from: 0, to: max(0, item.attributes.count - 1), by: 2)
                                .first { item.attributes[$0] == name }.map { item.attributes[$0 + 1] }
                        } ?? ""
                        start(.attribute(id, name), "\(name)=\"\(value)\"")
                    }
                }
            }
        }
    }

    /// Hide element, Force state ▸ and Break on ▸.
    @ViewBuilder
    private func debugItems(_ node: DeveloperToolsSession.DOMNode) -> some View {
        let id: Int = node.id
        if node.type == 1 {
            Toggle("Hide element", isOn: Binding(get: { elements.hidden.contains(id) }, set: { _ in session.toggleHidden(id) }))
            Menu("Force state") {
                ForEach(DeveloperToolsSession.PseudoState.chromium) { state in
                    Toggle(":" + state.rawValue, isOn: Binding(
                        get: { session.forcedStates[id, default: []].contains(state) },
                        set: { session.force(state, on: $0, for: id) }
                    ))
                }
            }
        }
        Menu("Break on") {
            ForEach(DeveloperElementsState.DOMBreakpoint.allCases) { type in
                Toggle(type.menuTitle, isOn: Binding(
                    get: { elements.breakpoints[id]?.contains(type) ?? false },
                    set: { _ in session.toggleBreakpoint(type, on: id) }
                ))
            }
        }
    }

    // MARK: Keys

    /// The tree's keys, as Chrome DevTools has them: the arrows, Home, End,
    /// Page Up and Page Down move the selection (and the page highlights
    /// what it lands on); ⌥→ and ⌥← open and close a whole subtree.
    private func key(_ press: KeyPress) -> KeyPress.Result {
        guard editing == nil, press.modifiers.isDisjoint(with: [.command, .control]) else { return .ignored }
        let option = press.modifiers.contains(.option)
        if !option, let move = DeveloperDOMTreeModel.Move(press.key) {
            let current = session.selectedNode.flatMap { tree.index[$0] }
            let page = Int(viewport / Self.rowHeight) - 1
            guard let next = DeveloperDOMTreeModel.target(move, from: current, count: tree.rows.count, page: page)
            else { return .ignored }
            let id = tree.rows[next].id
            if id != session.selectedNode { session.selectNode(id) }
            session.highlightNode(tree.rows[next].node.type == 1 ? id : nil)
            return .handled
        }
        guard let selected = session.selectedNode, let node = session.nodes[selected] else { return .ignored }
        if option {
            switch press.key {
            case .rightArrow:
                if node.count > 0 { session.expandRecursively(selected) }
                return .handled
            case .leftArrow:
                session.collapseChildren(selected)
                session.expanded.remove(selected)
                return .handled
            default:
                return .ignored
            }
        }
        // Held down, only the arrows repeat.
        if press.phase == .repeat, press.key != .leftArrow, press.key != .rightArrow { return .ignored }
        switch press.key {
        case .leftArrow:
            if session.expanded.contains(selected), node.count > 0 { session.expand(node) }
            else if let parent = node.parent, parent != session.root { session.selectNode(parent) }
            return .handled
        case .rightArrow:
            if node.count > 0, !session.expanded.contains(selected) { session.expand(node) }
            else if let child = node.children.first(where: { !(session.nodes[$0]?.display.isEmpty ?? true) }) {
                session.selectNode(child)
            }
            return .handled
        case .delete, .deleteForward:
            guard !node.isExtraChild else { return .handled }
            session.deleteNode(selected)
            return .handled
        case .return:
            // As in Chrome: an element's first attribute, or a new one.
            if node.type == 1, node.pseudoType == nil {
                let edit = Self.enterEdit(for: node)
                start(edit, Self.draft(for: edit, in: node))
            } else if node.type == 3 {
                start(.text(selected), node.text)
            }
            return .handled
        default:
            break
        }
        if press.characters == "h", node.type == 1, node.pseudoType == nil { session.toggleHidden(selected); return .handled }
        // F2: Edit as HTML.
        if press.characters == "\u{F705}" { editAsHTML(selected); return .handled }
        return .ignored
    }

    // MARK: Breadcrumbs

    private var breadcrumbs: some View {
        var ancestors: [DeveloperToolsSession.DOMNode] = []
        var id = session.selectedNode
        for _ in 0..<50 {
            guard let node = id.flatMap({ session.nodes[$0] }) else { break }
            if node.type == 1 { ancestors.append(node) }
            id = node.parent
        }
        return ScrollView(.horizontal) {
            HStack(spacing: 2) {
                ForEach(ancestors.reversed()) { node in
                    Button { session.selectNode(node.id) } label: { crumb(node) }
                        .buttonStyle(.plain)
                        .font(DeveloperToolsStyle.code)
                        .padding(.horizontal, 5).frame(height: DeveloperToolsStyle.controlHeight)
                        .background(session.selectedNode == node.id ? DeveloperToolsStyle.selected : .clear,
                                    in: RoundedRectangle(cornerRadius: DeveloperToolsStyle.controlRadius))
                        .onHover { session.highlightNode($0 ? node.id : nil) }
                }
            }
            .padding(.horizontal, DeveloperToolsStyle.gutter)
        }
        .scrollIndicators(.never)
        .background(DeveloperToolsStyle.chrome)
        .overlay(alignment: .top) { Divider() }
    }

    /// As DevTools' breadcrumbs: tag, then #id and .classes.
    private func crumb(_ node: DeveloperToolsSession.DOMNode) -> Text {
        func attribute(_ name: String) -> String? {
            stride(from: 0, to: max(0, node.attributes.count - 1), by: 2)
                .first { node.attributes[$0] == name }.map { node.attributes[$0 + 1] }
        }
        var text = Text(node.name).foregroundStyle(DeveloperToolsStyle.tint)
        if let id = attribute("id"), !id.isEmpty { text = text + Text("#" + id) }
        let classes = attribute("class")?.split(whereSeparator: \.isWhitespace) ?? []
        if !classes.isEmpty { text = text + Text("." + classes.joined(separator: ".")).foregroundStyle(.secondary) }
        return text
    }
}

struct DeveloperPanelIcon: View {
    let symbol: String
    let title: String
    var active = false
    var size = DeveloperToolsStyle.controlHeight
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size < 20 ? 10 : 12, weight: .medium))
                .foregroundStyle(active ? Palette.ink : .secondary).frame(width: size, height: size)
                .background(active ? DeveloperToolsStyle.selected : hovering ? DeveloperToolsStyle.raised : .clear,
                            in: RoundedRectangle(cornerRadius: DeveloperToolsStyle.controlRadius))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(title)
        .accessibilityLabel(title)
    }
}

/// A tree row's pieces (tag, attributes, closing tag): one line that
/// truncates, or, with Wrap lines on, lines that break between attributes
/// and within a long value.
struct DeveloperTreeLine<Content: View>: View {
    let wraps: Bool
    @ViewBuilder let content: Content

    var body: some View {
        if wraps {
            DeveloperWrapFlow { content }
        } else {
            HStack(spacing: 0) { content }
        }
    }
}

struct DeveloperWrapFlow: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let frames = frames(for: subviews, width: width)
        let used = frames.map(\.maxX).max() ?? 0
        return CGSize(width: width.isFinite ? min(width, used) : used, height: frames.map(\.maxY).max() ?? 0)
    }

    /// The first line's text baseline (and the last line's), so a row that
    /// lines up its name with the value on .firstTextBaseline puts it on the
    /// value's first line. Without it a Layout's baseline is its bottom
    /// edge, and a value wrapped over several lines rose above its row,
    /// over the declarations before it.
    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                           subviews: Subviews, cache: inout ()) -> CGFloat? {
        guard guide == .firstTextBaseline || guide == .lastTextBaseline else { return nil }
        let frames = frames(for: subviews, width: bounds.width)
        let lines = frames.indices.filter { frames[$0].height > 0 && frames[$0].width > 0 }
        let lineY = guide == .firstTextBaseline ? lines.map { frames[$0].minY }.min() : lines.map { frames[$0].minY }.max()
        guard let lineY else { return nil }
        let baselines = lines.filter { frames[$0].minY == lineY }.map { index in
            frames[index].minY + subviews[index].dimensions(in: ProposedViewSize(frames[index].size))[guide]
        }
        return baselines.max().map { bounds.minY + $0 }
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (view, frame) in zip(subviews, frames(for: subviews, width: bounds.width)) {
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                       anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }

    private func frames(for subviews: Subviews, width: CGFloat) -> [CGRect] {
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0
        return subviews.map { view in
            var size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += line
                line = 0
            }
            // A piece wider than the row wraps inside itself.
            if size.width > width, width.isFinite {
                size = view.sizeThatFits(ProposedViewSize(width: width, height: nil))
                size.width = min(size.width, width)
            }
            let frame = CGRect(x: x, y: y, width: size.width, height: size.height)
            x += size.width
            line = max(line, size.height)
            return frame
        }
    }
}

private extension View {
    /// A double-click that edits, even when the first click landed on the
    /// plain row this one replaced on selection: AppKit's click count spans
    /// both views, where SwiftUI's count: 2 gesture would see one tap each.
    func onEditClick(select: @escaping () -> Void, edit: @escaping () -> Void) -> some View {
        onTapGesture {
            if (NSApp.currentEvent?.clickCount ?? 1) >= 2 { edit() } else { select() }
        }
    }
}

/// The Elements panel's ⌘ keys, heard before the window's shortcuts (which
/// take ⌘F for Find on Page and ⌘G for its next match). As in Chrome
/// DevTools: anywhere in the panel ⌘F searches the tree, ⌘G and ⇧⌘G step
/// through its matches, and ⌘Z and ⇧⌘Z undo and redo DOM edits, though a
/// field being typed in keeps them for its text; while the tree has the
/// keyboard, ⌘C, ⌘X and ⌘V copy, cut and paste the selected node.
enum DeveloperElementsKeys {
    enum Clipboard { case copy, cut, paste }

    struct Actions {
        var find: () -> Void
        /// False while there is no search to step through.
        var findNext: (_ backwards: Bool) -> Bool
        var undo: () -> Void
        var redo: () -> Void
        /// False when there is no node to copy, cut or paste into.
        var clipboard: (Clipboard) -> Bool
    }

    /// The tree's, while it is on screen.
    @MainActor static var actions: Actions?
    /// Whether the tree itself has the keyboard (its FocusState).
    @MainActor static var treeFocused = false
    /// The panel on screen (DeveloperElementsKeyRegion).
    @MainActor static weak var region: NSView?
    /// The last click in the panel's window landed in the panel.
    @MainActor private static var clickedInside = false
    /// Asked by DevTools' key monitor (DeveloperToolsKeys.takeFirst), after
    /// the code view's keys and before DevTools' own.
    @MainActor static func take(_ event: NSEvent) -> Bool {
        guard let window = event.window, let region = Self.region, region.window === window else { return false }
        let frame = region.convert(region.bounds, to: nil)
        if event.type == .leftMouseDown {
            clickedInside = frame.contains(event.locationInWindow)
            return false
        }
        guard event.type == .keyDown, let actions = Self.actions else { return false }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard flags == .command || flags == [.command, .shift] else { return false }
        let shifted = flags.contains(.shift)
        let responder = window.firstResponder
        let typing = responder is NSTextView
        guard inPanel(responder, region: region, frame: frame) else { return false }
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch key {
        case "f" where !shifted:
            actions.find()
            return true
        case "g":
            return actions.findNext(shifted)
        case "z":
            guard !typing else { return false }
            if shifted { actions.redo() } else { actions.undo() }
            return true
        case "c", "x", "v":
            guard !shifted, !typing, treeFocused else { return false }
            return actions.clipboard(key == "c" ? .copy : key == "x" ? .cut : .paste)
        default:
            return false
        }
    }

    /// Whether the keyboard is in the panel: a field or view inside its
    /// frame, or the SwiftUI host the tree's focus lives in while the tree
    /// has it or the panel was the last thing clicked. Never the page.
    @MainActor private static func inPanel(_ responder: NSResponder?, region: NSView, frame: NSRect) -> Bool {
        var view = responder as? NSView
        // A field's editor stands in for the field.
        if let editor = view as? NSTextView, editor.isFieldEditor, let field = editor.delegate as? NSView {
            view = field
        }
        guard let view else { return treeFocused || clickedInside }
        var ancestor: NSView? = view
        while let current = ancestor {
            if current is WKWebView { return false }
            ancestor = current.superview
        }
        if region.isDescendant(of: view) { return treeFocused || clickedInside }
        let own = view.convert(view.bounds, to: nil)
        return frame.contains(NSPoint(x: own.midX, y: own.midY))
    }
}

/// Marks where the Elements panel is in its window, for its ⌘ keys; it
/// takes no clicks.
struct DeveloperElementsKeyRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> RegionView { RegionView() }
    func updateNSView(_ view: RegionView, context: Context) {}

    final class RegionView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil {
                DeveloperElementsKeys.region = self
            } else if DeveloperElementsKeys.region === self {
                DeveloperElementsKeys.region = nil
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}


/// The address an element links to or loads, as its context menu offers
/// it: its href, else its src, resolved against the page.
enum DeveloperElementLink {
    static func url(attributes: [String], base: URL?) -> URL? {
        for name in ["href", "src"] {
            guard let index = stride(from: 0, to: max(0, attributes.count - 1), by: 2)
                .first(where: { attributes[$0].lowercased() == name }) else { continue }
            let value = attributes[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, !value.hasPrefix("#"), !value.lowercased().hasPrefix("javascript:") else { return nil }
            guard let url = URL(string: value, relativeTo: base)?.absoluteURL, url.scheme != nil else { return nil }
            return url
        }
        return nil
    }
}
