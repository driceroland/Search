import SwiftUI

/// Read the window's own listeners from WebKit's DOM protocol.
@MainActor
enum DeveloperGlobalListeners {
    static func read(_ session: DeveloperToolsSession) async throws -> [DeveloperToolsSession.EventListener] {
        let revision = session.domRevision
        let raw = try await session.elementsBridge("""
            const document = await searchElements.documentRoot(target);
            return document ? await searchInspector.eventListeners(document.nodeId, target, true, false) : [];
            """, ["target": session.domTargetID as Any? ?? NSNull()]) as? [[String: Any]] ?? []
        guard session.domRevision == revision else { return [] }
        return raw.compactMap(DeveloperToolsSession.EventListener.init).filter { $0.target == "window" }
    }

    static func remove(_ listener: DeveloperToolsSession.EventListener, from session: DeveloperToolsSession,
                       revision: Int) async throws {
        guard listener.id > 0, revision == session.domRevision else { return }
        _ = try await session.elementsBridge("""
            const document = await searchElements.documentRoot(target);
            if (!document) return false;
            const current = await searchInspector.eventListeners(document.nodeId, target, true, false);
            if (!current.some(listener => listener.id === id && listener.target === "window")) return false;
            return await searchElements.listener(id, document.nodeId, target, "remove");
            """, ["target": session.domTargetID as Any? ?? NSNull(), "id": listener.id])
    }
}

struct DeveloperGlobalListenersPane: View {
    @ObservedObject var session: DeveloperToolsSession
    @State private var listeners: [DeveloperToolsSession.EventListener] = []
    @State private var revision: Int?
    @State private var refresh = 0

    var body: some View {
        let groups = Dictionary(grouping: listeners, by: \.type)
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
        .task(id: [session.domRevision, refresh]) {
            let document = session.domRevision
            let rows = try? await DeveloperGlobalListeners.read(session)
            guard !Task.isCancelled, document == session.domRevision else { return }
            listeners = rows ?? []
            revision = document
        }
        .accessibilityIdentifier("developer-global-listeners")
    }

    private func row(_ listener: DeveloperToolsSession.EventListener) -> some View {
        let link = session.listenerLink(listener)
        return HStack(spacing: 6) {
            Text(listener.handler.isEmpty ? "(anonymous)" : listener.handler)
                .font(DeveloperToolsStyle.code).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 4)
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
            Button("Remove") {
                guard let revision else { return }
                Task {
                    try? await DeveloperGlobalListeners.remove(listener, from: session, revision: revision)
                    refresh += 1
                }
            }
        }
    }
}
