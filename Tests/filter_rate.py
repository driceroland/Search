#!/usr/bin/env python3
"""A page animating under big blurs keeps moving: filters are drawn on the GPU.

Build first (`./build.sh`), then `python3 Tests/filter_rate.py`. A hidden
probe in a world of its own (split_view.py's harness) opens a page shaped
like www.kiraa.ai's background: large SVG blurs, each on a shape that
drifts, so WebKit draws every filter again on every frame. Drawn on
the CPU, WebKit's default, it got about 6 frames a second here (kiraa.ai
itself 2, in Safari too); with Core Image (FrameRate.apply) about 36. Counted by
Bench "rate", which lends the tab's stage to a window off every screen.
"""
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("filter-rate")

BLURS = "".join(
    f'<filter id="b{i}" x="-2000" y="-1500" width="5000" height="4000" filterUnits="userSpaceOnUse">'
    f'<feGaussianBlur stdDeviation="{80 + 25 * i}"/></filter>' for i in range(8))
SHAPES = "".join(
    f'<g class="drift" style="animation-delay:-{3 * i}s"><g filter="url(#b{i})">'
    f'<ellipse cx="{150 + 160 * i}" cy="{250 + 60 * i}" rx="600" ry="250" fill="hsl({45 * i},70%,55%)"/></g></g>'
    for i in range(8))
# Each blurred shape drifts, as kiraa.ai's do: shapes inside one SVG share
# its layer, so every frame the whole SVG is drawn again, every blur in it.
PAGE = f"""<!doctype html><title>Blurs</title><style>
body{{margin:0;background:#0c0c0c}} svg{{position:fixed;inset:0;width:100vw;height:100vh}}
.drift{{transform-box:view-box;transform-origin:50%;will-change:transform;animation:drift 8s ease-in-out infinite}}
@keyframes drift{{50%{{transform:translate(60px,-40px) rotate(4deg) scale(1.08)}}}}
</style><svg viewBox="0 0 1440 1024" preserveAspectRatio="xMidYMid slice"><defs>{BLURS}</defs>{SHAPES}</svg>""".encode()


class Serve(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(PAGE)))
        self.end_headers()
        self.wfile.write(PAGE)

    def log_message(self, *a): pass


def main():
    t = sv.T()
    server = ThreadingHTTPServer(("127.0.0.1", 0), Serve)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        sv.setup()
        sv.launch()
        id = sv.cmd({"do": "open", "url": f"http://127.0.0.1:{server.server_port}/blurs"})["id"]
        time.sleep(2)
        sv.cmd({"do": "select", "id": id})
        time.sleep(1)
        r = sv.cmd({"do": "rate", "seconds": 3})
        t.ok(f"the page under big blurs animates ({r['fps']} fps, was about 6)", r["fps"] >= 15 and not r["timedOut"], r)
        sv.quit()
    finally:
        sv.finish()
        server.shutdown()
    return t


if __name__ == "__main__":
    t = main()
    t.done()
    sys.exit(1 if t.failed else 0)
