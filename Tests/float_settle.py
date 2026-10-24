#!/usr/bin/env python3
"""The floating video goes out and comes back in one step, on a local page.

Build first (`./build.sh`), then `python3 Tests/float_settle.py`. A page's
player is sized by its own script 0.4 s after the page is resized, as
YouTube's is: put back in its tab, the page first shows the video at the
size it had in the little window, and only later at its own. The video is
floated and landed with the bench's `film float|land` in a hidden probe
(both windows off every screen), by ⇧⌘P, by switching tabs and by switching
apps. The bench records every frame the page draws and, beside it, what
WebKit has handed over to be drawn and when the covers are up: the video's
frame over the little window, the page as it was left over the tab. Each
must come off only once the page has reached the size it stays at, drawn,
with the video's own picture drawn at the size it is shown, and before its
time limit; and going out, the page never leaves a window. Both the native
crop, which keeps the source viewport and player geometry, and the fitting
fallback, which resizes the page, run through all three ways out and back.
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

sv.use("float-settle")

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
PROBE = """(function(){var r=document.querySelector('video').getBoundingClientRect();
return JSON.stringify({page:[innerWidth,innerHeight],video:[r.width,r.height],
rect:[r.left,r.top,r.width,r.height],
native:document.documentElement.classList.contains('office-float-native')})})()"""


def close(a, b, by=2):
    return len(a) == len(b) and all(abs(x - y) <= by for x, y in zip(a, b))


def probe(tab):
    return json.loads(sv.cmd({"do": "eval", "id": tab, "js": PROBE}).get("value"))


def film(action, path, seconds, via="key"):
    sv.cmd({"do": "film", "action": action, "path": path, "seconds": seconds, "via": via})
    return json.loads(Path(path + ".json").read_text())


def when(rows, test):
    """The first time something holds, on the hosts' clock."""
    return next((r["t"] for r in rows if test(r)), None)


def stretched(hosts, after):
    """Samples from `after` on in which a video's picture, drawn by another
    of WebKit's processes, is not at the size it is shown: the old picture
    stretched into a new room, until that process draws again."""
    return [(h["t"], h["drawn"]["host"][:2], h["drawn"]["room"]) for h in hosts
            if after is not None and h["t"] >= after and h["drawn"].get("host")
            and not close(h["drawn"]["host"][:2], h["drawn"]["room"])]


def round_trip(t, out, via, tab, native):
    """Out and back by one way, and what each cover did meanwhile."""
    mode = "native" if native else "fallback"
    name = mode + ", " + {"key": "⇧⌘P", "switch": "switching tabs", "app": "switching apps"}[via]
    before = probe(tab)

    # Out: the video's frame over the little window until the page is laid
    # out at the window's size with the video alone in it, and WebKit has
    # handed that over to be drawn.
    went = film("float", f"{out}/{mode}-{via}-float", 1.5, via)
    floating = probe(tab)
    t.ok(f"{name}, out: the expected isolation path is selected",
         floating["native"] == native, floating)
    shift, view = went["shift"], went["view"]
    frames = [dict(f, t=f["t"] + shift) for f in went["frames"]]
    hosts = went["hosts"]
    up = when(hosts, lambda h: h["in"] == "float")
    t.ok(f"{name}, out: the little window opens covered by the video's frame",
         up is not None and next(h for h in hosts if h["in"] == "float")["still"] == "frame",
         [h for h in hosts if h["in"] != "tab"][:2])
    t.ok(f"{name}, out: the page is in a window all the way",
         not went["unwindowed"] and all(h["in"] != "none" for h in hosts), went["unwindowed"][:5])
    down = when(hosts, lambda h: up is not None and h["t"] > up and h["still"] == "none")
    expected_page = before["page"] if native else view
    expected_video = before["video"] if native else view
    fits = when(frames, lambda f: f["isolated"] and close(f["page"], expected_page)
                and close(f["video"], expected_video))
    drawn = when(hosts, lambda h: h["in"] == "float"
                 and close(h["drawn"]["page"] or [0, 0], expected_page))
    t.ok(f"{name}, out: the frame comes off only once the destination geometry is drawn",
         None not in (down, fits, drawn) and fits < down and drawn <= down,
         {"fits": fits, "drawn": drawn, "down": down})
    t.ok(f"{name}, out: once it is off, the video's picture is drawn at the size it is shown",
         down is not None and not stretched(hosts, down), stretched(hosts, down)[:3])
    t.ok(f"{name}, out: and before its limit of {LIMIT_OUT} ms",
         None not in (up, down) and down - up < LIMIT_OUT - 20, {"up": up, "down": down})
    if native:
        t.ok(f"{name}, out: the source viewport and video rectangle never change",
             bool(frames) and all(close(f["page"], before["page"])
                                  and close(f["video"], before["video"]) for f in frames)
             and close(floating["rect"], before["rect"])
             and close(view, before["page"]),
             {"before": before, "after": floating, "view": view})
        t.ok(f"{name}, out: the web view is never resized to the little window",
             all(close(size[1:], before["page"]) for size in went["sizes"]), went["sizes"])

    time.sleep(2)

    # Back: the page as it was left over the tab, until the player has been
    # sized again, late, at the tab's size.
    came = film("land", f"{out}/{mode}-{via}-land", 2.5, via)
    returned = probe(tab)
    t.ok(f"{name}, back: native isolation is removed", not returned["native"], returned)
    shift, view = came["shift"], came["view"]
    frames = [dict(f, t=f["t"] + shift) for f in came["frames"]]
    hosts = came["hosts"]
    final = frames[-1]
    up = when(hosts, lambda h: h["in"] == "tab" and h["cover"])
    down = when(hosts, lambda h: up is not None and h["t"] > up and not h["cover"])
    t.ok(f"{name}, back: the tab is covered as the page comes home", up is not None and up < 100, up)
    stale = [f for f in frames if not f["isolated"] and close(f["page"], final["page"])
             and not close(f["video"], final["video"])]
    if native:
        t.ok(f"{name}, back: the source viewport and video rectangle never change",
             all(close(f["page"], before["page"]) and close(f["video"], before["video"]) for f in frames)
             and close(returned["page"], before["page"])
             and close(returned["rect"], before["rect"]),
             {"before": before, "after": returned, "stale": stale[:3]})
        t.ok(f"{name}, back: the web view keeps its source size throughout landing",
             all(close(size[1:], before["page"]) for size in came["sizes"]), came["sizes"])
    else:
        t.ok(f"{name}, back: the page shows the video at the little window's size first (the late player)",
             bool(stale), [f["video"] for f in frames[:5]])
    settled = when(frames, lambda f: not f["isolated"] and f["page"] == final["page"]
                   and close(f["video"], final["video"]))
    drawn = when(hosts, lambda h: h["in"] == "tab" and close(h["drawn"]["video"] or [0, 0], final["video"]))
    t.ok(f"{name}, back: the cover comes off only once the video is at its own size again, drawn",
         None not in (down, settled, drawn) and settled < down and drawn <= down
         and all(f["t"] < down for f in stale),
         {"settled": settled, "drawn": drawn, "down": down, "stale until": stale[-1]["t"] if stale else None})
    t.ok(f"{name}, back: once it is off, the video's picture is drawn at the size it is shown",
         down is not None and not stretched(hosts, down), stretched(hosts, down)[:3])
    t.ok(f"{name}, back: and before its limit of {LIMIT_LAND} ms",
         None not in (up, down) and down - up < LIMIT_LAND - 20, {"up": up, "down": down})


def main():
    pages = tempfile.mkdtemp(prefix="search-float-settle-")
    Path(pages, "late.html").write_text(PAGE)
    # A non-none clip path requires the fitting path, while leaving the
    # whole picture visible for the transition still and late-player checks.
    Path(pages, "fallback.html").write_text(PAGE.replace("</style>", "video{clip-path:inset(0)}</style>"))
    Path(pages, "other.html").write_text("<!doctype html><meta charset=utf-8><title>other</title><p>another page")

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
        base = f"http://127.0.0.1:{server.server_port}"
        # Somewhere to switch to, and the video, in front.
        sv.sp("open", url=f"{base}/other.html")
        # The video is muted, as autoplay asks: one WebKit stops as soon as
        # nobody can see its page, which is what going to another tab did to
        # it before it had floated.
        for path, native in (("late.html", True), ("fallback.html", False)):
            tab = sv.sp("open", url=f"{base}/{path}")["resultID"]
            sv.cmd({"do": "select", "id": tab}); time.sleep(2)
            for via in ("key", "switch", "app"):
                round_trip(t, out, via, tab, native)
                time.sleep(2)
            sv.sp("close", id=tab)
    finally:
        t.done(); sv.finish()
        server.shutdown()
        shutil.rmtree(pages, ignore_errors=True)
        if t.failed:
            print(f"Failed transition films: {out}")
        else:
            shutil.rmtree(out, ignore_errors=True)
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
