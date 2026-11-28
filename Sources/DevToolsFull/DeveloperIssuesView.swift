import AppKit
import SwiftUI

/// The colours of Chrome's issue icons: page errors red, breaking changes
/// yellow, improvements blue.
enum DeveloperIssueTheme {
    static let improvement = ConsoleTheme.verbose

    static func color(_ kind: DeveloperIssueKind) -> Color {
        switch kind {
        case .pageError: ConsoleTheme.errorText
        case .breakingChange: ConsoleTheme.warningIcon
        case .improvement: improvement
        }
    }
}

/// Chrome's Issues drawer tool (More tools › Issues): a toolbar with
/// "Include third-party cookie issues" and the grouping checkboxes, then
/// one collapsible row per type of issue with its count, explanation,
/// affected resources (linking to Network, Elements and Sources) and
/// Learn more links.
struct DeveloperIssuesView: View {
    let session: DeveloperToolsSession
    @ObservedObject private var model: DeveloperIssuesModel

    init(session: DeveloperToolsSession) {
        self.session = session
        model = DeveloperIssuesModel.model(for: session)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let problem = model.problem {
                Text(problem)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(DeveloperToolsStyle.gutter)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DeveloperToolsStyle.raised)
            }
            if model.groups.isEmpty {
                empty
            } else {
                ScrollViewReader { reader in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(sections) { section in
                                DeveloperIssueSectionView(model: model, section: section, depth: 0)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    // An issue opened from its underline in Elements.
                    .onAppear { scroll(reader) }
                    .onChange(of: model.revealed) { _, _ in scroll(reader) }
                }
            }
        }
        .font(.system(size: 11))
        .onAppear { model.viewAppeared() }
        .onDisappear {
            model.hover(nil)
            model.viewDisappeared()
        }
        .accessibilityIdentifier("developer-issues")
    }

    private func scroll(_ reader: ScrollViewProxy) {
        guard let id = model.revealed else { return }
        DispatchQueue.main.async {
            reader.scrollTo(id, anchor: .top)
            model.revealed = nil
        }
    }

    private var sections: [DeveloperIssueSection] {
        DeveloperIssueRules.sections(model.groups, byKind: model.options.groupByKind, byCategory: model.options.groupByCategory)
    }

    private var toolbar: some View {
        HStack(spacing: DeveloperToolsStyle.controlSpacing + 6) {
            Toggle("Include third-party cookie issues", isOn: $model.options.includeThirdPartyCookies)
                .toggleStyle(.developerCheckbox)
                .help("Show issues about cookies set by cross-site responses, which this browser blocks")
            Divider().frame(height: 14)
            Toggle("Group by category", isOn: $model.options.groupByCategory).toggleStyle(.developerCheckbox)
            Toggle("Group by kind", isOn: $model.options.groupByKind).toggleStyle(.developerCheckbox)
            Spacer(minLength: DeveloperToolsStyle.controlSpacing)
            if model.hidden > 0 {
                Text(model.hidden == 1 ? "1 hidden" : "\(model.hidden) hidden")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                    .help("Third-party cookie issues, shown with Include third-party cookie issues")
            }
            DeveloperIssuesCounter(model: model, compact: true, action: {})
            Menu {
                Toggle("Show low text contrast issues", isOn: $model.showLowContrast)
            } label: {
                Image(systemName: "gearshape")
                    .frame(width: DeveloperToolsStyle.controlHeight, height: DeveloperToolsStyle.controlHeight)
                    .accessibilityLabel("Issues settings")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Issues settings")
        }
        .padding(.horizontal, DeveloperToolsStyle.gutter)
        .frame(height: DeveloperToolsStyle.toolbarHeight)
        .background(DeveloperToolsStyle.chrome)
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.bubble").font(.system(size: 24)).foregroundStyle(.secondary)
            Text(model.hidden > 0 ? "Only third-party cookie issues detected so far" : "No issues detected so far")
                .font(.system(size: 12, weight: .semibold))
            Text("Issues the page runs into (Content Security Policy, mixed content, CORS, cookies, forms and deprecations) are listed here as they happen.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            if model.hidden > 0 {
                Button("Include third-party cookie issues") { model.options.includeThirdPartyCookies = true }
                    .controlSize(.small)
            }
        }
        .padding(DeveloperToolsStyle.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A heading (a kind, a category) and what's under it.
private struct DeveloperIssueSectionView: View {
    @ObservedObject var model: DeveloperIssuesModel
    let section: DeveloperIssueSection
    let depth: Int

    private var key: String { "section:" + section.id }
    /// Headings start open; a click folds one away.
    private var open: Bool { !model.expanded.contains(key) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !section.title.isEmpty {
                Button {
                    if open { model.expanded.insert(key) } else { model.expanded.remove(key) }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: open ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 10)
                        if let kind = section.kind {
                            Image(systemName: kind.icon).foregroundStyle(DeveloperIssueTheme.color(kind))
                        }
                        Text(section.title).fontWeight(.semibold)
                        Text("\(section.count)").foregroundStyle(.secondary).monospacedDigit()
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, DeveloperToolsStyle.gutter + CGFloat(depth) * 14)
                    .padding(.trailing, DeveloperToolsStyle.gutter)
                    .frame(height: DeveloperToolsStyle.rowHeight + 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(depth == 0 ? DeveloperToolsStyle.raised : Color.clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider()
            }
            if open || section.title.isEmpty {
                ForEach(section.children) { child in
                    DeveloperIssueSectionView(model: model, section: child, depth: depth + 1)
                }
                ForEach(section.groups) { group in
                    DeveloperIssueRow(model: model, group: group, indent: section.title.isEmpty ? 0 : depth + 1)
                }
            }
        }
    }
}

/// One type of issue: severity, title and count, and when open its
/// explanation, the resources it affects and where to read more.
private struct DeveloperIssueRow: View {
    @ObservedObject var model: DeveloperIssuesModel
    let group: DeveloperIssueGroup
    let indent: Int

    private var open: Bool { model.expanded.contains(group.id) }
    private var leading: CGFloat { DeveloperToolsStyle.gutter + CGFloat(indent) * 14 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if open { model.expanded.remove(group.id) } else { model.expanded.insert(group.id) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 10)
                    Image(systemName: group.kind.icon)
                        .foregroundStyle(DeveloperIssueTheme.color(group.kind))
                        .help(group.kind.name)
                    Text(group.title)
                        .lineLimit(open ? nil : 1)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 6)
                    Text("\(group.count)")
                        .monospacedDigit()
                        .padding(.horizontal, 6)
                        .frame(minWidth: 18, minHeight: 16)
                        .background(DeveloperIssueTheme.color(group.kind).opacity(0.18), in: Capsule())
                        .accessibilityLabel(group.count == 1 ? "1 issue" : "\(group.count) issues")
                }
                .padding(.leading, leading)
                .padding(.trailing, DeveloperToolsStyle.gutter)
                .padding(.vertical, 4)
                .frame(minHeight: DeveloperToolsStyle.rowHeight + 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(open ? DeveloperToolsStyle.selected : Color.clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button("Copy issue title") { DeveloperToolsSession.copyToPasteboard(group.title) }
            }
            if open { details }
            Divider()
        }
        .id(group.id)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let subtitle = group.subtitle {
                Text(subtitle)
                    .font(DeveloperToolsStyle.code)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(group.code.explanation)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(DeveloperAffectedResource.Kind.allCases, id: \.self) { kind in
                let items = group.resources(kind)
                if !items.isEmpty {
                    DeveloperIssueResources(model: model, groupID: group.id, kind: kind, items: items)
                }
            }
            if !group.code.links.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Learn more").foregroundStyle(.secondary)
                    ForEach(group.code.links, id: \.self) { link in
                        Button {
                            if let url = URL(string: link.url) { DevHost.open(url) }
                        } label: {
                            Label(link.title, systemImage: "arrow.up.forward.square")
                                .foregroundStyle(ConsoleTheme.verbose)
                        }
                        .buttonStyle(.plain)
                        .help(link.url)
                    }
                }
            }
        }
        .padding(.leading, leading + 26)
        .padding(.trailing, DeveloperToolsStyle.gutter)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// "3 requests": a fold of the resources of one kind an issue affects.
private struct DeveloperIssueResources: View {
    @ObservedObject var model: DeveloperIssuesModel
    let groupID: String
    let kind: DeveloperAffectedResource.Kind
    let items: [DeveloperAffectedResource]

    private var key: String { groupID + "#" + kind.rawValue }
    /// Resource folds start open, as Chrome's do once the issue is.
    private var open: Bool { !model.expanded.contains(key) }
    private static let shownLimit = 200

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                if open { model.expanded.insert(key) } else { model.expanded.remove(key) }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 10)
                    Text(kind.count(items.count)).fontWeight(.semibold)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(items.prefix(Self.shownLimit).enumerated()), id: \.offset) { _, item in
                        DeveloperIssueResourceRow(model: model, item: item)
                    }
                    if items.count > Self.shownLimit {
                        Text("and \(items.count - Self.shownLimit) more").foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 14)
            }
        }
    }
}

/// One affected resource, with links to where it lives.
private struct DeveloperIssueResourceRow: View {
    @ObservedObject var model: DeveloperIssuesModel
    let item: DeveloperAffectedResource

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            primary
            if let detail = item.detail, !detail.isEmpty {
                Text(detail)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 4)
            if item.kind != .source, let location = item.location, let url = item.url, let line = item.line {
                link(location, help: "Open in Sources") { model.reveal(source: url, line: line, column: item.column) }
            }
            if item.kind != .request, let id = item.requestID {
                link("Network", help: "Show the request in the Network panel") { model.reveal(request: id) }
            }
        }
        .frame(minHeight: 16)
    }

    @ViewBuilder
    private var primary: some View {
        switch item.kind {
        case .request:
            if let id = item.requestID {
                link(item.label, help: "Show the request in the Network panel") { model.reveal(request: id) }
            } else {
                code(item.label)
            }
        case .element:
            if let element = item.element, model.canReveal(element) {
                link(item.label, help: "Reveal in Elements") { model.reveal(element) }
                    .onHover { model.hover($0 ? element : nil) }
            } else {
                code(item.label)
            }
        case .source:
            if let url = item.url, let line = item.line {
                link(item.label, help: "Open in Sources") { model.reveal(source: url, line: line, column: item.column) }
            } else {
                code(item.label)
            }
        case .directive, .cookie:
            code(item.label)
        }
    }

    private func code(_ text: String) -> some View {
        Text(text)
            .font(DeveloperToolsStyle.code)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
            .help(text)
    }

    private func link(_ text: String, help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(DeveloperToolsStyle.code)
                .underline()
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(ConsoleTheme.verbose)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Chrome's issue counter: an icon and a count for each kind there are
/// issues of. A click opens the Issues tool. Shows nothing with no issues.
struct DeveloperIssuesCounter: View {
    @ObservedObject var model: DeveloperIssuesModel
    /// In the Issues toolbar itself, where a click has nowhere to go.
    var compact = false
    /// What a click does; nil opens the Issues tool.
    var action: (() -> Void)?

    var body: some View {
        let counts = model.counts
        let kinds = DeveloperIssueKind.allCases.filter { (counts[$0] ?? 0) > 0 }
        if !kinds.isEmpty {
            Button {
                if let action { action() } else { DeveloperIssuesModel.show() }
            } label: {
                HStack(spacing: 5) {
                    ForEach(kinds) { kind in
                        HStack(spacing: 2) {
                            Image(systemName: kind.icon).foregroundStyle(DeveloperIssueTheme.color(kind))
                            Text(Self.number(counts[kind] ?? 0)).monospacedDigit()
                        }
                    }
                }
                .frame(height: DeveloperToolsStyle.controlHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(kinds.map { $0.count(counts[$0] ?? 0) }.joined(separator: ", ") + (compact ? "" : ". Open Issues to view them."))
            .accessibilityLabel(kinds.map { $0.count(counts[$0] ?? 0) }.joined(separator: ", "))
        }
    }

    static func number(_ count: Int) -> String { count > 999 ? "999+" : "\(count)" }
}

/// The counter at the DevTools toolbar's right and in the Console's
/// toolbar ("2 Issues: …"), as Chrome shows them.
struct DeveloperIssuesBadge: View {
    @ObservedObject private var model: DeveloperIssuesModel
    /// The Console's form, with its "N Issues:" text.
    private let labelled: Bool

    init(session: DeveloperToolsSession, labelled: Bool = false) {
        model = DeveloperIssuesModel.model(for: session)
        self.labelled = labelled
    }

    var body: some View {
        let total = model.total
        if total > 0 {
            HStack(spacing: 4) {
                if labelled {
                    Button { DeveloperIssuesModel.show() } label: {
                        Text(total == 1 ? "1 Issue:" : "\(DeveloperIssuesCounter.number(total)) Issues:")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                }
                DeveloperIssuesCounter(model: model)
            }
            .padding(.horizontal, 4)
            .fixedSize()
        }
    }
}
