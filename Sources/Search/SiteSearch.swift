import Foundation

// Search a site from the address field, as in Arc (Settings › General):
// type the start of a site's name — "red", "yout", "chat" — and the list
// offers "Search Reddit"; Tab puts the site in the field as a small chip,
// and what is typed after it goes to that site's search. A short list of
// popular sites comes built in; a site you have been to that says where its
// search is (OpenSearch, as Chrome reads it) joins it by itself. Your own
// words ("yt cats", Settings › General › Site shortcuts) go on working
// as before, whether this is on or off.

struct SearchSite: Codable, Identifiable, Equatable {
    var id: String { host }
    let name: String
    /// The site, without its www.
    let host: String
    /// Where the words go: http or https, %s once (see Keyword.accepts).
    let template: String
    /// Other beginnings that name it: "yt" for YouTube, "so" for Stack Overflow.
    var aliases: [String] = []

    func url(for words: String) -> URL? { Engine.url(for: words, template: template) }
}

@MainActor
enum SiteSearch {
    /// Checked by hand on 28 Sep 2026, each opened with a word to find: the
    /// search comes back, or the site's sign-in or consent page does and
    /// goes on to it after (X, Claude, Google Maps).
    static var builtIn: [SearchSite] {
        [
            SearchSite(name: "Reddit", host: "reddit.com", template: "https://www.reddit.com/search/?q=%s"),
            SearchSite(name: "YouTube", host: "youtube.com", template: "https://www.youtube.com/results?search_query=%s", aliases: ["yt"]),
            SearchSite(name: "X", host: "x.com", template: "https://x.com/search?q=%s", aliases: ["twitter"]),
            SearchSite(name: "ChatGPT", host: "chatgpt.com", template: "https://chatgpt.com/?q=%s", aliases: ["gpt", "openai"]),
            SearchSite(name: "Claude", host: "claude.ai", template: "https://claude.ai/new?q=%s"),
            SearchSite(name: "Perplexity", host: "perplexity.ai", template: "https://www.perplexity.ai/search?q=%s"),
            SearchSite(name: "Wikipedia", host: "wikipedia.org",
                       template: "https://\(language).wikipedia.org/w/index.php?search=%s", aliases: ["wiki"]),
            SearchSite(name: "GitHub", host: "github.com", template: "https://github.com/search?q=%s", aliases: ["gh"]),
            SearchSite(name: "Stack Overflow", host: "stackoverflow.com", template: "https://stackoverflow.com/search?q=%s", aliases: ["so"]),
            SearchSite(name: "MDN", host: "developer.mozilla.org", template: "https://developer.mozilla.org/search?q=%s"),
            SearchSite(name: "Amazon", host: amazon, template: "https://www.\(amazon)/s?k=%s"),
            SearchSite(name: "Google Maps", host: "google.com/maps", template: "https://www.google.com/maps/search/%s", aliases: ["maps"]),
            SearchSite(name: "IMDb", host: "imdb.com", template: "https://www.imdb.com/find/?q=%s"),
            SearchSite(name: "Spotify", host: "open.spotify.com", template: "https://open.spotify.com/search/%s"),
            SearchSite(name: "Figma Community", host: "figma.com/community",
                       template: "https://www.figma.com/community/search?resource_type=mixed&sort_by=relevancy&query=%s"),
        ]
    }

    /// Wikipedia in the Mac's first language.
    private static var language: String {
        let code = Locale.preferredLanguages.first.map { Locale(identifier: $0).language.languageCode?.identifier ?? "en" } ?? "en"
        return code.allSatisfy(\.isLetter) && code.count <= 3 ? code : "en"
    }

    /// Amazon's own shop for the Mac's region.
    private static var amazon: String {
        switch Locale.current.region?.identifier {
        case "FR": "amazon.fr"
        case "DE", "AT": "amazon.de"
        case "GB", "IE": "amazon.co.uk"
        case "IT": "amazon.it"
        case "ES": "amazon.es"
        case "NL": "amazon.nl"
        case "BE": "amazon.com.be"
        case "JP": "amazon.co.jp"
        case "CA": "amazon.ca"
        case "AU": "amazon.com.au"
        case "IN": "amazon.in"
        case "BR": "amazon.com.br"
        case "MX": "amazon.com.mx"
        default: "amazon.com"
        }
    }

    /// The site the words typed so far begin the name of, if any, two
    /// letters at least, nothing after a space. A built-in one by the start
    /// of its name, its address or one of its other names; a learned one by
    /// the start of its address only — never by the name it gives itself,
    /// which could be anyone's ("Google", a bank's). Among them the one whose
    /// name is the shortest.
    /// `learnedToo`: the sites learned from visits are Personal's (see
    /// Profiles.swift); another profile's window is offered the built-in
    /// ones only, so no profile's field says where another has been.
    static func match(_ typed: String, learnedToo: Bool = true) -> SearchSite? {
        let word = typed.trimmingCharacters(in: .whitespaces).lowercased()
        guard word.count >= 2, !word.contains(" "), !word.contains("/") else { return nil }
        func names(_ site: SearchSite) -> [String] {
            let host = site.host.hasPrefix("www.") ? String(site.host.dropFirst(4)) : site.host
            return [site.name.lowercased().replacingOccurrences(of: " ", with: ""), host] + site.aliases
        }
        let found = builtIn.filter { site in names(site).contains { $0.hasPrefix(word) } }
        if let best = found.min(by: { $0.name.count < $1.name.count }) { return best }
        guard learnedToo else { return nil }
        return learned.filter { $0.host.hasPrefix(word) }.min { $0.host.count < $1.host.count }
    }

    // MARK: - learned from sites you visit (OpenSearch)

    private static var file: URL { Store.file("search-sites.json") }
    private static var loaded: [SearchSite]?
    /// Never more than this many: the oldest go first.
    static let most = 40

    static var learned: [SearchSite] {
        if let loaded { return loaded }
        let read = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([SearchSite].self, from: $0) } ?? []
        // Named by their address, whatever an earlier build wrote.
        let kept = read.filter { Keyword.accepts($0.template) && sameSite($0.template, $0.host) }
            .map { SearchSite(name: $0.host, host: $0.host, template: $0.template) }
        loaded = kept
        return kept
    }

    /// What a page's `<link rel="search">` asks, in Search's own world: the
    /// description's address, only on the page's own site and over https.
    static let lookup = """
    (function () {
      var link = document.querySelector('link[rel~="search"][type="application/opensearchdescription+xml"][href]');
      return link ? link.href : null;
    })();
    """

    /// A site's own home page, open in an ordinary tab, has said where its
    /// search is: the description is read from that site — https only, 64 KB
    /// at most, without the browser's cookies — and the site joins the list.
    /// Nothing is ever fetched for a site not visited, in the background or
    /// from a private tab (see Browser, where this is called).
    static func learn(from page: URL, description: URL) {
        guard page.scheme == "https", description.scheme == "https",
              let host = siteHost(page.absoluteString), sameSite(description.absoluteString, host),
              !builtIn.contains(where: { Vault.registrable(bare($0.host)) == Vault.registrable(host) }),
              !learned.contains(where: { $0.host == host }) else { return }
        var request = URLRequest(url: description, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.httpShouldHandleCookies = false
        // Redirected only within the site: nothing is read from one not visited.
        let session = URLSession(configuration: .ephemeral, delegate: SameSiteRedirects(host: host), delegateQueue: .main)
        session.dataTask(with: request) { data, response, _ in
            defer { session.finishTasksAndInvalidate() }
            guard let data, data.count <= 64 * 1024, (response as? HTTPURLResponse)?.statusCode == 200,
                  let found = OpenSearch.parse(data) else { return }
            let template = found.template
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    adopt(host: host, template: template)
                }
            }
        }.resume()
    }

    /// A learned site kept: named by its address, the only name it can't
    /// choose for itself, so the row and the chip say where the words go.
    /// (Its description's own name is left unread for that reason.)
    static func adopt(host: String, template: String) {
        guard Keyword.accepts(template), sameSite(template, host),
              !learned.contains(where: { $0.host == host }) else { return }
        var list = learned + [SearchSite(name: host, host: host, template: template)]
        if list.count > most { list.removeFirst(list.count - most) }
        loaded = list
        let snapshot = list
        Disk.write(file) { try? JSONEncoder().encode(snapshot) }
    }

    /// Forgotten, all of them: with the history (Browser.clearHistory).
    static func forget() {
        loaded = []
        try? FileManager.default.removeItem(at: file)
    }

    private static func bare(_ host: String) -> String {
        let first = host.split(separator: "/").first.map(String.init) ?? host
        return first.hasPrefix("www.") ? String(first.dropFirst(4)) : first
    }

    /// An address's host, without its www — a template's with its %s filled.
    private static func siteHost(_ address: String) -> String? {
        guard let url = URL(string: address.replacingOccurrences(of: "%s", with: "x")),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host()?.lowercased(), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// `address` is on the same site as `host` — the same registrable
    /// domain, as the public suffix list has it, so foo.github.io can't name
    /// github.io — and so the words go where the page said they would.
    static func sameSite(_ address: String, _ host: String) -> Bool {
        guard let other = siteHost(address) else { return false }
        let mine = bare(host)
        return other == mine || Vault.registrable(other) == Vault.registrable(mine)
    }
}

/// An OpenSearch description: its short name, and the address its HTML
/// results come from, with the words as %s. Anything it asks for besides
/// the words — a page number, a language — is left out if optional, and the
/// description refused if not.
enum OpenSearch {
    static func parse(_ data: Data) -> (name: String, template: String)? {
        let reader = Reader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), var template = reader.template else { return nil }
        template = template.replacingOccurrences(of: "{searchTerms}", with: "%s")
        // Optional parameters, {name?}, go; any other left means a value
        // this can't supply.
        template = template.replacingOccurrences(of: #"\{[^{}]*\?\}"#, with: "", options: .regularExpression)
        guard !template.contains("{"), template.components(separatedBy: "%s").count == 2 else { return nil }
        return (reader.name, template)
    }

    private final class Reader: NSObject, XMLParserDelegate {
        var name = ""
        var template: String?
        private var inName = false

        func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            let local = element.split(separator: ":").last.map(String.init) ?? element
            if local == "ShortName" { inName = true }
            if local == "Url", template == nil,
               (attributes["type"] ?? "").lowercased() == "text/html",
               (attributes["method"] ?? "get").lowercased() == "get",
               let found = attributes["template"] {
                template = found
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inName { name += string }
        }

        func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
            let local = element.split(separator: ":").last.map(String.init) ?? element
            if local == "ShortName" { inName = false }
        }
    }
}

/// A description's fetch, redirected only within the site it was asked of.
private final class SameSiteRedirects: NSObject, URLSessionTaskDelegate {
    let host: String
    init(host: String) { self.host = host }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let next = request.url
        let allowed = next?.scheme == "https" && next.map { url in
            MainActor.assumeIsolated { SiteSearch.sameSite(url.absoluteString, host) }
        } == true
        completionHandler(allowed ? request : nil)
    }
}
