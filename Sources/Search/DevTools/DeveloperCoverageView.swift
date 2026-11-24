import AppKit
import SwiftUI

/// Coverage's two colours, shared with the Sources gutter: Chrome's red
/// for code that never ran, and blue-green for code that did.
enum DeveloperCoverageStyle {
    static let unused = NSColor(name: nil) {
        $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.93, green: 0.40, blue: 0.36, alpha: 1)
            : NSColor(srgbRed: 0.85, green: 0.19, blue: 0.15, alpha: 1)
    }
    static let used = NSColor(name: nil) {
        $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.36, green: 0.68, blue: 0.86, alpha: 1)
            : NSColor(srgbRed: 0.18, green: 0.52, blue: 0.72, alpha: 1)
    }
}

/// Chrome's Coverage drawer tool: record (which reloads the page under
/// instrumentation), stop, clear, a URL filter and a type filter, then a
/// row per file with its total and unused bytes and Chrome's usage bar.
struct DeveloperCoverageView: View {
    @ObservedObject var session: DeveloperToolsSession
    @ObservedObject var coverage: DeveloperCoverage
    @State private var filterText = ""
    @State private var filter = DeveloperCoverageMath.Filter.all
    @State private var selection: DeveloperCoverageMath.Entry.ID?

    private var rows: [DeveloperCoverageMath.Entry] {
        DeveloperCoverageMath.shown(coverage.entries, text: filterText, filter: filter)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if coverage.entries.isEmpty {
                empty
            } else {
                table
            }
            Divider()
            footer
        }
        .font(.system(size: 11))
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: DeveloperToolsStyle.controlSpacing) {
            if coverage.recording {
                Button { coverage.stop() } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color(nsColor: DeveloperCoverageStyle.unused))
                        .frame(width: DeveloperToolsStyle.controlHeight, height: DeveloperToolsStyle.controlHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Stop instrumenting coverage and show results")
                .accessibilityLabel("Stop instrumenting coverage and show results")
            } else {
                DeveloperPanelIcon(symbol: "record.circle", title: "Start instrumenting coverage and reload page") {
                    coverage.startAndReload()
                }
                .disabled(!session.ready || coverage.starting)
            }
            DeveloperPanelIcon(symbol: "arrow.clockwise", title: "Start instrumenting coverage and reload page") {
                coverage.startAndReload()
            }
            .disabled(!session.ready || coverage.starting)
            DeveloperPanelIcon(symbol: "nosign", title: "Clear all") { coverage.clear() }
                .disabled(coverage.entries.isEmpty)
            DeveloperPanelIcon(symbol: "square.and.arrow.down", title: "Export…") { coverage.export() }
                .disabled(!coverage.canExport)
            Divider().frame(height: 14)
            Picker("Coverage type", selection: $coverage.granularity) {
                ForEach(DeveloperCoverageMath.Granularity.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .fixedSize()
            .help(coverage.granularity.help)
            Divider().frame(height: 14)
            Picker("Type", selection: $filter) {
                ForEach(DeveloperCoverageMath.Filter.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .fixedSize()
            .help("Filter coverage by type")
            TextField("URL filter", text: $filterText)
                .developerToolsField()
                .frame(maxWidth: 260)
            Spacer(minLength: 0)
            if coverage.starting { ProgressView().controlSize(.mini) }
        }
        .padding(.horizontal, DeveloperToolsStyle.gutter)
        .frame(height: DeveloperToolsStyle.toolbarHeight)
        .background(DeveloperToolsStyle.chrome)
    }

    // MARK: Table

    private enum Column {
        static let type: CGFloat = 44
        static let total: CGFloat = 84
        static let unused: CGFloat = 124
        static let bar: CGFloat = 160
    }

    private var table: some View {
        VStack(spacing: 0) {
            HStack(spacing: DeveloperToolsStyle.gutter) {
                Text("URL").frame(maxWidth: .infinity, alignment: .leading)
                Text("Type").frame(width: Column.type, alignment: .leading)
                Text("Total Bytes").frame(width: Column.total, alignment: .trailing)
                Text("Unused Bytes").frame(width: Column.unused, alignment: .trailing)
                Text("Usage Visualization").frame(width: Column.bar, alignment: .leading)
            }
            .developerColumnTitles()
            Divider()
            let shown = rows
            let largest = max(1, shown.map(\.total).max() ?? 1)
            if shown.isEmpty {
                Text("No files match the filter.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(shown.enumerated()), id: \.element.id) { index, entry in
                            row(entry, largest: largest, striped: index % 2 == 1)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func row(_ entry: DeveloperCoverageMath.Entry, largest: Int, striped: Bool) -> some View {
        let selected = selection == entry.id
        return HStack(spacing: DeveloperToolsStyle.gutter) {
            Text(entry.url)
                .font(DeveloperToolsStyle.code)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(entry.url)
            Text(entry.kind.rawValue).frame(width: Column.type, alignment: .leading)
            Text(entry.total.formatted()).monospacedDigit().frame(width: Column.total, alignment: .trailing)
            HStack(spacing: 4) {
                Text(entry.unused.formatted()).monospacedDigit()
                Text(DeveloperCoverageMath.percent(used: entry.unused, total: entry.total))
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            .frame(width: Column.unused, alignment: .trailing)
            bar(entry, largest: largest).frame(width: Column.bar, alignment: .leading)
        }
        .lineLimit(1)
        .padding(.horizontal, DeveloperToolsStyle.gutter)
        .frame(height: DeveloperToolsStyle.rowHeight)
        .background(selected ? DeveloperToolsStyle.selected : striped ? DeveloperToolsStyle.raised : .clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { open(entry) }
        .onTapGesture { selection = entry.id }
        .contextMenu {
            Button("Open in Sources panel") { open(entry) }
            Button("Copy URL") { DeveloperToolsSession.copyToPasteboard(entry.url) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue("\(DeveloperCoverageMath.percent(used: entry.unused, total: entry.total)) unused")
    }

    /// Chrome's bar: as long as the file is next to the largest shown, the
    /// used part one colour and the unused part red.
    private func bar(_ entry: DeveloperCoverageMath.Entry, largest: Int) -> some View {
        GeometryReader { geometry in
            let width = geometry.size.width * CGFloat(entry.total) / CGFloat(largest)
            HStack(spacing: 0) {
                Rectangle().fill(Color(nsColor: DeveloperCoverageStyle.used))
                    .frame(width: width * entry.usedFraction)
                Rectangle().fill(Color(nsColor: DeveloperCoverageStyle.unused))
                    .frame(width: width * (1 - entry.usedFraction))
            }
            .frame(height: 10)
            .frame(maxHeight: .infinity)
        }
        .accessibilityHidden(true)
    }

    /// Double-click: the file in Sources, as Chrome opens it.
    private func open(_ entry: DeveloperCoverageMath.Entry) {
        session.select(.sources)
        if let resource = (session.resources + session.contentScripts)
            .first(where: { DeveloperDebugger.sameScript($0.url, entry.url) }) {
            session.openSource(resource)
        }
    }

    // MARK: Empty state and footer

    private var empty: some View {
        VStack(spacing: 6) {
            if coverage.recording || coverage.starting {
                ProgressView().controlSize(.small)
                Text("Recording coverage…")
            } else {
                Text("Click the reload button to reload and start capturing coverage.")
                Text("Code that ran shows in blue, code that didn’t in red, here and in the Sources panel’s gutter.")
            }
            if let message = coverage.message {
                Text(message).foregroundStyle(.red)
            }
        }
        .multilineTextAlignment(.center)
        .foregroundStyle(.secondary)
        .padding(DeveloperToolsStyle.gutter * 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: DeveloperToolsStyle.gutter) {
            if !coverage.entries.isEmpty {
                let shown = rows
                Text(DeveloperCoverageMath.summary(shown))
                    .monospacedDigit()
                if shown.contains(where: { $0.kind == .css }) {
                    Text("CSS is approximate: a rule counts as used when its selector matches an element now.")
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 0)
            if coverage.skippedSheets > 0 {
                Text("\(coverage.skippedSheets) cross-origin stylesheet\(coverage.skippedSheets == 1 ? "" : "s") not read")
                    .foregroundStyle(.tertiary)
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, DeveloperToolsStyle.gutter)
        .frame(height: DeveloperToolsStyle.rowHeight)
        .background(DeveloperToolsStyle.chrome)
    }
}
