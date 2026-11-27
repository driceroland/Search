#!/usr/bin/env python3
"""A frame that loads while hidden is drawn at the page's zoom once shown
(FrameZoom.swift), in the real app: with the zoom above 100% and below it,
and as ⌘+, ⌘−, ⌘0 and Settings › Page zoom move it up and down.

Build first (`./build.sh debug`), then `python3 Tests/frame_zoom.py`.
A hidden probe in a world of its own. The page is on localhost and its
frames on 127.0.0.1, another site's as a sign-in prompt's or a password
manager's dropdown is. Each frame is made as those are: in a closed shadow
root, `display: none`, loaded, then shown. It holds a 100-pixel box and says
how wide it measures it: 100 at the page's zoom, and 100/zoom when WebKit
left the zoom off (90.9 at 110%, 111.1 at 90%). The page script's own
cases, a frame's own style sheets among them, are
Tests/SearchTests/FrameZoomTests.swift's.
"""
import json
import subprocess
import sys
import time
from http.server import BaseHTTPRequestHandler
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("frame-zoom")

PORT = sv.srv.server_port
PAGE_URL = f"http://localhost:{PORT}/page"
# Another site's, as the frames these stand in for are.
FRAMES = f"http://127.0.0.1:{PORT}"
# How wide each frame's box is, in its own pixels.
BOX = 100
# How long a frame has to come right. No longer: a page nobody sees has its
# frames restyled by WebKit itself some seconds after it loads, which is not
# what this looks for.
WAIT = 1.5

FRAME = """<!doctype html><style>html,body{margin:0}#b{width:100px;height:40px;background:#0a0}</style>
<div id=b></div><script>
var id = new URLSearchParams(location.search).get('id');
addEventListener('message', function () {
  parent.postMessage({id: id, box: document.getElementById('b').getBoundingClientRect().width}, '*');
});
</script>"""

PAGE = """<!doctype html><title>frames</title><body style="margin:0">
<iframe id=seen style="display:block;width:300px;height:60px;border:0" src="FRAMES/frame?id=seen"></iframe>
<div id=host></div>
<script>
var got = {}, made = {}, loaded = {}, resizes = 0;
addEventListener('resize', function () { resizes++; });
addEventListener('message', function (e) { if (e.data && e.data.id) got[e.data.id] = e.data.box; });
made.seen = document.getElementById('seen');
var root = document.getElementById('host').attachShadow({mode: 'closed'});
root.innerHTML = '<style>iframe{display:none;width:300px;height:60px;border:0}iframe.visible{display:block}</style>';
function add(id) {
  var f = document.createElement('iframe');
  f.onload = function () { loaded[id] = true; };
  f.src = 'FRAMES/frame?id=' + id;
  made[id] = f; root.appendChild(f);
}
function show(id) { made[id].classList.add('visible'); }
function ask() { got = {}; Object.keys(made).forEach(function (id) { made[id].contentWindow.postMessage('say', '*'); }); }
</script>"""


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        page = FRAME if self.path.startswith("/frame") else PAGE.replace("FRAMES", FRAMES)
        body = page.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


sv.srv.RequestHandlerClass = H


def opened(url):
    """A tab on `url`, loaded."""
    id = sv.cmd({"do": "open", "url": url})["id"]
    sv.cmd({"do": "wait", "id": id})
    time.sleep(0.8)
    return id


def zoom(tab):
    return sv.cmd({"do": "magnify", "id": tab})["zoom"]


def step(tab, **how):
    """⌘+ and ⌘− (`by`), or ⌘0 (`reset`): the zoom the tab is left at."""
    return sv.cmd({"do": "magnify", "id": tab, **how})["zoom"]


def boxes(tab):
    """What each frame measures its box as, asked now."""
    sv.ev(tab, "ask(); true")
    time.sleep(0.12)
    return json.loads(sv.ev(tab, "JSON.stringify(got)") or "{}")


def right(found, ids):
    """Every frame in `ids` answered, and every one is at its page's zoom."""
    return len(found) == len(ids) and all(abs(found[id] - BOX) < 0.5 for id in ids)


def settled(tab, ids):
    """What the frames say once every one is right, or once WAIT is up."""
    end = time.time() + WAIT
    while True:
        found = {id: box for id, box in boxes(tab).items() if id in ids}
        if right(found, ids) or time.time() > end:
            return found


def hidden(tab, id):
    """One more frame, loaded while hidden and then shown."""
    sv.ev(tab, f"add('{id}'); true")
    for _ in range(100):
        if sv.ev(tab, f"loaded['{id}'] === true"):
            break
        time.sleep(0.05)
    sv.ev(tab, f"show('{id}'); true")
    return id


def check(t, tab, ids, what, at):
    """A frame made now is right, and so is every one made before."""
    ids.append(hidden(tab, f"f{len(ids)}"))
    found = settled(tab, ids)
    now = zoom(tab)
    t.ok(f"{what}: at {round(at * 100)}% a frame shown late is drawn at the page's zoom, the earlier ones too",
         right(found, ids) and abs(now - at) < 0.001, (now, found))


def main():
    t = sv.T()
    try:
        # A default zoom above 100%.
        sv.setup()
        subprocess.run(["defaults", "write", sv.SUITE, "pageZoom", "-float", "1.1"])
        sv.launch()

        tab = opened(PAGE_URL)
        ids = ["seen"]
        sv.ev(tab, "resizes = 0; true")
        check(t, tab, ids, "the default zoom, above 100%", 1.1)
        # Before any ⌘+ or ⌘−, which resize the page as they should.
        heard = sv.ev(tab, "resizes")
        t.ok("…and the page around the frame is not resized for it", heard == 0, heard)

        # Going up: ⌘+ twice.
        at = 1.1
        for n in range(2):
            at = step(tab, by=1.1)
            check(t, tab, ids, f"⌘+ ({n + 1})", at)
        t.ok("…which went up", at > 1.3, at)

        # Going down: ⌘− through 100% and under it.
        for n in range(5):
            at = step(tab, by=1 / 1.1)
            check(t, tab, ids, f"⌘− ({n + 1})", at)
        t.ok("…which went down past 100%", at < 0.95, at)

        # And up again from under 100%.
        at = step(tab, by=1.1)
        check(t, tab, ids, "⌘+ from under 100%", at)

        # ⌘0: back to the default.
        step(tab, reset=True)
        check(t, tab, ids, "⌘0", 1.1)

        # Settings › Page zoom moved under 100%, then over it: a tab with no
        # zoom of its own follows, and its frames with it.
        for default, way in ((0.9, "down"), (1.25, "up")):
            sv.cmd({"do": "ui", "pageZoom": default})
            time.sleep(0.6)
            check(t, tab, ids, f"Settings › Page zoom {way}", default)

        # A tab opened at each: the frame is shown late in a page that began
        # zoomed.
        for default in (0.8, 1.5):
            sv.cmd({"do": "ui", "pageZoom": default})
            time.sleep(0.6)
            check(t, opened(PAGE_URL), ["seen"], "a new tab", default)

        # 100%: nothing was missed, and nothing moved.
        sv.cmd({"do": "ui", "pageZoom": 1.0})
        time.sleep(0.6)
        check(t, opened(PAGE_URL), ["seen"], "at 100%", 1.0)
    finally:
        sv.finish()
        t.done()
    return 1 if t.failed else 0


if __name__ == "__main__":
    sys.exit(main())
