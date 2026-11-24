#!/usr/bin/env python3
"""Float the video when you switch apps waits until the window is out of
sight (idea 470), and stops waiting when Search comes back.

Build first (`./build.sh`), then `python3 Tests/float_away_sight.py`. A
hidden probe's window is never in view and macOS never changes its
occlusion, so the bench's `seam` tells the window it is in sight or not
and posts the occlusion notification macOS would; leaving the app and
coming back are the browser's appLeft and appBack, as the app's own
notifications call them. The little window opens off every screen.

Checked: left with the window in sight, the video stays in its page; out
of sight, it floats; back, it lands, and no watch is left: the window
going out of sight again lifts nothing. Left and come back with the
window in sight all along, nothing floats then or later. Left twice
without coming back in between (two windows' notifications, or the
bench), then back: nothing is left watching. Left with the window already
out of sight, it floats at once, as before.
"""
import functools
import shutil
import sys
import tempfile
import threading
import time
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("float-away-sight")

PAGE = """<!doctype html><meta charset=utf-8><title>video</title>
<style>body{margin:0}video{width:640px;height:360px;display:block;background:#000}</style>
<video playsinline></video><canvas width=320 height=180 style="display:none"></canvas>
<script>
var c=document.querySelector('canvas'),g=c.getContext('2d'),n=0;
setInterval(function(){g.fillStyle='hsl('+(n++*7%360)+',70%,50%)';g.fillRect(0,0,320,180);},40);
var v=document.querySelector('video'); v.srcObject=c.captureStream(25); v.play();
</script>"""


def seam(**f):
    return sv.cmd({"do": "seam", **f})


def settle(wait=1.5):
    return seam(wait=wait)


def main():
    pages = tempfile.mkdtemp(prefix="search-float-sight-")
    Path(pages, "video.html").write_text(PAGE)

    class Quiet(SimpleHTTPRequestHandler):
        def log_message(self, *args):
            pass
    server = ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(Quiet, directory=pages))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    t = sv.T()
    try:
        sv.setup(**{"float.away": True}); sv.launch()
        sv.cmd({"do": "window"}); time.sleep(1)
        tab = sv.sp("open", url=f"http://127.0.0.1:{server.server_port}/video.html")["resultID"]
        sv.cmd({"do": "select", "id": tab}); time.sleep(2)

        # Left with the window in sight: the video stays in its page.
        seam(visible=True)
        s = seam(app="left", wait=1.5)
        t.ok("the video plays", s["playing"] is True, s)
        t.ok("left with the window in sight, the video stays in its page", s["showing"] is False, s)
        # Out of sight: it floats.
        s = seam(visible=False, wait=2)
        t.ok("the window out of sight, the video floats", s["showing"] is True and s["floating"] != "", s)
        # Back: it lands, and nothing is left watching.
        s = seam(app="back", wait=2)
        t.ok("back, the video lands", s["showing"] is False, s)
        seam(visible=True); s = seam(visible=False, wait=2)
        t.ok("back, the window going out of sight again lifts nothing", s["showing"] is False, s)

        # Left and back with the window in sight all along.
        seam(visible=True)
        s = seam(app="left", wait=1)
        seam(app="back", wait=0.5)
        s = seam(visible=False, wait=2)
        t.ok("left and back in sight: nothing floats later", s["showing"] is False, s)

        # Left twice without coming back in between, then back.
        seam(visible=True)
        seam(app="left", wait=0.5); seam(app="left", wait=0.5)
        s = seam(app="back", wait=0.5)
        t.ok("left twice in sight: still nothing floating", s["showing"] is False, s)
        s = seam(visible=False, wait=2)
        t.ok("left twice, then back: no watch is left to lift the video", s["showing"] is False, s)
        if s["showing"]:
            seam(app="back", wait=2)

        # Left with the window already out of sight: at once, as before.
        seam(visible=False)
        s = seam(app="left", wait=2)
        t.ok("left out of sight, the video floats at once", s["showing"] is True, s)
        s = seam(app="back", wait=2)
        t.ok("and lands when Search is back", s["showing"] is False, s)
        seam(real=True)
    finally:
        t.done(); sv.finish()
        server.shutdown()
        shutil.rmtree(pages, ignore_errors=True)
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
