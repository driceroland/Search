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
      document.addEventListener('contextmenu', function (e) {
        // A right-click of yours only: a page can dispatch one itself, and
        // would open this menu whenever it liked — under your next click.
        if (!e.isTrusted) return;
        var el = e.target;
        while (el && el.tagName !== 'IMG') el = el.parentElement;
        if (!el || !el.currentSrc || el.naturalWidth < 2) return;
        // Only an address this menu will act on takes WebKit's own menu
        // away; any other scheme keeps it, rather than getting nothing.
        if (!/^(https?|data|blob):/i.test(el.currentSrc)) return;
        // WebKit's own menu only steps aside when there is a way to ask for
        // this one — otherwise a right-click shows nothing at all.
        var relay = window.webkit && webkit.messageHandlers && webkit.messageHandlers.officeImages;
        if (!relay) return;
        e.preventDefault();
        relay.postMessage({ src: el.currentSrc });
      }, true);
    })();
    """

    func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
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
            tab.onImageMenu?(tab, url)
        }
    }
}

extension Browser {
    /// For Copy Image: no cookies at all — not kept, not sent, not shared
    /// between a normal tab's copy and a private one's — nothing cached.
    static let fetcher: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration)
    }()

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
        menu.addItem(ImageMenuItem(L("Open Image in New Tab")) { [weak self] in
            self?.open(url, foreground: true, from: tab)
        })
        menu.addItem(.separator())
        menu.addItem(ImageMenuItem(L("Copy Image")) { [weak self] in
            self?.copyImage(at: url, in: tab)
        })
        menu.addItem(ImageMenuItem(L("Download Image")) { [weak self] in
            self?.downloadImage(at: url, from: webView)
        })
        menu.addItem(.separator())
        menu.addItem(ImageMenuItem(L("Copy Image Address")) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
        })

        let screen = NSEvent.mouseLocation
        guard let window = webView.window else { return }
        let atWindow = window.convertPoint(fromScreen: screen)
        let atView = webView.convert(atWindow, from: nil)
        menu.popUp(positioning: nil, at: atView, in: webView)
    }

    /// Fetched once, written as an actual image rather than a reference to
    /// one — an NSImage hands a receiving app real bytes to choose from
    /// (TIFF, PNG, whatever it asks for), which is the thing a pasteboard
    /// promise doesn't always give it back on a paste.
    func copyImage(at url: URL, in tab: Tab) {
        Task {
            guard let data = await imageData(at: url, in: tab), Browser.reasonable(data), let image = NSImage(data: data) else {
                announce(L("Couldn't copy that image"))
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([image])
            announce(L("Image copied"))
        }
    }

    /// The picture's bytes. Fetched without a cache on disk: it may be a
    /// private tab's, and a copy is not a visit. A blob: picture — the ones
    /// WhatsApp Web shows — exists only inside the page that made it, where
    /// no URLSession can reach: it is read there, in Search's own world, in
    /// the frame it was right-clicked in (idea 179).
    func imageData(at url: URL, in tab: Tab) async -> Data? {
        guard url.scheme?.lowercased() == "blob" else {
            // Read as it comes, and let go past the limit.
            guard let (bytes, response) = try? await Browser.fetcher.bytes(from: url),
                  (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
                  response.expectedContentLength <= Int64(Browser.largestImage)
            else { return nil }
            var data = Data()
            do {
                for try await byte in bytes {
                    data.append(byte)
                    if data.count > Browser.largestImage { return nil }
                }
            } catch { return nil }
            return data
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
