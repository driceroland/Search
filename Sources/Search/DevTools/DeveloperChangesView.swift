import AppKit
import SwiftUI

/// Chrome's Changes drawer tool: the files edited in DevTools down the
/// left, the selected one's diff on the right, with Revert and Copy over
/// it and the insertions and deletions under it.
struct DeveloperChangesView: View {
    @ObservedObject var session: DeveloperToolsSession
    @ObservedObject private var changes: DeveloperChanges

    init(session: DeveloperToolsSession) {
        self.session = session
        changes = DeveloperChanges.of(session)
    }

    var body: some View {
        let files = changes.changed
        if files.isEmpty {
            VStack(spacing: 6) {
                Text("No changes").font(.system(size: 11, weight: .semibold))
                Text("Edits made in DevTools to style sheets and Local Overrides files show here.")
                    .multilineTextAlignment(.center)
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
            .padding(DeveloperToolsStyle.gutter * 2)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HSplitView {
                list(files)
                    .frame(minWidth: 120, idealWidth: 200, maxWidth: 360)
                if let file = changes.shown {
                    DeveloperChangesDiffView(file: file, changes: changes)
                        .id(file.id)
                        .frame(minWidth: 200, maxWidth: .infinity)
                }
            }
        }
    }

    private func list(_ files: [DeveloperChanges.File]) -> some View {
        let shown = changes.shown?.id
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(files) { file in
                    let selected = file.id == shown
                    HStack(spacing: DeveloperToolsStyle.controlSpacing) {
                        Image(systemName: file.kind == .source ? "doc.text" : file.kind == .inline ? "chevron.left.forwardslash.chevron.right" : "paintbrush")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .frame(width: 14)
                        Text(file.name).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, DeveloperToolsStyle.gutter)
                    .frame(height: DeveloperToolsStyle.rowHeight)
                    .background(selected ? DeveloperToolsStyle.selected : .clear)
                    .contentShape(Rectangle())
                    .onTapGesture { changes.selected = file.id }
                    .help(file.url)
                    .contextMenu {
                        Button("Revert all changes") { changes.revert(file) }
                        Button("Copy") { changes.copy(file) }
                    }
                    .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
                }
            }
        }
        .background(DeveloperToolsStyle.surface)
    }
}

/// One file's diff, as Chrome's Changes draws it: the original's and the
/// current text's line numbers, a + or − gutter, added lines green and
/// removed ones red, unchanged runs folded into a row that opens them.
private struct DeveloperChangesDiffView: View {
    let file: DeveloperChanges.File
    @ObservedObject var changes: DeveloperChanges
    @State private var expanded = Set<Int>()

    private static let added = Color.green.opacity(0.16)
    private static let removed = Color.red.opacity(0.16)

    var body: some View {
        let lines = DeveloperChangesDiff.diff(file.original, file.current)
        let rows = DeveloperChangesDiff.rows(lines, expanded: expanded)
        let digits = String(max(lines.count, 1)).count
        let numberWidth = CGFloat(digits) * 7 + 8
        VStack(spacing: 0) {
            toolbar
            Divider()
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        switch row {
                        case .line(_, let line): lineView(line, numberWidth: numberWidth)
                        case .collapsed(let at, let count): fold(at: at, count: count, numberWidth: numberWidth)
                        }
                    }
                }
                .padding(.vertical, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(DeveloperToolsStyle.surface)
            Divider()
            HStack {
                Text(DeveloperChangesDiff.summary(lines)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .font(.system(size: 10.5))
            .padding(.horizontal, DeveloperToolsStyle.gutter)
            .frame(height: DeveloperToolsStyle.rowHeight)
            .background(DeveloperToolsStyle.chrome)
        }
    }

    private var toolbar: some View {
        HStack(spacing: DeveloperToolsStyle.controlSpacing) {
            DeveloperPanelIcon(symbol: "arrow.uturn.backward", title: "Revert all changes to current file") {
                changes.revert(file)
            }
            DeveloperPanelIcon(symbol: "doc.on.doc", title: file.css ? "Copy CSS changes" : "Copy changes") {
                changes.copy(file)
            }
            Text(file.url).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                .help(file.url)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DeveloperToolsStyle.gutter)
        .frame(height: DeveloperToolsStyle.toolbarHeight)
        .background(DeveloperToolsStyle.chrome)
    }

    private func number(_ value: Int?, width: CGFloat) -> some View {
        Text(value.map(String.init) ?? "")
            .foregroundStyle(.tertiary)
            .frame(width: width, alignment: .trailing)
    }

    private func lineView(_ line: DeveloperChangesDiff.Line, numberWidth: CGFloat) -> some View {
        let mark = line.kind == .insert ? "+" : line.kind == .delete ? "−" : ""
        let tint: Color = line.kind == .insert ? Self.added : line.kind == .delete ? Self.removed : .clear
        return HStack(spacing: 0) {
            number(line.original, width: numberWidth)
            number(line.current, width: numberWidth)
            Text(mark)
                .foregroundStyle(line.kind == .insert ? Color.green : Color.red)
                .frame(width: 16)
            Text(line.text.isEmpty ? " " : line.text)
                .lineLimit(1)
                .fixedSize()
                .textSelection(.enabled)
            Spacer(minLength: DeveloperToolsStyle.gutter)
        }
        .font(DeveloperToolsStyle.code)
        .frame(height: 16)
        .background(tint)
        .accessibilityElement(children: .combine)
        .accessibilityLabel((line.kind == .insert ? "Added: " : line.kind == .delete ? "Removed: " : "") + line.text)
    }

    private func fold(at: Int, count: Int, numberWidth: CGFloat) -> some View {
        Button {
            expanded.insert(at)
        } label: {
            HStack(spacing: 0) {
                Color.clear.frame(width: numberWidth * 2 + 16)
                Text("… \(count) unchanged lines").foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .font(DeveloperToolsStyle.code)
            .frame(height: 18)
            .background(DeveloperToolsStyle.raised)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show the unchanged lines")
    }
}
