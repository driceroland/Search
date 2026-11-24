import SwiftUI

// Sources › Global Listeners, as in Chrome: the event listeners on the
// page's `window`, by type, each with its handler's place (opening it in
// Sources) and Remove. WebKit lists them with the document's listeners
// (DOM.getEventListenersForNode with ancestors, marked onWindow).

extension DeveloperToolsSession {
    func loadGlobalListeners() {
        guard let document = root else { globalListeners = []; return }
        run(inCurrentDocument: true) { session in
            let raw = try await session.bridge("return await perchInspector.eventListeners(node, target, true, false);", [
                "node": document, "target": session.domTargetID as Any? ?? NSNull(),
            ]) as? [[String: Any]] ?? []
            session.globalListeners = Self.onWindow(raw.compactMap(EventListener.init))
        }
    }

    /// The window's own listeners from a list with the document's.
    nonisolated static func onWindow(_ listeners: [EventListener]) -> [EventListener] {
        listeners.filter { $0.target == "window" }
    }

    func removeGlobalListener(_ listener: EventListener) {
        guard listener.id > 0, let document = root else { return }
        let id = listener.id
        run(inCurrentDocument: true) { session in
            _ = try await session.elementsBridge("return await perchElements.listener(id, node, target, action);", [
                "id": id, "node": document, "target": session.domTargetID as Any? ?? NSNull(), "action": "remove",
            ])
            session.loadGlobalListeners()
        }
    }
}

struct DeveloperGlobalListenersPane: View {
    @ObservedObject var session: DeveloperToolsSession

    var body: some View {
        let groups = Dictionary(grouping: session.globalListeners, by: \.type)
        VStack(alignment: .leading, spacing: 0) {
            if groups.isEmpty {
                Text("No event listeners").foregroundStyle(.secondary)
                    .padding(.horizontal, DeveloperToolsStyle.gutter).padding(.vertical, 4)
            }
            ForEach(groups.keys.sorted(), id: \.self) { type in
                Text(type).fontWeight(.semibold)
                    .padding(.horizontal, DeveloperToolsStyle.gutter)
                    .frame(height: DeveloperToolsStyle.rowHeight)
                ForEach(groups[type] ?? []) { listener in row(listener) }
            }
        }
        .font(.system(size: 11))
        .task(id: session.root) { session.loadGlobalListeners() }
        .accessibilityIdentifier("developer-global-listeners")
    }

    private func row(_ listener: DeveloperToolsSession.EventListener) -> some View {
        let link = session.listenerLink(listener)
        return HStack(spacing: 6) {
            Text("window").foregroundStyle(DeveloperToolsStyle.tint)
            Text(listener.handler.isEmpty ? "(anonymous)" : listener.handler)
                .font(DeveloperToolsStyle.code).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 4)
            Button("Remove") { session.removeGlobalListener(listener) }
                .buttonStyle(.plain).foregroundStyle(DeveloperToolsStyle.tint).font(.system(size: 10))
                .help("Remove this event listener")
            if !listener.url.isEmpty {
                Button(ConsoleFormat.location(link.url, line: link.line)) { session.revealListener(listener) }
                    .buttonStyle(.plain).underline().foregroundStyle(.secondary).font(.system(size: 10))
                    .lineLimit(1)
                    .help(link.url)
            }
        }
        .padding(.leading, DeveloperToolsStyle.gutter + 10).padding(.trailing, DeveloperToolsStyle.gutter)
        .frame(minHeight: DeveloperToolsStyle.rowHeight)
        .contextMenu {
            Button("Reveal in Sources panel") { session.revealListener(listener) }.disabled(listener.url.isEmpty)
            Button("Remove") { session.removeGlobalListener(listener) }
        }
    }
}
