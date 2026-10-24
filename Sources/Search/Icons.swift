import CryptoKit
import ImageIO
import SwiftUI
import WebKit

// A site's own icon, for the tabs that are set to wear one.
//
// WebKit doesn't hand these over, so the page is asked what it declares and
// the best of those is fetched once and kept as a small PNG next to the
// history. A tab brought back from yesterday's session has its icon before it
// has a page; a tab on a site never seen before shows a letter until the icon
// arrives, which is a second or so.

@MainActor
final class Favicons {
    static let shared = Favicons()

    /// Called with a site whenever one of its pages gets an icon, so every
    /// tab on that site can put on the one that is now its own.
    var arrived: ((String) -> Void)?

    /// What a page was last seen wearing: the icon it declared in each look,
    /// by that icon's name on disk (see `ident`), and when. `seen` is 0 for
    /// one that stands for the whole site without a page having said so: an
    /// import, or an icon kept before pages were.
    private struct Page: Codable {
        var light: String?
        var dark: String?
        var seen: Double
    }

    /// Site, then page, then icon: kept the way WebKit, Firefox and Chromium
    /// keep theirs. Two apps behind one host each declare an icon of their
    /// own, and the host alone can't say which a page wears (mac-mini/sonarr
    /// and mac-mini/radarr).
    private var pages: [String: [String: Page]] = [:] { didSet { lookups.removeAll() } }
    /// The same for shy tabs, never written down.
    private var shyPages: [String: [String: Page]] = [:] { didSet { lookups.removeAll() } }
    /// What each address was last found to wear, in each look, until a page
    /// changes: the History panel asks for two thousand at a time, and a page
    /// with no icon of its own is matched against every page of its site.
    private var lookups: [String: NSImage?] = [:]
    private var loaded = false
    private var saving = false
    /// Icons a page stopped wearing, to be deleted once no page wears them.
    private var dropped: Set<String> = []

    private var memory: [String: NSImage] = [:]
    private var busy: Set<String> = []
    private var missing: Set<String> = []
    /// Icon addresses that came back with nothing usable this session.
    private var failed: Set<URL> = []
    /// Icon addresses that gave no answer twice, and when each may be asked
    /// again.
    private var unreachable: [URL: Date] = [:]
    /// A minute: a site that is down isn't asked by every page of it, and
    /// one back up is asked again soon.
    private static let backoff: TimeInterval = 60
    /// Icons with no file on disk, as far as `known` has looked.
    private var absent: Set<String> = []

    /// More pages than this and the ones seen longest ago are forgotten.
    private static let most = 4000
    /// Declared icons tried for one page, best first; favicon.ico makes six.
    private static let tried = 5

    private static var folder: URL { Store.folder.appendingPathComponent("icons", isDirectory: true) }
    private static var index: URL { folder.appendingPathComponent("pages.json") }
    private static let disk = DispatchQueue(label: "Favicons.disk", qos: .utility)

    /// Clear History: every icon kept on disk goes. The tabs open now keep
    /// theirs until they are closed.
    func forgetAll() {
        try? FileManager.default.removeItem(at: Favicons.folder)
        pages.removeAll()
        shyPages.removeAll()
        dropped.removeAll()
        loaded = true
        missing.removeAll()
        failed.removeAll()
        unreachable.removeAll()
        absent.removeAll()
        if #available(macOS 15.4, *) { ExtensionShims.forgetIcons() }
    }

    /// One address forgotten from History: its page goes from the index,
    /// and its icon from disk once no page wears it. A page is its path, so
    /// the address's query makes no difference to which page goes.
    func forget(_ url: URL) {
        guard let site = Favicons.site(url) else { return }
        load()
        let page = Favicons.page(url)
        guard let gone = pages[site]?[page] else { return }
        pages[site]?[page] = nil
        if pages[site]?.isEmpty == true { pages[site] = nil }
        dropped.formUnion([gone.light, gone.dark].compactMap { $0 })
        save()
    }

    /// The last private tab closed: what its pages wore goes with it, and
    /// the icons only they wore go from memory.
    func forgetShy() {
        guard !shyPages.isEmpty else { return }
        for site in shyPages.values { for page in site.values { dropped.formUnion([page.light, page.dark].compactMap { $0 }) } }
        shyPages.removeAll()
        save()
    }
    private static func file(_ ident: String) -> URL { folder.appendingPathComponent(ident + ".png") }

    /// Whether the chrome is dark right now. A site that declares an icon
    /// for `prefers-color-scheme: dark` is asked for that one, and it is
    /// kept apart from the light one, so switching looks switches icons.
    static var dark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// Which site an address is, for its icon: its host, and its port when
    /// it names one — localhost:3000 and localhost:4321 are two projects,
    /// not one (#413). The port a scheme has anyway doesn't count.
    nonisolated static func site(_ url: URL) -> String? {
        guard let host = url.host()?.lowercased(), !host.isEmpty else { return nil }
        let scheme = url.scheme?.lowercased()
        guard let port = url.port, !(scheme == "http" && port == 80), !(scheme == "https" && port == 443) else { return host }
        return "\(host):\(port)"
    }

    /// Which page of its site an address is: its path. The query and the
    /// fragment are left off: neither changes what a page declares, and a
    /// query can carry a token, a reset link or a search, which the index
    /// is no place for.
    nonisolated static func page(_ url: URL) -> String {
        let path = url.path(percentEncoded: true)
        return path.isEmpty ? "/" : path
    }

    private static func segments(_ page: String) -> [Substring] { page.split(separator: "/") }

    /// The name an icon is kept under: its own address, so pages that point
    /// at the same file share one copy.
    private static func ident(_ icon: URL) -> String { ident(icon.absoluteString) }

    private static func ident(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let data = try? Data(contentsOf: Favicons.index),
           let kept = try? JSONDecoder().decode([String: [String: Page]].self, from: data) {
            pages = kept
            // An index with queries in its keys: each folded into its path.
            var folded = false
            for (site, kept) in pages {
                for (key, page) in kept {
                    guard let mark = key.firstIndex(of: "?") else { continue }
                    let path = String(key[..<mark]), there = pages[site]?[path]
                    pages[site]?[key] = nil
                    pages[site]?[path] = there.flatMap { $0.seen > page.seen ? $0 : nil } ?? page
                    dropped.formUnion([page.light, page.dark, there?.light, there?.dark].compactMap { $0 })
                    folded = true
                }
            }
            if folded { save() }
            return
        }
        // Icons kept site by site, from before pages were: each stands for
        // its whole site until a page of it says otherwise.
        let names = (try? FileManager.default.contentsOfDirectory(atPath: Favicons.folder.path)) ?? []
        for name in names where name.hasSuffix(".png") {
            let ident = String(name.dropLast(4))
            guard !(ident.count == 32 && ident.allSatisfy(\.isHexDigit)) else { continue }
            let dark = ident.hasSuffix("@dark")
            let site = dark ? String(ident.dropLast(5)) : ident
            var page = pages[site]?["/"] ?? Page(seen: 0)
            if dark { page.dark = ident } else { page.light = ident }
            pages[site, default: [:]]["/"] = page
        }
        if !pages.isEmpty { save() }
    }

    /// Written a moment later, so a burst of pages loading is one write.
    private func save() {
        guard !saving else { return }
        saving = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
            saving = false
            let gone = prune().map(Favicons.file)
            guard let data = try? JSONEncoder().encode(pages) else { return }
            let folder = Favicons.folder, index = Favicons.index
            Favicons.disk.async {
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try? data.write(to: index, options: .atomic)
                for file in gone { try? FileManager.default.removeItem(at: file) }
            }
        }
    }

    /// Forgets the pages seen longest ago once there are too many, and says
    /// which icons no page wears any more.
    private func prune() -> Set<String> {
        let count = pages.values.reduce(0) { $0 + $1.count }
        if count > Favicons.most {
            var all: [(site: String, path: String, page: Page)] = []
            for (site, kept) in pages { for (path, page) in kept { all.append((site, path, page)) } }
            all.sort { $0.page.seen < $1.page.seen }
            for old in all.prefix(count - Favicons.most * 3 / 4) {
                pages[old.site]?[old.path] = nil
                if pages[old.site]?.isEmpty == true { pages[old.site] = nil }
                dropped.formUnion([old.page.light, old.page.dark].compactMap { $0 })
            }
        }
        guard !dropped.isEmpty else { return [] }
        var worn = Set<String>()
        for kept in [pages, shyPages] {
            for site in kept.values { for page in site.values { worn.formUnion([page.light, page.dark].compactMap { $0 }) } }
        }
        let gone = dropped.subtracting(worn)
        dropped.removeAll()
        for ident in gone {
            memory[ident] = nil
            absent.insert(ident)
        }
        return gone
    }

    /// The icon an address wears, from what is already known, and nothing
    /// fetched: the one its page declared, or failing that the one the
    /// nearest page of the same site did, so a page never opened still has
    /// its site's. In the dark, the dark variant when there is one. A
    /// private tab (`shy`) also sees what its own pages wore; nothing else
    /// does.
    func cached(for url: URL?, shy: Bool = false) -> NSImage? {
        guard let url, let site = Favicons.site(url) else { return nil }
        return lookup(site, page: Favicons.page(url), shy: shy)
    }

    /// A site's icon, when there is no page to go by: the one its most
    /// recently seen page wore.
    func cached(_ site: String) -> NSImage? { lookup(site.lowercased(), page: nil, shy: false) }

    private func lookup(_ site: String, page: String?, shy: Bool) -> NSImage? {
        load()
        let key = "\(Favicons.dark) \(shy) \(site) \(page ?? "")"
        if let known = lookups[key] { return known }
        let other = site.hasPrefix("www.") ? String(site.dropFirst(4)) : "www." + site
        let found = nearest(site, page: page, shy: shy) ?? nearest(other, page: page, shy: shy)
        lookups[key] = found
        return found
    }

    private func nearest(_ site: String, page: String?, shy: Bool) -> NSImage? {
        let dark = Favicons.dark
        let kept = shy ? (pages[site] ?? [:]).merging(shyPages[site] ?? [:]) { _, shy in shy } : pages[site] ?? [:]
        if let page, let exact = kept[page], let hit = image(exact, dark: dark) { return hit }
        guard !kept.isEmpty else { return nil }
        guard let page else {
            for candidate in kept.values.sorted(by: { $0.seen > $1.seen }) {
                if let hit = image(candidate, dark: dark) { return hit }
            }
            return nil
        }
        // The page sharing the most of this one's path first: another page of
        // the same app, before anything else on its host.
        let mine = Favicons.segments(page)
        func shared(_ other: String) -> Int {
            zip(mine, Favicons.segments(other)).prefix { $0.0 == $0.1 }.count
        }
        let scored: [(shared: Int, root: Bool, page: Page)] = kept.map { (shared($0.key), $0.key == "/", $0.value) }
        // A host whose pages don't agree on one icon is several apps, and a
        // page of another one is no guide: the letter is truer than a guess.
        let agreed = Set(kept.values.compactMap { dark ? $0.dark ?? $0.light : $0.light ?? $0.dark }).count <= 1
        for candidate in scored.sorted(by: { $0.shared != $1.shared ? $0.shared > $1.shared : $0.page.seen > $1.page.seen }) {
            guard candidate.shared > 0 || candidate.root || agreed else { continue }
            if let hit = image(candidate.page, dark: dark) { return hit }
        }
        return nil
    }

    private func image(_ page: Page, dark: Bool) -> NSImage? {
        if dark, let ident = page.dark, let hit = known(ident) { return hit }
        return page.light.flatMap(known)
    }

    private func known(_ ident: String) -> NSImage? {
        if let hit = memory[ident] { return hit }
        // An icon with no file on disk is looked for there once, not on every
        // line of every list that shows it: the History panel asked for two
        // thousand of them each time it drew. One that arrives later goes
        // into `memory`, which is asked first.
        if absent.contains(ident) { return nil }
        guard let image = NSImage(contentsOf: Favicons.file(ident)) else {
            absent.insert(ident)
            return nil
        }
        memory[ident] = image
        return image
    }

    private static func fresh(_ ident: String) -> Bool {
        guard let stamp = try? file(ident).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        else { return false }
        return Date().timeIntervalSince(stamp) < 7 * 86_400
    }

    /// The look changed: every tab puts on the icon that goes with it, and
    /// asks again for one where the site may have a variant not yet seen.
    func relook(_ tabs: [Tab]) {
        missing = []
        failed = []
        for tab in tabs {
            guard tab.address != nil else { continue }
            tab.icon = cached(for: tab.address, shy: tab.shy)
            fetch(for: tab)
        }
    }

    /// An icon from somewhere else — another browser's cache, at import —
    /// kept for the whole site, unless the site already has one here.
    func adopt(_ data: Data, for host: String) async {
        let site = host.lowercased()
        guard cached(site) == nil, let image = await Favicons.square(data) else { return }
        let ident = Favicons.ident("adopted:" + site)
        memory[ident] = image
        absent.remove(ident)
        Favicons.keep(image, for: ident)
        if pages[site]?["/"] == nil { pages[site, default: [:]]["/"] = Page(light: ident, seen: 0) }
        save()
        arrived?(site)
    }

    /// Asks the page which icon it wants to be known by, fetches it, and keeps
    /// it. Nothing happens if this page's icon is on disk and fresh — unless
    /// the page has just changed its icon (`changed`), which is asked again.
    ///
    /// What the page shows is kept under the look it was asked in: a page
    /// follows Search's light or dark look, and a site that swaps its icon
    /// with it from script (GitHub), rather than declaring both, would
    /// otherwise have one look's icon overwrite the other's (#423).
    func fetch(for tab: Tab, changed: Bool = false) {
        guard let url = tab.address, let site = Favicons.site(url),
              url.scheme?.hasPrefix("http") == true
        else { return }
        load()

        let page = Favicons.page(url)
        let dark = Favicons.dark
        // Fresh and right for this look: nothing to do.
        if !changed, let kept = (tab.shy ? shyPages[site]?[page] : nil) ?? pages[site]?[page], kept.seen > 0,
           let ident = dark ? kept.dark : kept.light, Favicons.fresh(ident), let known = known(ident) {
            tab.icon = known
            return
        }
        let busyKey = site + page
        guard !busy.contains(busyKey), changed || !missing.contains(busyKey) else { return }
        busy.insert(busyKey)

        tab.web.evaluateJavaScript(Favicons.probe) { [weak self, weak tab] answer, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let declared = (answer as? [[String: String]]) ?? []
                let candidates = Favicons.rank(declared, page: url, dark: dark)
                let shy = tab?.shy ?? false
                Task { await self.download(candidates, site: site, page: page, dark: dark, shy: shy) }
            }
        }
    }

    private enum Scheme { case any, light, dark }

    /// What a `media` attribute says about the scheme, if anything.
    private static func media(_ value: String?) -> Scheme {
        let text = (value ?? "").lowercased()
        if text.contains("prefers-color-scheme") {
            if text.contains("dark") { return .dark }
            if text.contains("light") { return .light }
        }
        return .any
    }

    private func download(_ candidates: [URL], site: String, page: String, dark: Bool, shy: Bool, again: Bool = true) async {
        let busyKey = site + page
        defer { busy.remove(busyKey) }
        let session = URLSession(configuration: {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 8
            return config
        }())
        var unanswered: [URL] = []
        var asked = false
        for candidate in candidates where !failed.contains(candidate) {
            if let until = unreachable[candidate], until > Date() { continue }
            let ident = Favicons.ident(candidate)
            // Another page of the site wears the same file, and it is fresh.
            if !shy, Favicons.fresh(ident), let image = known(ident) {
                wear(ident, image, site: site, page: page, dark: dark, shy: shy)
                return
            }
            asked = true
            // No answer at all is the network, not the site.
            guard let (data, response) = try? await session.data(from: candidate) else {
                unanswered.append(candidate)
                continue
            }
            guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
                  data.count > 60, data.count < 2_000_000
            else {
                failed.insert(candidate)
                continue
            }
            var decoded = await Favicons.square(data)
            // An SVG icon: drawn by WebKit, never by a decoder of this
            // process's own, then read back as the PNG it drew (#680).
            if decoded == nil, SVGIcons.looksLikeSVG(data, response: response),
               let png = await SVGIcons.shared.png(from: data) {
                decoded = await Favicons.square(png)
            }
            guard let image = decoded else {
                failed.insert(candidate)
                continue
            }
            memory[ident] = image
            absent.remove(ident)
            if !shy { Favicons.keep(image, for: ident) }
            wear(ident, image, site: site, page: page, dark: dark, shy: shy)
            return
        }
        // Unreachable once more, a moment later: the first requests an app
        // makes to a machine on the local network fail while macOS is still
        // deciding whether it may. Still nothing, and the address is left
        // alone for a while rather than asked by every page of the site.
        if !unanswered.isEmpty {
            if again {
                try? await Task.sleep(for: .seconds(3))
                await download(candidates, site: site, page: page, dark: dark, shy: shy, again: false)
            } else {
                for candidate in unanswered { unreachable[candidate] = Date() + Favicons.backoff }
            }
            return
        }
        // Every candidate skipped: nothing new is known about the site.
        guard asked else { return }
        // Not asked again this session: hammering a site for an icon it
        // doesn't have is exactly the kind of thing a quiet browser doesn't do.
        missing.insert(busyKey)
    }

    private func wear(_ ident: String, _ image: NSImage, site: String, page: String, dark: Bool, shy: Bool) {
        // One that stood for the whole site goes once a page says otherwise.
        let before = (shy ? shyPages : pages)[site]?[page]
        var kept = before.flatMap { $0.seen > 0 ? $0 : nil } ?? Page(seen: 0)
        if dark { kept.dark = ident } else { kept.light = ident }
        kept.seen = Date().timeIntervalSince1970
        if shy {
            shyPages[site, default: [:]][page] = kept
        } else {
            pages[site, default: [:]][page] = kept
            if let before {
                dropped.formUnion(Set([before.light, before.dark].compactMap { $0 }).subtracting([kept.light, kept.dark].compactMap { $0 }))
            }
            save()
        }
        arrived?(site)
    }

    /// The kinds of picture a site's icon may be. Anything else a site sends
    /// — a PDF, a TIFF, an icns, PostScript — isn't opened at all: every
    /// kind is one more decoder a site can reach in this process.
    private static let kinds: Set<String> = [
        "public.png", "com.microsoft.ico", "public.jpeg", "com.compuserve.gif", "org.webmproject.webp", "com.microsoft.bmp",
    ]

    /// Decoded and drawn into a square off the main thread — an .ico can hold
    /// a dozen sizes and take a moment to unpack. Only the kinds above, no
    /// larger than 4096 pixels a side, and decoded straight to the small size
    /// a tab needs.
    private static func square(_ data: Data) async -> NSImage? {
        await Task.detached(priority: .utility) { () -> NSImage? in
            guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let kind = CGImageSourceGetType(source) as String?, Favicons.kinds.contains(kind)
            else { return nil }
            // The frame nearest 64 pixels from above, for an .ico of many.
            var best = 0, bestSide = 0
            for index in 0..<min(CGImageSourceGetCount(source), 32) {
                let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
                let w = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
                let h = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
                guard w > 0, h > 0, w <= 4096, h <= 4096 else { continue }
                let side = max(w, h)
                if bestSide == 0 || (side >= 64 && (bestSide < 64 || side < bestSide)) || (bestSide < 64 && side > bestSide) {
                    best = index
                    bestSide = side
                }
            }
            guard bestSide > 0,
                  let decoded = CGImageSourceCreateThumbnailAtIndex(source, best, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceThumbnailMaxPixelSize: 128,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                  ] as CFDictionary)
            else { return nil }
            let image = NSImage(cgImage: decoded, size: NSSize(width: decoded.width, height: decoded.height))
            let side: CGFloat = 64
            let out = NSImage(size: NSSize(width: side, height: side))
            out.lockFocus()
            NSGraphicsContext.current?.imageInterpolation = .high
            let scale = min(side / image.size.width, side / image.size.height)
            let w = image.size.width * scale
            let h = image.size.height * scale
            image.draw(
                in: NSRect(x: (side - w) / 2, y: (side - h) / 2, width: w, height: h),
                from: .zero,
                operation: .sourceOver,
                fraction: 1
            )
            out.unlockFocus()
            return out
        }.value
    }

    private static func keep(_ image: NSImage, for ident: String) {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { return }
        let file = Favicons.file(ident)
        let dir = folder
        Favicons.disk.async {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? png.write(to: file, options: .atomic)
        }
    }

    /// Best first. A crisp icon around 32–64 pixels is what a tab wants; the
    /// touch icon is a fine second; the file at the root is the fallback every
    /// site has had since 1999.
    private static func rank(_ declared: [[String: String]], page: URL, dark: Bool) -> [URL] {
        var scored: [(URL, Int)] = []
        for entry in declared {
            // An icon written into the page itself, as data: (an emoji in an
            // SVG, often) is read the same way, up to a size.
            guard let href = entry["href"],
                  let url = href.lowercased().hasPrefix("data:") ? inline(href)
                      : URL(string: href, relativeTo: page)?.absoluteURL,
                  url.scheme?.hasPrefix("http") == true || url.scheme == "data"
            else { continue }
            let rel = entry["rel"] ?? ""
            let sizes = entry["sizes"] ?? ""
            let type = entry["type"] ?? ""
            // An icon meant for the other scheme is the last resort; one
            // meant for this scheme comes first whatever its size.
            let scheme = media(entry["media"])
            if scheme == (dark ? .light : .dark) { continue }
            var score = 25
            if rel.contains("apple-touch") { score = 40 }
            if let px = sizes.split(separator: " ").compactMap({ Int($0.split(separator: "x").first ?? "") }).max() {
                switch px {
                case ..<24: score = 10
                case 24..<48: score = 45
                case 48..<128: score = 50
                case 128..<260: score = 42
                default: score = 20
                }
            }
            if sizes == "any" || type.contains("svg") || url.pathExtension.lowercased() == "svg" { score = 35 }
            if scheme != .any { score += 40 }
            scored.append((url, score))
        }
        var list = Array(scored.sorted { $0.1 > $1.1 }.map(\.0).prefix(Favicons.tried))
        // The same site's root, its port included.
        if page.host() != nil, let root = URL(string: "/favicon.ico", relativeTo: page)?.absoluteURL {
            list.append(root)
        }
        // The same address twice is a wasted request.
        var seen = Set<String>()
        return list.filter { seen.insert($0.absoluteString).inserted }
    }

    /// A data: address as a page writes it, `<` and spaces left as they
    /// are, made into one Foundation reads: its bytes in base64. Nil past
    /// the size an SVG icon may be.
    private static func inline(_ href: String) -> URL? {
        guard href.utf8.count <= SVGIcons.limit * 3, let comma = href.firstIndex(of: ",") else { return nil }
        let meta = href[href.index(href.startIndex, offsetBy: 5)..<comma]
        let body = String(href[href.index(after: comma)...])
        var parts = meta.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        let base64 = parts.last?.lowercased() == "base64"
        if base64 { parts.removeLast() }
        let bytes: Data? = base64
            ? Data(base64Encoded: (body.removingPercentEncoding ?? body).filter { !$0.isWhitespace })
            : (body.removingPercentEncoding ?? body).data(using: .utf8)
        guard let bytes, bytes.count <= SVGIcons.limit else { return nil }
        let type = parts.first.flatMap { $0.contains("/") && !$0.contains("=") ? $0 : nil } ?? "text/plain"
        guard type.allSatisfy({ $0.isLetter || $0.isNumber || "+-./".contains($0) }) else { return nil }
        return URL(string: "data:\(type);base64,\(bytes.base64EncodedString())")
    }

    private static let probe = """
    (function () {
      var out = [];
      var links = document.querySelectorAll('link[rel]');
      for (var i = 0; i < links.length; i++) {
        var l = links[i];
        var rel = (l.getAttribute('rel') || '').toLowerCase();
        if (rel.indexOf('icon') < 0) continue;
        out.push({
          href: l.href,
          rel: rel,
          sizes: (l.getAttribute('sizes') || '').toLowerCase(),
          type: (l.getAttribute('type') || '').toLowerCase(),
          media: (l.getAttribute('media') || '').toLowerCase()
        });
      }
      return out;
    })();
    """
}

/// What stands for a page when there is no room for its title: the site's
/// icon if there is one, and a letter in a faint square until there is.
struct Mark: View {
    let icon: NSImage?
    let letter: String
    var size: CGFloat = 16
    var dim = false

    var body: some View {
        Group {
            if let icon, icon.isTemplate {
                // One of Search's own pages (InternalPages.swift): its symbol,
                // in the row's ink, light or dark.
                Image(nsImage: icon)
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(Palette.ink.opacity(0.75))
                    .padding(size * 0.06)
                    .frame(width: size, height: size)
            } else if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
            } else {
                Text(letter)
                    .font(.system(size: size * 0.56, weight: .medium))
                    .foregroundStyle(Palette.muted)
                    .frame(width: size, height: size)
                    .background(
                        RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                            .fill(Palette.ink.opacity(0.06))
                    )
            }
        }
        .opacity(dim ? 0.45 : 1)
        .transition(.opacity)
        .animation(Motion.quick, value: icon == nil)
    }
}

/// A page that changes its icon after it has loaded — GitHub swaps it with
/// its theme, a chat puts a count on it — says so, and the icon is asked for
/// again (see Favicons.fetch). Changes that come close together are taken as
/// one, at most every two seconds; the top page only.
final class IconRelay: NSObject, WKScriptMessageHandler {
    static let name = "officeIcon"

    weak var tab: Tab?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame else { return }
        MainActor.assumeIsolated {
            guard let tab, tab.built === message.webView else { return }
            Favicons.shared.fetch(for: tab, changed: true)
        }
    }

    static let script = """
    (function () {
      if (window.top !== window || !document.head) return;
      var timer = null, last = 0;
      var icon = function (n) {
        return n && n.nodeType === 1 && n.tagName === 'LINK' && /icon/i.test(n.getAttribute('rel') || '');
      };
      var touched = function (r) {
        if (icon(r.target)) return true;
        for (var i = 0; i < r.addedNodes.length; i++) if (icon(r.addedNodes[i])) return true;
        for (var j = 0; j < r.removedNodes.length; j++) if (icon(r.removedNodes[j])) return true;
        return false;
      };
      new MutationObserver(function (records) {
        if (!records.some(touched)) return;
        clearTimeout(timer);
        timer = setTimeout(function () {
          last = Date.now();
          try { webkit.messageHandlers.officeIcon.postMessage(1); } catch (e) {}
        }, Math.max(500, 2000 - (Date.now() - last)));
      }).observe(document.head, { childList: true, subtree: true, attributes: true, attributeFilter: ['href', 'rel', 'media'] });
    })();
    """
}

/// SVG icons, drawn where WebKit draws every SVG a page shows: in a web
/// process of its own, sandboxed, out of this one. A site's SVG is put in
/// an <img> there (an SVG as an image runs no script and loads nothing),
/// drawn on a canvas at a tab's size and handed back as a PNG, which only
/// the PNG decoder here then reads. No SVG parser runs in Search's process.
///
/// One small view, not in any window, with a store that keeps nothing and
/// page scripts off; it is let go after a few seconds without work, and
/// with it its process. What it draws is kept as the PNGs every icon is.
@MainActor
final class SVGIcons: NSObject, WKNavigationDelegate {
    static let shared = SVGIcons()

    /// The largest SVG drawn, in bytes. Icons are a few kilobytes.
    nonisolated static let limit = 256 * 1024
    /// Pixels a side: a tab draws 16 points at 2x, the pins grid larger.
    private static let side = 128
    /// Longer than this, the drawing is given up on, and its process with it.
    private static let patience: TimeInterval = 4

    private var web: WKWebView?
    private var loaded = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var idle: DispatchWorkItem?
    private var running = 0

    /// An SVG by what the server says it is, or by its first bytes.
    nonisolated static func looksLikeSVG(_ data: Data, response: URLResponse?) -> Bool {
        guard data.count <= limit else { return false }
        if response?.mimeType?.lowercased() == "image/svg+xml" { return true }
        let head = String(decoding: data.prefix(1024), as: UTF8.self).lowercased()
        return head.contains("<svg")
    }

    /// The SVG drawn into a square PNG, or nil if it can't be.
    func png(from data: Data) async -> Data? {
        guard data.count <= SVGIcons.limit, let web = await view() else { return nil }
        idle?.cancel()
        running += 1
        defer {
            running -= 1
            letGoLater()
        }
        let source = "data:image/svg+xml;base64," + data.base64EncodedString()
        let prefix = "data:image/png;base64,"
        return await withCheckedContinuation { (answer: CheckedContinuation<Data?, Never>) in
            var done = false
            func finish(_ png: Data?) {
                guard !done else { return }
                done = true
                answer.resume(returning: png)
            }
            web.callAsyncJavaScript(SVGIcons.draw, arguments: ["src": source, "side": SVGIcons.side],
                                    in: nil, in: .defaultClient) { result in
                guard case .success(let value) = result, let text = value as? String, text.hasPrefix(prefix),
                      text.utf8.count < 2_000_000
                else { return finish(nil) }
                finish(Data(base64Encoded: String(text.dropFirst(prefix.count))))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + SVGIcons.patience) { [weak self] in
                guard !done else { return }
                finish(nil)
                self?.letGo()
            }
        }
    }

    /// The image is decoded and drawn in the web process; only the PNG it
    /// makes comes back. Kept to its proportions, centred in the square.
    private static let draw = """
    const img = new Image();
    img.src = src;
    await img.decode();
    const w = img.naturalWidth || side, h = img.naturalHeight || side;
    const scale = Math.min(side / w, side / h);
    const canvas = document.createElement('canvas');
    canvas.width = side; canvas.height = side;
    canvas.getContext('2d').drawImage(img, (side - w * scale) / 2, (side - h * scale) / 2, w * scale, h * scale);
    return canvas.toDataURL('image/png');
    """

    private func view() async -> WKWebView? {
        if let web, loaded { return web }
        if web == nil {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            config.defaultWebpagePreferences.allowsContentJavaScript = false
            config.applicationNameForUserAgent = Web.userAgentName
            config.mediaTypesRequiringUserActionForPlayback = .all
            let made = WKWebView(frame: NSRect(x: 0, y: 0, width: 16, height: 16), configuration: config)
            made.navigationDelegate = self
            web = made
            loaded = false
            // Nothing can be loaded into it but data: images.
            made.loadHTMLString(
                "<!doctype html><meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; img-src data:\">",
                baseURL: nil)
        }
        await withCheckedContinuation { waiting.append($0) }
        return loaded ? web : nil
    }

    private func ready(_ ok: Bool) {
        loaded = ok
        let all = waiting
        waiting.removeAll()
        all.forEach { $0.resume() }
    }

    private func letGoLater() {
        idle?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.running == 0 else { return }
            self.letGo()
        }
        idle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: work)
    }

    private func letGo() {
        idle?.cancel()
        idle = nil
        web?.navigationDelegate = nil
        web?.stopLoading()
        web = nil
        ready(false)
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        // Only the empty page it starts on; never a site.
        decisionHandler(action.request.url?.absoluteString == "about:blank" ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === web else { return }
        ready(true)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard webView === web else { return }
        letGo()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard webView === web else { return }
        letGo()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === web else { return }
        letGo()
    }
}
