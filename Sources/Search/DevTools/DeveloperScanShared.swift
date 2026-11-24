import Foundation

// A page scan run through the inspector (CSS overview, Lighthouse, Issues):
// the script leaves an object in the page holding {elements, data}; the
// data is read back and the holder kept, so one of its elements can be
// drawn on the page or revealed in Elements by its index.
extension DeveloperToolsSession {
    /// Evaluates `source` in `group`: the holder's object id and its data.
    /// `refused` is the error when the script threw without saying why,
    /// `tooLarge` when the data couldn't be read back.
    func scanPage(_ source: String, group: String, target: String?, refused: String,
                  tooLarge: String) async throws -> (id: String, data: [String: Any]) {
        let reply = try await command("Runtime.evaluate", [
            "expression": source, "objectGroup": group,
            "doNotPauseOnExceptionsAndMuteConsole": true, "includeCommandLineAPI": false,
        ], targetID: target)
        if reply.flag("wasThrown") {
            throw DeveloperPanelError(reply.object("result")?.string("description") ?? refused)
        }
        guard let id = reply.object("result")?.string("objectId") else {
            throw DeveloperPanelError("The page sent nothing back.")
        }
        let data = try await command("Runtime.callFunctionOn", [
            "objectId": id, "functionDeclaration": "function() { return this.data; }", "returnByValue": true,
        ], targetID: target)
        guard let value = data.object("result")?.object("value") else {
            _ = try? await command("Runtime.releaseObject", ["objectId": id], targetID: target)
            throw DeveloperPanelError(tooLarge)
        }
        return (id, value)
    }

    /// The node id of the holder's element at `index`, pushed to the inspector.
    func scannedNode(holder: String, index: Int, target: String?) async -> Int? {
        guard let reply = try? await command("Runtime.callFunctionOn", [
            "objectId": holder, "functionDeclaration": "function(index) { return this.elements[index] || null; }",
            "arguments": [["value": index]],
        ], targetID: target),
            let object = reply.object("result")?.string("objectId") else { return nil }
        let node = try? await command("DOM.requestNode", ["objectId": object], targetID: domTargetID)
        _ = try? await command("Runtime.releaseObject", ["objectId": object], targetID: target)
        guard let id = (node?["nodeId"] as? NSNumber)?.intValue, id > 0 else { return nil }
        return id
    }

    /// The node ids of the holder's elements at `indexes`, by index, with
    /// one script run for them all.
    func scannedNodes(holder: String, indexes: [Int], target: String?) async -> [Int: Int] {
        guard let list = try? await command("Runtime.callFunctionOn", [
            "objectId": holder, "functionDeclaration": "function(indexes) { return indexes.map(i => this.elements[i] || null); }",
            "arguments": [["value": indexes]],
        ], targetID: target).object("result")?.string("objectId") else { return [:] }
        let reply = try? await command("Runtime.getProperties", ["objectId": list, "ownProperties": true], targetID: target)
        var found: [Int: Int] = [:]
        for property in reply?.objects("properties") ?? reply?.objects("result") ?? [] {
            guard let position = property.string("name").flatMap(Int.init), indexes.indices.contains(position),
                  let object = property.object("value")?.string("objectId") else { continue }
            let node = try? await command("DOM.requestNode", ["objectId": object], targetID: domTargetID)
            _ = try? await command("Runtime.releaseObject", ["objectId": object], targetID: target)
            if let id = (node?["nodeId"] as? NSNumber)?.intValue, id > 0 { found[indexes[position]] = id }
        }
        _ = try? await command("Runtime.releaseObject", ["objectId": list], targetID: target)
        return found
    }

    /// A scanned element hovered in a list: drawn on the page as Elements
    /// draws a hovered node, after a moment. The task is the caller's to cancel.
    func hoverScanned(_ node: @escaping @MainActor () async -> Int?) -> Task<Void, Never> {
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(40))
            guard !Task.isCancelled, let id = await node(), !Task.isCancelled else { return }
            self?.highlightNode(id)
        }
    }

    /// Shows a scanned element in the Elements panel. Entering Elements
    /// reads the document afresh, which renumbers WebKit's nodes, so the
    /// node is asked for once that is done (as the Console's reveal does).
    func revealScanned(_ node: @escaping @MainActor () async -> Int?) {
        hideHighlight()
        let switching = panel != .elements
        let before = root
        select(.elements)
        Task {
            for _ in 0..<40 where switching {
                guard root == before || root == nil else { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard let id = await node() else { return }
            for _ in 0..<40 where nodes[id] == nil {
                try? await Task.sleep(for: .milliseconds(50))
            }
            selectNode(id)
        }
    }
}
