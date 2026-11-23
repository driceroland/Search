import SwiftUI

/// ⌘F in the Network panel: Chrome's search pane, across every request's
/// URL, headers, payload and response.
struct DeveloperNetworkSearchView: View {
    @ObservedObject var session: DeveloperToolsSession
    @ObservedObject var tools: DeveloperNetworkTools
    let requests: [DeveloperToolsSession.Request]
    /// Bumped by ⌘F: the field takes the keyboard again, as Chrome's ⌘F
    /// focuses the open search pane rather than closing it.
    var focusRequest = 0
    let reveal: (String, DeveloperRequestTab) -> Void
    let close: () -> Void

    @State private var query = ""
    @State private var caseSensitive = false
    @State private var regex = false
    @State private var hits: [DeveloperNetworkTools.SearchHit] = []
    @State private var searching = false
    @State private var searched = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DeveloperToolsStyle.controlSpacing) {
                TextField("Search", text: $query)
                    .developerToolsField()
                    .focused($focused)
                    .onSubmit(run)
                    // Esc in the field closes the pane, as in Chrome.
                    .onExitCommand(perform: close)
                    .accessibilityIdentifier("developer-network-search")
                toggle("Aa", "Match Case", isOn: $caseSensitive)
                toggle(".*", "Use Regular Expression", isOn: $regex)
                button("arrow.clockwise", "Refresh", action: run)
                button("nosign", "Clear search") {
                    query = ""
                    hits = []
                    searched = false
                }
                button("xmark", "Close", action: close)
            }
            .padding(DeveloperToolsStyle.controlSpacing)
            .background(DeveloperToolsStyle.chrome)
            .overlay(alignment: .bottom) { Rectangle().fill(DeveloperToolsStyle.rule.opacity(0.55)).frame(height: 1) }
            results
            Text(summary)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, DeveloperToolsStyle.gutter)
                .frame(maxWidth: .infinity, minHeight: DeveloperToolsStyle.rowHeight, alignment: .leading)
                .background(DeveloperToolsStyle.chrome)
        }
        .background(DeveloperToolsStyle.surface)
        .onAppear { focused = true }
        .onChange(of: focusRequest) { _, _ in focused = true }
    }

    private var summary: String {
        if searching { return "Searching…" }
        guard searched else { return "" }
        let files = Set(hits.map(\.request)).count
        return hits.isEmpty ? "No matches found." : "Search finished. Found \(hits.count) matching line\(hits.count == 1 ? "" : "s") in \(files) file\(files == 1 ? "" : "s")."
    }

    private var results: some View {
        let groups = Dictionary(grouping: hits, by: \.request)
        let order = requests.map(\.id).filter { groups[$0] != nil }
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(order, id: \.self) { id in
                    let request = requests.first { $0.id == id }
                    Text(request?.name ?? id)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(request?.url ?? "")
                        .padding(.horizontal, DeveloperToolsStyle.gutter)
                        .padding(.top, DeveloperToolsStyle.controlSpacing)
                    ForEach(groups[id] ?? []) { hit in
                        Button {
                            reveal(hit.request, hit.place == "response" ? .response
                                   : hit.place == "payload" ? .payload : .headers)
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: DeveloperToolsStyle.controlSpacing) {
                                Text(hit.place == "response" || hit.place == "payload" ? "\(hit.line)" : hit.place)
                                    .foregroundStyle(.secondary)
                                    .frame(minWidth: 18, alignment: .trailing)
                                Text(hit.text).lineLimit(1).truncationMode(.tail)
                            }
                            .font(DeveloperToolsStyle.code)
                            .padding(.horizontal, DeveloperToolsStyle.gutter)
                            .frame(maxWidth: .infinity, minHeight: 18, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func run() {
        let text = query
        guard !text.isEmpty else { return }
        searching = true
        Task {
            hits = await tools.search(text, in: requests, caseSensitive: caseSensitive, regex: regex)
            searching = false
            searched = true
        }
    }

    private func toggle(_ title: String, _ help: String, isOn: Binding<Bool>) -> some View {
        Button { isOn.wrappedValue.toggle() } label: {
            Text(title).font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(isOn.wrappedValue ? DeveloperToolsStyle.tint : .secondary)
                .frame(width: 20, height: DeveloperToolsStyle.controlHeight)
                .background(isOn.wrappedValue ? DeveloperToolsStyle.selected : .clear,
                            in: RoundedRectangle(cornerRadius: DeveloperToolsStyle.controlRadius))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(isOn.wrappedValue ? .isSelected : [])
    }

    private func button(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
                .frame(width: 18, height: DeveloperToolsStyle.controlHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// The Request conditions drawer (Network request blocking before Chrome renamed it):
/// patterns, each switchable, that block matching requests or delay them
/// with a throttling profile.
struct DeveloperNetworkBlockingView: View {
    @ObservedObject var tools: DeveloperNetworkTools
    let requests: [DeveloperToolsSession.Request]
    let close: () -> Void
    @State private var draft = ""
    @State private var adding = false
    @State private var problem: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DeveloperToolsStyle.gutter) {
                Text("Request conditions").font(.system(size: 11, weight: .semibold))
                Toggle("Enable blocking and throttling", isOn: $tools.blockingEnabled)
                    .toggleStyle(.developerCheckbox)
                    .controlSize(.small)
                    .foregroundStyle(.secondary)
                Button {
                    adding = true
                    focused = true
                } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .help("Add pattern")
                    .accessibilityLabel("Add pattern")
                Button { tools.blockPatterns.removeAll() } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help("Remove all patterns")
                    .disabled(tools.blockPatterns.isEmpty)
                Spacer(minLength: 0)
                Button(action: close) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Close")
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, DeveloperToolsStyle.gutter)
            .frame(height: DeveloperToolsStyle.toolbarHeight)
            .background(DeveloperToolsStyle.chrome)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if tools.blockPatterns.isEmpty && !adding {
                        VStack(spacing: 6) {
                            Text("No request blocking patterns").font(.system(size: 11, weight: .semibold))
                            Text("To block or throttle a network request, add a pattern here manually or via the Network panel’s context menu. Choose Block or a throttling profile for each pattern.")
                                .multilineTextAlignment(.center)
                            Button("Add pattern") {
                                adding = true
                                focused = true
                            }
                        }
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(DeveloperToolsStyle.gutter * 2)
                    }
                    ForEach($tools.blockPatterns) { $item in
                        HStack(spacing: DeveloperToolsStyle.gutter) {
                            Toggle("", isOn: $item.enabled).toggleStyle(.developerCheckbox).labelsHidden()
                                .help(item.throttling == nil ? "Block " + item.pattern : "Throttle " + item.pattern)
                            Text(item.pattern).font(DeveloperToolsStyle.code).lineLimit(1).truncationMode(.middle)
                                .opacity(item.enabled && tools.blockingEnabled ? 1 : 0.55)
                            Spacer(minLength: 0)
                            conditionMenu($item.throttling)
                            Text(count(item)).foregroundStyle(.secondary)
                            Button {
                                tools.blockPatterns.removeAll { $0.id == item.id }
                            } label: { Image(systemName: "xmark.circle") }
                                .buttonStyle(.borderless)
                                .help("Remove")
                        }
                        .font(.system(size: 10.5))
                        .padding(.horizontal, DeveloperToolsStyle.gutter)
                        .frame(height: DeveloperToolsStyle.rowHeight)
                    }
                    if adding {
                        HStack(spacing: DeveloperToolsStyle.gutter) {
                            TextField("Text pattern to block or throttle matching requests; use * for wildcard", text: $draft)
                                .developerToolsField()
                                .focused($focused)
                                .onSubmit(add)
                            Button("Add", action: add)
                            Button("Cancel") {
                                adding = false
                                draft = ""
                                problem = nil
                            }
                        }
                        .padding(DeveloperToolsStyle.controlSpacing)
                        if let problem {
                            Text(problem).foregroundStyle(.red).font(.system(size: 10.5))
                                .padding(.horizontal, DeveloperToolsStyle.gutter)
                        }
                    }
                }
            }
            .background(DeveloperToolsStyle.surface)
        }
        .accessibilityIdentifier("developer-network-blocking")
    }

    private func affected(_ pattern: String) -> Int {
        requests.filter { tools.extras[$0.id]?.blocked == true && Self.matches(pattern, $0.url) }.count
    }

    private func throttled(_ pattern: String) -> Int {
        requests.filter { tools.extras[$0.id]?.throttled != nil && Self.matches(pattern, $0.url) }.count
    }

    private func count(_ item: DeveloperNetworkTools.BlockPattern) -> String {
        DeveloperNetworkTools.condition(of: item, profiles: tools.profiles) == .block
            ? "\(affected(item.pattern)) blocked" : "\(throttled(item.pattern)) throttled"
    }

    /// Block, a preset or a custom profile, as Chrome's per-row menu offers.
    private func conditionMenu(_ throttling: Binding<String?>) -> some View {
        let item = DeveloperNetworkTools.BlockPattern(pattern: "", throttling: throttling.wrappedValue)
        return Menu(DeveloperNetworkTools.conditionName(of: item, profiles: tools.profiles)) {
            Button("Block") { throttling.wrappedValue = nil }
            Section("Throttling") {
                ForEach(DeveloperNetworkTools.conditionPresets) { preset in
                    Button(preset.rawValue) { throttling.wrappedValue = preset.rawValue }
                        .help(preset.detail)
                }
                ForEach(tools.profiles) { profile in
                    Button(profile.name) { throttling.wrappedValue = profile.id.uuidString }
                }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Only latency applies per request; bandwidth limits apply to the whole page.")
    }

    /// Close enough to the frontend's matcher to count the blocked rows.
    static func matches(_ pattern: String, _ url: String) -> Bool {
        var text = pattern
        if text.hasPrefix("*://") { text = String(text.dropFirst(4)) }
        let parts = text.replacingOccurrences(of: "\\", with: "").components(separatedBy: "*")
        let expression = parts.map(NSRegularExpression.escapedPattern).joined(separator: ".*")
        return url.range(of: expression, options: .regularExpression) != nil
    }

    private func add() {
        if let error = tools.addPattern(draft) {
            problem = error
            return
        }
        draft = ""
        problem = nil
        adding = false
    }
}

/// Custom… in the throttling menu: Chrome's "Add profile" fields.
struct DeveloperThrottlingProfileForm: View {
    let bandwidth: Bool
    let save: (DeveloperNetworkTools.ThrottlingProfile) -> Void
    @Environment(\.developerDismiss) private var dismiss
    @State private var name = ""
    @State private var download = ""
    @State private var upload = ""
    @State private var latency = "0"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add custom profile").font(.headline)
            Form {
                TextField("Profile Name", text: $name)
                TextField("Download (kbit/s)", text: $download)
                TextField("Upload (kbit/s)", text: $upload)
                TextField("Latency (ms)", text: $latency)
            }
            Text(bandwidth ? "Download is applied with WebKit’s network emulation; WebKit has one limit for both directions."
                 : "This version of WebKit can’t limit bandwidth, so only the latency applies.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") {
                    save(.init(name: name.trimmingCharacters(in: .whitespaces), download: Double(download) ?? 0,
                               upload: Double(upload) ?? 0, latency: min(5_000, max(0, Double(latency) ?? 0))))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || Double(latency) == nil)
            }
        }
        .padding(20)
        .frame(width: 340)
    }
}

/// A WebSocket's Messages tab: frames sent and received, with a filter.
struct DeveloperNetworkMessagesView: View {
    @ObservedObject var tools: DeveloperNetworkTools
    let request: DeveloperToolsSession.Request

    enum Kind: String, CaseIterable, Identifiable {
        case all = "All", sent = "Send", received = "Receive"
        var id: Self { self }
    }

    @State private var frames: [DeveloperNetworkTools.Frame] = []
    @State private var count = 0
    @State private var cleared = 0
    @State private var filter = ""
    @State private var kind = Kind.all
    @State private var selection: Int?
    @State private var dropped = 0

    var body: some View {
        let shown = visible
        VStack(spacing: 0) {
            HStack(spacing: DeveloperToolsStyle.gutter) {
                Button {
                    cleared = frames.count
                    selection = nil
                } label: { Image(systemName: "nosign") }
                    .buttonStyle(.borderless)
                    .help("Clear All")
                if !request.isEventSource {
                    Picker("", selection: $kind) {
                        ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .controlSize(.small)
                }
                TextField(request.isEventSource ? "Filter events" : "Filter using regex (example: (web)?socket)", text: $filter)
                    .developerToolsField()
                    .accessibilityIdentifier("developer-network-messages-filter")
            }
            .padding(.horizontal, DeveloperToolsStyle.gutter)
            .frame(height: DeveloperToolsStyle.toolbarHeight)
            .background(DeveloperToolsStyle.chrome)
            HStack(spacing: DeveloperToolsStyle.controlSpacing) {
                if request.isEventSource {
                    Text("Event type").frame(width: 76, alignment: .leading)
                    Text("Event ID").frame(width: 60, alignment: .leading)
                }
                Text("Data").frame(maxWidth: .infinity, alignment: .leading)
                if !request.isEventSource {
                    Text("Length").frame(width: 60, alignment: .trailing)
                }
                Text("Time").frame(width: 90, alignment: .trailing)
            }
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, DeveloperToolsStyle.gutter)
            .frame(height: DeveloperToolsStyle.rowHeight)
            .background(DeveloperToolsStyle.chrome)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(shown) { frame in row(frame) }
                    if dropped > 0 {
                        Text(dropped == 1 ? "1 message not shown" : "\(dropped) messages not shown")
                            .font(DeveloperToolsStyle.code)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, DeveloperToolsStyle.gutter)
                            .frame(height: DeveloperToolsStyle.rowHeight)
                            .help("The page received these too quickly to record")
                            .accessibilityIdentifier("developer-network-messages-dropped")
                    }
                }
            }
            .overlay {
                if shown.isEmpty && dropped == 0 {
                    Text(frames.isEmpty ? "No messages" : "No matching messages").foregroundStyle(.secondary)
                }
            }
            if let selection, let frame = frames.first(where: { $0.id == selection }) {
                Rectangle().fill(DeveloperToolsStyle.rule.opacity(0.55)).frame(height: 1)
                ScrollView {
                    Text(Self.preview(frame))
                        .font(DeveloperToolsStyle.code)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(DeveloperToolsStyle.gutter)
                }
                .frame(height: 120)
            }
        }
        .accessibilityIdentifier("developer-network-messages")
        .task(id: request.id) {
            while !Task.isCancelled {
                let next = await tools.frames(for: request.id, after: count)
                if request.isEventSource { dropped = tools.droppedMessages(for: request.id) }
                if !next.frames.isEmpty {
                    frames += next.frames
                    count = next.count
                    if request.isEventSource, frames.count > 512 {
                        let removed = frames.count - 512
                        frames.removeFirst(removed)
                        cleared = max(0, cleared - removed)
                    }
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    var visible: [DeveloperNetworkTools.Frame] {
        let expression = filter.isEmpty ? nil : try? NSRegularExpression(pattern: filter, options: .caseInsensitive)
        return frames.dropFirst(cleared).filter { frame in
            switch kind {
            case .all: break
            case .sent: if frame.kind != .sent { return false }
            case .received: if frame.kind != .received { return false }
            }
            let text = request.isEventSource
                ? [frame.eventType, frame.eventID, frame.data].compactMap { $0 }.joined(separator: " ") : frame.data
            guard let expression else { return filter.isEmpty || text.localizedCaseInsensitiveContains(filter) }
            return expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }
    }

    private func row(_ frame: DeveloperNetworkTools.Frame) -> some View {
        let selected = selection == frame.id
        let tint: Color = frame.kind == .sent ? .green : frame.kind == .error ? .red : .clear
        return Button { selection = frame.id } label: {
            HStack(spacing: DeveloperToolsStyle.controlSpacing) {
                if request.isEventSource {
                    Text(frame.eventType ?? "").lineLimit(1).frame(width: 76, alignment: .leading)
                    Text(frame.eventID ?? "").lineLimit(1).frame(width: 60, alignment: .leading)
                } else {
                    Image(systemName: frame.kind == .sent ? "arrow.up" : frame.kind == .error ? "exclamationmark.circle" : "arrow.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(frame.kind == .sent ? Color.green : frame.kind == .error ? .red : .red.opacity(0.8))
                }
                Text(Self.summary(frame)).lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !request.isEventSource {
                    Text(String(frame.length)).frame(width: 60, alignment: .trailing)
                }
                Text(frame.time.map(Self.clock) ?? "").frame(width: 90, alignment: .trailing)
            }
            .font(DeveloperToolsStyle.code)
            .padding(.horizontal, DeveloperToolsStyle.gutter)
            .frame(height: DeveloperToolsStyle.rowHeight)
            .background(selected ? DeveloperToolsStyle.selected : tint.opacity(0.08))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Chrome's wording for frames without readable text.
    static func summary(_ frame: DeveloperNetworkTools.Frame) -> String {
        switch frame.opcode {
        case 2: return "Binary Message"
        case 8: return "Connection Close Message"
        case 9: return "Ping Message"
        case 10: return "Pong Message"
        default: return frame.data
        }
    }

    static func preview(_ frame: DeveloperNetworkTools.Frame) -> String {
        if frame.binary {
            guard let data = Data(base64Encoded: frame.data) else { return frame.data }
            return data.prefix(4_096).enumerated().reduce(into: "") { text, item in
                if item.offset % 16 == 0 { text += (item.offset == 0 ? "" : "\n") + String(format: "%08x ", item.offset) }
                text += String(format: " %02x", item.element)
            }
        }
        return DeveloperRequestDetails.prettyJSON(frame.data) ?? frame.data
    }

    /// The frame's wall-clock time, as Chrome's Time column shows it.
    static func clock(_ time: Double) -> String {
        DeveloperMeasure.clock.string(from: Date(timeIntervalSince1970: time))
    }
}

/// The Network filter box, with Chrome's suggestions under it: filter keys
/// while a word is typed, then the values the log has for that key. Down
/// and Up choose one; Tab, Return or Right at the end takes it in place of
/// the word; Esc puts the list away until the next keystroke.
struct DeveloperNetworkFilterField: View {
    @Binding var query: String
    let requests: [DeveloperToolsSession.Request]
    let extras: [String: DeveloperNetworkTools.Extra]

    @FocusState private var focused: Bool
    @State private var chosen = 0
    @State private var dismissed = false

    var body: some View {
        let suggestions = focused && !dismissed
            ? DeveloperNetworkFilter.suggestions(for: query, requests: requests, extras: extras, limit: 12) : []
        TextField("Filter", text: $query)
            .textFieldStyle(.plain)
            .focused($focused)
            .onKeyPress(keys: [.upArrow, .downArrow, .tab, .return, .rightArrow], phases: [.down, .repeat]) { press in
                guard !suggestions.isEmpty else { return .ignored }
                let count = suggestions.count
                let current = min(chosen, count - 1)
                switch press.key {
                case .downArrow: chosen = (current + 1) % count
                case .upArrow: chosen = (current - 1 + count) % count
                case .rightArrow:
                    guard Self.caretAtEnd else { return .ignored }
                    accept(suggestions[current])
                default: accept(suggestions[current])
                }
                return .handled
            }
            .onExitCommand { dismissed = true }
            .onChange(of: query) { _, _ in
                chosen = 0
                dismissed = false
            }
            .overlay(alignment: .topLeading) {
                if !suggestions.isEmpty { list(suggestions) }
            }
            .help("e.g. /small[\\d]+/ url:a.com/b domain:*.example.com -method:GET status-code:404 larger-than:1k mime-type:text/html is:from-cache")
            .accessibilityIdentifier("developer-network-filter")
    }

    private func list(_ suggestions: [String]) -> some View {
        let current = min(chosen, suggestions.count - 1)
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.element) { index, item in
                Text(item)
                    .font(DeveloperToolsStyle.code)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, DeveloperToolsStyle.controlSpacing + 2)
                    .frame(maxWidth: .infinity, minHeight: 18, alignment: .leading)
                    .background(index == current ? DeveloperToolsStyle.selected : .clear)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        accept(item)
                        focused = true
                    }
            }
        }
        .padding(.vertical, 2)
        .frame(minWidth: 180, maxWidth: 320, alignment: .leading)
        .fixedSize(horizontal: true, vertical: true)
        .background(DeveloperToolsStyle.surface, in: RoundedRectangle(cornerRadius: DeveloperToolsStyle.controlRadius))
        .overlay { RoundedRectangle(cornerRadius: DeveloperToolsStyle.controlRadius).strokeBorder(DeveloperToolsStyle.rule) }
        .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
        .offset(y: DeveloperToolsStyle.controlHeight)
        .accessibilityIdentifier("developer-network-filter-suggestions")
    }

    private func accept(_ suggestion: String) {
        query = DeveloperNetworkFilter.complete(query, with: suggestion)
        chosen = 0
    }

    /// Whether the caret is at the end of the text being edited, so Right
    /// takes a suggestion only where Chrome's does.
    private static var caretAtEnd: Bool {
        guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return true }
        let range = editor.selectedRange()
        return range.length == 0 && range.location == (editor.string as NSString).length
    }
}

/// The waterfall bar's hover card: Chrome's timing breakdown, from when
/// the request was queued to its last byte.
struct DeveloperNetworkTimingPopover: View {
    let request: DeveloperToolsSession.Request
    let timing: [String: Double]
    /// The recording's start, which "Queued at" counts from.
    let origin: Double

    var body: some View {
        let phases = DeveloperNetworkTiming.phases(for: request, timing: timing)
        let total = max(request.time ?? 0, phases.map(\.end).max() ?? 0)
        VStack(alignment: .leading, spacing: 3) {
            if let started = request.started {
                let queued = (started - origin) * 1_000
                let start = phases.first { $0.label != "Queueing" }?.start ?? 0
                Text("Queued at \(Self.seconds(queued))").foregroundStyle(.secondary)
                Text("Started at \(Self.seconds(queued + start))").foregroundStyle(.secondary)
            }
            ForEach(DeveloperNetworkTiming.TimingSection.allCases, id: \.self) { section in
                let rows = phases.filter { $0.section == section }
                if !rows.isEmpty {
                    HStack {
                        Text(section.rawValue).fontWeight(.semibold)
                        Spacer()
                        Text("DURATION").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)
                    ForEach(rows, id: \.label) { phase in
                        HStack(spacing: DeveloperToolsStyle.gutter) {
                            Text(phase.label).frame(width: 150, alignment: .leading)
                            GeometryReader { space in
                                let start = total > 0 ? phase.start / total : 0
                                let width = total > 0 ? (phase.end - phase.start) / total : 0
                                Rectangle().fill(phase.color.opacity(0.85))
                                    .frame(width: max(2, space.size.width * width), height: 8)
                                    .offset(x: space.size.width * max(0, min(1, start)), y: (space.size.height - 8) / 2)
                            }
                            .frame(width: 100, height: 14)
                            Text(Self.duration(phase.end - phase.start)).monospacedDigit()
                                .frame(width: 70, alignment: .trailing)
                        }
                    }
                }
            }
            if phases.isEmpty {
                Text("Timing is not available for this request yet.").foregroundStyle(.secondary)
            }
            Divider().padding(.vertical, 2)
            HStack {
                Text(request.ended == nil ? "CAUTION: request is not finished yet!" : "Total").fontWeight(.semibold)
                Spacer()
                Text(request.time.map(Self.duration) ?? "Pending").monospacedDigit().fontWeight(.semibold)
            }
        }
        .font(.system(size: 11))
        .padding(10)
        .frame(width: 360)
        .accessibilityIdentifier("developer-network-timing-popover")
    }

    static func duration(_ milliseconds: Double) -> String {
        milliseconds < 1_000
            ? milliseconds.formatted(.number.precision(.fractionLength(2))) + " ms"
            : (milliseconds / 1_000).formatted(.number.precision(.fractionLength(2))) + " s"
    }

    static func seconds(_ milliseconds: Double) -> String {
        milliseconds < 1_000 ? "\(Int(milliseconds.rounded())) ms"
            : (milliseconds / 1_000).formatted(.number.precision(.fractionLength(2))) + " s"
    }
}

/// The Initiator column's hover card: the call stack that made the
/// request, each frame a link into Sources, as Chrome shows it.
struct DeveloperNetworkInitiatorPopover: View {
    let frames: [DeveloperRequestDetails.StackFrame]
    let reveal: (DeveloperRequestDetails.StackFrame) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(frames.enumerated()), id: \.offset) { _, frame in
                HStack(spacing: DeveloperToolsStyle.gutter) {
                    Text(frame.function).lineLimit(1)
                    Spacer(minLength: DeveloperToolsStyle.gutter)
                    if frame.url.isEmpty {
                        Text("(unknown)").foregroundStyle(.secondary)
                    } else {
                        Button { reveal(frame) } label: {
                            Text(frame.location).underline().foregroundStyle(DeveloperToolsStyle.tint).lineLimit(1)
                        }
                        .buttonStyle(.plain)
                        .help("Open \(frame.url)" + (frame.line.map { ":\($0)" } ?? "") + " in Sources")
                    }
                }
            }
        }
        .font(DeveloperToolsStyle.code)
        .padding(10)
        .frame(minWidth: 240, maxWidth: 420)
        .accessibilityIdentifier("developer-network-initiator-popover")
    }
}
