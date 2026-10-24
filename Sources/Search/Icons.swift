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

    /// Called with a host and its icon whenever one arrives, so every tab on
    /// that host can put it on at once.
    var arrived: ((String, NSImage) -> Void)?

    private var memory: [String: NSImage] = [:]
    private var busy: Set<String> = []
    private var missing: Set<String> = []
    /// Keys with no file on disk, as far as `known` has looked.
    private var absent: Set<String> = []

    private static var folder: URL { Store.folder.appendingPathComponent("icons", isDirectory: true) }

    /// Clear History: every icon kept on disk goes. The tabs open now keep
    /// theirs until they are closed.
    func forgetAll() {
        try? FileManager.default.removeItem(at: Favicons.folder)
        missing.removeAll()
        absent.removeAll()
        if #available(macOS 15.4, *) { ExtensionShims.forgetIcons() }
    }
    private static func file(_ key: String) -> URL { folder.appendingPathComponent(key + ".png") }

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

    /// The name an icon is kept under: the site, with a suffix for the dark
    /// variant a site offered. Sites without one keep one file for both.
    private static func key(_ host: String, dark: Bool) -> String { dark ? host + "@dark" : host }

    /// What is already known, and nothing fetched. In the dark, the dark
    /// variant when there is one, the ordinary icon otherwise.
    func cached(_ host: String) -> NSImage? {
        let normalized = host.lowercased()
        if let hit = match(normalized) { return hit }
        if normalized.hasPrefix("www.") {
            let bare = String(normalized.dropFirst(4))
            if let hit = match(bare) { return hit }
        } else {
            let www = "www." + normalized
            if let hit = match(www) { return hit }
        }
        return nil
    }

    private func match(_ key: String) -> NSImage? {
        if Favicons.dark, let hit = known(Favicons.key(key, dark: true)) { return hit }
        return known(key)
    }

    private func known(_ key: String) -> NSImage? {
        if let hit = memory[key] { return hit }
        // A host with no icon on disk is looked for there once, not on every
        // line of every list that shows it: the History panel asked for two
        // thousand of them each time it drew. One that arrives later goes
        // into `memory`, which is asked first.
        if absent.contains(key) { return nil }
        guard let image = NSImage(contentsOf: Favicons.file(key)) else {
            absent.insert(key)
            return nil
        }
        memory[key] = image
        return image
    }

    private static func fresh(_ key: String) -> Bool {
        guard let stamp = try? file(key).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        else { return false }
        return Date().timeIntervalSince(stamp) < 7 * 86_400
    }

    /// The look changed: every tab puts on the icon that goes with it, and
    /// asks again for one where the site may have a variant not yet seen.
    func relook(_ tabs: [Tab]) {
        missing = []
        for tab in tabs {
            guard let site = tab.address.flatMap(Favicons.site) else { continue }
            tab.icon = cached(site)
            fetch(for: tab)
        }
    }

    /// An icon from somewhere else — another browser's cache, at import —
    /// kept as if the site had handed it over, unless one is already here.
    func adopt(_ data: Data, for host: String) async {
        guard cached(host) == nil, let image = await Favicons.square(data) else { return }
        memory[host] = image
        Favicons.keep(image, for: host)
        arrived?(host, image)
    }

    /// Asks the page which icon it wants to be known by, fetches it, and keeps
    /// it. Nothing happens if a fresh one is already on disk — unless the
    /// page has just changed its icon (`changed`), which is fetched again.
    ///
    /// What the page shows is kept under the look it was asked in: a page
    /// follows Search's light or dark look, and a site that swaps its icon
    /// with it from script (GitHub), rather than declaring both, would
    /// otherwise have one look's icon overwrite the other's (#423).
    func fetch(for tab: Tab, changed: Bool = false) {
        guard let url = tab.address, let host = Favicons.site(url),
              url.scheme?.hasPrefix("http") == true
        else { return }

        let dark = Favicons.dark
        let key = Favicons.key(host, dark: dark)
        // Fresh and right for this look: nothing to do.
        if !changed, Favicons.fresh(key), let known = known(key) {
            if tab.address.flatMap(Favicons.site) == host { tab.icon = known }
            return
        }
        guard !busy.contains(host), changed || !missing.contains(host) else { return }
        busy.insert(host)

        tab.web.evaluateJavaScript(Favicons.probe) { [weak self, weak tab] answer, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let declared = (answer as? [[String: String]]) ?? []
                let candidates = Favicons.rank(declared, page: url, dark: dark)
                let shy = tab?.shy ?? false
                Task { await self.download(candidates, host: host, key: key, shy: shy) }
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

    private func download(_ candidates: [URL], host: String, key: String, shy: Bool) async {
        defer { busy.remove(host) }
        let session = URLSession(configuration: {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 8
            return config
        }())
        for candidate in candidates {
            guard let (data, response) = try? await session.data(from: candidate),
                  (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
                  data.count > 60, data.count < 2_000_000
            else { continue }
            var decoded = await Favicons.square(data)
            // An SVG icon: drawn by WebKit, never by a decoder of this
            // process's own, then read back as the PNG it drew (#680).
            if decoded == nil, SVGIcons.looksLikeSVG(data, response: response),
               let png = await SVGIcons.shared.png(from: data) {
                decoded = await Favicons.square(png)
            }
            guard let image = decoded else { continue }
            memory[key] = image
            absent.remove(key)
            if !shy { Favicons.keep(image, for: key) }
            arrived?(host, image)
            return
        }
        // Not asked again this session: hammering a site for an icon it
        // doesn't have is exactly the kind of thing a quiet browser doesn't do.
        missing.insert(host)
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

    private static func keep(_ image: NSImage, for key: String) {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { return }
        let file = Favicons.file(key)
        let dir = folder
        DispatchQueue.global(qos: .utility).async {
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
        var list = scored.sorted { $0.1 > $1.1 }.map(\.0)
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
