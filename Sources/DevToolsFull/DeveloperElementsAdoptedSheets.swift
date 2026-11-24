import AppKit
import SwiftUI

extension DeveloperToolsSession {
    /// Read a document's or shadow root's adoptedStyleSheets, or replace one
    /// after an edit. Neither operation installs a script, handler or global.
    func adoptedSheets(of root: Int, replacing index: Int = -1, with text: String? = nil) async throws -> [[String]?] {
        guard let raw = try await inspectElementValue(root, function: Self.adoptedSheetsScript,
                                                      arguments: [index, text as Any? ?? NSNull()]) as? [Any]
        else { return [] }
        return raw.map { $0 as? [String] }
    }

    /// Execute a bounded, built-in inspector operation against a current
    /// DOM node. Release the same target's remote object even if an edit or
    /// navigation invalidates the result.
    func inspectElementValue(_ id: Int, function: String, arguments: [Any]) async throws -> Any? {
        guard ready, !isClosed else { return nil }
        let target = domTargetID, revision = domRevision
        let reply = try await command("DOM.resolveNode", ["nodeId": id, "objectGroup": "search-elements"], targetID: target)
        guard let objectID = reply.object("object")?.string("objectId") else { return nil }
        defer {
            Task { _ = try? await command("Runtime.releaseObject", ["objectId": objectID], targetID: target) }
        }
        guard !Task.isCancelled, !isClosed, revision == domRevision else { return nil }
        let result = try await command("Runtime.callFunctionOn", [
            "objectId": objectID, "functionDeclaration": function,
            "arguments": arguments.map { ["value": $0] }, "returnByValue": true,
            "doNotPauseOnExceptionsAndMuteConsole": true,
        ], targetID: target)
        guard !Task.isCancelled, !isClosed, revision == domRevision else { return nil }
        if result.bool("wasThrown") == true {
            throw DeveloperElementInspectionError(message: result.object("result")?.string("description"))
        }
        return result.object("result")?["value"]
    }

    private static let adoptedSheetsScript = ##"""
    function(index, text) {
        const sheets = Array.from(this.adoptedStyleSheets ?? []).slice(0, 100);
        if (text != null && sheets[index])
            sheets[index].replaceSync(text);
        let remaining = 256 * 1024;
        return sheets.map((sheet) => {
            try {
                const rules = [];
                if (sheet.cssRules.length > 500)
                    return null;
                for (const rule of sheet.cssRules) {
                    const css = rule.cssText;
                    remaining -= css.length;
                    if (remaining < 0)
                        return null;
                    rules.push(css);
                }
                return rules;
            } catch {
                return null;
            }
        });
    }
    """##

    /// Use an inert element, not a clone that could fetch a resource or run
    /// a custom element constructor. A temporary sibling keeps the selected
    /// element's containing block, and inherited CSS values are copied.
    static let mathStepsScript = ##"""
    function(property, steps) {
        if (this.nodeType !== 1 || !this.parentNode)
            return null;
        const view = this.ownerDocument.defaultView;
        const computed = view.getComputedStyle(this);
        const probe = this.ownerDocument.createElement("div");
        probe.style.setProperty("visibility", "hidden", "important");
        probe.style.setProperty("pointer-events", "none", "important");
        for (const name of ["font", "font-size", "line-height", "writing-mode", "direction"])
            probe.style.setProperty(name, computed.getPropertyValue(name), "important");
        for (const name of Array.from(computed).filter((name) => name.startsWith("--")).slice(0, 64))
            probe.style.setProperty(name, computed.getPropertyValue(name));
        try {
            this.after(probe);
            return steps.slice(0, 40).map((step) => {
                const value = `calc(${step})`;
                if (value.length > 4096 || !view.CSS.supports(property, value))
                    return null;
                probe.style.setProperty(property, value, "important");
                return view.getComputedStyle(probe).getPropertyValue(property).trim() || null;
            });
        } finally {
            probe.remove();
        }
    }
    """##
}

private struct DeveloperElementInspectionError: LocalizedError {
    let message: String?
    var errorDescription: String? { message ?? "The page refused the Elements operation." }
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
        .onDisappear { writing?.cancel() }
    }

    private func reset() {
        writing?.cancel()
        drafts = rules.map { $0.isEmpty ? [""] : $0 } ?? []
    }

    /// Typing pauses a moment, then the sheet is replaced and read back.
    private func writeSoon() {
        writing?.cancel()
        let text = drafts.joined(separator: "\n")
        let revision = session.domRevision
        writing = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, revision == session.domRevision, let index = sheet.index else { return }
            do {
                let sheets = try await session.adoptedSheets(of: sheet.root, replacing: index, with: text)
                guard !Task.isCancelled, revision == session.domRevision else { return }
                elements.adoptedSheets[sheet.root] = sheets
            } catch { session.message = error.localizedDescription }
        }
    }
}
