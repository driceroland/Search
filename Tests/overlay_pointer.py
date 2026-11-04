#!/usr/bin/env python3
"""The page under a peek or the column out over it hears nothing of the pointer (idea 418).

Build first (`./build.sh`), then `python3 Tests/overlay_pointer.py`. It uses
the split suite's harness in a world of its own (bug-overlay-<checkout>):
started hidden, no window made or shown, everything removed afterwards.

A click over the column or a peek's dimming goes to what is on top: the
window asks what is there (`hit`). But the page's own tracking area hears
every move under them, AppKit tracking by rectangle and not by what is in
front, and WebKit lit up links, opened hover menus and changed the pointer
there. Those areas belong to an object of WebKit's, not the page's view, so
a hidden probe's window, which gets no pointer, has the bench hand each
area's owner what AppKit would (`pointer`) and say whether the page took it
as under cover. WebKit lights nothing up in a window that isn't the
active one, so what it does with a move is seen by hand; a press reaching
the page is counted by the page.
"""
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("bug-overlay")

PAGE = b"""<!doctype html><title>under</title>
<style>html,body{margin:0;height:100%} #all{height:100%} #all:hover{background:#eee}</style>
<script>
window.downs = 0;
addEventListener('mousedown', () => downs++, true);
</script>
<a id=all href="#x">all of the page is a link</a>"""


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(PAGE)))
        self.end_headers()
        self.wfile.write(PAGE)

    def log_message(self, *a):
        pass


srv = ThreadingHTTPServer(("127.0.0.1", 0), Page)
threading.Thread(target=srv.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{srv.server_port}"


def main():
    t = sv.T()
    try:
        sv.setup()
        sv.launch()
        page = sv.sp("open", url=f"{BASE}/under")["resultID"]
        time.sleep(1.5)

        def downs(): return sv.ev(page, "downs")
        def pointer(x, y, what="move"): return sv.cmd({"do": "pointer", "id": page, "x": x, "y": y, "what": what})
        def heard(x, y): return pointer(x, y)["covered"] is False

        # WebKit's tracking areas hand moves to an object of its own, past
        # the page's view: each must be behind a gate of ours.
        t.ok("every tracking area of WebKit's is gated", pointer(600, 400)["ungated"] == 0)

        # Uncovered, the page hears the pointer, as ever.
        t.ok("uncovered: the page hears a move", heard(600, 400))
        d = downs()
        pointer(600, 400, what="press"); time.sleep(0.2)
        t.ok("uncovered: a press is the page's", downs() == d + 1, (d, downs()))

        # A peek over it.
        sv.cmd({"do": "peek", "url": f"{BASE}/peeked"}); time.sleep(1.5)
        fx, fy, fw, fh = sv.cmd({"do": "probe"})["peekFrame"]
        beside = (fx - 40, fy + fh // 2)
        h = sv.cmd({"do": "hit", "x": beside[0], "y": beside[1]})
        t.ok("peek: a click beside the panel goes to the dimming, not the page", h["view"] != "PageView", h)
        for x, y in [beside, (fx + fw // 2, fy + fh // 2), (fx + fw // 2, fy + fh + 20)]:
            t.ok(f"peek: the page under it hears no move at {x},{y}", not heard(x, y))
        d = downs()
        r = pointer(*beside, what="press")
        t.ok("peek: a press reaching the page under it isn't the page's", downs() == d, (d, downs()))
        t.ok("peek: and puts the peek away, as a click beside it does", r["peek"] == "", r)

        # Back uncovered.
        t.ok("peek gone: the page hears the pointer again", heard(600, 400))

        # The folded column out over the page.
        sv.cmd({"do": "ui", "sidebar": True}); time.sleep(0.3)
        sv.cmd({"do": "ui", "folded": True}); time.sleep(0.6)
        sv.cmd({"do": "ui", "peek": True}); time.sleep(0.8)
        p = sv.cmd({"do": "probe"})
        t.ok("column out over the page", p.get("folded") is True and p.get("peeking") is True, p.get("peeking"))
        h = sv.cmd({"do": "hit", "x": 100, "y": 400})
        t.ok("column: a click over it doesn't go to the page", h["view"] != "PageView", h)
        t.ok("column: the page under it hears no move", not heard(100, 400) and not heard(40, 600))
        d = downs()
        pointer(100, 400, what="press"); time.sleep(0.2)
        t.ok("column: a press reaching the page under it isn't the page's", downs() == d, (d, downs()))
        t.ok("column: beside it, the page still hears the pointer", heard(800, 400))

        # The column back in: the page is the page's again where it was.
        sv.cmd({"do": "ui", "peek": False}); time.sleep(0.8)
        t.ok("column in: the page hears the pointer there again", heard(100, 400))
    finally:
        t.done()
        sv.finish()
    return 1 if t.failed else 0


if __name__ == "__main__":
    sys.exit(main())
