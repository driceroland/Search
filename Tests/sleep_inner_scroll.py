#!/usr/bin/env python3
"""A tab that slept wakes where it was in a page that scrolls inside itself
(idea 1149), in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/sleep_inner_scroll.py`. It
uses the split suite's harness: started hidden, no window made or shown,
everything removed afterwards.

Google Docs, Sheets, Notion and most web apps keep the window still and
scroll one big element inside it (Docs' .kix-appview-editor). A sleeping
tab's view brings back the window's scroll (interactionState) and nothing
else, so a long document woke at its top. The pages here are made that way:
the document is an overflow:auto box filling the window, drawn at once or,
like an app, a moment after the page loads.
"""
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("sleep-inner-scroll")

LINES = "".join(f"<p>Line {n}</p>" for n in range(1500))
BOX = "<div id=ed class='kix-appview-editor' style='position:absolute;inset:0;overflow:auto'>" + LINES + "</div>"
PAGES = {
    # The box is in the page as it arrives.
    "/doc": f"<!doctype html><title>doc</title><style>html,body{{margin:0;height:100%;overflow:hidden}}</style><body>{BOX}",
    # The box is drawn by the page's script, 1.2 s after it loads.
    "/app": "<!doctype html><title>app</title><style>html,body{margin:0;height:100%;overflow:hidden}</style><body><div id=root>Loading…</div>"
            "<script>setTimeout(() => { document.getElementById('root').innerHTML = " + repr(BOX) + " }, 1200)</script>",
    # The window itself scrolls: what already came back.
    "/plain": f"<!doctype html><title>plain</title><body style='margin:0'>{LINES}",
}
class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        body = PAGES.get(self.path.split("?")[0], "<!doctype html><title>other</title><p>other").encode()
        self.send_response(200); self.send_header("Content-Type", "text/html"); self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
server = ThreadingHTTPServer(("127.0.0.1", 0), Page)
threading.Thread(target=server.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{server.server_port}"

TOP = "(document.getElementById('ed') || {scrollTop: -1}).scrollTop"
t = sv.T()

def open_at(path, where, js=TOP, scroll=None):
    a = sv.cmd({"do": "split", "action": "open", "url": BASE + path})["resultID"]
    sv.cmd({"do": "select", "id": a}); sv.cmd({"do": "wait", "id": a, "seconds": 8}); time.sleep(1.6)
    sv.ev(a, scroll or f"document.getElementById('ed').scrollTop = {where}")
    time.sleep(0.4)
    before = sv.ev(a, js)
    b = sv.page("other"); sv.cmd({"do": "select", "id": b}); time.sleep(0.8)
    slept = sv.cmd({"do": "sleep", "id": a})
    return a, b, before, slept

def back_to(a, within=4.0, js=TOP):
    sv.cmd({"do": "select", "id": a}); sv.cmd({"do": "wait", "id": a, "seconds": 8})
    end, seen = time.time() + within, None
    while time.time() < end:
        try: seen = sv.ev(a, js)
        except Exception: pass
        time.sleep(0.2)
    return seen

def close(*ids):
    for i in ids: sv.sp("close", id=i)
    time.sleep(0.4)

def case_box():
    a, b, before, slept = open_at("/doc", 6000)
    t.ok("doc: scrolled inside its box before sleeping", before == 6000, before)
    t.ok("doc: asleep", slept.get("asleep") is True, slept)
    after = back_to(a)
    t.ok("doc: wakes at the same place in its box", after == 6000, after)
    close(a, b)

def case_late():
    a, b, before, slept = open_at("/app", 9000)
    t.ok("app: scrolled inside its box before sleeping", before == 9000, before)
    t.ok("app: asleep", slept.get("asleep") is True, slept)
    after = back_to(a, within=4.5)
    t.ok("app: the box drawn late still comes back to its place", after == 9000, after)
    close(a, b)

def case_plain():
    js = "Math.round(scrollY)"
    a, b, before, slept = open_at("/plain", 0, js=js, scroll="scrollTo(0, 5000)")
    t.ok("plain: asleep", slept.get("asleep") is True, slept)
    after = back_to(a, js=js)
    t.ok("plain: a page that scrolls the window still wakes where it was", after == before == 5000, (before, after))
    close(a, b)

def case_user_first():
    # The person scrolls the box before it is put back: theirs stands.
    a, b, before, slept = open_at("/app", 9000)
    t.ok("user first: asleep", slept.get("asleep") is True, slept)
    sv.cmd({"do": "select", "id": a}); sv.cmd({"do": "wait", "id": a, "seconds": 8})
    # Wait for the box, then wheel it at once, before the retry has put it back.
    for _ in range(40):
        if sv.ev(a, TOP) != -1: break
        time.sleep(0.05)
    sv.cmd({"do": "notches", "id": a, "notches": 2, "gap": 60, "lines": -3, "probe": TOP})
    time.sleep(3.5)
    after = sv.ev(a, TOP)
    t.ok("user first: a box the person scrolled isn't moved back", 0 < after < 2000, after)
    close(a, b)

def case_other_page():
    # The tab went somewhere else after waking: the old place isn't put there.
    a, b, before, slept = open_at("/doc", 6000)
    t.ok("other page: asleep", slept.get("asleep") is True, slept)
    sv.cmd({"do": "select", "id": a}); sv.cmd({"do": "wait", "id": a, "seconds": 8}); time.sleep(1.5)
    sv.cmd({"do": "go", "id": a, "url": BASE + "/doc?again"}); sv.cmd({"do": "wait", "id": a, "seconds": 8}); time.sleep(2.5)
    after = sv.ev(a, TOP)
    t.ok("other page: a new page in the tab starts at its top", after == 0, after)
    close(a, b)

try:
    sv.setup(); sv.launch()
    case_box()
    case_late()
    case_plain()
    case_user_first()
    case_other_page()
finally:
    t.done(); sv.finish()
sys.exit(1 if t.failed else 0)
