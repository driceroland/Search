#!/usr/bin/env python3
"""The page under a peek, the column out over it, the address field, a panel
or the Find bar hears nothing of the pointer (idea 418).

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
        # ⌘T's field comes up over the page in front, not as a blank tab.
        sv.setup(**{"newtab.floating": True})
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
        sv.cmd({"do": "ui", "folded": False}); time.sleep(0.6)

        # The rest of what comes over the page, at every point of a grid
        # where, with nothing over it, a click lands on the page.
        def hit(x, y): return sv.cmd({"do": "hit", "x": x, "y": y})["view"]
        grid = [(x, y) for x in range(40, 1600, 120) for y in range(60, 1000, 90)]
        bare = [p for p in grid if hit(*p) == "PageView"]
        t.ok("the grid finds the page", len(bare) > 40, len(bare))

        def leaks(points): return [p for p in points if heard(*p)]
        def deaf(points): return [p for p in points if not heard(*p)]
        def esc(): sv.cmd({"do": "press", "code": 53, "chars": "\x1b"})

        def over(name, show, hide, up, points=None):
            points = points or bare
            show(); time.sleep(0.8)
            t.ok(f"{name}: it is up", up())
            on_top = [p for p in points if hit(*p) != "PageView"]
            heard_under = leaks(on_top)
            print(f"  {name}: over {len(on_top)} of {len(points)} points, the page heard {len(heard_under)} of them")
            t.ok(f"{name}: the page under it hears no move", on_top and not heard_under, heard_under[:4])
            t.ok(f"{name}: beside it, the page still hears the pointer",
                 not deaf([p for p in points if p not in on_top]))
            hide(); time.sleep(0.8)
            t.ok(f"{name} gone: the page hears the pointer everywhere again", not up() and not deaf(bare))

        def field_up(): return any(hit(*p) != "PageView" for p in bare[::3])

        over("⌘L's field", lambda: sv.cmd({"do": "press", "code": 37, "chars": "l", "mods": ["cmd"]}), esc, field_up)
        over("⌘T's floating field", lambda: sv.cmd({"do": "press", "code": 17, "chars": "t", "mods": ["cmd"]}), esc, field_up)
        other = sv.page("other"); sv.sp("select", id=page); time.sleep(0.6)
        over("the ⌃Tab switcher", lambda: sv.cmd({"do": "press", "code": 48, "chars": "\t", "mods": ["ctrl"]}),
             lambda: sv.sp("mouse", points=[[5, 5], [5, 5]]), lambda: sv.cmd({"do": "switcher"})["visible"])
        sv.sp("select", id=page); time.sleep(0.6)
        over("the hidden elements' list", lambda: sv.cmd({"do": "ui", "hidden": True}),
             lambda: sv.cmd({"do": "ui", "hidden": False}), field_up)
        over("Welcome", lambda: sv.cmd({"do": "ui", "welcome": True}),
             lambda: sv.cmd({"do": "ui", "welcome": False}), field_up)
        over("What's New", lambda: sv.cmd({"do": "news", "on": True}),
             lambda: sv.cmd({"do": "news", "on": False}), field_up)
        # The Find bar is a pill along the page's top: a finer grid there.
        top = [(x, y) for x in range(40, 1600, 40) for y in range(50, 160, 10)]
        top = [p for p in top if hit(*p) == "PageView"]
        over("the Find bar", lambda: sv.cmd({"do": "find", "text": "page"}), esc,
             lambda: sv.sp("state")["finding"], points=top)

        # Split View: the field stands over the focused pane alone.
        sv.cmd({"do": "ui", "sidebar": False}); time.sleep(0.4)
        sv.sp("enabled", on=True)
        left = sv.page("left"); right = sv.page("right")
        sv.sp("pair", id=right, **{"with": left}, side="right"); sv.sp("select", id=right); time.sleep(1)
        f = sv.frames(sv.sp("state"))
        mid = f[right]["x"]
        both = [p for p in grid if hit(*p) == "PageView"]
        on_left = [p for p in both if p[0] < mid - 20]
        on_right = [p for p in both if p[0] > mid + 20]
        sv.cmd({"do": "press", "code": 37, "chars": "l", "mods": ["cmd"]}); time.sleep(0.8)
        def heard_on(id, points): return [p for p in points if sv.cmd({"do": "pointer", "id": id, "x": p[0], "y": p[1]})["covered"] is False]
        under = heard_on(right, on_right)
        print(f"  Split View, ⌘L on the right pane: its page heard {len(under)} of {len(on_right)} points")
        t.ok("split: the focused page under the field hears no move", on_right and not under, under[:4])
        t.ok("split: the other page still hears the pointer", on_left and len(heard_on(left, on_left)) == len(on_left))
        esc(); time.sleep(0.6)
    finally:
        t.done()
        sv.finish()
    return 1 if t.failed else 0


if __name__ == "__main__":
    sys.exit(main())
