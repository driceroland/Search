#!/usr/bin/env python3
"""Idea 1176: two pages side by side, the keys to the other one and back,
and the caret in a long editable page stays where it was (it went to the
very start, and a Google Doc jumped up with it). In a hidden probe.

Build first (`./build.sh debug`), then `python3 Tests/split_caret_kept.py`.
Uses the split suite's harness: started hidden, no window made or shown,
everything removed afterwards. `split keys` hands a page the keys as a
click on it does; nothing is copied, so the pasteboard is left alone.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("bld-caret")

DOC = ("document.body.innerHTML = '<div id=ed contenteditable style=\"font:16px/1.5 serif;padding:20px\">' + "
       "Array.from({length: 400}, (_, i) => '<p id=p' + i + '>Paragraph ' + i + ' lorem ipsum dolor sit amet.</p>').join('') + '</div>'; "
       "window.__log = []; document.addEventListener('selectionchange', () => { const s = getSelection(); "
       "__log.push(s.rangeCount && s.anchorNode.parentElement ? s.anchorNode.parentElement.id + ':' + s.anchorOffset : 'none') }); 1")
CARET = ("ed.focus(); const r = document.createRange(); r.setStart(document.getElementById('p300').firstChild, 10); "
         "getSelection().removeAllRanges(); getSelection().addRange(r); document.getElementById('p300').scrollIntoView(); __log = []; 1")
WHERE = "(() => { const s = getSelection(); return s.rangeCount && s.anchorNode.parentElement ? s.anchorNode.parentElement.id + ':' + s.anchorOffset : 'none' })()"
PICK = "(() => { const r = document.createRange(); r.selectNodeContents(document.getElementById('p5')); getSelection().removeAllRanges(); getSelection().addRange(r); return 1 })()"


def case(t):
    """the caret and the other page's selection kept across a trip to the other page"""
    sv.setup(splitView=True, sidebar=True); sv.launch()
    a = sv.page("doc"); b = sv.page("reference")
    sv.sp("pair", id=b, **{"with": a}, side="right"); time.sleep(0.8)
    for id in (a, b): sv.ev(id, DOC)
    sv.sp("focus", id=a); sv.sp("keys", id=a); time.sleep(0.3)
    sv.ev(a, CARET); time.sleep(0.3)
    top = sv.ev(a, "scrollY")
    t.ok("doc: caret deep in the page", sv.ev(a, WHERE) == "p300:10", sv.ev(a, WHERE))
    for round in range(3):
        sv.sp("focus", id=b); sv.sp("keys", id=b); time.sleep(0.3)
        sv.ev(b, PICK); time.sleep(0.2)
        sv.sp("focus", id=a); sv.sp("keys", id=a); time.sleep(0.5)
        t.ok(f"round {round + 1}: the caret where it was", sv.ev(a, WHERE) == "p300:10", (sv.ev(a, WHERE), sv.ev(a, "__log.join(' ')")))
        t.ok(f"round {round + 1}: never moved to the start", "p0:0" not in sv.ev(a, "__log.join(' ')"), sv.ev(a, "__log.join(' ')"))
        t.ok(f"round {round + 1}: the page didn't scroll", sv.ev(a, "scrollY") == top, (top, sv.ev(a, "scrollY")))
        t.ok(f"round {round + 1}: the reference keeps its selection", sv.ev(b, "getSelection().toString().startsWith('Paragraph 5 ')"), sv.ev(b, "getSelection().toString()"))


def main():
    t = sv.T()
    print(f"— {case.__doc__}")
    try:
        case(t)
    except Exception as error:
        t.ok("ran to the end", False, error)
    finally:
        sv.finish()
    t.done()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
