import SwiftUI

/// Everywhere you have been, and everything you have kept. Two lists in the
/// same white-and-hairline panel as the rest, and in both cases the point is
/// as much being able to remove a line as to read one.

enum When {
    private static let ago: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    static func said(_ date: Date) -> String {
        ago.localizedString(for: date, relativeTo: Date())
    }

    private static let hour: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    private static let plain: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMMM"
        return formatter
    }()

    /// The time of day. Once a list is grouped by day, that is all a row needs.
    static func clock(_ date: Date) -> String { hour.string(from: date) }

    static func day(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return plain.string(from: date)
    }
}

struct HistoryPanel: View {
    @ObservedObject var browser: Browser

    @FocusState private var hunting: Bool
    @State private var traces: [History.Trace] = []
    /// The list as drawn: each day's name, then its pages. Worked out when
    /// the history or the search changes, not each time the panel is drawn.
    @State private var lines: [Listed] = []
    @State private var clearing = false

    var body: some View {
        Plate("History", width: 600, close: { browser.recalling = false }) {
            VStack(alignment: .leading, spacing: 14) {
                Hunt(text: $browser.recallHunt, prompt: "Search everywhere you have been", focus: $hunting)

                if traces.isEmpty {
                    Card { Nothing(browser.recallHunt.isEmpty ? "Nothing yet." : "Nothing matches.") }
                } else {
                    // Lazy: only the lines in view are made. Two thousand of
                    // them, each with its icon, took the panel a third of a
                    // second to open, and scrolling redrew them all.
                    ScrollView(showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(lines) { line in
                                switch line.kind {
                                case .day(let day):
                                    Caption(day)
                                        .padding(.top, line.id == lines.first?.id ? 0 : 14)
                                        .padding(.bottom, 6)
                                case .trace(let trace, let first, let last):
                                    VStack(spacing: 0) {
                                        if !first { Rule() }
                                        Row(
                                            trace: trace,
                                            go: {
                                                browser.recalling = false
                                                browser.active?.go(to: trace.url)
                                            },
                                            forget: {
                                                browser.history.forget(trace.key)
                                                refresh()
                                            }
                                        )
                                    }
                                    // A day's card, drawn a line at a time.
                                    .background(Palette.ground)
                                    .clipShape(Slice(first: first, last: last))
                                    // The card's outline, reaching a point past the lines it
                                    // shares with its neighbours and cut to its own: only
                                    // its sides, and its rounded top or bottom, remain.
                                    .overlay(
                                        Slice(first: first, last: last)
                                            .strokeBorder(Palette.hairline, lineWidth: 1)
                                            .padding(.top, first ? 0 : -1)
                                            .padding(.bottom, last ? 0 : -1)
                                            .clipped()
                                    )
                                }
                            }
                        }
                        .padding(.bottom, 2)
                    }
                    .frame(maxHeight: 420)
                }
            }
        } foot: {
            if clearing {
                sweeps
            } else {
                HStack {
                    Text(traces.count == 1 ? "1 page" : "\(traces.count) pages")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                    Spacer()
                    Pill("Clear…") { withAnimation(Motion.settle) { clearing = true } }
                }
            }
        }
        .animation(Motion.settle, value: clearing)
        .onAppear {
            hunting = true
            refresh()
        }
        .onChange(of: browser.recallHunt) { _, _ in refresh() }
    }

    /// Three separate things, worded so nobody has to guess which one signs
    /// them out of their bank.
    private var sweeps: some View {
        VStack(alignment: .leading, spacing: 10) {
            Card {
                Line("History", "Everywhere you have been") {
                    Pill("Clear") {
                        browser.clearHistory()
                        refresh()
                        withAnimation(Motion.settle) { clearing = false }
                    }
                }
                Rule()
                Line("Cookies and sign-ins", "Signs you out of every site") {
                    Pill("Sign out of everything") { browser.clearSites() }
                }
                Rule()
                Line("Cache", "Only what was fetched to draw pages") {
                    Pill("Clear") { browser.clearCache() }
                }
            }
            HStack {
                Spacer()
                Pill("Back") { withAnimation(Motion.settle) { clearing = false } }
            }
        }
        .transition(.opacity)
    }

    private func refresh() {
        traces = browser.history.everything(matching: browser.recallHunt)
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: traces) { calendar.startOfDay(for: $0.last) }
        var made: [Listed] = []
        for day in grouped.keys.sorted(by: >) {
            let rows = grouped[day]!.sorted { $0.last > $1.last }
            made.append(Listed(id: "day " + day.description, kind: .day(When.day(day))))
            for (index, trace) in rows.enumerated() {
                made.append(Listed(id: trace.id, kind: .trace(trace, first: index == 0, last: index == rows.count - 1)))
            }
        }
        lines = made
    }

    /// One line of the list: a day's name, or a page under it.
    struct Listed: Identifiable {
        enum Kind {
            case day(String)
            case trace(History.Trace, first: Bool, last: Bool)
        }
        let id: String
        let kind: Kind
    }

    /// A slice of a card: rounded at the top on its first line and at the
    /// bottom on its last, as the whole card would be.
    struct Slice: InsettableShape {
        let first: Bool
        let last: Bool
        var inset: CGFloat = 0

        func path(in rect: CGRect) -> Path {
            let radius: CGFloat = 11 - inset
            let top = first ? radius : 0, bottom = last ? radius : 0
            return UnevenRoundedRectangle(topLeadingRadius: top, bottomLeadingRadius: bottom, bottomTrailingRadius: bottom, topTrailingRadius: top, style: .continuous)
                .path(in: rect.insetBy(dx: inset, dy: inset))
        }

        func inset(by amount: CGFloat) -> Slice {
            var copy = self
            copy.inset += amount
            return copy
        }
    }

    /// One line. A title, where it came from, and when — the three things you
    /// scan for, in the order you scan them.
    private struct Row: View {
        let trace: History.Trace
        let go: () -> Void
        let forget: () -> Void

        @State private var hovering = false

        var body: some View {
            HStack(spacing: 12) {
                Mark(icon: Favicons.shared.cached(trace.url.host()?.lowercased() ?? ""),
                     letter: trace.key.first.map { String($0).uppercased() } ?? "•", size: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(trace.title.isEmpty ? trace.key : trace.title)
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                    Text(trace.key)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if hovering {
                    Quick("Remove", tint: .red.opacity(0.75), act: forget)
                } else {
                    Text(When.clock(trace.last))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.muted)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(hovering ? Palette.hover : .clear)
            .contentShape(Rectangle())
            .onTapGesture(perform: go)
            .onHover { hovering = $0 }
            .animation(Motion.quick, value: hovering)
        }
    }
}

struct DownloadsPanel: View {
    @ObservedObject var browser: Browser
    @ObservedObject var loot: Loot

    var body: some View {
        Plate("Downloads", width: 560, close: { browser.hoarding = false }) {
            if loot.kept.isEmpty {
                Card { Nothing("Nothing downloaded yet.") }
            } else {
                ScrollView(showsIndicators: false) {
                    Card {
                        ForEach(Array(loot.kept.enumerated()), id: \.element.id) { index, keep in
                            if index > 0 { Rule() }
                            Row(
                                keep: keep,
                                open: { loot.open(keep) },
                                reveal: { loot.reveal(keep) },
                                forget: { loot.forget(keep) }
                            )
                        }
                    }
                    .padding(.bottom, 2)
                }
                .frame(maxHeight: 420)
            }
        } foot: {
            HStack {
                Text(loot.kept.isEmpty ? "Files land in \(browser.downloadsFolder.lastPathComponent)"
                     : "Clearing the list leaves the files where they are")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                Spacer()
                if !loot.kept.isEmpty {
                    Pill("Clear list") { loot.forgetAll() }
                }
            }
        }
    }

    private struct Row: View {
        let keep: Keep
        let open: () -> Void
        let reveal: () -> Void
        let forget: () -> Void

        @State private var hovering = false

        var body: some View {
            HStack(spacing: 12) {
                Image(systemName: keep.stillThere ? "doc" : "doc.badge.ellipsis")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(keep.stillThere ? Palette.muted : Palette.faint)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(keep.name)
                        .font(.system(size: 13))
                        .foregroundStyle(keep.stillThere ? Palette.ink : Palette.faint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(keep.from.isEmpty ? When.said(keep.date) : "\(keep.from) · \(When.said(keep.date))")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if hovering {
                    if keep.stillThere { Quick("Show in Finder", act: reveal) }
                    Quick("Remove", tint: .red.opacity(0.75), act: forget)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(hovering ? Palette.hover : .clear)
            .contentShape(Rectangle())
            .onTapGesture { if keep.stillThere { open() } }
            .onHover { hovering = $0 }
            .animation(Motion.quick, value: hovering)
        }
    }
}
