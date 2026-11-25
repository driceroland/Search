import AppKit
import SwiftUI

// Chrome DevTools' Quick source (More tools › Quick source): the file in
// front in Sources, shown in the drawer while another panel is in front,
// following as Sources' tab changes. Search's is read-only: Sources' own
// code view (SourceCodeView) with the same highlighting, ⌘P to open
// another file there, ⌃G and ⇧⌘O to move about, ⌘F to find.

/// The drawer's own copy of the file in front: its own document, so its
/// scroll and caret don't move Sources' view of the same file.
@MainActor
final class DeveloperQuickSource {
    static func of(_ session: DeveloperToolsSession) -> DeveloperQuickSource {
        DeveloperSessionModels.model(for: session) { _ in DeveloperQuickSource() }
    }

    /// The last few files' documents, so stepping between tabs keeps each
    /// one's place.
    private var documents: [(url: String, text: String, document: SourceDocument)] = []
    private static let kept = 8

    func document(for resource: SourceResource, text: String?) -> SourceDocument? {
        if let index = documents.firstIndex(where: { $0.url == resource.url && (text == nil || $0.text == text) }) {
            return documents[index].document
        }
        guard let text else { return nil }
        let document = SourceDocument(text: text, url: resource.url, type: resource.type)
        documents.removeAll { $0.url == resource.url }
        documents.append((resource.url, text, document))
        if documents.count > Self.kept { documents.removeFirst(documents.count - Self.kept) }
        return document
    }
}

struct DeveloperQuickSourceView: View {
    @ObservedObject var session: DeveloperToolsSession
    @ObservedObject private var overrides = DeveloperLocalOverrides.shared

    init(session: DeveloperToolsSession) {
        self.session = session
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            code
        }
        .accessibilityIdentifier("developer-quick-source")
    }

    private var header: some View {
        HStack(spacing: DeveloperToolsStyle.controlSpacing) {
            if let resource = session.sourceResource {
                Image(systemName: resource.type == DeveloperSourceMaps.authoredType
                      ? DeveloperSourceMaps.icon(for: resource.url) : "doc.plaintext")
                    .foregroundStyle(.secondary)
                Text(SourceTree.fileName(resource.url))
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text(resource.url)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(resource.url)
                Spacer(minLength: 0)
                Text("Read-only").foregroundStyle(.tertiary)
                DeveloperPanelIcon(symbol: "arrow.up.forward.square", title: "Show in Sources panel") {
                    session.select(.sources)
                }
            } else {
                Text("Quick source").foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, DeveloperToolsStyle.gutter)
        .frame(height: DeveloperToolsStyle.toolbarHeight)
        .background(DeveloperToolsStyle.chrome)
    }

    @ViewBuilder private var code: some View {
        if let resource = session.sourceResource,
           let document = DeveloperQuickSource.of(session).document(
               for: resource, text: overrides.activeContent(for: resource.url) ?? session.source) {
            SourceCodeView(document: document, markers: [:], editable: false, actions: actions(document),
                           reveal: reveal(document), moved: { document.caret = $0.offset })
                .id(ObjectIdentifier(document))
        } else {
            Text(session.sourceResource == nil
                 ? "Open a file in the Sources panel, or press ⌘P in the Sources panel’s editor, to see it here."
                 : "Loading source")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// A line asked for (⌃G, a ⌘P `file:line`, a link) in this file. The
    /// Sources panel marks it seen when it shows it; here it's only followed.
    private func reveal(_ document: SourceDocument) -> SourceCodeView.Reveal? {
        guard let asked = session.sourceReveal, DeveloperDebugger.sameScript(asked.url, document.url),
              !document.formatting else { return nil }
        return .init(line: document.shownLine(forOriginal: asked.line),
                     column: document.pretty ? nil : asked.column, serial: asked.serial)
    }

    // MARK: Quick open

    private var openable: [SourceResource] {
        session.resources + session.contentScripts + session.sourceMaps.authoredResources + session.workerScripts
    }

    /// The files ⌘P lists, as Sources' editor lists them.
    private var quickOpenFiles: [QuickOpenFile] {
        var files = openable.map { resource in
            let name = SourceTree.fileName(resource.url)
            let detail: String
            if resource.url.hasPrefix("http") {
                detail = String(resource.url.prefix { $0 != "?" }.dropLast(name.count))
                    .replacingOccurrences(of: "https://", with: "")
                    .replacingOccurrences(of: "http://", with: "")
            } else {
                detail = resource.url
            }
            return QuickOpenFile(id: "r:" + resource.id, name: name, detail: detail)
        }
        files += DeveloperSnippets.shared.snippets.map { QuickOpenFile(id: "s:" + $0.name, name: $0.name, detail: "Snippets") }
        return files
    }

    /// A ⌘P choice becomes the file in front, here and in Sources, which
    /// stays where it is behind the panel shown.
    private func open(_ id: String, line: Int?, column: Int?) {
        let url: String
        if id.hasPrefix("s:"), let snippet = DeveloperSnippets.shared.snippet(named: String(id.dropFirst(2))) {
            session.openSnippet(snippet.name, text: snippet.text)
            url = "snippet:///" + snippet.name
        } else if let resource = openable.first(where: { "r:" + $0.id == id }) {
            if session.sourceResource != resource { session.openSource(resource) }
            DeveloperSourceTabs.of(session).note(resource)
            url = resource.url
        } else {
            return
        }
        if let line { session.revealSource(url: url, line: max(1, line), column: column.map { max(1, $0) }, showPanel: false) }
    }

    private func actions(_ document: SourceDocument) -> SourceEditorActions {
        let actions = SourceEditorActions()
        let session = session
        actions.url = document.url
        actions.isPretty = document.pretty
        actions.canPrettyPrint = document.language.canPrettyPrint
        actions.togglePretty = { document.togglePretty() }
        actions.evaluate = { session.evaluate($0) }
        actions.addWatch = { session.debugger.addWatch($0) }
        let view = self
        actions.files = { view.quickOpenFiles }
        actions.openFile = { view.open($0, line: $1, column: $2) }
        return actions
    }
}
