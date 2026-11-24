#!/usr/bin/env python3
"""Idea 1079: after a click on a video's play button, Space and the arrow
keys play, pause and seek it, as in other browsers.

Build first (`./build.sh`), then `python3 Tests/video_keys.py`. It uses the
split suite's harness: started hidden in a world of its own, no window made
or shown, everything removed afterwards. The clip is made here with ffmpeg
(twenty silent seconds of a test card), so nothing is heard.

Two players on a local page: a native <video controls>, and a custom one
(a button, and keydown handlers on the document). The video is clicked as a
hand would (the bench's `tap`), then Space and ← → are pressed through the
app's event queue, so Search's own key handling sees them first, as it does
a real press.

Search never kept those keys from the page: they reach it, setting on or
off. WebKit's own controls do nothing with them in the page (only Space,
filling the screen), in Safari too. With Settings › Videos › Space and arrow
keys control videos on, they play, pause and seek the clicked video; a page
that uses the key on the video itself keeps it; off, the video is left as
WebKit has it.
"""
import http.server
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("video-keys")
t = sv.T()

FOLDER = Path(tempfile.mkdtemp(prefix="video-keys-"))
if not shutil.which("ffmpeg"): sys.exit("needs ffmpeg")
subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc=size=320x240:rate=25", "-t", "20",
                "-c:v", "libx264", "-pix_fmt", "yuv420p", "-movflags", "+faststart", str(FOLDER / "clip.mp4")], check=True)

PAGE = b"""<!doctype html><title>players</title>
<style>body{margin:0} video{display:block;width:320px;height:240px} #custom{width:320px;height:100px;background:#333}</style>
<video id=v controls playsinline></video>
<div id=custom><button id=play>Play</button></div>
<script>
fetch('clip.mp4').then(r => r.blob()).then(b => { document.getElementById('v').src = URL.createObjectURL(b); });
window.log = [];
document.addEventListener('keydown', e => window.log.push(e.key), true);
// The custom player: its keys on the document, as many sites have them.
window.custom = { playing: false, t: 0 };\n// ?own: the site takes Space on the video itself.\nif (location.search === '?own') document.addEventListener('keydown', e => { if (e.target.tagName === 'VIDEO' && e.key === ' ') { e.preventDefault(); window.own = (window.own || 0) + 1; } });
document.getElementById('play').addEventListener('click', () => { custom.playing = !custom.playing; });
document.addEventListener('keydown', e => {
  if (e.target.tagName === 'VIDEO') return;
  if (e.key === ' ') { custom.playing = !custom.playing; e.preventDefault(); }
  if (e.key === 'ArrowRight') { custom.t += 5; e.preventDefault(); }
  if (e.key === 'ArrowLeft') { custom.t -= 5; e.preventDefault(); }
});
</script>"""


class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = (FOLDER / "clip.mp4").read_bytes() if self.path.endswith("clip.mp4") else PAGE
        kind = "video/mp4" if self.path.endswith("clip.mp4") else "text/html"
        self.send_response(200); self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)

    def log_message(self, *a): pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
threading.Thread(target=server.serve_forever, daemon=True).start()
URL = f"http://localhost:{server.server_port}/players"

KEYS = {"space": (49, " "), "left": (123, ""), "right": (124, ""), "up": (126, ""), "down": (125, "")}


def press(name):
    code, chars = KEYS[name]
    mods = ["arrow"] if name != "space" else []
    sv.cmd({"do": "press", "code": code, "chars": chars, "mods": mods}); time.sleep(0.4)


def ev(tab, js): return sv.ev(tab, js)


def state(tab):
    return ev(tab, "JSON.stringify({paused: v.paused, time: Math.round(v.currentTime * 10) / 10, "
                   "active: document.activeElement && document.activeElement.tagName, log: window.log, custom: window.custom})")


import json


def run(on):
    sv.setup()
    subprocess.run(["defaults", "write", sv.SUITE, "video.keys", "-bool", "true" if on else "false"])
    sv.launch()
    word = "on" if on else "off"
    tab = sv.sp("open", url=URL)["resultID"]; time.sleep(1)
    sv.cmd({"do": "select", "id": tab}); sv.cmd({"do": "wait", "id": tab, "seconds": 10}); time.sleep(2)

    # The native player: clicked, then the keys.
    sv.cmd({"do": "key", "id": tab, "text": ""})  # the keys to the page, as a click leaves them
    sv.cmd({"do": "tap", "id": tab, "selector": "#v"}); time.sleep(1.5)
    before = json.loads(state(tab)); print(f"{word}: after the click:", before)
    t.ok(f"{word}: the clicked video holds the focus", before["active"] == "VIDEO", before)
    ev(tab, "window.log = [], 1")
    press("space"); time.sleep(0.6)
    after = json.loads(state(tab))
    t.ok(f"{word}: Space reaches the page", after["log"] == [" "], after)
    t.ok(f"{word}: Space {'pauses' if on else 'leaves'} the video", after["paused"] == (not before["paused"] if on else before["paused"]),
         f"{before['paused']} → {after['paused']}")
    press("space"); time.sleep(0.6)
    again = json.loads(state(tab))
    if on: t.ok(f"{word}: Space again plays it", again["paused"] is False, again)
    ev(tab, "v.pause(), v.currentTime = 10, 1"); time.sleep(0.5)
    press("right"); r = json.loads(state(tab))
    t.ok(f"{word}: → reaches the page", "ArrowRight" in r["log"], r)
    t.ok(f"{word}: → {'goes 5 s on' if on else 'leaves the time'}", r["time"] == (15 if on else 10), r["time"])
    press("left"); press("left"); l = json.loads(state(tab))
    t.ok(f"{word}: ← {'goes 5 s back' if on else 'leaves the time'}", l["time"] == (5 if on else 10), l["time"])

    # The custom player: its button clicked, then the keys, handled once.
    ev(tab, "window.log = [], custom.playing = false, custom.t = 0, 1")
    sv.cmd({"do": "tap", "id": tab, "selector": "#play"}); time.sleep(0.5)
    c = json.loads(state(tab))
    press("space"); press("right"); press("right"); press("left")
    c2 = json.loads(state(tab))
    t.ok(f"{word}: custom: the keys reach the page", c2["log"][:4] == [" ", "ArrowRight", "ArrowRight", "ArrowLeft"], c2["log"])
    t.ok(f"{word}: custom: Space toggles it once", c2["custom"]["playing"] != c["custom"]["playing"], c2)
    t.ok(f"{word}: custom: the arrows seek it", c2["custom"]["t"] == 5, c2)
    t.ok(f"{word}: custom: the native video is left alone", c2["paused"] is True and c2["time"] == l["time"], c2)

    # A site that takes Space on the video itself keeps it.
    if on:
        own = sv.sp("open", url=URL + "?own")["resultID"]; time.sleep(1)
        sv.cmd({"do": "select", "id": own}); sv.cmd({"do": "wait", "id": own, "seconds": 10}); time.sleep(2)
        sv.cmd({"do": "key", "id": own, "text": ""})
        sv.cmd({"do": "tap", "id": own, "selector": "#v"}); time.sleep(1.5)
        b = json.loads(state(own))
        press("space"); time.sleep(0.6)
        a = json.loads(state(own))
        t.ok("on: a site's own Space on the video is left to it", a["paused"] == b["paused"] and ev(own, "window.own") == 1, f"{b} → {a}")
    sv.finish()


try:
    for on in (False, True):
        run(on)
finally:
    t.done(); sv.finish(); server.shutdown(); shutil.rmtree(FOLDER, ignore_errors=True)
sys.exit(1 if t.failed else 0)
