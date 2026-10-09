#!/usr/bin/env python3
"""The floating video's isolation (Float.swift, Isolate.on) on local pages.

Build first (`./build.sh`), then `python3 Tests/float_video.py`. Each page
holds a playing video under an ancestor that makes a box of its own for
fixed elements (a transform, a filter, containment…), is drawn only when on
screen, or is faded out. Isolation must preserve the video's geometry until
the fitting fallback is requested, then fill the viewport and restore the
original layout on return. The script uses a hidden probe, not the floating
panel: native cropping, dragging, transitions and desktop changes still need
manual testing. Running this file explicitly starts that probe.
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

sv.use("float-video")
ROOT = Path(__file__).resolve().parents[1]
REQUEST = "00000000-0000-0000-0000-000000000001"
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
return JSON.stringify({x:r.left,y:r.top,w:r.width,h:r.height,iw:innerWidth,ih:innerHeight,seen:seen,
scroll:scrollY,playing:!v.paused&&v.readyState>=2,marked:v.hasAttribute('data-office-float'),
floating:document.documentElement.classList.contains('office-floating'),
fit:document.documentElement.classList.contains('office-float-fit')})})()"""


def script(source, declaration):
    start = source.index('"""', source.index(declaration)) + 3
    return source[start:source.index('"""', start)].strip().replace("\\\\", "\\")


def same_rect(a, b):
    return all(abs(a[key] - b[key]) < 1 for key in ("x", "y", "w", "h"))


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
    isolate = script(source, "static func on(_ request: UUID)").replace(r"\(request.uuidString)", REQUEST)
    present = script(source, "static let present =")
    restore = script(source, "static func off(_ request: UUID?")
    restore = restore.replace(r'\(request?.uuidString ?? "")', REQUEST).replace(r"\(waitForResize)", "false")
    t = sv.T()
    try:
        sv.setup(); sv.launch()
        for name in CASES:
            tab = sv.sp("open", url=f"{base}/{name}.html")["resultID"]
            time.sleep(1.5)

            def evaluate(js, world="search"):
                return sv.cmd({"do": "eval", "id": tab, "js": js, "world": world}).get("value")

            # A visible player and one below the viewport take different
            # native paths, but neither may move during preparation.
            for scroll in (1200, 500):
                evaluate(f"window.scrollTo(0,{scroll})", "page")
                time.sleep(0.2)
                before = json.loads(evaluate(PROBE, "page"))
                said = evaluate(isolate)
                p = json.loads(evaluate(PROBE, "page"))
                rectangle = [before[key] for key in ("x", "y", "w", "h")]
                matches = isinstance(said, list) and len(said) == 4 and all(abs(a - b) < 1 for a, b in zip(said, rectangle))
                t.ok(f"{name}/{scroll}: preparation preserves geometry and playback",
                     matches and same_rect(before, p) and p["scroll"] == before["scroll"]
                     and p["marked"] and p["floating"] and not p["fit"] and p["playing"], p)
                # An old completion must not undo the current lift.
                stale = restore.replace(REQUEST, "00000000-0000-0000-0000-000000000002")
                t.ok(f"{name}/{scroll}: stale return is ignored", evaluate(stale) == "obsolete")
                t.ok(f"{name}/{scroll}: fitting fallback starts", evaluate(present) is True)
                time.sleep(0.2)
                p = json.loads(evaluate(PROBE, "page"))
                fills = abs(p["x"]) < 1 and abs(p["y"]) < 1 and abs(p["w"] - p["iw"]) < 1 and abs(p["h"] - p["ih"]) < 1
                t.ok(f"{name}/{scroll}: fallback fills the view and is drawn",
                     fills and p["seen"] and p["playing"] and p["fit"] and p["marked"], p)
                t.ok(f"{name}/{scroll}: return completes", evaluate(restore) == "landed")
                time.sleep(0.2)
                p = json.loads(evaluate(PROBE, "page"))
                t.ok(f"{name}/{scroll}: return restores layout and playback",
                     same_rect(before, p) and p["scroll"] == before["scroll"]
                     and p["seen"] == before["seen"] and p["playing"]
                     and not p["marked"] and not p["floating"] and not p["fit"], p)
            evaluate("document.querySelector('video').pause()", "page")
            t.ok(f"{name}: paused video is not isolated", evaluate(isolate) == "none")
            time.sleep(0.4)
            sv.sp("close", id=tab)
    finally:
        t.done(); sv.finish()
        server.shutdown(); server.server_close()
        shutil.rmtree(pages)
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
