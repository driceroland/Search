import SwiftUI

/// Bringing things over from another browser, all in one place: which
/// browser, which of its profiles, and what of it. Opened from Settings ›
/// Passwords and from Bring in… in Bookmarks and Passwords; the Welcome has
/// the short version of it. From Settings › Extensions it opens on the
/// extensions alone.
///
/// What each browser holds is counted as the sheet opens, off the main
/// thread and from its files alone — no key is asked for and nothing is
/// decrypted, so nothing prompts until Bring them in is pressed. Then macOS
/// asks once for that browser's key, if it keeps one.
struct ImportPanel: View {
    @ObservedObject var browser: Browser

    @State private var sources: [ImportSource] = []
    @State private var unreadable: [String] = []
    @State private var looking = true
    @State private var pick: ImportSource?
    /// Each browser's profiles, and the one used most recently.
    @State private var profiles: [String: [ImportSource.Profile]] = [:]
    @State private var usual: [String: String] = [:]
    /// The profile chosen for a browser, where it isn't the usual one:
    /// a folder's name, or "" for all of them.
    @State private var chosen: [String: String] = [:]
    @State private var previews: [String: ImportSource.Preview] = [:]

    @State private var wantsPasswords = true
    @State private var wantsBookmarks = true
    @State private var wantsHistory = true
    @State private var wantsExtensions = false
    /// What came from this browser before goes, and its bookmarks come
    /// fresh. Off unless asked for; passwords are never taken out.
    @State private var replaceBookmarks = false
    /// Arc's spaces, their pinned tabs and its favourites (see takeArc).
    @State private var wantsArc = true
    /// How many spaces and pinned things Arc has, by browser and profile.
    @State private var arcCounts: [String: (spaces: Int, pinned: Int)] = [:]
    /// Opened for the extensions: the first browser counted with some is
    /// picked, until you pick one yourself.
    @State private var forExtensions = false
    @State private var bringing = false
    @State private var brought: [Said]?
    /// Whether that import left any bookmarks behind, which is what the
    /// offer to show the bar is for.
    @State private var marksLanded = false

    struct Said: Hashable {
        let ok: Bool
        let text: String
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Nothing in the other browser changes. Passwords go into your keychain.")
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.muted)

            if looking {
                HStack(spacing: 8) {
                    Ring(size: 10)
                    Text("Looking on this Mac…").font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
            } else if sources.isEmpty {
                Card { Nothing("No other browser found on this Mac.") }
            } else {
                Caption("On this Mac")
                Card {
                    ForEach(Array(sources.enumerated()), id: \.element.id) { index, source in
                        if index > 0 { Rule() }
                        Row(name: source.name, detail: detail(of: source), chosen: pick == source) {
                            guard !bringing else { return }
                            pick = source
                            replaceBookmarks = false
                            forExtensions = false
                            brought = nil
                        }
                    }
                }
            }

            notes

            if let source = pick {
                options(for: source)
            }
        }
    }

    var body: some View {
        Plate("Bring things over", width: 580, close: { browser.bringingIn = nil }) {
            // As tall as it needs to be, and scrolling past what the window
            // can hold: many browsers, or a small window.
            ViewThatFits(in: .vertical) {
                content
                ScrollView { content }
                    .scrollBounceBehavior(.basedOnSize)
            }
        } foot: {
            VStack(alignment: .leading, spacing: 10) {
                if let brought {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(brought, id: \.self) { said in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: said.ok ? "checkmark" : "exclamationmark.circle")
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .foregroundStyle(said.ok ? Palette.ink : Palette.muted)
                                    .frame(width: 12)
                                Text(said.text)
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(said.ok ? Palette.ink : Palette.muted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .transition(.opacity)
                }
                HStack(spacing: 8) {
                    if brought != nil {
                        Pill("Show bookmarks") {
                            browser.bringingIn = nil
                            browser.bookmarking = true
                        }
                        // The bar is off until it is asked for, and nobody asks
                        // for a row that has nothing in it. Bookmarks having just
                        // arrived is the one moment it is worth offering, and the
                        // sheet goes so that the bar is seen where it appears.
                        if marksLanded, !browser.prefs.bookmarksBar {
                            Pill("Show the bookmarks bar") {
                                withAnimation(Motion.glide) { browser.prefs.bookmarksBar = true }
                                browser.bringingIn = nil
                            }
                        }
                        Pill("Show passwords") {
                            browser.bringingIn = nil
                            browser.managing = true
                        }
                    } else if let source = pick {
                        Pill(bringing ? "Bringing…" : "Bring them in", filled: true) { bring(from: source) }
                            .disabled(bringing || !(wantsPasswords || wantsBookmarks || wantsHistory || (wantsExtensions && !fresh(source).isEmpty)
                                                     || (wantsArc && arcCounts[key(source, profile(of: source))] != nil)))
                        if bringing { Ring(size: 10) }
                    }
                    Spacer(minLength: 8)
                    Pill("File…") { browser.importFile() }
                        .disabled(bringing)
                }
            }
        }
        .animation(Motion.settle, value: brought)
        .animation(Motion.settle, value: pick)
        .onAppear {
            if browser.bringingExtensions {
                browser.bringingExtensions = false
                forExtensions = true
                wantsExtensions = true
                wantsPasswords = false
                wantsBookmarks = false
                wantsHistory = false
            }
            look()
        }
        .onChange(of: previews) { _, _ in
            guard forExtensions, let pick, fresh(pick).isEmpty,
                  let other = sources.first(where: { !fresh($0).isEmpty }) else { return }
            self.pick = other
        }
        // Asked for again at another browser while still open.
        .onChange(of: browser.bringingIn) { _, name in
            guard !bringing, let found = sources.first(where: { $0.name == name }) else { return }
            pick = found
            brought = nil
        }
    }

    /// Safari, and browsers on this Mac with nothing where their data should
    /// be: said by name rather than left out.
    @ViewBuilder
    private var notes: some View {
        let lines = (ImportSource.safari
                     ? ["Safari — macOS keeps its data from other apps: in Safari, File › Export Browsing Data, then bring the file in below."]
                     : []) + unreadable
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(lines, id: \.self) { line in
                    Text(line)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.faint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.leading, 2)
        }
    }

    private func options(for source: ImportSource) -> some View {
        let preview = previews[key(source, profile(of: source))]
        let extensions = fresh(source)
        return Card {
            if let record = ImportRecords.of(source.name) {
                Line("Brought before", broughtBefore(record)) { EmptyView() }
                Rule()
            }
            if let choices = profiles[source.id], choices.count > 1 {
                Line("Profile") {
                    Picker("", selection: Binding(
                        get: { chosen[source.id] ?? usual[source.id] ?? "" },
                        set: { value in
                            chosen[source.id] = value
                            brought = nil
                            count(source)
                        }
                    )) {
                        ForEach(choices) { profile in
                            Text(profile.id == usual[source.id] ? "Most recent: \(profile.name)" : profile.name).tag(profile.id)
                        }
                        Divider()
                        Text("All profiles").tag("")
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                Rule()
            }
            // A kind the browser has none of is said so, and can't be picked.
            Line("Passwords", preview?.passwords == 0 ? "None in \(source.name)" : source.asksForKey
                 ? "macOS asks once for \(source.name)'s keychain key"
                 : "Read from \(source.name)'s own files, unless it has a primary password") {
                option($wantsPasswords, none: preview?.passwords == 0)
            }
            Rule()
            Line("Bookmarks", preview?.bookmarks == 0 ? "None in \(source.name)" : "In a “\(source.name)” folder, or at the top if you have none yet") {
                option($wantsBookmarks, none: preview?.bookmarks == 0)
            }
            // Brought before: only what is new comes, unless what came from
            // it last time is to go first. An import from before this was
            // kept has nothing recorded, and nothing is guessed at.
            if wantsBookmarks, preview?.bookmarks != 0, let record = ImportRecords.of(source.name) {
                Rule()
                let recorded = !record.bookmarkIDs.isEmpty
                Line("Replace what came from \(source.name) before",
                     recorded ? "Its bookmarks from \(record.date.formatted(.dateTime.day().month())) go, and these come fresh; passwords only ever add"
                              : "Nothing recorded from \(source.name) yet — only what is new comes") {
                    option($replaceBookmarks, none: !recorded)
                }
            }
            Rule()
            Line("History", preview?.places == 0 ? "None in \(source.name)" : "The last \((preview.map { $0.places } ?? 3000).formatted()) places") {
                option($wantsHistory, none: preview?.places == 0)
            }
            // Arc's own: its spaces, what is pinned in them, its favourites.
            if let arc = arcCounts[key(source, profile(of: source))], arc.spaces + arc.pinned > 0 {
                Rule()
                Line("Spaces and pinned tabs",
                     "\(arc.spaces == 1 ? "1 space" : "\(arc.spaces) spaces"), \(arc.pinned) pinned — each a space here, its pinned tabs asleep in it, the favourites as pins") {
                    Switch(on: $wantsArc)
                }
            }
            if !extensions.isEmpty {
                Rule()
                Line("Extensions", "\(extensions.count) found — installed fresh from the Chrome Web Store, you say yes to each one") {
                    Switch(on: $wantsExtensions)
                }
            }
        }
    }

    // MARK: - counting

    private func key(_ source: ImportSource, _ profile: String?) -> String {
        "\(source.id)/\(profile ?? "")"
    }

    /// The profile to read: the one chosen, or the one used most recently;
    /// nil for all of them.
    private func profile(of source: ImportSource) -> String? {
        let id = chosen[source.id] ?? usual[source.id] ?? ""
        return id.isEmpty ? nil : id
    }

    private func detail(of source: ImportSource) -> String {
        guard let preview = previews[key(source, profile(of: source))] else { return "Counting…" }
        func count(_ n: Int, _ one: String) -> String { n == 1 ? "1 \(one)" : "\(n.formatted()) \(one)s" }
        var parts: [String] = []
        if let choices = profiles[source.id], choices.count > 1 { parts.append("\(choices.count) profiles") }
        // What it has; a kind it has none of isn't worth a word.
        for (n, one) in [(preview.bookmarks, "bookmark"), (preview.places, "place"), (preview.passwords, "password")] where n > 0 {
            parts.append(count(n, one))
        }
        if let arc = arcCounts[key(source, profile(of: source))], arc.spaces > 0 {
            parts.append(count(arc.spaces, "space"))
        }
        if let record = ImportRecords.of(source.name) {
            parts.append("brought \(record.date.formatted(.dateTime.day().month()))")
        }
        return parts.isEmpty ? "Nothing to bring in" : parts.joined(separator: " · ")
    }

    /// What was brought from it before, in a line: "312 bookmarks, 1,204
    /// places and 58 passwords, 27 Sep".
    private func broughtBefore(_ record: ImportRecord) -> String {
        func count(_ n: Int, _ one: String) -> String { n == 1 ? "1 \(one)" : "\(n.formatted()) \(one)s" }
        let parts = [(record.bookmarks, "bookmark"), (record.places, "place"), (record.passwords, "password"),
                     (record.spaces ?? 0, "space"), (record.pinned ?? 0, "pinned tab")]
            .filter { $0.0 > 0 }.map { count($0.0, $0.1) }
        let what = parts.isEmpty ? "Nothing new" : ListFormatter.localizedString(byJoining: parts)
        return "\(what), \(record.date.formatted(.dateTime.day().month()))"
    }

    /// A kind's switch; off and out of reach when there is none of it.
    @ViewBuilder
    private func option(_ on: Binding<Bool>, none: Bool) -> some View {
        if none {
            Switch(on: .constant(false)).disabled(true).opacity(0.4)
        } else {
            Switch(on: on)
        }
    }

    /// The store extensions it has that aren't here already.
    private func fresh(_ source: ImportSource) -> [String] {
        guard #available(macOS 15.4, *), let preview = previews[key(source, profile(of: source))] else { return [] }
        let have = Set(Extensions.shared.installed.map(\.id))
        return preview.extensions.filter { !have.contains($0) }
    }

    /// Every browser on this Mac, its profiles and what each holds, found
    /// off the main thread.
    private func look() {
        let wanted = browser.bringingIn ?? ""
        DispatchQueue.global(qos: .userInitiated).async {
            let found = ImportSource.installed()
            let missing = Chromium.unreadable().map { "\($0.source.name) is on this Mac, but nothing of it was found in \($0.looked)." }
            let lists = found.map { ($0.id, $0.profiles, $0.usual) }
            DispatchQueue.main.async {
                sources = found
                unreadable = missing
                for (id, list, most) in lists {
                    profiles[id] = list
                    usual[id] = most
                }
                pick = found.first { $0.name == wanted } ?? found.first
                looking = false
                found.forEach(count)
            }
        }
    }

    /// What a browser holds in the profile chosen for it, unless counted
    /// already.
    private func count(_ source: ImportSource) {
        let profile = profile(of: source)
        let key = key(source, profile)
        guard previews[key] == nil else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let preview = source.preview(profile: profile)
            let arc = source.arcCounts(profile: profile)
            DispatchQueue.main.async {
                if let arc { arcCounts[key] = arc }
                previews[key] = preview
            }
        }
    }

    // MARK: - bringing

    private func bring(from source: ImportSource) {
        // This import's own answer, not the one before it in the same sheet.
        marksLanded = false
        let profile = profile(of: source)
        let extensions = wantsExtensions ? fresh(source) : []
        // A kind it has none of isn't read at all: no keychain question for
        // a browser with no passwords.
        let preview = previews[key(source, profile)]
        let passwords = wantsPasswords && preview?.passwords != 0
        let marks = wantsBookmarks && preview?.bookmarks != 0
        let places = wantsHistory && preview?.places != 0
        bringing = true
        var said: [Int: Said] = [:]
        let group = DispatchGroup()
        if passwords {
            group.enter()
            // The one moment macOS asks for the key, if the browser keeps one.
            DispatchQueue.global(qos: .userInitiated).async {
                let outcome = Result { try source.read(profile: profile) }
                DispatchQueue.main.async {
                    switch outcome {
                    case .success(let found):
                        let kept = browser.keep(found)
                        ImportRecords.note(source.name, passwords: kept)
                        let skipped = found.skipped > 0 ? " (\(found.skipped.formatted()) skipped: no address)" : ""
                        said[0] = Said(ok: true, text: (kept == 1 ? "1 password" : "\(kept.formatted()) passwords") + skipped)
                    case .failure(Chromium.Trouble.noPassphrase):
                        said[0] = Said(ok: false, text: "macOS didn't hand over \(source.name)'s key — allow it and try again")
                    case .failure(Mozilla.Trouble.primaryPassword):
                        said[0] = Said(ok: false, text: "\(source.name) has a primary password: export your passwords from it and bring in the CSV file")
                    case .failure:
                        said[0] = Said(ok: false, text: "No passwords readable in \(source.name)")
                    }
                    group.leave()
                }
            }
        }
        if marks {
            let (added, already, kept) = browser.takeBookmarks(from: source, profile: profile, replacing: replaceBookmarks)
            marksLanded = added + already > 0
            said[1] = kept
                ? Said(ok: false, text: "Couldn't read all of \(source.name)'s bookmarks: what came from it before was kept, \(added.formatted()) new")
                : Said(ok: true, text: added == 0 && already == 0 ? "No bookmarks in \(source.name)"
                           : already == 0 ? "\(added.formatted()) bookmarks"
                           : "\(added.formatted()) new bookmarks, \(already.formatted()) already here")
        }
        if places {
            group.enter()
            browser.takePlaces(from: source, profile: profile) { count in
                said[2] = Said(ok: true, text: "\(count.formatted()) places")
                group.leave()
            }
        }
        if #available(macOS 15.4, *), !extensions.isEmpty {
            // Each from the store, fresh and checked, one question at a time.
            Task { for id in extensions { await Extensions.shared.install(id: id) } }
            said[3] = Said(ok: true, text: extensions.count == 1 ? "1 extension to confirm" : "\(extensions.count) extensions to confirm")
        }
        if wantsArc, arcCounts[key(source, profile)] != nil, let sidebar = source.arcSidebar(profile: profile) {
            let (spaces, pins, tabs) = browser.takeArc(sidebar, from: source, profile: profile)
            ImportRecords.note(source.name, spaces: spaces, pinned: pins + tabs)
            func count(_ n: Int, _ one: String) -> String { n == 1 ? "1 \(one)" : "\(n.formatted()) \(one)s" }
            said[4] = Said(ok: true, text: spaces + pins + tabs == 0 ? "Arc's spaces and pins were all here already"
                           : "\(count(spaces, "new space")), \(count(pins, "pin")), \(count(tabs, "pinned tab"))")
        }
        group.notify(queue: .main) {
            bringing = false
            brought = said.keys.sorted().compactMap { said[$0] }
        }
    }

    /// One browser to choose, and what it holds.
    private struct Row: View {
        let name: String
        let detail: String
        let chosen: Bool
        let pick: () -> Void
        @State private var hovering = false

        var body: some View {
            HStack(spacing: 12) {
                Circle()
                    .strokeBorder(chosen ? Palette.ink : Palette.faint, lineWidth: chosen ? 4.5 : 1.2)
                    .frame(width: 14, height: 14)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.system(size: 13)).foregroundStyle(Palette.ink)
                    Text(detail).font(.system(size: 11.5)).foregroundStyle(Palette.muted).monospacedDigit()
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(hovering ? Palette.hover : .clear)
            .contentShape(Rectangle())
            .onTapGesture(perform: pick)
            .onHover { hovering = $0 }
            .animation(Motion.quick, value: hovering)
        }
    }
}
