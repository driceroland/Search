import Foundation

// Where you have been, so the field can finish the address for you. Kept in one
// small file next to the app's own settings, written a moment after a visit
// rather than on every keystroke.

struct Suggestion: Identifiable, Equatable {
    /// What you could type to get here, kept reversible for completion.
    let key: String
    let title: String
    let url: URL
    let kind: Kind
    /// Set when this is a page you already have open somewhere.
    var tab: UUID?

    enum Kind: Equatable {
        /// A page that is open right now.
        case open
        /// Somewhere you have actually been.
        case visited
        /// One of the well-known addresses the field knows from the start.
        case known
        /// Not a place at all — words, and an engine to ask.
        case search
        /// Not a place either: something the app itself does.
        case command(AddressCommand)

        var isCommand: Bool { if case .command = self { return true }; return false }
    }

    /// A command's row can read the same as the search for the same word
    /// ("Settings" typed with its capital), and two rows can't share a name.
    var id: String {
        if kind.isCommand { return "command " + key }
        if case .visited = kind { return History.identity(for: url) }
        return key
    }

    /// A command goes nowhere, but the field still needs *a* URL to carry;
    /// `take` and `submit` read the kind first and never follow this one.
    @MainActor
    static func command(_ command: AddressCommand) -> Suggestion {
        Suggestion(key: command.title, title: "", url: URL(string: "about:blank")!, kind: .command(command))
    }
}

private struct Visit: Codable {
    var url: String
    var key: String
    var title: String
    var count: Int
    var last: Date
}

private struct PageText {
    let address: String
    let searchable: String
    let host: String
    let homepage: Bool
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
    /// These are derived once when a visit enters memory. Suggestions run on
    /// every keystroke, so neither URL parsing nor address formatting belongs
    /// in that loop.
    private var pageText: [String: PageText] = [:]
    private var visitedHosts: Set<String> = []

    init() { load() }

    /// URL identity ignores fragments, normalizes only the scheme and host,
    /// and keeps the spelling and encoding of the path and query intact.
    nonisolated static func identity(for url: URL) -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        parts.scheme = parts.scheme?.lowercased()
        parts.host = parts.host?.lowercased()
        parts.fragment = nil
        // An absent path and a lone slash have always meant the same home page.
        if parts.percentEncodedPath.isEmpty { parts.percentEncodedPath = "/" }
        return parts.string ?? url.absoluteString
    }

    private static func isWeb(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "")
    }

    private static func pageText(for url: URL) -> PageText {
        var shownURL = url
        if var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            parts.fragment = nil
            shownURL = parts.url ?? url
        }
        let address = Address.editable(shownURL)
        let searchable = stripped(address)
        let host = (shownURL.host()?.lowercased() ?? "")
        let bareHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let path = shownURL.path()
        return PageText(
            address: address,
            searchable: searchable,
            host: bareHost,
            homepage: path.isEmpty || path == "/"
        )
    }

    private static func stripped(_ address: String) -> String {
        var text = address.trimmingCharacters(in: .whitespaces).lowercased()
        for scheme in ["https://", "http://"] where text.hasPrefix(scheme) {
            text = String(text.dropFirst(scheme.count))
        }
        if text.hasPrefix("www.") { text = String(text.dropFirst(4)) }
        return text
    }

    private func remember(_ visit: Visit, url: URL? = nil) {
        guard let page = url ?? URL(string: visit.url) else { return }
        let text = History.pageText(for: page)
        pageText[visit.key] = text
        if !text.host.isEmpty { visitedHosts.insert(text.host) }
    }

    private func forgetText(for key: String) {
        let host = pageText.removeValue(forKey: key)?.host
        guard let host, !host.isEmpty,
              !pageText.values.contains(where: { $0.host == host })
        else { return }
        visitedHosts.remove(host)
    }

    private static func homepage(of url: URL) -> URL? {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        parts.user = nil
        parts.password = nil
        parts.percentEncodedPath = "/"
        parts.percentEncodedQuery = nil
        parts.fragment = nil
        return parts.url
    }

    // MARK: - writing

    func record(_ url: URL, title: String) {
        guard History.isWeb(url) else { return }
        let key = History.identity(for: url)
        guard !key.isEmpty else { return }
        let text = History.pageText(for: url)

        // Reading a deep page is also, in the way that matters here, another
        // visit to the site. Without this, typing three letters offers the
        // article you happened to open last week rather than the front page —
        // and nobody types a domain meaning to land halfway down it.
        if !text.homepage, let homeURL = History.homepage(of: url) {
            let root = History.identity(for: homeURL)
            var home = visits[root] ?? Visit(
                url: homeURL.absoluteString, key: root, title: "", count: 0, last: Date()
            )
            home.count += 1
            home.last = Date()
            visits[root] = home
            remember(home, url: homeURL)
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
        if let seen = visits[key] { remember(seen, url: url) }
        save()
    }

    /// Somewhere another browser has been. Counted as it was counted there,
    /// so a site visited daily for a year outranks one seen once — the day
    /// you switch, the field already knows you.
    func take(_ url: URL, title: String, count: Int, last: Date) {
        guard History.isWeb(url) else { return }
        let key = History.identity(for: url)
        guard !key.isEmpty else { return }
        if var seen = visits[key] {
            // The larger of the two, not their sum: the same browser brought
            // in again must not count every visit twice.
            seen.count = max(seen.count, count)
            if last > seen.last { seen.last = last }
            if seen.title.isEmpty { seen.title = title }
            visits[key] = seen
        } else {
            let visit = Visit(url: url.absoluteString, key: key, title: title, count: count, last: last)
            visits[key] = visit
            remember(visit, url: url)
        }
    }

    /// After a batch of `take`s.
    func settle() { save() }

    /// A page's title usually lands a beat after the page does.
    func retitle(_ url: URL, _ title: String) {
        let key = History.identity(for: url)
        guard !title.isEmpty, var seen = visits[key], seen.title != title else { return }
        seen.title = title
        visits[key] = seen
        save()
    }

    func forget() {
        visits = [:]
        pageText = [:]
        visitedHosts = []
        save()
    }

    /// Everywhere you have been, newest first, for the window that shows it.
    struct Trace: Identifiable, Equatable {
        let key: String
        /// A reversible address for display; `key` is the stable URL identity.
        let address: String
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
            .filter { visit in
                !(visit.title.isEmpty && pageText[visit.key]?.homepage == true)
            }
            .filter {
                needle.isEmpty
                    || pageText[$0.key]?.searchable.contains(needle) == true
                    || $0.title.lowercased().contains(needle)
            }
            .sorted { $0.last > $1.last }
            .compactMap { visit in
                URL(string: visit.url).map {
                    Trace(
                        key: visit.key,
                        address: pageText[visit.key]?.address ?? visit.key,
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
        forgetText(for: key)
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

        let bytes = Array(needle.utf8)
        let ascii = bytes.allSatisfy { $0 >= 0x20 && $0 < 0x7F } ? bytes : nil
        let now = Date()
        // Only the best few are kept while scanning, in order, and only those
        // become suggestions. Making one for every match in a big history,
        // only to sort them all and keep five, was work thrown away each key.
        var best: [(Suggestion, Double)] = []
        // Higher first, then the shorter key, then whichever came first: the
        // order a stable sort of every match would have left them in.
        func ahead(_ score: Double, _ key: String, of other: (Suggestion, Double)) -> Bool {
            score == other.1 ? key.count < other.0.key.count : score > other.1
        }
        func offer(_ key: String, _ score: Double, _ make: () -> Suggestion?) {
            if best.count == limit, let last = best.last, !ahead(score, key, of: last) { return }
            guard let made = make() else { return }
            best.insert((made, score), at: best.firstIndex { ahead(score, key, of: $0) } ?? best.endIndex)
            if best.count > limit { best.removeLast() }
        }

        for visit in visits.values {
            guard let text = pageText[visit.key],
                  let rank = rank(text.searchable, against: needle, ascii: ascii)
            else { continue }
            // The front door before the room inside it: a bare domain is
            // what a bare domain typed into a field means.
            let score = rank + 4 + frecency(visit, now: now) + (text.homepage ? 1.5 : 0)
            offer(text.address, score) {
                URL(string: visit.url).map { Suggestion(key: text.address, title: visit.title, url: $0, kind: .visited) }
            }
        }

        // Only where memory has nothing to offer. A list of famous websites is
        // a poor substitute for knowing where someone actually goes.
        for known in History.known where !visitedHosts.contains(known.0) {
            guard let rank = rank(known.0, against: needle, ascii: ascii) else { continue }
            offer(known.0, rank) {
                URL(string: "https://" + known.0).map { Suggestion(key: known.0, title: known.1, url: $0, kind: .known) }
            }
        }

        return best.map(\.0)
    }

    /// What the field should draw greyed out after the caret: the rest of the
    /// best match, or nothing if it doesn't carry on from what was typed.
    func completion(for typed: String, among options: [Suggestion]) -> String? {
        guard !typed.isEmpty, typed.count >= 2 else { return nil }
        for option in options {
            guard option.key.count >= typed.count else { continue }
            let prefix = String(option.key.prefix(typed.count))
            guard prefix.caseInsensitiveCompare(typed) == .orderedSame else { continue }
            let rest = String(option.key.dropFirst(typed.count))
            guard let completed = Address.url(from: typed + rest),
                  History.identity(for: completed) == History.identity(for: option.url)
            else { continue }
            return rest.isEmpty ? nil : rest
        }
        return nil
    }

    /// Frecency, plus the same preference for a front door over a room inside
    /// it that the search uses.
    private func standing(_ visit: Visit, now: Date) -> Double {
        frecency(visit, now: now) + (pageText[visit.key]?.homepage == true ? 1.5 : 0)
    }

    /// Where the match falls decides most of the ordering: the start of the
    /// host is what people mean, the middle of a path almost never is.
    private func rank(_ key: String, against needle: String, ascii: [UInt8]?) -> Double? {
        // Plain addresses can be read as bytes. Check the whole key: even a
        // mark attached to a slash can change where a Character ends. A nil
        // score asks the original matcher below; zero means no ASCII match.
        if let ascii,
           let score = key.utf8.withContiguousStorageIfAvailable({ bytes -> Double? in
               guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return nil }
               if bytes.starts(with: ascii) { return 6 }
               let hostEnd = bytes.firstIndex(where: { $0 == 0x2F || $0 == 0x3F || $0 == 0x23 }) ?? bytes.endIndex
               let host = bytes[..<hostEnd]
               if let dot = host.firstIndex(of: 0x2E), host[(dot + 1)...].starts(with: ascii) { return 3 }
               if ascii.count >= 2, ascii.count <= host.count {
                   for start in 0...(host.count - ascii.count) {
                       if host[start...].starts(with: ascii) { return 2 }
                   }
               }
               return 0
           }), let score {
            return score == 0 ? nil : score
        }
        if key.hasPrefix(needle) { return 6 }
        // Read in place: this runs for every place in the history on every
        // key, and splitting each key into new strings was most of its cost.
        let hostEnd = key.firstIndex(where: { "/?#".contains($0) }) ?? key.endIndex
        let host = key[..<hostEnd]
        // "google" finding mail.google.com without the subdomain.
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

    private func strip(_ typed: String) -> String { History.stripped(typed) }

    // MARK: - the file

    private static var folder: URL { Store.folder }
    private static var file: URL { Store.file("history.json") }

    private func load() {
        guard let data = try? Data(contentsOf: History.file) else { return }
        guard let list = try? JSONDecoder().decode([Visit].self, from: data) else {
            Store.quarantine(History.file)
            return
        }
        // Keys written by an older Search can meet under the new rule:
        // they are merged, never trusted to be unique.
        visits = Dictionary(list.map { saved in
            var visit = saved
            if let url = URL(string: visit.url) { visit.key = History.identity(for: url) }
            return (visit.key, visit)
        }, uniquingKeysWith: { a, b in
            var kept = a.last >= b.last ? a : b
            kept.count = a.count + b.count
            return kept
        })
        for visit in visits.values { remember(visit) }
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
