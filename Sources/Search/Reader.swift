import Foundation

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

      var sheet = document.createElement('style');
      sheet.textContent = [
        'html,body{background:#fff !important;margin:0 !important;padding:0 !important}',
        '#office-reader{max-width:38em;margin:0 auto;padding:72px 24px 160px;',
        'font:400 18px/1.72 ui-serif,Georgia,"Times New Roman",serif;color:#171717}',
        '#office-reader h1{font:600 30px/1.24 -apple-system,BlinkMacSystemFont,sans-serif;',
        'margin:0 0 8px;letter-spacing:-0.01em}',
        '#office-reader .office-from{font:400 12px/1 -apple-system,sans-serif;color:#a3a3a3;',
        'margin:0 0 40px;text-transform:uppercase;letter-spacing:.06em}',
        '#office-reader p{margin:0 0 1.35em}',
        '#office-reader img,#office-reader video,#office-reader iframe{max-width:100%;',
        'height:auto;border-radius:6px;margin:1.6em 0;display:block}',
        '#office-reader iframe{width:100%;aspect-ratio:16/9;height:auto;border:0}',
        '#office-reader iframe.office-chart{aspect-ratio:auto}',
        '#office-reader figure{margin:1.8em 0}',
        '#office-reader figcaption{font:400 13px/1.5 -apple-system,sans-serif;',
        'color:#a3a3a3;margin-top:.6em}',
        '#office-reader a{color:#171717;text-underline-offset:3px}',
        '#office-reader h2,#office-reader h3{font:600 20px/1.3 -apple-system,sans-serif;',
        'margin:2em 0 .6em}',
        '#office-reader pre,#office-reader code{font-family:ui-monospace,monospace;font-size:14px}',
        '#office-reader pre{background:#f5f5f5;padding:14px;border-radius:8px;overflow:auto}',
        '#office-reader blockquote{margin:1.6em 0;padding-left:1.2em;',
        'border-left:2px solid #e8e8e8;color:#555}'
      ].join('');

      var wrap = document.createElement('div');
      wrap.id = 'office-reader';
      wrap.innerHTML = article.innerHTML;
      // The photo comes without the topper's own classes and styles, which
      // the page's stylesheet would still lay out as a topper: off to one
      // side, cropped.
      if (lead) {
        var opening = lead.cloneNode(true);
        var parts = [opening].concat(Array.prototype.slice.call(opening.querySelectorAll('*')));
        for (var y = 0; y < parts.length; y++) {
          parts[y].removeAttribute('class');
          parts[y].removeAttribute('style');
        }
        wrap.insertBefore(opening, wrap.firstChild);
      }

      // What was arranged around the words rather than being part of them.
      // Not header: an article's opening image lives there as often as not.
      var clutter = wrap.querySelectorAll(
        'script,style,noscript,form,nav,aside,footer,button,input,select,textarea,' +
        '[role="complementary"],[role="navigation"],[role="banner"],[aria-hidden="true"]'
      );
      for (var c = 0; c < clutter.length; c++) clutter[c].remove();

      // Embedded video is part of the article, and so is a chart or a map a
      // newsroom put in it: one of the chart makers', or any frame it placed
      // in a figure, at the height it had. Any other frame is not: an
      // advertisement, a widget.
      var players = /youtube|youtu\\.be|vimeo|dailymotion|loom\\.com|streamable|wistia|ted\\.com/i;
      var charts = /flourish|flo\\.uri\\.sh|datawrapper|dwcdn\\.net|infogram|tableau|ig\\.ft\\.com|google\\.com\\/maps/i;
      var frames = wrap.querySelectorAll('iframe');
      for (var f = 0; f < frames.length; f++) {
        var where = frames[f].getAttribute('src') || frames[f].getAttribute('data-src') || '';
        if (players.test(where)) {
          frames[f].setAttribute('src', where);
          frames[f].removeAttribute('height');
          frames[f].removeAttribute('width');
        } else if (where && (charts.test(where) || frames[f].closest('figure'))) {
          var tall = +frames[f].getAttribute('data-office-height');
          frames[f].setAttribute('src', where);
          frames[f].setAttribute('style', 'height:' + (tall > 60 ? tall : 420) + 'px');
          frames[f].className = 'office-chart';
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

      // A box whose content went (the figure a frame sat in, the one a
      // picture with nothing behind it left) goes too, rather than stay as
      // an empty band in the site's colours.
      var boxes = wrap.querySelectorAll('figure, picture, div, section, p');
      for (var e = boxes.length - 1; e >= 0; e--) {
        if (!boxes[e].textContent.trim() &&
            !boxes[e].querySelector('img, video, audio, iframe, svg, canvas, table')) boxes[e].remove();
      }

      var top = document.createElement('h1');
      top.textContent = title;
      var from = document.createElement('p');
      from.className = 'office-from';
      from.textContent = location.host.replace(/^www\\./, '');

      document.body.innerHTML = '';
      document.head.appendChild(sheet);
      wrap.insertBefore(from, wrap.firstChild);
      wrap.insertBefore(top, wrap.firstChild);
      document.body.appendChild(wrap);
      window.scrollTo(0, 0);
      return 'read';
    })();
    """
}
