import AppKit
import SwiftUI

extension DeveloperToolsSession {
    /// A document's or shadow root's adoptedStyleSheets, each as its rules'
    /// text (nil where they can't be read); with `text`, sheet `index` is
    /// first replaced through `replaceSync`.
    func adoptedSheets(of root: Int, replacing index: Int = -1, with text: String? = nil) async throws -> [[String]?] {
        let raw = try await elementsBridge("return await perchElements.adoptedSheets(node, target, index, text);", [
            "node": root, "target": domTargetID as Any? ?? NSNull(), "index": index, "text": text as Any? ?? NSNull(),
        ]) as? [Any] ?? []
        return raw.map { $0 as? [String] }
    }
}

/// A row for adoptedStyleSheets, which aren't nodes, so it has none of a
/// node row's editing, drag, highlight or breakpoints: Chrome's
/// `#adopted-style-sheets` (opens and closes) or one sheet as `<style>`.
struct DeveloperAdoptedSheetRow: View {
    let row: DeveloperDOMTreeModel.Row
    let line: String
    let selected: Bool
    let wraps: Bool
    let width: CGFloat
    let toggle: () -> Void
    let select: () -> Void
    @State private var hovering = false

    private var height: CGFloat { DeveloperDOMTreeView.rowHeight }

    private var text: AttributedString {
        guard line.hasPrefix("<style>"), line.hasSuffix("</style>") else {
            var plain = AttributedString(line)
            plain.foregroundColor = .secondary
            return plain
        }
        var open = AttributedString("<style>"), close = AttributedString("</style>")
        open.foregroundColor = DeveloperToolsStyle.tint
        close.foregroundColor = DeveloperToolsStyle.tint
        return open + AttributedString(String(line.dropFirst(7).dropLast(8))) + close
    }

    var body: some View {
        HStack(alignment: .top, spacing: 1) {
            if row.expandable {
                DeveloperPanelIcon(symbol: row.expanded ? "chevron.down" : "chevron.right",
                                   title: row.expanded ? "Collapse node" : "Expand node", size: height, action: toggle)
            } else {
                Color.clear.frame(width: height, height: height)
            }
            Text(text).font(DeveloperToolsStyle.code).lineLimit(wraps ? nil : 1)
                .frame(minHeight: height, alignment: .topLeading)
            Spacer(minLength: 0)
        }
        .frame(minHeight: height, maxHeight: wraps ? nil : height, alignment: .top)
        .padding(.leading, DeveloperDOMTreeView.leading(row.depth))
        .padding(.trailing, DeveloperToolsStyle.gutter)
        .modifier(DeveloperDOMRowWidth(depth: row.depth, wraps: wraps, width: width))
        .background(selected ? DeveloperToolsStyle.selected : hovering ? Palette.ink.opacity(0.06) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            if (NSApp.currentEvent?.clickCount ?? 1) >= 2, row.expandable { toggle() } else { select() }
        }
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(line)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A selected adopted sheet's rules, one editable section each as in
/// Styles: an edit writes the whole sheet back with `replaceSync` (an empty
/// sheet gets one section to add rules in). Read-only where the rules
/// can't be read.
struct DeveloperAdoptedSheetPane: View {
    @ObservedObject var session: DeveloperToolsSession
    @ObservedObject var elements: DeveloperElementsState
    let sheet: DeveloperDOMTreeModel.AdoptedSheet
    @State private var drafts: [String] = []
    @State private var writing: Task<Void, Never>?

    private var rules: [String]? {
        guard let index = sheet.index, let sheets = elements.adoptedSheets[sheet.root], sheets.indices.contains(index)
        else { return nil }
        return sheets[index]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("adoptedStyleSheets[\(sheet.index ?? 0)]").foregroundStyle(.secondary)
                    .padding(.horizontal, DeveloperToolsStyle.gutter).padding(.vertical, 4)
                Divider()
                if rules == nil {
                    Text("This sheet’s rules can’t be read").foregroundStyle(.secondary)
                        .padding(DeveloperToolsStyle.gutter)
                }
                ForEach(drafts.indices, id: \.self) { index in
                    TextField("", text: Binding(get: { drafts.indices.contains(index) ? drafts[index] : "" },
                                                set: { drafts[index] = $0; writeSoon() }), axis: .vertical)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, DeveloperToolsStyle.gutter).padding(.vertical, 4)
                        .accessibilityLabel("Rule \(index + 1)")
                    Divider()
                }
            }
        }
        .font(DeveloperToolsStyle.code)
        .onAppear(perform: reset)
        .onChange(of: sheet.id) { _, _ in reset() }
    }

    private func reset() {
        writing?.cancel()
        drafts = rules.map { $0.isEmpty ? [""] : $0 } ?? []
    }

    /// Typing pauses a moment, then the sheet is replaced and read back.
    private func writeSoon() {
        writing?.cancel()
        let text = drafts.joined(separator: "\n")
        writing = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let index = sheet.index else { return }
            do { elements.adoptedSheets[sheet.root] = try await session.adoptedSheets(of: sheet.root, replacing: index, with: text) }
            catch { session.message = error.localizedDescription }
        }
    }
}
