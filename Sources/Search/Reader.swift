import SwiftUI

// Reading mode: the article, and nothing that was arranged around it.
//
// The hard part is deciding what the article is. The heuristic here is the old
// one and it holds up: the piece of the page carrying the most prose, punished
// for every link inside it — because navigation, related-articles rails and
// comment threads are all made of links, and prose is not.

enum Reader {
    static let script = """
    (function () {
      function prose(el) {
        var paragraphs = el.querySelectorAll('p');
        if (paragraphs.length < 2) return 0;
        var letters = 0;
        for (var i = 0; i < paragraphs.length; i++) {
          letters += (paragraphs[i].innerText || '').length;
        }
        if (letters < 400) return 0;
        // A rail of related links has plenty of text and nothing to read.
        var links = el.querySelectorAll('a').length;
        return letters / (1 + links * 14);
      }

      function best() {
        var candidates = document.querySelectorAll(
          'article, main, [role="main"], .post, .entry, .article, .content, #content, div, section'
        );
        var top = null, mark = 0;
        for (var i = 0; i < candidates.length; i++) {
          var score = prose(candidates[i]);
          if (score > mark) { mark = score; top = candidates[i]; }
        }
        return top;
      }

      // Already an article: going back can bring one as it was left, after
      // the page in between let go of reading mode (Tab.didCommit).
      if (document.getElementById('office-reader')) return 'read';

      var article = best();
      if (!article) return 'none';

      // The site's stylesheets go below, and with them whatever they hid:
      // the copies of a box a page keeps for each size of screen, of which
      // only one shows. What the page itself doesn't show is marked while it
      // still can be told, and stays out. Not when it holds paragraphs,
      // though: an article's folded-away rest is still the article.
      var every = article.querySelectorAll('*');
      for (var h = 0; h < every.length; h++) {
        var el = every[h];
        if (el.closest('svg') || /^(SOURCE|TRACK|SCRIPT|STYLE|TEMPLATE|BR|WBR)$/.test(el.tagName)) continue;
        if (getComputedStyle(el).display === 'none' && !el.querySelector('p')) el.setAttribute('data-office-gone', '');
      }
      // The size they gave a drawing in the text, an icon as often as not,
      // goes with them too: left to itself, an <svg> fills the column. The
      // size it is drawn at is written onto it, and nothing for one the page
      // doesn't show.
      var drawings = article.querySelectorAll('svg');
      for (var d = 0; d < drawings.length; d++) {
        if (drawings[d].parentElement.closest('svg')) continue;
        var drawn = drawings[d].getBoundingClientRect();
        drawings[d].setAttribute('width', Math.round(drawn.width));
        drawings[d].setAttribute('height', Math.round(drawn.height));
      }

      // Every picture is resolved while the real page is still standing.
      //
      // currentSrc is what the browser actually chose and loaded, after srcset,
      // sizes and <picture> have had their say. Reading it here and writing it
      // back as a plain src is the only way to be sure the reader shows the
      // same image the page did — copying the markup alone gets you a lazy
      // placeholder, or nothing at all.
      var late = ['data-src', 'data-original', 'data-lazy-src', 'data-lazy',
                  'data-full-src', 'data-hi-res-src', 'data-image', 'data-echo'];
      var pictures = article.querySelectorAll('img');
      for (var i = 0; i < pictures.length; i++) {
        var picture = pictures[i];
        picture.setAttribute('loading', 'eager');
        var real = picture.currentSrc || picture.getAttribute('src') || '';
        // A one-pixel placeholder counts as nothing.
        if (!real || real.indexOf('data:image') === 0 || picture.naturalWidth <= 2) {
          for (var k = 0; k < late.length; k++) {
            var kept = picture.getAttribute(late[k]);
            if (kept) { real = kept; break; }
          }
        }
        if (real) picture.setAttribute('src', real);
        var lateSet = picture.getAttribute('data-srcset');
        if (lateSet && !picture.getAttribute('srcset')) {
          picture.setAttribute('srcset', lateSet);
        }
      }

      var heading = document.querySelector('h1');
      var title = (heading && heading.innerText.trim()) || document.title;

      // Light or dark as the window is, or as chosen in the article's corner
      // (ReaderLook puts it on <html>, which the reader keeps). A page
      // follows the window it is drawn in, so with nothing chosen the
      // article goes dark with the window, and changes with it while open.
      // The dark ground is the window's own (Palette.ground); the text is a
      // shade softer than Palette.ink, there being a lot of it.
      var dark = 'color-scheme:dark;--r-ground:#1c1c1c;--r-ink:#e0e0e0;--r-quiet:#8a8a8a;' +
        '--r-aside:#a8a8a8;--r-rule:#333;--r-code:#2a2a2a;--r-picture:brightness(.92)';
      var sheet = document.createElement('style');
      sheet.textContent = [
        ':root{color-scheme:light;--r-ground:#fff;--r-ink:#171717;--r-quiet:#a3a3a3;',
        '--r-aside:#555;--r-rule:#e8e8e8;--r-code:#f5f5f5;--r-picture:none}',
        '@media (prefers-color-scheme:dark){:root:not([data-office-look=light]){' + dark + '}}',
        ':root[data-office-look=dark]{' + dark + '}',
        'html,body{background:var(--r-ground) !important;margin:0 !important;padding:0 !important}',
        '#office-reader{max-width:38em;margin:0 auto;padding:72px 24px 160px;',
        'font:400 18px/1.72 ui-serif,Georgia,"Times New Roman",serif;color:var(--r-ink)}',
        '#office-reader h1{font:600 30px/1.24 -apple-system,BlinkMacSystemFont,sans-serif;',
        'margin:0 0 8px;letter-spacing:-0.01em}',
        '#office-reader .office-from{font:400 12px/1 -apple-system,sans-serif;color:var(--r-quiet);',
        'margin:0 0 40px;text-transform:uppercase;letter-spacing:.06em}',
        '#office-reader p{margin:0 0 1.35em}',
        '#office-reader img,#office-reader video,#office-reader iframe{max-width:100%;',
        'height:auto;border-radius:6px;margin:1.6em 0;display:block}',
        // A photo, a touch dimmer on dark, so it doesn't glare.
        '#office-reader img{filter:var(--r-picture)}',
        '#office-reader iframe{width:100%;aspect-ratio:16/9;height:auto;border:0}',
        '#office-reader svg{max-width:100%}',
        '#office-reader figure{margin:1.8em 0}',
        '#office-reader figcaption{font:400 13px/1.5 -apple-system,sans-serif;',
        'color:var(--r-quiet);margin-top:.6em}',
        '#office-reader a{color:var(--r-ink);text-underline-offset:3px}',
        '#office-reader h2,#office-reader h3{font:600 20px/1.3 -apple-system,sans-serif;',
        'margin:2em 0 .6em}',
        '#office-reader pre,#office-reader code{font-family:ui-monospace,monospace;font-size:14px}',
        '#office-reader pre{background:var(--r-code);padding:14px;border-radius:8px;overflow:auto}',
        '#office-reader blockquote{margin:1.6em 0;padding-left:1.2em;',
        'border-left:2px solid var(--r-rule);color:var(--r-aside)}',
        // A colour written onto an element was picked for the site's own
        // ground, and on dark it can be all but invisible.
        '#office-reader [style]{color:inherit !important;background-color:transparent !important}'
      ].join('');

      var wrap = document.createElement('div');
      wrap.id = 'office-reader';
      wrap.innerHTML = article.innerHTML;

      // What was arranged around the words rather than being part of them.
      // Not header: an article's opening image lives there as often as not.
      var clutter = wrap.querySelectorAll(
        'script,style,noscript,form,nav,aside,footer,button,input,select,textarea,' +
        '[role="complementary"],[role="navigation"],[role="banner"],[aria-hidden="true"],' +
        '[data-office-gone]'
      );
      for (var c = 0; c < clutter.length; c++) clutter[c].remove();

      // Embedded video is part of the article; every other frame is not.
      var players = /youtube|youtu\\.be|vimeo|dailymotion|loom\\.com|streamable|wistia|ted\\.com/i;
      var frames = wrap.querySelectorAll('iframe');
      for (var f = 0; f < frames.length; f++) {
        var where = frames[f].getAttribute('src') || frames[f].getAttribute('data-src') || '';
        if (players.test(where)) {
          frames[f].setAttribute('src', where);
          frames[f].removeAttribute('height');
          frames[f].removeAttribute('width');
        } else {
          frames[f].remove();
        }
      }

      // A picture with nothing behind it is a broken icon, which is worse than
      // no picture at all.
      var kept = wrap.querySelectorAll('img');
      for (var g = 0; g < kept.length; g++) {
        var src = kept[g].getAttribute('src') || '';
        if (!src || src.indexOf('data:image') === 0) kept[g].remove();
      }

      // The article's own heading goes when it only says the title again,
      // which the reader puts on top.
      var own = wrap.querySelector('h1');
      if (own && own.textContent.replace(/\\s+/g, ' ').trim().toLowerCase() ===
          title.replace(/\\s+/g, ' ').toLowerCase()) own.remove();

      var top = document.createElement('h1');
      top.textContent = title;
      var from = document.createElement('p');
      from.className = 'office-from';
      from.textContent = location.host.replace(/^www\\./, '');

      document.body.innerHTML = '';
      // The site's own stylesheets go with its layout. Kept, a rule of theirs
      // like p{color:#222} outranks the article's colour: nothing to see on
      // white, and text that disappears on dark. Search's own stay (office-*:
      // what was hidden on this site, a video floating out of it).
      var theirs = document.querySelectorAll('link[rel~="stylesheet"], style');
      for (var t = 0; t < theirs.length; t++) {
        if (!/^office-/.test(theirs[t].id)) theirs[t].remove();
      }
      if (document.adoptedStyleSheets) document.adoptedStyleSheets = [];
      document.head.appendChild(sheet);
      wrap.insertBefore(from, wrap.firstChild);
      wrap.insertBefore(top, wrap.firstChild);
      document.body.appendChild(wrap);
      window.scrollTo(0, 0);
      return 'read';
    })();
    """

    /// Light, dark, or as the window is: chosen on an article, and kept for
    /// the next one.
    static var look: Look {
        get { Store.settings.string(forKey: "reader.look").flatMap(Look.init) ?? .system }
        set { Store.settings.set(newValue.rawValue, forKey: "reader.look") }
    }

    /// Puts a look on the page. It is on <html>, which the reader keeps, so
    /// it holds for the article and goes when the page does.
    static func apply(_ look: Look) -> String {
        look == .system
            ? "document.documentElement.removeAttribute('data-office-look');"
            : "document.documentElement.setAttribute('data-office-look','\(look.rawValue)');"
    }
}

/// The article's own light and dark, in its corner while it is up. Quiet
/// until the pointer comes to it.
struct ReaderLook: View {
    let tab: Tab
    @State private var look = Reader.look
    @State private var hovering = false
    @Environment(\.colorScheme) private var window

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Look.allCases) { each in
                Button {
                    look = each
                    Reader.look = each
                    tab.built?.evaluateJavaScript(Reader.apply(each))
                } label: {
                    Image(systemName: each == .light ? "sun.max" : each == .dark ? "moon" : "circle.lefthalf.filled")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(look == each ? Palette.ink : Palette.muted)
                        .frame(width: 24, height: 22)
                        .background(Capsule().fill(look == each ? Palette.wash : .clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(each == .system ? "As the window is" : each.title)
            }
        }
        .padding(3)
        .background(Palette.ground, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
        // In the article's colours, which may not be the window's.
        .environment(\.colorScheme, look == .dark ? .dark : look == .light ? .light : window)
        .opacity(hovering ? 1 : 0.55)
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        .animation(Motion.quick, value: look)
        .padding(14)
        // An article read in another tab may have been given another look
        // since: the one kept is the one it wears when it comes back.
        .onAppear { tab.built?.evaluateJavaScript(Reader.apply(look)) }
    }
}
