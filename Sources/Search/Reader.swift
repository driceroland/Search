import Foundation

// Reading mode: the article, and nothing that was arranged around it.
//
// The hard part is deciding what the article is. The heuristic here is the old
// one and it holds up: the piece of the page carrying the most prose, punished
// for every link inside it — because navigation, related-articles rails and
// comment threads are all made of links, and prose is not.
//
// Unless the site has already answered it. More and more publish a markdown
// copy of each page, written for language models and just as good for a
// person: the article, decided by whoever wrote it (see `twin`). When there
// is one it is drawn instead (see Markdown.swift), in the same page as the
// guess would have been.

enum Reader {
    /// The one look both kinds of reading share.
    static let sheet = [
        "html,body{background:#fff !important;margin:0 !important;padding:0 !important}",
        "#office-reader{max-width:38em;margin:0 auto;padding:72px 24px 160px;",
        "font:400 18px/1.72 ui-serif,Georgia,\"Times New Roman\",serif;color:#171717}",
        "#office-reader h1{font:600 30px/1.24 -apple-system,BlinkMacSystemFont,sans-serif;",
        "margin:0 0 8px;letter-spacing:-0.01em}",
        "#office-reader .office-from{font:400 12px/1 -apple-system,sans-serif;color:#a3a3a3;",
        "margin:0 0 40px;text-transform:uppercase;letter-spacing:.06em}",
        "#office-reader p{margin:0 0 1.35em}",
        "#office-reader img,#office-reader video,#office-reader iframe{max-width:100%;",
        "height:auto;border-radius:6px;margin:1.6em 0;display:block}",
        "#office-reader iframe{width:100%;aspect-ratio:16/9;height:auto;border:0}",
        "#office-reader figure{margin:1.8em 0}",
        "#office-reader figcaption{font:400 13px/1.5 -apple-system,sans-serif;",
        "color:#a3a3a3;margin-top:.6em}",
        "#office-reader a{color:#171717;text-underline-offset:3px}",
        "#office-reader h2,#office-reader h3{font:600 20px/1.3 -apple-system,sans-serif;",
        "margin:2em 0 .6em}",
        "#office-reader h4,#office-reader h5,#office-reader h6{font:600 16px/1.4 -apple-system,sans-serif;",
        "margin:1.8em 0 .5em}",
        "#office-reader pre,#office-reader code,#office-reader kbd{font-family:ui-monospace,monospace;font-size:14px}",
        "#office-reader pre{background:#f5f5f5;padding:14px;border-radius:8px;overflow:auto}",
        "#office-reader blockquote{margin:1.6em 0;padding-left:1.2em;",
        "border-left:2px solid #e8e8e8;color:#555}",
        // Said outright: a site's own reset (Tailwind's, most often) takes
        // the numbers off every list on the page, this one included.
        "#office-reader ul,#office-reader ol{margin:0 0 1.35em;padding-left:1.4em}",
        "#office-reader ul{list-style:disc outside}",
        "#office-reader ol{list-style:decimal outside}",
        "#office-reader li>ul{list-style-type:circle}",
        "#office-reader :not(pre)>code{background:#f5f5f5;padding:.1em .35em;border-radius:4px}",
        "#office-reader li{margin:.3em 0}",
        "#office-reader li>ul,#office-reader li>ol{margin-bottom:0}",
        "#office-reader hr{border:0;border-top:1px solid #e8e8e8;margin:2.4em 0}",
        "#office-reader .office-wide{overflow-x:auto;margin:1.6em 0}",
        "#office-reader table{border-collapse:collapse;font:400 15px/1.5 -apple-system,sans-serif}",
        "#office-reader th,#office-reader td{border-bottom:1px solid #e8e8e8;padding:8px 12px 8px 0;",
        "text-align:left;vertical-align:top}",
        "#office-reader th{font-weight:600}",
        "#office-reader .office-part{font:600 16px/1.4 -apple-system,sans-serif;margin:1.8em 0 .5em}",
        "#office-reader details{margin:0 0 1.35em}",
        "#office-reader summary{cursor:pointer}",
    ].joined()

    /// Puts the reading page in place of the page: the title, where it's
    /// from, and what to read. Called with the sheet, since a script only
    /// knows what it's handed.
    ///
    /// The page's own stylesheets go first. Left in, they reach the reading
    /// page through every rule written for a bare element (Tailwind's reset
    /// took the numbers off every list) and every font the page loaded.
    /// Search's own stay: each has an `office-` id, and Dusk and Find on Page
    /// keep theirs in adoptedStyleSheets, which are left as they are. Done
    /// once, as reading mode opens; a page that adds a sheet back later keeps
    /// it, because a watcher that took it away again would fight any
    /// extension (Dark Reader, Stylus) that puts its own back, forever.
    static let present = """
    function present(wrap, title, from, sheet) {
      var theirs = document.querySelectorAll('style, link[rel~="stylesheet" i]');
      for (var i = 0; i < theirs.length; i++) {
        if ((theirs[i].id || '').indexOf('office-') !== 0) theirs[i].remove();
      }
      document.documentElement.removeAttribute('style');
      document.body.removeAttribute('style');
      var style = document.createElement('style');
      style.id = 'office-reader-sheet';
      style.textContent = sheet;
      var top = document.createElement('h1');
      top.textContent = title;
      var line = document.createElement('p');
      line.className = 'office-from';
      line.textContent = from;
      wrap.id = 'office-reader';
      document.body.innerHTML = '';
      (document.head || document.documentElement).appendChild(style);
      wrap.insertBefore(line, wrap.firstChild);
      wrap.insertBefore(top, wrap.firstChild);
      document.body.appendChild(wrap);
      window.scrollTo(0, 0);
    }
    """

    /// The guess, for a page with no twin. Called with `sheet`.
    static let script = present + """

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

      var article = best();
      if (!article) return 'none';

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

      // What the page's own styles hide, seen while they still apply: the
      // reading page goes without them (see present), and a label meant
      // only for screen readers, a menu folded shut or the mobile copy of a
      // table would all come into view. Pictures' sources and the like are
      // hidden by WebKit itself, which the reading page keeps.
      var inherent = /^(SOURCE|TRACK|PARAM|AREA|TEMPLATE|BR|WBR|SCRIPT|STYLE|NOSCRIPT)$/;
      var all = article.querySelectorAll('*');
      for (var h = 0; h < all.length; h++) {
        var el = all[h];
        if (inherent.test(el.tagName) || el.closest('details:not([open])')) continue;
        var look = getComputedStyle(el);
        var gone = look.display === 'none' || look.visibility === 'hidden';
        if (!gone && (look.overflow === 'hidden' || look.clip !== 'auto')) {
          var box = el.getBoundingClientRect();
          // The usual way of hiding text from sight but not from a screen
          // reader: a box a pixel square, its overflow cut off.
          gone = box.width <= 1 && box.height <= 1;
        }
        if (gone) el.setAttribute('data-office-hidden', '');
      }

      var heading = document.querySelector('h1');
      var title = (heading && heading.innerText.trim()) || document.title;

      var wrap = document.createElement('div');
      wrap.innerHTML = article.innerHTML;

      var hidden = wrap.querySelectorAll('[data-office-hidden]');
      for (var d = 0; d < hidden.length; d++) hidden[d].remove();
      // A style written on an element is the page's styling too: a fixed
      // width, a white font for a dark box that isn't there any more.
      var styled = wrap.querySelectorAll('[style]');
      for (var y = 0; y < styled.length; y++) styled[y].removeAttribute('style');

      // What was arranged around the words rather than being part of them.
      // Not header: an article's opening image lives there as often as not.
      var clutter = wrap.querySelectorAll(
        'script,style,noscript,form,nav,aside,footer,button,input,select,textarea,' +
        '[role="complementary"],[role="navigation"],[role="banner"],[aria-hidden="true"]'
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

      present(wrap, title, location.host.replace(/^www\\./, ''), sheet);
      return 'read';
    """

    /// The site's own markdown for this page, if it has some. Answers the
    /// text and the address it came from, with the page's title and host
    /// for when the markdown has no heading; or null.
    ///
    /// Three places, in order, all of them the site's own say-so:
    ///
    /// - the page is markdown already, a README opened as it is;
    /// - the page names its twin, `<link rel="alternate" type="text/markdown">`
    ///   (Mintlify, Cloudflare's docs and others write one on every page);
    /// - the same address with `.md` on the end, which llms.txt proposed and
    ///   docs sites took up (Anthropic's, Vercel's, Bun's).
    ///
    /// Asking the page's own address for markdown with an Accept header finds
    /// more, but what it mostly finds is Cloudflare converting the whole page
    /// on the fly, menus, footers and all: worse than the guess, and a second
    /// render of the page on every site that has nothing to give.
    ///
    /// Only a response that says it is markdown counts, so that a site
    /// answering every address with its home page, or a 404 page, is never
    /// read as one; anything else is dropped at the headers, before its body
    /// comes down. The request goes from the page, with its cookies, so a
    /// site you are signed in to gives the twin you'd see. Nothing is cached:
    /// a server that answers markdown without saying it varies by what was
    /// asked for would otherwise leave it where Back finds it.
    static let twin = """
    var markdown = ['text/markdown', 'text/x-markdown'];
    function kind(type) { return (type || '').toLowerCase().split(';')[0].trim(); }
    var heading = document.querySelector('h1');
    var about = {
      title: (heading && heading.innerText.trim()) || document.title,
      from: location.host.replace(/^www\\./, '')
    };

    var own = kind(document.contentType);
    if (markdown.indexOf(own) >= 0 ||
        (own === 'text/plain' && /\\.(md|markdown)$/i.test(location.pathname))) {
      return { url: location.href, text: document.body ? document.body.textContent : '',
               title: about.title, from: about.from };
    }
    if (!/^https?:$/.test(location.protocol)) return null;

    // `named`: the page asked for this one by name, and a site that says so
    // may serve its markdown as plain text.
    async function read(address, patience, named) {
      var stop = new AbortController();
      var timer = setTimeout(function () { stop.abort(); }, patience);
      try {
        var answer = await fetch(address, {
          headers: { Accept: 'text/markdown, text/plain;q=0.5' },
          cache: 'no-store', signal: stop.signal
        });
        var type = kind(answer.headers.get('content-type'));
        var fits = markdown.indexOf(type) >= 0 || (named && type === 'text/plain');
        if (!answer.ok || !fits) {
          if (answer.body) answer.body.cancel();
          return null;
        }
        var text = await answer.text();
        if (text.length > 4000000 || /^\\s*<(!doctype|html)/i.test(text)) return null;
        return { url: answer.url || address, text: text, title: about.title, from: about.from };
      } catch (e) {
        return null;
      } finally {
        clearTimeout(timer);
      }
    }

    var links = document.querySelectorAll('link[rel~="alternate" i][type]');
    for (var i = 0; i < links.length; i++) {
      if (markdown.indexOf(kind(links[i].type)) < 0 || !/^https?:/.test(links[i].href)) continue;
      var named = await read(links[i].href, 5000, true);
      if (named) return named;
      break;
    }

    // Most sites have no twin, so this one is kept short: the reader
    // shouldn't wait on an address that was only ever a guess.
    var guess = new URL(location.href);
    guess.hash = '';
    if (/\\.(md|markdown)$/i.test(guess.pathname)) return null;
    guess.pathname += /\\/$/.test(guess.pathname) ? 'index.html.md' : '.md';
    return await read(guess.href, 1500, false);
    """

    /// The twin, drawn: `html` from Markdown.page, set in the same page the
    /// guess makes. Called with `html`, `title`, `from` and `sheet`.
    static let show = present + """

    var wrap = document.createElement('div');
    wrap.innerHTML = html;
    present(wrap, title, from, sheet);
    return 'read';
    """
}
