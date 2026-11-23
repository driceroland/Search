import AppKit
import SwiftUI

/// Performance › Find (⌘F), as in Chrome DevTools: the Main track's entries
/// whose name, details or URL hold the text, stepped through with Return and
/// ⇧Return, each selected and brought into view, all of them outlined.
/// Pure, so the tests can read it without the panel.
enum DeveloperPerformanceFind {
    /// The most matches kept, so a short query over a huge recording stays quick.
    static let limit = 10_000

    /// What an entry is found by: its name, its details (a script and
    /// line, an event's target), its record type, and the URLs and names
    /// its data carries.
    static func haystack(_ event: DeveloperPerformanceEvent) -> [String] {
        var fields = [event.title, event.type]
        if let detail = event.detail { fields.append(detail) }
        for key in ["url", "scriptName", "name", "functionName", "type", "message"] {
            if let value = event.data[key], !value.isEmpty { fields.append(value) }
        }
        return fields
    }

    /// Whether `event` matches `query`, ignoring case.
    static func matches(_ event: DeveloperPerformanceEvent, _ query: String) -> Bool {
        haystack(event).contains { $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    /// The ids of the shown entries that match, in time order (as `events`
    /// is laid out); hidden ones left out, as the flame chart doesn't draw them.
    static func matches(_ query: String, in events: [DeveloperPerformanceEvent]) -> [Int] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        var found: [Int] = []
        for event in events where !event.isHidden && matches(event, query) {
            found.append(event.id)
            if found.count >= limit { break }
        }
        return found
    }

    /// The match after (or, `backwards`, before) `current`, round the ends;
    /// the first (or last) when none is current yet.
    static func step(_ current: Int?, count: Int, backwards: Bool) -> Int? {
        guard count > 0 else { return nil }
        guard let current, current >= 0, current < count else { return backwards ? count - 1 : 0 }
        return backwards ? (current - 1 + count) % count : (current + 1) % count
    }

    /// Chrome's count beside the field: "3 of 12", or "No matches".
    static func status(_ current: Int?, count: Int) -> String {
        guard count > 0 else { return "No matches" }
        return "\(((current ?? -1) + 1).formatted()) of \(count.formatted())"
    }
}

/// The find bar over the flame chart: the field, "n of m", previous and
/// next, and Cancel (or Esc).
struct DeveloperPerformanceFindBar: View {
    @Binding var query: String
    let current: Int?
    let count: Int
    /// Bumped by ⌘F with the bar already up, to put the keyboard back in it.
    let focusRequest: Int
    let step: (_ backwards: Bool) -> Void
    let close: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DeveloperToolsStyle.controlSpacing) {
                field
                DeveloperPanelIcon(symbol: "chevron.up", title: "Search previous (⇧Return)") { step(true) }
                    .disabled(count == 0)
                DeveloperPanelIcon(symbol: "chevron.down", title: "Search next (Return)") { step(false) }
                    .disabled(count == 0)
                Spacer(minLength: 0)
                Button("Cancel", action: close)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, DeveloperToolsStyle.gutter)
            .frame(height: DeveloperToolsStyle.toolbarHeight)
            .background(DeveloperToolsStyle.chrome)
            Divider()
        }
        .onAppear { focused = true }
        .onChange(of: focusRequest) { _, _ in focused = true }
        .accessibilityIdentifier("developer-performance-find")
    }

    private var field: some View {
        HStack(spacing: DeveloperToolsStyle.controlSpacing) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Find", text: $query)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit {
                    step(NSApp.currentEvent?.modifierFlags.contains(.shift) == true)
                    focused = true
                }
                .onExitCommand { close() }
                .accessibilityLabel("Find in timeline")
            if !query.isEmpty {
                Text(DeveloperPerformanceFind.status(current, count: count))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .developerToolsField()
        .frame(maxWidth: 360)
    }
}
