import AppKit
import SwiftUI

/// Chrome's Developer resources drawer tool: every source map and
/// authored file DevTools loaded for the page, with its status, address,
/// initiator, size and error; a URL filter over them.
struct DeveloperResourcesView: View {
    let session: DeveloperToolsSession
    @ObservedObject private var log: DeveloperResourceLog
    @State private var filter = ""
    @State private var selection: Int?
    /// The drawer's width: Initiator and Error give way in a narrow one.
    @State private var width: CGFloat = 900

    init(session: DeveloperToolsSession) {
        self.session = session
        log = session.sourceMaps.resourceLog
    }

    private var rows: [DeveloperResourceRecord] { DeveloperResourceFilter.filter(log.list.records, query: filter) }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            table
            Divider()
            Text(DeveloperResourceList.summary(rows))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, DeveloperToolsStyle.gutter)
                .frame(maxWidth: .infinity, minHeight: DeveloperToolsStyle.rowHeight, alignment: .leading)
                .background(DeveloperToolsStyle.chrome)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .accessibilityIdentifier("developer-resources")
    }

    private var toolbar: some View {
        HStack(spacing: DeveloperToolsStyle.controlSpacing) {
            TextField("Filter by URL", text: $filter)
                .developerToolsField()
                .frame(maxWidth: 320)
            Toggle("Load through website", isOn: $log.loadThroughWebsite)
                .toggleStyle(.developerCheckbox)
                .help("Load source maps and authored files through the page, with its cookies for each address. "
                      + "Off, DevTools requests them itself without cookies.")
            Spacer(minLength: 0)
            DeveloperPanelIcon(symbol: "nosign", title: "Clear") { log.removeAll() }
                .disabled(log.list.records.isEmpty)
        }
        .padding(.horizontal, DeveloperToolsStyle.gutter)
        .frame(height: DeveloperToolsStyle.toolbarHeight)
        .background(DeveloperToolsStyle.chrome)
    }

    // MARK: Table

    enum Column {
        static let status: CGFloat = 64
        static let bytes: CGFloat = 84
        /// Initiator and Error each: up to 220, shrinking so URL keeps at
        /// least 140 of a narrow drawer, down to 60.
        static func wide(_ width: CGFloat) -> CGFloat {
            let rest = width - status - bytes - 140 - 6 * DeveloperToolsStyle.gutter
            return min(220, max(60, rest / 2))
        }
    }

    private var table: some View {
        VStack(spacing: 0) {
            HStack(spacing: DeveloperToolsStyle.gutter) {
                Text("Status").frame(width: Column.status, alignment: .leading)
                Text("URL").frame(maxWidth: .infinity, alignment: .leading)
                Text("Initiator").frame(width: Column.wide(width), alignment: .leading)
                Text("Total Bytes").frame(width: Column.bytes, alignment: .trailing)
                Text("Error").frame(width: Column.wide(width), alignment: .leading)
            }
            .developerColumnTitles()
            Divider()
            let shown = rows
            if shown.isEmpty {
                Text(log.list.records.isEmpty
                     ? "No developer resources loaded yet. Source maps appear here as scripts and stylesheets bring them."
                     : "No resources match the filter.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding()
                    .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(shown.enumerated()), id: \.element.id) { index, record in
                            row(record, striped: index % 2 == 1)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func row(_ record: DeveloperResourceRecord, striped: Bool) -> some View {
        let selected = selection == record.id
        return HStack(spacing: DeveloperToolsStyle.gutter) {
            status(record.status).frame(width: Column.status, alignment: .leading)
            Text(record.displayURL)
                .font(DeveloperToolsStyle.code)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(record.displayURL)
            Text(record.initiator.isEmpty ? "" : SourceTree.fileName(record.initiator))
                .truncationMode(.middle)
                .frame(width: Column.wide(width), alignment: .leading)
                .help(record.initiator)
            Text(DeveloperResourceFilter.bytesText(record))
                .monospacedDigit()
                .frame(width: Column.bytes, alignment: .trailing)
            Text(record.error ?? "")
                .foregroundStyle(Color(nsColor: .systemRed))
                .truncationMode(.tail)
                .frame(width: Column.wide(width), alignment: .leading)
                .help(record.error ?? "")
        }
        .lineLimit(1)
        .padding(.horizontal, DeveloperToolsStyle.gutter)
        .frame(height: DeveloperToolsStyle.rowHeight)
        .background(selected ? DeveloperToolsStyle.selected : striped ? DeveloperToolsStyle.raised : .clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { open(record) }
        .onTapGesture { selection = record.id }
        .contextMenu {
            Button("Copy URL") { DeveloperToolsSession.copyToPasteboard(record.url) }
            if !record.initiator.isEmpty {
                Button("Copy initiator URL") { DeveloperToolsSession.copyToPasteboard(record.initiator) }
            }
            Divider()
            Button("Open in Sources panel") { open(record) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(record.status.rawValue)
    }

    private func status(_ status: DeveloperResourceRecord.Status) -> some View {
        HStack(spacing: 4) {
            switch status {
            case .success: Image(systemName: "checkmark.circle.fill").foregroundStyle(Color(nsColor: .systemGreen))
            case .failure: Image(systemName: "xmark.octagon.fill").foregroundStyle(Color(nsColor: .systemRed))
            case .pending: ProgressView().controlSize(.mini)
            }
            Text(status.rawValue)
        }
        .font(.system(size: 11))
    }

    /// The file in Sources: an authored file as the map lists it, else the
    /// script or stylesheet the map was loaded for.
    private func open(_ record: DeveloperResourceRecord) {
        let resources = session.resources + session.contentScripts + session.sourceMaps.authoredResources
        let resource = resources.first { $0.url == record.url }
            ?? resources.first { !record.initiator.isEmpty && DeveloperDebugger.sameScript($0.url, record.initiator) }
        guard let resource else {
            session.message = "\(SourceTree.fileName(record.url)) isn’t one of the page’s files."
            return
        }
        session.select(.sources)
        session.openSource(resource)
    }
}
