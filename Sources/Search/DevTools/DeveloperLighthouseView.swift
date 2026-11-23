import SwiftUI

/// Chrome DevTools' Lighthouse panel, as Search's own implementation of
/// Lighthouse's audits: the start view (mode, device, categories, Analyze),
/// a run's progress, and the report: a score gauge per category, the
/// metrics, the audits in Lighthouse's groups with their details, a filter,
/// and the runtime settings, with View treemap and View trace under the
/// metrics. Past reports are in the toolbar's menu; each exports as
/// Lighthouse's JSON (LHR).
struct DeveloperLighthouseView: View {
    let session: DeveloperToolsSession
    @ObservedObject private var model: DeveloperLighthouseModel

    init(session: DeveloperToolsSession) {
        self.session = session
        model = DeveloperLighthouseModel.model(for: session)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let problem = model.problem {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    Text(problem).textSelection(.enabled)
                    Spacer(minLength: 0)
                    DeveloperPanelIcon(symbol: "xmark", title: "Dismiss", size: 16) { model.problem = nil }
                }
                .padding(DeveloperToolsStyle.gutter)
                .background(DeveloperToolsStyle.raised)
            }
            if model.running {
                DeveloperLighthouseProgress(model: model)
            } else if model.starting || model.selected == nil {
                DeveloperLighthouseStart(model: model, session: session)
            } else if let report = model.selected {
                DeveloperLighthouseReportView(model: model, report: report).id(report.id)
            }
        }
        .font(.system(size: 11))
        .accessibilityIdentifier("developer-lighthouse")
    }

    private var toolbar: some View {
        HStack(spacing: DeveloperToolsStyle.controlSpacing) {
            DeveloperPanelIcon(symbol: "plus", title: "Perform an audit…") { model.starting = true }
                .disabled(model.running)
            Menu {
                ForEach(model.reports.reversed()) { report in
                    Button {
                        model.selectedID = report.id
                        model.starting = false
                    } label: {
                        if report.id == model.selected?.id, !model.starting {
                            Label(report.title, systemImage: "checkmark")
                        } else {
                            Text(report.title)
                        }
                    }
                }
                if model.reports.isEmpty { Text("No reports") }
            } label: {
                Text(model.starting || model.selected == nil ? "(new report)" : model.selected?.title ?? "Reports").lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(model.running || model.reports.isEmpty)
            .help("Reports")
            Divider().frame(height: 16)
            Menu {
                Button("Save as JSON…") { if let report = model.selected { model.export(report) } }
                Button("Copy JSON") { if let report = model.selected { model.copyJSON(report) } }
                Divider()
                Button("Save as HTML…") { if let report = model.selected { model.exportHTML(report) } }
                Button("Open in browser") { if let report = model.selected { model.openInBrowser(report) } }
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(model.selected == nil || model.starting || model.running)
            .help("Export report")
            DeveloperPanelIcon(symbol: "trash", title: "Delete report") {
                if let report = model.selected { model.removeReport(report.id) }
            }
            .disabled(model.selected == nil || model.starting || model.running)
            Spacer(minLength: 0)
            Text("Search's implementation of Lighthouse audits").foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, DeveloperToolsStyle.gutter)
        .frame(height: DeveloperToolsStyle.toolbarHeight)
        .background(DeveloperToolsStyle.chrome)
    }
}

// MARK: Start

private struct DeveloperLighthouseStart: View {
    @ObservedObject var model: DeveloperLighthouseModel
    @ObservedObject var session: DeveloperToolsSession

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Generate a Lighthouse report").font(.system(size: 13, weight: .semibold))
                    Text("Search's own implementation of Lighthouse's audits, with Lighthouse's categories, weights and scoring, run on WebKit. Lighthouse itself drives Chrome and can't run here, so some audits are estimated or not applicable, and each says so.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                HStack(alignment: .top, spacing: 32) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Mode").font(.system(size: 11, weight: .semibold))
                        Picker("Mode", selection: $model.mode) {
                            ForEach(DeveloperLighthouseMode.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.radioGroup).labelsHidden()
                        Text(model.mode.summary).foregroundStyle(.secondary).frame(maxWidth: 260, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Device").font(.system(size: 11, weight: .semibold))
                        Picker("Device", selection: $model.formFactor) {
                            ForEach(DeveloperLighthouseFormFactor.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.radioGroup).labelsHidden()
                        .disabled(model.mode != .navigation)
                        Text(deviceNote).foregroundStyle(.secondary).frame(maxWidth: 260, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Throttling").font(.system(size: 11, weight: .semibold))
                        Picker("Throttling", selection: $model.throttling) {
                            ForEach(DeveloperLighthouseThrottling.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.radioGroup).labelsHidden()
                        .disabled(model.mode != .navigation)
                        Text(model.mode == .navigation ? model.throttling.summary : "Only a Navigation run is throttled.")
                            .foregroundStyle(.secondary).frame(maxWidth: 260, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Toggle("Clear storage", isOn: $model.clearStorage)
                            .toggleStyle(.developerCheckbox)
                            .disabled(model.mode != .navigation)
                            .help("Before the load, removes the site's caches, service workers and stored data (not its cookies), as Lighthouse resets storage.")
                            .padding(.top, 4)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Categories").font(.system(size: 11, weight: .semibold))
                        ForEach(DeveloperLighthouseCategoryID.allCases) { category in
                            Toggle(category.title, isOn: Binding(
                                get: { model.categories.contains(category) && model.mode.categories.contains(category) },
                                set: { _ in model.toggle(category) }))
                                .toggleStyle(.developerCheckbox)
                                .disabled(!model.mode.categories.contains(category))
                                .help(model.mode.categories.contains(category) ? String() : "Not supported in \(model.mode.rawValue.lowercased()) mode")
                        }
                    }
                }
                HStack {
                    Button(startTitle) { model.start() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!session.ready || !model.mode.categories.contains(where: model.categories.contains))
                    if !model.reports.isEmpty {
                        Button("Cancel") { model.starting = false }
                    }
                }
                if model.mode == .navigation {
                    Text(navigationNote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(DeveloperToolsStyle.gutter + 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var startTitle: String {
        switch model.mode {
        case .navigation: "Analyze page load"
        case .timespan: "Start timespan"
        case .snapshot: "Analyze page state"
        }
    }

    private var navigationNote: String {
        let storage = model.clearStorage ? ", after clearing the site's storage" : ""
        let throttled = switch model.throttling {
        case .simulated: "The metrics are then simulated on Lighthouse's \(DeveloperLighthouseLantern.Settings.lighthouse(model.formFactor).summary)."
        case .devtools: model.formFactor == .mobile ? "The network is slowed to Slow 4G for the load; the CPU isn't." : "Desktop DevTools throttling slows neither network nor CPU."
        case .none: "Network and CPU aren't throttled, so the metrics are this Mac's."
        }
        return "The page reloads with the cache disabled\(storage). " + throttled
    }

    private var deviceNote: String {
        guard model.mode == .navigation else { return "\(model.mode.rawValue) mode audits the page in the window's own viewport." }
        let factor = model.formFactor
        return "Emulated with the device toolbar: \(factor.width)×\(factor.height) at \(factor.deviceScaleFactor.formatted())×"
            + (factor == .mobile ? " with a mobile user agent." : ".") + " Put back afterwards."
    }
}

private struct DeveloperLighthouseProgress: View {
    @ObservedObject var model: DeveloperLighthouseModel

    var body: some View {
        VStack(spacing: 12) {
            if model.phase == .timespan {
                Image(systemName: "record.circle").font(.system(size: 20)).foregroundStyle(.red)
                Text(model.phase.title).foregroundStyle(.secondary)
                HStack {
                    Button("End timespan") { model.endTimespan() }
                        .keyboardShortcut(.defaultAction)
                    Button("Cancel") { model.cancel() }
                }
            } else {
                ProgressView().controlSize(.small)
                Text(model.phase.title).foregroundStyle(.secondary)
                Button("Cancel") { model.cancel() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: Report

enum DeveloperLighthouseColors {
    // Lighthouse's report colours.
    static let fail = Color(red: 1, green: 0.2, blue: 0.2)
    static let average = Color(red: 1, green: 0.64, blue: 0)
    static let pass = Color(red: 0, green: 0.8, blue: 0.4)

    /// Lighthouse's titles and descriptions use Markdown's `code` spans.
    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    static func color(_ score: Double?) -> Color {
        guard let score else { return .secondary }
        switch DeveloperLighthouseScoring.rating(score) {
        case .fail: return fail
        case .average: return average
        case .pass: return pass
        }
    }
}

/// A category's score as Lighthouse's gauge draws it.
private struct DeveloperLighthouseGauge: View {
    let score: Double?
    var fraction: (passed: Int, total: Int)?
    var size: CGFloat = 56

    var body: some View {
        let color = fraction != nil ? Color.secondary : DeveloperLighthouseColors.color(score)
        let filled = fraction.map { $0.total > 0 ? Double($0.passed) / Double($0.total) : 0 } ?? score ?? 0
        ZStack {
            Circle().fill(color.opacity(0.1))
            Circle().stroke(color.opacity(0.18), lineWidth: size / 14)
            Circle().trim(from: 0, to: filled).stroke(color, style: StrokeStyle(lineWidth: size / 14, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Group {
                if let fraction {
                    Text("\(fraction.passed)/\(fraction.total)")
                } else if let score {
                    Text("\(Int((score * 100).rounded()))")
                } else {
                    Text("–")
                }
            }
            .font(.system(size: size * 0.32, weight: .medium, design: .monospaced))
            .foregroundStyle(color)
        }
        .frame(width: size, height: size)
    }
}

private struct DeveloperLighthouseReportView: View {
    @ObservedObject var model: DeveloperLighthouseModel
    let report: DeveloperLighthouseReport
    @State private var filter = ""
    @State private var expanded = Set<String>()
    @State private var openGroups = Set<String>()
    @State private var showingTreemap = false

    var body: some View {
        ScrollViewReader { scroll in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 28) {
                        Spacer(minLength: 0)
                        ForEach(report.categories) { category in
                            Button {
                                withAnimation { scroll.scrollTo(category.id.rawValue, anchor: .top) }
                            } label: {
                                VStack(spacing: 6) {
                                    gauge(category, size: 52)
                                    Text(category.title).foregroundStyle(.primary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 16)
                    legend
                    HStack {
                        TextField("Filter audits", text: $filter).developerToolsField().frame(maxWidth: 260)
                        Spacer(minLength: 0)
                        Text(report.finalURL).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    .padding(.horizontal, DeveloperToolsStyle.gutter + 8).padding(.vertical, 8)
                    if !report.warnings.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(report.warnings, id: \.self) { warning in
                                Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, DeveloperToolsStyle.gutter + 8).padding(.bottom, 8)
                    }
                    ForEach(report.categories) { category in
                        Divider()
                        section(category).id(category.id.rawValue)
                    }
                    Divider()
                    footer
                }
            }
        }
        .sheet(isPresented: $showingTreemap) {
            DeveloperLighthouseTreemapView(roots: report.treemap, title: report.title) { showingTreemap = false }
        }
    }

    private func gauge(_ category: DeveloperLighthouseCategory, size: CGFloat) -> some View {
        let fraction = report.mode != .navigation && category.id == .performance ? report.fraction(category) : nil
        return DeveloperLighthouseGauge(score: category.score, fraction: fraction, size: size)
    }

    private var legend: some View {
        HStack(spacing: 14) {
            Spacer(minLength: 0)
            legendItem("0–49", DeveloperLighthouseColors.fail)
            legendItem("50–89", DeveloperLighthouseColors.average)
            legendItem("90–100", DeveloperLighthouseColors.pass)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
    }

    private func legendItem(_ text: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text)
        }
    }

    @ViewBuilder
    private func section(_ category: DeveloperLighthouseCategory) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                gauge(category, size: 72)
                VStack(alignment: .leading, spacing: 4) {
                    Text(category.title).font(.system(size: 15, weight: .semibold))
                    Text(category.id.description).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 14)
            if category.id == .performance {
                metrics
                if report.mode == .navigation { reportTools }
            }
            ForEach(report.sections(category, filter: filter), id: \.id) { group in
                groupView(category, group)
            }
        }
        .padding(.horizontal, DeveloperToolsStyle.gutter + 8)
        .padding(.bottom, 14)
    }

    private var metrics: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("METRICS").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12, alignment: .topLeading)],
                      alignment: .leading, spacing: 10) {
                ForEach(DeveloperLighthouseMetric.allCases) { metric in
                    if let audit = report.audit(metric.rawValue) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 5) {
                                status(audit)
                                Text(metric.title)
                            }
                            if let value = audit.displayValue {
                                Text(value).font(.system(size: 18, weight: .regular, design: .monospaced))
                                    .foregroundStyle(DeveloperLighthouseColors.color(audit.score))
                            } else {
                                Text("n/a").font(.system(size: 18, design: .monospaced)).foregroundStyle(.secondary)
                            }
                            if let explanation = audit.explanation {
                                Text(explanation).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                            ForEach(audit.warnings, id: \.self) { warning in
                                Text(warning).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            Text(report.mode == .timespan
                 ? String("Values are estimated and may vary. Measured over the timespan, from when it started to when it ended.")
                 : String("Values are estimated and may vary. The performance score is calculated directly from these metrics; those that couldn't be measured are left out and the others' weights re-normalised."))
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Chrome's View Treemap and View Trace, under the metrics.
    private var reportTools: some View {
        HStack(spacing: DeveloperToolsStyle.controlSpacing) {
            Button {
                showingTreemap = true
            } label: {
                Label("View treemap", systemImage: "square.grid.2x2")
            }
            .disabled(report.treemap.isEmpty)
            .help(report.treemap.isEmpty ? "No scripts' text was read in this run." : "The page's JavaScript by script and source-map module")
            Button {
                model.viewTrace(report)
            } label: {
                Label("View trace", systemImage: "waveform.path.ecg")
            }
            .disabled(!model.hasTrace(report))
            .help(model.hasTrace(report) ? "Open the run's recording in the Performance panel"
                  : "This run has no trace: Performance was already recording, or the report is from before.")
            Spacer(minLength: 0)
        }
        .padding(.top, 2)
    }

    @ViewBuilder
    private func groupView(_ category: DeveloperLighthouseCategory, _ group: DeveloperLighthouseReport.Section) -> some View {
        let key = category.id.rawValue + "|" + group.id
        let open = group.collapsed ? openGroups.contains(key) : !openGroups.contains(key)
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if openGroups.contains(key) { openGroups.remove(key) } else { openGroups.insert(key) }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold))
                        .frame(width: 10)
                    Text(group.title.uppercased()).font(.system(size: 10, weight: .semibold))
                    Text("(\(group.audits.count))").foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.vertical, 6)
            if open {
                if let description = group.description {
                    Text(DeveloperLighthouseColors.markdown(description)).foregroundStyle(.secondary).padding(.bottom, 4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(group.audits) { audit in
                    auditRow(audit, key: key)
                    Divider()
                }
            }
        }
    }

    @ViewBuilder
    private func status(_ audit: DeveloperLighthouseAudit) -> some View {
        if audit.mode == .notApplicable || audit.mode == .informative || audit.score == nil {
            Circle().stroke(Color.secondary, lineWidth: 1).frame(width: 8, height: 8)
        } else {
            switch DeveloperLighthouseScoring.rating(audit.score ?? 0) {
            case .fail:
                Image(systemName: "triangle.fill").font(.system(size: 8)).foregroundStyle(DeveloperLighthouseColors.fail)
            case .average:
                Rectangle().fill(DeveloperLighthouseColors.average).frame(width: 8, height: 8)
            case .pass:
                Circle().fill(DeveloperLighthouseColors.pass).frame(width: 8, height: 8)
            }
        }
    }

    @ViewBuilder
    private func auditRow(_ audit: DeveloperLighthouseAudit, key: String) -> some View {
        let id = key + "|" + audit.id
        let open = expanded.contains(id)
        VStack(alignment: .leading, spacing: 6) {
            Button {
                if open { expanded.remove(id) } else { expanded.insert(id) }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    status(audit).frame(width: 10)
                    Text(DeveloperLighthouseColors.markdown(audit.title)).frame(maxWidth: .infinity, alignment: .leading)
                    if let value = audit.displayValue {
                        Text(value).foregroundStyle(DeveloperLighthouseColors.color(audit.score)).lineLimit(1)
                    }
                    Image(systemName: open ? "chevron.up" : "chevron.down").font(.system(size: 9)).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 5)
            if open {
                VStack(alignment: .leading, spacing: 6) {
                    Text(DeveloperLighthouseColors.markdown(audit.description)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let explanation = audit.explanation {
                        Text(DeveloperLighthouseColors.markdown(explanation)).fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(audit.warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                    }
                    if let details = audit.details, !details.items.isEmpty {
                        DeveloperLighthouseTable(model: model, details: details)
                    }
                    Text(audit.id).font(DeveloperToolsStyle.code).foregroundStyle(.tertiary)
                }
                .padding(.leading, 16).padding(.bottom, 8)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Runtime settings").font(.system(size: 11, weight: .semibold))
            row("URL", report.finalURL)
            if report.requestedURL != report.finalURL { row("Requested URL", report.requestedURL) }
            row("Fetch time", report.fetchTime.formatted(date: .abbreviated, time: .standard))
            row("Mode", report.mode.rawValue)
            row("Device", report.mode == .navigation ? report.formFactor.rawValue : "Window's own viewport")
            if let viewport = report.viewport { row("Viewport", viewport.summary) }
            row("Emulation", report.emulation)
            if report.mode == .navigation {
                row("Throttling", report.simulation?.summary ?? report.throttling.rawValue)
                if let simulation = report.simulation {
                    row("Simulated TTI", DeveloperLighthouseRules.seconds(simulation.interactive.value))
                }
            }
            if !report.userAgent.isEmpty { row("User agent", report.userAgent) }
            row("Run time", String(format: "%.1f s", report.totalTime / 1_000))
            row("Generated by", "Search's implementation of Lighthouse audits (shaped like Lighthouse \(DeveloperLighthouseLHR.version); not Lighthouse itself)")
        }
        .padding(DeveloperToolsStyle.gutter + 8)
        .textSelection(.enabled)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
            Text(value).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// An audit's details: its headings as columns, a node's cell linked to
/// Elements (hover to highlight, click to reveal) while the page is the one audited.
private struct DeveloperLighthouseTable: View {
    @ObservedObject var model: DeveloperLighthouseModel
    let details: DeveloperLighthouseDetails

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                ForEach(Array(details.headings.enumerated()), id: \.offset) { offset, heading in
                    Text(heading.label).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                        .frame(maxWidth: offset == 0 ? .infinity : 130, alignment: offset == 0 ? .leading : .trailing)
                }
            }
            .padding(.vertical, 4).padding(.horizontal, 6)
            .background(DeveloperToolsStyle.raised)
            ForEach(Array(details.items.prefix(200).enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 8) {
                    ForEach(Array(details.headings.enumerated()), id: \.offset) { offset, heading in
                        cell(item[heading.key])
                            .frame(maxWidth: offset == 0 ? .infinity : 130, alignment: offset == 0 ? .leading : .trailing)
                    }
                }
                .padding(.vertical, 3).padding(.horizontal, 6)
                Divider()
            }
            if details.items.count > 200 {
                Text("\(details.items.count - 200) more not shown").foregroundStyle(.secondary).padding(6)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(DeveloperToolsStyle.rule))
    }

    @ViewBuilder
    private func cell(_ value: DeveloperLighthouseValue?) -> some View {
        switch value {
        case .none:
            Text("")
        case .some(.text(let text)):
            Text(text).fixedSize(horizontal: false, vertical: true)
        case .some(.url(let url)):
            Text(url.isEmpty ? "—" : url).lineLimit(2).truncationMode(.middle).help(url).textSelection(.enabled)
        case .some(.code(let code)):
            Text(code).font(DeveloperToolsStyle.code).lineLimit(3).textSelection(.enabled)
        case .some(.bytes(let bytes)):
            Text(DeveloperLighthouseRules.kib(bytes)).font(DeveloperToolsStyle.code)
        case .some(.ms(let ms)):
            Text(DeveloperLighthouseRules.ms(ms)).font(DeveloperToolsStyle.code)
        case .some(.numeric(let number)):
            Text(number.formatted()).font(DeveloperToolsStyle.code)
        case .some(.node(let node)):
            DeveloperLighthouseNodeCell(model: model, node: node)
        }
    }
}

private struct DeveloperLighthouseNodeCell: View {
    @ObservedObject var model: DeveloperLighthouseModel
    let node: DeveloperLighthouseNode
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if !node.label.isEmpty, node.label != node.snippet {
                Text(node.label).lineLimit(1)
            }
            Text(node.snippet.isEmpty ? node.selector : node.snippet)
                .font(DeveloperToolsStyle.code)
                .underline(hovering && model.live)
                .foregroundStyle(model.live ? DeveloperToolsStyle.tint : Color.secondary)
                .lineLimit(2)
        }
        .help(model.live ? "Reveal in Elements: " + node.selector : node.selector)
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            model.hover(inside && model.live ? node.index : nil)
        }
        .onTapGesture { model.reveal(node.index) }
    }
}

// MARK: Grouping

extension DeveloperLighthouseReport {
    /// One collapsible group of a category's audits.
    struct Section {
        var id: String
        var title: String
        var description: String?
        var audits: [DeveloperLighthouseAudit]
        var collapsed: Bool
    }

    /// A category's audits as Lighthouse's report groups them: for
    /// Performance, Opportunities and Diagnostics; for the others, the
    /// failing audits by their group; then Passed audits and Not
    /// applicable, both collapsed. Metrics are shown on their own.
    func sections(_ category: DeveloperLighthouseCategory, filter: String = "") -> [Section] {
        let query = filter.trimmingCharacters(in: .whitespaces).lowercased()
        let refs = category.refs.filter { ref in
            guard DeveloperLighthouseMetric(rawValue: ref.id) == nil, let audit = audits[ref.id] else { return false }
            return query.isEmpty || audit.title.lowercased().contains(query) || audit.id.contains(query)
        }
        let list = refs.compactMap { ref in audits[ref.id].map { (ref, $0) } }
        let failing = list.filter { !$0.1.passed && $0.1.mode != .notApplicable && $0.1.mode != .informative }
        let informative = list.filter { $0.1.mode == .informative }
        let passed = list.filter { $0.1.passed && $0.1.mode != .notApplicable }
        let notApplicable = list.filter { $0.1.mode == .notApplicable }
        var out: [Section] = []
        if category.id == .performance {
            let opportunities = failing.filter { $0.0.group == "load-opportunities" }.map(\.1).sorted {
                ($0.details?.overallSavingsMs ?? 0) > ($1.details?.overallSavingsMs ?? 0)
            }
            let diagnostics = failing.filter { $0.0.group != "load-opportunities" }.map(\.1) + informative.map(\.1)
            if !opportunities.isEmpty {
                let group = DeveloperLighthouseCatalog.groups["load-opportunities"]
                out.append(Section(id: "opportunities", title: group?.title ?? "Opportunities", description: group?.description,
                                   audits: opportunities, collapsed: false))
            }
            if !diagnostics.isEmpty {
                let group = DeveloperLighthouseCatalog.groups["diagnostics"]
                out.append(Section(id: "diagnostics", title: group?.title ?? "Diagnostics", description: group?.description,
                                   audits: diagnostics, collapsed: false))
            }
        } else {
            var order: [String] = []
            var byGroup: [String: [DeveloperLighthouseAudit]] = [:]
            for (ref, audit) in failing + informative {
                let group = ref.group ?? "other"
                if byGroup[group] == nil { order.append(group) }
                byGroup[group, default: []].append(audit)
            }
            for group in order {
                let info = DeveloperLighthouseCatalog.groups[group]
                out.append(Section(id: group, title: info?.title ?? "Other", description: info?.description,
                                   audits: byGroup[group] ?? [], collapsed: false))
            }
        }
        if !passed.isEmpty {
            out.append(Section(id: "passed", title: "Passed audits", audits: passed.map(\.1), collapsed: true))
        }
        if !notApplicable.isEmpty {
            out.append(Section(id: "notApplicable", title: "Not applicable", audits: notApplicable.map(\.1), collapsed: true))
        }
        return out
    }
}
