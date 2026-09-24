import Foundation

// Where you have been, so the field can finish the address for you. Kept in one
// small file next to the app's own settings, written a moment after a visit
// rather than on every keystroke.

struct Suggestion: Identifiable, Equatable {
    /// What you would have typed to get here: no scheme, no www.
    let key: String
    let title: String
    let url: URL
    let kind: Kind
    /// Set when this is a page you already have open somewhere.
    var tab: UUID?

    enum Kind {
        /// A page that is open right now.
        case open
        /// Somewhere you have actually been.
        case visited
        /// One of the well-known addresses the field knows from the start.
        case known
        /// Not a place at all — words, and an engine to ask.
        case search
    }

    var id: String { key }
}

private struct Visit: Codable {
    var url: String
    var key: String
    var title: String
    var count: Int
    var last: Date
}

@MainActor
final class History: ObservableObject {
    private var visits: [String: Visit] = [:] {
        didSet {
            recentCache = nil
            objectWillChange.send()
        }
    }
    /// The last few places, as the History menu lists them. The menu bar is
    /// drawn again whenever anything in the window changes — every key typed
    /// into the address field included — and sorting the whole history for
    /// it each time cost more than everything else a key press does.
    private var recentCache: [Trace]?
    private var saving = false

    init() { load() }

    // MARK: - writing

    func record(_ url: URL, title: String) {
        guard url.scheme == "http" || url.scheme == "https" else { return }
        let key = Address.pretty(url).lowercased()
        guard !key.isEmpty else { return }

        // Reading a deep page is also, in the way that matters here, another
        // visit to the site. Without this, typing three letters offers the
        // article you happened to open last week rather than the front page —
        // and nobody types a domain meaning to land halfway down it.
        if let host = url.host(), key.contains("/") {
            let root = (host.hasPrefix("www.") ? String(host.dropFirst(4)) : host).lowercased()
            var home = visits[root] ?? Visit(
                url: "https://" + root + "/", key: root, title: "", count: 0, last: Date()
            )
            home.count += 1
            home.last = Date()
            visits[root] = home
        }

        if var seen = visits[key] {
            seen.count += 1
            seen.last = Date()
            seen.url = url.absoluteString
            if !title.isEmpty { seen.title = title }
            visits[key] = seen
        } else {
            visits[key] = Visit(
                url: url.absoluteString,
                key: key,
                title: title,
                count: 1,
                last: Date()
            )
        }
        save()
    }

    /// Somewhere another browser has been. Counted as it was counted there,
    /// so a site visited daily for a year outranks one seen once — the day
    /// you switch, the field already knows you.
    func take(_ url: URL, title: String, count: Int, last: Date) {
        guard url.scheme == "http" || url.scheme == "https" else { return }
        let key = Address.pretty(url).lowercased()
        guard !key.isEmpty else { return }
        if var seen = visits[key] {
            seen.count += count
            if last > seen.last { seen.last = last }
            if seen.title.isEmpty { seen.title = title }
            visits[key] = seen
        } else {
            visits[key] = Visit(url: url.absoluteString, key: key, title: title, count: count, last: last)
        }
    }

    /// After a batch of `take`s.
    func settle() { save() }

    /// A page's title usually lands a beat after the page does.
    func retitle(_ url: URL, _ title: String) {
        let key = Address.pretty(url).lowercased()
        guard !title.isEmpty, var seen = visits[key], seen.title != title else { return }
        seen.title = title
        visits[key] = seen
        save()
    }

    func forget() {
        visits = [:]
        save()
    }

    /// Everywhere you have been, newest first, for the window that shows it.
    struct Trace: Identifiable, Equatable {
        let key: String
        let title: String
        let url: URL
        let last: Date
        let count: Int

        var id: String { key }
    }

    func everything(matching typed: String = "") -> [Trace] {
        let needle = typed.trimmingCharacters(in: .whitespaces).lowercased()
        return visits.values
            // Every visit to a page also credits its domain, so the address
            // field can offer the front door. Those credits have no title of
            // their own, and in a list of where you have been they are a second
            // copy of every line.
            .filter { !($0.title.isEmpty && !$0.key.contains("/")) }
            .filter {
                needle.isEmpty
                    || $0.key.contains(needle)
                    || $0.title.lowercased().contains(needle)
            }
            .sorted { $0.last > $1.last }
            .compactMap { visit in
                URL(string: visit.url).map {
                    Trace(
                        key: visit.key,
                        title: visit.title,
                        url: $0,
                        last: visit.last,
                        count: visit.count
                    )
                }
            }
    }

    func forget(_ key: String) {
        visits[key] = nil
        save()
    }

    /// The last eight places, newest first; worked out again only once the
    /// history has changed.
    func recent() -> [Trace] {
        if let recentCache { return recentCache }
        let made = Array(everything().prefix(8))
        recentCache = made
        return made
    }

    // MARK: - reading

    /// Best matches first. A place you have been always beats a place the app
    /// merely knows the name of, and among places you have been, one you go to
    /// often and recently beats one you saw once in March.
    func suggestions(for typed: String, limit: Int = 5) -> [Suggestion] {
        let needle = strip(typed)
        // An empty field proposes nothing. A list of guesses in front of
        // someone who has not yet said what they want is noise, and it is in
        // the way of the one thing they came here to do.
        guard !needle.isEmpty else { return [] }

        let now = Date()
        var scored: [(Suggestion, Double)] = []

        for visit in visits.values {
            guard let rank = rank(visit.key, against: needle) else { continue }
            guard let url = URL(string: visit.url) else { continue }
            scored.append((
                Suggestion(key: visit.key, title: visit.title, url: url, kind: .visited),
                // The front door before the room inside it: a bare domain is
                // what a bare domain typed into a field means.
                rank + 4 + frecency(visit, now: now) + (visit.key.contains("/") ? 0 : 1.5)
            ))
        }

        // Only where memory has nothing to offer. A list of famous websites is
        // a poor substitute for knowing where someone actually goes.
        for known in History.known where visits[known.0] == nil {
            guard let rank = rank(known.0, against: needle) else { continue }
            guard let url = URL(string: "https://" + known.0) else { continue }
            scored.append((
                Suggestion(key: known.0, title: known.1, url: url, kind: .known),
                rank
            ))
        }

        return scored
            .sorted { $0.1 == $1.1 ? $0.0.key.count < $1.0.key.count : $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
    }

    /// What the field should draw greyed out after the caret: the rest of the
    /// best match, or nothing if it doesn't carry on from what was typed.
    func completion(for typed: String, among options: [Suggestion]) -> String? {
        let lower = typed.lowercased()
        guard !lower.isEmpty, lower.count >= 2 else { return nil }
        guard let hit = options.first(where: { $0.key.hasPrefix(lower) }) else { return nil }
        let rest = String(hit.key.dropFirst(lower.count))
        return rest.isEmpty ? nil : rest
    }

    /// Frecency, plus the same preference for a front door over a room inside
    /// it that the search uses.
    private func standing(_ visit: Visit, now: Date) -> Double {
        frecency(visit, now: now) + (visit.key.contains("/") ? 0 : 1.5)
    }

    /// Where the match falls decides most of the ordering: the start of the
    /// host is what people mean, the middle of a path almost never is.
    private func rank(_ key: String, against needle: String) -> Double? {
        if key.hasPrefix(needle) { return 6 }
        // Read in place: this runs for every place in the history on every
        // key, and splitting each key into new strings was most of its cost.
        let host = key[..<(key.firstIndex(of: "/") ?? key.endIndex)]
        // "hub" finding github.com, once the "git" has been skipped.
        if let dot = host.firstIndex(of: "."), host[host.index(after: dot)...].hasPrefix(needle) { return 3 }
        // Only from two letters up. A single letter matching anywhere inside
        // a name turns "x" into example.com and netflix.com, which is not what
        // anybody meant by it.
        if needle.count >= 2, host.contains(needle) { return 2 }
        // Deliberately no match on the path. "blog" turning up six articles
        // from three sites is not an answer to anything.
        return nil
    }

    /// Often, and lately. A month-old visit counts for about a third of a
    /// fresh one, which is roughly how long a habit takes to stop being one.
    private func frecency(_ visit: Visit, now: Date) -> Double {
        let days = max(0, now.timeIntervalSince(visit.last) / 86_400)
        return Double(visit.count) * exp(-days / 30)
    }

    private func strip(_ typed: String) -> String {
        var text = typed.trimmingCharacters(in: .whitespaces).lowercased()
        for scheme in ["https://", "http://"] where text.hasPrefix(scheme) {
            text = String(text.dropFirst(scheme.count))
        }
        if text.hasPrefix("www.") { text = String(text.dropFirst(4)) }
        return text
    }

    // MARK: - the file

    private static var folder: URL { Store.folder }
    private static var file: URL { Store.file("history.json") }

    private func load() {
        guard let data = try? Data(contentsOf: History.file) else { return }
        guard let list = try? JSONDecoder().decode([Visit].self, from: data) else {
            Store.quarantine(History.file)
            return
        }
        visits = Dictionary(uniqueKeysWithValues: list.map { ($0.key, $0) })
    }

    /// Coalesced: a busy minute of browsing writes the file once, not thirty
    /// times, and never on the main thread.
    private func save() {
        guard !saving else { return }
        saving = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            saving = false
            let now = Date()
            // A cap, so the file can't grow without end. What goes is what has
            // been visited least and longest ago.
            let list = self.visits.values
                .sorted { self.frecency($0, now: now) > self.frecency($1, now: now) }
                .prefix(2_000)
                .map { $0 }
            DispatchQueue.global(qos: .utility).async {
                guard let data = try? JSONEncoder().encode(list) else { return }
                try? FileManager.default.createDirectory(
                    at: History.folder, withIntermediateDirectories: true
                )
                try? data.write(to: History.file, options: .atomic)
            }
        }
    }

    /// Somewhere to start on the first day, before there is any history to go
    /// on. Ranked below anything actually visited, and dropped from the list
    /// the moment you have been there yourself.
    private static let known: [(String, String)] = [
        ("google.com", "Google"), ("mail.google.com", "Gmail"),
        ("drive.google.com", "Google Drive"), ("calendar.google.com", "Google Calendar"),
        ("maps.google.com", "Google Maps"), ("youtube.com", "YouTube"),
        ("github.com", "GitHub"), ("figma.com", "Figma"), ("vercel.com", "Vercel"),
        ("notion.so", "Notion"), ("linear.app", "Linear"), ("slack.com", "Slack"),
        ("discord.com", "Discord"), ("x.com", "X"), ("linkedin.com", "LinkedIn"),
        ("instagram.com", "Instagram"), ("reddit.com", "Reddit"),
        ("news.ycombinator.com", "Hacker News"), ("stackoverflow.com", "Stack Overflow"),
        ("claude.ai", "Claude"), ("chatgpt.com", "ChatGPT"),
        ("dribbble.com", "Dribbble"), ("behance.net", "Behance"),
        ("awwwards.com", "Awwwards"), ("mobbin.com", "Mobbin"),
        ("siteinspire.com", "SiteInspire"), ("are.na", "Are.na"),
        ("pinterest.com", "Pinterest"), ("framer.com", "Framer"),
        ("webflow.com", "Webflow"), ("developer.apple.com", "Apple Developer"),
        ("swift.org", "Swift"), ("npmjs.com", "npm"), ("supabase.com", "Supabase"),
        ("stripe.com", "Stripe"), ("shopify.com", "Shopify"),
        ("cloudflare.com", "Cloudflare"), ("netlify.com", "Netlify"),
        ("apple.com", "Apple"), ("spotify.com", "Spotify"), ("netflix.com", "Netflix"),
        ("wikipedia.org", "Wikipedia"), ("deepl.com", "DeepL"), ("loom.com", "Loom"),
        ("amazon.fr", "Amazon"), ("leboncoin.fr", "leboncoin"), ("lemonde.fr", "Le Monde"),
    ]
}
