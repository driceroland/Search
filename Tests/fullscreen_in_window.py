#!/usr/bin/env python3
"""Keep full screen in the window (PageFullScreen.swift), in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/fullscreen_in_window.py`.
With the setting on, a page's full screen asked for by a real click fills
the browser's window: the window never goes into macOS full screen, the
page's viewport grows to the window's size as the column steps aside, the
element is laid over the viewport, and the page's own API says it is full
screen. Esc gives the column back. A frame of another origin, with
allowfullscreen, fills the window with its iframe. Without a click, the
request is refused and nothing changes. With the setting off, the script
isn't in the page at all.
"""
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("fullscreen-in-window")

PAGE = """<!doctype html><title>player</title>
<style>body{margin:0} #box{width:320px;height:180px;margin:60px;background:#08f;transform:translateZ(0)}
#go{position:absolute;left:10px;top:10px;width:120px;height:40px}</style>
<div id=box><button id=go onclick="document.getElementById('box').requestFullscreen()
  .then(function(){window.went='yes'}, function(e){window.went='no:'+e})">Full</button></div>
<script>window.changes=0; document.addEventListener('fullscreenchange', function(){window.changes++});
// Asked by the page itself, with no click: refused.
setTimeout(function(){ document.getElementById('box').requestFullscreen()
  .then(function(){window.bare='yes'}, function(){window.bare='no'}) }, 300)</script>"""

FRAME = """<!doctype html><style>html,body{margin:0;height:100%}
button{width:100%;height:100%}</style>
<button onclick="document.documentElement.requestFullscreen()">Full</button>"""


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/player":
            body = PAGE
        elif self.path == "/framed":
            body = (f"<!doctype html><title>framed</title><style>body{{margin:0}}</style>"
                    f"<iframe id=f allowfullscreen style='width:300px;height:200px;margin:40px;border:0' "
                    f"src='http://localhost:{self.server.server_port}/inner'></iframe>")
        elif self.path == "/inner":
            body = FRAME
        else:
            body = "<!doctype html><title>x</title>"
        data = body.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *a):
        pass


srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{srv.server_port}"


def ev(tab, js):
    return sv.cmd({"do": "eval", "id": tab, "js": js}).get("value")


def size(tab):
    return ev(tab, "[innerWidth, innerHeight]")


def window_full():
    return sv.cmd({"do": "probe"})["cards"]["windowFullScreen"]


def opened(path):
    tab = sv.sp("open", url=f"{BASE}/{path}")["resultID"]
    time.sleep(1.5)
    return tab


def main():
    t = sv.T()

    print("setting on")
    sv.setup(**{"fullscreen.inWindow": True, "sidebar": True})
    sv.launch()
    try:
        tab = opened("player")
        t.ok("the script is in the page", ev(tab, "!!window.__searchInWindowFullscreen") is True)
        # Asked by the page as it loaded, not by a click: refused. (Not from
        # the bench's eval, which WebKit counts as a user's gesture.)
        t.ok("a request without a click is refused", ev(tab, "window.bare") == "no", ev(tab, "window.bare"))
        t.ok("and nothing is full screen", ev(tab, "document.fullscreenElement") is None)
        before = size(tab)
        t.ok("the column still beside the page", before[0] < 1100, before)

        sv.cmd({"do": "tap", "id": tab, "selector": "#go"})
        time.sleep(1.5)
        t.ok("the click's request goes through", ev(tab, "window.went") == "yes", ev(tab, "window.went"))
        t.ok("document.fullscreenElement is the box",
             ev(tab, "document.fullscreenElement === document.getElementById('box')") is True)
        t.ok("fullscreenchange came", ev(tab, "window.changes") == 1, ev(tab, "window.changes"))
        t.ok("the window is not in macOS full screen", window_full() is False)
        during = size(tab)
        t.ok("the page grew to the window, the column gone",
             during[0] > before[0], f"{before} -> {during}")
        box = ev(tab, "var r=document.getElementById('box').getBoundingClientRect(); [r.left,r.top,r.width,r.height]")
        t.ok("the box covers the viewport", box == [0, 0, during[0], during[1]], f"{box} in {during}")

        sv.cmd({"do": "key", "id": tab, "text": "\u001b"})
        time.sleep(1.5)
        t.ok("Esc leaves", ev(tab, "document.fullscreenElement") is None)
        t.ok("fullscreenchange came again", ev(tab, "window.changes") == 2, ev(tab, "window.changes"))
        t.ok("the page is back at its size", size(tab) == before, f"{before} -> {size(tab)}")
        t.ok("the box is back in the page",
             ev(tab, "document.getElementById('box').getBoundingClientRect().width") == 320)

        frame_tab = opened("framed")
        before = size(frame_tab)
        sv.cmd({"do": "tap", "id": frame_tab, "selector": "#f"})
        time.sleep(1.5)
        t.ok("a frame's full screen fills the window with its iframe",
             ev(frame_tab, "document.fullscreenElement === document.getElementById('f')") is True)
        during = size(frame_tab)
        t.ok("and the page grew", during[0] > before[0], f"{before} -> {during}")
        t.ok("the iframe covers the viewport",
             ev(frame_tab, "var r=document.getElementById('f').getBoundingClientRect(); [r.width,r.height]") == during)
        t.ok("the window is not in macOS full screen", window_full() is False)
        sv.cmd({"do": "eval", "id": frame_tab, "world": "search",
                "js": "document.dispatchEvent(new Event('__searchleavefullscreen')); 1"})
        time.sleep(1.5)
        t.ok("Search's leave ends it", ev(frame_tab, "document.fullscreenElement") is None)
        t.ok("and the page is back", size(frame_tab) == before, f"{before} -> {size(frame_tab)}")
    finally:
        sv.quit()

    print("setting off")
    sv.setup(**{"fullscreen.inWindow": False, "sidebar": True})
    sv.launch()
    try:
        tab = opened("player")
        t.ok("off, the script isn't in the page", ev(tab, "!!window.__searchInWindowFullscreen") is False)
    finally:
        sv.finish()

    t.done()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
