import AppKit
import Combine

/// What the Elements panel keeps beside the DOM tree for one session.
@MainActor
final class DeveloperElementsState: ObservableObject {
    /// Nodes switched to `visibility: hidden` with H (Hide element).
    @Published var hidden = Set<Int>()
    /// Node id → "grid" or "flex", for the tree's badges.
    @Published var layout: [Int: String] = [:]
    /// Grid and flex containers listed in the Layout tab.
    @Published var containers: [LayoutContainer] = []
    /// The container and scroll-snap overlays shown, which the page draws
    /// (WebKit has no overlay of its own for them).
    @Published var pageOverlays = Set<PageOverlay>()
    @Published var fonts: [RenderedFont] = []
    @Published var fontsNode: Int?
    /// Classes switched off in the .cls pane, kept so they can come back.
    @Published var offClasses: [Int: [String]] = [:]
    /// Break on: node id → the DOMDebugger types set on it.
    @Published var breakpoints: [Int: Set<DOMBreakpoint>] = [:]
    /// A node cut or copied in the tree, for Paste.
    @Published var clipboard: (node: Int, cut: Bool)?
    /// Layout › Overlay display settings for grids.
    @Published var gridOptions = GridOptions()
    /// The Styles editor open now: a selector, a declaration's name or
    /// value, or a new declaration. Kept here rather than in a rule's view
    /// because every write reads the cascade back and rebuilds those views.
    @Published var styleEdit: StyleEdit?
    /// A rule just added with + (New Style Rule), whose selector opens for
    /// editing as soon as the rule shows, as in Chrome DevTools.
    @Published var pendingSelector: DeveloperToolsSession.StyleID?
    /// A declaration's name ↑ or ↓ moved to past the end of a rule, in
    /// the rule above or below: opened once that rule's view takes it.
    @Published var pendingName: PendingName?
    /// The sidebar tab asked for ("Styles" or "Computed"), by View computed
    /// value and Computed's → buttons; DeveloperElementsView brings it
    /// forward and clears it.
    @Published var requestedSidebar: String?
    /// A property name Computed filters to when it next shows.
    @Published var computedFilter: String?
    /// A declaration Styles scrolls to and flashes.
    @Published var flash: StyleFlash?
    /// Event Listeners: the listeners (by eventListenerId) the debugger
    /// pauses on when their event is dispatched.
    @Published var listenerBreakpoints = Set<Int>()
    /// Accessibility › Show source order: the element whose descendants
    /// the page numbers, nil when off.
    @Published var sourceOrder: SourceOrder?

    struct SourceOrder: Equatable {
        let node: Int
        /// How many badges the page drew, once it answered.
        var shown: Int? = nil
        var capped = false
    }
    /// Rules edited in Styles since the page loaded, for Copy all CSS changes.
    private(set) var changes: [StyleChange] = []
    private var flashSerial = 0

    struct PageOverlay: Hashable {
        let node: Int
        /// "container" or "scroll-snap", as the tree's badge names it.
        let kind: String
    }

    struct PendingName: Equatable {
        /// The rule's id, for the pane to scroll to.
        let rule: Int
        let style: DeveloperToolsSession.StyleID
        let index: Int
    }

    /// One open Styles editor and the declarations it works on.
    struct StyleEdit: Equatable {
        typealias Field = DeveloperStyleEditing.Field
        let style: DeveloperToolsSession.StyleID
        var field: Field
        var name = ""
        var value = ""
        var selector = ""
        /// The rule's declarations when editing began.
        let original: [DeveloperToolsSession.Detail]
        /// The declarations as edited so far, shown while the editor is open.
        var working: [DeveloperToolsSession.Detail]
        /// The declarations when the current one's editing began: Esc goes
        /// back to these, as in Chrome DevTools.
        var checkpoint: [DeveloperToolsSession.Detail]
        /// Whether a step or a Tab wrote the rule while the editor stayed open.
        var written = false
        /// Whether completions show: only once something is typed.
        var suggest = false
        /// The completion highlighted with the arrow keys.
        var highlight = 0

        init(style: DeveloperToolsSession.StyleID, field: Field, properties: [DeveloperToolsSession.Detail], selector: String) {
            self.style = style
            self.field = field
            original = properties
            working = properties
            checkpoint = properties
            enter(field, selector: selector)
        }

        /// Moves to another field: its text read from the declarations, and
        /// a new checkpoint when it belongs to another declaration.
        mutating func enter(_ next: Field, selector current: String) {
            let same = DeveloperStyleEditing.declaration(of: next) == DeveloperStyleEditing.declaration(of: field)
            if !same { checkpoint = working }
            switch next {
            case .selector:
                selector = current
            case .name(let index), .value(let index):
                if working.indices.contains(index) {
                    name = working[index].name
                    value = working[index].value + (working[index].important ? " !important" : "")
                }
            case .newName:
                if !same { name = ""; value = "" }
            case .newValue:
                if !same { value = "" }
            }
            field = next
            if case .newValue = next { suggest = value.isEmpty } else { suggest = false }
            highlight = 0
        }
    }

    struct StyleFlash: Equatable {
        let rule: Int
        let name: String
        let serial: Int
    }

    /// One edited rule as Chrome's Changes tool keeps it.
    struct StyleChange {
        let key: String
        let selector: String
        let original: [DeveloperToolsSession.Detail]
        var current: [DeveloperToolsSession.Detail]
    }

    /// The declaration flashed in Styles for a moment, as Chrome DevTools
    /// flashes the one a link or → button leads to.
    func flashDeclaration(rule: Int, name: String) {
        flashSerial += 1
        let serial = flashSerial
        flash = StyleFlash(rule: rule, name: name, serial: serial)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            if self?.flash?.serial == serial { self?.flash = nil }
        }
    }

    func recordChange(_ rule: DeveloperToolsSession.StyleRule, from original: [DeveloperToolsSession.Detail],
                      to properties: [DeveloperToolsSession.Detail]) {
        let key = [rule.selector, rule.origin, rule.sourceURL ?? "", rule.sourceLine.map(String.init) ?? "",
                   rule.inline ? "inline" : ""].joined(separator: "\n")
        if let index = changes.firstIndex(where: { $0.key == key }) {
            changes[index].current = properties
            if changes[index].current == changes[index].original { changes.remove(at: index) }
        } else if original != properties {
            changes.append(StyleChange(key: key, selector: rule.selector, original: original, current: properties))
        }
    }

    /// Copy all CSS changes: every edited rule, removed lines commented out.
    var changesText: String {
        changes.map { DeveloperStyleEditing.changesText(selector: $0.selector, original: $0.original, current: $0.current) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    struct GridOptions: Equatable {
        enum Labels: String, CaseIterable, Identifiable {
            case hidden = "Hide line labels", numbers = "Show line numbers", names = "Show line names"
            var id: Self { self }
        }
        var labels = Labels.numbers
        var trackSizes = false
        var areaNames = false
        var extendedLines = false
        var protocolValue: [String: Any] {
            ["lineNumbers": labels == .numbers, "lineNames": labels == .names, "trackSizes": trackSizes,
             "areaNames": areaNames, "extendedLines": extendedLines]
        }
    }

    /// Chromium's labels for DOM breakpoint types (Break on ▸).
    enum DOMBreakpoint: String, CaseIterable, Identifiable {
        case subtree = "subtree-modified", attribute = "attribute-modified", removal = "node-removed"
        var id: Self { self }
        var menuTitle: String {
            switch self {
            case .subtree: "subtree modifications"
            case .attribute: "attribute modifications"
            case .removal: "node removal"
            }
        }
    }
    /// Supported CSS properties and their keyword values, for autocomplete.
    @Published private(set) var catalog: [String: [String]] = DeveloperElementsState.sharedCatalog
    private(set) var propertyNames: [String] = DeveloperElementsState.sharedNames
    private static var sharedCatalog: [String: [String]] = [:]
    private static var sharedNames: [String] = []

    struct LayoutContainer: Identifiable, Equatable {
        let id: Int
        let kind: String
        let label: String
        var showing: Bool
        var color: String?
    }

    struct RenderedFont: Identifiable, Equatable {
        let name: String
        let url: String?
        let glyphs: Int
        let synthesized: Bool
        var id: String { name + (url ?? "") }
        /// As Chromium's Rendered fonts lists it.
        var origin: String { url == nil ? "Local file" : "Network resource" }
    }

    func reset() {
        hidden = []
        layout = [:]
        containers = []
        pageOverlays = []
        fonts = []
        fontsNode = nil
        offClasses = [:]
        breakpoints = [:]
        clipboard = nil
        styleEdit = nil
        pendingSelector = nil
        pendingName = nil
        flash = nil
        changes = []
        listenerBreakpoints = []
        sourceOrder = nil
    }

    func setCatalog(_ raw: [[String: Any]]) {
        var map: [String: [String]] = [:]
        for item in raw {
            guard let name = item["name"] as? String else { continue }
            map[name] = item["values"] as? [String] ?? []
        }
        guard !map.isEmpty else { return }
        Self.sharedCatalog = map
        Self.sharedNames = map.keys.sorted { a, b in
            // Unprefixed names first, as DevTools suggests them.
            let ap = a.hasPrefix("-"), bp = b.hasPrefix("-")
            return ap == bp ? a < b : !ap
        }
        propertyNames = Self.sharedNames
        catalog = map
    }

    /// Up to `limit` completions for what is typed in a declaration editor:
    /// property names before the colon, that property's values after it.
    func completions(for typed: String, limit: Int = 8) -> [String] {
        if let colon = typed.firstIndex(of: ":") {
            let name = typed[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = typed[typed.index(after: colon)...]
            let word = value.split(separator: " ", omittingEmptySubsequences: false).last.map(String.init) ?? ""
            let values = (catalog[name] ?? []) + ["inherit", "initial", "unset", "revert"]
            guard !word.isEmpty else { return Array(values.prefix(limit)) }
            return Array(values.filter { $0.hasPrefix(word.lowercased()) && $0 != word }.prefix(limit))
        }
        let word = typed.trimmingCharacters(in: .whitespaces).lowercased()
        guard !word.isEmpty else { return [] }
        return Array(propertyNames.filter { $0.hasPrefix(word) && $0 != word }.prefix(limit))
    }

    /// The typed text with its last word replaced by a completion.
    static func complete(_ typed: String, with completion: String) -> String {
        if let colon = typed.firstIndex(of: ":") {
            let head = typed[...colon]
            var words = typed[typed.index(after: colon)...].split(separator: " ", omittingEmptySubsequences: false).map(String.init)
            if words.isEmpty { words = [""] }
            words[words.count - 1] = completion
            let joined = words.joined(separator: " ")
            return head + (joined.hasPrefix(" ") ? joined : " " + joined)
        }
        return completion + ": "
    }
}

extension DeveloperToolsSession {
    enum CopyKind: String, CaseIterable, Identifiable {
        case outerHTML = "Copy outerHTML"
        case selector = "Copy selector"
        case jsPath = "Copy JS path"
        case styles = "Copy styles"
        case xpath = "Copy XPath"
        case fullXPath = "Copy full XPath"
        case element = "Copy element"
        var id: Self { self }
    }

    private var target: Any { domTargetID as Any? ?? NSNull() }

    /// The Elements helpers run with the bridge, installed on first use.
    func elementsBridge(_ body: String, _ arguments: [String: Any] = [:]) async throws -> Any? {
        try await bridge(DeveloperElementsBridgeScript.source + "\n" + body, arguments)
    }

    // MARK: Tree contents

    /// Attributes, text and layout badges for nodes the tree knows by id,
    /// read from the frontend's own DOM model.
    func syncNodes(_ ids: Set<Int>) {
        guard ready, !ids.isEmpty else { return }
        let revision = domRevision
        let target = self.target
        Task { [weak self] in
            guard let self else { return }
            let raw = try? await self.elementsBridge("return searchElements.details(ids, target);", [
                "ids": Array(ids), "target": target,
            ]) as? [String: [String: Any]]
            guard self.domRevision == revision, let raw else { return }
            self.apply(details: raw)
        }
    }

    private func apply(details raw: [String: [String: Any]]) {
        var tree = nodes
        var layout = elements.layout
        var changed = false
        for (key, item) in raw {
            guard let id = Int(key), var node = tree[id] else { continue }
            let attributes = (item["attributes"] as? [String] ?? node.attributes).prefix(60).map { String($0.prefix(300)) }
            let text = String((item["nodeValue"] as? String ?? node.text).prefix(300))
            let count = item["childNodeCount"] as? Int ?? node.count
            if node.attributes != attributes || node.text != text || node.count != max(count, node.children.count) {
                node.attributes = attributes
                node.text = text
                node.count = max(count, node.children.count)
                tree[id] = node
                changed = true
            }
            layout[id] = item["layout"] as? String
        }
        if changed { nodes = tree }
        if layout != elements.layout { elements.layout = layout }
    }

    /// A parent's children as the frontend has them now, after an edit.
    private func reloadChildren(of parent: Int) async {
        guard nodes[parent] != nil else { return }
        let target = self.target
        guard let children = try? await elementsBridge("return await searchElements.children(node, target);", [
            "node": parent, "target": target,
        ]) as? [[String: Any]] else { return }
        var tree = nodes
        let old = Set(tree[parent]?.children ?? [])
        let ids = Self.addNodes(children, into: &tree, parent: parent)
        tree[parent]?.children = ids
        tree[parent]?.count = ids.count
        for gone in old.subtracting(ids) { tree.removeValue(forKey: gone) }
        nodes = tree
        syncNodes(Set(ids).union([parent]))
    }

    /// A node and its ancestors (nearest first) placed under the first one
    /// the tree already has.
    private func insertChain(_ chain: [[String: Any]]) {
        guard let start = chain.firstIndex(where: { ($0["parentId"] as? Int).map { nodes[$0] != nil } ?? false }) else { return }
        var tree = nodes
        var added = Set<Int>()
        for item in chain[...start].reversed() {
            guard let parent = item["parentId"] as? Int, tree[parent] != nil,
                  let id = Self.addNodes([item], into: &tree, parent: parent).first else { break }
            if let siblings = tree[parent]?.children, !siblings.contains(id) {
                let ordered = DOMNode.treeOrder(siblings + [id], in: tree)
                tree[parent]?.children = ordered
            }
            added.insert(id)
        }
        nodes = tree
        syncNodes(added)
    }

    /// The element ancestors of a node, nearest first, as the Styles
    /// pane's "Inherited from …" headers name them.
    func ancestorLabels(of id: Int) -> [[String: Any]] {
        var output: [[String: Any]] = []
        var parent = nodes[id]?.parent
        while let current = parent, let node = nodes[current], output.count < 100 {
            if node.type == 1 { output.append(["nodeId": current, "label": Self.label(node)]) }
            parent = node.parent
        }
        return output
    }

    /// tag#id.class, as DevTools writes a node in links and breadcrumbs.
    static func label(_ node: DOMNode) -> String {
        func attribute(_ name: String) -> String? {
            stride(from: 0, to: max(0, node.attributes.count - 1), by: 2)
                .first { node.attributes[$0] == name }.map { node.attributes[$0 + 1] }
        }
        let classes = attribute("class")?.split(whereSeparator: \.isWhitespace) ?? []
        return node.name + (attribute("id").map { $0.isEmpty ? "" : "#" + $0 } ?? "")
            + classes.map { "." + $0 }.joined()
    }

    func expandRecursively(_ id: Int) {
        run(inCurrentDocument: true) { session in
            let raw = try await session.elementsBridge("return await searchElements.subtree(node, target);", [
                "node": id, "target": session.target,
            ]) as? [String: Any]
            guard let raw, let node = session.nodes[id] else { return }
            var tree = session.nodes
            _ = Self.addNodes([raw], into: &tree, parent: node.parent)
            var open = session.expanded
            var stack = [id]
            while let next = stack.popLast(), open.count < 3_000 {
                guard let item = tree[next], !item.children.isEmpty else { continue }
                open.insert(next)
                stack.append(contentsOf: item.children)
            }
            session.nodes = tree
            session.expanded = open
            session.syncNodes(Set(tree.keys))
        }
    }

    func collapseChildren(_ id: Int) {
        var stack = nodes[id]?.children ?? []
        var open = expanded
        while let next = stack.popLast() {
            open.remove(next)
            stack.append(contentsOf: nodes[next]?.children ?? [])
        }
        expanded = open
    }

    /// ⌘F in the tree: text, a CSS selector or an XPath, as DevTools takes it.
    func searchDOM(_ query: String) async -> [Int] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ready, !query.isEmpty else { return [] }
        let revision = domRevision
        guard let found = try? await elementsBridge("return await searchElements.search(query, target);", [
            "query": query, "target": target,
        ]) as? [[String: Any]], domRevision == revision else { return [] }
        var ids: [Int] = []
        for item in found {
            guard let id = item["nodeId"] as? Int else { continue }
            if nodes[id] == nil, let chain = item["chain"] as? [[String: Any]] { insertChain(chain) }
            if nodes[id] != nil, nodes[id]?.type == 1 || nodes[id]?.type == 3 { ids.append(id) }
        }
        // Text matches select their element, as DevTools highlights them.
        var seen = Set<Int>()
        return ids.compactMap { id in
            let element = nodes[id]?.type == 3 ? nodes[id]?.parent ?? id : id
            return seen.insert(element).inserted ? element : nil
        }
    }

    // MARK: Editing (each a step ⌘Z can take back)

    private func edit(_ change: @escaping @MainActor (DeveloperToolsSession, Any) async throws -> Void) {
        run(inCurrentDocument: true) { session in
            try await change(session, session.target)
            _ = try? await session.command("DOM.markUndoableState", targetID: session.domTargetID)
        }
    }

    func outerHTML(of id: Int) async throws -> String {
        let reply = try await command("DOM.getOuterHTML", ["nodeId": id], targetID: domTargetID)
        return reply["outerHTML"] as? String ?? ""
    }

    /// Edit as HTML: the node replaced by what was typed; the new node selected.
    func setOuterHTML(_ id: Int, _ html: String) {
        guard let node = nodes[id], let parent = node.parent else { return }
        let index = nodes[parent]?.children.firstIndex(of: id)
        edit { session, _ in
            _ = try await session.command("DOM.setOuterHTML", ["nodeId": id, "outerHTML": html], targetID: session.domTargetID)
            await session.reloadChildren(of: parent)
            let children = session.nodes[parent]?.children ?? []
            if let index, children.indices.contains(index) { session.selectNode(children[index]) }
            else { session.selectNode(parent) }
        }
    }

    func deleteNode(_ id: Int) {
        guard let node = nodes[id], let parent = node.parent else { return }
        let siblings = nodes[parent]?.children ?? []
        let index = siblings.firstIndex(of: id) ?? 0
        // DevTools selects the next sibling, else the previous one, else the parent.
        let next = siblings.indices.contains(index + 1) ? siblings[index + 1]
            : index > 0 ? siblings[index - 1] : parent
        edit { session, _ in
            _ = try await session.command("DOM.removeNode", ["nodeId": id], targetID: session.domTargetID)
            await session.reloadChildren(of: parent)
            if session.selectedNode == id || session.selectedNode == nil { session.selectNode(next) }
        }
    }

    func duplicate(_ id: Int) {
        guard let parent = nodes[id]?.parent else { return }
        edit { session, _ in
            let html = try await session.outerHTML(of: id)
            _ = try await session.command("DOM.insertAdjacentHTML", ["nodeId": id, "position": "afterend", "html": html],
                                          targetID: session.domTargetID)
            await session.reloadChildren(of: parent)
        }
    }

    func setTagName(_ id: Int, _ name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let node = nodes[id], node.name != name.lowercased(), let parent = node.parent else { return }
        edit { session, _ in
            let reply = try await session.command("DOM.setNodeName", ["nodeId": id, "name": name], targetID: session.domTargetID)
            await session.reloadChildren(of: parent)
            if let new = reply["nodeId"] as? Int { session.selectNode(new) }
        }
    }

    /// An attribute retyped as `name="value"` (several allowed), or a new
    /// one added when `original` is nil; emptied, it goes.
    func setAttributeText(_ id: Int, original: String?, text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard original != nil || !text.isEmpty else { return }
        edit { session, _ in
            if text.isEmpty, let original {
                _ = try await session.command("DOM.removeAttribute", ["nodeId": id, "name": original], targetID: session.domTargetID)
            } else {
                var params: [String: Any] = ["nodeId": id, "text": text]
                if let original { params["name"] = original }
                _ = try await session.command("DOM.setAttributesAsText", params, targetID: session.domTargetID)
            }
            await session.refreshAttributes(id)
        }
    }

    func removeAttribute(_ id: Int, name: String) {
        edit { session, _ in
            _ = try await session.command("DOM.removeAttribute", ["nodeId": id, "name": name], targetID: session.domTargetID)
            await session.refreshAttributes(id)
        }
    }

    func setText(_ id: Int, _ text: String) {
        edit { session, _ in
            _ = try await session.command("DOM.setNodeValue", ["nodeId": id, "value": text], targetID: session.domTargetID)
            session.nodes[id]?.text = String(text.prefix(300))
        }
    }

    private func refreshAttributes(_ id: Int) async {
        let reply = try? await command("DOM.getAttributes", ["nodeId": id], targetID: domTargetID)
        if let values = reply?["attributes"] as? [String] {
            nodes[id]?.attributes = values.prefix(60).map { String($0.prefix(300)) }
        }
        if selectedNode == id { selectNode(id) }
    }

    /// Dragged in the tree: into `parent`, before `before` (or last).
    func move(_ id: Int, into parent: Int, before: Int?) {
        guard id != parent, before != id, let from = nodes[id]?.parent else { return }
        // A node can't go inside itself.
        var ancestor: Int? = parent
        while let current = ancestor {
            if current == id { return }
            ancestor = nodes[current]?.parent
        }
        edit { session, _ in
            var params: [String: Any] = ["nodeId": id, "targetNodeId": parent]
            if let before { params["insertBeforeNodeId"] = before }
            let reply = try await session.command("DOM.moveTo", params, targetID: session.domTargetID)
            await session.reloadChildren(of: from)
            if from != parent { await session.reloadChildren(of: parent) }
            session.expanded.insert(parent)
            if let moved = reply["nodeId"] as? Int { session.selectNode(moved) }
        }
    }

    func undo() { history("DOM.undo") }
    func redo() { history("DOM.redo") }

    private func history(_ method: String) {
        run(inCurrentDocument: true) { session in
            _ = try await session.command(method, targetID: session.domTargetID)
            // The tree follows from the DOM events WebKit sends back; the
            // selection's styles and attributes are read again now.
            if let selected = session.selectedNode, let parent = session.nodes[selected]?.parent {
                await session.reloadChildren(of: parent)
            }
            if let selected = session.selectedNode, session.nodes[selected] != nil {
                await session.refreshAttributes(selected)
            }
        }
    }

    // MARK: Context menu

    func copyText(_ kind: CopyKind, of id: Int) async throws -> String {
        switch kind {
        case .outerHTML, .element:
            return try await outerHTML(of: id)
        case .styles:
            if selectedNode == id { return copiedStyles() }
            let raw = try await elementsBridge("return await searchElements.styles(node, target);", [
                "node": id, "target": target,
            ]) as? [[String: Any]] ?? []
            return copiedStyles(StyleRule.cascade(raw.enumerated().compactMap { StyleRule(raw: $1, id: $0) }))
        default:
            let paths = try await elementsBridge("return await searchElements.paths(node, target);", [
                "node": id, "target": target,
            ]) as? [String: String] ?? [:]
            switch kind {
            case .selector: return paths["selector"] ?? ""
            case .jsPath: return paths["jsPath"] ?? ""
            case .xpath: return paths["xpath"] ?? ""
            default: return paths["fullXPath"] ?? ""
            }
        }
    }

    func copy(_ kind: CopyKind, of id: Int) {
        run(inCurrentDocument: true) { session in
            let text = try await session.copyText(kind, of: id)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    /// Copy styles: the selected element's winning author declarations, as
    /// DevTools copies them (inherited ones only where they inherit).
    func copiedStyles(_ rules: [StyleRule]? = nil) -> String {
        var lines: [String] = []
        for rule in (rules ?? matchedStyles).reversed() where rule.pseudo == nil && rule.origin != "user-agent" && !rule.atRule {
            for property in rule.properties where property.enabled && property.parsed && !property.overridden {
                if rule.inherited && !property.inheritable { continue }
                lines.append("    \(property.name): \(property.value)\(property.important ? " !important" : "");")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Hide element (H): `visibility: hidden` through DevTools' own class.
    func toggleHidden(_ id: Int) {
        guard nodes[id]?.type == 1 else { return }
        let hide = !elements.hidden.contains(id)
        run(inCurrentDocument: true) { session in
            let hidden = try await session.elementsBridge("return await searchElements.toggleHidden(node, target, hide);", [
                "node": id, "target": session.target, "hide": hide,
            ]) as? Bool ?? hide
            if hidden { session.elements.hidden.insert(id) } else { session.elements.hidden.remove(id) }
            _ = try? await session.command("DOM.markUndoableState", targetID: session.domTargetID)
            await session.refreshAttributes(id)
        }
    }

    /// Store as global variable: temp1, temp2… and echoed in the Console.
    func storeAsGlobal(_ id: Int) {
        run(inCurrentDocument: true) { session in
            let name = try await session.elementsBridge("return await searchElements.storeAsGlobal(node, target);", [
                "node": id, "target": session.target,
            ]) as? String
            if let name { session.evaluate(name) }
        }
    }

    func scrollIntoView(_ id: Int) {
        run(inCurrentDocument: true) { session in
            _ = try await session.elementsBridge("return await searchElements.scrollIntoView(node, target);", [
                "node": id, "target": session.target,
            ])
        }
    }

    func focusNode(_ id: Int) {
        run(inCurrentDocument: true) { session in
            _ = try await session.command("DOM.focus", ["nodeId": id], targetID: session.domTargetID)
        }
    }

    /// The node's own pixels, as Page.snapshotNode renders them.
    func snapshot(_ id: Int) async throws -> Data {
        var reply: [String: Any]
        do {
            reply = try await command("Page.snapshotNode", ["nodeId": id])
        } catch {
            guard let domTargetID else { throw error }
            reply = try await command("Page.snapshotNode", ["nodeId": id, "targetId": domTargetID])
        }
        guard let url = reply["dataURL"] as? String, let comma = url.firstIndex(of: ","),
              let data = Data(base64Encoded: String(url[url.index(after: comma)...])) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return data
    }

    /// Capture node screenshot: saved where a save panel says
    /// (DeveloperScreenshots.swift).
    func captureScreenshot(_ id: Int) {
        let host = DevHost.isPrivate(web) ? nil : address?.host()
        run(inCurrentDocument: true) { session in
            let data = try await session.snapshot(id)
            DeveloperScreenshot.save(data, host: host)
        }
    }

    // MARK: Styles

    /// Chromium's DOMNode.simpleSelector, for a new rule's selector.
    func simpleSelector(_ id: Int) -> String {
        guard let node = nodes[id], node.type == 1 else { return nodes[id]?.name ?? "" }
        func attribute(_ name: String) -> String? {
            stride(from: 0, to: max(0, node.attributes.count - 1), by: 2)
                .first { node.attributes[$0] == name }.map { node.attributes[$0 + 1] }
        }
        let escape = { (text: String) in Self.cssEscape(text) }
        if node.name == "input", let type = attribute("type"), attribute("id") == nil, attribute("class") == nil {
            return "input[type=\"\(escape(type))\"]"
        }
        if let id = attribute("id"), !id.isEmpty { return node.name + "#" + escape(id) }
        if let classes = attribute("class")?.split(whereSeparator: \.isWhitespace), !classes.isEmpty {
            return (node.name == "div" ? "" : node.name) + "." + classes.map { escape(String($0)) }.joined(separator: ".")
        }
        return node.name
    }

    static func cssEscape(_ text: String) -> String {
        var output = ""
        for (index, character) in text.enumerated() {
            if character.isLetter || character == "-" || character == "_" || (character.isNumber && index > 0)
                || character.unicodeScalars.first.map({ $0.value > 0x7F }) == true {
                output.append(character)
            } else if character.isNumber, let scalar = character.unicodeScalars.first {
                output += "\\" + String(scalar.value, radix: 16) + " "
            } else {
                output += "\\" + String(character)
            }
        }
        return output
    }

    /// New Style Rule (+): a rule for the element in the inspector sheet,
    /// its selector opened for editing once it shows (pendingSelector), as
    /// in Chrome DevTools. Returns nothing: the rule's id comes with the
    /// cascade read back.
    func addRule(for id: Int, selector: String? = nil) {
        let selector = selector ?? simpleSelector(id)
        guard !selector.isEmpty else { return }
        run(inCurrentDocument: true) { session in
            let added = try await session.elementsBridge("return await searchElements.addRule(selector, target);", [
                "selector": selector, "target": session.target,
            ]) as? [String: Any]
            if let sheet = added?["styleSheetId"] as? String {
                session.elements.pendingSelector = StyleID(sheet: sheet, ordinal: added?["ordinal"] as? Int ?? 0)
            }
            _ = try? await session.command("DOM.markUndoableState", targetID: session.domTargetID)
            if session.selectedNode == id { session.selectNode(id) }
        }
    }

    func setSelector(_ ruleID: Int, _ selector: String) {
        let selector = selector.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selector.isEmpty, let rule = matchedStyles.first(where: { $0.id == ruleID })?.rule,
              let selected = selectedNode else { return }
        run(inCurrentDocument: true) { session in
            _ = try await session.command("CSS.setRuleSelector", ["ruleId": rule.protocolValue, "selector": selector],
                                          targetID: session.domTargetID)
            _ = try? await session.command("DOM.markUndoableState", targetID: session.domTargetID)
            if session.selectedNode == selected { session.selectNode(selected) }
        }
    }

    /// One declaration set on element.style: the box model's edits.
    func setInlineValue(_ name: String, _ value: String) {
        guard let rule = matchedStyles.first(where: \.inline) else { return }
        editStyle(rule.id, properties: Self.setting(name, value, in: rule.properties))
    }

    /// The box model's arrow keys: element.style written as the value
    /// steps, without reading the cascade back until the edit ends.
    func previewInlineValue(_ name: String, _ value: String) {
        guard let rule = matchedStyles.first(where: \.inline), let style = rule.style else { return }
        writeStyle(style, Self.setting(name, value, in: rule.properties))
    }

    /// Esc in the box model: element.style as it was before the steps.
    func restoreInlineStyle() {
        guard let rule = matchedStyles.first(where: \.inline) else { return }
        editRule(rule.id, properties: rule.properties)
    }

    /// The declarations with one set to a value (emptied, it goes).
    static func setting(_ name: String, _ value: String, in properties: [Detail]) -> [Detail] {
        var properties = properties
        let value = value.trimmingCharacters(in: .whitespaces)
        if let index = properties.lastIndex(where: { $0.name == name }) {
            if value.isEmpty { properties.remove(at: index) } else {
                properties[index].value = value
                properties[index].enabled = true
            }
        } else if !value.isEmpty {
            properties.append(Detail(name: name, value: value))
        }
        return properties
    }

    // MARK: Style edits (each a step ⌘Z can take back)

    /// A rule's declarations written and read back as one undoable step
    /// (editRule marks it), noted for Copy all CSS changes.
    func editStyle(_ ruleID: Int, properties: [Detail], original: [Detail]? = nil) {
        if let rule = matchedStyles.first(where: { $0.id == ruleID }) {
            elements.recordChange(rule, from: original ?? rule.properties, to: properties)
        }
        editRule(ruleID, properties: properties)
    }

    /// A rule's declarations written while its editor stays open (an arrow
    /// key's step, a Tab to the next field), without reading the cascade
    /// back: that would rebuild the pane under the editor.
    func writeStyle(_ style: StyleID, _ properties: [Detail]) {
        let text = properties.map(\.text).joined(separator: " ")
        run(inCurrentDocument: true) { session in
            try await session.setStyleText(style, text)
        }
    }

    /// Ends the history step: what was done since the last mark goes back
    /// with one ⌘Z.
    func markUndoableState() {
        run(inCurrentDocument: true) { session in
            _ = try? await session.command("DOM.markUndoableState", targetID: session.domTargetID)
        }
    }

    /// The open editor's text folded into its declarations, written if they
    /// changed (a selector is set instead). Returns how many declarations
    /// now stand where the edited one did (DeveloperStyleEditing.fold).
    @discardableResult
    func foldStyleEdit(_ edit: inout DeveloperElementsState.StyleEdit) -> Int {
        if edit.field == .selector {
            let selector = edit.selector.trimmingCharacters(in: .whitespacesAndNewlines)
            if let rule = matchedStyles.first(where: { $0.style == edit.style }), !selector.isEmpty, selector != rule.selector {
                setSelector(rule.id, selector)
            }
            return 1
        }
        let (properties, change) = DeveloperStyleEditing.fold(edit.working, field: edit.field, name: edit.name, value: edit.value)
        if properties != edit.working {
            edit.working = properties
            edit.written = true
            writeStyle(edit.style, properties)
        }
        return change
    }

    /// The editor closed: what it changed written, read back and marked as
    /// one undoable step.
    func commitStyleEdit(_ edit: DeveloperElementsState.StyleEdit) {
        if elements.styleEdit?.style == edit.style { elements.styleEdit = nil }
        guard edit.working != edit.original || edit.written else { return }
        if let rule = matchedStyles.first(where: { $0.style == edit.style }) {
            editStyle(rule.id, properties: edit.working, original: edit.original)
            return
        }
        // The cascade is being read again; write and read it once more.
        writeStyle(edit.style, edit.working)
        markUndoableState()
        if let selected = selectedNode {
            run(inCurrentDocument: true) { session in
                if session.selectedNode == selected { session.selectNode(selected) }
            }
        }
    }

    /// Return, a click elsewhere, or Esc (`cancel`), which puts back the
    /// declaration being edited as it was when its editing began.
    func finishStyleEdit(cancel: Bool = false) {
        guard var edit = elements.styleEdit else { return }
        if cancel { edit.working = edit.checkpoint } else { foldStyleEdit(&edit) }
        commitStyleEdit(edit)
    }

    // MARK: Highlights, links and reveals

    /// Hovering the box model: only that layer of the selected element
    /// highlighted ("margin", "border", "padding" or "content"), through
    /// highlightNode(_:config:); nil hides it. A hovered selector calls
    /// highlightSelector(_:config:) directly.
    func highlightBox(_ layer: String?) {
        let layers: [String: DeveloperHighlight.Layer] = [
            "content": .content, "padding": .padding, "border": .border, "margin": .margin,
        ]
        guard let node = selectedNode, let layer, let box = layers[layer] else {
            hideHighlight()
            return
        }
        highlightNode(node, config: .only(box))
    }

    /// The rule that sets a property for the selected element: the one
    /// whose declaration wins, else the first that declares it.
    static func declaringRule(_ name: String, in rules: [StyleRule]) -> Int? {
        let rules = rules.filter { !$0.atRule }
        return rules.first { $0.properties.contains { $0.name == name && $0.enabled && !$0.overridden } }?.id
            ?? rules.first { $0.properties.contains { $0.name == name } }?.id
    }

    /// Styles brought forward, scrolled to a declaration and flashing it:
    /// a var() link, Computed's → buttons.
    func revealDeclaration(_ name: String, in ruleID: Int? = nil) {
        guard let rule = ruleID ?? Self.declaringRule(name, in: matchedStyles) else { return }
        elements.requestedSidebar = "Styles"
        elements.flashDeclaration(rule: rule, name: name)
    }

    /// View computed value: Computed brought forward, filtered to the property.
    func showComputed(_ name: String) {
        elements.computedFilter = name
        elements.requestedSidebar = "Computed"
    }

    /// An event listener's handler location opened in Sources at its line,
    /// in the authored file when the script has a source map.
    func revealListener(_ listener: EventListener) {
        guard !listener.url.isEmpty else { return }
        let link = listenerLink(listener)
        revealSource(url: link.url, line: link.line ?? 1)
    }

    /// A listener's handler place as its link reads, 1-based: in the
    /// authored file when the script has a source map, as in Chrome.
    func listenerLink(_ listener: EventListener) -> (url: String, line: Int?) {
        sourceMaps.linked(url: listener.url, line: listener.line.map { $0 + 1 }, column: listener.column.map { $0 + 1 })
    }

    /// The .cls pane: a class switched on or off, or added.
    func setClass(_ name: String, on: Bool, for id: Int) {
        guard let node = nodes[id] else { return }
        let current = stride(from: 0, to: max(0, node.attributes.count - 1), by: 2)
            .first { node.attributes[$0] == "class" }.map { node.attributes[$0 + 1] } ?? ""
        var classes = current.split(whereSeparator: \.isWhitespace).map(String.init)
        var off = elements.offClasses[id, default: []]
        if on {
            off.removeAll { $0 == name }
            if !classes.contains(name) { classes.append(name) }
        } else {
            classes.removeAll { $0 == name }
            if !off.contains(name) { off.append(name) }
        }
        elements.offClasses[id] = off.isEmpty ? nil : off
        edit { session, _ in
            _ = try await session.command("DOM.setAttributeValue", [
                "nodeId": id, "name": "class", "value": classes.joined(separator: " "),
            ], targetID: session.domTargetID)
            await session.refreshAttributes(id)
        }
    }

    func loadCatalog() {
        guard elements.catalog.isEmpty, ready else { return }
        Task { [weak self] in
            guard let self else { return }
            if let raw = try? await self.elementsBridge("return await searchElements.cssCatalog();") as? [[String: Any]] {
                self.elements.setCatalog(raw)
            }
        }
    }

    func loadFonts(_ id: Int) {
        run(inCurrentDocument: true) { session in
            let raw = (try? await session.elementsBridge("return await searchElements.fonts(node, target);", [
                "node": id, "target": session.target,
            ])) as? [[String: Any]] ?? []
            guard session.selectedNode == id else { return }
            session.elements.fontsNode = id
            session.elements.fonts = raw.compactMap {
                guard let name = $0["name"] as? String else { return nil }
                return DeveloperElementsState.RenderedFont(name: name, url: $0["url"] as? String,
                                                           glyphs: $0["glyphs"] as? Int ?? 0,
                                                           synthesized: $0["synthesized"] as? Bool == true)
            }
        }
    }

    // MARK: Layout

    func loadLayout() {
        run(inCurrentDocument: true) { session in
            let raw = try await session.elementsBridge("return await searchElements.layoutNodes(target);", [
                "target": session.target,
            ]) as? [[String: Any]] ?? []
            let old = Dictionary(session.elements.containers.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            session.elements.containers = raw.compactMap {
                guard let id = $0["nodeId"] as? Int, let kind = $0["kind"] as? String else { return nil }
                return DeveloperElementsState.LayoutContainer(id: id, kind: kind, label: $0["label"] as? String ?? "",
                                                              showing: old[id]?.showing ?? false,
                                                              color: old[id]?.color ?? (kind == "grid" ? "#9c27b0" : "#7b1fa2"))
            }
            for container in session.elements.containers { session.elements.layout[container.id] = container.kind }
        }
    }

    func setOverlay(_ id: Int, on: Bool, color: String? = nil) {
        let kind = elements.containers.first { $0.id == id }?.kind ?? elements.layout[id] ?? "grid"
        if let index = elements.containers.firstIndex(where: { $0.id == id }) {
            elements.containers[index].showing = on
            if let color { elements.containers[index].color = color }
        } else {
            elements.containers.append(.init(id: id, kind: kind, label: nodes[id].map(Self.label) ?? "",
                                             showing: on, color: color ?? (kind == "grid" ? "#9c27b0" : "#7b1fa2")))
        }
        let shown = elements.containers.first { $0.id == id }?.color
        let options = elements.gridOptions.protocolValue
        run(inCurrentDocument: true) { session in
            _ = try await session.elementsBridge("return await searchElements.setOverlay(node, target, on, kind, color, options);", [
                "node": id, "target": session.target, "on": on, "kind": kind,
                "color": shown as Any? ?? NSNull(), "options": options,
            ])
        }
    }

    /// The tree's container and scroll-snap badges: their overlays were
    /// drawn in the page, which the package doesn't do, so they only say so.
    func setPageOverlay(_ id: Int, kind: String, on: Bool) {}

    /// An anchor-positioned element's anchor badge: its anchor (the
    /// element whose anchor-name its position-anchor names) is selected,
    /// as Chrome's badge reveals it.
    func revealAnchor(of id: Int) {
        let target = self.target
        let revision = domRevision
        Task { [weak self] in
            guard let self, self.ready else { return }
            let found = try? await self.elementsBridge("return await searchElements.anchorOf(node, target);", [
                "node": id, "target": target,
            ])
            guard self.domRevision == revision, let node = (found as? NSNumber)?.intValue, node > 0 else { return }
            for _ in 0..<40 where self.nodes[node] == nil {
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard self.nodes[node] != nil else { return }
            self.selectNode(node)
        }
    }

    /// Overlay display settings changed: the grids shown are drawn again.
    func refreshGridOverlays() {
        for container in elements.containers where container.kind == "grid" && container.showing {
            setOverlay(container.id, on: true)
        }
    }

    // MARK: Break on

    /// Kept by the debugger, whose Sources sidebar lists the same DOM
    /// breakpoints; the Elements panel mirrors them (mirrorDOMBreakpoints).
    func toggleBreakpoint(_ type: DeveloperElementsState.DOMBreakpoint, on id: Int) {
        guard let kind = DeveloperDebugger.DOMBreakpoint.Kind(rawValue: type.rawValue) else { return }
        debugger.toggleDOMBreakpoint(node: id, type: kind)
    }

    /// The debugger's DOM breakpoints, as Elements' Break on menu reads
    /// them: node id → the types set, switched off ones included, as
    /// Chrome's hasDOMBreakpoint counts them. The DOM Breakpoints tab lists
    /// the debugger's own list, with each one's checkbox.
    func mirrorDOMBreakpoints() {
        var map: [Int: Set<DeveloperElementsState.DOMBreakpoint>] = [:]
        for item in debugger.domBreakpoints {
            if let type = DeveloperElementsState.DOMBreakpoint(rawValue: item.type.rawValue) {
                map[item.node, default: []].insert(type)
            }
        }
        elements.breakpoints = map
    }

    // MARK: Properties and Accessibility

    struct PropertyItem: Identifiable, Equatable {
        let name: String
        let value: String
        let type: String
        let objectID: String?
        let own: Bool
        var id: String { name }
    }

    /// The node object's properties, or an object's inside it when expanded.
    func properties(of id: Int, object: String? = nil) async -> [PropertyItem] {
        guard ready else { return [] }
        let raw = (try? await elementsBridge("return await searchElements.properties(node, object, target);", [
            "node": id, "object": object as Any? ?? NSNull(), "target": target,
        ])) as? [[String: Any]] ?? []
        return raw.compactMap {
            guard let name = $0["name"] as? String else { return nil }
            return PropertyItem(name: name, value: $0["value"] as? String ?? "", type: $0["type"] as? String ?? "",
                                objectID: $0["objectId"] as? String, own: $0["own"] as? Bool ?? true)
        }
    }

    struct AccessibilityDetails {
        struct NodeLink: Identifiable {
            let id: Int
            let role: String
            let label: String

            init?(_ raw: [String: Any]) {
                guard let id = raw["id"] as? Int else { return nil }
                self.id = id
                role = raw["role"] as? String ?? ""
                label = raw["label"] as? String ?? ""
            }

            var title: String {
                let name = role.isEmpty ? "Node \(id)" : role
                return label.isEmpty ? name : "\(name) \(label)"
            }
        }

        struct Relation: Identifiable {
            let title: String
            let nodes: [NodeLink]
            var id: String { title }
        }

        let properties: [String: Any]
        let ancestors: [NodeLink]
        let selected: NodeLink?
        let children: [NodeLink]
        let relations: [Relation]

        init(_ raw: [String: Any] = [:]) {
            func links(_ key: String) -> [NodeLink] {
                (raw[key] as? [[String: Any]] ?? []).compactMap(NodeLink.init)
            }
            properties = raw["properties"] as? [String: Any] ?? [:]
            ancestors = links("ancestors")
            selected = (raw["selected"] as? [String: Any]).flatMap(NodeLink.init)
            children = links("children")
            relations = [("labelledBy", "Labelled by"), ("controls", "Controls"), ("owns", "Owns"),
                         ("activeDescendant", "Active descendant")].compactMap { key, title in
                let nodes = links(key)
                return nodes.isEmpty ? nil : Relation(title: title, nodes: nodes)
            }
        }
    }

    func accessibility(of id: Int) async -> AccessibilityDetails {
        guard ready else { return AccessibilityDetails() }
        let raw = (try? await elementsBridge("return await searchElements.accessibility(node, target);", [
            "node": id, "target": target,
        ])) as? [String: Any] ?? [:]
        return AccessibilityDetails(raw)
    }

    func styleContrast(of id: Int) async -> DeveloperStyleContrast? {
        guard ready,
              let raw = (try? await elementsBridge("return await searchElements.contrast(node, target);", [
                "node": id, "target": target,
              ])) as? [String: Any],
              let backgrounds = raw["backgrounds"] as? [[String: Any]], !backgrounds.isEmpty else { return nil }
        let layers = backgrounds.enumerated().map { index, layer in
            DeveloperCSSOverview.Element(index: index, parent: index + 1 < backgrounds.count ? index + 1 : nil,
                                         label: "", backgroundImage: layer["image"] as? Bool ?? false,
                                         values: ["backgroundColor": layer["color"] as? String ?? ""])
        }
        guard let background = DeveloperCSSOverview.effectiveBackground(of: 0, in: layers) else { return nil }
        let largeText = DeveloperCSSOverview.isLargeText(fontSize: raw["fontSize"] as? String ?? "",
                                                          fontWeight: raw["fontWeight"] as? String ?? "")
        return DeveloperStyleContrast(background: background, largeText: largeText)
    }

    // MARK: Cut, copy, paste

    func cut(_ id: Int) {
        elements.clipboard = (id, true)
        copy(.element, of: id)
    }

    func copyNode(_ id: Int) {
        elements.clipboard = (id, false)
        copy(.element, of: id)
    }

    /// Paste: the node cut or copied, as the last child of this one.
    func paste(into id: Int) {
        guard let clip = elements.clipboard, clip.node != id else { return }
        if clip.cut {
            elements.clipboard = nil
            move(clip.node, into: id, before: nil)
            return
        }
        edit { session, _ in
            let html = try await session.outerHTML(of: clip.node)
            _ = try await session.command("DOM.insertAdjacentHTML", ["nodeId": id, "position": "beforeend", "html": html],
                                          targetID: session.domTargetID)
            session.expanded.insert(id)
            await session.reloadChildren(of: id)
        }
    }

    // MARK: Source links

    /// A rule's file:line link opens the sheet in Sources, scrolled to the
    /// rule's line and highlighting it, as in Chrome DevTools. `line` is
    /// the rule's 0-based sourceLine.
    /// A rule's place in its authored file (_button.scss:40), 1-based, when
    /// its sheet's CSS source map is loaded, as Chrome's rule links read;
    /// nil for a rule no map has.
    func authoredLocation(of rule: StyleRule) -> (url: String, line: Int)? {
        guard !rule.inline, let url = rule.sourceURL, !url.isEmpty, let line = rule.sourceLine,
              let original = sourceMaps.original(url: url, line: line, column: rule.sourceColumn ?? 0) else { return nil }
        return (original.url, original.line + 1)
    }

    /// A rule's link, as in Chrome: its authored file in Sources when a
    /// CSS source map has it, else its style sheet at the rule's line.
    func openRule(_ rule: StyleRule) {
        if let authored = authoredLocation(of: rule) {
            revealSource(url: authored.url, line: authored.line)
        } else if let url = rule.sourceURL {
            openStylesheet(url, line: rule.sourceLine)
        }
    }

    func openStylesheet(_ url: String, line: Int? = nil) {
        if let line {
            revealSource(url: url, line: line + 1)
            return
        }
        run { session in
            let tree = try await session.command("Page.getResourceTree")
            guard let frame = Self.frame(holding: url, in: tree["frameTree"] as? [String: Any]) else { return }
            session.select(.sources)
            session.openSource(Resource(frame: frame, url: url, type: "Stylesheet"))
        }
    }

    private static func frame(holding url: String, in tree: [String: Any]?) -> String? {
        guard let tree, let frame = tree["frame"] as? [String: Any], let id = frame["id"] as? String else { return nil }
        if frame["url"] as? String == url { return id }
        if (tree["resources"] as? [[String: Any]] ?? []).contains(where: { $0["url"] as? String == url }) { return id }
        for child in tree["childFrames"] as? [[String: Any]] ?? [] {
            if let found = self.frame(holding: url, in: child) { return found }
        }
        return nil
    }
}

extension DeveloperToolsSession.StyleRule {
    init?(raw: [String: Any], id: Int) {
        guard let selector = raw["selector"] as? String,
              let properties = raw["properties"] as? [[String: Any]] else { return nil }
        func styleID(_ value: Any?) -> DeveloperToolsSession.StyleID? {
            guard let value = value as? [String: Any], let sheet = value["styleSheetId"] as? String else { return nil }
            return DeveloperToolsSession.StyleID(sheet: sheet, ordinal: value["ordinal"] as? Int ?? 0)
        }
        func declaration(_ item: [String: Any]) -> DeveloperToolsSession.Detail? {
            guard let name = item["name"] as? String, let value = item["value"] as? String else { return nil }
            var detail = DeveloperToolsSession.Detail(name: name, value: value, enabled: item["enabled"] as? Bool ?? true,
                                                      important: item["important"] as? Bool == true,
                                                      parsed: item["parsed"] as? Bool ?? true)
            detail.overridden = item["inactive"] as? Bool == true
            detail.inheritable = item["inheritable"] as? Bool ?? true
            detail.longhands = (item["longhands"] as? [[String: Any]] ?? []).compactMap(declaration)
            return detail
        }
        self.init(id: id, selector: selector, origin: raw["origin"] as? String ?? "",
                  properties: properties.compactMap(declaration), style: styleID(raw["styleId"]))
        rule = styleID(raw["ruleId"])
        section = raw["section"] as? String
        sectionNode = raw["sectionNode"] as? Int
        inherited = raw["inherited"] as? Bool == true
        pseudo = raw["pseudo"] as? String
        groupings = raw["groupings"] as? [String] ?? []
        sourceURL = raw["sourceURL"] as? String
        sourceLine = raw["sourceLine"] as? Int
        sourceColumn = raw["sourceColumn"] as? Int
    }

    /// Where the rule comes from, as DevTools labels it.
    func location(document: URL?) -> String {
        switch origin {
        case "user-agent": return "user agent stylesheet"
        case "user": return "user stylesheet"
        case "inline": return ""
        default: break
        }
        let line = sourceLine.map { ":\($0 + 1)" } ?? ""
        if origin == "inspector" { return "inspector-stylesheet" + line }
        guard let sourceURL, !sourceURL.isEmpty else { return "" }
        if let document, sourceURL == document.absoluteString { return "(index)" + line }
        let name = URL(string: sourceURL).map { $0.lastPathComponent.isEmpty ? ($0.host() ?? sourceURL) : $0.lastPathComponent }
        return (name ?? sourceURL) + line
    }

    var selectorEditable: Bool { rule != nil && origin != "user-agent" && origin != "user" }

    /// A rule of the sections Chrome shows below the cascade (@keyframes,
    /// @property, @font-face, @position-try): read-only, and no part of
    /// the cascade.
    var atRule: Bool { section?.hasPrefix("@") == true }

    /// Strikes through every declaration a later or more specific one
    /// beats: within a rule the last wins, across rules the first listed
    /// (the most specific) wins unless a later one is !important, and an
    /// inherited value loses to the element's own and to closer ancestors.
    static func cascade(_ rules: [Self]) -> [Self] {
        var rules = rules
        struct Winner { let rule: Int; let property: Int; let important: Bool; let level: Int }
        var winners: [String: [String: Winner]] = [:]
        var levels: [Int?] = []
        for r in rules.indices {
            let rule = rules[r]
            if rule.atRule { continue }
            let group = rule.pseudo ?? ""
            var level = 0
            if rule.inherited {
                if levels.last != rule.sectionNode || levels.isEmpty { levels.append(rule.sectionNode) }
                level = levels.count
            }
            for p in rule.properties.indices.reversed() {
                let property = rule.properties[p]
                guard property.enabled, property.parsed, !rule.inherited || property.inheritable else { continue }
                let keys = property.longhands.isEmpty ? [property.name] : property.longhands.map(\.name)
                var wins = false
                for key in keys {
                    if let winner = winners[group]?[key] {
                        if winner.level == level, property.important, !winner.important {
                            rules[winner.rule].properties[winner.property].overridden = true
                            winners[group]?[key] = Winner(rule: r, property: p, important: true, level: level)
                            wins = true
                        }
                    } else {
                        winners[group, default: [:]][key] = Winner(rule: r, property: p, important: property.important, level: level)
                        wins = true
                    }
                }
                if !wins { rules[r].properties[p].overridden = true }
            }
        }
        return rules
    }
}

extension DeveloperToolsSession.PseudoState {
    /// Force state ▸ in Chromium's DOM tree context menu, in its order.
    static let chromium: [Self] = [.active, .hover, .focus, .visited, .focusWithin, .focusVisible]
    /// The :hov pane's always-shown states (ElementStatePaneWidget).
    static let persistent: [Self] = [.active, .hover, .focus, .focusWithin, .focusVisible, .target]

    /// The pane's element-specific states that WebKit can force: :visited,
    /// shown for links as Chromium does. WebKit's CSS.forcePseudoState
    /// takes none of the form states (:enabled, :valid, …).
    static func specific(for node: DeveloperToolsSession.DOMNode?) -> [Self] {
        guard let node, ["a", "area", "link"].contains(node.name),
              stride(from: 0, to: max(0, node.attributes.count - 1), by: 2).contains(where: { node.attributes[$0] == "href" })
        else { return [] }
        return [.visited]
    }
}
