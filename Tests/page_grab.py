#!/usr/bin/env python3
"""The window moved by the top of the page (Grab.swift), in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/page_grab.py`. Uses the
split suite's harness, in a world of its own: started hidden, no window made or shown, everything
removed afterwards. What is checked here is the page's side: which points
of a site's top bar count as empty ground, that the view hears it, and that
a click on that ground still reaches the page. The drag itself moves a
window on a screen, so it is checked by hand on a release candidate.
"""
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

# A world of its own rather than the split suite's, so another suite running
# at the same time can't take its socket.
sv.W = "grab-tests"
sv.SUPPORT = f"{sv.HOME}/Library/Application Support/Search ({sv.W})"
sv.SUITE = f"com.officecommun.search.test.{sv.W}"

HEADER = b"""<!doctype html><title>bar</title>
<style>
  body { margin: 0; font: 16px -apple-system, sans-serif }
  header { position: sticky; top: 0; height: 64px; display: flex; align-items: center; gap: 24px; padding: 0 24px; background: #eee }
  .clicky { cursor: pointer; width: 40px; height: 40px; background: #ccc }
  .quiet { -webkit-user-select: none; user-select: none }
  main { height: 3000px; padding: 24px }
</style>
<header>
  <a href="/x" id="link">Link</a><button id="btn">Button</button><span id="words">Some words</span>
  <span id="quiet" class="quiet">Quiet</span><div id="clicky" class="clicky"></div><input id="field">
  <div id="role" role="button" style="width: 40px; height: 40px"></div><div id="empty" style="flex: 1; height: 40px"></div>
</header>
<main><p id="para">A paragraph</p></main>
<script>window.clicks = 0; addEventListener('click', () => window.clicks++)</script>
"""
PLAIN = b"<!doctype html><title>plain</title><body style='margin:0'><p style='margin:200px 40px'>Only words, far down</p>"


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        body = HEADER if self.path == "/bar" else PLAIN
        self.send_response(200); self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)

    def log_message(self, *a): pass


srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{srv.server_port}"


def open_page(path):
    # Waited for, loaded: the first page after a launch can take a while.
    r = sv.sp("open", url=f"{BASE}/{path}")["resultID"]
    for _ in range(50):
        try:
            if sv.ev(r, "location.pathname + document.readyState") == f"/{path}complete": break
        except RuntimeError:
            pass
        time.sleep(0.2)
    time.sleep(0.3)
    return r


def search(id, js):
    return sv.cmd({"do": "eval", "id": id, "js": js, "world": "search"}).get("value")


def at_element(id, el):
    return search(id, f"""(() => {{ const r = document.getElementById('{el}').getBoundingClientRect();
        return window.__searchGrab.at(r.left + r.width / 2, r.top + r.height / 2); }})()""")


def at(id, x, y):
    return search(id, f"window.__searchGrab.at({x}, {y})")


def main():
    t = sv.T()
    try:
        sv.setup(); sv.launch()
        off = open_page("bar")
        t.ok("off: pages get no listener", search(off, "typeof window.__searchGrab") == "undefined")
        sv.quit()
        subprocess.run(["defaults", "write", sv.SUITE, "window.bypage", "-bool", "true"])
        sv.launch()
        bar = open_page("bar")
        t.ok("on: the page has the listener", search(bar, "typeof window.__searchGrab") == "object")
        t.ok("empty ground in the header is the window's", at_element(bar, "empty") is True)
        for el in ["link", "btn", "words", "clicky", "field", "role"]:
            t.ok(f"{el} stays the page's", at_element(bar, el) is False)
        t.ok("words that can't be selected are ground", at_element(bar, "quiet") is True)
        t.ok("below the header, the page's own", at(bar, 400, 140) is False)
        search(bar, "scrollTo(0, 600)"); time.sleep(0.3)
        t.ok("scrolled: the sticky header still is", at_element(bar, "empty") is True)
        t.ok("scrolled: the article under it isn't", at(bar, 400, 100) is False)

        # The relay reaches the view, from the main frame.
        search(bar, "scrollTo(0, 0)")
        search(bar, "webkit.messageHandlers.officeGrab.postMessage(true), true"); time.sleep(0.2)
        g = sv.cmd({"do": "grab", "id": bar})
        t.ok("the view hears the page", g["grabbable"] is True and g["on"] is True, g)
        # A click on the ground is held until let go, then the page has it whole.
        before = sv.ev(bar, "window.clicks")
        sv.cmd({"do": "tap", "id": bar, "selector": "#empty"}); time.sleep(0.3)
        t.ok("a click on the ground still reaches the page", sv.ev(bar, "window.clicks") == before + 1)
        search(bar, "webkit.messageHandlers.officeGrab.postMessage(false), true"); time.sleep(0.2)
        t.ok("and the view hears no again", sv.cmd({"do": "grab", "id": bar})["grabbable"] is False)
        plain = open_page("plain")
        t.ok("a page without a header: its top edge is", at(plain, 400, 20) is True)
        t.ok("a page without a header: below the edge isn't", at(plain, 400, 120) is False)
    finally:
        t.done(); sv.finish()
    return 1 if t.failed else 0


if __name__ == "__main__":
    sys.exit(main())
