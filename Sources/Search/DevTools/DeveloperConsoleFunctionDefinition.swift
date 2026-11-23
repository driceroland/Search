import Foundation

/// The console's "Show function definition" (Chrome's object menu on a
/// function): where the function was written, from
/// `Debugger.getFunctionDetails`, opened in Sources at that line.
extension DeveloperToolsSession {
    /// Where a function was defined: its script's address and the 1-based
    /// line and column, moved to the authored file when the script has a
    /// source map, as Chrome reveals it.
    struct FunctionDefinition: Equatable {
        let url: String
        let line: Int
        let column: Int
    }

    func consoleFunctionDefinition(objectId: String, targetID: String?) async throws -> FunctionDefinition? {
        let reply = try await command("Debugger.getFunctionDetails", ["functionId": objectId], targetID: targetID)
        guard let details = reply["details"] as? [String: Any],
              let location = details["location"] as? [String: Any],
              let scriptID = location["scriptId"] as? String else { return nil }
        let line = location["lineNumber"] as? Int ?? 0
        let column = location["columnNumber"] as? Int ?? 0
        // The frontend's debugger knows every parsed script by its id.
        let url = try await bridge("""
            const owner = target == null ? WI.mainTarget
                : (WI.targetManager?.targetForIdentifier?.(target) ?? WI.mainTarget);
            const script = WI.debuggerManager?.scriptForIdentifier?.(scriptId, owner)
                ?? WI.debuggerManager?.scriptForIdentifier?.(scriptId, WI.mainTarget);
            return script?.url || script?.sourceURL || "";
            """, ["scriptId": scriptID, "target": targetID as Any? ?? NSNull()]) as? String ?? ""
        guard !url.isEmpty else { return nil }
        if let original = sourceMaps.original(url: url, line: line, column: column) {
            return FunctionDefinition(url: original.url, line: original.line + 1, column: original.column + 1)
        }
        return FunctionDefinition(url: url, line: line + 1, column: column + 1)
    }

    /// Opens the function's definition in Sources, as Chrome's menu item does.
    func showConsoleFunctionDefinition(_ object: ConsoleRemoteObject, targetID: String?) {
        guard object.type == "function", let id = object.objectId else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                guard let definition = try await self.consoleFunctionDefinition(objectId: id, targetID: targetID) else {
                    self.message = "No function definition found."
                    return
                }
                self.revealSource(url: definition.url, line: definition.line, column: definition.column)
            } catch {
                self.message = error.localizedDescription
            }
        }
    }
}
