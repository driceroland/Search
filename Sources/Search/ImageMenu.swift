import AppKit
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

    /// Every frame: an image inside an ad or a map embed is still an image.
    /// Only a genuine <img> with something to point at is worth the trip —
    /// a broken one, or a 1×1 tracking pixel, isn't worth a menu at all.
    static let watch = """
    (function () {
      if (window.__officeImages) return;
      window.__officeImages = true;
      document.addEventListener('contextmenu', function (e) {
        var el = e.target;
        while (el && el.tagName !== 'IMG') el = el.parentElement;
        if (!el || !el.currentSrc || el.naturalWidth < 2) return;
        e.preventDefault();
        window.webkit.messageHandlers.officeImages.postMessage({ src: el.currentSrc });
      }, true);
    })();
    """

    func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any],
              let src = body["src"] as? String,
              let url = URL(string: src)
        else { return }
        MainActor.assumeIsolated { [weak self] in
            guard let self, let tab else { return }
            tab.onImageMenu?(tab, url)
        }
    }
}

extension Browser {
    /// The menu itself, popped where the pointer already is — the click that
    /// asked for this one happened a moment ago, in JavaScript, with no
    /// native event left to hang an NSMenu off of.
    func showImageMenu(for tab: Tab, at url: URL) {
        guard let webView = tab.built else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(ImageMenuItem("Open Image in New Tab") { [weak self] in
            self?.open(url, foreground: true, from: tab)
        })
        menu.addItem(.separator())
        menu.addItem(ImageMenuItem("Copy Image") { [weak self] in
            self?.copyImage(at: url)
        })
        menu.addItem(ImageMenuItem("Download Image") { [weak self] in
            self?.downloadImage(at: url, from: webView)
        })
        menu.addItem(.separator())
        menu.addItem(ImageMenuItem("Copy Image Address") {
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
    func copyImage(at url: URL) {
        Task {
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = NSImage(data: data)
            else {
                announce("Couldn't copy that image")
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([image])
            announce("Image copied")
        }
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
