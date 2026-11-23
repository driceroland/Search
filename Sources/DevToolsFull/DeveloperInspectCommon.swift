import SwiftUI

/// What went wrong reading the page, in a band under a panel's toolbar
/// (Animations, CSS overview, Layers).
struct DeveloperProblemNote: View {
    let text: String
    /// Nil keeps the panel's own font.
    var font: Font? = .system(size: 11)

    var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .padding(DeveloperToolsStyle.gutter)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DeveloperToolsStyle.raised)
    }
}

extension View {
    /// A table's row of column titles, on the panel's chrome over its rows
    /// (Coverage, Layers, Resources).
    func developerColumnTitles() -> some View {
        fontWeight(.medium)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, DeveloperToolsStyle.gutter)
            .frame(height: DeveloperToolsStyle.rowHeight)
            .background(DeveloperToolsStyle.chrome)
    }
}
