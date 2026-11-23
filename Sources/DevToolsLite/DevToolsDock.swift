import SwiftUI

// The panel beside the page: Lighthouse or the Recorder, for the tab in
// front. Search's quiet style: a heading, one control row, the result.

struct DevToolsDock: View {
    @ObservedObject var session: DevToolsSession
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Picker("", selection: Binding(get: { session.panel ?? .lighthouse }, set: { session.panel = $0 })) {
                    Text("Lighthouse").tag(DevTool.lighthouse)
                    Text("Recorder").tag(DevTool.recorder)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer(minLength: 0)
                IconButton(icon: "xmark", help: "Close") {
                    session.panel = nil
                    if session.idle { close() }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Rectangle().fill(Look.hairline).frame(height: 1)
            switch session.panel {
            case .recorder: RecorderPanel(recorder: session.recorder)
            default: LighthousePanel(model: session.lighthouse)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(Look.ink)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Look.ground)
    }
}

// MARK: - Lighthouse

private struct LighthousePanel: View {
    @ObservedObject var model: LighthouseModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Picker("Mode", selection: $model.mode) {
                        ForEach(LighthouseMode.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Device", selection: $model.form) {
                        ForEach(LighthouseFormFactor.allCases) { Text($0.title).tag($0) }
                    }
                }
                .labelsHidden()
                .fixedSize()
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                          alignment: .leading, spacing: 4) {
                    ForEach(LighthouseCategory.allCases) { category in
                        Toggle(category.title, isOn: Binding(
                            get: { model.categories.contains(category) },
                            set: { on in if on { model.categories.insert(category) } else { model.categories.remove(category) } }))
                            .toggleStyle(.checkbox)
                    }
                }
                .font(.system(size: 11))
                HStack {
                    Button(model.running ? "Cancel" : model.mode == .navigation ? "Analyze page load" : "Analyze page") {
                        model.running ? model.cancel() : model.run()
                    }
                    .disabled(!model.running && model.categories.isEmpty)
                    if model.running {
                        ProgressView().controlSize(.small)
                        Text(model.stage).foregroundStyle(Look.muted)
                    }
                    Spacer(minLength: 0)
                    if model.report != nil, !model.running {
                        Button("Save…") { model.saveReport() }
                            .help("Save the report as Lighthouse JSON")
                    }
                }
                if let notice = model.notice {
                    Text(notice).foregroundStyle(Look.unsafe)
                }
            }
            .padding(12)
            Rectangle().fill(Look.hairline).frame(height: 1)
            if let report = model.report {
                ReportView(report: report)
            } else {
                Text("Audits the page in this tab for performance, accessibility, best practices and SEO, the way Lighthouse does, with this package's own checks on WebKit.")
                    .foregroundStyle(Look.muted)
                    .padding(12)
                Spacer(minLength: 0)
            }
        }
    }
}

private struct ReportView: View {
    let report: LighthouseReport

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    ForEach(report.categories) { category in
                        Gauge(title: category.title, score: report.score(category), fraction: report.fraction(category))
                    }
                }
                .frame(maxWidth: .infinity)
                Text("\(report.url)\n\(report.mode.title) · \(report.form.title) · \(Int(report.viewport.width)) × \(Int(report.viewport.height)) · \(report.fetched.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Look.muted)
                    .textSelection(.enabled)
                ForEach(report.warnings, id: \.self) { warning in
                    Text(warning).font(.system(size: 11)).foregroundStyle(Look.unsafe)
                }
                ForEach(report.categories) { category in
                    CategoryView(report: report, category: category)
                }
            }
            .padding(12)
        }
    }
}

private struct Gauge: View {
    let title: String
    let score: Double?
    let fraction: (passed: Int, total: Int)

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle().stroke(Look.hairline, lineWidth: 4)
                if let score {
                    Circle().trim(from: 0, to: score).stroke(color(score), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text("\(Int((score * 100).rounded()))").font(.system(size: 14, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(color(score))
                } else {
                    Text("\(fraction.passed)/\(fraction.total)").font(.system(size: 11, weight: .medium)).monospacedDigit()
                }
            }
            .frame(width: 46, height: 46)
            Text(title).font(.system(size: 10.5)).foregroundStyle(Look.muted).lineLimit(1)
        }
    }
}

private func color(_ score: Double) -> Color {
    let shown = (score * 100).rounded()
    return shown >= 90 ? Look.safe : shown >= 50 ? Look.unsafe : .red
}

private struct CategoryView: View {
    let report: LighthouseReport
    let category: LighthouseCategory
    @State private var showsPassed = false

    var body: some View {
        let audits = report.audits(in: category)
        let failing = audits.filter { $0.scored && !$0.passed || ($0.display == .numeric && $0.value != nil && LighthouseMetric(rawValue: $0.id) != nil) }
        let unmeasured = audits.filter { $0.display == .error }
        let passed = audits.filter { $0.scored && $0.passed && LighthouseMetric(rawValue: $0.id) == nil }
        VStack(alignment: .leading, spacing: 6) {
            Text(category.title).font(.system(size: 13, weight: .semibold))
            ForEach(failing) { AuditRow(audit: $0) }
            ForEach(unmeasured) { AuditRow(audit: $0) }
            if !passed.isEmpty {
                DisclosureGroup("Passed audits (\(passed.count))", isExpanded: $showsPassed) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(passed) { AuditRow(audit: $0) }
                    }
                }
                .foregroundStyle(Look.muted)
            }
        }
    }
}

private struct AuditRow: View {
    let audit: LighthouseAudit
    @State private var open = false

    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            VStack(alignment: .leading, spacing: 4) {
                Text(audit.entry?.description ?? "").foregroundStyle(Look.muted)
                if let explanation = audit.explanation { Text(explanation).foregroundStyle(Look.muted) }
                ForEach(Array(audit.items.prefix(20).enumerated()), id: \.offset) { _, item in
                    VStack(alignment: .leading, spacing: 1) {
                        if let node = item.node {
                            Text(node.label.isEmpty ? node.selector : node.label).lineLimit(1)
                            Text(node.snippet).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Look.muted).lineLimit(2)
                        }
                        if let url = item.url { Text(url).font(.system(size: 10.5)).lineLimit(1).truncationMode(.middle) }
                        if let text = item.text { Text(text).font(.system(size: 10.5)).foregroundStyle(Look.muted) }
                    }
                    .textSelection(.enabled)
                }
            }
            .font(.system(size: 11))
            .padding(.leading, 4)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Circle().fill(dot).frame(width: 7, height: 7)
                // Lighthouse's titles mark code with backticks.
                Text(LocalizedStringKey(audit.title)).lineLimit(2)
                Spacer(minLength: 4)
                if let shown = audit.displayValue {
                    Text(shown).foregroundStyle(Look.muted).monospacedDigit()
                }
            }
        }
    }

    private var dot: Color {
        guard let score = audit.score else { return Look.faint }
        return color(score)
    }
}

// MARK: - Recorder

private struct RecorderPanel: View {
    @ObservedObject var recorder: RecorderModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                switch recorder.state {
                case .recording:
                    Button("Stop") { recorder.stop() }
                    Circle().fill(.red).frame(width: 7, height: 7)
                    Text("Recording").foregroundStyle(Look.muted)
                case .playing(let index):
                    Button("Stop") { recorder.stop() }
                    ProgressView().controlSize(.small)
                    Text("Step \(index + 1) of \(recorder.recording.steps.count)").foregroundStyle(Look.muted)
                default:
                    Button("Record") { recorder.record() }
                    Button("Replay") { recorder.play() }.disabled(recorder.recording.steps.isEmpty)
                }
                Spacer(minLength: 0)
                Menu {
                    Button("Import…") { recorder.importFile() }
                    Button("Export as JSON…") { recorder.export() }.disabled(recorder.recording.steps.isEmpty)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(recorder.busy)
            }
            .padding(12)
            if case .failed(let index, let why) = recorder.state {
                Text("Step \(index + 1) failed: \(why)").foregroundStyle(Look.unsafe).padding(.horizontal, 12).padding(.bottom, 8)
            } else if recorder.state == .played {
                Text("Replayed every step").foregroundStyle(Look.safe).padding(.horizontal, 12).padding(.bottom, 8)
            }
            if let notice = recorder.notice {
                Text(notice).foregroundStyle(Look.unsafe).padding(.horizontal, 12).padding(.bottom, 8)
            }
            Rectangle().fill(Look.hairline).frame(height: 1)
            if recorder.recording.steps.isEmpty {
                Text("Record clicks, typing, keys and scrolls on this page, replay them, and export them as Chrome Recorder JSON.")
                    .foregroundStyle(Look.muted)
                    .padding(12)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(recorder.recording.title).font(.system(size: 12, weight: .semibold)).padding(.bottom, 6)
                        ForEach(Array(recorder.recording.steps.enumerated()), id: \.element.id) { index, step in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("\(index + 1)").monospacedDigit().foregroundStyle(Look.faint).frame(width: 22, alignment: .trailing)
                                Text(step.summary).lineLimit(2).truncationMode(.middle)
                                Spacer(minLength: 0)
                                if !recorder.busy {
                                    Button { recorder.remove(step) } label: { Image(systemName: "minus.circle") }
                                        .buttonStyle(.plain)
                                        .foregroundStyle(Look.faint)
                                        .help("Remove this step")
                                }
                            }
                            .padding(.vertical, 3)
                            .background(highlight(index))
                        }
                    }
                    .padding(12)
                }
            }
        }
    }

    private func highlight(_ index: Int) -> Color {
        switch recorder.state {
        case .playing(let at) where at == index: Look.wash
        case .failed(let at, _) where at == index: Look.unsafe.opacity(0.15)
        default: .clear
        }
    }
}
