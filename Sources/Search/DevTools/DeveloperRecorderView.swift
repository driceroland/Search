import AppKit
import SwiftUI

/// Chrome DevTools' Recorder panel: Create a new recording (a name, the
/// selector attribute and the kinds of selector to record), the
/// recording's steps as they stream in, each expandable and editable,
/// with breakpoints; Replay at a chosen speed, or with Performance
/// recording it; export as JSON, a @puppeteer/replay script or a
/// Puppeteer script; import Chrome's JSON. Recordings are listed in the
/// toolbar's menu.
struct DeveloperRecorderView: View {
    let session: DeveloperToolsSession
    @ObservedObject private var model: DeveloperRecorderModel
    @ObservedObject private var store: DeveloperRecordings

    init(session: DeveloperToolsSession) {
        self.session = session
        let model = DeveloperRecorderModel.model(for: session)
        self.model = model
        store = model.store
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
            if model.creating || store.all.isEmpty {
                DeveloperRecorderCreate(model: model, session: session)
            } else if let recording = model.selected {
                DeveloperRecorderRecording(model: model, recording: recording)
            } else {
                Text("No recording selected.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .font(.system(size: 11))
        .accessibilityIdentifier("developer-recorder")
    }

    private var toolbar: some View {
        HStack(spacing: DeveloperToolsStyle.controlSpacing) {
            DeveloperPanelIcon(symbol: "plus", title: "Create a new recording") { model.creating = true }
                .disabled(model.recording || model.replaying)
            Menu {
                ForEach(store.all.reversed()) { recording in
                    Button {
                        model.selectedID = recording.id
                        model.creating = false
                    } label: {
                        if recording.id == model.selectedID, !model.creating {
                            Label(recording.title, systemImage: "checkmark")
                        } else {
                            Text(recording.title)
                        }
                    }
                }
                if store.all.isEmpty { Text("No recordings") }
            } label: {
                Text(model.creating ? "Create recording" : model.selected?.title ?? "Recordings")
                    .lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(model.recording || model.replaying)
            .help("Recordings")
            Divider().frame(height: 16)
            DeveloperPanelIcon(symbol: "square.and.arrow.down", title: "Import recording") { model.importRecording() }
                .disabled(model.recording || model.replaying)
            Menu {
                ForEach(DeveloperRecorderModel.ExportFormat.allCases) { format in
                    Button(format.rawValue) { model.export(model.selectedID, as: format) }
                }
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(model.selected == nil || model.creating || model.recording)
            .help("Export recording")
            DeveloperPanelIcon(symbol: "trash", title: "Delete recording") {
                if let id = model.selectedID { model.delete(id) }
            }
            .disabled(model.selected == nil || model.creating || model.recording || model.replaying)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DeveloperToolsStyle.gutter)
        .frame(height: DeveloperToolsStyle.toolbarHeight)
        .background(DeveloperToolsStyle.chrome)
    }
}

/// Create a new recording: its name, the selector attribute and the kinds
/// of selector to record, then Start recording.
private struct DeveloperRecorderCreate: View {
    @ObservedObject var model: DeveloperRecorderModel
    let session: DeveloperToolsSession
    @State private var title = DeveloperRecording.defaultTitle()
    @State private var attribute = ""
    @State private var types = Set(DeveloperRecorderSelectorType.allCases)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Create a new recording").font(.system(size: 13, weight: .semibold))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Recording name").foregroundStyle(.secondary)
                    TextField("Recording name", text: $title).textFieldStyle(.roundedBorder).frame(maxWidth: 360)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Selector attribute").foregroundStyle(.secondary)
                    TextField("data-testid", text: $attribute).textFieldStyle(.roundedBorder).frame(maxWidth: 360)
                    Text("Recorded first when an element has it, ahead of the usual test attributes and ids.")
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Selector types to record").foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        ForEach(DeveloperRecorderSelectorType.allCases) { type in
                            Toggle(type.title, isOn: Binding(
                                get: { types.contains(type) },
                                set: { on in if on { types.insert(type) } else if types.count > 1 { types.remove(type) } }
                            ))
                            .toggleStyle(.developerCheckbox)
                        }
                    }
                }
                HStack {
                    Button("Start recording") {
                        model.startRecording(title: title, types: types, attribute: attribute)
                        title = DeveloperRecording.defaultTitle()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!session.ready || model.recording || model.replaying)
                    if !model.store.all.isEmpty {
                        Button("Cancel") { model.creating = false }
                    }
                }
                Text("Steps are recorded as you click, type, press keys, scroll and navigate in the page.")
                    .foregroundStyle(.secondary)
            }
            .padding(DeveloperToolsStyle.gutter + 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// One recording: its title, Replay and its steps.
private struct DeveloperRecorderRecording: View {
    @ObservedObject var model: DeveloperRecorderModel
    let recording: DeveloperRecording
    @State private var expanded = Set<UUID>()
    @State private var editingTitle = false
    @State private var titleText = ""
    /// Show code: the recording as code, beside the steps.
    @State private var showCode = false
    @State private var codeFormat = DeveloperRecorderModel.ExportFormat.json
    @State private var settingsShown = false
    @State private var timeoutText = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !model.recording {
                replaySettings
                Divider()
            }
            HStack(spacing: 0) {
                steps
                if showCode {
                    Divider()
                    code.frame(minWidth: 240, idealWidth: 360, maxWidth: 520)
                }
            }
        }
    }

    // MARK: Replay settings

    /// Chrome's Replay settings: the network to replay under and how long
    /// each step may wait.
    private var replaySettings: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                settingsShown.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .rotationEffect(.degrees(settingsShown ? 90 : 0))
                        .foregroundStyle(.secondary)
                    Text("Replay settings").fontWeight(.medium)
                    if !settingsShown {
                        Text(settingsSummary).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if settingsShown {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 6) {
                    GridRow {
                        Text("Network").foregroundStyle(.secondary)
                        Picker("Network", selection: Binding(
                            get: { model.replayNetwork(recording.id) },
                            set: { model.setReplayNetwork($0, in: recording.id) }
                        )) {
                            ForEach(DeveloperToolsSession.NetworkCondition.allCases) { condition in
                                Text(condition.rawValue).tag(condition)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .help("Network conditions while replaying, as the Network conditions tool throttles")
                    }
                    GridRow {
                        Text("Timeout").foregroundStyle(.secondary)
                        HStack(spacing: 4) {
                            TextField(DeveloperRecorderJSON.format(DeveloperRecorderExport.defaultTimeout), text: $timeoutText)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 80)
                                .onSubmit(commitTimeout)
                            Text("ms").foregroundStyle(.secondary)
                        }
                        .help("The timeout setting (in milliseconds) applies to every step of the replay. "
                              + "Steps with their own timeout keep it.")
                    }
                }
                .padding(.leading, 14)
                .disabled(model.replaying)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, DeveloperToolsStyle.gutter + 4)
        .padding(.vertical, 5)
        .onAppear { timeoutText = recording.timeout.map(DeveloperRecorderJSON.format) ?? "" }
        .onChange(of: recording.id) { _, _ in timeoutText = recording.timeout.map(DeveloperRecorderJSON.format) ?? "" }
        .onChange(of: settingsShown) { _, shown in if !shown { commitTimeout() } }
    }

    private var settingsSummary: String {
        let network = model.replayNetwork(recording.id)
        let timeout = DeveloperRecorderJSON.format(recording.timeout ?? DeveloperRecorderExport.defaultTimeout)
        return (network == .unrestricted ? "No throttling" : network.rawValue) + " · Timeout: \(timeout) ms"
    }

    private func commitTimeout() {
        let text = timeoutText.trimmingCharacters(in: .whitespaces)
        model.setReplayTimeout(text.isEmpty ? nil : Double(text), in: recording.id)
        timeoutText = store(recording.id)?.timeout.map(DeveloperRecorderJSON.format) ?? ""
    }

    private func store(_ id: UUID) -> DeveloperRecording? { model.store.recording(id) }

    // MARK: Show code

    private var code: some View {
        let text = codeFormat.text(recording)
        return VStack(spacing: 0) {
            HStack(spacing: DeveloperToolsStyle.controlSpacing) {
                Picker("Format", selection: $codeFormat) {
                    ForEach(DeveloperRecorderModel.ExportFormat.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .controlSize(.small)
                Spacer(minLength: 0)
                DeveloperPanelIcon(symbol: "doc.on.doc", title: "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                DeveloperPanelIcon(symbol: "xmark", title: "Hide code") { showCode = false }
            }
            .padding(.horizontal, DeveloperToolsStyle.gutter)
            .frame(height: DeveloperToolsStyle.toolbarHeight)
            .background(DeveloperToolsStyle.chrome)
            Divider()
            ScrollView([.vertical, .horizontal]) {
                Text(text)
                    .font(DeveloperToolsStyle.code)
                    .textSelection(.enabled)
                    .fixedSize()
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(DeveloperToolsStyle.gutter)
            }
            .accessibilityIdentifier("developer-recorder-code")
        }
    }

    // MARK: Steps

    private var steps: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(recording.steps.enumerated()), id: \.element.id) { index, step in
                        DeveloperRecorderStepRow(model: model, recordingID: recording.id, step: step,
                                                 last: index == recording.steps.count - 1,
                                                 expanded: Binding(
                                                     get: { expanded.contains(step.id) },
                                                     set: { if $0 { expanded.insert(step.id) } else { expanded.remove(step.id) } }
                                                 ))
                            .id(step.id)
                    }
                    if !model.recording {
                        Button {
                            model.addStep(near: recording.steps.last?.id, after: true, in: recording.id)
                        } label: {
                            Label("Add step", systemImage: "plus")
                        }
                        .buttonStyle(.borderless)
                        .padding(.leading, 34)
                        .padding(.vertical, 8)
                        .disabled(model.replaying)
                    }
                }
                .padding(.vertical, 6)
            }
            .onChange(of: recording.steps.count) { _, _ in
                if model.recording, let last = recording.steps.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    private var header: some View {
        HStack(spacing: DeveloperToolsStyle.controlSpacing + 4) {
            if editingTitle {
                TextField("Title", text: $titleText)
                    .onSubmit {
                        let text = titleText.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !text.isEmpty { model.edit(recording.id) { $0.title = text } }
                        editingTitle = false
                    }
                    .onExitCommand { editingTitle = false }
                    .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)
            } else {
                Text(recording.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    .onTapGesture(count: 2) {
                        guard !model.recording else { return }
                        titleText = recording.title
                        editingTitle = true
                    }
                    .help("Double-click to rename")
            }
            Spacer(minLength: 8)
            if model.recording, model.recordingID == recording.id {
                Circle().fill(.red).frame(width: 8, height: 8)
                Text("Recording…").foregroundStyle(.secondary)
                Button {
                    model.addAssertion()
                } label: {
                    Label("Add assertion", systemImage: "checkmark.seal")
                }
                .help("Add a step that waits for the element last acted on")
                Button("End recording") { model.stopRecording() }
                    .keyboardShortcut(.defaultAction)
            } else if model.replayingID == recording.id {
                if model.pausedAt != nil {
                    Button("Continue") { model.continueReplay() }
                    Button("Step over") { model.continueReplay(stepping: true) }
                } else {
                    ProgressView().controlSize(.mini)
                    Text("Replaying…").foregroundStyle(.secondary)
                }
                Button("Cancel replay") { model.cancelReplay() }
            } else {
                Picker("Speed", selection: $model.speed) {
                    ForEach(DeveloperRecorderSpeed.allCases) { speed in Text(speed.rawValue).tag(speed) }
                }
                .labelsHidden()
                .fixedSize()
                .help("Replay speed")
                Button {
                    model.replay(recording.id, measure: true)
                } label: {
                    Label("Measure performance", systemImage: "waveform.path")
                }
                .disabled(model.recording || model.replaying)
                .help("Replay while the Performance panel records")
                Button {
                    model.replay(recording.id)
                } label: {
                    Label("Replay", systemImage: "play.fill")
                }
                .disabled(model.recording || model.replaying || recording.steps.isEmpty)
            }
            DeveloperPanelIcon(symbol: "chevron.left.forwardslash.chevron.right",
                               title: showCode ? "Hide code" : "Show code", active: showCode) {
                showCode.toggle()
            }
        }
        .controlSize(.small)
        .padding(.horizontal, DeveloperToolsStyle.gutter + 4)
        .padding(.vertical, 6)
    }
}

/// A step in the list: its status on the timeline line, its title and
/// what it acts on; expanded, its fields to edit.
private struct DeveloperRecorderStepRow: View {
    @ObservedObject var model: DeveloperRecorderModel
    let recordingID: UUID
    let step: DeveloperRecorderStep
    let last: Bool
    @Binding var expanded: Bool
    @State private var hovering = false

    private var status: DeveloperRecorderModel.Status? { model.status[step.id] }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            gutter
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    expanded.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .foregroundStyle(.secondary)
                        Text(step.title).fontWeight(.medium)
                        Text(step.subtitle).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        if step.assertsNavigation {
                            Image(systemName: "arrow.turn.down.right").foregroundStyle(.secondary).help("Waits for a navigation")
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if case .failed(let message)? = status {
                    Text(message).foregroundStyle(.red).textSelection(.enabled)
                }
                if expanded {
                    DeveloperRecorderStepEditor(model: model, recordingID: recordingID, step: step)
                        .disabled(model.recording || model.replaying)
                        .padding(.bottom, 6)
                }
            }
            .padding(.vertical, 5)
            .padding(.trailing, DeveloperToolsStyle.gutter)
            if hovering, !model.recording {
                menu.padding(.top, 3).padding(.trailing, DeveloperToolsStyle.gutter)
            }
        }
        .background(model.pausedAt == step.id ? Color.yellow.opacity(0.15) : hovering ? DeveloperToolsStyle.raised : .clear)
        .onHover { hovering = $0 }
        .contextMenu { menuItems }
    }

    /// The breakpoint and status dot on the line joining the steps, as
    /// Chrome draws them; clicking it sets or clears the breakpoint.
    private var gutter: some View {
        ZStack(alignment: .top) {
            Rectangle().fill(DeveloperToolsStyle.rule).frame(width: 2)
                .frame(maxHeight: .infinity)
                .opacity(last ? 0 : 1)
                .padding(.top, 10)
            Button {
                model.toggleBreakpoint(step.id, in: recordingID)
            } label: {
                ZStack {
                    if step.breakpoint {
                        RoundedRectangle(cornerRadius: 3).fill(Color.blue).frame(width: 22, height: 14)
                    }
                    Circle().fill(dotColor).frame(width: 10, height: 10)
                        .overlay(Circle().stroke(Color.white.opacity(step.breakpoint ? 0.9 : 0), lineWidth: 1.5))
                }
                .frame(width: 26, height: 20)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(step.breakpoint ? "Remove breakpoint" : "Add breakpoint")
        }
        .frame(width: 34)
    }

    private var dotColor: Color {
        switch status {
        case .running?: .orange
        case .done?: .green
        case .failed?: .red
        default: DeveloperToolsStyle.tint.opacity(0.85)
        }
    }

    private var menu: some View {
        Menu { menuItems } label: { Image(systemName: "ellipsis") }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
    }

    @ViewBuilder
    private var menuItems: some View {
        Button("Add step before") { model.addStep(near: step.id, after: false, in: recordingID) }
        Button("Add step after") { model.addStep(near: step.id, after: true, in: recordingID) }
        Button("Duplicate step") { model.duplicateStep(step.id, in: recordingID) }
        Button("Remove step") { model.removeStep(step.id, in: recordingID) }
        Divider()
        Button(step.breakpoint ? "Remove breakpoint" : "Add breakpoint") { model.toggleBreakpoint(step.id, in: recordingID) }
    }
}

/// A step's fields: its type, selectors, the fields its type has, and
/// the events it waits for.
private struct DeveloperRecorderStepEditor: View {
    @ObservedObject var model: DeveloperRecorderModel
    let recordingID: UUID
    let step: DeveloperRecorderStep

    private static let booleans: Set<String> = ["isMobile", "hasTouch", "isLandscape", "visible"]
    private static let numbers: Set<String> = ["offsetX", "offsetY", "x", "y", "width", "height", "deviceScaleFactor",
                                               "timeout", "duration", "count", "download", "upload", "latency"]
    private static let choices: [String: [String]] = [
        "button": ["primary", "auxiliary", "secondary", "back", "forward"],
        "deviceType": ["mouse", "pen", "touch"],
        "operator": [">=", "==", "<="],
    ]

    private func change(_ edit: (inout DeveloperRecorderStep) -> Void) {
        model.editStep(step.id, in: recordingID, edit)
    }

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 5) {
            GridRow {
                label("type")
                Picker("type", selection: Binding(
                    get: { step.type },
                    set: { type in
                        guard type != step.type, let kind = DeveloperRecorderStepType(rawValue: type) else { return }
                        change { edited in
                            // The new type's fields, keeping what the two share.
                            var fields = Dictionary(kind.template, uniquingKeysWith: { first, _ in first })
                            for (key, value) in edited.fields where kind.editableFields.contains(key) || key == "selectors" && kind.targetsElement {
                                fields[key] = value
                            }
                            if let events = edited.fields["assertedEvents"] { fields["assertedEvents"] = events }
                            edited.type = type
                            edited.fields = fields
                        }
                    }
                )) {
                    ForEach(DeveloperRecorderStepType.allCases) { kind in Text(kind.rawValue).tag(kind.rawValue) }
                    if step.kind == nil { Text(step.type).tag(step.type) }
                }
                .labelsHidden()
                .fixedSize()
            }
            if step.kind?.targetsElement == true || step.fields["selectors"] != nil {
                GridRow(alignment: .top) {
                    label("selectors")
                    selectors
                }
            }
            ForEach(step.kind?.editableFields ?? step.fields.keys.sorted().filter { $0 != "selectors" && $0 != "assertedEvents" }, id: \.self) { name in
                GridRow {
                    label(name)
                    field(name)
                }
            }
            GridRow(alignment: .top) {
                label("assertedEvents")
                events
            }
        }
        .font(DeveloperToolsStyle.code)
        .textFieldStyle(.roundedBorder)
        .controlSize(.small)
    }

    private func label(_ name: String) -> some View {
        Text(name).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
    }

    @ViewBuilder
    private func field(_ name: String) -> some View {
        if Self.booleans.contains(name) {
            Toggle("", isOn: Binding(
                get: { step[name]?.bool ?? false },
                set: { on in change { $0[name] = .bool(on) } }
            ))
            .labelsHidden()
            .toggleStyle(.developerCheckbox)
        } else if let options = Self.choices[name] {
            Picker(name, selection: Binding(
                get: { step[name]?.string ?? "" },
                set: { value in change { $0[name] = value.isEmpty ? nil : .string(value) } }
            )) {
                Text("—").tag("")
                ForEach(options, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
        } else if Self.numbers.contains(name) {
            DeveloperRecorderNumberField(value: step[name]?.number) { value in
                change { $0[name] = value.map { .number($0) } }
            }
            .frame(maxWidth: 120)
        } else {
            TextField(name, text: Binding(
                get: { step[name]?.string ?? "" },
                set: { value in change { $0[name] = value.isEmpty && name != "value" ? nil : .string(value) } }
            ))
            .frame(maxWidth: 420)
        }
    }

    /// Each alternative on a line; a selector through shadow roots has a
    /// field per part.
    private var selectors: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(step.selectors.enumerated()), id: \.offset) { index, parts in
                HStack(spacing: 4) {
                    Text(DeveloperRecorderSelector.kind(of: parts.first ?? "").title)
                        .foregroundStyle(.tertiary).frame(width: 44, alignment: .leading)
                    ForEach(Array(parts.enumerated()), id: \.offset) { part, text in
                        TextField("selector", text: Binding(
                            get: { text },
                            set: { value in
                                change { edited in
                                    var all = edited.selectors
                                    guard all.indices.contains(index), all[index].indices.contains(part) else { return }
                                    all[index][part] = value
                                    edited.selectors = all
                                }
                            }
                        ))
                        .frame(minWidth: 120, maxWidth: 360)
                    }
                    DeveloperPanelIcon(symbol: "minus", title: "Remove selector", size: 16) {
                        change { edited in
                            var all = edited.selectors
                            guard all.indices.contains(index) else { return }
                            all.remove(at: index)
                            edited.selectors = all
                        }
                    }
                }
            }
            DeveloperPanelIcon(symbol: "plus", title: "Add a selector", size: 16) {
                change { $0.selectors.append([".selector"]) }
            }
        }
    }

    private var events: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(step.assertedEvents.enumerated()), id: \.offset) { index, event in
                HStack(spacing: 4) {
                    Text(event.type).foregroundStyle(.tertiary)
                    TextField("url", text: eventBinding(index, \.url)).frame(minWidth: 160, maxWidth: 320)
                    TextField("title", text: eventBinding(index, \.title)).frame(minWidth: 100, maxWidth: 220)
                    DeveloperPanelIcon(symbol: "minus", title: "Remove event", size: 16) {
                        change { edited in
                            var all = edited.assertedEvents
                            guard all.indices.contains(index) else { return }
                            all.remove(at: index)
                            edited.assertedEvents = all
                        }
                    }
                }
            }
            DeveloperPanelIcon(symbol: "plus", title: "Wait for a navigation", size: 16) {
                change { $0.assertedEvents.append(DeveloperRecorderAssertedEvent(url: "", title: "")) }
            }
        }
    }

    private func eventBinding(_ index: Int, _ key: WritableKeyPath<DeveloperRecorderAssertedEvent, String?>) -> Binding<String> {
        Binding(
            get: { step.assertedEvents.indices.contains(index) ? step.assertedEvents[index][keyPath: key] ?? "" : "" },
            set: { value in
                change { edited in
                    var all = edited.assertedEvents
                    guard all.indices.contains(index) else { return }
                    all[index][keyPath: key] = value
                    edited.assertedEvents = all
                }
            }
        )
    }
}

/// A number field that keeps what's typed until Return or leaving it,
/// so "1." on the way to "1.5" isn't thrown away.
private struct DeveloperRecorderNumberField: View {
    let value: Double?
    let commit: (Double?) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    private func shown(_ value: Double?) -> String { value.map(DeveloperRecorderJSON.format) ?? "" }

    var body: some View {
        TextField("", text: $text)
            .focused($focused)
            .onAppear { text = shown(value) }
            .onChange(of: value) { _, new in if !focused { text = shown(new) } }
            .onChange(of: focused) { _, now in if !now { save() } }
            .onSubmit(save)
    }

    private func save() {
        let typed = text.trimmingCharacters(in: .whitespaces)
        if typed.isEmpty {
            commit(nil)
        } else if let number = Double(typed), number.isFinite {
            commit(number)
        } else {
            text = shown(value)
        }
    }
}
