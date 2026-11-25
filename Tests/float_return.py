#!/usr/bin/env python3
"""The floating video's return button goes back to the video's own tab, in
its own window, and makes no window (idea 1177).

Build first (`./build.sh`), then `python3 Tests/float_return.py`. A hidden
probe floats a local page's video (⇧⌘P's path) into the little window off
every screen, then presses its return button through the bench, with the
video's tab in front, in another of the window's spaces, behind another
window, in another profile's window, and after the tab was closed or put to
sleep. Nothing is ordered in during a test run: the bench tells which
window the button would bring forward, and counts the windows made.
Before, the button brought forward the app's first window, whichever it
was ("firstWindow").
"""
import functools
import sys
import tempfile
import threading
import time
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("float-return")

PAGE = """<!doctype html><meta charset=utf-8><title>video</title>
<style>body{margin:0}video{width:640px;height:360px;display:block}</style>
<video muted playsinline></video>
<canvas width=320 height=180 style="display:none"></canvas>
<script>
var c=document.querySelector('canvas'),g=c.getContext('2d'),n=0;
setInterval(function(){g.fillStyle='hsl('+(n++*7%360)+',70%,50%)';g.fillRect(0,0,320,180);},40);
var v=document.querySelector('video'); v.srcObject=c.captureStream(25); v.play();
</script>"""


def serve():
    root = Path(tempfile.mkdtemp(prefix="float-return-"))
    (root / "video.html").write_text(PAGE)
    handler = functools.partial(SimpleHTTPRequestHandler, directory=str(root))
    handler.log_message = lambda *a: None
    server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return f"http://127.0.0.1:{server.server_port}/video.html"


def video(url, window=1):
    tab = sv.cmd({"do": "open", "url": url, "window": window})["id"]
    sv.cmd({"do": "select", "id": tab, "window": window})
    time.sleep(1.5)
    return tab


def lift(t, name, window=1):
    up = sv.cmd({"do": "float", "action": "lift", "window": window, "wait": 1.5})
    t.ok(f"{name}: the video floats", up.get("showing") is True and up.get("floating"), up)
    return up


def back(t, name, owner, tab):
    r = sv.cmd({"do": "float", "action": "return"})
    print("     ", name, {k: r.get(k) for k in ("owner", "to", "firstWindow", "space", "active")})
    t.ok(f"{name}: the little window closed", r.get("showing") is False and r.get("floating") is False, r)
    t.ok(f"{name}: back to the video's own window", r.get("owner") == owner and r.get("to") == owner, r)
    t.ok(f"{name}: its tab in front there", r.get("active") == tab, r)
    t.ok(f"{name}: no window made", r.get("browsersMade") == 0 and r.get("windowsMade") == 0, r)
    t.ok(f"{name}: nothing on screen", r.get("onScreen") == 0, r)
    return r


t = sv.T()
try:
    url = serve()
    sv.setup()
    sv.launch()

    # 1. The video's tab, in front in its own window.
    tab = video(url)
    lift(t, "same window")
    back(t, "same window", 1, tab)

    # 2. The window gone on to another of its spaces.
    lift(t, "other space")
    sv.cmd({"do": "space", "action": "new", "name": "Other"})
    sv.cmd({"do": "space", "action": "go", "index": 2})
    time.sleep(0.6)
    r = back(t, "other space", 1, tab)
    t.ok("other space: the video's space again", r.get("space") != "Other", r)

    # 3. Another window opened, and in front, since.
    lift(t, "other window")
    sv.cmd({"do": "windows", "action": "new"})
    sv.cmd({"do": "windows", "action": "front", "n": 2})
    back(t, "other window", 1, tab)

    # 4. The video in the second window: the first is not the one.
    tab2 = video(url, window=2)
    lift(t, "second window", window=2)
    r = back(t, "second window", 2, tab2)
    t.ok("second window: the app's first window was what came up before",
         r.get("firstWindow") != "owner", r)

    # 5. Another profile's window.
    sv.cmd({"do": "profile", "action": "new", "name": "Other"})
    sv.cmd({"do": "profile", "action": "window", "name": "Other"})
    time.sleep(1)
    n = len(sv.cmd({"do": "windows", "action": "list"})["windows"])
    tab3 = video(url, window=n)
    lift(t, "other profile", window=n)
    back(t, "other profile", n, tab3)

    # 6. The tab closed, or asleep, while out: the little window goes with it,
    # and the button has nothing to bring.
    lift(t, "closed tab")
    sv.cmd({"do": "close", "id": tab})
    time.sleep(0.5)
    shown = sv.cmd({"do": "float", "action": "showing"})
    t.ok("closed tab: the little window closed with it", shown.get("showing") is False, shown)
    r = sv.cmd({"do": "float", "action": "return"})
    t.ok("closed tab: the button brings nothing", r.get("to") == 0 and r.get("browsersMade") == 0
         and r.get("windowsMade") == 0 and r.get("onScreen") == 0, r)

    # Asleep: a floating video keeps its tab awake, so the button still
    # finds it; one that did sleep took the little window with it.
    tab = video(url)
    lift(t, "asleep")
    slept = sv.cmd({"do": "sleep", "id": tab})
    time.sleep(0.5)
    print("      sleep:", slept)
    if slept.get("asleep"):
        shown = sv.cmd({"do": "float", "action": "showing"})
        t.ok("asleep: the little window closed", shown.get("showing") is False, shown)
        r = sv.cmd({"do": "float", "action": "return"})
        t.ok("asleep: the button brings nothing", r.get("to") == 0 and r.get("browsersMade") == 0
             and r.get("windowsMade") == 0 and r.get("onScreen") == 0, r)
    else:
        back(t, "kept awake", 1, tab)
finally:
    t.done()
    sv.finish()
sys.exit(1 if t.failed else 0)
