import AppKit

// Live folders, as Arc's: a pin folder filled from a web feed — a blog's
// RSS, a GitHub repository's releases.atom or commits.atom — rather than by
// hand. It holds the feed's latest posts, each a line that opens its page in
// a new tab as a bookmark would; never a pin, never carried in or out.
//
// Only where pin folders are (Settings › Spaces & Pins › Folders in pinned
// rows, with Pinned rows): with the switch off nothing is fetched.
//
// Fetched when made, a little after launch, every half hour while Search
// runs, and on Refresh in the folder's menu. Each fetch is a plain request
// on a session of its own that keeps nothing: no cookies sent or taken, no
// sign-in of any space, no cache, and it gives up past a timeout or 2 MB.
// One that fails keeps the posts the folder had; its heading says so in its
// tooltip and nothing else.
//
// The feed's address and its posts are kept with the folder in
// pin-folders.json (PinFolder.feed, .items).

@MainActor
enum LiveFolders {
    /// Arc keeps a live folder short; a column 260 points wide wants it so.
    nonisolated static let most = 12
    static let every: TimeInterval = 30 * 60
    /// Folders whose last fetch failed: their tooltip says so.
    private(set) static var failed: Set<UUID> = []
    /// Folders being fetched now: a second Refresh waits for the first.
    private static var fetching: Set<UUID> = []
    private static var timer: Timer?

    /// At launch: a first fetch once the windows are up, then every half
    /// hour.
    static func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: every, repeats: true) { _ in
            MainActor.assumeIsolated { refreshAll() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { refreshAll() }
    }

    /// Every live folder of every space, while the switch is on.
    static func refreshAll() {
        guard Shared.prefs.showsPinFolders else { return }
        PinFolders.load()
        for (space, folders) in PinFolders.bySpace {
            for folder in folders where folder.isLive { refresh(folder.id, in: space) }
        }
    }

    static func isFetching(_ id: UUID) -> Bool { fetching.contains(id) }

    static func refresh(_ id: UUID, in space: UUID) {
        guard let feed = PinFolders.folders(space).first(where: { $0.id == id })?.feed,
              fetching.insert(id).inserted else { return }
        Task {
            let result = await Feed.load(feed)
            fetching.remove(id)
            // The folder as it is now, renamed or moved meanwhile: only its
            // posts change.
            var folders = PinFolders.folders(space)
            guard let index = folders.firstIndex(where: { $0.id == id }) else { return }
            switch result {
            case .success(let read):
                failed.remove(id)
                folders[index].items = Feed.keepingIDs(read.items, from: folders[index].items ?? [])
            case .failure:
                failed.insert(id)
            }
            PinFolders.set(space, folders, from: nil, always: true)
        }
    }

    /// New Live Folder: the address asked for, a feed found there, and a
    /// folder made with its name and posts. Nothing is made for an address
    /// with no feed; it says so.
    static func ask(for browser: Browser, in parent: UUID?) {
        Ask.name("New Live Folder",
                 detail: "A feed’s address, or a site’s that has one. Its latest posts fill the folder, kept fresh every half hour.",
                 placeholder: "https://example.com/feed.xml", confirm: "Add") { text in
            guard let url = Feed.address(text) else {
                Ask.tell("That isn’t a web address", detail: "A feed’s address starts with https:// or http://.")
                return
            }
            Task {
                switch await Feed.load(url) {
                case .success(let read):
                    browser.newLiveFolder(read, in: parent)
                case .failure(let problem):
                    Ask.tell("No feed found", detail: problem.said(url))
                }
            }
        }
    }

    /// A folder deleted: nothing more to say about it.
    static func forget(_ id: UUID) {
        failed.remove(id)
    }
}

extension Browser {
    /// A live folder made from a feed read, inside `parent` if one may be
    /// made there, else at the top.
    @discardableResult
    func newLiveFolder(_ read: Feed.Read, in parent: UUID? = nil) -> UUID {
        var folders = pinFolders
        let parent = PinTree.canMake(in: parent, in: folders) ? parent : nil
        let made = PinFolder(id: UUID(), name: String(read.title.prefix(200)), parent: parent,
                             feed: read.feed, items: read.items)
        folders.append(made)
        objectWillChange.send()
        PinFolders.set(spaceID, folders, from: self)
        return made.id
    }

    /// A post picked: its page in a new tab in front, as a bookmark opened
    /// in a new tab. The folder's line stays a line, not a pin. It came
    /// from no page, so it goes among the tabs as ⌘T's does (`loose`):
    /// with a grouped tab in front it went into that group (idea 978).
    func openFeedItem(_ item: FeedItem) {
        open(item.link, foreground: true, from: active, loose: true)
    }
}

/// A feed fetched and read. Pure but for `load`, so the tests can hold it.
enum Feed {
    /// What a feed said: its name, its address (the one found, when a page's
    /// was given), and its latest posts, at most LiveFolders.most.
    struct Read: Equatable {
        var title: String
        var feed: URL
        var items: [FeedItem]
    }

    enum Problem: Error, Equatable {
        case network, tooBig, notAFeed

        func said(_ url: URL) -> String {
            switch self {
            case .network: "\(url.host() ?? url.absoluteString) couldn’t be reached."
            case .tooBig: "What \(url.host() ?? url.absoluteString) sent is too large to be a feed."
            case .notAFeed: "There’s no RSS or Atom feed at \(url.absoluteString), nor one that page points to."
            }
        }
    }

    static let maxBytes = 2_000_000

    /// What was typed, as an address: a bare `example.com/feed` is https.
    static func address(_ text: String) -> URL? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(" ") else { return nil }
        let full = text.contains("://") ? text : "https://" + text
        guard let url = URL(string: full), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", url.host()?.isEmpty == false else { return nil }
        return url
    }

    /// A session of its own that keeps nothing and sends no sign-in.
    private static var session: URLSession {
        ProxyNetwork.kept("live-folders") {
            let config = URLSessionConfiguration.ephemeral
            config.httpCookieStorage = nil
            config.httpShouldSetCookies = false
            config.httpCookieAcceptPolicy = .never
            config.urlCredentialStorage = nil
            config.urlCache = nil
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            config.timeoutIntervalForRequest = 15
            config.timeoutIntervalForResource = 30
            config.httpAdditionalHeaders = [
                "Accept": "application/rss+xml, application/atom+xml, application/xml;q=0.9, text/xml;q=0.9, text/html;q=0.5, */*;q=0.1",
            ]
            ProxyNetwork.stamp(config)
            return URLSession(configuration: config)
        }
    }

    /// The feed at `url`, or, for a page, the feed the page points to.
    static func load(_ url: URL) async -> Result<Read, Problem> {
        switch await fetch(url) {
        case .failure(let problem): return .failure(problem)
        case .success(let data):
            if let read = parse(data, url: url) { return .success(read) }
            guard let found = discover(data, page: url), found != url else { return .failure(.notAFeed) }
            switch await fetch(found) {
            case .failure(let problem): return .failure(problem)
            case .success(let data): return parse(data, url: found).map { .success($0) } ?? .failure(.notAFeed)
            }
        }
    }

    private static func fetch(_ url: URL) async -> Result<Data, Problem> {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return .failure(.notAFeed) }
        do {
            let (bytes, response) = try await session.bytes(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return .failure(.network) }
            if response.expectedContentLength > maxBytes { return .failure(.tooBig) }
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > maxBytes { return .failure(.tooBig) }
            }
            return .success(data)
        } catch {
            return .failure(.network)
        }
    }

    /// A refetch's posts wearing the ids they already had, by link, so the
    /// column doesn't draw the same post anew and an unchanged feed changes
    /// nothing on disk.
    static func keepingIDs(_ fresh: [FeedItem], from old: [FeedItem]) -> [FeedItem] {
        let ids = Dictionary(old.map { ($0.link, $0.id) }, uniquingKeysWith: { a, _ in a })
        return fresh.map { item in
            var item = item
            if let id = ids[item.link] { item.id = id }
            return item
        }
    }

    // MARK: - reading

    /// RSS 2.0 (and 1.0) or Atom; nil for anything else, a web page among
    /// them. A feed that breaks off part way keeps the posts read before.
    static func parse(_ data: Data, url: URL) -> Read? {
        let reader = FeedReader(base: url)
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        parser.parse()
        guard reader.isFeed else { return nil }
        var seen = Set<URL>()
        let items = reader.items.filter { seen.insert($0.link).inserted }.prefix(LiveFolders.most)
        let title = clean(reader.title ?? "", html: false)
        return Read(title: title.isEmpty ? (url.host() ?? "Live Folder") : title, feed: url, items: Array(items))
    }

    /// A page's own feed: the first `<link rel="alternate">` of an RSS or
    /// Atom type in it, against the page's address.
    static func discover(_ data: Data, page: URL) -> URL? {
        guard let html = String(data: data.prefix(maxBytes), encoding: .utf8)
                ?? String(data: data.prefix(maxBytes), encoding: .isoLatin1) else { return nil }
        let tags = html.matches(of: #/<link\b[^>]*>/#.ignoresCase())
        for tag in tags {
            let attributes = Self.attributes(String(tag.output))
            let rel = (attributes["rel"] ?? "").lowercased().split(separator: " ")
            let type = (attributes["type"] ?? "").lowercased()
            guard rel.contains("alternate"), type == "application/rss+xml" || type == "application/atom+xml",
                  let href = attributes["href"].map({ decode($0) }),
                  let url = URL(string: href.trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: page)?.absoluteURL,
                  let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http"
            else { continue }
            return url
        }
        return nil
    }

    /// A tag's attributes, names lowercased, quoted either way or not.
    private static func attributes(_ tag: String) -> [String: String] {
        var out: [String: String] = [:]
        for match in tag.matches(of: #/([A-Za-z_:][-A-Za-z0-9_:.]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))/#) {
            let value = match.output.2 ?? match.output.3 ?? match.output.4 ?? ""
            out[String(match.output.1).lowercased()] = String(value)
        }
        return out
    }

    /// A title as a line: tags taken out of one sent as HTML, entities a
    /// feed escaped twice read, and the spaces made one.
    static func clean(_ text: String, html: Bool) -> String {
        var text = text
        if html { text = text.replacing(#/<[^>]*>/#, with: "") }
        text = decode(text)
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The entities a title carries most: &amp; and friends, and numbers.
    static func decode(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let named = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
                     "#39": "'", "hellip": "…", "mdash": "—", "ndash": "–", "rsquo": "’", "lsquo": "‘",
                     "rdquo": "”", "ldquo": "“"]
        return text.replacing(#/&(#[xX][0-9A-Fa-f]{1,6}|#[0-9]{1,7}|[A-Za-z]{2,8});/#) { match in
            let name = String(match.output.1)
            if let known = named[name] ?? named[name.lowercased()] { return known }
            let number: UInt32?
            if name.hasPrefix("#x") || name.hasPrefix("#X") { number = UInt32(name.dropFirst(2), radix: 16) }
            else if name.hasPrefix("#") { number = UInt32(name.dropFirst()) }
            else { number = nil }
            return number.flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? String(match.output.0)
        }
    }
}

/// XMLParser's delegate for RSS and Atom: the feed's title, and each post's
/// title and link. Text is taken from the title, link and guid directly in a
/// channel, feed, item or entry, so a post's source or media title is not.
private final class FeedReader: NSObject, XMLParserDelegate {
    let base: URL
    var isFeed = false
    var title: String?
    var items: [FeedItem] = []

    private var path: [String] = []
    private var inPost = false
    private var postTitle: String?
    private var postHTML = false
    private var postLink: String?
    private var postGuid: String?
    private var guidIsLink = true
    /// The element whose text is being gathered, and how deep it started.
    private var gathering: (name: String, depth: Int)?
    private var text = ""
    private var titleHTML = false

    init(base: URL) { self.base = base }

    private static func local(_ name: String) -> String {
        name.split(separator: ":").last.map(String.init)?.lowercased() ?? name.lowercased()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        let name = Self.local(elementName)
        let parent = path.last
        path.append(name)
        if path.count == 1 { isFeed = ["rss", "feed", "rdf"].contains(name) }
        guard isFeed, gathering == nil else { return }
        switch name {
        case "item", "entry":
            inPost = true
            postTitle = nil; postLink = nil; postGuid = nil; postHTML = false; guidIsLink = true
        case "title" where parent == "item" || parent == "entry" || parent == "channel" || parent == "feed":
            gathering = (name, path.count)
            text = ""
            titleHTML = ["html", "xhtml"].contains(attributes["type"]?.lowercased() ?? "")
        case "link" where inPost && (parent == "item" || parent == "entry"):
            if let href = attributes["href"] {
                // Atom: the page is the alternate link, or one with no rel.
                let rel = attributes["rel"]?.lowercased() ?? "alternate"
                if rel == "alternate", postLink == nil { postLink = href }
            } else {
                gathering = (name, path.count)
                text = ""
            }
        case "guid" where inPost && parent == "item":
            guidIsLink = attributes["isPermaLink"]?.lowercased() != "false"
            gathering = (name, path.count)
            text = ""
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if gathering != nil { text += string }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if gathering != nil, let string = String(data: CDATABlock, encoding: .utf8) { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        let name = Self.local(elementName)
        defer { path.removeLast() }
        if let gathering, gathering.depth == path.count, gathering.name == name {
            self.gathering = nil
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch name {
            case "title":
                if inPost { postTitle = value; postHTML = titleHTML } else if title == nil { title = value }
            case "link": if postLink == nil, !value.isEmpty { postLink = value }
            case "guid": postGuid = value
            default: break
            }
            return
        }
        guard (name == "item" || name == "entry"), inPost else { return }
        inPost = false
        let raw = postLink ?? (guidIsLink ? postGuid : nil)
        guard let raw, let link = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: base)?.absoluteURL,
              let scheme = link.scheme?.lowercased(), scheme == "https" || scheme == "http"
        else { return }
        var said = Feed.clean(postTitle ?? "", html: postHTML)
        // No title: where it goes, as a bookmark with none reads.
        if said.isEmpty { said = (link.host() ?? "") + (link.path() == "/" ? "" : link.path()) }
        items.append(FeedItem(id: UUID(), title: String(said.prefix(300)), link: link))
        // Enough, with room for repeats: the rest of a long feed goes unread.
        if items.count >= LiveFolders.most * 2 { parser.abortParsing() }
    }
}
