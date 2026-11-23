import Foundation
import SwiftUI

// The tabs Search closed by itself, as Arc's archive keeps them.
//
// With Settings › Tabs › Close tabs left alone on, a tab nobody has looked
// at for its time closes (Closing.swift). ⇧⌘T and Recently Closed hold a
// dozen closes, and every close counts, ⌘W's too: a week's worth of tabs
// closed overnight went past them, and History has each page among
// everything else. Here they stay together, newest first, for thirty days
// or the last five hundred: History › Archived Tabs… lists them, with a
// search, and a click opens one again in the window.
//
// Only what Search closed: a tab you closed yourself is one you meant to.
// Never a private tab, which nothing keeps. Clearing the history empties
// it too. With tabs never closing,
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
    /// Kept for a month: past that, History has it.
    nonisolated static let lasts: TimeInterval = 30 * 86_400

    let file: URL
    init(file name: String) {
        file = Store.file(name)
        let saved = (try? Data(contentsOf: file)).flatMap { try? Archive.decoder.decode([Archived].self, from: $0) }
        tabs = Archive.trimmed(saved ?? [], now: Date())
    }

    // MARK: - the one

    static let shared = Archive(file: "archive.json")

    // MARK: - changing it

    /// A tab Search just closed. A page already here moves to the top.
    func add(_ url: URL, title: String, at closed: Date = Date()) {
        guard let url = History.kept(url) else { return }
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

    /// Newest first, a month at most, and no more than the cap.
    nonisolated static func trimmed(_ list: [Archived], now: Date) -> [Archived] {
        let since = now.addingTimeInterval(-lasts)
        return Array(list.filter { $0.closed >= since }.sorted { $0.closed > $1.closed }.prefix(cap))
    }

    private func save() {
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
    var archive: Archive { Archive.shared }

    /// Closing one by itself (Closing.swift): into the archive first. Its
    /// address as the tab knows it, asleep or not; Search's own pages are
    /// one click away already.
    func archive(_ tab: Tab) {
        guard !tab.shy, let url = tab.address ?? tab.page?.url, InternalPage(url: url) == nil,
              ["http", "https", "file"].contains(url.scheme?.lowercased() ?? "") else { return }
        archive.add(url, title: tab.title)
    }

    /// From the list: a tab of its own in the window, in front,
    /// and out of the archive.
    func reopen(_ archived: Archived) {
        archive.remove(archived.id)
        _ = open(archived.url, foreground: true)
    }

    /// History › Archived Tabs…, in a tab.
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
        Plate("Archived Tabs", width: 600, close: { browser.archiving = false }) {
            VStack(alignment: .leading, spacing: 14) {
                Hunt(text: $hunt, prompt: "Search the tabs Search closed", focus: $hunting)
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
                Text("· kept for 30 days")
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
            ? "Tabs never close by themselves (Settings › Tabs)."
            : "Nothing yet. Tabs Search closes for you land here."
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

    /// Each day's name, then its tabs, newest first.
    private func lines(_ listed: [Archived]) -> [Line] {
        let calendar = Calendar.current
        var made: [Line] = []
        var at = 0
        while at < listed.count {
            let day = calendar.startOfDay(for: listed[at].closed)
            var end = at
            while end < listed.count, calendar.startOfDay(for: listed[end].closed) == day { end += 1 }
            made.append(Line(id: "day \(day.timeIntervalSince1970)", kind: .day(When.day(day)), first: made.isEmpty))
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
                    Text(When.clock(tab.closed))
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
            .help("Open again")
        }
    }
}
