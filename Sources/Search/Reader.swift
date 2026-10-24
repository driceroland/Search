import SwiftUI

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
    private static let dark = "color-scheme:dark;--r-ground:#1c1c1c;--r-ink:#e0e0e0;--r-quiet:#8a8a8a;"
        + "--r-aside:#a8a8a8;--r-rule:#333;--r-code:#2a2a2a;--r-picture:brightness(.92)"

    static let sheet = [
        // Light, or dark as the window is or as chosen in the corner
        // (ReaderLook puts it on <html>, which the reader keeps). The dark
        // ground is the window's own (Palette.ground); the text a shade
        // softer than Palette.ink, there being a lot of it.
        ":root{color-scheme:light;--r-ground:#fff;--r-ink:#171717;--r-quiet:#a3a3a3;",
        "--r-aside:#555;--r-rule:#e8e8e8;--r-code:#f5f5f5;--r-picture:none}",
        "@media (prefers-color-scheme:dark){:root:not([data-office-look=light]){" + dark + "}}",
        ":root[data-office-look=dark]{" + dark + "}",
        "html,body{background:var(--r-ground) !important;margin:0 !important;padding:0 !important}",
        "#office-reader{max-width:38em;margin:0 auto;padding:72px 24px 160px;",
        "font:400 18px/1.72 ui-serif,Georgia,\"Times New Roman\",serif;color:var(--r-ink)}",
        "#office-reader h1{font:600 30px/1.24 -apple-system,BlinkMacSystemFont,sans-serif;",
        "margin:0 0 8px;letter-spacing:-0.01em}",
        "#office-reader .office-from{font:400 12px/1 -apple-system,sans-serif;color:var(--r-quiet);",
        "margin:0 0 40px;text-transform:uppercase;letter-spacing:.06em}",
        "#office-reader p{margin:0 0 1.35em}",
        "#office-reader img,#office-reader video,#office-reader iframe{max-width:100%;",
        "height:auto;border-radius:6px;margin:1.6em 0;display:block}",
        // A photo, a touch dimmer on dark, so it doesn't glare.
        "#office-reader img{filter:var(--r-picture)}",
        "#office-reader iframe{width:100%;aspect-ratio:16/9;height:auto;border:0}",
        "#office-reader svg{max-width:100%}",
        "#office-reader iframe.office-chart{aspect-ratio:auto}",
        "#office-reader figure{margin:1.8em 0}",
        "#office-reader figcaption{font:400 13px/1.5 -apple-system,sans-serif;",
        "color:var(--r-quiet);margin-top:.6em}",
        // A caption and its credit, which the site's own layout kept apart.
        "#office-reader figcaption > * + *{margin-left:.35em}",
        // The byline and a summary, quieter than the text.
        "#office-reader .office-above{font:400 14px/1.55 -apple-system,sans-serif;",
        "color:var(--r-aside);margin:0 0 1.6em}",
        "#office-reader .office-above ul{padding-left:1.2em}",
        "#office-reader .office-above h2{margin:.4em 0}",
        "#office-reader a{color:var(--r-ink);text-underline-offset:3px}",
        "#office-reader h2,#office-reader h3{font:600 20px/1.3 -apple-system,sans-serif;",
        "margin:2em 0 .6em}",
        "#office-reader h4,#office-reader h5,#office-reader h6{font:600 16px/1.4 -apple-system,sans-serif;",
        "margin:1.8em 0 .5em}",
        "#office-reader pre,#office-reader code,#office-reader kbd{font-family:ui-monospace,monospace;font-size:14px}",
        "#office-reader pre{background:var(--r-code);padding:14px;border-radius:8px;overflow:auto}",
        "#office-reader blockquote{margin:1.6em 0;padding-left:1.2em;",
        "border-left:2px solid var(--r-rule);color:var(--r-aside)}",
        // Said outright: a site's own reset (Tailwind's, most often) takes
        // the numbers off every list on the page, this one included.
        "#office-reader ul,#office-reader ol{margin:0 0 1.35em;padding-left:1.4em}",
        "#office-reader ul{list-style:disc outside}",
        "#office-reader ol{list-style:decimal outside}",
        "#office-reader li>ul{list-style-type:circle}",
        "#office-reader :not(pre)>code{background:var(--r-code);padding:.1em .35em;border-radius:4px}",
        "#office-reader li{margin:.3em 0}",
        "#office-reader li>ul,#office-reader li>ol{margin-bottom:0}",
        "#office-reader hr{border:0;border-top:1px solid var(--r-rule);margin:2.4em 0}",
        "#office-reader .office-wide{overflow-x:auto;margin:1.6em 0}",
        "#office-reader table{border-collapse:collapse;font:400 15px/1.5 -apple-system,sans-serif}",
        "#office-reader th,#office-reader td{border-bottom:1px solid var(--r-rule);padding:8px 12px 8px 0;",
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
      // Light unless reading mode follows the window (`readerLook`, when given).
      var chosen = typeof readerLook === 'string' ? readerLook : 'light';
      if (chosen === 'system') document.documentElement.removeAttribute('data-office-look');
      else document.documentElement.setAttribute('data-office-look', chosen);
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

      // Already an article: going back can bring one as it was left.
      if (document.getElementById('office-reader')) return 'read';

      var article = best();
      if (!article) return 'none';

      // The photo an article opens with isn't always in it: the FT keeps its
      // own in a topper beside the <article>. So the first large picture
      // before the text comes too, looked for no more than four boxes out,
      // and never in a menu, a rail or a footer.
      var lead = null;
      for (var up = article.parentElement, depth = 0;
           up && up !== document.body && depth < 4 && !lead;
           up = up.parentElement, depth++) {
        var shown = up.querySelectorAll('figure, picture');
        for (var l = 0; l < shown.length && !lead; l++) {
          var face = shown[l].querySelector('img');
          // Before the text, and not around it.
          if (face && article.compareDocumentPosition(shown[l]) === Node.DOCUMENT_POSITION_PRECEDING &&
              !shown[l].closest('nav, aside, footer, [role="banner"]') &&
              face.getBoundingClientRect().width >= 400) lead = shown[l];
        }
      }

      // A chart's frame is as tall as its own script made it, and that script
      // won't run in the reader: the height is read while the page shows it.
      var framed = article.querySelectorAll('iframe');
      for (var z = 0; z < framed.length; z++) {
        framed[z].setAttribute('data-office-height', Math.round(framed[z].getBoundingClientRect().height));
      }

      // Bloomberg keeps an article's byline, its takeaways and the video it
      // opens with between the headline and the text, outside the part with
      // the most prose. Such parts of its head come along, in the page's
      // order: those drawn on the page, and never one from a menu, a rail or
      // a footer. Class names are matched in part and whatever their case,
      // as sites build them (BasicByline_byline__VTyoS); a subheading is an
      // h2.
      // The size a drawing in the text is given, an icon as often as not,
      // goes with the page's styles: left to itself, an <svg> fills the
      // column. The size it is drawn at is written onto it.
      var drawings = article.querySelectorAll('svg');
      for (var dr = 0; dr < drawings.length; dr++) {
        if (drawings[dr].parentElement.closest('svg')) continue;
        var drawn = drawings[dr].getBoundingClientRect();
        drawings[dr].setAttribute('width', Math.round(drawn.width));
        drawings[dr].setAttribute('height', Math.round(drawn.height));
      }

      var heading = document.querySelector('h1');
      var above = [];
      if (heading) {
        var found = document.querySelectorAll(
          '[class*="byline" i],[class*="takeaways" i],[class*="lede" i],h2'
        );
        for (var a = 0; a < found.length; a++) {
          var part = found[a];
          if (part.contains(article) || article.contains(part) ||
              above.some(function (o) { return o.contains(part); })) continue;
          if (!(heading.compareDocumentPosition(part) & Node.DOCUMENT_POSITION_FOLLOWING)) continue;
          if (!(article.compareDocumentPosition(part) & Node.DOCUMENT_POSITION_PRECEDING)) continue;
          if (part.closest('nav, aside, footer, [role="banner"]') || !part.getClientRects().length) continue;
          above.push(part);
        }
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
      var pictures = Array.prototype.slice.call(article.querySelectorAll('img'));
      if (lead) pictures = pictures.concat(Array.prototype.slice.call(lead.querySelectorAll('img')));
      above.forEach(function (o) {
        pictures = pictures.concat(Array.prototype.slice.call(o.querySelectorAll('img')));
      });
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
      // Not a box that holds paragraphs, though: an article's folded-away
      // rest is still the article. The head's parts are looked at the same.
      var inherent = /^(SOURCE|TRACK|PARAM|AREA|TEMPLATE|BR|WBR|SCRIPT|STYLE|NOSCRIPT)$/;
      var all = [];
      [article].concat(above).forEach(function (root) {
        all = all.concat(Array.prototype.slice.call(root.querySelectorAll('*')));
      });
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
        if (gone && !(look.display === 'none' && el.querySelector('p'))) el.setAttribute('data-office-hidden', '');
      }

      var title = (heading && heading.innerText.trim()) || document.title;

      var wrap = document.createElement('div');
      wrap.innerHTML = article.innerHTML;
      for (var o = above.length - 1; o >= 0; o--) {
        var copy = above[o].cloneNode(true);
        copy.classList.add('office-above');
        wrap.insertBefore(copy, wrap.firstChild);
      }

      var hidden = wrap.querySelectorAll('[data-office-hidden]');
      for (var d = 0; d < hidden.length; d++) hidden[d].remove();
      // A style written on an element is the page's styling too: a fixed
      // width, a white font for a dark box that isn't there any more.
      var styled = wrap.querySelectorAll('[style]');
      for (var y = 0; y < styled.length; y++) styled[y].removeAttribute('style');
      // The photo comes without the topper's own classes and styles, which
      // the page's stylesheet would still lay out as a topper: off to one
      // side, cropped.
      if (lead) {
        var opening = lead.cloneNode(true);
        var parts = [opening].concat(Array.prototype.slice.call(opening.querySelectorAll('*')));
        for (var x = 0; x < parts.length; x++) {
          parts[x].removeAttribute('class');
          parts[x].removeAttribute('style');
        }
        var after = wrap.firstChild;
        while (after && after.classList && after.classList.contains('office-above')) after = after.nextSibling;
        wrap.insertBefore(opening, after);
      }

      // A picture in a button, a click to see it larger, is the picture:
      // Bloomberg puts every photo in one. The button goes and what it holds
      // stays.
      var pressed = wrap.querySelectorAll('button');
      for (var b = 0; b < pressed.length; b++) {
        if (!pressed[b].querySelector('img, picture, video')) continue;
        while (pressed[b].firstChild) pressed[b].parentNode.insertBefore(pressed[b].firstChild, pressed[b]);
        pressed[b].remove();
      }

      // What was arranged around the words rather than being part of them.
      // Not header: an article's opening image lives there as often as not.
      // A video.js player's controls, title bar and read-outs go too; the
      // video stays.
      var clutter = wrap.querySelectorAll(
        'script,style,noscript,form,nav,aside,footer,button,input,select,textarea,' +
        '[role="complementary"],[role="navigation"],[role="banner"],[aria-hidden="true"],' +
        '.video-js > [class*="vjs-"]:not(video)'
      );
      for (var c = 0; c < clutter.length; c++) clutter[c].remove();

      // So does a box inviting you to a newsletter, which Bloomberg sets in
      // the middle of the text. Only a short one: a newsletter's own page
      // may keep its whole text in a box named the same.
      var invites = wrap.querySelectorAll('[class*="newsletter" i]');
      for (var n = 0; n < invites.length; n++) {
        if (invites[n].querySelectorAll('p').length < 3) invites[n].remove();
      }

      // Embedded video is part of the article, and so is a chart or a map
      // from one of the chart makers a newsroom puts in it, at the height it
      // had. Any other frame is not: an advertisement, a widget.
      var players = /youtube|youtu\\.be|vimeo|dailymotion|loom\\.com|streamable|wistia|ted\\.com/i;
      var charts = /flourish|flo\\.uri\\.sh|datawrapper|dwcdn\\.net|infogram|tableau|ig\\.ft\\.com|google\\.com\\/maps/i;
      var frames = wrap.querySelectorAll('iframe');
      for (var f = 0; f < frames.length; f++) {
        var where = frames[f].getAttribute('src') || frames[f].getAttribute('data-src') || '';
        if (players.test(where)) {
          frames[f].setAttribute('src', where);
          frames[f].removeAttribute('height');
          frames[f].removeAttribute('width');
        } else if (where && charts.test(where)) {
          var tall = +frames[f].getAttribute('data-office-height');
          frames[f].setAttribute('src', where);
          frames[f].setAttribute('style', 'height:' + (tall > 60 ? tall : 420) + 'px');
          frames[f].className = 'office-chart';
        } else {
          frames[f].remove();
        }
      }

      // A video's poster, which its player also shows as a picture beside it:
      // once is enough.
      var videos = wrap.querySelectorAll('video'), posters = [];
      for (var v = 0; v < videos.length; v++) {
        if (videos[v].poster) posters.push(videos[v].poster);
      }
      var stills = wrap.querySelectorAll('img');
      for (var t = 0; t < stills.length; t++) {
        if (posters.indexOf(stills[t].src) >= 0 && !stills[t].closest('video')) stills[t].remove();
      }

      // A video its player fed from the page itself, through a blob: address,
      // has nothing to play once that player is gone. It plays from the plain
      // stream it names beside that, which WebKit plays on its own, with
      // controls and never by itself, and fetches nothing of until play is
      // pressed; with none, it is its poster; with no poster, it goes.
      for (var q = 0; q < videos.length; q++) {
        var video = videos[q], fed = /^blob:/.test(video.getAttribute('src') || ''), plain = '';
        var named = video.querySelectorAll('source');
        for (var m = 0; m < named.length; m++) {
          if (/^blob:/.test(named[m].getAttribute('src') || '')) fed = true;
          else if (!plain && /^https?:/.test(named[m].src)) plain = named[m].src;
        }
        if (!fed) continue;
        if (plain) {
          for (var r = 0; r < named.length; r++) named[r].remove();
          video.setAttribute('preload', 'metadata');
          video.setAttribute('src', plain);
          video.setAttribute('controls', '');
          video.setAttribute('playsinline', '');
          video.removeAttribute('autoplay');
          // Out of the player's box, which the page's stylesheet still sizes
          // for the player.
          var player = video.parentNode.closest('.video-js');
          if (player) player.parentNode.replaceChild(video, player);
        } else if (video.poster) {
          var still = document.createElement('img');
          still.setAttribute('src', video.poster);
          video.parentNode.replaceChild(still, video);
        } else {
          video.remove();
        }
      }

      // A picture with nothing behind it is a broken icon, which is worse than
      // no picture at all.
      var kept = wrap.querySelectorAll('img');
      for (var g = 0; g < kept.length; g++) {
        var src = kept[g].getAttribute('src') || '';
        if (!src || src.indexOf('data:image') === 0) kept[g].remove();
      }

      // A box whose content went (the figure a frame sat in, the one a
      // picture with nothing behind it left) goes too, rather than stay as
      // an empty band.
      var boxes = wrap.querySelectorAll('figure, picture, div, section, p');
      for (var e = boxes.length - 1; e >= 0; e--) {
        if (!boxes[e].textContent.trim() &&
            !boxes[e].querySelector('img, video, audio, iframe, svg, canvas, table')) boxes[e].remove();
      }

      // The article's own heading goes when it only says the title again,
      // which the reader puts on top.
      var own = wrap.querySelector('h1');
      if (own && own.textContent.replace(/\\s+/g, ' ').trim().toLowerCase() ===
          title.replace(/\\s+/g, ' ').toLowerCase()) own.remove();

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
    /// comes down. Only the page's own origin is asked, and only an answer
    /// from it read: a twin named on another site, or a redirect to one, is
    /// not the site's say-so about this page, and reading mode never sends a
    /// request beyond the page's own site. The request goes from the page,
    /// with its cookies, so a site you are signed in to gives the twin you'd
    /// see. Nothing is cached:
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
    function home(address) {
      try { return new URL(address, location.href).origin === location.origin; } catch (e) { return false; }
    }
    async function read(address, patience, named) {
      if (!home(address)) return null;
      var stop = new AbortController();
      var timer = setTimeout(function () { stop.abort(); }, patience);
      try {
        var answer = await fetch(address, {
          headers: { Accept: 'text/markdown, text/plain;q=0.5' },
          cache: 'no-store', credentials: 'same-origin', signal: stop.signal
        });
        var type = kind(answer.headers.get('content-type'));
        var fits = markdown.indexOf(type) >= 0 || (named && type === 'text/plain');
        if (!answer.ok || !fits || (answer.url && !home(answer.url))) {
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
      if (markdown.indexOf(kind(links[i].type)) < 0 || !/^https?:/.test(links[i].href) || !home(links[i].href)) continue;
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

    /// Light, dark, or as the window is: chosen on an article, and kept for
    /// the next one. Light whenever reading mode doesn't follow the window.
    static var look: Look {
        get {
            guard Store.settings.bool(forKey: "reader.follows") else { return .light }
            return Store.settings.string(forKey: "reader.look").flatMap(Look.init) ?? .system
        }
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

/// The article's own light and dark, in its corner while it is up, with
/// reading mode following the window (Settings › General). Quiet until the
/// pointer comes to it.
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
