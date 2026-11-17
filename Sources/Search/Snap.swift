import AppKit
import WebKit

// Capture… (View menu, with Settings › Browsing › Pages › Capture pages on):
// a picture of part of the page, as Arc's Capture takes one.
//
// One light layer over the page, and three ways out of it: drag across an
// area, click an element — outlined under the pointer as Hide Elements
// outlines it — or press Whole Page. Escape, or the command again, and
// nothing is taken. The layer is gone before WebKit draws the picture, so
// it is never in it. The picture goes on this Mac's clipboard (not to your
// other devices') and into your downloads folder as a PNG, and that is all:
// nothing is sent anywhere, and from a private tab nothing else is kept —
// its copy is marked so clipboard managers leave it out of their history.

/// The arithmetic of a capture, apart from any page or screen: what the
/// page said it chose, in its CSS pixels, turned into the rectangle WebKit
/// draws in the web view's points, and how big a picture that makes.
enum SnapGeometry {
    /// What the layer in the page answers with.
    struct Choice: Equatable {
        enum Kind: String { case area, element, page }

        let kind: Kind
        /// Where it is in the page's viewport, in CSS pixels. Unused for a
        /// whole page, which is `document` from its top-left corner.
        var rect: CGRect = .zero
        /// How far the page is scrolled.
        var scroll: CGPoint = .zero
        /// The page's full size.
        var document: CGSize = .zero
        /// Where the visual viewport sits in the layout one, and its scale:
        /// a pinch zoom (WKWebView.magnification) moves and scales it.
        var offset: CGPoint = .zero
        var scale: CGFloat = 1

        init(kind: Kind, rect: CGRect = .zero, scroll: CGPoint = .zero, document: CGSize = .zero,
             offset: CGPoint = .zero, scale: CGFloat = 1) {
            self.kind = kind
            self.rect = rect
            self.scroll = scroll
            self.document = document
            self.offset = offset
            self.scale = scale
        }

        /// As the page posts it. Nil for anything else, a cancel included.
        init?(_ value: Any?) {
            guard let found = value as? [String: Any],
                  let kind = (found["kind"] as? String).flatMap(Kind.init) else { return nil }
            func number(_ key: String) -> CGFloat {
                (found[key] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0
            }
            self.init(kind: kind,
                      rect: CGRect(x: number("x"), y: number("y"), width: number("w"), height: number("h")),
                      scroll: CGPoint(x: number("sx"), y: number("sy")),
                      document: CGSize(width: number("dw"), height: number("dh")),
                      offset: CGPoint(x: number("vx"), y: number("vy")),
                      scale: number("vs") > 0 ? number("vs") : 1)
        }
    }

    /// What to ask WebKit for.
    struct Plan: Equatable {
        /// In the web view's points, from its top-left corner. Off the
        /// visible part where the page goes on: WebKit paints that too.
        let rect: CGRect
        /// The picture's width in points, when it isn't `rect`'s: a whole
        /// page at its own size whatever the pinch zoom, or a picture too
        /// big to hold made smaller.
        let width: CGFloat?
        /// A page taller than `tallest` points: its top only.
        let cropped: Bool
    }

    /// The tallest picture taken, in points: past it, a page that keeps
    /// loading more as it is scrolled has no end.
    static let tallest: CGFloat = 30_000
    /// The most pixels a picture may have, about 256 MB as WebKit draws it.
    static let budget: CGFloat = 64_000_000

    /// The page, from its top-left corner, in the viewport's CSS pixels.
    static func page(_ choice: Choice) -> CGRect {
        CGRect(origin: CGPoint(x: -choice.scroll.x, y: -choice.scroll.y), size: choice.document)
    }

    /// CSS pixels in the viewport to the web view's points: the pinch zoom
    /// moves and scales the visual viewport, and page zoom (⌘+) makes each
    /// CSS pixel bigger.
    static func view(_ css: CGRect, _ choice: Choice, zoom: CGFloat) -> CGRect {
        let factor = choice.scale * zoom
        return CGRect(x: (css.minX - choice.offset.x) * factor, y: (css.minY - choice.offset.y) * factor,
                      width: css.width * factor, height: css.height * factor)
    }

    /// Nil when there is nothing there to take: a click on nothing, an
    /// area dragged off the page.
    static func plan(_ choice: Choice, zoom: CGFloat, backing: CGFloat,
                     tallest: CGFloat = SnapGeometry.tallest, budget: CGFloat = SnapGeometry.budget) -> Plan? {
        let page = page(choice)
        // A page that says it has no size is its viewport.
        let bounds = page.width > 0 && page.height > 0 ? page : choice.rect
        let css = choice.kind == .page ? bounds : choice.rect.intersection(bounds)
        guard !css.isNull, css.width >= 2, css.height >= 2 else { return nil }
        var rect = view(css, choice, zoom: zoom).integral
        guard rect.width >= 2, rect.height >= 2 else { return nil }

        // Its size with no pinch zoom: a whole page is taken at that, a part
        // as you see it.
        let pinch = max(choice.scale, 0.01)
        var cropped = false
        if rect.height / pinch > tallest {
            rect.size.height = (tallest * pinch).rounded(.down)
            cropped = true
        }
        var width = choice.kind == .page ? (rect.width / pinch).rounded() : rect.width
        let height = width / rect.width * rect.height
        let pixels = width * height * backing * backing
        if pixels > budget {
            width = (width * (budget / pixels).squareRoot()).rounded(.down)
        }
        return Plan(rect: rect, width: width == rect.width ? nil : max(width, 1), cropped: cropped)
    }

    /// "Capture 2026-11-17 at 14.03.22.png": a time, as the Mac names its
    /// own screenshots, and not the site, which a private tab's would give
    /// away in the Downloads folder.
    static func fileName(_ date: Date, in zone: TimeZone = .current) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = zone
        format.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Capture \(format.string(from: date)).png"
    }

    /// The picture as a PNG at its full resolution, tagged with its size in
    /// points so a Retina capture opens at the size it was on screen.
    static func png(_ image: NSImage) -> (png: Data, tiff: Data)? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        if image.size.width > 0, image.size.height > 0 { rep.size = image.size }
        guard let png = rep.representation(using: .png, properties: [:]), let tiff = rep.tiffRepresentation else { return nil }
        return (png, tiff)
    }

    /// On the clipboard of this Mac only — Universal Clipboard would hand it
    /// to your other devices. A private tab's is marked transient, which is
    /// what clipboard managers go by to keep it out of their history.
    static func copy(png: Data, tiff: Data, passing: Bool, to board: NSPasteboard = .general) {
        board.prepareForNewContents(with: .currentHostOnly)
        board.setData(png, forType: .png)
        board.setData(tiff, forType: .tiff)
        if passing {
            board.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        }
    }

    /// The layer over the page, in Search's own world (see Web.world), put
    /// in only when Capture… is chosen. `on(done)` raises it; `done` is
    /// handed the choice, or null when it is put away. Everything it draws
    /// is in a closed shadow root, so the page's styles never reach it, and
    /// it is taken out of the page before `done` is called.
    static let script = """
    (function () {
      if (window.__officeCapture) return;
      var host = null, frame = null, tag = null, band = null, bar = null;
      var live = false, done = null, start = null, dragging = false, target = null;

      function css(el, text) { el.style.cssText = text; return el; }

      function build() {
        host = css(document.createElement('div'),
          'all:initial;position:fixed;left:0;top:0;width:0;height:0;z-index:2147483647;pointer-events:none');
        var root = host.attachShadow({ mode: 'closed' });
        frame = css(document.createElement('div'),
          'position:fixed;pointer-events:none;border:2px solid rgba(23,23,23,.9);' +
          'background:rgba(23,23,23,.07);border-radius:4px;box-sizing:border-box;display:none');
        tag = css(document.createElement('div'),
          'position:absolute;font:500 11px -apple-system,BlinkMacSystemFont,sans-serif;color:#fff;' +
          'background:#171717;padding:2px 7px;border-radius:5px;white-space:nowrap;overflow:hidden;' +
          'text-overflow:ellipsis');
        frame.appendChild(tag);
        // The area being dragged, and everything else a shade darker.
        band = css(document.createElement('div'),
          'position:fixed;pointer-events:none;border:1px solid rgba(255,255,255,.9);' +
          'box-shadow:0 0 0 1px rgba(23,23,23,.5),0 0 0 100vmax rgba(0,0,0,.18);box-sizing:border-box;display:none');
        bar = css(document.createElement('div'),
          'position:fixed;top:12px;left:50%;transform:translateX(-50%);pointer-events:auto;' +
          'display:flex;align-items:center;gap:10px;padding:5px 5px 5px 12px;border-radius:10px;' +
          'background:rgba(23,23,23,.92);color:rgba(255,255,255,.75);cursor:default;' +
          'font:500 12px -apple-system,BlinkMacSystemFont,sans-serif;white-space:nowrap;' +
          'box-shadow:0 6px 18px rgba(0,0,0,.18)');
        var hint = document.createElement('span');
        hint.textContent = 'Drag an area or click an element';
        var whole = css(document.createElement('div'),
          'padding:4px 10px;border-radius:7px;background:#fff;color:#171717;cursor:pointer');
        whole.textContent = 'Whole Page';
        whole.setAttribute('role', 'button');
        whole.addEventListener('click', function (e) {
          e.preventDefault();
          e.stopPropagation();
          finish(pageChoice('page'));
        });
        var esc = css(document.createElement('div'),
          'padding:4px 8px 4px 2px;color:rgba(255,255,255,.5);cursor:pointer');
        esc.textContent = 'esc';
        esc.addEventListener('click', function (e) { e.stopPropagation(); off(); });
        bar.appendChild(hint);
        bar.appendChild(whole);
        bar.appendChild(esc);
        root.appendChild(band);
        root.appendChild(frame);
        root.appendChild(bar);
        document.documentElement.appendChild(host);
      }

      var known = {
        nav: 'Navigation', header: 'Header', footer: 'Footer', aside: 'Sidebar', main: 'Main',
        article: 'Article', section: 'Section', form: 'Form', dialog: 'Dialog', video: 'Video',
        img: 'Image', picture: 'Image', svg: 'Graphic', canvas: 'Canvas', button: 'Button',
        iframe: 'Embed', figure: 'Figure', table: 'Table', pre: 'Code'
      };

      function name(el) {
        var said = el.getAttribute && (el.getAttribute('aria-label') || el.getAttribute('title'));
        var what = said && said.trim() ? said.trim()
                 : (known[el.tagName.toLowerCase()] || el.tagName.toLowerCase());
        if (what.length > 40) what = what.slice(0, 40) + '…';
        var r = el.getBoundingClientRect();
        return what + ' · ' + Math.round(r.width) + '×' + Math.round(r.height);
      }

      function place(el) {
        var r = el.getBoundingClientRect();
        frame.style.display = 'block';
        frame.style.left = r.left + 'px';
        frame.style.top = r.top + 'px';
        frame.style.width = r.width + 'px';
        frame.style.height = r.height + 'px';
        tag.textContent = name(el);
        tag.style.top = r.top >= 26 ? '-21px' : '3px';
        tag.style.left = Math.max(2, -r.left + 4) + 'px';
        tag.style.maxWidth = Math.max(80, window.innerWidth - Math.max(0, r.left) - 16) + 'px';
      }

      function under(x, y) {
        var el = document.elementFromPoint(x, y);
        if (!el || el === host || el === document.documentElement) return null;
        return el;
      }

      function pageChoice(kind, r) {
        var doc = document.documentElement, body = document.body;
        var vv = window.visualViewport;
        return {
          kind: kind,
          x: r ? r.left : 0, y: r ? r.top : 0, w: r ? r.width : 0, h: r ? r.height : 0,
          sx: window.scrollX, sy: window.scrollY,
          dw: Math.max(doc.scrollWidth, body ? body.scrollWidth : 0, doc.clientWidth),
          dh: Math.max(doc.scrollHeight, body ? body.scrollHeight : 0, doc.clientHeight),
          vx: vv ? vv.offsetLeft : 0, vy: vv ? vv.offsetTop : 0, vs: vv ? vv.scale : 1
        };
      }

      function ours(e) { return e.target === host; }

      function swallow(e) {
        if (!live || ours(e)) return;
        e.preventDefault();
        e.stopPropagation();
        e.stopImmediatePropagation();
      }

      function onDown(e) {
        if (!live || ours(e)) return;
        swallow(e);
        if (e.button !== 0) return;
        start = { x: e.clientX, y: e.clientY };
        dragging = false;
      }

      function onMove(e) {
        if (!live) return;
        if (start) {
          var dx = e.clientX - start.x, dy = e.clientY - start.y;
          if (!dragging && dx * dx + dy * dy < 16) return;
          dragging = true;
          frame.style.display = 'none';
          band.style.display = 'block';
          band.style.left = Math.min(start.x, e.clientX) + 'px';
          band.style.top = Math.min(start.y, e.clientY) + 'px';
          band.style.width = Math.abs(dx) + 'px';
          band.style.height = Math.abs(dy) + 'px';
          return;
        }
        if (ours(e)) { frame.style.display = 'none'; target = null; return; }
        var el = under(e.clientX, e.clientY);
        if (!el) return;
        target = el;
        place(el);
      }

      function onUp(e) {
        if (!live || !start) return;
        swallow(e);
        var from = start;
        start = null;
        if (dragging) {
          dragging = false;
          var r = {
            left: Math.min(from.x, e.clientX), top: Math.min(from.y, e.clientY),
            width: Math.abs(e.clientX - from.x), height: Math.abs(e.clientY - from.y)
          };
          if (r.width < 4 || r.height < 4) { band.style.display = 'none'; return; }
          finish(pageChoice('area', r));
          return;
        }
        var el = target || under(e.clientX, e.clientY);
        if (!el) return;
        finish(pageChoice('element', el.getBoundingClientRect()));
      }

      function onKey(e) {
        if (!live || e.key !== 'Escape') return;
        swallow(e);
        off();
      }

      var presses = ['mousedown', 'mouseup', 'click', 'dblclick', 'contextmenu', 'touchstart', 'auxclick'];

      function listen(add) {
        var how = add ? 'addEventListener' : 'removeEventListener';
        window[how]('pointerdown', onDown, true);
        window[how]('pointermove', onMove, true);
        window[how]('pointerup', onUp, true);
        window[how]('keydown', onKey, true);
        presses.forEach(function (kind) { window[how](kind, swallow, true); });
      }

      function teardown() {
        live = false;
        start = null;
        dragging = false;
        target = null;
        listen(false);
        document.documentElement.style.cursor = '';
        if (host && host.parentNode) host.parentNode.removeChild(host);
        host = null;
      }

      function finish(choice) {
        var answer = done;
        done = null;
        teardown();
        if (answer) answer(choice);
      }

      function off() { finish(null); }

      window.__officeCapture = {
        on: function (answer) {
          if (live) finish(null);
          done = answer;
          live = true;
          build();
          document.documentElement.style.cursor = 'crosshair';
          listen(true);
        },
        off: off,
        // For the bench: the three choices without a pointer.
        area: function (x, y, w, h) { finish(pageChoice('area', { left: x, top: y, width: w, height: h })); },
        element: function (x, y) {
          var el = under(x, y);
          if (el) finish(pageChoice('element', el.getBoundingClientRect()));
          else off();
        },
        page: function () { finish(pageChoice('page')); },
        live: function () { return live; }
      };
    })();
    """
}

extension Browser {
    /// Capture… in the View menu: the layer goes up over the page in
    /// front, or, if it is already up, comes down.
    func toggleSnap() {
        if snapping { return stopSnapping() }
        guard prefs.capturesPages, let tab = active, tab.isWeb else { return }
        // One pointing mode at a time.
        if veiling { toggleHiding() }
        snapping = true
        snapTab = tab
        tab.web.callInSearch(SnapGeometry.script + """

        return await new Promise(function (answer) { window.__officeCapture.on(answer); });
        """, arguments: [:]) { [weak self, weak tab] value in
            guard let self, let tab, snapTab === tab else { return }
            snapping = false
            snapTab = nil
            guard let choice = SnapGeometry.Choice(value) else { return }
            // A test run keeps out of the Mac's clipboard and Downloads.
            if Store.testing {
                let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("search-bench-snap")
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                snap(choice, in: tab, to: Browser.free(SnapGeometry.fileName(Date()), in: folder),
                     board: NSPasteboard(name: NSPasteboard.Name("search.bench.snap")))
            } else {
                snap(choice, in: tab)
            }
        }
    }

    /// Escape, another tab, or Hide Elements: the layer comes down and
    /// nothing is taken.
    func stopSnapping() {
        let tab = snapTab
        snapping = false
        snapTab = nil
        tab?.built?.evaluateInSearch("window.__officeCapture && window.__officeCapture.off()")
    }

    /// The bench's way in, past the layer: the same picture, written to
    /// `file` and copied to `board` rather than to Downloads and the Mac's
    /// clipboard.
    func snap(_ choice: SnapGeometry.Choice, in tab: Tab, to file: URL? = nil, board: NSPasteboard = .general,
              finished: (([String: Any]) -> Void)? = nil) {
        let web = tab.web
        let backing = web.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        guard let plan = SnapGeometry.plan(choice, zoom: web.pageZoom, backing: backing) else {
            announce("Nothing there to capture")
            finished?(["error": "nothing there"])
            return
        }
        let config = WKSnapshotConfiguration()
        config.rect = plan.rect
        // After the layer has gone from the screen, so it is never in it.
        config.afterScreenUpdates = true
        if let width = plan.width { config.snapshotWidth = NSNumber(value: Double(width)) }
        let passing = tab.shy
        let file = file ?? Browser.free(SnapGeometry.fileName(Date()), in: downloadsFolder)
        web.takeSnapshot(with: config) { [weak self] image, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard let image, let data = SnapGeometry.png(image) else {
                    self.announce("Couldn't capture this page")
                    finished?(["error": error?.localizedDescription ?? "no picture"])
                    return
                }
                SnapGeometry.copy(png: data.png, tiff: data.tiff, passing: passing, to: board)
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    let wrote = (try? data.png.write(to: file, options: .atomic)) != nil
                    DispatchQueue.main.async {
                        guard let self else { return }
                        let copied = plan.cropped ? "The top of the page copied" : "Copied"
                        if wrote {
                            self.announce("\(copied) and saved to \(file.deletingLastPathComponent().lastPathComponent)", file: file)
                        } else {
                            self.announce("\(copied), but couldn't save it")
                        }
                        let rep = NSBitmapImageRep(data: data.png)
                        finished?(["path": wrote ? file.path : "", "width": rep?.pixelsWide ?? 0,
                                   "height": rep?.pixelsHigh ?? 0, "points": [image.size.width, image.size.height],
                                   "rect": [plan.rect.minX, plan.rect.minY, plan.rect.width, plan.rect.height],
                                   "cropped": plan.cropped])
                    }
                }
            }
        }
    }
}
