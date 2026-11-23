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


// MARK: Reporting API


// MARK: Notifications


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
