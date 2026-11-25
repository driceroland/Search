import AppKit
import ImageIO
import WebKit

// Right-click on an image, own menu.
//
// WebKit's own — Open Image in New Window, Download Image, Copy Image, Copy
// Subject, Look Up — is the same one Safari has, and two of those five do
// nothing on at least some sites: Download Image never asks WebKit for a
// download at all (it isn't a navigation, so nothing this app's own
// WKNavigationDelegate sees applies to it), and Copy Image writes the kind of
// pasteboard promise a "paste" — as opposed to a drag — doesn't always
// resolve, which is the empty box some apps show for what should have been a
// picture. Neither is a bug in this app's own downloading or copying; there
// simply isn't a public hook to fix WebKit's own menu from the outside.
//
// So the page's own menu is asked to step aside for exactly one element —
// an <img>, on its own contextmenu event, nothing else touched — and this
// app's own menu, doing the same two things a different way, stands in for
// it. Copy Subject and Look Up are the one real loss: both are system
// features with no public equivalent, so a picture with text or a
// recognisable object in it won't offer to lift either, here, the way
// Safari's own menu would.

final class ImageRelay: NSObject, WKScriptMessageHandler {
    static let name = "officeImages"

    weak var tab: Tab?
    /// The frame the last right-click on an image came from: a blob: image
    /// can only be read in the page that made it.
    private(set) var frame: WKFrameInfo?

    /// Every frame: an image inside an ad or a map embed is still an image.
    /// Only a genuine <img> with something to point at is worth the trip —
    /// a broken one, or a 1×1 tracking pixel, isn't worth a menu at all.
    static let watch = """
    (function () {
      if (window.__officeImages) return;
      window.__officeImages = true;
      // A right-click on a picture: what this script makes of it, for the
      // listeners below and for the probe (picture_link_menu.py), in
      // Search's world only. Nothing when it isn't one worth a menu.
      function decide(e) {
        var el = e.target;
        while (el && el.tagName !== 'IMG') el = el.parentElement;
        if (!el) return null;
        // Only an address this menu will act on takes WebKit's own menu
        // away; any other scheme keeps it, rather than getting nothing.
        var src = el.currentSrc && el.naturalWidth >= 2 && /^(https?|data|blob):/i.test(el.currentSrc) ? el.currentSrc : '';
        return { src: src, linked: linked(e), keep: !!window.__officeImagesKeep };
      }
      Object.defineProperty(window, '__officeImagesDecide', { value: decide });
      document.addEventListener('contextmenu', function (e) {
        // A right-click of yours only: a page can dispatch one itself, and
        // would open this menu whenever it liked — under your next click.
        if (!e.isTrusted) return;
        var said = decide(e);
        if (!said) return;
        // WebKit's own menu only steps aside when there is a way to ask for
        // this one — otherwise a right-click shows nothing at all.
        var relay = window.webkit && webkit.messageHandlers && webkit.messageHandlers.officeImages;
        if (!relay) return;
        // WebKit's own menu comes up, told which picture it is over: its
        // own hit test, not this script's, says whether that picture is
        // also a link (idea 1208). The event's path can't see a link inside
        // a closed shadow root, and a picture there lost Open Link in New
        // Tab to this app's picture menu. A picture that isn't a link has
        // its menu made this app's there (PageView.willOpenMenu); one that
        // is keeps WebKit's, with Copy Image and Download Image told which
        // picture they are for, to be this app's. So does every picture
        // while an extension may have right-click items (see keepMenu).
        relay.postMessage({ src: said.src, kept: true, keep: said.keep });
        // A page that keeps its own right-click from its pictures leaves
        // WebKit's menu out: this app's picture menu then comes up itself,
        // as it always did, after the page's own listeners have had their
        // say. Never over a link, which WebKit's menu would have offered.
        if (said.src && !said.linked && !said.keep) {
          window.addEventListener('contextmenu', function late(e2) {
            if (e2 === e && e.defaultPrevented) relay.postMessage({ src: said.src });
          }, { once: true });
        }
      }, true);
      // As the middle button finds a link (MiddleRelay): on the path, so one
      // in a shadow root counts, and an <area> or an SVG <a> too.
      function linked(e) {
        var path = e.composedPath();
        for (var i = 0; i < path.length; i++) {
          var tag = path[i].tagName ? path[i].tagName.toLowerCase() : '';
          if ((tag === 'a' || tag === 'area') && path[i].hasAttribute('href')) return true;
        }
        return false;
      }
    })();
    """

    /// Set ahead of `watch` while an extension may put items in a page's
    /// right-click menu (contextMenus): WebKit adds them to its own menu
    /// only, and this app's picture menu would leave them out.
    static let keepMenu = "window.__officeImagesKeep = true;"

    func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        // WebKit's own menu, coming up over a picture (see watch): the
        // picture it is to act on, or none, and whether it stays WebKit's.
        if let body = message.body as? [String: Any], body["kept"] as? Bool == true {
            let url = (body["src"] as? String).flatMap(URL.init(string:)).flatMap {
                ["http", "https", "data", "blob"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil
            }
            let keep = body["keep"] as? Bool == true
            MainActor.assumeIsolated { [weak self] in
                guard let self, let tab else { return }
                frame = message.frameInfo
                tab.built?.keepPicture(url, keep: keep)
            }
            return
        }
        guard let body = message.body as? [String: Any],
              let src = body["src"] as? String,
              let url = URL(string: src),
              // The page names this address and the menu carries it into the
              // app's own opening, copying and downloading: only the schemes
              // a picture arrives by are let through. The script above
              // already checks, but any page can post to this handler.
              ["http", "https", "data", "blob"].contains(url.scheme?.lowercased() ?? "")
        else { return }
        MainActor.assumeIsolated { [weak self] in
            guard let self, let tab else { return }
            frame = message.frameInfo
            // No WebKit menu came for it: the page kept it away.
            tab.built?.keepPicture(nil, keep: false)
            tab.onImageMenu?(tab, url)
        }
    }
}

/// Over a picture, WebKit's menu or this app's: WebKit's hit test decides
/// (idea 1208). Its menu over a picture that is also a link has the link's
/// items, which it keeps; over a picture alone, the picture's items only,
/// which become this app's (see ImageMenu.swift's head for why). And while
/// an extension may have right-click items, WebKit's, which alone has them.
enum PictureMenu {
    static let linkItems: Set<String> = [
        "WKMenuItemIdentifierOpenLink", "WKMenuItemIdentifierOpenLinkInNewWindow",
        "WKMenuItemIdentifierDownloadLinkedFile", "WKMenuItemIdentifierCopyLink",
    ]
    static let pictureItems: Set<String> = [
        "WKMenuItemIdentifierOpenImageInNewWindow", "WKMenuItemIdentifierDownloadImage", "WKMenuItemIdentifierCopyImage",
    ]

    /// Whether WebKit's menu, its items' identifiers in order, gives way to
    /// this app's picture menu.
    static func replaces(_ identifiers: [String], keep: Bool) -> Bool {
        !keep && identifiers.contains(where: pictureItems.contains) && !identifiers.contains(where: linkItems.contains)
    }

    /// How long a picture WebKit's menu was told of stays its own: the menu
    /// comes up at once, and a page that kept it away leaves nothing to
    /// pass on to the next one.
    static let fresh: TimeInterval = 1

    /// WebKit's menu over a picture made what it is to be: this app's
    /// picture items in place of WebKit's (true), or WebKit's own with Copy
    /// Image and Download Image done by this app (`retarget`).
    @MainActor
    static func shape(_ menu: NSMenu, picture url: URL?, keep: Bool, items: (URL) -> [NSMenuItem],
                      retarget: (NSMenuItem) -> Void) -> Bool {
        let identifiers = menu.items.compactMap { $0.identifier?.rawValue }
        if let url, replaces(identifiers, keep: keep) {
            let own = items(url)
            if !own.isEmpty {
                menu.removeAllItems()
                own.forEach(menu.addItem)
                return true
            }
        }
        for item in menu.items where ["WKMenuItemIdentifierCopyImage", "WKMenuItemIdentifierDownloadImage"].contains(item.identifier?.rawValue ?? "") {
            if url != nil { retarget(item) }
        }
        return false
    }
}

extension Browser {
    /// For Copy Image: no cookies at all — not kept, not sent, not shared
    /// between a normal tab's copy and a private one's — nothing cached.
    /// Kept by Proxy.swift rather than here: a session holds the proxy it
    /// was born with, so one made once would copy pictures directly for the
    /// rest of the run after a proxy was turned on.
    static var fetcher: URLSession {
        ProxyNetwork.kept("copy-image") {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.urlCache = nil
            configuration.urlCredentialStorage = nil
            configuration.timeoutIntervalForRequest = 30
            ProxyNetwork.stamp(configuration)
            return URLSession(configuration: configuration)
        }
    }

    /// The most a copied picture may weigh, and the most pixels it may
    /// unpack to: a small file can claim to be enormous, and it is this
    /// process that would decode it.
    private static let largestImage = 50_000_000
    private static let mostPixels = 100_000_000

    /// The menu itself, popped where the pointer already is — the click that
    /// asked for this one happened a moment ago, in JavaScript, with no
    /// native event left to hang an NSMenu off of.
    func showImageMenu(for tab: Tab, at url: URL) {
        guard let webView = tab.built else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        pictureItems(for: tab, at: url).forEach(menu.addItem)

        let screen = NSEvent.mouseLocation
        guard let window = webView.window else { return }
        let atWindow = window.convertPoint(fromScreen: screen)
        let atView = webView.convert(atWindow, from: nil)
        menu.popUp(positioning: nil, at: atView, in: webView)
    }

    /// The picture menu's items: in a menu of their own (showImageMenu), or
    /// in place of WebKit's over a picture that is no link (PageView).
    func pictureItems(for tab: Tab, at url: URL) -> [NSMenuItem] {
        guard let webView = tab.built else { return [] }
        let menu = NSMenu()
        menu.addItem(ImageMenuItem("Open Image in New Tab") { [weak self] in
            self?.open(url, foreground: true, from: tab)
        })
        // As a link's menu has it: the picture beside its page (idea 474).
        // Only from a tab in the row, which a pair can be made with, and
        // only an address a tab can show again.
        if prefs.splitView, !tab.bench, tabs.contains(where: { $0.id == tab.id }),
           ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            menu.addItem(ImageMenuItem("Open Image in Split View") { [weak self] in
                self?.openLinkBeside(url, from: tab)
            })
        }
        menu.addItem(.separator())
        menu.addItem(ImageMenuItem("Copy Image") { [weak self] in
            self?.copyImage(at: url, in: tab)
        })
        menu.addItem(ImageMenuItem("Download Image") { [weak self] in
            self?.downloadImage(at: url, from: webView)
        })
        menu.addItem(.separator())
        menu.addItem(ImageMenuItem("Copy Image Address") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
        })
        let items = menu.items
        menu.removeAllItems()
        return items
    }

    /// Fetched once, written as an actual image rather than a reference to
    /// one — an NSImage hands a receiving app real bytes to choose from
    /// (TIFF, PNG, whatever it asks for), which is the thing a pasteboard
    /// promise doesn't always give it back on a paste.
    func copyImage(at url: URL, in tab: Tab) {
        Task {
            guard let data = await imageData(at: url, in: tab), Browser.reasonable(data), let image = NSImage(data: data) else {
                announce("Couldn't copy that image")
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([image])
            announce("Image copied")
        }
    }

    /// The picture's bytes. Fetched without a cache on disk: it may be a
    /// private tab's, and a copy is not a visit. A blob: picture — the ones
    /// WhatsApp Web shows — exists only inside the page that made it, where
    /// no URLSession can reach: it is read there, in Search's own world, in
    /// the frame it was right-clicked in (idea 179).
    func imageData(at url: URL, in tab: Tab) async -> Data? {
        guard url.scheme?.lowercased() == "blob" else {
            return await ImageFetch(url, limit: Browser.largestImage).data(over: Browser.fetcher)
        }
        guard let web = tab.built else { return nil }
        let read = """
        const found = await fetch(src);
        const blob = await found.blob();
        if (!blob.type.startsWith("image/") || blob.size > 50000000) return null;
        const bytes = new Uint8Array(await blob.arrayBuffer());
        let text = "";
        for (let i = 0; i < bytes.length; i += 32768) text += String.fromCharCode.apply(null, bytes.subarray(i, i + 32768));
        return btoa(text);
        """
        let frame = tab.imageFrame
        let answer: Any? = await withCheckedContinuation { done in
            web.callAsyncJavaScript(read, arguments: ["src": url.absoluteString], in: frame, in: Web.world) { result in
                done.resume(returning: try? result.get())
            }
        }
        return (answer as? String).flatMap { Data(base64Encoded: $0) }
    }

    /// A picture this process may decode: one of its frames at most
    /// `mostPixels`, read from its header before anything is unpacked.
    nonisolated static func reasonable(_ data: Data) -> Bool {
        guard data.count <= largestImage,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return false }
        let w = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        return w > 0 && h > 0 && w * h <= mostPixels
    }

    /// The same WKDownload this app already knows how to finish — asked for
    /// directly, since a context menu's "Download Image" never reaches
    /// WKNavigationDelegate to ask for one on its own.
    func downloadImage(at url: URL, from webView: WKWebView) {
        webView.startDownload(using: URLRequest(url: url)) { [weak self] download in
            self?.keep(download)
        }
    }
}

/// A menu item that runs a closure. NSMenuItem wants a target and a
/// selector; being both itself is simpler here than a second object to
/// keep alive alongside it.
private final class ImageMenuItem: NSMenuItem {
    private let act: () -> Void

    init(_ title: String, act: @escaping () -> Void) {
        self.act = act
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { act() }
}

/// One picture's bytes, read as they come in and let go of past the limit.
/// Taken in the pieces the network hands over: reading them a byte at a time
/// (URLSession's `bytes`) took twenty seconds for a 3 MB picture, which is
/// what Copy Image waited on.
private final class ImageFetch: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let url: URL
    private let limit: Int
    private var received = Data()
    private var done: CheckedContinuation<Data?, Never>?

    init(_ url: URL, limit: Int) {
        self.url = url
        self.limit = limit
    }

    func data(over session: URLSession) async -> Data? {
        await withCheckedContinuation { continuation in
            done = continuation
            let task = session.dataTask(with: url)
            task.delegate = self
            task.resume()
        }
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let fine = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? true
        completionHandler(fine && response.expectedContentLength <= Int64(limit) ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        received.append(data)
        if received.count > limit {
            received = Data()
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        done?.resume(returning: error == nil && !received.isEmpty ? received : nil)
        done = nil
    }
}
