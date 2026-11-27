#!/usr/bin/env python3
"""Hidden column: what the page's own buttons in the edge band get (idea 1308).

Build first (`./build.sh`), then `python3 Tests/edge_band_press.py`. It uses
the split suite's harness in a world of its own (bug-edgeband-<checkout>):
started hidden, no window made or shown, everything removed afterwards.

Airtable's collapsed sidebar lies against the page's left edge, its button
6-12 points in. With the column hidden until the pointer reaches the edge,
that is inside the band that brings the column out (28 points), and the
band kept the page from hearing the pointer there: no hover. Resting on the
button for the dwell (0.05 s) brought the column out over it, and the click
went to the column. The real pointer can't be moved from a hidden probe, so
this checks the pieces: what a move and a press at x = 2...30 reach with the
column away (`pointer`), what the page says is under the pointer there
(`edgeask`, the same question the edge asks before it brings the column),
and the decision itself is unit-tested (FoldDwellTests).
"""
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("bug-edgeband")

# Airtable-like: a collapsed bar along the left edge with a button 4-14 px
# in near the top, and plain page below it.
PAGE = b"""<!doctype html><title>band</title>
<style>html,body{margin:0;height:100%;font:14px sans-serif}
#bar{position:fixed;left:0;top:0;bottom:0;width:16px;background:#f4f4f4}
#btn{position:absolute;left:4px;top:180px;width:10px;height:60px;background:#88f;cursor:pointer}
#btn:hover{background:#44f}</style>
<script>
window.downs = 0; window.overs = 0;
addEventListener('mousedown', e => { if (e.target.id === 'btn') downs++ }, true);
addEventListener('mouseover', e => { if (e.target.id === 'btn') overs++ }, true);
</script>
<div id=bar><div id=btn role=button></div></div>"""


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
        sv.setup(sidebar=True)
        sv.launch()
        page = sv.sp("open", url=f"{BASE}/band")["resultID"]
        time.sleep(1.5)
        sv.cmd({"do": "ui", "folded": True}); time.sleep(0.6)
        sv.cmd({"do": "ui", "hides": True}); time.sleep(0.8)
        p = sv.cmd({"do": "probe"})
        t.ok("column hidden for good, away", p.get("folded") is True and p.get("peeking") is False, p.get("peeking"))
        left = round(sv.frames(sv.sp("state"))[page]["x"])
        top = round(sv.frames(sv.sp("state"))[page]["y"])
        print(f"  page from x {left}")

        def pointer(x, y, what="move"): return sv.cmd({"do": "pointer", "id": page, "x": x, "y": y, "what": what})
        def downs(): return sv.ev(page, "downs")
        def ask(x, y):
            try: return sv.cmd({"do": "edgeask", "x": x, "y": y}).get("pages")
            except RuntimeError: return "n/a"

        on_button = top + 210        # the button's middle, down the window
        plain = top + 500            # nothing of the page's there
        rows = []
        for x in range(2, 32, 2):
            said = ask(x, on_button)
            heard = pointer(x, on_button)["covered"] is False
            d = downs(); pointer(x, on_button, what="press"); time.sleep(0.15)
            pressed = downs() == d + 1
            # As after the dwell: the column out, then the press.
            sv.cmd({"do": "ui", "peek": True}); time.sleep(0.5)
            d = downs(); pointer(x, on_button, what="press"); time.sleep(0.15)
            under_column = downs() == d + 1
            sv.cmd({"do": "ui", "peek": False}); time.sleep(0.6)
            plain_said = ask(x, plain)
            plain_heard = pointer(x, plain)["covered"] is False
            rows.append((x, said, heard, pressed, under_column, plain_said, plain_heard))
            print(f"  x {x:2}: button asked={said} hover={heard} press(away)={pressed} press(column out)={under_column}"
                  f" | plain asked={plain_said} hover={plain_heard}")
        on_btn = [r for r in rows if left + 4 <= r[0] < left + 14]
        t.ok("a press on the button with the column away is the page's", all(r[3] for r in on_btn))
        t.ok("the page says its button is there", all(r[1] is True for r in on_btn), [r[1] for r in on_btn])
        t.ok("on the button off the true edge, the page hears the pointer",
             all(r[2] for r in on_btn if r[0] >= 4), [(r[0], r[2]) for r in on_btn])
        t.ok("on the true edge (< 4) the page still hears nothing", all(not r[2] for r in rows if r[0] < 4))
        t.ok("on plain page in the band the page hears nothing (Gmail's rail, idea 1048)",
             all(not r[6] for r in rows if r[0] < 28), [(r[0], r[6]) for r in rows])
        t.ok("plain page in the band is nobody's: the column may come", all(r[5] is False for r in rows if r[0] < 28),
             [(r[0], r[5]) for r in rows])
    finally:
        t.done()
        sv.finish()
    return 1 if t.failed else 0


if __name__ == "__main__":
    sys.exit(main())
