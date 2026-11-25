import AppKit
import SwiftUI

// MARK: Font editor

/// Chromium's FontEditor: one button per rule, on its first font
/// declaration, opening a popover that sets font-family (with fallbacks),
/// font-size, line-height, font-weight and letter-spacing.
enum DeveloperFontEditor {
    static let properties = ["font-family", "font-size", "line-height", "font-weight", "letter-spacing"]

    struct Metric {
        let name: String
        let title: String
        let units: [String]
        /// The slider's range for each unit.
        let ranges: [String: ClosedRange<Double>]
        let step: Double
    }

    static let metrics: [Metric] = [
        Metric(name: "font-size", title: "Size", units: ["px", "em", "rem", "%", "vh", "vw"],
               ranges: ["px": 0...72, "em": 0...4.5, "rem": 0...4.5, "%": 0...450, "vh": 0...10, "vw": 0...10], step: 1),
        Metric(name: "line-height", title: "Line height", units: ["", "px", "em", "rem", "%"],
               ranges: ["": 0...3, "px": 0...72, "em": 0...3, "rem": 0...3, "%": 0...300], step: 0.1),
        Metric(name: "font-weight", title: "Weight", units: [""], ranges: ["": 100...900], step: 100),
        Metric(name: "letter-spacing", title: "Spacing", units: ["px", "em", "rem"],
               ranges: ["px": -10...10, "em": -0.5...0.5, "rem": -0.5...0.5], step: 0.1),
    ]

    static let generic = ["serif", "sans-serif", "monospace", "cursive", "fantasy", "system-ui",
                          "ui-serif", "ui-sans-serif", "ui-monospace", "ui-rounded"]

    /// Whether the declaration at `index` is the rule's first enabled font
    /// declaration, the one the button sits on.
    static func carriesButton(_ properties: [DeveloperToolsSession.Detail], at index: Int) -> Bool {
        properties.firstIndex { $0.enabled && Self.properties.contains($0.name) } == index
    }

    /// The rule's declarations with `name` set to `value` where it already
    /// is, so the editor's button doesn't move rows under the popover, or
    /// appended; nil removes it.
    static func setting(_ name: String, _ value: String?, in properties: [DeveloperToolsSession.Detail]) -> [DeveloperToolsSession.Detail] {
        let added = value.map { DeveloperStyleEditing.parse("\(name): \($0)") } ?? []
        guard let at = properties.lastIndex(where: { $0.name == name }) else { return properties + added }
        var result = properties.enumerated().filter { $0.element.name != name || $0.offset == at }.map(\.element)
        let index = result.firstIndex { $0.name == name }!
        result.replaceSubrange(index...index, with: added)
        return result
    }

    /// The number and unit of a length, as "12.5" and "px"; nil for keywords
    /// and anything else a slider can't hold.
    static func split(_ value: String) -> (number: Double, unit: String)? {
        let text = value.trimmingCharacters(in: .whitespaces)
        guard let match = text.range(of: #"^-?(\d+\.?\d*|\.\d+)"#, options: .regularExpression),
              let number = Double(text[match]) else {
            return keyword(text).map { ($0, "") }
        }
        let unit = String(text[match.upperBound...]).lowercased()
        return unit.allSatisfy({ $0.isLetter || $0 == "%" }) ? (number, unit) : nil
    }

    /// font-weight keywords as numbers.
    static func keyword(_ text: String) -> Double? {
        ["normal": 400, "bold": 700][text.lowercased()]
    }

    static func css(_ number: Double, unit: String, step: Double) -> String {
        let rounded = step >= 1 ? (number / step).rounded() * step : (number * 100).rounded() / 100
        return DeveloperColorFormats.number(rounded) + unit
    }

    /// The comma-separated families, unquoted.
    static func families(_ value: String) -> [String] {
        developerSplitLayers(value).map {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
        }.filter { !$0.isEmpty }
    }

    /// A family list back to CSS: names with spaces quoted, generic names bare.
    static func familyCSS(_ families: [String]) -> String {
        families.filter { !$0.isEmpty }.map { name in
            generic.contains(name) || !name.contains(" ") ? name : "\"\(name)\""
        }.joined(separator: ", ")
    }
}

struct DeveloperFontEditorButton: View {
    let rule: DeveloperToolsSession.StyleRule
    /// Sets (value) or removes (nil) a declaration in the rule.
    let onSet: (String, String?) -> Void
    @State private var shown = false

    var body: some View {
        Button { shown = true } label: {
            Image(systemName: "textformat.size").font(.system(size: 9)).foregroundStyle(DeveloperToolsStyle.tint)
        }
        .buttonStyle(.plain)
        .help("Open font editor")
        .accessibilityLabel("Open font editor")
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            DeveloperFontEditorView(rule: rule, onSet: onSet)
        }
    }
}

struct DeveloperFontEditorView: View {
    let rule: DeveloperToolsSession.StyleRule
    let onSet: (String, String?) -> Void
    @State private var families: [String] = []
    @State private var values: [String: String] = [:]

    private static let installed: [String] = NSFontManager.shared.availableFontFamilies.sorted()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Font family").font(.system(size: 11, weight: .semibold))
            ForEach(families.indices, id: \.self) { index in
                HStack(spacing: 4) {
                    Text(index == 0 ? "Primary" : "Fallback \(index)").frame(width: 66, alignment: .leading)
                    TextField("Family", text: Binding(get: { families[index] }, set: { families[index] = $0 }))
                        .developerToolsField().frame(width: 140).onSubmit(commitFamilies)
                    Menu {
                        Section("Generic") { ForEach(DeveloperFontEditor.generic, id: \.self) { pick($0, at: index) } }
                        Section("Installed") { ForEach(Self.installed, id: \.self) { pick($0, at: index) } }
                    } label: { Image(systemName: "chevron.down") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("Choose a family")
                    Button { families.remove(at: index); commitFamilies() } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.plain).help("Remove this family")
                }
            }
            Button("Add fallback") { families.append(""); }.buttonStyle(.link).font(.system(size: 11))

            Divider()
            Text("CSS properties").font(.system(size: 11, weight: .semibold))
            Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 6) {
                ForEach(DeveloperFontEditor.metrics, id: \.name) { metric in row(metric) }
            }
        }
        .font(.system(size: 11))
        .padding(10)
        .frame(minWidth: 320)
        .onAppear(perform: load)
    }

    private func pick(_ name: String, at index: Int) -> some View {
        Button(name) { families[index] = name; commitFamilies() }
    }

    private func current(_ name: String) -> String? {
        rule.properties.last { $0.name == name && $0.enabled }?.value
    }

    private func load() {
        families = DeveloperFontEditor.families(current("font-family") ?? "")
        if families.isEmpty { families = [""] }
        for metric in DeveloperFontEditor.metrics { values[metric.name] = current(metric.name) ?? "" }
    }

    private func commitFamilies() {
        let css = DeveloperFontEditor.familyCSS(families)
        onSet("font-family", css.isEmpty ? nil : css)
    }

    private func set(_ metric: Metric, _ text: String) {
        values[metric.name] = text
        onSet(metric.name, text.trimmingCharacters(in: .whitespaces).isEmpty ? nil : text)
    }

    typealias Metric = DeveloperFontEditor.Metric

    private func row(_ metric: Metric) -> some View {
        let text = values[metric.name] ?? ""
        let parts = DeveloperFontEditor.split(text)
        let unit = parts?.unit ?? metric.units[0]
        let range = metric.ranges[unit] ?? metric.ranges[metric.units[0]]!
        return GridRow {
            Text(metric.title)
            DeveloperSlider(value: Binding(get: { Swift.min(Swift.max(parts?.number ?? range.lowerBound, range.lowerBound), range.upperBound) },
                                           set: { set(metric, DeveloperFontEditor.css($0, unit: unit, step: metric.step)) }),
                            in: range, step: metric.step)
                .frame(width: 110)
                .disabled(parts == nil && !text.isEmpty)
            TextField(metric.title, text: Binding(get: { values[metric.name] ?? "" }, set: { values[metric.name] = $0 }))
                .developerToolsField().frame(width: 64)
                .onSubmit { set(metric, values[metric.name] ?? "") }
            if metric.units.count > 1 {
                Picker("Unit", selection: Binding(get: { unit }, set: { new in
                    let number = parts?.number ?? (metric.ranges[new] ?? range).lowerBound
                    set(metric, DeveloperFontEditor.css(number, unit: new, step: metric.step))
                })) {
                    ForEach(metric.units, id: \.self) { Text($0.isEmpty ? "—" : $0).tag($0) }
                }
                .labelsHidden().frame(width: 60)
            } else {
                Color.clear.frame(width: 60, height: 1)
            }
        }
    }
}
