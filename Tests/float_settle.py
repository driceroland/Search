#!/usr/bin/env python3
"""The floating video goes out and comes back in one step, on a local page.

Build first (`./build.sh`), then `python3 Tests/float_settle.py`. A page's
player is sized by its own script 0.4 s after the page is resized, as
YouTube's is: put back in its tab, the page first shows the video at the
size it had in the little window, and only later at its own. The video is
floated and landed with the bench's `film float|land` in a hidden probe
(both windows off every screen), which records every frame the page draws
and, beside it, when the covers are up: the video's frame over the little
window, the page as it was left over the tab. Each must come off only once
the page has reached the size it stays at, and before its time limit.
"""
import functools
import json
import shutil
import sys
import tempfile
import threading
import time
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

# Two columns, the player in the wider one at a size its script sets 0.4 s
# after the last resize, and never at once.
PAGE = """<!doctype html><meta charset=utf-8><title>late</title>
<style>body{margin:0;display:flex;gap:16px;background:#fff}
#player{background:#000;margin:16px}#side{flex:1;min-width:200px}#side div{height:90px;margin:8px;background:#ddd}
video{width:100%;height:100%;display:block}</style>
<div id=player><video muted playsinline></video></div>
<div id=side><div></div><div></div><div></div><div></div></div>
<canvas width=320 height=180 style="display:none"></canvas>
<script>
var c=document.querySelector('canvas'),g=c.getContext('2d'),n=0;
setInterval(function(){g.fillStyle='hsl('+(n++*7%360)+',70%,50%)';g.fillRect(0,0,320,180);},40);
var v=document.querySelector('video'); v.srcObject=c.captureStream(25); v.play();
var p=document.getElementById('player'), later=null;
function fit(){var w=Math.round(innerWidth*0.6);p.style.width=w+'px';p.style.height=Math.round(w*9/16)+'px';}
fit();
addEventListener('resize',function(){clearTimeout(later);later=setTimeout(fit,400);});
</script>"""

LIMIT_OUT, LIMIT_LAND = 800, 1500


def close(a, b, by=2):
    return all(abs(x - y) <= by for x, y in zip(a, b))


def film(action, path, seconds):
    sv.cmd({"do": "film", "action": action, "path": path, "seconds": seconds})
    return json.loads(Path(path + ".json").read_text())


def when(rows, test):
    """The first time something holds, on the hosts' clock."""
    return next((r["t"] for r in rows if test(r)), None)


def main():
    pages = tempfile.mkdtemp(prefix="search-float-settle-")
    Path(pages, "late.html").write_text(PAGE)

    class Quiet(SimpleHTTPRequestHandler):
        def log_message(self, *args):
            pass
    server = ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(Quiet, directory=pages))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    out = tempfile.mkdtemp(prefix="search-float-film-")
    t = sv.T()
    try:
        sv.setup(); sv.launch()
        sv.cmd({"do": "window"}); time.sleep(1)
        tab = sv.sp("open", url=f"http://127.0.0.1:{server.server_port}/late.html")["resultID"]
        sv.cmd({"do": "select", "id": tab}); time.sleep(2)

        # Out: the video's frame over the little window until the page is
        # laid out at the window's size with the video alone in it.
        went = film("float", f"{out}/float", 1.5)
        shift, view = went["shift"], went["view"]
        frames = [dict(f, t=f["t"] + shift) for f in went["frames"]]
        hosts = went["hosts"]
        up = when(hosts, lambda h: h["in"] == "float")
        t.ok("out: the little window opens covered by the video's frame",
             up is not None and next(h for h in hosts if h["in"] == "float")["still"] == "frame",
             [h for h in hosts if h["in"] == "float"][:1])
        down = when(hosts, lambda h: up is not None and h["t"] > up and h["still"] == "none")
        fits = when(frames, lambda f: f["isolated"] and close(f["page"], view) and close(f["video"], view))
        t.ok("out: the frame comes off only once the page fills the window",
             None not in (down, fits) and fits < down, {"fits": fits, "down": down})
        t.ok(f"out: and before its limit of {LIMIT_OUT} ms",
             None not in (up, down) and down - up < LIMIT_OUT - 20, {"up": up, "down": down})

        time.sleep(2)

        # Back: the page as it was left over the tab, until the player has
        # been sized again, late, at the tab's size.
        came = film("land", f"{out}/land", 2.5)
        shift, view = came["shift"], came["view"]
        frames = [dict(f, t=f["t"] + shift) for f in came["frames"]]
        hosts = came["hosts"]
        final = frames[-1]
        up = when(hosts, lambda h: h["in"] == "tab" and h["cover"])
        down = when(hosts, lambda h: up is not None and h["t"] > up and not h["cover"])
        t.ok("back: the tab is covered as the page comes home", up is not None and up < 100, up)
        stale = [f for f in frames if not f["isolated"] and close(f["page"], final["page"])
                 and not close(f["video"], final["video"])]
        t.ok("back: the page shows the video at the little window's size first (the late player)",
             bool(stale), [f["video"] for f in frames[:5]])
        settled = when(frames, lambda f: not f["isolated"] and f["page"] == final["page"]
                       and close(f["video"], final["video"]))
        t.ok("back: the cover comes off only once the video is at its own size again",
             None not in (down, settled) and settled < down and all(f["t"] < down for f in stale),
             {"settled": settled, "down": down, "stale until": stale[-1]["t"] if stale else None})
        t.ok(f"back: and before its limit of {LIMIT_LAND} ms",
             None not in (up, down) and down - up < LIMIT_LAND - 20, {"up": up, "down": down})
    finally:
        t.done(); sv.finish()
        server.shutdown()
        shutil.rmtree(pages, ignore_errors=True); shutil.rmtree(out, ignore_errors=True)
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
