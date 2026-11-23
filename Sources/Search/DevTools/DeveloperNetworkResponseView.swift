import AppKit
import SwiftUI

/// The Response tab, as Chrome draws it: the body read-only in the same
/// code view Sources uses (line numbers, colours by token, ⌘F to find in
/// the response while it has the keyboard), and a footer with the `{}`
/// button that pretty-prints minified JavaScript, CSS, HTML or JSON and
/// the caret's line and column. A large body costs no more than in
/// Sources: tokens are worked out off the main thread and painted only
/// where the view is looking.
struct DeveloperResponseSourceView: View {
    @StateObject private var document: SourceDocument
    @State private var position = SourceTextView.Position()
    private let actions: SourceEditorActions

    init(text: String, url: String, mimeType: String?, evaluate: @escaping (String) -> Void) {
        _document = StateObject(wrappedValue: SourceDocument(text: text, url: url,
                                                             type: Self.resourceType(mimeType: mimeType)))
        let actions = SourceEditorActions()
        actions.evaluate = evaluate
        actions.canPrettyPrint = true
        actions.canSetBreakpoints = false
        self.actions = actions
    }

    /// The kind of resource SourceLanguage.detect expects, from the
    /// response's MIME type, for a URL whose path doesn't say.
    static func resourceType(mimeType: String?) -> String {
        let mime = mimeType?.lowercased() ?? ""
        if mime.contains("javascript") || mime.contains("ecmascript") { return "Script" }
        if mime.contains("css") { return "Stylesheet" }
        if mime.contains("html") || mime.contains("xml") || mime.contains("svg") { return "Document" }
        return ""
    }

    var body: some View {
        VStack(spacing: 0) {
            SourceCodeView(
                document: document,
                markers: [:],
                editable: false,
                actions: currentActions,
                moved: { position = $0; document.caret = $0.offset }
            )
            .accessibilityIdentifier("developer-network-response-source")
            Rectangle().fill(DeveloperToolsStyle.rule.opacity(0.55)).frame(height: 1)
            footer
        }
    }

    private var currentActions: SourceEditorActions {
        let document = document
        actions.isPretty = document.pretty
        actions.canPrettyPrint = document.language.canPrettyPrint
        actions.togglePretty = { document.togglePretty() }
        return actions
    }

    private var footer: some View {
        HStack(spacing: DeveloperToolsStyle.gutter) {
            Button { document.togglePretty() } label: {
                Text("{}")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(document.pretty ? DeveloperToolsStyle.tint : Color.secondary)
                    .frame(width: 22, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!document.language.canPrettyPrint || document.formatting)
            .help(document.pretty ? "Show original" : "Pretty print")
            .accessibilityLabel("Pretty print")
            .accessibilityValue(document.pretty ? "On" : "Off")
            .accessibilityIdentifier("developer-network-response-pretty")
            if document.formatting {
                ProgressView().controlSize(.mini)
                Text("Pretty-printing…").foregroundStyle(.secondary)
            } else {
                Text(DeveloperSourcePane.positionText(position))
                    .foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 6)
        .frame(height: DeveloperToolsStyle.controlHeight)
        .background(DeveloperToolsStyle.chrome)
    }
}
