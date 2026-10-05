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
      var heading = document.querySelector('h1');

      // Bloomberg keeps an article's byline, its takeaways and the video it
      // opens with between the headline and the text, outside the part with
      // the most prose. Such parts of its head come along, in the page's
      // order: those drawn on the page, and never one from a menu, a rail or
      // a footer. Class names are matched in part and whatever their case,
      // as sites build them (BasicByline_byline__VTyoS); a subheading is an
      // h2.
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

      // What the page itself hides stays out: a box it keeps in a copy for
      // each size of screen, of which only one shows. Copied out of the
      // page, every copy comes along, and whether the site's own rules still
      // hide them in the reader depends on how those rules were written.
      // Not when it holds paragraphs, though: an article's folded-away rest
      // is still the article.
      [article].concat(above).forEach(function (root) {
        var every = root.querySelectorAll('*');
        for (var h = 0; h < every.length; h++) {
          var el = every[h];
          if (el.closest('svg') || /^(SOURCE|TRACK|SCRIPT|STYLE|TEMPLATE|BR|WBR)$/.test(el.tagName)) continue;
          if (getComputedStyle(el).display === 'none' && !el.querySelector('p')) el.setAttribute('data-office-gone', '');
        }
      });

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
        '#office-reader figure{margin:1.8em 0}',
        '#office-reader figcaption{font:400 13px/1.5 -apple-system,sans-serif;',
        'color:#a3a3a3;margin-top:.6em}',
        // A caption and its credit, which the site's own layout kept apart.
        '#office-reader figcaption > * + *{margin-left:.35em}',
        // The byline and a summary, quieter than the text.
        '#office-reader .office-above{font:400 14px/1.55 -apple-system,sans-serif;',
        'color:#555;margin:0 0 1.6em}',
        '#office-reader .office-above ul{padding-left:1.2em}',
        '#office-reader .office-above h2{margin:.4em 0}',
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
      for (var o = above.length - 1; o >= 0; o--) {
        var copy = above[o].cloneNode(true);
        copy.classList.add('office-above');
        wrap.insertBefore(copy, wrap.firstChild);
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
        '[data-office-gone],.video-js > [class*="vjs-"]:not(video)'
      );
      for (var c = 0; c < clutter.length; c++) clutter[c].remove();

      // So does a box inviting you to a newsletter, which Bloomberg sets in
      // the middle of the text. Only a short one: a newsletter's own page
      // may keep its whole text in a box named the same.
      var invites = wrap.querySelectorAll('[class*="newsletter" i]');
      for (var n = 0; n < invites.length; n++) {
        if (invites[n].querySelectorAll('p').length < 3) invites[n].remove();
      }

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

      // A video's poster, which its player also shows as a picture beside it:
      // once is enough.
      var videos = wrap.querySelectorAll('video'), posters = [];
      for (var v = 0; v < videos.length; v++) {
        if (videos[v].poster) posters.push(videos[v].poster);
      }
      var stills = wrap.querySelectorAll('img');
      for (var s = 0; s < stills.length; s++) {
        if (posters.indexOf(stills[s].src) >= 0 && !stills[s].closest('video')) stills[s].remove();
      }

      // A video its player fed from the page itself, through a blob: address,
      // has nothing to play once that player is gone. It plays from the plain
      // stream it names beside that, which WebKit plays on its own, with
      // controls and never by itself; with none, it is its poster; with no
      // poster, it goes.
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
          video.setAttribute('src', plain);
          video.setAttribute('controls', '');
          video.setAttribute('playsinline', '');
          video.removeAttribute('autoplay');
          // Out of the player's box, which the page's stylesheet still sizes
          // for the player: kept around it, the box's room for the picture
          // and the picture itself would both take a screen's height.
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
