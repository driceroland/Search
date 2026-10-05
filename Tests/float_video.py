#!/usr/bin/env python3
"""The floating video's isolation (Float.swift, Isolate.on) on local pages.

Build first (`./build.sh`), then `python3 Tests/float_video.py`. Each page
holds a playing video under an ancestor that makes a box of its own for
fixed elements (a transform, a filter, containment…), is drawn only when on
screen, or is faded out. The isolation script is run on an ordinary tab of
a hidden probe — the floating window itself is never opened — and the video
must then fill the page's view and be visible.
"""
import functools
import json
import sys
import tempfile
import threading
import time
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
CASES = {
    "plain": "",
    "transform": "transform:translateZ(0);",
    "filter": "filter:blur(0px);",
    "contain": "contain:paint;",
    "will-change": "will-change:transform;",
    "content-visibility": "content-visibility:auto; contain-intrinsic-size:auto 300px;",
    "opacity": "opacity:0;",
    "perspective": "perspective:100px;",
    "backdrop": "backdrop-filter:blur(1px);",
    "container": "container-type:inline-size;",
}
PAGE = """<!doctype html><meta charset=utf-8><title>{name}</title>
<style>body{{margin:0}} .feed>div{{height:600px;border-bottom:1px solid #ccc}}</style>
<div class=feed><div>post</div><div>post</div>
<div style="position:relative;width:640px;height:360px;margin:40px auto;overflow:hidden;{style}">
<div style="position:absolute;inset:0"><video muted playsinline style="width:100%;height:100%"></video></div></div>
<div>post</div><div>post</div></div>
<canvas width=320 height=180 style="display:none"></canvas>
<script>
var c=document.querySelector('canvas'),g=c.getContext('2d'),n=0;
setInterval(function(){{g.fillStyle='hsl('+(n++*7%360)+',70%,50%)';g.fillRect(0,0,320,180);}},40);
var v=document.querySelector('video'); v.srcObject=c.captureStream(25); v.play();
window.scrollTo(0,500);
</script>"""
PROBE = """(function(){var v=document.querySelector('video');var r=v.getBoundingClientRect();
var seen=v.checkVisibility?v.checkVisibility({contentVisibilityAuto:true,opacityProperty:true,visibilityProperty:true}):true;
return JSON.stringify({x:r.left,y:r.top,w:r.width,h:r.height,iw:innerWidth,ih:innerHeight,seen:seen})})()"""


def main():
    pages = tempfile.mkdtemp(prefix="search-float-")
    for name, style in CASES.items():
        Path(pages, f"{name}.html").write_text(PAGE.format(name=name, style=style))
    class Quiet(SimpleHTTPRequestHandler):
        def log_message(self, *args):
            pass
    handler = functools.partial(Quiet, directory=pages)
    server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_port}"
    source = (ROOT / "Sources/Search/Float.swift").read_text()
    start = source.index('static let on = """') + len('static let on = """')
    isolate = source[start:source.index('"""', start)].strip().replace("\\\\", "\\")
    t = sv.T()
    try:
        sv.setup(); sv.launch()
        for name in CASES:
            tab = sv.sp("open", url=f"{base}/{name}.html")["resultID"]
            time.sleep(1.5)
            said = sv.cmd({"do": "eval", "id": tab, "js": isolate, "world": "search"}).get("value")
            time.sleep(0.4)
            p = json.loads(sv.cmd({"do": "eval", "id": tab, "js": PROBE}).get("value"))
            fills = abs(p["x"]) < 1 and abs(p["y"]) < 1 and abs(p["w"] - p["iw"]) < 1 and abs(p["h"] - p["ih"]) < 1
            t.ok(f"{name}: the video fills the view and is drawn", isinstance(said, dict) and said.get("floating") is True and fills and p["seen"], p)
            sv.sp("close", id=tab)
    finally:
        t.done(); sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
