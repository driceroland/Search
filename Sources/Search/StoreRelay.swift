import Combine
import WebKit

// The Chrome Web Store, made to work for this browser.
//
// The store sees a browser that isn't Chrome and says so: a banner asking to
// "Switch to Chrome", and an "Add to Chrome" button that stays grey. Search
// installs from the store on its own (Extensions.install, through Crx), so on
// the store's pages the banner goes and the grey button is replaced by an
// "Add to Search" one — the button people already look for, rather than a bar
// at the bottom of the window they would have to notice. What gets installed
// is read from the tab's own address, never from anything the page says; the
// page only asks, and the usual confirmation still stands between the asking
// and the installing.

final class StoreRelay: NSObject, WKScriptMessageHandler {
    static let name = "officeStore"

    weak var tab: Tab?

    func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any] else { return }
        MainActor.assumeIsolated {
            guard let tab else { return }
            if body["add"] != nil { tab.onStoreAdd?(tab) }
            if let placed = body["placed"] as? String { tab.storePlaced = placed }
        }
    }

    /// Main frame, every page, returning at once anywhere but the store. The
    /// store's markup is generated and its class names change between
    /// releases, so nothing here leans on them: the store's own button is the
    /// disabled one that names Chrome, and the banner is the small block
    /// around the one enabled button that does — only that block, since the
    /// store puts the banner and the extension's own header, button and all,
    /// in the same section.
    static let script = """
    (function () {
      if (location.hostname !== 'chromewebstore.google.com' || window.__officeStore) return;
      var state = { installed: [], busy: null };

      function pageID() {
        var m = location.pathname.match(/\\/detail\\/(?:[^\\/]+\\/)?([a-p]{32})/);
        return m ? m[1] : null;
      }

      function theirs() {
        var buttons = document.querySelectorAll('button[disabled]');
        for (var i = 0; i < buttons.length; i++) {
          var b = buttons[i];
          if (!b.dataset.office && /chrome/i.test(b.textContent || '')) return b;
        }
        return null;
      }

      // From the banner's own button up, as far as it goes without taking in
      // the header beside it: short, and holding no install button.
      function bannerOf(button) {
        var box = null, up = button.parentElement;
        while (up && up !== document.body) {
          if (up.querySelector('button[disabled], button[data-office]')) break;
          if ((up.innerText || '').length > 160) break;
          box = up;
          up = up.parentElement;
        }
        return box;
      }

      function hideBanner() {
        // And the floating "Switch to Chrome?" card, known by the Chrome logo
        // it carries in any language — it sits right over the button.
        var cards = document.querySelectorAll('[role="dialog"]');
        for (var c = 0; c < cards.length; c++) {
          if (!cards[c].dataset.office && cards[c].querySelector('img[src*="productlogos/chrome"]')) {
            cards[c].style.display = 'none';
            cards[c].dataset.office = 'promo';
          }
        }
        var buttons = document.querySelectorAll('button:not([disabled])');
        for (var i = 0; i < buttons.length; i++) {
          var b = buttons[i];
          if (b.dataset.office || !/chrome/i.test(b.getAttribute('aria-label') || '')) continue;
          var box = bannerOf(b);
          if (box && !box.dataset.office) {
            box.style.display = 'none';
            box.dataset.office = 'banner';
          }
        }
      }

      // The words only, so the button keeps the store's own shape and colour.
      function label(button, text) {
        var walker = document.createTreeWalker(button, NodeFilter.SHOW_TEXT);
        var node, last = null;
        while ((node = walker.nextNode())) { if (node.nodeValue.trim()) last = node; }
        if (last) last.nodeValue = text; else button.textContent = text;
      }

      function render(ours) {
        var id = pageID();
        var installed = !!id && state.installed.indexOf(id) >= 0;
        var busy = !!id && state.busy === id;
        label(ours, installed ? 'Added to Search' : (busy ? 'Adding…' : 'Add to Search'));
        ours.disabled = installed || busy;
      }

      function mend() {
        hideBanner();
        if (!pageID()) return;
        var original = theirs();
        if (original && original.parentNode) {
          var ours = original.cloneNode(true);
          ['disabled', 'jsaction', 'jscontroller', 'jsname', 'jslog', 'aria-describedby'].forEach(function (name) {
            ours.removeAttribute(name);
          });
          ours.dataset.office = 'add';
          original.dataset.office = 'theirs';
          original.style.display = 'none';
          original.parentNode.insertBefore(ours, original.nextSibling);
          window.webkit.messageHandlers.officeStore.postMessage({ placed: pageID() });
        }
        renderAll();
      }

      // The store keeps the pages it has left, hidden, beside the one it shows.
      function renderAll() {
        var mine = document.querySelectorAll('button[data-office="add"]');
        for (var i = 0; i < mine.length; i++) render(mine[i]);
      }

      // Caught on the window, before the store's own handlers — which listen
      // on the document — can see the click at all.
      window.addEventListener('click', function (e) {
        var mine = e.target && e.target.closest && e.target.closest('button[data-office="add"]');
        if (!mine) return;
        e.preventDefault();
        e.stopImmediatePropagation();
        if (!mine.disabled) window.webkit.messageHandlers.officeStore.postMessage({ add: true });
      }, true);

      window.__officeStore = {
        state: function (next) {
          state = next || state;
          renderAll();
        }
      };

      // The store is one page that rewrites itself: whatever it redraws, mend
      // again. A timer rather than a frame — a tab out of sight gets no frames.
      var queued = false;
      new MutationObserver(function () {
        if (queued) return;
        queued = true;
        setTimeout(function () { queued = false; mend(); }, 60);
      }).observe(document.documentElement, { childList: true, subtree: true });
      mend();
    })();
    """
}

extension Browser {
    /// Where "Chrome Web Store…" goes: its extensions, not its themes.
    static let webStore = URL(string: "https://chromewebstore.google.com/category/extensions")!

    /// The page's "Add to Search" was pressed: the extension this tab is showing.
    func addFromStore(_ tab: Tab) {
        guard #available(macOS 15.4, *), let url = tab.address, StoreOffer.isStorePage(url) else { return }
        Extensions.shared.install(from: url.absoluteString)
    }

    /// Tells a store page what is installed and what is on its way, so its
    /// button can say "Added to Search" or "Adding…".
    func tellStore(_ tab: Tab) {
        guard #available(macOS 15.4, *), let url = tab.address, StoreOffer.isStorePage(url) else { return }
        tab.tellStore(installed: Extensions.shared.installed.map(\.id), busy: Extensions.shared.busy)
    }

    /// And tells every store page again whenever either changes.
    func followStore() {
        guard #available(macOS 15.4, *) else { return }
        let extensions = Extensions.shared
        storeWatch = extensions.$installed.map { _ in () }
            .merge(with: extensions.$busy.map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                guard let self else { return }
                for tab in allTabs where tab.built != nil { tellStore(tab) }
            }
    }
}
