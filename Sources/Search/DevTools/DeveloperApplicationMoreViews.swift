import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

// The Application panel's Back/forward cache, Reporting API, frame and
// Extension storage views, and the Storage view's usage bar.

/// A heading and label and value rows, as Chrome's report views lay them out.
private struct DeveloperFieldSection: View {
    let title: String
    let rows: [[String]]

    var body: some View {
        VStack(alignment: .leading, spacing: DeveloperToolsStyle.controlSpacing) {
            Text(title).fontWeight(.semibold).accessibilityAddTraits(.isHeader)
            Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 3) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        Text(row.first ?? "").foregroundStyle(.secondary).frame(minWidth: 140, alignment: .leading)
                        Text(row.dropFirst().first ?? "").font(DeveloperToolsStyle.code).textSelection(.enabled)
                            .lineLimit(8).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }
}

// MARK: Back/forward cache

/// Chrome's Application › Background services › Back/forward cache.
struct DeveloperBackForwardCacheView: View {
    let session: DeveloperToolsSession
    let page: URL?
    let loading: Bool
    @State private var testing = false
    @State private var outcome: DeveloperBackForwardCacheOutcome?
    @State private var problem: String?

    private var testable: Bool { page.flatMap(DeveloperApplication.origin) != nil && !loading && !testing }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Back/forward cache").font(.headline).accessibilityAddTraits(.isHeader)
                Text("Pages kept in the back/forward cache come back at once when you go Back or Forward. The test leaves this page for a blank one and comes back, then checks whether the page was restored rather than loaded again.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: DeveloperToolsStyle.gutter) {
                    Button("Test back/forward cache") { test() }
                        .disabled(!testable)
                    if testing { ProgressView().controlSize(.small).accessibilityLabel("Testing") }
                }
                if page.flatMap(DeveloperApplication.origin) == nil, !testing {
                    Text("Choose an HTTP or HTTPS page to test.").foregroundStyle(.secondary)
                }
                if let problem { Text(problem).foregroundStyle(.secondary).textSelection(.enabled) }
                if let outcome { result(outcome) }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(DeveloperToolsStyle.gutter)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { DeveloperApplicationProbe.shared.watch(session.web) }
    }

    @ViewBuilder
    private func result(_ outcome: DeveloperBackForwardCacheOutcome) -> some View {
        Divider()
        HStack(spacing: DeveloperToolsStyle.controlSpacing) {
            Image(systemName: outcome.restored ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .foregroundStyle(outcome.restored ? Color.green : Color.red)
                .accessibilityHidden(true)
            Text(outcome.restored ? "Successfully served from back/forward cache." : "Not served from back/forward cache.")
                .fontWeight(.semibold)
        }
        Text(outcome.url).font(DeveloperToolsStyle.code).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(2)
        if !outcome.restored {
            if outcome.reasons.isEmpty {
                Text("Nothing on the page explains it. WebKit may have been short of memory, or kept the page out for a reason a page can’t see.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Possible reasons").fontWeight(.semibold).accessibilityAddTraits(.isHeader)
                ForEach(Array(outcome.reasons.enumerated()), id: \.offset) { _, reason in
                    HStack(alignment: .firstTextBaseline, spacing: DeveloperToolsStyle.gutter) {
                        Text(reason.kind.rawValue)
                            .font(.caption).padding(.horizontal, 5).padding(.vertical, 1)
                            .background((reason.kind == .likely ? Color.orange : Color.secondary).opacity(0.18),
                                        in: RoundedRectangle(cornerRadius: 4))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(reason.title)
                            Text(reason.detail).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            ForEach(outcome.caveats, id: \.self) { note in
                Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func test() {
        guard let page, testable else { return }
        testing = true
        problem = nil
        outcome = nil
        Task {
            defer { testing = false }
            do {
                outcome = try await DeveloperApplicationMore.testBackForwardCache(in: session, address: page)
            } catch {
                problem = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

// MARK: Reporting API

/// Chrome's Application › Background services › Reporting API: the reports
/// the page's ReportingObserver saw and the endpoints its document names.
struct DeveloperReportingView: View {
    let session: DeveloperToolsSession
    let page: URL
    let refresh: Int
    @State private var reports: [DeveloperReport] = []
    @State private var dropped = 0
    @State private var early: Bool?
    @State private var endpoints: [DeveloperReportingEndpoint] = []
    @State private var headersRecorded = false
    @State private var loaded = false
    @State private var selection: Int?
    @State private var tableState = DeveloperTableState()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DeveloperToolsStyle.controlSpacing) {
                Text("Reports").fontWeight(.semibold).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                Button("Clear reports") { clear() }.disabled(reports.isEmpty)
            }
            .padding(.horizontal, DeveloperToolsStyle.gutter)
            .frame(height: DeveloperToolsStyle.toolbarHeight)
            Divider()
            if !loaded {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 80)
            } else if reports.isEmpty {
                Text(early == nil
                     ? "The reporting script is not in this page yet. Reload the page to collect its reports."
                     : "No reports yet. Deprecation, intervention and Content Security Policy reports this page triggers appear here.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: 80).padding(DeveloperToolsStyle.gutter)
            } else {
                GeometryReader { geometry in
                    let url = max(160, geometry.size.width - 420)
                    DeveloperApplicationTable(
                        columns: ["URL", "Type", "Source", "Generated at"],
                        rows: reports.map { report in
                            DeveloperApplicationSnapshot.Row(id: report.id, values: [
                                report.url, report.type, report.source,
                                Date(timeIntervalSince1970: report.time / 1000).formatted(date: .omitted, time: .standard),
                            ], editableValue: nil)
                        },
                        defaultWidths: [url, 130, 150, 120], state: $tableState, selection: $selection
                    ) { _ in EmptyView() }
                }
                .frame(minHeight: 120)
                if let id = selection, let report = reports.first(where: { $0.id == id }) {
                    ScrollView {
                        DeveloperFieldSection(title: "Body", rows: report.body.isEmpty ? [["Body", "—"]] : report.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(DeveloperToolsStyle.gutter)
                    }
                    .frame(maxHeight: 160)
                    .background(DeveloperToolsStyle.chrome)
                    .overlay(alignment: .top) { Divider() }
                }
            }
            if dropped > 0 {
                Text("\(dropped) more reports were not kept.").font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, DeveloperToolsStyle.gutter)
            }
            if early == false {
                Text("The reporting script started after the page did; buffered reports were collected, but reload to be sure none are missed.")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, DeveloperToolsStyle.gutter).padding(.top, DeveloperToolsStyle.controlSpacing)
            }
            Divider().padding(.top, DeveloperToolsStyle.controlSpacing)
            VStack(alignment: .leading, spacing: DeveloperToolsStyle.controlSpacing) {
                Text("Endpoints").fontWeight(.semibold).accessibilityAddTraits(.isHeader)
                if !headersRecorded {
                    Text("Network has no record of this document. Reload with DevTools open to read its Reporting-Endpoints and Report-To headers.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else if endpoints.isEmpty {
                    Text("The document names no endpoints in Reporting-Endpoints, Report-To or a CSP report-uri.")
                        .foregroundStyle(.secondary)
                } else {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 3) {
                        GridRow {
                            Text("Name").foregroundStyle(.secondary)
                            Text("URL").foregroundStyle(.secondary)
                            Text("Header").foregroundStyle(.secondary)
                        }
                        ForEach(Array(endpoints.enumerated()), id: \.offset) { _, endpoint in
                            GridRow {
                                Text(endpoint.name).font(DeveloperToolsStyle.code)
                                Text(endpoint.url).font(DeveloperToolsStyle.code).textSelection(.enabled).lineLimit(2)
                                Text(endpoint.source).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Text("WebKit delivers reports itself and does not say whether an endpoint received them.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DeveloperToolsStyle.gutter)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { DeveloperApplicationProbe.shared.watch(session.web) }
        .task(id: refresh) { await load() }
    }

    private func load() async {
        guard let web = session.web, web.url == page else { loaded = true; return }
        let snapshot = await DeveloperApplicationProbe.snapshot(in: web)
        early = snapshot?["early"] as? Bool
        reports = DeveloperReport.parse(snapshot?["reports"] as? [Any] ?? [])
        dropped = (snapshot?["dropped"] as? NSNumber)?.intValue ?? 0
        if let details = await DeveloperApplicationMore.documentDetails(page.absoluteString, in: session) {
            headersRecorded = true
            endpoints = DeveloperReportingHeaders.endpoints(DeveloperResponseHeaders(details.responseHeaders), document: page)
        } else {
            headersRecorded = false
            endpoints = []
        }
        loaded = true
    }

    private func clear() {
        guard let web = session.web else { return }
        Task {
            await DeveloperApplicationProbe.clearReports(in: web)
            selection = nil
            await load()
        }
    }
}

// MARK: Notifications

/// Chrome's Application › Background services › Notifications: with
/// recording on, the notifications the page shows and the permission it
/// asks for, kept through its navigations until recording stops.
struct DeveloperNotificationsView: View {
    let session: DeveloperToolsSession
    @ObservedObject private var recorder = DeveloperNotificationRecorder.shared
    @State private var selection: Int?
    @State private var tableState = DeveloperTableState()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DeveloperToolsStyle.controlSpacing) {
                Button { toggle() } label: {
                    Image(systemName: recorder.recording ? "stop.circle.fill" : "record.circle")
                        .foregroundStyle(recorder.recording ? Color.red : Color.secondary)
                        .frame(width: DeveloperToolsStyle.controlHeight, height: DeveloperToolsStyle.controlHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(recorder.recording ? "Stop recording events" : "Start recording events")
                .accessibilityLabel(recorder.recording ? "Stop recording events" : "Start recording events")
                .disabled(session.web == nil)
                Button("Clear") {
                    selection = nil
                    Task { await recorder.clear() }
                }
                .disabled(recorder.events.isEmpty)
                Button("Save events") { save() }
                    .disabled(recorder.events.isEmpty)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DeveloperToolsStyle.gutter)
            .frame(height: DeveloperToolsStyle.toolbarHeight)
            Divider()
            if recorder.events.isEmpty {
                Text(emptyText)
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .frame(maxWidth: 520).padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { geometry in
                    let title = max(160, geometry.size.width - 520)
                    DeveloperApplicationTable(
                        columns: ["Timestamp", "Event", "Origin", "Title"],
                        rows: recorder.events.map { event in
                            DeveloperApplicationSnapshot.Row(id: event.id, values: [
                                Date(timeIntervalSince1970: event.time / 1000).formatted(date: .numeric, time: .standard),
                                event.name, event.origin, event.title,
                            ], editableValue: nil)
                        },
                        defaultWidths: [170, 160, 190, title], state: $tableState, selection: $selection
                    ) { _ in EmptyView() }
                }
                .frame(minHeight: 120)
                if let id = selection, let event = recorder.events.first(where: { $0.id == id }) {
                    ScrollView {
                        DeveloperFieldSection(title: "Event metadata",
                                              rows: [["Title", event.title.isEmpty ? "—" : event.title]] + event.details)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(DeveloperToolsStyle.gutter)
                    }
                    .frame(maxHeight: 180)
                    .background(DeveloperToolsStyle.chrome)
                    .overlay(alignment: .top) { Divider() }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var emptyText: String {
        if recorder.recording {
            return recorder.supported
                ? "Recording Notifications activity… Notifications this page shows and the permission it requests appear here."
                : "Recording Notifications activity… This page has neither Notification nor ServiceWorkerRegistration, so it can’t show notifications."
        }
        return "Start recording events to debug Notifications. Click the record button to start recording; DevTools records what this page does with Notifications while the tab is inspected."
    }

    private func toggle() {
        guard let web = session.web else { return }
        Task {
            if recorder.recording { await recorder.stop() } else { await recorder.start(in: web) }
        }
    }

    /// Chrome's "Save events": the log as a JSON file.
    private func save() {
        let data = DeveloperNotificationEvent.export(recorder.events)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Notifications-events.json"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}

// MARK: Frames

/// Chrome's frame view: Document, Security & Isolation and Permissions
/// Policy, and the frame's resources by kind.
struct DeveloperFrameDetailsView: View {
    let session: DeveloperToolsSession
    let page: URL
    let frameID: String
    let refresh: Int
    /// Shows a resource's preview, as choosing it in the sidebar does.
    let preview: (String) -> Void
    @State private var node: DeveloperFrameNode?
    @State private var path: [Int]?
    @State private var sections: [DeveloperFrameDetails.Section] = []
    @State private var hasOwner = false
    @State private var problem: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let node {
                    Text(node.title).font(.headline).accessibilityAddTraits(.isHeader)
                    ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                        DeveloperFieldSection(title: section.title, rows: section.rows)
                        if section.title == "Document", let path, !path.isEmpty {
                            Button("Reveal owner element in Elements") {
                                DeveloperApplicationMore.revealOwner(path: path, in: session)
                            }
                            .disabled(!hasOwner)
                            .help(hasOwner ? "Select the element that holds this frame"
                                  : "The element is inside a cross-origin frame, which Search can’t reach")
                        }
                    }
                    resources(node)
                } else if let problem {
                    Text(problem).foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(DeveloperToolsStyle.gutter)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: [frameID, String(refresh), page.absoluteString]) { await load() }
    }

    @ViewBuilder
    private func resources(_ node: DeveloperFrameNode) -> some View {
        Text("Resources").fontWeight(.semibold).accessibilityAddTraits(.isHeader)
        let groups = DeveloperFrameDetails.orderedGroups(node)
        if groups.isEmpty {
            Text("WebKit lists no resources for this frame.").foregroundStyle(.secondary)
        }
        ForEach(groups, id: \.title) { group in
            DisclosureGroup("\(group.title) (\(group.resources.count))") {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(group.resources.prefix(300), id: \.self) { resource in
                        HStack(spacing: DeveloperToolsStyle.controlSpacing) {
                            Button(resource.name) { DeveloperApplicationMore.open(resource, in: session) }
                                .buttonStyle(.plain).foregroundStyle(DeveloperToolsStyle.tint)
                                .lineLimit(1).truncationMode(.middle)
                                .help(DeveloperFrameDetails.opensInSources(resource.type)
                                      ? "Open in Sources: \(resource.url)" : "Show in Network: \(resource.url)")
                            Spacer(minLength: DeveloperToolsStyle.gutter)
                            Text(resource.mimeType).foregroundStyle(.secondary).lineLimit(1)
                            Button { preview(resource.url) } label: { Image(systemName: "eye") }
                                .buttonStyle(.plain).foregroundStyle(.secondary)
                                .help("Preview").accessibilityLabel("Preview \(resource.name)")
                        }
                        .frame(height: DeveloperToolsStyle.rowHeight)
                    }
                }
                .padding(.leading, DeveloperToolsStyle.gutter)
            }
        }
    }

    private func load() async {
        guard let raw = try? await session.command("Page.getResourceTree")["frameTree"] as? [String: Any],
              let root = DeveloperFrameNode.parse(raw), let found = root.find(frameID) else {
            node = nil
            problem = "This frame is no longer on the page."
            return
        }
        let route = DeveloperFrameDetails.path(to: frameID, in: root) ?? []
        let context = await DeveloperApplicationMore.frameContext(path: route, in: session, address: page)
        let details = await DeveloperApplicationMore.documentDetails(found.url, in: session)
        guard !Task.isCancelled else { return }
        path = route
        hasOwner = context.owner != nil
        sections = DeveloperFrameDetails.sections(found, context: context,
                                                  headers: details.map { DeveloperResponseHeaders($0.responseHeaders) })
        node = found
        problem = nil
    }
}

// MARK: Extension storage

/// Chrome's Application › Storage › Extension storage, for the extension
/// whose page is inspected: chrome.storage.local, sync and session.
struct DeveloperExtensionStorageView: View {
    let session: DeveloperToolsSession
    let page: URL?
    let loading: Bool
    let refresh: Int
    @State private var area = "local"
    @State private var areas: [DeveloperApplicationMore.ExtensionArea] = []
    @State private var problem: String?
    @State private var actionProblem: String?
    @State private var selection: Int?
    @State private var tableState = DeveloperTableState()
    @State private var serial = 0

    private var extensionID: String? { DeveloperExtensionStorage.extensionID(of: page) }

    var body: some View {
        VStack(spacing: 0) {
            if extensionID == nil {
                Text("Open DevTools on one of an extension’s own pages (chrome-extension://…) to see its storage.\n\nStorage of extensions whose content scripts run on this page isn’t shown: WebKit runs content scripts in a world of each extension’s own, which DevTools can’t enter, and keeps their storage where only the extension can read it.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .frame(maxWidth: 520).padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: DeveloperToolsStyle.controlSpacing) {
                    Picker("Area", selection: $area) {
                        ForEach(DeveloperExtensionStorage.areas, id: \.self) { Text($0.capitalized).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    Text(extensionID ?? "").font(DeveloperToolsStyle.code).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 0)
                    Button("Delete selected") { if let row = selectedRow { delete(row) } }
                        .disabled(selectedRow == nil)
                    Button("Clear") { clear() }.disabled(current?.items?.isEmpty != false)
                }
                .padding(.horizontal, DeveloperToolsStyle.gutter)
                .frame(height: DeveloperToolsStyle.toolbarHeight)
                Divider()
                if let actionProblem {
                    Text(actionProblem).foregroundStyle(.secondary).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(DeveloperToolsStyle.gutter)
                    Divider()
                }
                content
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: [page?.absoluteString ?? "", String(loading), String(refresh), String(serial)]) { await load() }
        .onChange(of: area) { _, _ in selection = nil }
    }

    private var current: DeveloperApplicationMore.ExtensionArea? { areas.first { $0.name == area } }

    private var rows: [DeveloperApplicationSnapshot.Row] {
        (current?.items ?? []).enumerated().map { index, pair in
            DeveloperApplicationSnapshot.Row(id: index, values: pair, editableValue: nil)
        }
    }

    private var selectedRow: DeveloperApplicationSnapshot.Row? {
        guard let selection else { return nil }
        return rows.first { $0.id == selection }
    }

    @ViewBuilder
    private var content: some View {
        if let problem {
            Text(problem).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if areas.isEmpty {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let issue = current?.problem {
            Text("chrome.storage.\(area): \(issue)").foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            GeometryReader { geometry in
                let first = max(105, geometry.size.width * 0.37)
                DeveloperApplicationTable(
                    columns: ["Key", "Value"], rows: rows,
                    defaultWidths: [first, max(130, geometry.size.width - first)],
                    state: $tableState, selection: $selection,
                    editable: [0, 1], canEdit: { _ in true }, addsRows: true,
                    commit: { row, changes in await commit(row, changes) },
                    delete: { row in delete(row) }
                ) { row in
                    Button("Delete") { delete(row) }
                }
            }
        }
    }

    private func load() async {
        guard let page, !loading, extensionID != nil else { return }
        do {
            areas = try await DeveloperApplicationMore.extensionStorage(in: session, address: page)
            problem = nil
        } catch {
            areas = []
            problem = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func commit(_ row: DeveloperApplicationSnapshot.Row?, _ changes: [Int: String]) async -> String? {
        guard let page else { return DeveloperApplicationMore.Issue.pageChanged.errorDescription }
        do {
            if let row {
                let key = row.values.first ?? ""
                let newKey = changes[0] ?? key
                if newKey.isEmpty {
                    try await DeveloperApplicationMore.writeExtensionStorage(area: area, set: nil, value: nil, remove: [key],
                                                                             in: session, address: page)
                } else {
                    // A rename alone moves the stored value as it is, not the table's text.
                    try await DeveloperApplicationMore.writeExtensionStorage(area: area, set: newKey, value: changes[1],
                                                                             previousKey: key, in: session, address: page)
                }
            } else {
                let key = changes[0] ?? ""
                guard !key.isEmpty else { return "Enter a key for the new item." }
                try await DeveloperApplicationMore.writeExtensionStorage(area: area, set: key, value: changes[1] ?? "\"\"",
                                                                         in: session, address: page)
            }
            serial += 1
            return nil
        } catch {
            serial += 1
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func delete(_ row: DeveloperApplicationSnapshot.Row) {
        guard let page, let key = row.values.first else { return }
        run { try await DeveloperApplicationMore.writeExtensionStorage(area: area, set: nil, value: nil, remove: [key],
                                                                        in: session, address: page) }
    }

    private func clear() {
        guard let page else { return }
        run { try await DeveloperApplicationMore.writeExtensionStorage(area: area, set: nil, value: nil, clear: true,
                                                                        in: session, address: page) }
    }

    private func run(_ work: @escaping () async throws -> Void) {
        actionProblem = nil
        Task {
            do { try await work() } catch {
                actionProblem = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            selection = nil
            serial += 1
        }
    }
}

// MARK: Storage usage

/// Chrome's usage pie, drawn as a bar with a legend.
struct DeveloperStorageBreakdownBar: View {
    let breakdown: DeveloperStorageBreakdown
    let sizes: [(name: String, bytes: Double?, approximate: Bool)]

    static func color(_ name: String) -> Color {
        switch name {
        case "Local storage": .blue
        case "Session storage": .teal
        case "IndexedDB": .purple
        case "Cache storage": .orange
        case "File system": .green
        case "Cookies": .brown
        case "Service workers": .pink
        default: .gray
        }
    }

    var body: some View {
        let format = ByteCountFormatStyle(style: .file)
        VStack(alignment: .leading, spacing: DeveloperToolsStyle.controlSpacing) {
            if !breakdown.segments.isEmpty {
                GeometryReader { geometry in
                    HStack(spacing: 1) {
                        ForEach(breakdown.segments, id: \.name) { segment in
                            Self.color(segment.name)
                                .frame(width: max(2, (geometry.size.width - CGFloat(breakdown.segments.count)) * segment.fraction))
                                .help("\(segment.name): \(Int64(segment.bytes).formatted(format))")
                        }
                    }
                }
                .frame(height: 12)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Storage usage by type")
                .accessibilityValue(breakdown.segments.map { "\($0.name) \(Int(($0.fraction * 100).rounded())) percent" }
                    .joined(separator: ", "))
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                ForEach(sizes, id: \.name) { item in
                    GridRow {
                        Circle().fill(Self.color(item.name)).frame(width: 8, height: 8).accessibilityHidden(true)
                        Text(item.name).foregroundStyle(.secondary)
                        Text(item.bytes.map { (item.approximate ? "≈ " : "") + Int64($0).formatted(format) } ?? "Not measured")
                            .monospacedDigit()
                    }
                }
                if let other = breakdown.segments.first(where: { $0.name == DeveloperStorageBreakdown.unattributed }) {
                    GridRow {
                        Circle().fill(Self.color(other.name)).frame(width: 8, height: 8).accessibilityHidden(true)
                        Text("Other (in WebKit’s total)").foregroundStyle(.secondary)
                        Text(Int64(other.bytes).formatted(format)).monospacedDigit()
                    }
                }
            }
        }
    }
}
