import Foundation

/// Elements checks exercise the installed package's own inspector session.
extension DeveloperToolsSession {
    func automateElements(_ action: String, _ arguments: [String: Any]) async -> [String: Any]? {
        switch action {
        case "elements.adoptedSheets":
            return await automateAdoptedSheets(arguments)
        case "elements.styleHints":
            guard let selectedNode, let property = arguments.string("property"), let value = arguments.string("value"),
                  let reference = arguments.string("reference") else { return ["error": "no selected style"] }
            let steps = DeveloperStyleEditing.mathSteps(value)
            let results = await styleMathResults(of: selectedNode, property: property, steps: steps)
            let used = styles.first { $0.name == property }?.value
            return ["chain": variableChain(reference), "steps": steps,
                    "math": DeveloperStyleEditing.mathLines(steps, results: results, used: used)]
        case "elements.issueMarks":
            guard let node = arguments.int("node") else { return ["error": "no node"] }
            let issues = DeveloperIssuesModel.model(for: self)
            issues.viewAppeared()
            defer { issues.viewDisappeared() }
            _ = await waitForElements { issues.marks[node] != nil }
            let marks = issues.marks[node] ?? []
            return ["attributes": marks.compactMap(\.attribute), "titles": marks.map(\.title)]
        case "elements.styleHelpers":
            let contrast = DeveloperContrastFix.apca(.black, .white)
            let flow = DeveloperLayoutEditor.autoFlow("column dense")
            let order = DeveloperStyleEditing.setting("color", to: ["color"], in: ["display", "color", "gap", "color"]) { $0 }
            return ["apca": contrast, "dense": flow.dense, "direction": flow.direction ?? "",
                    "regexp": DeveloperStyleFilter.matches("COLOR: blue", "/^color:.*blue$/"),
                    "order": order]
        default:
            return nil
        }
    }

    private func automateAdoptedSheets(_ arguments: [String: Any]) async -> [String: Any] {
        select(.elements)
        guard await waitForElements({ self.root != nil }), let document = root else { return ["error": "no document"] }
        let target = arguments.string("shadowHost")
        var sheetRoot = document
        if let target {
            guard let result = try? await command("DOM.querySelector", ["nodeId": document, "selector": target], targetID: domTargetID),
                  let host = result.int("nodeId"), host > 0 else { return ["error": "no shadow host"] }
            selectNode(host)
            guard await waitForElements({ self.nodes[host] != nil }), let node = nodes[host] else { return ["error": "no shadow host"] }
            expand(node)
            func shadowRoot() -> Int? { nodes[host]?.children.first { nodes[$0]?.shadowRootType != nil } }
            guard await waitForElements({ shadowRoot() != nil }), let shadow = shadowRoot(), let root = nodes[shadow] else {
                return ["error": "no shadow root"]
            }
            expand(root)
            sheetRoot = shadow
        }
        do {
            let sheets = try await adoptedSheets(of: sheetRoot, replacing: arguments.int("index") ?? -1, with: arguments.string("text"))
            let rows = DeveloperDOMTreeModel.flatten(nodes: nodes, root: document, expanded: expanded,
                                                     adopted: [sheetRoot: sheets], adoptedOpen: [sheetRoot])
            return ["sheets": sheets.map { $0 ?? [] }, "rows": rows.compactMap { $0.sheet?.label }]
        } catch {
            return ["error": error.localizedDescription]
        }
    }

    private func waitForElements(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }
}
