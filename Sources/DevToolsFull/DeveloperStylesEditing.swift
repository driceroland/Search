import AppKit
import SwiftUI

/// One matched rule in Elements › Styles, edited as in Chrome DevTools: a
/// click on a declaration's name edits the name, on its value the value;
/// Tab, Return and Shift-Tab move name → value → the next name, past the
/// last value Tab opens a new declaration, and a click in the blank after
/// a line (or the rule's empty end) adds one there. Up and Down step the
/// number at the caret (Shift ±10, Option ±0.1, Command ±100; Page Up and
/// Page Down ±10, with Shift ±100) or cycle a keyword through the
/// property's values, written to the page at once; in a name nothing was
/// typed in they go to the declaration above or below. Option-Down on a
/// value with no number at the caret opens the colour picker for a colour,
/// else a tooltip on its CSS functions. Esc puts the declaration back. The checkbox switches a declaration off
/// or on; the selector edits on a click and, hovered, highlights what it
/// matches; @media and other at-rules sit above it, the source link beside
/// it; overridden declarations are struck through. The open editor lives
/// in DeveloperElementsState.styleEdit, which outlasts the rebuilds every
/// write causes.
struct DeveloperStyleRuleView: View {
    @ObservedObject var session: DeveloperToolsSession
    @ObservedObject var elements: DeveloperElementsState
    let rule: DeveloperToolsSession.StyleRule
    /// Indices into the rule's properties that the filter lets through.
    let shown: [Int]
    var contrast: DeveloperStyleContrast? = nil

    @State private var expanded = Set<Int>()
    /// The value tooltip ⌥↓ opened under a value field, until a key or an edit.
    @State private var tip: ValueTip?
    /// The calc()/min()/max()/clamp() hovers, worked out in the page, by
    /// node, property and value.
    @State private var mathTips: [String: String] = [:]

    private struct ValueTip: Equatable {
        let field: DeveloperStyleEditing.Field
        let lines: [String]
    }

    private typealias Field = DeveloperStyleEditing.Field
    private typealias Detail = DeveloperToolsSession.Detail

    /// This rule's open editor, if it has one.
    private var edit: DeveloperElementsState.StyleEdit? {
        guard let style = rule.style, let edit = elements.styleEdit, edit.style == style else { return nil }
        return edit
    }

    /// The rule's declarations as the session has them now (an edit
    /// written a moment ago included), for the writes this view makes.
    private var current: [Detail] {
        session.matchedStyles.first { $0.id == rule.id && $0.style == rule.style }?.properties ?? rule.properties
    }

    var body: some View {
        let edit = self.edit
        let properties = edit?.working ?? rule.properties
        let rows = edit == nil ? shown : properties.indices.filter { !rule.inherited || properties[$0].inheritable }
        let insert = edit.flatMap { DeveloperStyleEditing.insertion(of: $0.field) }
        VStack(alignment: .leading, spacing: 1) {
            ForEach(rule.groupings, id: \.self) { grouping in
                Text(grouping).foregroundStyle(.secondary).lineLimit(2)
            }
            selectorLine(editing: edit?.field == .selector)
                .padding(.bottom, 3)
            if insert == 0 { newDeclaration }
            ForEach(rows, id: \.self) { index in
                if properties.indices.contains(index) {
                    declaration(properties[index], at: index, field: edit?.field)
                    if expanded.contains(index) {
                        ForEach(properties[index].longhands) { longhand in
                            HStack(spacing: 0) {
                                Text(longhand.name).foregroundStyle(DeveloperToolsStyle.tint.opacity(0.8))
                                Text(": " + longhand.value + ";").foregroundStyle(.secondary)
                            }
                            .padding(.leading, 44)
                        }
                    }
                    if let insert, insert > 0, insert == index + 1 { newDeclaration }
                }
            }
            if let insert, insert > 0, !rows.contains(insert - 1) { newDeclaration }
            Text("}")
                .foregroundStyle(DeveloperToolsStyle.tint)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { begin(.newName(properties.count)) }
                .help(rule.editable ? "Click to add a declaration" : "")
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .onAppear { DispatchQueue.main.async { takePendingSelector(); takePendingName() } }
        .onChange(of: elements.pendingSelector) { _, _ in takePendingSelector() }
        .onChange(of: elements.pendingName) { _, _ in takePendingName() }
    }

    // MARK: Selector

    private func selectorLine(editing: Bool) -> some View {
        // As in DevTools, the source floats right of the selector; when the
        // two don't fit on a line the source goes above, and the selector
        // has the whole width to wrap in.
        ViewThatFits(in: .horizontal) {
            selectorRow(editing: editing, wraps: false)
            VStack(alignment: .trailing, spacing: 0) {
                source
                selectorRow(editing: editing, wraps: true)
            }
        }
    }

    /// Unwrapped, the source follows on the line.
    private func selectorRow(editing: Bool, wraps: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            if editing {
                editor(.selector)
                Text(" {")
            } else {
                // Whitespace as one space, as Chrome shows a selector
                // written over several lines in its stylesheet.
                Text(rule.selector.split(whereSeparator: \.isWhitespace).joined(separator: " ") + " {")
                    .foregroundStyle(DeveloperToolsStyle.tint)
                    .fixedSize(horizontal: !wraps, vertical: true)
                    .onTapGesture { begin(.selector) }
                    .onHover { hoverSelector($0) }
                    .help(selectorHelp)
                    .contextMenu { ruleMenu }
            }
            // As in DevTools, a click in the blank after "{" adds a
            // declaration at the top of the rule.
            Color.clear.frame(minWidth: 8, maxWidth: .infinity, minHeight: 13, maxHeight: 13)
                .contentShape(Rectangle())
                .onTapGesture { begin(.newName(0)) }
            if !wraps { source.fixedSize() }
        }
    }

    /// As in Chrome DevTools, a hovered selector shows its specificity;
    /// element.style and the attribute styles have none.
    private var selectorHelp: String {
        guard !rule.inline, rule.origin != "inline", !rule.atRule, !rule.selector.hasPrefix("@") else {
            return rule.selectorEditable ? "Click to edit the selector" : ""
        }
        return DeveloperStyleSpecificity.tooltip(for: rule.selector)
    }

    /// As in Chrome DevTools: hovering a selector highlights every element
    /// it matches; element.style highlights its element.
    private func hoverSelector(_ inside: Bool) {
        if rule.atRule { return }
        if rule.selector == "element.style" {
            session.highlightNode(inside ? (rule.inherited ? rule.sectionNode : session.selectedNode) : nil)
        } else {
            session.highlightSelector(inside ? rule.selector : nil)
        }
    }

    /// ⌘-click on a declaration's name or value, as in Chrome: its rule in
    /// the style sheet, in Sources. False when the click is an ordinary
    /// one, or the rule has no file to show.
    private func revealOnCommandClick() -> Bool {
        guard NSEvent.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
              !rule.inline, rule.sourceURL != nil else { return false }
        session.openRule(rule)
        return true
    }

    @ViewBuilder
    private var source: some View {
        // In the authored file (_button.scss:40) when a CSS source map has the rule, as in Chrome.
        let authored = session.authoredLocation(of: rule)
        let location = rule.inline ? "" : authored.map { ConsoleFormat.location($0.url, line: $0.line) }
            ?? rule.location(document: session.address)
        if let url = rule.sourceURL, !location.isEmpty, rule.origin == "regular" || rule.origin == "author" {
            Button(location) { session.openRule(rule) }
                .buttonStyle(.plain).foregroundStyle(.secondary).underline().lineLimit(1).truncationMode(.head)
                .help(authored.map { "\($0.url):\($0.line)" } ?? url + (rule.sourceLine.map { ":\($0 + 1)" } ?? ""))
        } else if !location.isEmpty {
            Text(location).foregroundStyle(.secondary).italic(rule.origin == "user-agent").lineLimit(1)
        }
    }

    @ViewBuilder
    private var ruleMenu: some View {
        Button("Copy selector") { copy(rule.selector) }
        Button("Copy rule") { copy(DeveloperStyleEditing.ruleText(selector: rule.selector, properties: current)) }
        Button("Copy all declarations") { copy(DeveloperStyleEditing.allDeclarations(current)) }
        Button("Copy all CSS changes") { copy(elements.changesText) }
    }

    // MARK: Declarations

    private func declaration(_ property: Detail, at index: Int, field: Field?) -> some View {
        let editingName: Bool = field == .name(index)
        let editingValue: Bool = field == .value(index)
        let dim: Bool = !property.enabled || property.overridden
        let struck: Bool = !property.enabled || !property.parsed || property.overridden
        let flashing: Bool = elements.flash.map { $0.rule == rule.id && $0.name == property.name } ?? false
        return VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                checkbox(property, at: index).padding(.trailing, 4)
                if !property.longhands.isEmpty { longhandsTriangle(index) }
                if editingName || editingValue {
                    if editingName {
                        editor(.name(index))
                    } else {
                        nameText(property, at: index, dim: dim, struck: struck)
                    }
                    Text(": ").strikethrough(struck).fixedSize()
                    if editingValue {
                        editor(.value(index))
                    } else {
                        DeveloperWrapFlow { valuePieces(property, at: index, dim: dim, struck: struck) }
                            .layoutPriority(1)
                    }
                } else {
                    declarationFlow(property, at: index, dim: dim, struck: struck)
                        .layoutPriority(1)
                    // A click in the blank after a declaration adds one after it.
                    Color.clear.frame(minWidth: 8, maxWidth: .infinity, minHeight: 13, maxHeight: 13)
                        .contentShape(Rectangle())
                        .onTapGesture { begin(.newName(index + 1)) }
                }
            }
            if let field, editingName || editingValue { suggestionList(field) }
            if editingValue { tipView(.value(index)) }
        }
        .padding(.leading, 4)
        .background(flashing ? Color.yellow.opacity(0.3) : Color.clear)
        .animation(.easeOut(duration: 0.4), value: flashing)
        .contextMenu { declarationMenu(property) }
    }

    private func longhandsTriangle(_ index: Int) -> some View {
        Image(systemName: expanded.contains(index) ? "arrowtriangle.down.fill" : "arrowtriangle.right.fill")
            .font(.system(size: 7)).foregroundStyle(.secondary)
            .onTapGesture { if expanded.contains(index) { expanded.remove(index) } else { expanded.insert(index) } }
            .help("Show the longhand properties")
            .padding(.trailing, 4)
    }

    /// One flow for the whole declaration, as Chrome sets it as inline
    /// text: a value too long for the line carries on under the name, not
    /// in a narrow column after it.
    private func declarationFlow(_ property: Detail, at index: Int, dim: Bool, struck: Bool) -> some View {
        DeveloperWrapFlow {
            nameText(property, at: index, dim: dim, struck: struck)
            Text(": ").strikethrough(struck)
            valuePieces(property, at: index, dim: dim, struck: struck)
            if rule.editable, property.enabled, let kind = DeveloperLayoutEditor.kind(property) {
                DeveloperLayoutEditorButton(kind: kind, rule: rule) { name, value in setDeclaration(name, value) }
                    .padding(.leading, 4)
            }
            if rule.editable, DeveloperFontEditor.carriesButton(rule.properties, at: index) {
                DeveloperFontEditorButton(rule: rule) { name, value in
                    session.editStyle(rule.id, properties: DeveloperFontEditor.setting(name, value, in: current))
                }
                    .padding(.leading, 4)
            }
            if !property.parsed {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                    .font(.system(size: 9)).help("Invalid property value").padding(.leading, 4)
            } else if let reason = inactiveReason(property) {
                // As in Chrome: a declaration that has no effect
                // where it is, with why and what would give it one.
                Image(systemName: "info.circle").foregroundStyle(.secondary)
                    .font(.system(size: 9)).help(reason).padding(.leading, 4)
                    .accessibilityLabel(reason)
            }
        }
    }

    /// Why a declaration that applies does nothing on the selected element
    /// (DeveloperInactiveCSS), judged by its and its parent's layout.
    /// Inherited and pseudo-element rules style other boxes: none for them.
    private func inactiveReason(_ property: Detail) -> String? {
        guard property.enabled, property.parsed, !property.overridden, !rule.inherited, rule.pseudo == nil,
              let context = session.layoutContext else { return nil }
        return DeveloperInactiveCSS.reason(property: property.name, value: property.value, in: context)
    }

    @ViewBuilder
    private func checkbox(_ property: Detail, at index: Int) -> some View {
        if rule.editable {
            Toggle("", isOn: Binding(get: { property.enabled }, set: { on in
                if edit != nil { session.finishStyleEdit() }
                update(at: index) { $0.enabled = on }
            }))
            .toggleStyle(.developerCheckbox)
            .controlSize(.mini)
            .labelsHidden()
            .help(property.enabled ? "Switch off this declaration" : "Switch on this declaration")
        } else {
            Color.clear.frame(width: 14, height: 1)
        }
    }

    private func nameText(_ property: Detail, at index: Int, dim: Bool, struck: Bool) -> some View {
        Text(property.name).foregroundStyle(dim ? .secondary : DeveloperToolsStyle.tint).strikethrough(struck)
            .onTapGesture { if !revealOnCommandClick() { begin(.name(index)) } }
    }

    /// The value with its swatches and closing semicolon, as pieces of a
    /// DeveloperWrapFlow; var() references are links that show what they
    /// resolve to and lead to the custom property's declaration.
    ///
    /// Pieces of a flow, not an HStack: in a narrow pane an HStack squeezed
    /// every piece (each var() link, each run of plain text) into a column
    /// of its own, each wrapping by itself and the lot spilling over the
    /// next rule. In the flow the pieces stay whole and go to the next line
    /// together, breaking between words as one Text would.
    @ViewBuilder
    private func valuePieces(_ property: Detail, at index: Int, dim: Bool, struck: Bool) -> some View {
        let editable = rule.editable && property.enabled
        let edit = { if !revealOnCommandClick() { begin(.value(index)) } }
        let textContrast = property.name == "color" && property.enabled && !struck && rule.pseudo == nil ? contrast : nil
        DeveloperColorSwatch(value: property.value, contrast: textContrast, onChange: editable ? { setValue($0, at: index) } : nil)
            .padding(.trailing, 3)
        if DeveloperEasing.isTimingProperty(property.name) {
            DeveloperEasingSwatch(value: property.value, onChange: editable ? { setValue($0, at: index) } : nil)
                .padding(.trailing, 3)
        }
        DeveloperShadowSwatch(property: property.name, value: property.value,
                              onChange: editable ? { setValue($0, at: index) } : nil)
            .padding(.trailing, 3)
        // As in Chrome: a clock before each angle (rotate(), hue-rotate(),
        // gradients), opening the dial.
        ForEach(0..<min(DeveloperAngle.matches(in: property.value).count, 8), id: \.self) { angle in
            DeveloperAngleSwatch(value: property.value, index: angle,
                                 onChange: editable ? { setValue($0, at: index) } : nil)
                .padding(.trailing, 3)
        }
        ForEach(Array(DeveloperStyleEditing.flowPieces(property.value).enumerated()), id: \.offset) { _, segment in
            if let variable = segment.variable {
                Text(segment.text)
                    .foregroundStyle(dim ? .secondary : Palette.ink)
                    .underline(true, pattern: .dot)
                    .strikethrough(struck)
                    .help(variableChain(segment.text).joined(separator: "\n"))
                    .onTapGesture { session.revealDeclaration(variable) }
            } else {
                Text(segment.text).foregroundStyle(dim ? .secondary : Palette.ink).strikethrough(struck)
                    .contentShape(Rectangle()).onTapGesture(perform: edit)
                    .help(mathTips[mathKey(property)] ?? "")
                    .onHover { if $0 { evaluateMath(property) } }
            }
        }
        if property.important {
            Text(" !important").foregroundStyle(dim ? .secondary : Palette.ink).strikethrough(struck)
                .contentShape(Rectangle()).onTapGesture(perform: edit)
        }
        Text(";").strikethrough(struck).contentShape(Rectangle()).onTapGesture(perform: edit)
    }

    /// As in Chrome: a var() reference followed through each custom
    /// property to its value (DeveloperToolsSession.variableChain).
    private func variableChain(_ reference: String) -> [String] { session.variableChain(reference) }

    private func mathKey(_ property: Detail) -> String {
        "\(session.domRevision) \(session.selectedNode ?? 0) \(property.name): \(property.value)"
    }

    /// As in Chrome: a calc(), min(), max() or clamp() value hovered is
    /// worked out step by step in the page, on the selected element (so
    /// not for inherited, pseudo-element or custom-property declarations).
    private func evaluateMath(_ property: Detail) {
        let key = mathKey(property)
        guard mathTips[key] == nil, !rule.inherited, rule.pseudo == nil, !property.name.hasPrefix("--"),
              let node = session.selectedNode else { return }
        let steps = DeveloperStyleEditing.mathSteps(property.value)
        guard !steps.isEmpty else { return }
        mathTips[key] = ""
        Task {
            let results = await session.styleMathResults(of: node, property: property.name, steps: steps)
            guard key == mathKey(property) else { mathTips.removeValue(forKey: key); return }
            let used = property.overridden || !property.enabled ? nil : session.styles.first(where: { $0.name == property.name })?.value
            mathTips[key] = DeveloperStyleEditing.mathLines(steps, results: results, used: used).joined(separator: "\n")
        }
    }

    @ViewBuilder
    private func declarationMenu(_ property: Detail) -> some View {
        Button("Copy declaration") { copy(DeveloperStyleEditing.declarationText(property)) }
        Button("Copy property") { copy(property.name) }
        Button("Copy value") { copy(property.value + (property.important ? " !important" : "")) }
        Button("Copy rule") { copy(DeveloperStyleEditing.ruleText(selector: rule.selector, properties: current)) }
        Button("Copy declaration as JS") { copy(DeveloperStyleEditing.javaScript(property)) }
        Divider()
        Button("Copy all declarations") { copy(DeveloperStyleEditing.allDeclarations(current)) }
        Button("Copy all declarations as JS") { copy(DeveloperStyleEditing.allJavaScript(current)) }
        Button("Copy all CSS changes") { copy(elements.changesText) }
        Divider()
        Button("View computed value") { session.showComputed(property.name) }
    }

    private func copy(_ text: String) { DeveloperToolsSession.copyToPasteboard(text) }

    @ViewBuilder
    private var newDeclaration: some View {
        if let edit, let at = DeveloperStyleEditing.insertion(of: edit.field) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Color.clear.frame(width: 18, height: 1)
                    if edit.field == .newName(at) {
                        editor(.newName(at))
                    } else {
                        Text(edit.name).foregroundStyle(DeveloperToolsStyle.tint)
                            .onTapGesture { begin(.newName(at)) }
                    }
                    Text(": ")
                    if edit.field == .newValue(at) {
                        editor(.newValue(at))
                    } else {
                        Spacer(minLength: 0)
                    }
                }
                suggestionList(edit.field)
                tipView(edit.field)
            }
            .padding(.leading, 4)
            .accessibilityIdentifier("developer-style-add-\(rule.id)")
        }
    }

    private func setValue(_ value: String, at index: Int) { update(at: index) { $0.value = value } }

    /// One of the rule's declarations changed and the rule written.
    private func update(at index: Int, _ change: (inout Detail) -> Void) {
        var properties = current
        guard properties.indices.contains(index) else { return }
        change(&properties[index])
        session.editStyle(rule.id, properties: properties)
    }

    /// The flexbox and grid editors: a declaration set, replaced or removed.
    private func setDeclaration(_ name: String, _ value: String?) {
        let added = value.map { DeveloperStyleEditing.parse("\(name): \($0)") } ?? []
        session.editStyle(rule.id, properties: DeveloperStyleEditing.setting(name, to: added, in: current, name: \.name))
    }

    // MARK: The editor

    private static func text(of edit: DeveloperElementsState.StyleEdit, _ field: Field) -> String {
        switch field {
        case .selector: edit.selector
        case .name, .newName: edit.name
        case .value, .newValue: edit.value
        }
    }

    /// The text field for a selector, a name or a value, with the rest of
    /// the highlighted completion greyed after what is typed.
    private func editor(_ field: Field) -> some View {
        let edit = elements.styleEdit
        let text = edit.map { Self.text(of: $0, field) } ?? ""
        let items = suggestions(field)
        let top = edit.flatMap { highlighted(items, $0) }
        let word = field.isValue ? DeveloperStyleEditing.lastWord(text) : text
        let rest = top.map { DeveloperStyleEditing.remainder(of: $0, after: word) } ?? ""
        return DeveloperStyleField(
            text: Binding(get: { elements.styleEdit.map { Self.text(of: $0, field) } ?? "" },
                          set: { typed($0, in: field) }),
            onKey: { key, current, selection in handle(key, in: field, text: current, selection: selection) },
            onEnd: { ended(field) }
        )
        .frame(width: field.isValue ? nil : DeveloperStyleField.width(of: text + rest))
        .frame(maxWidth: field.isValue ? CGFloat.infinity : nil, alignment: .leading)
        .overlay(alignment: .leading) {
            if !rest.isEmpty {
                HStack(spacing: 0) {
                    Text(text).hidden()
                    Text(rest).foregroundStyle(.tertiary)
                }
                .lineLimit(1)
                .padding(.leading, 2)
                .allowsHitTesting(false)
            }
        }
        .background(DeveloperToolsStyle.surface)
        .accessibilityIdentifier("developer-style-editor-\(rule.id)")
    }

    /// Completions for what is typed, the exact match first, as Chrome's
    /// suggest box lists them; none until something is typed.
    private func suggestions(_ field: Field) -> [String] {
        guard let edit = elements.styleEdit, edit.style == rule.style, edit.field == field, edit.suggest else { return [] }
        switch field {
        case .selector:
            return []
        case .name, .newName:
            let word = edit.name.trimmingCharacters(in: .whitespaces).lowercased()
            let exact = !word.isEmpty && elements.catalog[word] != nil ? [word] : []
            return exact + elements.completions(for: edit.name, limit: 8 - exact.count)
        case .value, .newValue:
            let word = DeveloperStyleEditing.lastWord(edit.value).lowercased()
            let values = keywords(for: edit.name) + ["inherit", "initial", "unset", "revert"]
            let exact = !word.isEmpty && values.contains(word) ? [word] : []
            return exact + elements.completions(for: edit.name + ": " + edit.value, limit: 8 - exact.count)
        }
    }

    private func keywords(for name: String) -> [String] {
        elements.catalog[name.trimmingCharacters(in: .whitespaces).lowercased()] ?? []
    }

    private func highlighted(_ items: [String], _ edit: DeveloperElementsState.StyleEdit) -> String? {
        items.isEmpty ? nil : items[min(max(edit.highlight, 0), items.count - 1)]
    }

    @ViewBuilder
    private func suggestionList(_ field: Field) -> some View {
        let items = suggestions(field)
        if !items.isEmpty {
            let highlight = min(max(elements.styleEdit?.highlight ?? 0, 0), items.count - 1)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { offset, item in
                    Text(item)
                        .padding(.horizontal, 4).frame(maxWidth: .infinity, alignment: .leading)
                        .background(offset == highlight ? DeveloperToolsStyle.selected : Color.clear)
                        .contentShape(Rectangle())
                        .onTapGesture { _ = accept(item, in: field) }
                }
            }
            .frame(maxWidth: 220)
            .background(DeveloperToolsStyle.surface)
            .overlay { Rectangle().strokeBorder(DeveloperToolsStyle.rule) }
            .padding(.leading, 22)
        }
    }

    /// The value tooltip under a value field, as Chrome's shows a CSS
    /// function's meaning and what the value comes to.
    @ViewBuilder
    private func tipView(_ field: Field) -> some View {
        if let tip, tip.field == field, elements.styleEdit?.field == field {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(tip.lines.enumerated()), id: \.offset) { _, line in
                    Text(line).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .frame(maxWidth: 320, alignment: .leading)
            .background(DeveloperToolsStyle.surface)
            .overlay { Rectangle().strokeBorder(DeveloperToolsStyle.rule) }
            .padding(.leading, 22)
            .accessibilityIdentifier("developer-style-value-tooltip")
        }
    }

    /// ⌥↓ on a value: a colour opens the colour picker (the edit is kept
    /// first, then each pick written, as a click on the swatch does);
    /// anything else, the tooltip on its CSS functions.
    private func openTooltip(_ found: DeveloperStyleEditing.ValueTooltip, for field: Field, name: String, text: String) {
        switch found {
        case .color(let token):
            guard let color = DeveloperColor.nsColor(token) else { return }
            let property = name.trimmingCharacters(in: .whitespaces)
            let typedValue = DeveloperStyleEditing.parse(property + ": " + text).first?.value ?? text
            session.finishStyleEdit()
            DeveloperColorPicking.shared.open(color) { picked in
                let properties = current
                guard let index = properties.lastIndex(where: { $0.name == property }) else { return }
                setValue(typedValue.replacingOccurrences(of: token, with: DeveloperColor.css(picked, like: token)), at: index)
            }
        case .functions(let names):
            var lines: [String] = []
            for function in names {
                lines.append(DeveloperStyleEditing.functionHelp(function))
                if function == "var" {
                    for segment in DeveloperStyleEditing.segments(text) {
                        if segment.variable != nil { lines += variableChain(segment.text).map { "  " + $0 } }
                    }
                }
            }
            let property = name.trimmingCharacters(in: .whitespaces).lowercased()
            if let computed = session.styles.first(where: { $0.name == property })?.value {
                lines.append("Computed: \(computed)")
            }
            tip = ValueTip(field: field, lines: lines)
        }
    }

    /// The completion taken into the field; returns the field's new text.
    private func accept(_ item: String, in field: Field) -> String {
        guard var edit = elements.styleEdit, edit.field == field else { return "" }
        let text: String
        if field.isValue {
            edit.value = DeveloperStyleEditing.completeValue(edit.value, with: item)
            text = edit.value
        } else {
            edit.name = item
            text = item
        }
        edit.suggest = false
        edit.highlight = 0
        elements.styleEdit = edit
        return text
    }

    /// Something typed: ":" in a name moves to the value and ";" ending a
    /// value to the next declaration, as in Chrome DevTools.
    private func typed(_ text: String, in field: Field) {
        guard var edit = elements.styleEdit, edit.style == rule.style, edit.field == field else { return }
        if tip != nil { tip = nil }
        switch field {
        case .selector:
            edit.selector = text
        case .name, .newName:
            if let colon = text.firstIndex(of: ":") {
                edit.name = String(text[..<colon]).trimmingCharacters(in: .whitespaces)
                let rest = text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if !rest.isEmpty { edit.value = rest }
                edit.suggest = false
                elements.styleEdit = edit
                advance(forward: true)
                return
            }
            edit.name = text
        case .value, .newValue:
            if text.hasSuffix(";"), DeveloperStyleEditing.balanced(String(text.dropLast())) {
                edit.value = String(text.dropLast())
                edit.suggest = false
                elements.styleEdit = edit
                advance(forward: true)
                return
            }
            edit.value = text
        }
        edit.suggest = true
        edit.highlight = 0
        elements.styleEdit = edit
    }

    private func handle(_ key: DeveloperStyleField.Key, in field: Field, text: String,
                        selection: NSRange) -> DeveloperStyleField.Reply {
        guard var edit = elements.styleEdit, edit.style == rule.style, edit.field == field else { return .ignored }
        let items = suggestions(field)
        let length = (text as NSString).length
        if tip != nil, key != .escape { tip = nil }
        switch key {
        case .up(let flags), .down(let flags), .pageUp(let flags), .pageDown(let flags):
            let up = key.isUp, page = key.isPage
            if !items.isEmpty, !page {
                // The suggest box is open: the arrows move its highlight.
                let current = min(max(edit.highlight, 0), items.count - 1)
                edit.highlight = (current + (up ? -1 : 1) + items.count) % items.count
                elements.styleEdit = edit
                return .handled
            }
            if !page, case .name(let index) = field {
                // A name nothing was typed in: ↑ and ↓ go to the
                // declaration above or below, as in Chrome's Styles pane.
                let original = edit.working.indices.contains(index) ? edit.working[index].name : nil
                if DeveloperStyleEditing.navigates(field, typed: edit.name, original: original, suggesting: !items.isEmpty) {
                    let rows = edit.working.indices.filter { !rule.inherited || edit.working[$0].inheritable }
                    if let target = DeveloperStyleEditing.adjacentName(from: field, up: up, rows: rows) {
                        begin(target)
                    } else if let next = DeveloperStyleEditing.adjacentRule(from: rule.id, up: up, in: session.matchedStyles),
                              let style = next.rule.style {
                        // Past the rule's first or last: the rule above or
                        // below, as Chrome's Styles pane moves on.
                        session.finishStyleEdit()
                        elements.pendingName = .init(rule: next.rule.id, style: style, index: next.index)
                    }
                }
                return .handled
            }
            guard field.isValue else { return .handled }
            // A whole selection steps the value's first number, as Chrome does.
            let caret: Int? = selection.length > 0 && selection.length >= length ? nil : selection.location
            let amount = DeveloperStyleEditing.stepAmount(flags, page: page) * (up ? 1 : -1)
            let modifiers = flags.intersection([.command, .shift, .option, .control])
            var replacement: (text: String, range: NSRange)?
            if let step = DeveloperStyleEditing.step(text, caret: caret, by: amount) {
                replacement = (step.text, step.range)
            } else if !up, !page, modifiers == .option, let found = DeveloperStyleEditing.valueTooltip(text) {
                // ⌥↓ with no number to step: the colour picker, or the
                // tooltip on the value's CSS functions.
                openTooltip(found, for: field, name: edit.name, text: text)
                return .handled
            } else if let next = DeveloperStyleEditing.cycle(text, through: keywords(for: edit.name), up: up) {
                replacement = (next, NSRange(location: 0, length: (next as NSString).length))
            }
            guard let replacement else { return .handled }
            edit.value = replacement.text
            edit.suggest = false
            preview(&edit)
            elements.styleEdit = edit
            return .replace(replacement.text, replacement.range)
        case .right:
            guard let item = highlighted(items, edit), selection.location >= length else { return .ignored }
            let new = accept(item, in: field)
            return .replace(new, NSRange(location: (new as NSString).length, length: 0))
        case .tab, .enter:
            if let item = highlighted(items, edit) { _ = accept(item, in: field) }
            advance(forward: true)
            return .handled
        case .backtab:
            advance(forward: false)
            return .handled
        case .escape:
            if tip != nil { tip = nil; return .handled }
            if !items.isEmpty {
                edit.suggest = false
                elements.styleEdit = edit
                return .handled
            }
            session.finishStyleEdit(cancel: true)
            return .handled
        }
    }

    /// A stepped value written to the page with the editor still open.
    private func preview(_ edit: inout DeveloperElementsState.StyleEdit) {
        guard case .value(let index) = edit.field, edit.working.indices.contains(index) else { return }
        let (properties, change) = DeveloperStyleEditing.fold(edit.working, field: edit.field, name: edit.name, value: edit.value)
        guard change == 1, properties != edit.working else { return }
        edit.working = properties
        edit.written = true
        session.writeStyle(edit.style, properties)
    }

    /// Tab, Return or Shift-Tab: the field folded into the rule and the
    /// editor moved on (DeveloperStyleEditing.next), or closed.
    private func advance(forward: Bool) {
        guard var edit = elements.styleEdit, edit.style == rule.style else { return }
        let from = edit.field
        let change = session.foldStyleEdit(&edit)
        let rows = edit.working.indices.filter { !rule.inherited || edit.working[$0].inheritable }
        guard let next = DeveloperStyleEditing.next(from: from, forward: forward, rows: rows, count: edit.working.count,
                                                    change: change, selectorEditable: rule.selectorEditable),
              next == .selector || rule.editable else {
            session.commitStyleEdit(edit)
            return
        }
        edit.enter(next, selector: rule.selector)
        elements.styleEdit = edit
    }

    private func begin(_ field: Field) {
        guard let style = rule.style, field == .selector ? rule.selectorEditable : rule.editable else { return }
        if var edit = elements.styleEdit, edit.style == style {
            guard edit.field != field else { return }
            session.foldStyleEdit(&edit)
            edit.enter(field, selector: rule.selector)
            elements.styleEdit = edit
            return
        }
        session.finishStyleEdit()
        elements.styleEdit = DeveloperElementsState.StyleEdit(style: style, field: field, properties: current,
                                                              selector: rule.selector)
    }

    /// Focus left the field (another field, the tree, the page): the edit is kept.
    private func ended(_ field: Field) {
        guard let edit = elements.styleEdit, edit.style == rule.style, edit.field == field else { return }
        session.finishStyleEdit()
    }

    /// ↑ or ↓ from the end of the rule beside this one: its name opens here.
    private func takePendingName() {
        guard let pending = elements.pendingName, pending.style == rule.style else { return }
        elements.pendingName = nil
        begin(.name(pending.index))
    }

    /// A rule added with + opens its selector for editing as it first shows.
    private func takePendingSelector() {
        guard let pending = elements.pendingSelector, pending == rule.rule else { return }
        elements.pendingSelector = nil
        begin(.selector)
    }
}

/// A one-line field for the Styles editors that hands DevTools' keys
/// (Tab, Shift-Tab, Return, Esc, the arrows) to its owner before the text
/// system acts on them, reports the caret, and takes focus as it appears.
struct DeveloperStyleField: NSViewRepresentable {
    enum Key: Equatable {
        case up(NSEvent.ModifierFlags), down(NSEvent.ModifierFlags), right, tab, backtab, enter, escape
        /// Page Up and Page Down (fn↑, fn↓), which step a value by 10.
        case pageUp(NSEvent.ModifierFlags), pageDown(NSEvent.ModifierFlags)

        /// ↑ or Page Up.
        var isUp: Bool {
            switch self {
            case .up, .pageUp: return true
            default: return false
            }
        }

        /// Page Up or Page Down.
        var isPage: Bool {
            switch self {
            case .pageUp, .pageDown: return true
            default: return false
            }
        }
    }

    enum Reply {
        case ignored, handled
        /// The field's text replaced, the range selected.
        case replace(String, NSRange)
    }

    @Binding var text: String
    var alignment: NSTextAlignment = .left
    let onKey: (Key, String, NSRange) -> Reply
    let onEnd: () -> Void

    static let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

    /// Wide enough for the text and the caret after it.
    static func width(of text: String) -> CGFloat {
        let measured = (text as NSString).size(withAttributes: [.font: font]).width
        return min(max(ceil(measured) + 8, 14), 360)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> Field {
        let field = Field()
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = Self.font
        field.alignment = alignment
        field.lineBreakMode = .byClipping
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.stringValue = text
        field.delegate = context.coordinator
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: Field, context: Context) {
        context.coordinator.parent = self
        if let editor = field.currentEditor() as? NSTextView {
            if editor.string != text {
                editor.string = text
                editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            }
        } else if field.stringValue != text {
            field.stringValue = text
        }
    }

    final class Field: NSTextField {
        /// Set while the view leaves its window, so the end of editing that
        /// causes isn't taken for the user leaving the field.
        fileprivate var removing = false

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil { removing = true }
            super.viewWillMove(toWindow: newWindow)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            removing = false
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window, !self.removing, self.currentEditor() == nil else { return }
                window.makeFirstResponder(self)
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: DeveloperStyleField

        init(_ parent: DeveloperStyleField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? Field, !field.removing else { return }
            parent.onEnd()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            let event = NSApp.currentEvent
            let flags = event?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []
            // ↑, ↓, Page Up and Page Down, by key code.
            let arrows: [UInt16: (NSEvent.ModifierFlags) -> Key] = [126: Key.up, 125: Key.down, 116: Key.pageUp, 121: Key.pageDown]
            let key: Key
            if let event, event.type == .keyDown, let arrow = arrows[event.keyCode] {
                key = arrow(flags)
            } else {
                switch selector {
                case #selector(NSResponder.moveRight(_:)): key = .right
                case #selector(NSResponder.insertTab(_:)): key = .tab
                case #selector(NSResponder.insertBacktab(_:)): key = .backtab
                case #selector(NSResponder.insertNewline(_:)): key = .enter
                case #selector(NSResponder.cancelOperation(_:)), #selector(NSTextView.complete(_:)): key = .escape
                default: return false
                }
            }
            switch parent.onKey(key, textView.string, textView.selectedRange()) {
            case .ignored:
                return false
            case .handled:
                return true
            case .replace(let text, let range):
                textView.string = text
                textView.setSelectedRange(range)
                return true
            }
        }
    }
}

/// The Styles pane's editing rules, apart from the views so they can be
/// tested: where Tab goes, what an arrow key does to a value, how var()
/// and completions read, and the text the copy items put on the clipboard.
enum DeveloperStyleEditing {
    typealias Detail = DeveloperToolsSession.Detail

    enum Field: Hashable {
        case selector
        case name(Int)
        case value(Int)
        /// A declaration being added at an index: its name, then its value.
        case newName(Int)
        case newValue(Int)

        var isValue: Bool {
            switch self {
            case .value, .newValue: true
            default: false
            }
        }
    }

    /// Which declaration a field belongs to: a name and its value are one.
    static func declaration(of field: Field) -> String {
        switch field {
        case .selector: "selector"
        case .name(let index), .value(let index): "declaration \(index)"
        case .newName(let index), .newValue(let index): "new \(index)"
        }
    }

    /// Where a new declaration goes, for a field that adds one.
    static func insertion(of field: Field) -> Int? {
        switch field {
        case .newName(let index), .newValue(let index): index
        default: nil
        }
    }

    /// Where Tab (forward) or Shift-Tab goes from a field, as in Chrome
    /// DevTools: selector → first name; name → its value; value → the next
    /// name, past the last one a new declaration; Shift-Tab back the same
    /// way to the selector. `rows` are the declarations shown, `count` all
    /// of them, after the field was folded in; `change` is how many
    /// declarations now stand where the field's did (0 when it was emptied
    /// and went; for a new name, whether one was typed). Nil closes the editor.
    static func next(from field: Field, forward: Bool, rows: [Int], count: Int, change: Int,
                     selectorEditable: Bool) -> Field? {
        let top: Field? = selectorEditable ? .selector : nil
        func valueBefore(_ index: Int) -> Field? { rows.last { $0 < index }.map(Field.value) ?? top }
        func nameFrom(_ index: Int) -> Field { rows.first { $0 >= index }.map(Field.name) ?? .newName(count) }
        switch (field, forward) {
        case (.selector, true): return nameFrom(0)
        case (.selector, false): return nil
        case (.name(let index), true): return change == 0 ? nameFrom(index) : .value(index)
        case (.name(let index), false): return valueBefore(index)
        case (.value(let index), true): return nameFrom(index + max(change, 0))
        case (.value(let index), false): return change == 0 ? valueBefore(index) : .name(index)
        case (.newName(let index), true): return change == 0 ? nil : .newValue(index)
        case (.newName(let index), false): return valueBefore(index)
        case (.newValue(let index), true): return change == 0 ? nil : .newName(index + change)
        case (.newValue(let index), false): return .newName(index)
        }
    }

    /// A field's name and value folded into the declarations: an emptied
    /// one goes, "a: b; c: d" becomes two, a new one is inserted once it
    /// has a value. Returns the declarations and how many now stand where
    /// the field's did (see `next`).
    static func fold(_ properties: [Detail], field: Field, name: String, value: String) -> (properties: [Detail], change: Int) {
        let name = name.trimmingCharacters(in: .whitespaces)
        let typed = name.isEmpty ? [] : parse(name + ": " + value)
        var properties = properties
        switch field {
        case .selector:
            return (properties, 1)
        case .name(let index), .value(let index):
            guard properties.indices.contains(index) else { return (properties, 0) }
            let old = properties[index]
            if typed.count == 1, typed[0].name == old.name, typed[0].value == old.value, typed[0].important == old.important {
                return (properties, 1)
            }
            properties.replaceSubrange(index...index, with: typed)
            return (properties, typed.count)
        case .newName:
            return (properties, name.isEmpty ? 0 : 1)
        case .newValue(let index):
            guard !typed.isEmpty else { return (properties, 0) }
            properties.insert(contentsOf: typed, at: min(max(index, 0), properties.count))
            return (properties, typed.count)
        }
    }

    /// "name: value" typed into a rule, split on semicolons as DevTools
    /// splits it; names lowercased except custom properties (--name).
    static func parse(_ typed: String) -> [Detail] {
        typed.split(separator: ";").compactMap { part in
            let pair = part.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard pair.count == 2, !pair[0].isEmpty, !pair[1].isEmpty else { return nil }
            var value = pair[1]
            var important = false
            if value.lowercased().hasSuffix("!important") {
                important = true
                value = String(value.dropLast("!important".count)).trimmingCharacters(in: .whitespaces)
            }
            guard !value.isEmpty else { return nil }
            let name = pair[0].hasPrefix("--") ? pair[0] : pair[0].lowercased()
            return Detail(name: name, value: value, important: important)
        }
    }

    // MARK: Arrow keys

    /// Chrome's steps: 1, Shift 10, Option 0.1, Command 100.
    static func stepAmount(_ flags: NSEvent.ModifierFlags) -> Double {
        if flags.contains(.command) { return 100 }
        if flags.contains(.shift) { return 10 }
        if flags.contains(.option) { return 0.1 }
        return 1
    }

    struct Step: Equatable {
        let text: String
        /// The new number, selected so the next press steps it again.
        let range: NSRange
    }

    /// The number at the caret (or, with no caret, the first) moved by
    /// `delta`, its unit kept; numbers inside words (h1, translate3d) and
    /// hex colours are left alone. Nil when there is none to step.
    /// The number, then its unit: a caret anywhere in "10px" steps the 10.
    private static let numberExpression = try? NSRegularExpression(pattern: #"(?<![\w#.\-])(-?(?:\d+(?:\.\d+)?|\.\d+))[a-zA-Z%]*"#)

    static func step(_ text: String, caret: Int?, by delta: Double) -> Step? {
        guard let expression = numberExpression else { return nil }
        let string = text as NSString
        let matches = expression.matches(in: text, range: NSRange(location: 0, length: string.length))
        let found: NSTextCheckingResult?
        if let caret {
            found = matches.first { $0.range.location <= caret && caret <= $0.range.location + $0.range.length }
        } else {
            found = matches.first
        }
        guard let found, found.numberOfRanges > 1 else { return nil }
        let numberRange = found.range(at: 1)
        guard let number = Double(string.substring(with: numberRange)) else { return nil }
        let replacement = format(number + delta)
        let new = string.replacingCharacters(in: numberRange, with: replacement)
        return Step(text: new, range: NSRange(location: numberRange.location, length: (replacement as NSString).length))
    }

    /// A stepped number as Chrome writes it: six decimals at most, no
    /// trailing zeros, no "-0".
    static func format(_ number: Double) -> String {
        let rounded = (number * 1_000_000).rounded() / 1_000_000
        if rounded == rounded.rounded(), abs(rounded) < 1e15 { return String(Int(rounded)) }
        var text = String(format: "%.6f", rounded)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text == "-0" ? "0" : text
    }

    /// A keyword value moved to the property's previous (Up) or next
    /// (Down) value, wrapping; nil when the value isn't one of them.
    static func cycle(_ text: String, through values: [String], up: Bool) -> String? {
        let word = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !values.isEmpty, let index = values.firstIndex(of: word) else { return nil }
        return values[(index + (up ? -1 : 1) + values.count) % values.count]
    }

    /// Page Up and Page Down step as Chrome's do: 10, or 100 with Shift.
    static func stepAmount(_ flags: NSEvent.ModifierFlags, page: Bool) -> Double {
        guard page else { return stepAmount(flags) }
        return flags.contains(.shift) ? 100 : 10
    }

    // MARK: Moving between declarations

    /// Whether ↑ and ↓ in a field move between declarations, as they move
    /// the selection between properties in Chrome's Styles pane, rather
    /// than step or complete: a name field still holding the declaration's
    /// own name (nothing typed in it) with no completions open.
    static func navigates(_ field: Field, typed: String, original: String?, suggesting: Bool) -> Bool {
        guard case .name = field, !suggesting, let original else { return false }
        return typed.trimmingCharacters(in: .whitespaces) == original
    }

    /// The name of the declaration shown above (↑) or below (↓) a name
    /// field's. `rows` are the declarations shown; nil at either end.
    static func adjacentName(from field: Field, up: Bool, rows: [Int]) -> Field? {
        guard case .name(let index) = field else { return nil }
        let found = up ? rows.last(where: { $0 < index }) : rows.first(where: { $0 > index })
        return found.map(Field.name)
    }

    /// Where ↑ or ↓ goes past a rule's first or last declaration: the
    /// nearest editable rule above or below with a declaration shown, at
    /// its last (↑) or first (↓). Nil at the pane's top or bottom.
    static func adjacentRule(from id: Int, up: Bool, in rules: [DeveloperToolsSession.StyleRule])
        -> (rule: DeveloperToolsSession.StyleRule, index: Int)? {
        guard let start = rules.firstIndex(where: { $0.id == id }) else { return nil }
        let order = up ? Array(rules[..<start].reversed()) : Array(rules[(start + 1)...])
        for candidate in order where candidate.editable {
            let rows = candidate.properties.indices.filter { !candidate.inherited || candidate.properties[$0].inheritable }
            if let index = up ? rows.last : rows.first { return (candidate, index) }
        }
        return nil
    }

    // MARK: The value tooltip

    /// What ⌥↓ opens on a value with no number at the caret to step: the
    /// colour picker for a colour, as Chrome's swatch opens from the
    /// keyboard, or a tooltip on the CSS functions it uses.
    enum ValueTooltip: Equatable {
        case color(String)
        /// The functions' names, lowercased, in the order they first appear.
        case functions([String])
    }

    static func valueTooltip(_ value: String) -> ValueTooltip? {
        let text = value.trimmingCharacters(in: .whitespaces)
        let colors = DeveloperColor.tokens(in: text)
        if let first = colors.first, first.count == text.count { return .color(first) }
        let names = functionNames(text)
        if !names.isEmpty { return .functions(names) }
        return colors.first.map(ValueTooltip.color)
    }

    /// "calc(var(--a) + 2px)" as ["calc", "var"].
    private static let functionExpression = try? NSRegularExpression(pattern: #"(?<![\w-])([a-zA-Z][\w-]*)\("#)

    static func functionNames(_ value: String) -> [String] {
        guard let expression = functionExpression else { return [] }
        let string = value as NSString
        var names: [String] = []
        for match in expression.matches(in: value, range: NSRange(location: 0, length: string.length)) {
            let name = string.substring(with: match.range(at: 1)).lowercased()
            if !names.contains(name) { names.append(name) }
        }
        return names
    }

    /// A line for a CSS function in the value tooltip.
    static func functionHelp(_ name: String) -> String {
        let help: [String: String] = [
            "calc": "Works out the value from an expression",
            "min": "The smallest of the values",
            "max": "The largest of the values",
            "clamp": "The middle value, kept between the smallest and the largest",
            "var": "The value of a custom property",
            "env": "The value of an environment variable",
            "attr": "The value of the element's attribute",
            "url": "A file the value refers to",
            "rgb": "A colour from red, green and blue", "rgba": "A colour from red, green, blue and alpha",
            "hsl": "A colour from hue, saturation and lightness", "hsla": "A colour from hue, saturation, lightness and alpha",
            "hwb": "A colour from hue, whiteness and blackness",
            "lab": "A colour in CIE Lab", "lch": "A colour in CIE LCH",
            "oklab": "A colour in Oklab", "oklch": "A colour in OkLCH",
            "color": "A colour in a named colour space", "color-mix": "Two colours mixed",
            "linear-gradient": "A gradient along a line", "radial-gradient": "A gradient out from a point",
            "conic-gradient": "A gradient around a point",
            "repeating-linear-gradient": "A repeating gradient along a line",
            "repeating-radial-gradient": "A repeating gradient out from a point",
            "cubic-bezier": "An easing curve from two control points", "steps": "An easing in equal steps",
            "linear": "An easing through the points given",
            "translate": "Moves the element", "translatex": "Moves the element across",
            "translatey": "Moves the element up or down", "translate3d": "Moves the element in 3D",
            "rotate": "Turns the element", "scale": "Resizes the element", "skew": "Slants the element",
            "matrix": "A 2D transform matrix", "matrix3d": "A 3D transform matrix",
            "repeat": "Repeats grid tracks", "minmax": "A grid track between two sizes",
            "fit-content": "A size that fits the content, up to a limit",
            "blur": "Blurs the element", "brightness": "Brightens or darkens the element",
            "drop-shadow": "A shadow following the element's shape",
        ]
        return "\(name)() — " + (help[name] ?? "a CSS function")
    }

    /// The box model's Tab order: each box from the outside in (position
    /// when it is shown, margin, border, padding), its sides clockwise
    /// from the top as CSS writes them, then the content's width and height.
    static func boxOrder(positioned: Bool) -> [String] {
        let sides = ["top", "right", "bottom", "left"]
        var order = positioned ? sides : []
        order += sides.map { "margin-\($0)" }
        order += sides.map { "border-\($0)-width" }
        order += sides.map { "padding-\($0)" }
        return order + ["width", "height"]
    }

    // MARK: Completions

    /// The word a value completion replaces: the last one typed.
    static func lastWord(_ value: String) -> String {
        value.split(separator: " ", omittingEmptySubsequences: false).last.map(String.init) ?? ""
    }

    static func completeValue(_ value: String, with completion: String) -> String {
        var words = value.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        if words.isEmpty { words = [""] }
        words[words.count - 1] = completion
        return words.joined(separator: " ")
    }

    /// The part of a completion still to come after what is typed, shown
    /// greyed in the field.
    static func remainder(of completion: String, after word: String) -> String {
        guard !word.isEmpty, completion.lowercased().hasPrefix(word.lowercased()), completion.count > word.count else { return "" }
        return String(completion.dropFirst(word.count))
    }

    /// Whether brackets and quotes are closed, so a ";" typed after the
    /// text ends the declaration rather than sitting inside a string or url().
    static func balanced(_ text: String) -> Bool {
        var depth = 0
        var quote: Character?
        var escaped = false
        for character in text {
            if escaped { escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if let open = quote {
                if character == open { quote = nil }
                continue
            }
            switch character {
            case "\"", "'": quote = character
            case "(", "[": depth += 1
            case ")", "]": depth -= 1
            default: break
            }
        }
        return depth == 0 && quote == nil
    }

    // MARK: var()

    struct Segment: Equatable {
        let text: String
        /// The custom property a var() segment refers to.
        let variable: String?
    }

    /// `segments`, with plain text cut again after each space, so a value
    /// laid out in a flow breaks between words; a var() reference stays one
    /// piece.
    static func flowPieces(_ value: String) -> [Segment] {
        segments(value).flatMap { segment -> [Segment] in
            guard segment.variable == nil else { return [segment] }
            var pieces: [Segment] = []
            var word = ""
            for character in segment.text {
                word.append(character)
                if character == " " {
                    pieces.append(Segment(text: word, variable: nil))
                    word = ""
                }
            }
            if !word.isEmpty { pieces.append(Segment(text: word, variable: nil)) }
            return pieces
        }
    }

    /// A value cut into plain text and var(--name, fallback) references.
    static func segments(_ value: String) -> [Segment] {
        var output: [Segment] = []
        var plain = ""
        let characters = Array(value)
        var index = 0
        while index < characters.count {
            let rest = String(characters[index..<min(index + 4, characters.count)]).lowercased()
            let preceded = index > 0 && (characters[index - 1].isLetter || characters[index - 1] == "-")
            if rest == "var(", !preceded {
                var depth = 0
                var end: Int?
                for position in index..<characters.count {
                    if characters[position] == "(" { depth += 1 }
                    if characters[position] == ")" {
                        depth -= 1
                        if depth == 0 { end = position; break }
                    }
                }
                if let end {
                    let inside = String(characters[(index + 4)..<end])
                    let name = inside.split(separator: ",", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                    if !plain.isEmpty { output.append(Segment(text: plain, variable: nil)) }
                    plain = ""
                    output.append(Segment(text: String(characters[index...end]), variable: name.hasPrefix("--") ? name : nil))
                    index = end + 1
                    continue
                }
            }
            plain.append(characters[index])
            index += 1
        }
        if !plain.isEmpty { output.append(Segment(text: plain, variable: nil)) }
        return output
    }

    // MARK: Copying

    static func declarationText(_ property: Detail) -> String {
        "\(property.name): \(property.value)\(property.important ? " !important" : "");"
    }

    /// Copy declaration as JS, as Chrome writes it: camelCased name (custom
    /// properties quoted), the value quoted.
    static func javaScript(_ property: Detail) -> String {
        var name = ""
        if property.name.hasPrefix("--") {
            name = "'\(property.name)'"
        } else {
            var upper = false
            for character in property.name {
                if character == "-" { upper = true; continue }
                if upper, character.isLetter { name += character.uppercased() } else {
                    if upper { name += "-" }
                    name.append(character)
                }
                upper = false
            }
            if upper { name += "-" }
        }
        let value = (property.value + (property.important ? " !important" : "")).replacingOccurrences(of: "'", with: "\\'")
        return "\(name): '\(value)'"
    }

    static func allDeclarations(_ properties: [Detail]) -> String {
        properties.map(\.text).joined(separator: "\n")
    }

    static func allJavaScript(_ properties: [Detail]) -> String {
        properties.filter(\.enabled).map(javaScript).joined(separator: ",\n")
    }

    static func ruleText(selector: String, properties: [Detail]) -> String {
        selector + " {\n" + properties.map { "  " + $0.text + "\n" }.joined() + "}"
    }

    /// One rule as Copy all CSS changes writes it: the declarations taken
    /// out or changed commented, the new ones as they are; empty when
    /// nothing differs.
    static func changesText(selector: String, original: [Detail], current: [Detail]) -> String {
        let before = original.filter(\.enabled).map(declarationText)
        let after = current.filter(\.enabled).map(declarationText)
        let removed = before.filter { !after.contains($0) }
        let added = after.filter { !before.contains($0) }
        guard !removed.isEmpty || !added.isEmpty else { return "" }
        return selector + " {\n" + removed.map { "  /* \($0) */\n" }.joined() + added.map { "  \($0)\n" }.joined() + "}"
    }
}


/// Elements › Event Listeners: what listens on the selected element (and,
/// with Ancestors, on its ancestors, document and window), by event type.
struct DeveloperEventListenersView: View {
    @ObservedObject var session: DeveloperToolsSession
    @ObservedObject private var elements: DeveloperElementsState
    @State private var collapsed: Set<String> = []
    /// Listeners whose details (flags and handler) are shown.
    @State private var expanded: Set<Int> = []
    /// Handler sources read for expanded listeners, by id.
    @State private var sources: [Int: String] = [:]

    init(session: DeveloperToolsSession) {
        _session = ObservedObject(wrappedValue: session)
        _elements = ObservedObject(wrappedValue: session.elements)
    }
    @AppStorage("developerTools.listenerCategory", store: DevDefaults.store) private var category = "All"

    var body: some View {
        let shown = session.listeners.filter {
            category == "All" || (category == "Passive" ? $0.passive : !$0.passive)
        }
        let groups = Dictionary(grouping: shown, by: \.type)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DeveloperToolsStyle.gutter) {
                reloading("Ancestors", \.listenerAncestors, help: "Show listeners on the ancestors")
                Picker("", selection: $category) {
                    ForEach(["All", "Passive", "Blocking"], id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden().fixedSize().controlSize(.small)
                .help("Event listeners category")
                reloading("Framework listeners", \.listenerFramework, help: "Show handlers registered through jQuery and React")
                Spacer(minLength: 0)
                DeveloperPanelIcon(symbol: "arrow.clockwise", title: "Refresh event listeners", action: session.loadListeners)
            }
            .font(.system(size: 11))
            .padding(.bottom, 4)
            if groups.isEmpty {
                Text("No event listeners").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.top, 12)
            }
            ForEach(groups.keys.sorted(), id: \.self) { type in
                let open = !collapsed.contains(type)
                Button {
                    if open { collapsed.insert(type) } else { collapsed.remove(type) }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: open ? "arrowtriangle.down.fill" : "arrowtriangle.right.fill")
                            .font(.system(size: 7)).foregroundStyle(.secondary)
                        Text(type).fontWeight(.semibold)
                        Spacer(minLength: 0)
                    }
                    .frame(height: DeveloperToolsStyle.rowHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if open {
                    ForEach(groups[type] ?? []) { listener in listenerRow(listener) }
                }
            }
        }
        .padding(8)
        .accessibilityIdentifier("developer-event-listeners")
        .task(id: session.listeners.map(\.id)) {
            sources = [:]
            await session.readListenerBreakpoints()
        }
    }

    /// A checkbox for one of the session's listener options; the list is read again as it changes.
    private func reloading(_ title: String, _ option: ReferenceWritableKeyPath<DeveloperToolsSession, Bool>,
                           help: String) -> some View {
        Toggle(title, isOn: Binding(get: { session[keyPath: option] }, set: {
            session[keyPath: option] = $0
            session.loadListeners()
        }))
        .toggleStyle(.developerCheckbox).controlSize(.small)
        .help(help)
    }

    private func listenerRow(_ listener: DeveloperToolsSession.EventListener) -> some View {
        let open = expanded.contains(listener.id)
        let native = listener.framework == nil && listener.id > 0
        let paused = elements.listenerBreakpoints.contains(listener.id)
        return VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Button {
                    if open { expanded.remove(listener.id) } else { expanded.insert(listener.id) }
                } label: {
                    Image(systemName: open ? "arrowtriangle.down.fill" : "arrowtriangle.right.fill")
                        .font(.system(size: 7)).foregroundStyle(.secondary)
                        .frame(width: 8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(open ? "Collapse" : "Expand")
                if listener.framework == nil {
                    Toggle("", isOn: Binding(get: { !listener.disabled }, set: { session.setListener(listener.id, disabled: !$0) }))
                        .toggleStyle(.developerCheckbox).controlSize(.mini).labelsHidden()
                        .help(listener.disabled ? "Enable this listener" : "Disable this listener")
                } else {
                    Color.clear.frame(width: 12, height: 1)
                }
                Text(listener.target.isEmpty ? "node" : listener.target).foregroundStyle(DeveloperToolsStyle.tint)
                    .strikethrough(listener.disabled)
                    .lineLimit(1)
                if paused {
                    Image(systemName: "pause.circle.fill").font(.system(size: 9)).foregroundStyle(.blue)
                        .help("Paused on when this listener runs")
                        .accessibilityLabel("Breakpoint")
                }
                Spacer(minLength: 0)
                if native {
                    Button("Remove") { session.removeListener(listener) }
                        .buttonStyle(.plain).foregroundStyle(DeveloperToolsStyle.tint).font(.system(size: 10))
                        .help("Remove this event listener")
                }
                // As in Chrome DevTools, the handler's script:line opens in Sources.
                locationLink(listener)
            }
            if open {
                VStack(alignment: .leading, spacing: 2) {
                    Text(flags(listener)).foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Text("handler: ").foregroundStyle(.secondary)
                        if let source = sources[listener.id] {
                            Text(DeveloperListenerPreview.firstLine(source)).lineLimit(1).truncationMode(.tail)
                                .textSelection(.enabled)
                                .help(source)
                        } else {
                            Text(listener.handler.isEmpty ? "(anonymous)" : listener.handler)
                        }
                        Spacer(minLength: 6)
                        locationLink(listener)
                    }
                    if native {
                        Toggle("Breakpoint", isOn: Binding(get: { paused }, set: { session.setListenerBreakpoint(listener, on: $0) }))
                            .toggleStyle(.developerCheckbox).controlSize(.mini)
                            .help(paused ? "Remove the breakpoint on this listener" : "Pause when this listener runs")
                    }
                }
                .font(.system(size: 10, design: .monospaced))
                .padding(.leading, 34)
                .task(id: listener.id) {
                    guard native, sources[listener.id] == nil,
                          let source = await session.listenerSource(listener) else { return }
                    sources[listener.id] = source
                }
            }
        }
        .padding(.leading, 4)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Reveal in Sources panel") { session.revealListener(listener) }
                .disabled(listener.url.isEmpty)
            if native {
                Button("Remove") { session.removeListener(listener) }
                Button(paused ? "Remove breakpoint" : "Add breakpoint") {
                    session.setListenerBreakpoint(listener, on: !paused)
                }
            }
        }
    }

    @ViewBuilder
    private func locationLink(_ listener: DeveloperToolsSession.EventListener) -> some View {
        if listener.url.isEmpty {
            Text(listener.location).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
        } else {
            // In the authored file when the script has a source map, as in Chrome.
            let link = session.listenerLink(listener)
            Button(ConsoleFormat.location(link.url, line: link.line)) { session.revealListener(listener) }
                .buttonStyle(.plain).foregroundStyle(.secondary).underline()
                .lineLimit(1).truncationMode(.head)
                .help(link.url + (link.line.map { ":\($0)" } ?? ""))
        }
    }

    private func flags(_ listener: DeveloperToolsSession.EventListener) -> String {
        var parts = ["handler: " + (listener.handler.isEmpty ? "(anonymous)" : listener.handler)]
        if let framework = listener.framework {
            parts += [framework] + (listener.useCapture ? ["capture"] : [])
        } else {
            parts += ["useCapture: \(listener.useCapture)", "passive: \(listener.passive)", "once: \(listener.once)"]
            if listener.isAttribute { parts.append("attribute") }
        }
        return parts.joined(separator: " · ")
    }
}
