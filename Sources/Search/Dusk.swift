import AppKit
import WebKit

// Dark pages for sites that have no dark look of their own.
//
// A site that answers prefers-color-scheme already goes dark with the frame
// (see Tab.build), so this is only for the ones that stay white. WebKit has
// no switch for it: Chromium darkens as it paints, and the paint-time filter
// Mail uses (-apple-color-filter) isn't parsed in a web view, flag or no
// flag (macOS 27.2). So a page is darkened in its own colours: each rule of
// its that sets one gets a dark twin (DuskColours.swift), and pictures are
// never touched. The twins take a moment to make, and until they are ready,
// or on a Mac whose WebKit can't do relative colours (before macOS 15), the
// page is turned over with a CSS filter on its root and the pictures on it
// are turned back.
//
// Whether a site needs it is measured, never read off what the site says:
// plenty declare `color-scheme: light dark` and only mean their form
// controls, and plenty more keep a dark theme behind a setting of their own.
// The page's colours are sampled across the screen just before its first
// frame, and again whenever it changes its theme; a site already dark is
// left alone. The filter changes no computed colour, and the twins are set
// aside while it looks, so the measuring always sees the site's own colours.
//
// On unless turned off in Settings › Appearance, and only ever while the
// frame is dark. ⇧⌘D turns it off, or on, for the site you're on, and is
// kept; ⌥⇧⌘D pauses it everywhere until pressed again or Search quits.

@MainActor
final class Dusk: ObservableObject {
    static let shared = Dusk()

    /// Settings › Appearance. Off, pages get nothing at all.
    var on = false {
        didSet { if on != oldValue { revision += 1 } }
    }

    /// For now, not for good: forgotten when Search quits.
    @Published private(set) var paused = false

    /// Bumped whenever what the open pages should show has changed, for
    /// every window to pass on to its tabs.
    @Published private(set) var revision = 0

    /// The sites someone switched against what was measured: darkened on a
    /// site that measured dark, or left alone on one that measured light.
    /// A choice that agrees with the measuring isn't kept.
    private(set) var sites: [String: Bool] = Store.settings.dictionary(forKey: "dusk.sites") as? [String: Bool] ?? [:]

    /// What each site measured this session: true, dark by itself. Only so a
    /// site's next page can be darkened before its first frame rather than
    /// just after it. Never written down: kept, it would be a list of every
    /// site visited, outside History and its Clear.
    private var seen: [String: Bool] = [:]

    var active: Bool { on && !paused }

    /// Pages take the window's appearance, and the window the app's.
    static var frameIsDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// The same host the hidden elements are kept by: no www.
    static func host(of url: URL?) -> String? {
        guard let url, ["http", "https"].contains(url.scheme?.lowercased()),
              let host = url.host()?.lowercased(), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    func pause(_ paused: Bool) {
        guard self.paused != paused else { return }
        self.paused = paused
        revision += 1
    }

    /// `native`: what the page measured, true for dark by itself, nil when it
    /// hasn't been measured yet (it is then taken for light, which is what
    /// gets it darkened).
    func choose(_ darkened: Bool, for host: String, native: Bool?) {
        let measured = !(native ?? false)
        if darkened == measured { sites[host] = nil } else { sites[host] = darkened }
        Store.settings.set(sites, forKey: "dusk.sites")
        revision += 1
    }

    func saw(_ host: String, dark: Bool) {
        seen[host] = dark
    }

    /// A page's darkening changed; the View menu's line says so.
    func heard() { objectWillChange.send() }

    /// For each new document, or nil while off or paused: then nothing is
    /// put into pages at all.
    var script: String? {
        active ? Dusk.page(config) : nil
    }

    /// For a page already up: taking it over, or letting it go, now.
    var update: String {
        Dusk.page(config)
    }

    private var config: String {
        // "filter" keeps a page to the filter even where the browser can do
        // colours: for comparing the two, set by hand.
        let mode = Store.settings.string(forKey: "dusk.mode") ?? "colours"
        let config: [String: Any] = ["on": active, "sites": sites, "seen": seen, "mode": mode]
        guard let data = try? JSONSerialization.data(withJSONObject: config),
              let json = String(data: data, encoding: .utf8) else { return "{\"on\":false,\"sites\":{},\"seen\":{}}" }
        return json
    }

    private static func page(_ config: String) -> String {
        "(\(whole))(\(config));"
    }

    /// The page script with the colour engine in its place (see DuskColours.swift).
    private static let whole = script.replacingOccurrences(of: DuskColours.slot, with: DuskColours.engine)

    /// The shade under the page, where a scroll past its end shows: the
    /// white a light page left there, turned over as the filter turns it.
    static let underPage = NSColor(srgbRed: 0.09, green: 0.09, blue: 0.09, alpha: 1)

    /// Where the page script lives, run as a function of its settings. One
    /// per main frame: a frame inside is turned over with its page, except
    /// for the ones turned back with the pictures.
    ///
    /// A page is darkened in its own colours where the browser can (see
    /// DuskColours.swift), and by the filter until they are ready, or where
    /// it can't. The page is filtered `invert hue-rotate contrast`; what is turned back
    /// is filtered by the exact reverse, in reverse order, so a photo comes
    /// out as it went in. The contrast of .85 is what keeps white from going
    /// to pure black and black text from going to pure white.
    static let script = #"""
    function (config) {
      if (window.top !== window) return;
      if (window.__officeDusk) { window.__officeDusk.update(config); return; }
      if (!config.on) return;

      var doc = document, root = doc.documentElement;
      var scheme = matchMedia('(prefers-color-scheme: dark)');
      var host = location.hostname.toLowerCase().replace(/^www\./, '');
      // true: dark by itself. false: light. undefined: not measured yet.
      var native = config.seen[host];
      var shown = false, told = null, ground = '#fff';

      // What is kept as the site made it: the pictures, and what the page
      // marks as good as one (see scan).
      var KEEP = 'data-office-dusk';
      var pictures = 'img, video, picture, canvas, embed, object, iframe, [style*="url("], [' + KEEP + ']';
      var turned = '@media screen {'
        + 'html { filter: invert(1) hue-rotate(180deg) contrast(.85) !important; color-scheme: light !important; }'
        + ':is(' + pictures + '):not(:is(' + pictures + ') *) { filter: contrast(1.1765) hue-rotate(180deg) invert(1) !important; }'
        + 'html:has(:fullscreen), html:has(:fullscreen) :is(' + pictures + ') { filter: none !important; }'
        + '}';
      var sheet = new CSSStyleSheet();
      // The page in its own colours, made dark: null where the browser
      // can't, or where it is kept to the filter by hand.
      var paint = config.mode === 'filter' ? null : (/*COLOURS*/)(doc, [sheet]);
      // Whether the filter is what shows now: until the colours are ready,
      // and on its own without them.
      var filtering = false;

      // A sheet of the document's own rather than an element in it: nothing
      // for a page's framework to find in its markup and take out again.
      var attach = function () {
        if (doc.adoptedStyleSheets.indexOf(sheet) < 0) doc.adoptedStyleSheets = doc.adoptedStyleSheets.concat([sheet]);
      };

      var wanted = function () {
        var chosen = config.sites[host];
        if (!config.on || !scheme.matches || chosen === false) return false;
        return chosen === true || native === false;
      };

      var tell = function () {
        var now = [native === true, native !== undefined, shown].join();
        if (now === told) return;
        told = now;
        try {
          webkit.messageHandlers.officeDusk.postMessage({ dark: native === true, known: native !== undefined, on: shown });
        } catch (e) {}
      };

      var apply = function () {
        var was = shown;
        shown = wanted();
        attach();
        // The colours once they are ready; the filter before, from the first
        // frame, so the page is never seen white while they are made. Both
        // change here, in one go, so no frame falls between them.
        var painted = shown && !!paint && paint.ready();
        filtering = shown && !painted;
        // The ground a page left transparent is the canvas's, which the
        // filter on the root doesn't reach: it is given the page's own, so
        // that it turns over with the rest.
        sheet.replaceSync(filtering ? turned + '@media screen { html { background-color: ' + ground + ' !important; } }' : '');
        if (paint) paint.show(painted);
        if (shown && paint && !paint.started() && ready()) paint.start(apply);
        // Once, and again whenever it is darkened anew: what came while it
        // wasn't was never looked at.
        if (shown && ready() && (!scanned || !was || scannedFor !== filtering)) everything();
        tell();
      };

      // Any colour the page can name, lab() and oklch() included, as sRGB:
      // drawn once into a pixel and read back.
      var pixel = doc.createElement('canvas');
      pixel.width = pixel.height = 1;
      var pen = pixel.getContext('2d', { willReadFrequently: true });
      var colours = {};
      var rgba = function (colour) {
        if (colours[colour]) return colours[colour];
        pen.clearRect(0, 0, 1, 1);
        pen.fillStyle = 'rgba(0, 0, 0, 0)';
        pen.fillStyle = colour;
        pen.fillRect(0, 0, 1, 1);
        var d = pen.getImageData(0, 0, 1, 1).data;
        return (colours[colour] = [d[0], d[1], d[2], d[3] / 255]);
      };
      var linear = function (c) { c /= 255; return c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4); };
      // true, light; false, dark; null, not enough of a colour to say.
      var light = function (colour) {
        var p = rgba(colour);
        if (p[3] < 0.5) return null;
        return 0.2126 * linear(p[0]) + 0.7152 * linear(p[1]) + 0.0722 * linear(p[2]) > 0.35;
      };
      var opaque = function (colour) { return rgba(colour)[3] >= 0.5; };

      // What shows where nothing on the page has a ground of its own. The
      // one reading the sheet can change: it sets the root's ground and its
      // scheme while the page is darkened.
      var fellThrough = false;
      var canvas = function () {
        fellThrough = true;
        var top = getComputedStyle(root).backgroundColor;
        if (opaque(top)) return light(top);
        if (doc.body) {
          var body = getComputedStyle(doc.body).backgroundColor;
          if (opaque(body)) return light(body);
        }
        var meta = doc.querySelector('meta[name="color-scheme"]');
        var says = getComputedStyle(root).colorScheme + ' ' + (meta ? meta.content : '');
        return !(scheme.matches && /dark/.test(says));
      };

      var at = function (x, y) {
        var under = doc.elementsFromPoint(x, y);
        for (var i = 0; i < under.length; i++) {
          if (under[i] === root) break;
          var said = light(getComputedStyle(under[i]).backgroundColor);
          if (said !== null) return said;
        }
        return canvas();
      };

      // Nine points across the screen; dark by itself when most are dark.
      // Before the next frame is drawn, so nothing flickers.
      var sample = function () {
        var w = innerWidth, h = innerHeight, lit = 0, n = 0;
        fellThrough = false;
        [1 / 6, 1 / 2, 5 / 6].forEach(function (fy) {
          [1 / 6, 1 / 2, 5 / 6].forEach(function (fx) {
            n++;
            if (at(w * fx, h * fy)) lit++;
          });
        });
        return lit * 2 < n;
      };
      // The sheet only changes what the page's root reads, so it is set
      // aside, and the page's style worked out twice over, only when a point
      // came down to the root. While a page loads this runs every frame it
      // changes in, and most pages have a ground of their own under every
      // point.
      var measure = function () {
        // The colours change every colour on the page: read with them set
        // aside, always.
        if (paint && paint.showing()) return paint.aside(measureOwn);
        measureOwn();
      };
      var measureOwn = function () {
        var dark = sample();
        if (fellThrough || !filtering) {
          sheet.disabled = true;
          dark = sample();
          var top = getComputedStyle(root).backgroundColor;
          var body = doc.body ? getComputedStyle(doc.body).backgroundColor : '';
          ground = opaque(top) ? top : (body && opaque(body) ? body : '#fff');
          sheet.disabled = false;
        }
        native = dark;
      };

      // A light page is rarely light all over. Three things on it are kept
      // as the site made them, since turning them over is what breaks it:
      //
      // - A dark part: a bar, a footer, a button with a ground of its own
      //   that isn't light. Turned over, a dark bar goes pale and the white
      //   logo on it goes black.
      // - A photo drawn as a background from a stylesheet, which the
      //   selector can't see: turned over, its people are negatives. Not a
      //   small one, which is an icon in a sprite and goes with the text.
      // - A picture's frame: the box a picture all but fills, with whatever
      //   is written over it, so a headline on a photo keeps its colour.
      //
      // Each is marked where it is found; the sheet turns back only the
      // outermost of what is marked, so one inside another is left be.
      var photo = 32, big = 150 * 100;
      var tags = { IMG: 1, VIDEO: 1, PICTURE: 1, CANVAS: 1, IFRAME: 1, EMBED: 1, OBJECT: 1 };
      var skip = { SCRIPT: 1, STYLE: 1, NOSCRIPT: 1, TEMPLATE: 1, svg: 1, HEAD: 1, LINK: 1, META: 1 };
      var frame = function (el) {
        var r = el.getBoundingClientRect(), area = r.width * r.height;
        if (area < big) return el;
        var found = el;
        for (var p = el.parentElement; p && p !== doc.body && p !== root; p = p.parentElement) {
          var q = p.getBoundingClientRect();
          if (q.width * q.height * 0.85 > area || q.height > innerHeight * 1.5) break;
          found = p;
        }
        return found;
      };
      // Whether a background drawn from a stylesheet is a photo rather than
      // an icon: by how big it is drawn, not how big its box is. A select's
      // chevron sits in a box 200 wide and is an icon all the same. At its
      // own size (auto) it can't be told without loading it, and only a
      // large box is taken for a photo. A form control's is always an icon.
      var controls = { INPUT: 1, SELECT: 1, BUTTON: 1, TEXTAREA: 1 };
      var photoIn = function (el, style) {
        if (controls[el.tagName] || style.backgroundImage.indexOf('url(') < 0) return false;
        var w = el.offsetWidth, h = el.offsetHeight;
        if (w < photo || h < photo) return false;
        var size = style.backgroundSize.split(',')[0].trim();
        if (/cover|contain/.test(size)) return true;
        var parts = size.split(/\s+/), box = [w, h], given = false, fills = true;
        for (var i = 0; i < parts.length && i < 2; i++) {
          if (parts[i] === 'auto') continue;
          given = true;
          var n = parseFloat(parts[i]);
          if ((parts[i].indexOf('%') > 0 ? n / 100 : n / box[i]) < 0.5) fills = false;
        }
        return given ? fills : w * h >= 300 * 150;
      };
      // Under the filter, "picture" for a picture's frame or a photo and
      // "dark" for a dark part, both turned back whole.
      var mark = function (el, kind) { if (!el.hasAttribute(KEEP)) el.setAttribute(KEEP, kind || 'picture'); };
      // In the colours, only what is laid over a picture keeps the site's
      // own (DuskColours.swift): the writing and the buttons on it, found by
      // where they are drawn. A frame can't stand for them there: a caption
      // under a photo, in the same link, is the page's and goes light.
      var OVER = 'data-office-dusk-over';
      var over = function (pic) {
        var r = pic.getBoundingClientRect(), area = r.width * r.height;
        if (area < big) return;
        // Near the picture: the few boxes around it no more than three
        // times its size, where what is written on it lives.
        var scope = pic;
        for (var up = 0; up < 4 && scope.parentElement && scope.parentElement !== doc.body; up++) {
          var q = scope.parentElement.getBoundingClientRect();
          if (q.width * q.height > area * 3) break;
          scope = scope.parentElement;
        }
        var near = scope.querySelectorAll('*');
        for (var i = 0; i < near.length && i < 300; i++) {
          var el = near[i];
          if (el === pic || el.contains(pic) || el.hasAttribute(OVER) || skip[el.tagName]) continue;
          var own = el.tagName === 'IMG';
          for (var t = el.firstChild; t && !own; t = t.nextSibling) own = t.nodeType === 3 && /\S/.test(t.data);
          if (!own && !opaque(getComputedStyle(el).backgroundColor)) continue;
          var b = el.getBoundingClientRect(), mine = b.width * b.height;
          var w = Math.min(r.right, b.right) - Math.max(r.left, b.left), h = Math.min(r.bottom, b.bottom) - Math.max(r.top, b.top);
          if (mine > 0 && w > 0 && h > 0 && w * h >= mine * 0.5) el.setAttribute(OVER, '');
        }
      };
      var picture = function (el, photo) {
        if (!filtering) return over(el);
        var f = frame(el);
        if (f !== el || photo) mark(f);
      };
      var look = function (el) {
        if (skip[el.tagName] || el.hasAttribute(filtering ? KEEP : OVER)) return NodeFilter.FILTER_REJECT;
        if (tags[el.tagName]) {
          picture(el, false);
          return NodeFilter.FILTER_REJECT;
        }
        var style = getComputedStyle(el);
        if (photoIn(el, style)) {
          picture(el, true);
          // What is inside a photo is looked at in its own right in the
          // colours: another picture within it, say.
          return filtering ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_SKIP;
        }
        if (filtering && light(style.backgroundColor) === false) {
          mark(el, 'dark');
          return NodeFilter.FILTER_REJECT;
        }
        return NodeFilter.FILTER_SKIP;
      };
      var scan = function (top) {
        if (!top || top.nodeType !== 1 || filtering && top.closest('[' + KEEP + ']')) return;
        if (look(top) !== NodeFilter.FILTER_SKIP) return;
        var walker = doc.createTreeWalker(top, NodeFilter.SHOW_ELEMENT, { acceptNode: look });
        while (walker.nextNode()) {}
      };
      // The whole page, while it is darkened: when it first has its look,
      // at its load, and a moment after for what came late. Then only
      // what is added, as it is added, before it is drawn.
      var passes = 0, spent = 0, scanned = false, scannedFor = null;
      var everything = function () {
        var t = performance.now();
        scan(doc.body);
        spent += performance.now() - t;
        passes++;
        scanned = true;
        scannedFor = filtering;
      };
      new MutationObserver(function (records) {
        if (!shown || !scanned) return;
        var t = performance.now();
        records.forEach(function (r) {
          for (var i = 0; i < r.addedNodes.length; i++) scan(r.addedNodes[i]);
        });
        spent += performance.now() - t;
      }).observe(root, { childList: true, subtree: true });
      // A picture that comes in late has no size until it loads, and its
      // frame is only found then.
      doc.addEventListener('load', function (e) {
        var el = e.target;
        if (shown && scanned && el.tagName === 'IMG' && !(filtering && el.closest('[' + KEEP + ']'))) picture(el, false);
      }, true);
      addEventListener('load', function () {
        if (shown) everything();
        setTimeout(function () { if (shown) everything(); }, 2000);
      });

      // A page is ready to be read once it has a body and the stylesheets in
      // its head have come; before that, what it shows is not its look.
      var ready = function () {
        if (!doc.body) return false;
        if (doc.readyState !== 'loading') return true;
        var links = doc.querySelectorAll('link[rel~="stylesheet"]');
        for (var i = 0; i < links.length; i++) if (!links[i].sheet && !links[i].disabled) return false;
        return true;
      };

      // In the next frame, before it is drawn: a page on screen is measured
      // and darkened with nothing seen in between. A page in the background
      // gets no frames until it is shown, so a timer stands in, and a tab
      // opened behind this one is already right when you go to it.
      var waiting = false, watchedBody = null;
      var soon = function () {
        if (waiting) return;
        waiting = true;
        var frame = 0, timer = 0;
        var go = function () {
          cancelAnimationFrame(frame);
          clearTimeout(timer);
          if (!waiting) return;
          step();
        };
        frame = requestAnimationFrame(go);
        timer = setTimeout(go, 100);
      };
      var step = function () {
        waiting = false;
        if (!ready()) { soon(); return; }
        if (doc.body !== watchedBody) {
          watchedBody = doc.body;
          themes.observe(watchedBody, { attributes: true, attributeFilter: ['class', 'style', 'data-theme', 'data-color-mode', 'data-mode'] });
        }
        if (!config.on || !scheme.matches) { apply(); return; }
        measure();
        apply();
      };

      // A theme switched by the site itself: a class, a style or a data-
      // attribute on <html> or <body>. Watched for as long as the page is up.
      var themes = new MutationObserver(soon);
      themes.observe(root, { attributes: true, attributeFilter: ['class', 'style', 'data-theme', 'data-color-mode', 'data-mode'] });
      // And a page that draws itself after it loads, as an app does: its
      // look is only there once it has drawn. Watched until a few seconds
      // after the load, when it has.
      var growing = new MutationObserver(soon);
      growing.observe(root, { childList: true, subtree: true });
      addEventListener('load', function () {
        soon();
        setTimeout(function () { growing.disconnect(); }, 3000);
      });
      // A page whose load never comes (a stream, a request left hanging).
      setTimeout(function () { growing.disconnect(); }, 15000);
      doc.addEventListener('DOMContentLoaded', soon);
      // A change of look or of settings is taken at once, frame or no frame:
      // a tab in the background gets none until it is shown, and should be
      // right when it is. The measuring after can wait for one.
      scheme.addEventListener('change', function () { apply(); soon(); });

      window.__officeDusk = {
        update: function (next) { config = next; apply(); soon(); },
        // A private tab's ⇧⌘D: this page only, kept nowhere.
        force: function (on) { config.sites[host] = on; apply(); },
        state: function () {
          return { native: native, shown: shown, mode: !shown ? 'none' : filtering ? 'filter' : 'colours',
                   kept: doc.querySelectorAll('[' + KEEP + ']').length, passes: passes, ms: Math.round(spent),
                   colours: paint ? paint.stats() : null };
        }
      };

      // A site known to be light is darkened before anything is drawn; the
      // measuring after only confirms it.
      if (wanted()) apply();
      soon();
    }
    """#
}

/// A page saying whether it is darkened, and what it measured.
final class DuskRelay: NSObject, WKScriptMessageHandler {
    static let name = "officeDusk"

    weak var tab: Tab?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let said = message.body as? [String: Any] else { return }
        MainActor.assumeIsolated {
            guard let tab, let web = tab.built, web === message.webView else { return }
            let on = said["on"] as? Bool ?? false
            let dark = said["dark"] as? Bool ?? false
            if said["known"] as? Bool == true {
                tab.duskNative = dark
                // A private tab remembers nothing, not even this.
                if !tab.shy, let host = Dusk.host(of: web.url) { Dusk.shared.saw(host, dark: dark) }
            }
            if tab.dusked != on {
                tab.dusked = on
                Dusk.shared.heard()
            }
            web.underPageBackgroundColor = on ? Dusk.underPage : nil
        }
    }
}
