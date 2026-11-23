import Foundation

/// Elements › Event Listeners: Remove, the Breakpoint toggle and the
/// handler's source, as Chrome DevTools offers them per listener.
extension DeveloperToolsSession {
    /// Remove: the listener taken off its node (or window), then the list
    /// read again. WebKit's DOM domain has no removeEventListener, so the
    /// page removes the handler that getEventListeners lists for it.
    func removeListener(_ listener: EventListener) {
        guard listener.id > 0, let selected = selectedNode else { return }
        let id = listener.id
        run(inCurrentDocument: true) { session in
            _ = try await session.elementsBridge("return await perchElements.listener(id, node, target, action);", [
                "id": id, "node": selected, "target": session.domTargetID as Any? ?? NSNull(), "action": "remove",
            ])
            session.elements.listenerBreakpoints.remove(id)
            session.loadListeners()
        }
    }

    /// Breakpoint: the debugger pauses in the listener's handler when its
    /// event is dispatched (WebKit's DOM.setBreakpointForEventListener).
    func setListenerBreakpoint(_ listener: EventListener, on: Bool) {
        guard listener.id > 0 else { return }
        let id = listener.id
        if on { elements.listenerBreakpoints.insert(id) } else { elements.listenerBreakpoints.remove(id) }
        run(inCurrentDocument: true) { session in
            do {
                _ = try await session.command(on ? "DOM.setBreakpointForEventListener" : "DOM.removeBreakpointForEventListener",
                                              ["eventListenerId": id], targetID: session.domTargetID)
            } catch {
                if on { session.elements.listenerBreakpoints.remove(id) } else { session.elements.listenerBreakpoints.insert(id) }
                throw error
            }
        }
    }

    /// Which of the listeners shown have a breakpoint, as WebKit reports
    /// them (hasBreakpoint), for the toggles' state.
    func readListenerBreakpoints() async {
        guard ready, let selected = selectedNode, nodes[selected]?.type == 1 else { return }
        let ancestors = listenerAncestors
        guard let reply = try? await command("DOM.getEventListenersForNode",
                                             ["nodeId": selected, "includeAncestors": ancestors], targetID: domTargetID),
              selectedNode == selected else { return }
        let raw = reply["listeners"] as? [[String: Any]] ?? []
        elements.listenerBreakpoints = Set(raw.compactMap { item in
            item["hasBreakpoint"] as? Bool == true ? item["eventListenerId"] as? Int : nil
        })
    }

    /// The handler's source, for the listener's expanded preview; nil when
    /// the page no longer has it.
    func listenerSource(_ listener: EventListener) async -> String? {
        guard ready, listener.id > 0, let selected = selectedNode else { return nil }
        return try? await elementsBridge("return await perchElements.listener(id, node, target, action);", [
            "id": listener.id, "node": selected, "target": domTargetID as Any? ?? NSNull(), "action": "source",
        ]) as? String
    }
}

/// How a listener's handler is previewed when its row is expanded.
enum DeveloperListenerPreview {
    /// The source's first line, as Chrome shows a function collapsed:
    /// trimmed and cut at `limit` characters with an ellipsis.
    static func firstLine(_ source: String, limit: Int = 120) -> String {
        let line = source.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)) + "…"
    }
}
