import AppKit
import SwiftUI

// Chrome DevTools' Protocol monitor (More tools › Protocol monitor): every
// command Search sends to WebKit's inspector and every event it drains,
// with the method, direction, target, parameters, response and how long
// the response took; a filter, Clear, a record toggle, and a box to send
// a raw command. While no monitor is shown the hooks in
// DeveloperToolsSession read one stored flag and do nothing else.

@MainActor
final class DeveloperProtocolMonitor: ObservableObject {
    enum Direction: String {
        case sent
        case received
    }

    struct Entry: Identifiable, Equatable {
        let id: Int
        let method: String
        let direction: Direction
        /// The target's identifier; nil is the main target.
        let target: String?
        /// Parameters as JSON.
        let params: String
        /// The response as JSON, once it came.
        var response: String?
        var error: String?
        let time: Date
        /// Milliseconds from sending a command to its response.
        var elapsed: Double?
    }

    /// Rows kept; older ones go first, as Chrome's monitor drops them.
    nonisolated static let defaultLimit = 10_000
    /// Longest parameter or response text kept for a row.
    static let longestText = 20_000

    let limit: Int
    @Published private(set) var entries: [Entry] = []
    /// The toolbar's record toggle.
    @Published var recording = true { didSet { updateActive() } }
    /// Read on every command and drain: one stored flag, so a closed
    /// monitor costs nothing more.
    private(set) var isActive = false
    private var viewers = 0
    private var nextID = 0
    private var startTimes: [Int: CFAbsoluteTime] = [:]

    init(limit: Int = DeveloperProtocolMonitor.defaultLimit) {
        self.limit = max(1, limit)
    }

    /// A monitor view appeared or went away.
    func viewerOpened() { viewers += 1; updateActive() }
    func viewerClosed() { viewers = max(0, viewers - 1); updateActive() }

    private func updateActive() {
        let active = recording && viewers > 0
        if isActive != active { isActive = active }
    }

    func clear() {
        entries = []
        startTimes = [:]
    }

    // MARK: Recording

    /// A command going out; the id to answer it with.
    func sent(_ method: String, params: [String: Any], target: String?) -> Int {
        let id = nextID
        nextID += 1
        startTimes[id] = CFAbsoluteTimeGetCurrent()
        append(contentsOf: [Entry(id: id, method: method, direction: .sent, target: target, params: Self.json(params),
                                  time: Date())])
        return id
    }

    func answered(_ id: Int, response: [String: Any]) {
        finish(id) { $0.response = Self.json(response) }
    }

    func failed(_ id: Int, error: String) {
        finish(id) { $0.error = error }
    }

    /// Events as the bridge drains them: method, params and targetId.
    func received(_ events: [[String: Any]]) {
        guard !events.isEmpty else { return }
        var batch: [Entry] = []
        batch.reserveCapacity(min(events.count, limit))
        let now = Date()
        for event in events.suffix(limit) {
            guard let method = event["method"] as? String else { continue }
            batch.append(Entry(id: nextID, method: method, direction: .received, target: event["targetId"] as? String,
                               params: Self.json(event["params"] as? [String: Any] ?? [:]), time: now))
            nextID += 1
        }
        append(contentsOf: batch)
    }

    private func append(contentsOf batch: [Entry]) {
        guard !batch.isEmpty else { return }
        var list = entries
        list.append(contentsOf: batch)
        if list.count > limit {
            let dropped = list.prefix(list.count - limit)
            for entry in dropped where entry.direction == .sent { startTimes[entry.id] = nil }
            list.removeFirst(list.count - limit)
        }
        entries = list
    }

    private func finish(_ id: Int, _ change: (inout Entry) -> Void) {
        let start = startTimes.removeValue(forKey: id)
        // Ids rise one by one and rows only go from the front, so a row's
        // place follows from the first row's id.
        guard let first = entries.first?.id else { return }
        var index = id - first
        if !entries.indices.contains(index) || entries[index].id != id {
            guard let found = entries.firstIndex(where: { $0.id == id }) else { return }
            index = found
        }
        change(&entries[index])
        if let start { entries[index].elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000 }
    }

    // MARK: Text

    static func json(_ value: Any) -> String {
        let data = JSONSerialization.isValidJSONObject(value)
            ? try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]) : nil
        let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? String(describing: value)
        guard text.utf16.count > longestText else { return text }
        return String(text.prefix(longestText)) + "\u{2026}"
    }

    // MARK: Filter

    /// Chrome's filter: words that must all appear in the method (or the
    /// parameters and response), `-word` to leave rows out, and `type:sent`,
    /// `type:received`, `method:` and `target:` for one column.
    static func filter(_ entries: [Entry], _ query: String) -> [Entry] {
        let terms = query.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard !terms.isEmpty else { return entries }
        return entries.filter { entry in
            terms.allSatisfy { raw in
                let negated = raw.hasPrefix("-") && raw.count > 1
                let term = negated ? String(raw.dropFirst()) : raw
                return matches(entry, term) != negated
            }
        }
    }

    private static func matches(_ entry: Entry, _ term: String) -> Bool {
        let lower = term.lowercased()
        if lower.hasPrefix("type:") {
            let value = lower.dropFirst(5)
            return value.isEmpty || entry.direction.rawValue.hasPrefix(value)
        }
        if lower.hasPrefix("method:") {
            return entry.method.localizedCaseInsensitiveContains(String(term.dropFirst(7)))
        }
        if lower.hasPrefix("target:") {
            let value = String(term.dropFirst(7))
            return (entry.target ?? "main").localizedCaseInsensitiveContains(value)
        }
        return entry.method.localizedCaseInsensitiveContains(term)
            || entry.params.localizedCaseInsensitiveContains(term)
            || (entry.response?.localizedCaseInsensitiveContains(term) ?? false)
    }

    /// The raw command box's parameters: empty means `{}`; anything else
    /// must be a JSON object.
    static func parameters(_ text: String) -> [String: Any]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [:] }
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object
    }
}

extension DeveloperToolsSession {
    /// The Protocol monitor's "Send a raw command": what it sends and its
    /// answer show in the monitor like any other command.
    func sendRawProtocolCommand(method: String, parameters text: String, target: String) {
        let method = method.trimmingCharacters(in: .whitespaces)
        guard !method.isEmpty else { return }
        guard let params = DeveloperProtocolMonitor.parameters(text) else {
            message = "The parameters aren’t a JSON object."
            return
        }
        let trimmedTarget = target.trimmingCharacters(in: .whitespaces)
        let targetID = trimmedTarget.isEmpty || trimmedTarget == "main" ? nil : trimmedTarget
        Task { [weak self] in
            guard let self else { return }
            do { _ = try await self.command(method, params, targetID: targetID) }
            catch { self.message = error.localizedDescription }
        }
    }
}

// MARK: - View

struct DeveloperProtocolMonitorView: View {
    @ObservedObject var session: DeveloperToolsSession
    @ObservedObject var monitor: DeveloperProtocolMonitor
    @State private var filter = ""
    @State private var selection: Int?
    @State private var method = ""
    @State private var parameters = ""
    @State private var target = ""
    /// The table's width: Timestamp, then Elapsed time, give way in a
    /// narrow one so Method keeps its room.
    @State private var tableWidth: CGFloat = 900

    init(session: DeveloperToolsSession) {
        self.session = session
        monitor = session.protocolMonitor
    }

    private var shown: [DeveloperProtocolMonitor.Entry] {
        DeveloperProtocolMonitor.filter(monitor.entries, filter)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HSplitView {
                table.frame(minWidth: 260, maxWidth: .infinity, maxHeight: .infinity)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { tableWidth = $0 }
                if let selection, let entry = monitor.entries.first(where: { $0.id == selection }) {
                    details(entry).frame(minWidth: 220, idealWidth: 320, maxHeight: .infinity)
                }
            }
            Divider()
            sendBox
        }
        .background(DeveloperToolsStyle.surface)
        .onAppear { monitor.viewerOpened() }
        .onDisappear { monitor.viewerClosed() }
        .accessibilityIdentifier("developer-protocol-monitor")
    }

    private var toolbar: some View {
        HStack(spacing: DeveloperToolsStyle.controlSpacing) {
            Button { monitor.recording.toggle() } label: {
                Image(systemName: monitor.recording ? "stop.circle.fill" : "record.circle")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(monitor.recording ? Color.red : Color.secondary)
                    .frame(width: DeveloperToolsStyle.controlHeight, height: DeveloperToolsStyle.controlHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(monitor.recording ? "Stop recording protocol messages" : "Record protocol messages")
            .accessibilityLabel(monitor.recording ? "Stop recording protocol messages" : "Record protocol messages")
            DeveloperPanelIcon(symbol: "nosign", title: "Clear log") {
                monitor.clear()
                selection = nil
            }
            .disabled(monitor.entries.isEmpty)
            Divider().frame(height: 14)
            TextField("Filter", text: $filter)
                .developerToolsField()
                .frame(maxWidth: 260)
                .help("Filter by method; type:sent, type:received, target: and -word narrow it further")
            Spacer(minLength: 0)
            Text(countText).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.horizontal, DeveloperToolsStyle.gutter)
        .frame(height: DeveloperToolsStyle.toolbarHeight)
        .background(DeveloperToolsStyle.chrome)
    }

    private var countText: String {
        let total = monitor.entries.count
        let visible = filter.isEmpty ? total : shown.count
        return visible == total ? "\(total) messages" : "\(visible) of \(total) messages"
    }

    enum Column {
        static let direction: CGFloat = 18
        static let target: CGFloat = 90
        static let elapsed: CGFloat = 80
        static let time: CGFloat = 90
        /// Room Method keeps before a column drops out.
        static let method: CGFloat = 120

        /// Which of Elapsed time and Timestamp fit a table `width` wide.
        static func shown(_ width: CGFloat) -> (elapsed: Bool, time: Bool) {
            let gap = DeveloperToolsStyle.gutter
            let base = 2 * gap + direction + gap + method + gap + target
            let elapsedFits = width >= base + gap + elapsed
            return (elapsedFits, elapsedFits && width >= base + 2 * gap + elapsed + time)
        }
    }

    private var table: some View {
        VStack(spacing: 0) {
            HStack(spacing: DeveloperToolsStyle.gutter) {
                Color.clear.frame(width: Column.direction, height: 1)
                Text("Method").frame(maxWidth: .infinity, alignment: .leading)
                Text("Target").frame(width: Column.target, alignment: .leading)
                if Column.shown(tableWidth).elapsed {
                    Text("Elapsed time").frame(width: Column.elapsed, alignment: .trailing)
                }
                if Column.shown(tableWidth).time {
                    Text("Timestamp").frame(width: Column.time, alignment: .trailing)
                }
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, DeveloperToolsStyle.gutter)
            .frame(height: DeveloperToolsStyle.rowHeight)
            .background(DeveloperToolsStyle.chrome)
            Divider()
            let rows = shown
            if rows.isEmpty {
                Text(monitor.recording ? "Protocol messages Search sends and receives show here." : "Recording is off.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(rows) { entry in row(entry).id(entry.id) }
                        }
                    }
                    .onChange(of: monitor.entries.last?.id) { _, last in
                        if selection == nil, let last { proxy.scrollTo(last, anchor: .bottom) }
                    }
                }
            }
        }
    }

    private func row(_ entry: DeveloperProtocolMonitor.Entry) -> some View {
        HStack(spacing: DeveloperToolsStyle.gutter) {
            Image(systemName: entry.direction == .sent ? "arrow.up" : "arrow.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(entry.direction == .sent ? DeveloperToolsStyle.tint : Color.green)
                .frame(width: Column.direction)
                .accessibilityLabel(entry.direction == .sent ? "Sent" : "Received")
            Text(entry.method)
                .foregroundStyle(entry.error == nil ? Palette.ink : ConsoleTheme.errorText)
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(entry.target ?? "main").foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                .frame(width: Column.target, alignment: .leading)
            if Column.shown(tableWidth).elapsed {
                Text(elapsedText(entry)).foregroundStyle(.secondary).monospacedDigit()
                    .frame(width: Column.elapsed, alignment: .trailing)
            }
            if Column.shown(tableWidth).time {
                Text(DeveloperMeasure.clock.string(from: entry.time)).foregroundStyle(.secondary).monospacedDigit()
                    .frame(width: Column.time, alignment: .trailing)
            }
        }
        .font(DeveloperToolsStyle.code)
        .padding(.horizontal, DeveloperToolsStyle.gutter)
        .frame(height: DeveloperToolsStyle.rowHeight)
        .background(selection == entry.id ? DeveloperToolsStyle.selected : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { selection = selection == entry.id ? nil : entry.id }
        .contextMenu {
            Button("Copy method") { DeveloperToolsSession.copyToPasteboard(entry.method) }
            Button("Copy parameters") { DeveloperToolsSession.copyToPasteboard(entry.params) }
            if let response = entry.response { Button("Copy response") { DeveloperToolsSession.copyToPasteboard(response) } }
            if entry.direction == .sent {
                Divider()
                Button("Edit and resend") {
                    method = entry.method
                    parameters = entry.params == "{}" ? "" : entry.params
                    target = entry.target ?? ""
                }
            }
        }
    }

    private func elapsedText(_ entry: DeveloperProtocolMonitor.Entry) -> String {
        guard entry.direction == .sent else { return "" }
        guard let elapsed = entry.elapsed else { return "(pending)" }
        return elapsed < 10 ? String(format: "%.1f ms", elapsed) : "\(Int(elapsed.rounded())) ms"
    }

    private func details(_ entry: DeveloperProtocolMonitor.Entry) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                section(entry.direction == .sent ? "Request" : "Event", entry.params)
                if let error = entry.error {
                    Text("Error").font(.headline)
                    Text(error).font(DeveloperToolsStyle.code).foregroundStyle(ConsoleTheme.errorText).textSelection(.enabled)
                } else if let response = entry.response {
                    section("Response", response)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DeveloperToolsStyle.gutter)
        }
        .background(DeveloperToolsStyle.surface)
    }

    private func section(_ title: String, _ json: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline)
            DeveloperJSONPreview(text: json, scrolls: false) {
                Text(json).font(DeveloperToolsStyle.code).textSelection(.enabled)
            }
            .id(json)
        }
    }

    private var sendBox: some View {
        HStack(spacing: DeveloperToolsStyle.controlSpacing) {
            TextField("Send a raw command", text: $method)
                .developerToolsField()
                .frame(minWidth: 140, maxWidth: 240)
                .onSubmit(send)
            TextField("Parameters (JSON)", text: $parameters)
                .developerToolsField()
                .frame(maxWidth: .infinity)
                .onSubmit(send)
            TextField("Target", text: $target)
                .developerToolsField()
                .frame(width: 110)
                .help("A target identifier; empty for the main target")
                .onSubmit(send)
            Button("Send", action: send)
                .controlSize(.small)
                .disabled(method.trimmingCharacters(in: .whitespaces).isEmpty || !session.ready)
        }
        .padding(.horizontal, DeveloperToolsStyle.gutter)
        .frame(height: DeveloperToolsStyle.toolbarHeight + 4)
        .background(DeveloperToolsStyle.chrome)
    }

    private func send() {
        session.sendRawProtocolCommand(method: method, parameters: parameters, target: target)
    }
}
