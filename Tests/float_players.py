#!/usr/bin/env python3
"""Float the video on its own, on sites outside the list of streaming sites
(idea 1248): Video.js's and Plyr's home pages, and beIN's sign-in page.

Build first (`./build.sh`), then `python3 Tests/float_players.py`. Needs the
network; beIN refuses some countries (403 Forbidden), and is then skipped.
In a hidden probe, each site's player is played, then the bench's
`float leave` goes to another tab as ⌃Tab does, without taking the page for
a player's (as `film float` does): the site's own video must float, as ⇧⌘P
floats it. Never heard: the tab is muted (`mute`) before the page loads, and
every video's sound is drawn into an audio graph that goes nowhere before
it plays.

A local page checks the other side: a muted background video, on a site
outside the list, still floats nothing.
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

sv.use("float-players")

SITES = [
    ("Video.js", "https://videojs.org/"),
    ("Plyr", "https://plyr.io/"),
    ("beIN", "https://connect-id.beinsports.com/en"),
]
# beIN answers 403 Forbidden outside its countries: reported, not failed.
BLOCKED = "document.title.indexOf('403') === 0"

# Silenced at the source first, then played. The tab is muted already.
PLAY = """(function(){
  var vs = [].slice.call(document.querySelectorAll('video'));
  if (!vs.length) return 'no video';
  window.__sink = window.__sink || new (window.AudioContext || window.webkitAudioContext)();
  vs.forEach(function (v) {
    try { if (!v.__sunk) { window.__sink.createMediaElementSource(v); v.__sunk = true; } } catch (e) {}
  });
  var v = vs.sort(function (a, b) {
    var x = a.getBoundingClientRect(), y = b.getBoundingClientRect();
    return y.width * y.height - x.width * x.height;
  })[0];
  if (!v.__sunk) return 'not sunk';
  v.muted = false; v.volume = 1;
  var p = v.play(); if (p && p.catch) p.catch(function (e) { window.__playError = String(e); });
  return 'ok';
})()"""
STATE = """(function(){var v=document.querySelectorAll('video'),o=[];for(var i=0;i<v.length;i++){var b=v[i].getBoundingClientRect();
o.push({paused:v[i].paused,muted:v[i].muted,w:Math.round(b.width),h:Math.round(b.height),d:v[i].duration,sunk:!!v[i].__sunk});}
return JSON.stringify({videos:o,err:window.__playError||null})})()"""
PLAYING = "(function(){var v=document.querySelectorAll('video');for(var i=0;i<v.length;i++)if(!v[i].paused&&v[i].readyState>=2&&!v[i].muted&&v[i].__sunk)return true;return false})()"

BACKGROUND = """<!doctype html><meta charset=utf-8><title>studio</title>
<canvas width=320 height=180 style="display:none"></canvas>
<video id=hero muted loop playsinline style="width:960px;height:540px"></video>
<script>var c=document.querySelector('canvas'),g=c.getContext('2d'),n=0;
setInterval(function(){g.fillStyle='hsl('+(n++*7%360)+',70%,50%)';g.fillRect(0,0,320,180);},40);
var v=document.getElementById('hero');v.srcObject=c.captureStream(25);v.play();</script>"""


def showing():
    return sv.cmd({"do": "float", "action": "showing"}).get("showing") is True


def land(tab):
    sv.cmd({"do": "select", "id": tab})
    time.sleep(1.5)


def main():
    pages = tempfile.mkdtemp(prefix="search-float-players-")
    Path(pages, "studio.html").write_text(BACKGROUND)
    Path(pages, "other.html").write_text("<!doctype html><meta charset=utf-8><title>other</title><p>another page")

    class Quiet(SimpleHTTPRequestHandler):
        def log_message(self, *args):
            pass
    server = ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(Quiet, directory=pages))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_port}"
    hosts = {"autoplay." + h: True for h in ["videojs.org", "plyr.io", "connect-id.beinsports.com"]}
    t = sv.T()
    try:
        sv.setup(**{"float.leave": True, "float.away": False, **hosts}); sv.launch()
        sv.cmd({"do": "window"}); time.sleep(1)
        other = sv.sp("open", url=f"{base}/other.html")["resultID"]

        # First, a muted background video still floats nothing.
        tab = sv.sp("open", url=f"{base}/studio.html")["resultID"]
        sv.cmd({"do": "mute", "id": tab})
        sv.cmd({"do": "select", "id": tab})
        sv.ev(tab, "location.reload(); 1")
        time.sleep(2.5)
        bg = sv.ev(tab, "(function(){var v=document.getElementById('hero');return !v.paused&&v.muted})()")
        left = sv.cmd({"do": "float", "action": "leave", "to": other})
        t.ok("a muted background video elsewhere floats nothing", bg is True and left.get("showing") is False, (bg, left, tab))
        if showing():
            land(tab)
        sv.ev(tab, "document.getElementById('hero').pause(); 1")

        for name, url in SITES:
            tab = sv.sp("open", url=f"{base}/other.html?{name}")["resultID"]
            muted = sv.cmd({"do": "mute", "id": tab}).get("muted")
            if muted is not True:
                t.ok(f"{name}: tab muted before loading", False, muted)
                continue
            sv.cmd({"do": "select", "id": tab})
            sv.ev(tab, f"location.replace({url!r}); 1")
            said = None
            for _ in range(60):
                time.sleep(0.5)
                try:
                    said = sv.ev(tab, PLAY)
                except RuntimeError as e:
                    said = str(e)
                if said == "ok":
                    break
            # A player may still be swapping its source in, which aborts a
            # play: asked again until it plays.
            playing = False
            for _ in range(20):
                time.sleep(1)
                if sv.ev(tab, PLAYING) is True:
                    playing = True
                    break
                said = sv.ev(tab, PLAY)
            if not playing and sv.ev(tab, BLOCKED) is True:
                print(f"  skip  {name}: the site answers 403 Forbidden from here")
                continue
            if not playing:
                t.ok(f"{name}: its player plays (silenced)", False, (said, sv.ev(tab, STATE)))
                continue
            time.sleep(2)
            left = sv.cmd({"do": "float", "action": "leave", "to": other})
            t.ok(f"{name}: leaving the tab floats its video", left.get("showing") is True, (left, sv.ev(tab, STATE)))
            land(tab)
            sv.ev(tab, "document.querySelectorAll('video').forEach(function(v){v.pause()}); 1")

    finally:
        t.done(); sv.finish()
        server.shutdown()
        shutil.rmtree(pages, ignore_errors=True)
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
