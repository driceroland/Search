import Combine
import SwiftUI

/// Elements › Styles: the filter, :hov, .cls and + (New Style Rule), then
/// the cascade in DevTools' order with its section headers.
struct DeveloperStylesPane: View {
    @ObservedObject var session: DeveloperToolsSession
    @ObservedObject var elements: DeveloperElementsState
    let node: Int
    @State private var filter = ""
    @State private var pane: Pane?
    @State private var newClass = ""
    /// With the node it was measured on: kept while a new measure runs.
    @State private var contrast: (node: Int, value: DeveloperStyleContrast?)?
    /// Bumped when Rendering's emulation changes, which restyles the page
    /// without a new style read.
    @State private var emulation = 0

    private enum Pane { case states, classes }

    /// The selection's style reads (rerun after edits, :hov and attribute
    /// changes) empty and refill session.styles, so a refill measures again.
    private var contrastInputs: [String] {
        let relevant = ["background-color", "background-image", "font-size", "font-weight"]
        return [String(node), String(session.domRevision), String(emulation), String(session.styles.isEmpty)]
            + session.styles
            .filter { relevant.contains($0.name) }.map { $0.name + "=" + $0.value }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DeveloperToolsStyle.controlSpacing) {
                TextField("Filter", text: $filter).developerToolsField()
                toggle(":hov", .states, help: "Toggle element state", active: !(session.forcedStates[node]?.isEmpty ?? true))
                toggle(".cls", .classes, help: "Element classes", active: false)
                DeveloperRenderingShortcuts(session: session)
                DeveloperPanelIcon(symbol: "plus", title: "New Style Rule") { session.addRule(for: node) }
            }
            .padding(.horizontal, DeveloperToolsStyle.gutter).frame(height: DeveloperToolsStyle.toolbarHeight)
            .background(DeveloperToolsStyle.chrome)
            if pane == .states { statesPane }
            if pane == .classes { classesPane }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(shownRules(), id: \.rule.id) { item in
                            if item.opensSection, let section = item.rule.section { header(section, rule: item.rule) }
                            DeveloperStyleRuleView(session: session, elements: elements, rule: item.rule,
                                                   shown: item.shown, contrast: contrast.flatMap { $0.node == node ? $0.value : nil })
                            Divider().padding(.vertical, 5)
                        }
                    }
                    .padding(8)
                    // A click on the pane's blank space closes the open
                    // editor, keeping what was typed, as in DevTools.
                    .contentShape(Rectangle())
                    .onTapGesture { if elements.styleEdit != nil { session.finishStyleEdit() } }
                }
                .font(DeveloperToolsStyle.code)
                .onAppear { reveal(proxy) }
                .onChange(of: elements.flash) { _, _ in reveal(proxy) }
                .onChange(of: elements.pendingName) { _, pending in
                    guard let pending else { return }
                    // A filter may hide the rule: the move stops, as at the pane's end.
                    guard filter.isEmpty else { elements.pendingName = nil; return }
                    proxy.scrollTo(pending.rule)
                }
            }
        }
        .task(id: contrastInputs) {
            // The old ratio stays until the new one arrives, rather than
            // flickering out while the styles reload.
            guard !session.styles.isEmpty else { return }
            let node = node
            let result = await session.styleContrast(of: node)
            guard !Task.isCancelled else { return }
            contrast = (node, result)
        }
        .onReceive(session.rendering.$options.dropFirst().debounce(for: .milliseconds(250), scheduler: RunLoop.main)) { _ in
            emulation += 1
        }
    }

    /// A var() link or Computed's → button: the rule holding the
    /// declaration scrolled into view (it flashes in DeveloperStyleRuleView).
    private func reveal(_ proxy: ScrollViewProxy) {
        guard let flash = elements.flash else { return }
        if !filter.isEmpty { filter = "" }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(flash.rule, anchor: .center) }
        }
    }

    struct ShownRule {
        let rule: DeveloperToolsSession.StyleRule
        /// The declarations the filter leaves, by index.
        let shown: [Int]
        /// The first rule shown of its section ("Inherited from …"), under its header.
        let opensSection: Bool
    }

    /// The rules shown and which open their section, in one pass (it was a
    /// scan back over the earlier rules for each one, every redraw).
    private func shownRules() -> [ShownRule] {
        var result: [ShownRule] = []
        var section: String??
        var sectionShown = false
        for rule in session.matchedStyles {
            if section != .some(rule.section) {
                section = .some(rule.section)
                sectionShown = false
            }
            let shown = rule.properties.indices.filter {
                let property = rule.properties[$0]
                return (!rule.inherited || property.inheritable) && matches(property.name + " " + property.value)
            }
            guard !shown.isEmpty || (filter.isEmpty && !rule.inherited && (rule.inline || rule.editable)) else { continue }
            result.append(ShownRule(rule: rule, shown: shown, opensSection: rule.section != nil && !sectionShown))
            sectionShown = true
        }
        return result
    }

    @ViewBuilder
    private func header(_ section: String, rule: DeveloperToolsSession.StyleRule) -> some View {
        let prefix = "Inherited from "
        HStack(spacing: 0) {
            if section.hasPrefix(prefix), let target = rule.sectionNode {
                Text(prefix).foregroundStyle(.secondary)
                Button(String(section.dropFirst(prefix.count))) { session.selectNode(target) }
                    .buttonStyle(.plain).foregroundStyle(DeveloperToolsStyle.tint)
                    .onHover { session.highlightNode($0 ? target : nil) }
            } else {
                Text(section).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 11))
        .padding(.bottom, 4)
    }

    private func toggle(_ title: String, _ value: Pane, help: String, active: Bool) -> some View {
        Button { pane = pane == value ? nil : value } label: {
            Text(title).font(DeveloperToolsStyle.code)
                .foregroundStyle(pane == value || active ? DeveloperToolsStyle.tint : .secondary)
                .padding(.horizontal, 4).frame(height: DeveloperToolsStyle.controlHeight)
                .background(pane == value ? DeveloperToolsStyle.selected : .clear,
                            in: RoundedRectangle(cornerRadius: DeveloperToolsStyle.controlRadius))
        }
        .buttonStyle(.plain).help(help).accessibilityLabel(help)
    }

    /// Chromium's ElementStatePaneWidget: the page-focus checkbox, the
    /// persistent states, then the element-specific ones that apply.
    private var statesPane: some View {
        let columns = [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)]
        let specific = DeveloperToolsSession.PseudoState.specific(for: session.nodes[node])
        return VStack(alignment: .leading, spacing: 4) {
            // WebKit's protocol has no page-focus emulation; Rendering's
            // page script approximates it.
            DeveloperFocusedPageToggle(session: session)
                .foregroundStyle(Palette.ink)
            Text("Force element state").foregroundStyle(.secondary)
            LazyVGrid(columns: columns, spacing: 3) {
                ForEach(DeveloperToolsSession.PseudoState.persistent) { state in stateToggle(state) }
            }
            if !specific.isEmpty {
                DisclosureGroup("Force specific element state") {
                    LazyVGrid(columns: columns, spacing: 3) {
                        ForEach(specific) { state in stateToggle(state) }
                    }
                }
                .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 11))
        .padding(DeveloperToolsStyle.gutter)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DeveloperToolsStyle.chrome)
    }

    private func stateToggle(_ state: DeveloperToolsSession.PseudoState) -> some View {
        Toggle(":" + state.rawValue, isOn: Binding(
            get: { session.forcedStates[node, default: []].contains(state) },
            set: { session.force(state, on: $0, for: node) }
        ))
        .toggleStyle(.developerCheckbox)
        .foregroundStyle(Palette.ink)
    }

    private var classesPane: some View {
        let current = classes
        let off = elements.offClasses[node, default: []]
        return VStack(alignment: .leading, spacing: 4) {
            TextField("Add new class", text: $newClass)
                .developerToolsField()
                .onSubmit {
                    for name in newClass.split(whereSeparator: \.isWhitespace) { session.setClass(String(name), on: true, for: node) }
                    newClass = ""
                }
            FlowingChecks(names: current + off.filter { !current.contains($0) }) { name in
                Toggle(name, isOn: Binding(get: { current.contains(name) }, set: { session.setClass(name, on: $0, for: node) }))
                    .toggleStyle(.developerCheckbox)
            }
        }
        .font(.system(size: 11))
        .padding(DeveloperToolsStyle.gutter)
        .background(DeveloperToolsStyle.chrome)
    }

    private var classes: [String] {
        guard let item = session.nodes[node] else { return [] }
        let value = stride(from: 0, to: max(0, item.attributes.count - 1), by: 2)
            .first { item.attributes[$0] == "class" }.map { item.attributes[$0 + 1] } ?? ""
        return value.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private func matches(_ text: String) -> Bool {
        filter.isEmpty || text.localizedCaseInsensitiveContains(filter)
    }
}

/// Checkboxes laid out in rows of three, as the .cls pane lists classes.
private struct FlowingChecks<Content: View>: View {
    let names: [String]
    @ViewBuilder let content: (String) -> Content

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3), spacing: 3) {
            ForEach(names, id: \.self) { content($0) }
        }
    }
}

/// Elements › Computed: the box model, then computed values (set ones, or
/// all with Show all), each expandable to the declarations behind it.
struct DeveloperComputedPane: View {
    @ObservedObject var session: DeveloperToolsSession
    @ObservedObject var elements: DeveloperElementsState
    let node: Int
    @AppStorage("developerTools.computedShowAll") private var showAll = false
    @AppStorage("developerTools.computedGroup") private var group = false
    @State private var closedGroups = Set<String>()
    @State private var filter = ""
    /// View computed value's filter: that property alone, until the
    /// filter is typed into.
    @State private var exact: String?
    @State private var open = Set<String>()
    @State private var hovered: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DeveloperToolsStyle.controlSpacing) {
                TextField("Filter", text: $filter).developerToolsField()
                Toggle("Show all", isOn: $showAll).toggleStyle(.developerCheckbox).controlSize(.small).fixedSize()
                Toggle("Group", isOn: $group).toggleStyle(.developerCheckbox).controlSize(.small).fixedSize()
            }
            .padding(.horizontal, DeveloperToolsStyle.gutter).frame(height: DeveloperToolsStyle.toolbarHeight)
            .background(DeveloperToolsStyle.chrome)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    DeveloperBoxModel(session: session).padding(8)
                    Divider()
                    let list = properties
                    if list.isEmpty {
                        Text("No matching property").foregroundStyle(.secondary).padding(8)
                    }
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if group {
                            ForEach(DeveloperComputedCategory.order, id: \.self) { category in
                                let members = list.filter { DeveloperComputedCategory.categories(of: $0.name).contains(category) }
                                if !members.isEmpty {
                                    let closed = closedGroups.contains(category)
                                    HStack(spacing: 4) {
                                        Image(systemName: closed ? "arrowtriangle.right.fill" : "arrowtriangle.down.fill")
                                            .font(.system(size: 7)).foregroundStyle(.secondary)
                                        Text(category).fontWeight(.semibold)
                                        Spacer(minLength: 0)
                                    }
                                    .frame(height: 20).contentShape(Rectangle())
                                    .onTapGesture { if closed { closedGroups.remove(category) } else { closedGroups.insert(category) } }
                                    if !closed { ForEach(members) { property in row(property).padding(.leading, 10) } }
                                }
                            }
                        } else {
                            ForEach(list) { property in row(property) }
                        }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    fonts
                }
            }
            .font(DeveloperToolsStyle.code)
        }
        .task(id: node) { session.loadFonts(node) }
        .onAppear(perform: takeFilter)
        .onChange(of: elements.computedFilter) { _, _ in takeFilter() }
        .onChange(of: filter) { _, now in if now != exact { exact = nil } }
    }

    /// View computed value in Styles: the property alone, its trace open.
    private func takeFilter() {
        guard let name = elements.computedFilter else { return }
        DispatchQueue.main.async {
            elements.computedFilter = nil
            exact = name
            filter = name
            open.insert(name)
        }
    }

    /// The → button Chrome shows on a hovered row: Styles, scrolled to the
    /// declaration and flashing it.
    private func navigate(_ rule: DeveloperToolsSession.StyleRule, _ declaration: DeveloperToolsSession.Detail) -> some View {
        Button { session.revealDeclaration(declaration.name, in: rule.id) } label: {
            Image(systemName: "arrow.right.circle").font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Navigate to style")
        .accessibilityLabel("Navigate to style")
    }

    private var traces: [String: [(DeveloperToolsSession.StyleRule, DeveloperToolsSession.Detail)]] {
        var map: [String: [(DeveloperToolsSession.StyleRule, DeveloperToolsSession.Detail)]] = [:]
        for rule in session.matchedStyles where rule.pseudo == nil && !rule.atRule {
            for property in rule.properties where property.enabled && (!rule.inherited || property.inheritable) {
                let names = property.longhands.isEmpty ? [property.name] : [property.name] + property.longhands.map(\.name)
                for name in names { map[name, default: []].append((rule, property)) }
            }
        }
        return map
    }

    private var properties: [DeveloperToolsSession.Detail] {
        let set = traces
        return session.styles
            .filter { showAll || set[$0.name] != nil }
            .filter { property in
                if let exact, exact == filter { return property.name == exact }
                return filter.isEmpty || (property.name + " " + property.value).localizedCaseInsensitiveContains(filter)
            }
            .sorted { a, b in
                let ap = a.name.hasPrefix("-"), bp = b.name.hasPrefix("-")
                return ap == bp ? a.name < b.name : !ap
            }
    }

    @ViewBuilder
    private func row(_ property: DeveloperToolsSession.Detail) -> some View {
        let trace = traces[property.name] ?? []
        let expanded = open.contains(property.name)
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: expanded ? "arrowtriangle.down.fill" : "arrowtriangle.right.fill")
                .font(.system(size: 7)).foregroundStyle(.secondary).opacity(trace.isEmpty ? 0 : 1)
            Text(property.name).foregroundStyle(trace.isEmpty ? .secondary : DeveloperToolsStyle.tint)
            Text(property.value).textSelection(.enabled)
            DeveloperColorSwatch(value: property.value)
            Spacer(minLength: 0)
            if hovered == property.name, let winner = trace.first(where: { !$0.1.overridden }) ?? trace.first {
                navigate(winner.0, winner.1)
            }
        }
        .frame(minHeight: 18)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { hovered = property.name } else if hovered == property.name { hovered = nil }
        }
        .onTapGesture {
            guard !trace.isEmpty else { return }
            if expanded { open.remove(property.name) } else { open.insert(property.name) }
        }
        if expanded {
            ForEach(Array(trace.enumerated()), id: \.offset) { _, item in
                let (rule, declaration) = item
                let value = declaration.name == property.name ? declaration.value
                    : declaration.longhands.first { $0.name == property.name }?.value ?? declaration.value
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    navigate(rule, declaration)
                    Text(value).strikethrough(declaration.overridden).foregroundStyle(declaration.overridden ? .secondary : Palette.ink)
                    Text(rule.selector).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 0)
                    // In the authored file when a CSS source map has the rule, as in Chrome.
                    let location = session.authoredLocation(of: rule).map { ConsoleFormat.location($0.url, line: $0.line) }
                        ?? rule.location(document: session.address)
                    if rule.sourceURL != nil, !location.isEmpty, rule.origin != "user-agent" {
                        Button(location) { session.openRule(rule) }.buttonStyle(.plain)
                            .foregroundStyle(DeveloperToolsStyle.tint).underline().lineLimit(1)
                    } else {
                        Text(location).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .padding(.leading, 22)
                .frame(minHeight: 17)
            }
        }
    }

    @ViewBuilder
    private var fonts: some View {
        if elements.fontsNode == node, !elements.fonts.isEmpty {
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text("Rendered fonts").fontWeight(.semibold)
                ForEach(elements.fonts) { font in
                    HStack(spacing: 6) {
                        Text("Family name:").foregroundStyle(.secondary)
                        Text(font.name)
                    }
                    HStack(spacing: 6) {
                        Text("Font origin:").foregroundStyle(.secondary)
                        Text(font.origin + " (\(font.glyphs) \(font.glyphs == 1 ? "glyph" : "glyphs"))")
                        if font.synthesized { Text("synthesized").foregroundStyle(.secondary) }
                    }
                    .padding(.bottom, 3)
                }
            }
            .padding(8)
        }
    }
}

/// DevTools' box model: margin, border, padding and content, every side
/// shown. A double-click on a value edits it into element.style: Up and
/// Down step it (Shift ±10, Option ±0.1, Command ±100) on the page at
/// once, Tab and Shift-Tab move round the sides, Esc puts it back.
/// Hovering a layer highlights just that layer of the element on the
/// page, as in Chrome DevTools.
struct DeveloperBoxModel: View {
    @ObservedObject var session: DeveloperToolsSession
    @State private var editing: String?
    @State private var draft = ""
    /// Whether a step wrote element.style while the editor stayed open.
    @State private var written = false
    /// The layers under the pointer, outermost first.
    @State private var hovered: [String] = []

    var body: some View {
        let position = value("position")
        VStack(spacing: 0) {
            if positioned(position) {
                layer("position", prefix: nil, color: .clear, dashed: true) { margin }
            } else {
                margin
            }
        }
        .font(.system(size: 10, design: .monospaced))
        .frame(maxWidth: 360)
        .frame(maxWidth: .infinity)
    }

    private func positioned(_ position: String) -> Bool { position != "static" && !position.isEmpty }

    private var margin: some View {
        layer("margin", prefix: "margin", color: .orange) {
            layer("border", prefix: "border", suffix: "-width", color: .yellow) {
                layer("padding", prefix: "padding", color: .green) {
                    HStack(spacing: 2) {
                        cell("width")
                        Text("×").foregroundStyle(.secondary)
                        cell("height")
                    }
                    .padding(.vertical, 6).padding(.horizontal, 8)
                    .frame(maxWidth: .infinity)
                    .background(Color.blue.opacity(0.18))
                    .overlay { Rectangle().strokeBorder(Color.blue.opacity(0.4)) }
                    .onHover { hover("content", $0) }
                }
            }
        }
    }

    /// One box: its name in the corner, a value on each side.
    private func layer<Content: View>(_ name: String, prefix: String?, suffix: String = "", color: Color,
                                      dashed: Bool = false, @ViewBuilder _ content: () -> Content) -> some View {
        let property = { (side: String) in prefix.map { "\($0)-\(side)\(suffix)" } ?? side }
        return VStack(spacing: 1) {
            ZStack {
                HStack { Text(name).foregroundStyle(.secondary); Spacer() }
                cell(property("top"))
            }
            HStack(spacing: 4) {
                cell(property("left")).frame(minWidth: 22)
                content()
                cell(property("right")).frame(minWidth: 22)
            }
            cell(property("bottom"))
        }
        .padding(4)
        .background(color.opacity(0.14))
        .overlay {
            Rectangle().strokeBorder(dashed ? Palette.ink.opacity(0.35) : color.opacity(0.5),
                                     style: StrokeStyle(lineWidth: 1, dash: dashed ? [3, 2] : []))
        }
        .onHover { hover(name, $0) }
    }

    /// The innermost layer under the pointer highlighted on the page.
    private func hover(_ layer: String, _ inside: Bool) {
        hovered.removeAll { $0 == layer }
        if inside { hovered.append(layer) }
        guard let top = hovered.last else {
            session.highlightBox(nil)
            return
        }
        if top == "position" {
            session.highlightNode(session.selectedNode)
        } else {
            session.highlightBox(top)
        }
    }

    @ViewBuilder
    private func cell(_ property: String) -> some View {
        if editing == property {
            DeveloperStyleField(text: $draft, alignment: .center,
                                onKey: { key, text, selection in handle(key, property: property, text: text, selection: selection) },
                                onEnd: { if editing == property { commit(property) } })
                .frame(width: 46)
                .background(DeveloperToolsStyle.surface)
        } else {
            Text(display(property))
                .onTapGesture(count: 2) { start(property) }
                .help(property)
        }
    }

    private func start(_ property: String) {
        draft = display(property) == "-" ? "0" : display(property)
        written = false
        editing = property
    }

    private func handle(_ key: DeveloperStyleField.Key, property: String, text: String,
                        selection: NSRange) -> DeveloperStyleField.Reply {
        switch key {
        case .up(let flags), .down(let flags), .pageUp(let flags), .pageDown(let flags):
            let up = key.isUp, page = key.isPage
            let length = (text as NSString).length
            let caret: Int? = selection.length > 0 && selection.length >= length ? nil : selection.location
            let base = text.trimmingCharacters(in: .whitespaces) == "-" ? "0" : text
            let amount = DeveloperStyleEditing.stepAmount(flags, page: page) * (up ? 1 : -1)
            guard let step = DeveloperStyleEditing.step(base, caret: base == text ? caret : nil, by: amount)
            else { return .handled }
            draft = step.text
            written = true
            session.previewInlineValue(property, Self.typed(step.text))
            return .replace(step.text, step.range)
        case .tab, .backtab:
            let order = DeveloperStyleEditing.boxOrder(positioned: positioned(value("position")))
            let next = order.firstIndex(of: property).map { order[($0 + (key == .tab ? 1 : -1) + order.count) % order.count] }
            let nextDraft = next.map { display($0) == "-" ? "0" : display($0) }
            commit(property)
            if let next, let nextDraft {
                draft = nextDraft
                written = false
                editing = next
            }
            return .handled
        case .enter:
            commit(property)
            return .handled
        case .escape:
            editing = nil
            if written { session.restoreInlineStyle() }
            written = false
            return .handled
        case .right:
            return .ignored
        }
    }

    private func value(_ name: String) -> String {
        session.styles.first { $0.name == name }?.value ?? ""
    }

    /// As DevTools shows a side: pixels without the unit, "-" for zero.
    private func display(_ property: String) -> String {
        let raw = value(property)
        if raw.isEmpty { return "-" }
        guard raw.hasSuffix("px"), let number = Double(raw.dropLast(2)) else { return raw }
        if number == 0 { return "-" }
        return number == number.rounded() ? String(Int(number)) : String(format: "%.2f", number)
            .replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
    }

    /// What a typed side means: a bare number is pixels, "-" is zero.
    private static func typed(_ draft: String) -> String {
        var typed = draft.trimmingCharacters(in: .whitespaces)
        if typed == "-" { typed = "0" }
        if Double(typed) != nil { typed += "px" }
        return typed
    }

    private func commit(_ property: String) {
        guard editing == property else { return }
        editing = nil
        let typed = Self.typed(draft)
        let stepped = written
        written = false
        guard stepped || typed != value(property) else { return }
        session.setInlineValue(property, typed)
    }
}

/// Elements › Layout: the page's grid and flex containers, each overlay
/// switched on or off and coloured, as in DevTools' Layout pane.
struct DeveloperLayoutPane: View {
    @ObservedObject var session: DeveloperToolsSession
    @ObservedObject var elements: DeveloperElementsState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            section("Grid / grid lanes", overlays: "Grid / grid lanes overlays",
                    empty: "No grid or grid lanes layouts found on this page", kind: "grid")
            Divider()
            section("Flexbox", overlays: "Flexbox overlays", empty: "No flexbox layouts found on this page", kind: "flex")
        }
        .padding(8)
        .task { session.loadLayout() }
    }

    /// LayoutPane's "Overlay display settings" (the grid overlay settings).
    private var gridSettings: some View {
        let options = Binding(get: { elements.gridOptions }, set: {
            elements.gridOptions = $0
            session.refreshGridOverlays()
        })
        return VStack(alignment: .leading, spacing: 3) {
            Text("Overlay display settings").foregroundStyle(.secondary)
            Picker("", selection: options.labels) {
                ForEach(DeveloperElementsState.GridOptions.Labels.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden().fixedSize()
            Toggle("Show track sizes", isOn: options.trackSizes).toggleStyle(.developerCheckbox)
            Toggle("Show area names", isOn: options.areaNames).toggleStyle(.developerCheckbox)
            Toggle("Extend grid lines", isOn: options.extendedLines).toggleStyle(.developerCheckbox)
        }
        .padding(.bottom, 4)
    }

    private func section(_ title: String, overlays: String, empty: String, kind: String) -> some View {
        let list = elements.containers.filter { $0.kind == kind }
        return VStack(alignment: .leading, spacing: 5) {
            Text(title).fontWeight(.semibold)
            if kind == "grid" { gridSettings }
            Text(overlays).foregroundStyle(.secondary)
            if list.isEmpty {
                Text(empty).foregroundStyle(.secondary).padding(.leading, 6)
            }
            ForEach(list) { container in
                HStack(spacing: 6) {
                    Toggle(isOn: Binding(get: { container.showing }, set: { session.setOverlay(container.id, on: $0) })) {
                        Text(container.label).foregroundStyle(DeveloperToolsStyle.tint).lineLimit(1)
                    }
                    .toggleStyle(.developerCheckbox)
                    Spacer(minLength: 0)
                    ColorPicker("", selection: Binding(
                        get: { DeveloperColor.parse(container.color ?? "") ?? .purple },
                        set: { session.setOverlay(container.id, on: true, color: DeveloperColor.hex($0)) }
                    ), supportsOpacity: false)
                    .labelsHidden()
                    .help("Choose the overlay color for this element")
                    DeveloperPanelIcon(symbol: "scope", title: "Show element in the Elements panel") {
                        session.selectNode(container.id)
                    }
                }
                .onHover { session.highlightNode($0 ? container.id : nil) }
            }
        }
    }
}

/// CSS colours read and written the way the Styles pane needs them.
enum DeveloperColor {
    static let names: [String: (Double, Double, Double)] = [
        "black": (0, 0, 0), "white": (255, 255, 255), "red": (255, 0, 0), "green": (0, 128, 0),
        "blue": (0, 0, 255), "yellow": (255, 255, 0), "orange": (255, 165, 0), "purple": (128, 0, 128),
        "gray": (128, 128, 128), "grey": (128, 128, 128), "silver": (192, 192, 192), "maroon": (128, 0, 0),
        "navy": (0, 0, 128), "teal": (0, 128, 128), "olive": (128, 128, 0), "lime": (0, 255, 0),
        "aqua": (0, 255, 255), "cyan": (0, 255, 255), "fuchsia": (255, 0, 255), "magenta": (255, 0, 255),
        "pink": (255, 192, 203), "brown": (165, 42, 42), "gold": (255, 215, 0), "indigo": (75, 0, 130),
        "rebeccapurple": (102, 51, 153), "tomato": (255, 99, 71), "coral": (255, 127, 80),
    ]

    static func nsColor(_ value: String) -> NSColor? {
        let text = value.trimmingCharacters(in: .whitespaces).lowercased()
        if text == "transparent" { return NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0) }
        if let rgb = names[text] { return NSColor(srgbRed: rgb.0 / 255, green: rgb.1 / 255, blue: rgb.2 / 255, alpha: 1) }
        if text.hasPrefix("#") {
            let hex = Array(text.dropFirst())
            guard [3, 4, 6, 8].contains(hex.count), hex.allSatisfy(\.isHexDigit) else { return nil }
            let digits = hex.count <= 4 ? hex.flatMap { [$0, $0] } : hex
            let parts = stride(from: 0, to: digits.count, by: 2).map { Double(Int(String(digits[$0...$0 + 1]), radix: 16) ?? 0) / 255 }
            return NSColor(srgbRed: parts[0], green: parts[1], blue: parts[2], alpha: parts.count > 3 ? parts[3] : 1)
        }
        guard let open = text.firstIndex(of: "("), text.hasSuffix(")") else { return nil }
        let function = text[..<open]
        let numbers = text[text.index(after: open)..<text.index(before: text.endIndex)]
            .split(whereSeparator: { ", /".contains($0) }).map(String.init)
        func number(_ part: String, scale: Double) -> Double? {
            if part.hasSuffix("%") { return Double(part.dropLast()).map { $0 / 100 } }
            return Double(part).map { $0 / scale }
        }
        guard numbers.count >= 3 else { return nil }
        let alpha = numbers.count > 3 ? number(numbers[3], scale: 1) ?? 1 : 1
        if function == "rgb" || function == "rgba" {
            guard let r = number(numbers[0], scale: 255), let g = number(numbers[1], scale: 255),
                  let b = number(numbers[2], scale: 255) else { return nil }
            return NSColor(srgbRed: r, green: g, blue: b, alpha: alpha)
        }
        if function == "hsl" || function == "hsla" {
            guard let h = Double(numbers[0].replacingOccurrences(of: "deg", with: "")),
                  let s = number(numbers[1], scale: 100), let l = number(numbers[2], scale: 100) else { return nil }
            let v = l + s * min(l, 1 - l)
            let saturation = v == 0 ? 0 : 2 * (1 - l / v)
            return NSColor(hue: (h.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 360,
                           saturation: saturation, brightness: v, alpha: alpha)
        }
        return nil
    }

    static func parse(_ value: String) -> Color? { nsColor(value).map(Color.init(nsColor:)) }

    static func hex(_ color: Color) -> String {
        css(NSColor(color), like: "#")
    }

    /// A colour written back in the notation the declaration used.
    static func css(_ color: NSColor, like original: String) -> String {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        let r = Int((rgb.redComponent * 255).rounded()), g = Int((rgb.greenComponent * 255).rounded())
        let b = Int((rgb.blueComponent * 255).rounded())
        let a = rgb.alphaComponent
        let lower = original.lowercased()
        if lower.hasPrefix("#") || a >= 0.999 && !lower.hasPrefix("rgb") {
            let base = String(format: "#%02x%02x%02x", r, g, b)
            return a >= 0.999 ? base : base + String(format: "%02x", Int((a * 255).rounded()))
        }
        if a >= 0.999 { return "rgb(\(r), \(g), \(b))" }
        return "rgba(\(r), \(g), \(b), \(String(format: "%.2f", a).replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)))"
    }

    /// Colours inside a value: whole hex, functional or named tokens.
    /// Made once: swatches look for colours each time a value is drawn.
    private static let tokenExpression = try? NSRegularExpression(
        pattern: #"#[0-9a-fA-F]{3,8}\b|(?:rgba?|hsla?)\([^)]*\)|\b[a-zA-Z]+\b"#)

    static func tokens(in value: String) -> [String] {
        guard let expression = tokenExpression else { return [] }
        let range = NSRange(value.startIndex..., in: value)
        return expression.matches(in: value, range: range).compactMap { match in
            guard let range = Range(match.range, in: value) else { return nil }
            let token = String(value[range])
            return nsColor(token) == nil ? nil : token
        }
    }
}

/// The square DevTools draws before a colour: clicked, the colour picker;
/// Shift-clicked, the colour in the next format (hex → rgb → hsl → hwb …);
/// right-clicked, the menu of every format.
struct DeveloperColorSwatch: View {
    let value: String
    var contrast: DeveloperStyleContrast? = nil
    var onChange: ((String) -> Void)? = nil
    @State private var contrastShown = false

    var body: some View {
        if let token = DeveloperColor.tokens(in: value).first, let color = DeveloperColor.nsColor(token) {
            HStack(spacing: 4) {
                swatch(token, color: color)
                if let contrast, let rgb = color.usingColorSpace(.sRGB) {
                    let foreground = DeveloperCSSColor(red: rgb.redComponent * 255, green: rgb.greenComponent * 255,
                                                       blue: rgb.blueComponent * 255, alpha: rgb.alphaComponent)
                    // As in Chrome's color picker: the ratio opens the AA
                    // and AAA lines, each failing one with a fix.
                    Button { contrastShown = true } label: { contrastBadge(contrast.measure(foreground)) }
                        .buttonStyle(.plain)
                        .popover(isPresented: $contrastShown, arrowEdge: .bottom) {
                            DeveloperContrastDetails(foreground: foreground, contrast: contrast, apply: applyFix(token))
                        }
                }
            }
        }
    }

    /// A suggested colour written over `token`, in its notation.
    private func applyFix(_ token: String) -> ((DeveloperCSSColor) -> Void)? {
        guard let onChange else { return nil }
        return { fix in
            onChange(value.replacingOccurrences(of: token, with: DeveloperColor.css(DeveloperContrastFix.nsColor(fix), like: token)))
            contrastShown = false
        }
    }

    private func contrastBadge(_ result: DeveloperStyleContrast.Result) -> some View {
        let ratio = DeveloperCSSOverview.ratioLabel(result.ratio) + ":1"
        let aa = result.aa ? "AA passes" : "AA fails"
        let aaa = result.aaa ? "AAA passes" : "AAA fails"
        return HStack(spacing: 4) {
            Text(ratio).monospacedDigit()
            contrastMark("AA", passes: result.aa)
            contrastMark("AAA", passes: result.aaa)
        }
        .font(.system(size: 9))
        .foregroundStyle(.secondary)
        .fixedSize()
        .help("Contrast ratio \(ratio). \(aa). \(aaa).")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Contrast ratio \(ratio). \(aa). \(aaa).")
    }

    private func contrastMark(_ title: String, passes: Bool) -> some View {
        HStack(spacing: 2) {
            Text(title)
            Image(systemName: passes ? "checkmark" : "xmark").fontWeight(.semibold)
        }
    }

    private func swatch(_ token: String, color: NSColor) -> some View {
        Button {
            guard let onChange else { return }
            if NSEvent.modifierFlags.contains(.shift) {
                onChange(value.replacingOccurrences(of: token, with: DeveloperColorFormats.next(after: token, color: color)))
                return
            }
            DeveloperColorPicking.shared.open(color) { picked in
                onChange(value.replacingOccurrences(of: token, with: DeveloperColor.css(picked, like: token)))
            }
        } label: {
            ZStack {
                Rectangle().fill(Color.white)
                Path { path in
                    path.addRect(CGRect(x: 0, y: 0, width: 5, height: 5))
                    path.addRect(CGRect(x: 5, y: 5, width: 5, height: 5))
                }
                .fill(Color.gray.opacity(0.4))
                Rectangle().fill(Color(nsColor: color))
            }
            .frame(width: 10, height: 10)
            .overlay { Rectangle().strokeBorder(Palette.ink.opacity(0.3), lineWidth: 0.5) }
        }
        .buttonStyle(.plain)
        .help(onChange == nil ? token : "Open color picker. Shift-click to change color format")
        .accessibilityLabel("Color \(token)")
        .contextMenu {
            if let onChange {
                let options = DeveloperColorFormats.options(for: color, original: token)
                ForEach(options.filter { $0.section == 0 }, id: \.self) { option in
                    Button(option.text) { onChange(value.replacingOccurrences(of: token, with: option.text)) }
                }
                Divider()
                ForEach(options.filter { $0.section == 1 }, id: \.self) { option in
                    Button(option.text) { onChange(value.replacingOccurrences(of: token, with: option.text)) }
                }
                Divider()
                Menu("color()") {
                    ForEach(options.filter { $0.section == 2 }, id: \.self) { option in
                        Button(option.text) { onChange(value.replacingOccurrences(of: token, with: option.text)) }
                    }
                }
            }
        }
    }
}

/// The system colour panel, driving one declaration at a time.
@MainActor
final class DeveloperColorPicking: NSObject {
    static let shared = DeveloperColorPicking()
    private var handler: ((NSColor) -> Void)?
    private var pending: DispatchWorkItem?

    func open(_ color: NSColor, onChange: @escaping (NSColor) -> Void) {
        handler = nil
        let panel = NSColorPanel.shared
        panel.showsAlpha = true
        panel.setTarget(self)
        panel.setAction(#selector(changed(_:)))
        panel.color = color
        handler = onChange
        panel.orderFront(nil)
    }

    @objc private func changed(_ panel: NSColorPanel) {
        let color = panel.color
        // Dragging in the panel sends many changes; write the last of each burst.
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.handler?(color) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }
}

/// Chromium's PropertyNameCategories, for Computed › Group.
enum DeveloperComputedCategory {
    static let order = ["Layout", "Text", "Appearance", "Animation", "CSS Variables", "Grid", "Flex", "Table",
                        "Generated Content", "Other"]
    private static let lists: [(String, [String])] = [
        ("Layout", ["display", "margin", "padding", "height", "width", "position", "top", "right", "bottom", "left",
                    "z-index", "float", "clear", "overflow", "resize", "clip", "visibility", "box-sizing",
                    "align-content", "align-items", "align-self", "flex", "flex-basis", "flex-direction", "flex-flow",
                    "flex-grow", "flex-shrink", "flex-wrap", "justify-content", "order", "inline-size", "block-size",
                    "min-inline-size", "min-block-size", "max-inline-size", "max-block-size", "min-width",
                    "max-width", "min-height", "max-height"]),
        ("Text", ["font", "font-family", "font-size", "font-size-adjust", "font-stretch", "font-style",
                  "font-variant", "font-weight", "font-smoothing", "direction", "tab-size", "text-align",
                  "text-align-last", "text-decoration", "text-decoration-color", "text-decoration-line",
                  "text-decoration-style", "text-indent", "text-justify", "text-overflow", "text-shadow",
                  "text-transform", "text-size-adjust", "line-height", "vertical-align", "letter-spacing",
                  "word-spacing", "white-space", "word-break", "word-wrap"]),
        ("Appearance", ["color", "outline", "outline-color", "outline-offset", "outline-style", "Outline-width",
                        "border", "border-image", "background", "cursor", "box-shadow", "≈", "tap-highlight-color"]),
        ("Animation", ["animation", "animation-delay", "animation-direction", "animation-duration",
                       "animation-fill-mode", "animation-iteration-count", "animation-name", "animation-play-state",
                       "animation-timing-function", "transition", "transition-delay", "transition-duration",
                       "transition-property", "transition-timing-function"]),
        ("Grid", ["grid", "grid-column", "grid-row", "order", "place-items", "place-content", "place-self"]),
        ("Flex", ["flex", "order", "place-items", "place-content", "place-self"]),
        ("Table", ["border-collapse", "border-spacing", "caption-side", "empty-cells", "table-layout"]),
        ("Generated Content", ["content", "quotes", "counter-reset", "counter-increment"]),
    ]
    private static let byName: [String: [String]] = {
        var map: [String: [String]] = [:]
        for (category, names) in lists { for name in names { map[name, default: []].append(category) } }
        return map
    }()

    private static func match(_ name: String) -> [String] {
        if let found = byName[name] { return found }
        return name.hasPrefix("--") ? ["CSS Variables"] : []
    }

    /// categorizePropertyName: the name, else a shorthand it belongs to
    /// (approximated by its leading hyphenated parts), else Other.
    static func categories(of name: String) -> [String] {
        let canonical = name.replacingOccurrences(of: #"^-(webkit|moz|ms|o)-"#, with: "", options: .regularExpression)
        let direct = match(canonical)
        if !direct.isEmpty { return direct }
        var parts = canonical.split(separator: "-").map(String.init)
        while parts.count > 1 {
            parts.removeLast()
            let found = match(parts.joined(separator: "-"))
            if !found.isEmpty { return found }
        }
        return ["Other"]
    }
}
