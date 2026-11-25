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
    /// Which history Clear takes: nil for every space's, as Safari's All
    /// Profiles; shown only when a signed-out space keeps one of its own.
    @State private var clearsIn: UUID?
    @State private var span: Span = .all
    private var clearing: Bool { browser.recallMode == .clearing }

    enum Span: String, CaseIterable, Identifiable {
        case all = "All History", today = "Today", week = "Last 7 Days", month = "Last 30 Days"
        var id: Self { self }
        var since: Date? {
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: Date())
            switch self {
            case .all: return nil
            case .today: return today
            case .week: return calendar.date(byAdding: .day, value: -6, to: today)
            case .month: return calendar.date(byAdding: .day, value: -29, to: today)
            }
        }
    }

    var body: some View {
        Plate("History", width: 600, close: { browser.recalling = false }) {
            VStack(alignment: .leading, spacing: 14) {
                Hunt(text: $browser.recallHunt, prompt: "Search everywhere you have been", focus: $hunting,
                     count: (traces.count, "page"))

                if traces.isEmpty {
                    Card { Nothing(browser.recallHunt.isEmpty && span == .all ? "Nothing yet." : "Nothing matches.") }
                } else {
                    // Lazy: only the lines in view are made. Two thousand of
                    // them, each with its icon, took the panel a third of a
                    // second to open, and scrolling redrew them all.
                    ScrollView {
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
                                                // In this tab, as Chrome's
                                                // history does: Back returns here.
                                                (browser.pageTab(.history) ?? browser.active)?.go(to: trace.url)
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
                    .listHeight(420)
                }
            }
        } foot: {
            if clearing {
                sweeps
            } else {
                HStack {
                    PillMenu(selection: $span, title: span.rawValue) {
                        ForEach(Span.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .help("Show history from")
                    Spacer()
                    Pill("Clear…") { withAnimation(Motion.settle) { browser.recallMode = .clearing } }
                }
            }
        }
        .animation(Motion.settle, value: clearing)
        .onAppear {
            hunting = true
            refresh()
        }
        .onChange(of: browser.recallHunt) { _, _ in refresh() }
        .onChange(of: span) { _, _ in refresh() }
        // Another space may keep a history of its own (Spaces.history).
        .onChange(of: browser.spaceID) { _, _ in refresh() }
    }

    /// Three separate things, worded so nobody has to guess which one signs
    /// them out of their bank.
    private var sweeps: some View {
        VStack(alignment: .leading, spacing: 10) {
            Card {
                Line("History", historyDetail) {
                    let scopes = browser.historyScopes
                    if !scopes.isEmpty {
                        Picker("", selection: $clearsIn) {
                            Text("All Spaces").tag(UUID?.none)
                            ForEach(scopes, id: \.space) { Text($0.name).tag(UUID?.some($0.space)) }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                    }
                    Pill("Clear") {
                        browser.clearHistory(in: scopes.contains { $0.space == clearsIn } ? clearsIn : nil)
                        clearsIn = nil
                        refresh()
                        withAnimation(Motion.settle) { browser.recallMode = .history }
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
                Pill("Back") { withAnimation(Motion.settle) { browser.recallMode = .history } }
            }
        }
        .transition(.opacity)
    }

    private var historyDetail: String {
        guard let clearsIn, let scope = browser.historyScopes.first(where: { $0.space == clearsIn }) else {
            return "Everywhere you have been"
        }
        return "Where you have been in \(scope.name)"
    }

    private func refresh() {
        let found = browser.history.everything(matching: browser.recallHunt)
        traces = span.since.map { since in found.filter { $0.last >= since } } ?? found
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
                Mark(icon: Favicons.shared.cached(for: trace.url),
                     letter: trace.address.first.map { String($0).uppercased() } ?? "•", size: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(trace.title.isEmpty ? Address.withoutWWW(trace.address) : trace.title)
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                    Text(Address.withoutWWW(trace.address))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if hovering {
                    Quick("Remove", tint: .red.opacity(0.75), symbol: "trash", act: forget)
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
    @ObservedObject var fetches: Fetches
    /// Under the downloads button or in the side panel (Settings ›
    /// Downloads › Open Downloads): the same list in a narrower place, with
    /// its own title line and cross instead of the plate's.
    let compact: Bool
    let close: (() -> Void)?

    init(browser: Browser, loot: Loot, compact: Bool = false, close: (() -> Void)? = nil) {
        self.browser = browser
        self.loot = loot
        self.fetches = browser.fetches
        self.compact = compact
        self.close = close
    }

    var body: some View {
        if compact { small } else { plate }
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Downloads")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Spacer(minLength: 0)
                Door(icon: "folder", help: "Open the Downloads Folder") {
                    NSWorkspace.shared.open(browser.downloadsFolder)
                }
                if let close { Door(icon: "xmark", help: "Close", act: close) }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Rectangle().fill(Palette.hairline).frame(height: 1)
            list
                .padding(12)
            if !loot.kept.isEmpty {
                Spacer(minLength: 0)
                Rectangle().fill(Palette.hairline).frame(height: 1)
                HStack {
                    Spacer()
                    Pill("Clear list") { loot.forgetAll() }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var plate: some View {
        Plate("Downloads", width: 560, close: close ?? { browser.hoarding = false }) {
            list
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

    @ViewBuilder
    private var list: some View {
        if fetches.entries.isEmpty && loot.kept.isEmpty {
            Card { Nothing("Nothing downloaded yet.") }
        } else {
            FadingScroll {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if !fetches.entries.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Caption("Current downloads", count: fetches.entries.count)
                            Card {
                                ForEach(Array(fetches.entries.enumerated()), id: \.element.id) { index, entry in
                                    if index > 0 { Rule() }
                                    FetchRow(
                                        entry: entry,
                                        pause: { browser.pauseDownload(entry) },
                                        resume: { browser.resumeDownload(entry) },
                                        retry: { browser.retryDownload(entry) },
                                        cancel: { browser.cancelDownload(entry) }
                                    )
                                }
                            }
                        }
                    }

                    if !loot.kept.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Caption("Completed", count: loot.kept.count)
                            Card {
                                ForEach(Array(loot.kept.enumerated()), id: \.element.id) { index, keep in
                                    if index > 0 { Rule() }
                                    KeptRow(
                                        keep: keep,
                                        open: { loot.open(keep) },
                                        reveal: { loot.reveal(keep) },
                                        forget: { loot.forget(keep) }
                                    )
                                }
                            }
                        }
                    }
                }
                .padding(.bottom, 2)
            }
            // Hairlines from edge to edge, as Settings' are: the cards hold
            // icons, not text, at the inset a rule would start from.
            .environment(\.ruleInset, 0)
            .listHeight(420)
        }
    }

    /// The list's scroll, fading out at its foot while more lies below
    /// rather than cutting a line in half; less as the end comes up, and
    /// not at all once it is in view. A mask, so it is the same in light
    /// and dark and over whatever the list is drawn on.
    private struct FadingScroll<Content: View>: View {
        @ViewBuilder let content: () -> Content
        /// Where the list ends, and how tall the scroll is: the end lies
        /// below the foot by the difference.
        @State private var end: CGFloat = 0
        @State private var height: CGFloat = 0
        private let fade: CGFloat = 24
        private static var space: String { "downloads.list" }

        var body: some View {
            ScrollView {
                content()
                    // Read where it is rather than sent up as a preference:
                    // one from inside the scroll never came out of it here.
                    .background(GeometryReader { list in
                        let bottom = list.frame(in: .named(Self.space)).maxY
                        Color.clear
                            .onAppear { end = bottom }
                            .onChange(of: bottom) { _, new in end = new }
                    })
            }
            .coordinateSpace(name: Self.space)
            // Measured beside the scroll, not around it, so it sizes itself
            // as it always has.
            .background(GeometryReader { view in
                Color.clear
                    .onAppear { height = view.size.height }
                    .onChange(of: view.size.height) { _, new in height = new }
            })
            .mask {
                VStack(spacing: 0) {
                    Rectangle()
                    LinearGradient(colors: [.black, .black.opacity(1 - min(1, max(0, end - height) / fade))],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: fade)
                }
            }
        }
    }

    private struct FetchRow: View {
        @ObservedObject var entry: FetchEntry
        let pause: () -> Void
        let resume: () -> Void
        let retry: () -> Void
        let cancel: () -> Void

        private var bytes: String {
            let received = ByteCountFormatter.string(fromByteCount: entry.completedBytes, countStyle: .file)
            guard entry.totalBytes > 0 else { return received + " downloaded" }
            let total = ByteCountFormatter.string(fromByteCount: entry.totalBytes, countStyle: .file)
            return "\(received) of \(total)"
        }

        private var stateLabel: String {
            switch entry.state {
            case .downloading: return "Downloading"
            case .pausing: return entry.stopping
            case .paused: return "Paused"
            case .resuming: return "Resuming…"
            case .failed: return "Failed"
            }
        }

        private var icon: String {
            switch entry.state {
            case .downloading, .pausing, .resuming: return "arrow.down.circle"
            case .paused: return "pause.circle"
            case .failed: return "exclamationmark.circle"
            }
        }

        var body: some View {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(Palette.muted)
                    .frame(width: 18)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.name)
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 7) {
                        if let fraction = entry.fraction {
                            // Grey, as the ring in the chrome is.
                            Capsule()
                                .fill(Palette.hairline)
                                .overlay(alignment: .leading) {
                                    Capsule()
                                        .fill(Palette.ink.opacity(0.6))
                                        .frame(width: 68 * min(1, max(0, fraction)))
                                }
                                .frame(width: 68, height: 3)
                        }
                        Text("\(stateLabel) · \(bytes)")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Palette.muted)
                            .monospacedDigit()
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if case .failed = entry.state {
                        Text(entry.errorDescription ?? "The download failed.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Palette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                Spacer(minLength: 4)
                controls
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .contextMenu { if let address = entry.address { CopyAddress(address: address) } }
        }

        @ViewBuilder
        private var controls: some View {
            switch entry.state {
            case .downloading:
                HStack(spacing: 4) {
                    if entry.canPause { Quick("Pause", act: pause) }
                    Quick("Cancel", act: cancel)
                }
            case .pausing:
                HStack(spacing: 4) {
                    Quick(entry.stopping, act: {})
                        .disabled(true)
                    Quick("Cancel", act: cancel)
                }
            case .paused:
                HStack(spacing: 4) {
                    if entry.canResume {
                        Quick("Resume", act: resume)
                    } else if entry.canRetry {
                        Quick("Retry", act: retry)
                            .help("Start the download again from the beginning")
                    }
                    Quick("Remove", symbol: "trash", act: cancel)
                }
            case .resuming:
                HStack(spacing: 4) {
                    Quick("Resuming…", act: {})
                        .disabled(true)
                    Quick("Cancel", act: cancel)
                }
            case .failed:
                HStack(spacing: 4) {
                    if entry.canResume { Quick("Resume", act: resume) }
                    if entry.canRetry {
                        Quick("Retry", act: retry)
                            .help("Start the download again from the beginning")
                    }
                    Quick("Remove", symbol: "trash", act: cancel)
                }
            }
        }
    }

    private struct KeptRow: View {
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
                    Quick("Remove", tint: .red.opacity(0.75), symbol: "trash", act: forget)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(hovering ? Palette.hover : .clear)
            .contentShape(Rectangle())
            .contextMenu { if let address = keep.address { CopyAddress(address: address) } }
            .modifier(DragOut(keep: keep))
            .onTapGesture { if keep.stillThere { open() } }
            .onHover { hovering = $0 }
            .animation(Motion.quick, value: hovering)
        }
    }

    /// A finished download dragged out of the list as its file, onto a page
    /// or into another app, with the file's own icon under the pointer. A
    /// row whose file has gone has nothing to drag. The drag starts only
    /// once the pointer moves, so a click still opens the file.
    private struct DragOut: ViewModifier {
        let keep: Keep

        func body(content: Content) -> some View {
            if keep.stillThere {
                content.onDrag {
                    keep.dragged ?? NSItemProvider()
                } preview: {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: keep.path))
                        .resizable()
                        .frame(width: 32, height: 32)
                }
            } else {
                content
            }
        }
    }

    /// A row's right-click, for handing the download to another app.
    private struct CopyAddress: View {
        let address: String

        var body: some View {
            Button("Copy Address") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(address, forType: .string)
            }
        }
    }
}
