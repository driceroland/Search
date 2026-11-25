import AppKit
import SwiftUI

/// Elements' full-page accessibility tree, as Chrome's "Switch to
/// accessibility tree view" shows it in the DOM tree's place: a row per
/// accessible node, its role and name, ignored nodes skipped. Read a level
/// at a time from DOM.getAccessibilityPropertiesForNode as rows open.
@MainActor
final class DeveloperAccessibilityTree: ObservableObject {
    struct Node: Identifiable, Equatable {
        /// The DOM node's id: selecting the row selects it.
        let id: Int
        let role: String
        let name: String
        /// Accessibility children before ignored ones are skipped.
        let childCount: Int
    }

    struct Row: Identifiable, Equatable {
        let node: Node
        let depth: Int
        var id: Int { node.id }
    }

    @Published private(set) var roots: [Node] = []
    @Published private(set) var children: [Int: [Node]] = [:]
    @Published private(set) var expanded = Set<Int>()
    @Published private(set) var loading = false
    /// Each load's number, so an older read finishing late is dropped.
    private var generation = 0

    /// The most rows the tree lists, however much is open.
    static let rowLimit = 5000

    static func nodes(_ raw: Any?) -> [Node] {
        (raw as? [[String: Any]] ?? []).compactMap { item in
            guard let id = item["nodeId"] as? Int else { return nil }
            return Node(id: id, role: item["role"] as? String ?? "", name: item["name"] as? String ?? "",
                        childCount: item["childCount"] as? Int ?? 0)
        }
    }

    var rows: [Row] { Self.rows(roots: roots, children: children, expanded: expanded) }

    /// The open rows in order, each under its parent; a node met again
    /// (the accessibility tree reaches it twice) isn't listed again.
    static func rows(roots: [Node], children: [Int: [Node]], expanded: Set<Int>) -> [Row] {
        var output: [Row] = []
        var seen = Set<Int>()
        var stack: [(Node, Int)] = roots.reversed().map { ($0, 0) }
        while output.count < rowLimit, let item = stack.popLast() {
            let (node, depth) = item
            guard seen.insert(node.id).inserted else { continue }
            output.append(Row(node: node, depth: depth))
            if expanded.contains(node.id), let below = children[node.id] {
                stack.append(contentsOf: below.reversed().map { ($0, depth + 1) })
            }
        }
        return output
    }

    /// The tree read again from its root, which opens, as in Chrome.
    func load(_ session: DeveloperToolsSession) async {
        generation += 1
        let current = generation
        loading = true
        let found = await session.accessibilityTreeRoot()
        guard current == generation else { return }
        roots = found
        children = [:]
        expanded = []
        loading = false
        if let first = found.first, first.childCount > 0 { await open(first.id, session) }
    }

    func toggle(_ id: Int, _ session: DeveloperToolsSession) {
        if expanded.contains(id) {
            expanded.remove(id)
        } else {
            Task { await open(id, session) }
        }
    }

    func open(_ id: Int, _ session: DeveloperToolsSession) async {
        let current = generation
        if children[id] == nil {
            let found = await session.accessibilityTreeChildren(of: id)
            guard current == generation else { return }
            children[id] = found
        }
        expanded.insert(id)
    }
}

extension DeveloperToolsSession {
    /// The accessibility tree's root row: the document's web area, else
    /// what <html> or <body> leads to.
    func accessibilityTreeRoot() async -> [DeveloperAccessibilityTree.Node] {
        guard ready, let root else { return [] }
        func child(of parent: Int?, named name: String) -> Int? {
            guard let parent, let node = nodes[parent] else { return nil }
            return node.children.first { id in nodes[id]?.type == 1 && nodes[id]?.name == name }
        }
        let html = child(of: root, named: "html")
        let body = child(of: html, named: "body")
        let candidates = [root, html, body].compactMap { $0 }
        let raw = try? await elementsBridge("return await searchElements.accessibilityTreeRoot(candidates, target);", [
            "candidates": candidates, "target": domTargetID as Any? ?? NSNull(),
        ])
        return DeveloperAccessibilityTree.nodes(raw)
    }

    /// A row's children as it opens, ignored nodes skipped, at most 200.
    func accessibilityTreeChildren(of id: Int) async -> [DeveloperAccessibilityTree.Node] {
        guard ready else { return [] }
        let raw = try? await elementsBridge("return await searchElements.accessibilityTreeChildren(node, target);", [
            "node": id, "target": domTargetID as Any? ?? NSNull(),
        ])
        return DeveloperAccessibilityTree.nodes(raw)
    }
}

/// The accessibility tree in the Elements panel: a click selects the row's
/// DOM node (shown in Styles and the rest), hovering highlights it.
struct DeveloperAccessibilityTreeView: View {
    @ObservedObject var session: DeveloperToolsSession
    @StateObject private var tree = DeveloperAccessibilityTree()

    var body: some View {
        let rows = tree.rows
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in line(row) }
            }
            .padding(.vertical, 3)
        }
        .overlay {
            if rows.isEmpty {
                Text(tree.loading ? "Loading accessibility tree…" : "No accessibility tree")
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: session.domRevision) { await tree.load(session) }
        .accessibilityIdentifier("developer-elements-accessibility-tree-view")
    }

    private func line(_ row: DeveloperAccessibilityTree.Row) -> some View {
        let selected = session.selectedNode == row.id
        let open = tree.expanded.contains(row.id)
        let height = DeveloperDOMTreeView.rowHeight
        return HStack(spacing: 1) {
            if row.node.childCount > 0 {
                DeveloperPanelIcon(symbol: open ? "chevron.down" : "chevron.right",
                                   title: open ? "Collapse node" : "Expand node", size: height) {
                    tree.toggle(row.id, session)
                }
                .frame(width: height)
            } else {
                Color.clear.frame(width: height, height: height)
            }
            // As Chrome writes a row: the role, then the name in quotes.
            Text(row.node.role.isEmpty ? "generic" : row.node.role)
                .foregroundStyle(DeveloperToolsStyle.tint)
            if !row.node.name.isEmpty {
                Text(" \"" + row.node.name + "\"").foregroundStyle(Color.purple)
            }
            Spacer(minLength: 0)
        }
        .font(DeveloperToolsStyle.code)
        .lineLimit(1)
        .frame(height: height)
        .padding(.leading, DeveloperDOMTreeView.leading(row.depth))
        .padding(.trailing, DeveloperToolsStyle.gutter)
        .background(selected ? DeveloperToolsStyle.selected : .clear)
        .contentShape(Rectangle())
        .onTapGesture {
            if (NSApp.currentEvent?.clickCount ?? 1) >= 2, row.node.childCount > 0 { tree.toggle(row.id, session) }
            else { session.selectNode(row.id) }
        }
        .onHover { inside in session.highlightNode(inside ? row.id : nil) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.node.role + (row.node.name.isEmpty ? "" : " " + row.node.name))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
