import Foundation
import SwiftUI

// The tabs Search closed by itself, as Arc's archive keeps them.
//
// With Settings › Tabs › Close tabs left alone on, a tab nobody has looked
// at for its time closes (Closing.swift). ⇧⌘T and Recently Closed hold a
// dozen closes, and every close counts, ⌘W's too: a week's worth of tabs
// closed overnight went past them, and History has each page among
// everything else. Here they stay together, newest first, from the start
// of last month on, five hundred at most: the Archive (search://archive,
// the button after Downloads, or History › Archived Tabs…) lists them in
// Recent, Yesterday, This Week, This Month and Last Month, with a search,
// and a click opens one again in the space on screen.
//
// Only what Search closed: a tab you closed yourself is one you meant to.
// Never a private tab, which nothing keeps. Each profile has its own, as it
// has its own history: a window lists only its profile's, and deleting a
// profile, or clearing its history, empties it. With tabs never closing,
// nothing is added and the menu doesn't offer it.

/// One tab Search closed, as the archive keeps it.
struct Archived: Codable, Identifiable, Equatable {
    var id = UUID()
    let url: URL
    let title: String
    /// When it was closed.
    let closed: Date

    var label: String { title.isEmpty ? Address.withoutWWW(Address.editable(url)) : title }
    var site: String { Address.withoutWWW(url.host() ?? Address.editable(url)) }
}

@MainActor
final class Archive: ObservableObject {
    /// Newest first.
    @Published private(set) var tabs: [Archived] = []

    /// Kept at most: far more than anybody scrolls back through, and a small file.
    nonisolated static let cap = 500
    /// Kept for a month at least: past that, History has it.
    nonisolated static let lasts: TimeInterval = 30 * 86_400

    /// The oldest close still kept: thirty days back, or the start of last
    /// month when that is further, so Last Month is whole.
    nonisolated static func since(_ now: Date, calendar: Calendar = .current) -> Date {
        let month = calendar.dateInterval(of: .month, for: now)?.start ?? now
        let last = calendar.date(byAdding: .month, value: -1, to: month) ?? month
        return min(now.addingTimeInterval(-lasts), last)
    }

    /// The Archive's groups, newest first.
    enum Shelf: Int, CaseIterable {
        case recent, yesterday, week, month, lastMonth

        var title: String {
            switch self {
            case .recent: return "Recent"
            case .yesterday: return "Yesterday"
            case .week: return "This Week"
            case .month: return "This Month"
            case .lastMonth: return "Last Month"
            }
        }
    }

    /// Which group a close falls in: the last 24 hours, then the day
    /// before today, this week, this month and last month, each without
    /// what an earlier one took. Nil before last month.
    nonisolated static func shelf(of closed: Date, now: Date, calendar: Calendar = .current) -> Shelf? {
        if closed >= now.addingTimeInterval(-86_400) { return .recent }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(closed, inSameDayAs: yesterday) { return .yesterday }
        if calendar.isDate(closed, equalTo: now, toGranularity: .weekOfYear) { return .week }
        if calendar.isDate(closed, equalTo: now, toGranularity: .month) { return .month }
        if let start = calendar.dateInterval(of: .month, for: now)?.start,
           let last = calendar.date(byAdding: .month, value: -1, to: start),
           calendar.isDate(closed, equalTo: last, toGranularity: .month) { return .lastMonth }
        // Thirty days back can reach two months back early in a month.
        return closed >= now.addingTimeInterval(-lasts) ? .lastMonth : nil
    }

    let file: URL
    /// Its profile deleted: nothing more is written.
    private var retired = false

    init(file name: String) {
        file = Store.file(name)
        let saved = (try? Data(contentsOf: file)).flatMap { try? Archive.decoder.decode([Archived].self, from: $0) }
        tabs = Archive.trimmed(saved ?? [], now: Date())
    }

    // MARK: - each profile's

    private static var made: [UUID: Archive] = [:]

    /// archive.json for Personal, one of its own for each other profile, as
    /// history is (see Profiles.history).
    static func fileName(of profile: UUID) -> String {
        profile == Profile.personalID ? "archive.json" : "archive-\(profile.uuidString).json"
    }

    static func of(_ profile: UUID) -> Archive {
        if let archive = made[profile] { return archive }
        let archive = Archive(file: fileName(of: profile))
        made[profile] = archive
        return archive
    }

    /// A profile deleted: its archive emptied and its file gone, opened
    /// this run or not.
    static func forget(profile: UUID) {
        made.removeValue(forKey: profile)?.retired = true
        Disk.remove(Store.file(fileName(of: profile)))
    }

    // MARK: - changing it

    /// A tab Search just closed. A page already here moves to the top.
    func add(_ url: URL, title: String, at closed: Date = Date()) {
        guard !retired, let url = History.kept(url) else { return }
        var list = tabs.filter { $0.url != url }
        list.insert(Archived(url: url, title: title, closed: closed), at: 0)
        tabs = Archive.trimmed(list, now: Date())
        save()
    }

    func remove(_ id: Archived.ID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        tabs.removeAll { $0.id == id }
        save()
    }

    func clear() {
        guard !tabs.isEmpty else { return }
        tabs = []
        save()
    }

    /// What the list shows: past the month, nothing, even before anything
    /// is next added; and, with words typed, what has all of them in its
    /// title or address.
    func listed(matching hunt: String = "", now: Date = Date()) -> [Archived] {
        let words = hunt.lowercased().split(whereSeparator: \.isWhitespace)
        return Archive.trimmed(tabs, now: now).filter { tab in
            let text = (tab.title + " " + tab.url.absoluteString).lowercased()
            return words.allSatisfy { text.contains($0) }
        }
    }

    /// Newest first, from `since` on, and no more than the cap.
    nonisolated static func trimmed(_ list: [Archived], now: Date) -> [Archived] {
        let since = since(now)
        return Array(list.filter { $0.closed >= since }.sorted { $0.closed > $1.closed }.prefix(cap))
    }

    private func save() {
        guard !retired else { return }
        let snapshot = tabs
        Disk.write(file) { try? Archive.encoder.encode(snapshot) }
    }

    nonisolated private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    nonisolated private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

extension Browser {
    /// This window's profile's.
    var archive: Archive { Archive.of(profileID) }

    /// Closing one by itself (Closing.swift): into the archive first. Its
    /// address as the tab knows it, asleep or not; Search's own pages are
    /// one click away already.
    func archive(_ tab: Tab) {
        guard !tab.shy, let url = tab.address ?? tab.page?.url, InternalPage(url: url) == nil,
              ["http", "https", "file"].contains(url.scheme?.lowercased() ?? "") else { return }
        archive.add(url, title: tab.title)
    }

    /// From the list: a tab of its own in the space on screen, in front,
    /// and out of the archive.
    func reopen(_ archived: Archived) {
        archive.remove(archived.id)
        _ = open(archived.url, foreground: true)
    }

    /// The Archive, search://archive, in a tab.
    var archiving: Bool {
        get { pageTab(.archive) != nil }
        set { if newValue { show(InternalPage(.archive)) } else { putAway(.archive) } }
    }
}

/// History › Archived Tabs…: History's look, its days and its rows, for the
/// tabs Search closed by itself.
struct ArchivePanel: View {
    @ObservedObject var browser: Browser
    @ObservedObject var archive: Archive

    @FocusState private var hunting: Bool
    @State private var hunt = ""

    private var listed: [Archived] { archive.listed(matching: hunt) }

    var body: some View {
        let listed = self.listed
        Plate("Archive", width: 600, close: { browser.archiving = false }) {
            VStack(alignment: .leading, spacing: 14) {
                Hunt(text: $hunt, prompt: "Search the Archive", focus: $hunting)
                if listed.isEmpty {
                    Card { Nothing(hunt.isEmpty ? empty : "Nothing matches.") }
                } else {
                    ScrollView(showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(lines(listed)) { line in
                                switch line.kind {
                                case .day(let day):
                                    Caption(day)
                                        .padding(.top, line.first ? 0 : 14)
                                        .padding(.bottom, 6)
                                case .tab(let tab, let first, let last):
                                    VStack(spacing: 0) {
                                        if !first { Rule() }
                                        Row(tab: tab,
                                            go: { browser.reopen(tab) },
                                            remove: { archive.remove(tab.id) })
                                    }
                                    .background(Palette.ground)
                                    .clipShape(HistoryPanel.Slice(first: first, last: last))
                                    .overlay(
                                        HistoryPanel.Slice(first: first, last: last)
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
            HStack {
                Text(listed.count == 1 ? "1 tab" : "\(listed.count) tabs")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                Text("· kept until the end of next month")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.faint)
                Spacer()
                if !archive.tabs.isEmpty {
                    Pill("Clear") { archive.clear() }
                }
            }
        }
        .onAppear { hunting = true }
    }

    private var empty: String {
        browser.prefs.tabLife.interval == nil
            ? "Archiving is off (Settings › Tabs › Archive tabs you leave alone)."
            : "Nothing yet. Tabs you leave alone land here."
    }

    private struct Line: Identifiable {
        enum Kind {
            case day(String)
            case tab(Archived, first: Bool, last: Bool)
        }
        let id: String
        let kind: Kind
        var first = false
    }

    /// Each group's name, then its tabs, newest first.
    private func lines(_ listed: [Archived]) -> [Line] {
        let now = Date()
        let listed = listed.filter { Archive.shelf(of: $0.closed, now: now) != nil }
        var made: [Line] = []
        var at = 0
        while at < listed.count {
            let shelf = Archive.shelf(of: listed[at].closed, now: now)
            var end = at
            while end < listed.count, Archive.shelf(of: listed[end].closed, now: now) == shelf { end += 1 }
            made.append(Line(id: "shelf \(shelf?.rawValue ?? -1)", kind: .day(shelf?.title ?? ""), first: made.isEmpty))
            for index in at..<end {
                made.append(Line(id: listed[index].id.uuidString,
                                 kind: .tab(listed[index], first: index == at, last: index == end - 1)))
            }
            at = end
        }
        return made
    }

    /// A title, its site, and when it closed: History's row.
    private struct Row: View {
        let tab: Archived
        let go: () -> Void
        let remove: () -> Void

        @State private var hovering = false

        var body: some View {
            HStack(spacing: 12) {
                Mark(icon: Favicons.shared.cached(for: tab.url),
                     letter: tab.site.first.map { String($0).uppercased() } ?? "•", size: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tab.label)
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                    Text(tab.site)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if hovering {
                    Quick("Remove", tint: .red.opacity(0.75), act: remove)
                } else {
                    Text(Calendar.current.isDateInToday(tab.closed)
                         ? When.clock(tab.closed)
                         : When.day(Calendar.current.startOfDay(for: tab.closed)) + ", " + When.clock(tab.closed))
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
            .help("Open again in this space")
        }
    }
}

/// The Archive's button in the column's foot, after Downloads: there only
/// while tabs are archived (Settings › Tabs), lit while the Archive is the
/// tab in front.
struct ArchiveDoor: View {
    @ObservedObject var browser: Browser

    var body: some View {
        if browser.prefs.tabLife != .never {
            if let tab = browser.active {
                Front(browser: browser, tab: tab)
            } else {
                ArchiveDoor.door(browser, on: false)
            }
        }
    }

    fileprivate static func door(_ browser: Browser, on: Bool) -> some View {
        Door(icon: "cabinet", on: on, help: "Archive") {
            browser.archiving = !on
        }
    }

    /// Watches the tab in front, so the button lights as it becomes the
    /// Archive, by the button, a link or an address typed, and goes out
    /// as it leaves.
    private struct Front: View {
        let browser: Browser
        @ObservedObject var tab: Tab

        var body: some View {
            ArchiveDoor.door(browser, on: tab.page?.kind == .archive)
        }
    }
}
