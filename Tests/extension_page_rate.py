#!/usr/bin/env python3
"""An extension's new tab animates as often as a web page does (idea 770).

Build first (`./build.sh`), then `python3 Tests/extension_page_rate.py`. A
hidden probe in a world of its own (split_view.py's harness) counts
requestAnimationFrame callbacks for two seconds (Bench "rate"), first on a
web page drawing a WebGL shader every frame, then on an extension's new tab
(⌘T) drawing the same. A hidden app draws nothing, so "rate" lends the tab's
stage to a borderless window off every screen, as the float filming does,
and gives it back; the probe is never shown. Twice: with Settings › General
› Pages at 120 Hz at Never (WebKit's own, near 60) and at Always, where a
screen that goes faster lets both go faster.
"""
import json
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("ext-page-rate")
work = Path(tempfile.mkdtemp(prefix="search-ext-page-rate-"))

SHADER = """
const c = document.createElement('canvas');
c.style.cssText = 'position:fixed;inset:0;width:100%;height:100%';
document.body.appendChild(c);
const g = c.getContext('webgl');
function sh(k, s) { const x = g.createShader(k); g.shaderSource(x, s); g.compileShader(x); return x; }
const p = g.createProgram();
g.attachShader(p, sh(g.VERTEX_SHADER, 'attribute vec2 p;void main(){gl_Position=vec4(p,0,1);}'));
g.attachShader(p, sh(g.FRAGMENT_SHADER, 'precision highp float;uniform float t;uniform vec2 r;void main(){vec2 u=gl_FragCoord.xy/r;float v=0.;for(int i=0;i<40;i++){v+=sin(u.x*float(i)+t)*cos(u.y*float(i)-t);}gl_FragColor=vec4(fract(v),u,1);}'));
g.linkProgram(p); g.useProgram(p);
g.bindBuffer(g.ARRAY_BUFFER, g.createBuffer());
g.bufferData(g.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), g.STATIC_DRAW);
const at = g.getAttribLocation(p, 'p'); g.enableVertexAttribArray(at); g.vertexAttribPointer(at, 2, g.FLOAT, false, 0, 0);
const tl = g.getUniformLocation(p, 't'), rl = g.getUniformLocation(p, 'r');
function frame(t) {
  c.width = innerWidth * devicePixelRatio; c.height = innerHeight * devicePixelRatio;
  g.viewport(0, 0, c.width, c.height); g.uniform1f(tl, t / 1000); g.uniform2f(rl, c.width, c.height);
  g.drawArrays(g.TRIANGLES, 0, 3); requestAnimationFrame(frame);
}
requestAnimationFrame(frame);
"""
PAGE = ("<!doctype html><title>Shader</title><body style=margin:0><script>" + SHADER + "</script>").encode()


class Serve(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(PAGE)))
        self.end_headers()
        self.wfile.write(PAGE)

    def log_message(self, *a): pass


server = ThreadingHTTPServer(("127.0.0.1", 0), Serve)
threading.Thread(target=server.serve_forever, daemon=True).start()


def rates():
    web = sv.cmd({"do": "open", "url": f"http://127.0.0.1:{server.server_port}/shader"})["id"]
    time.sleep(1.5)
    sv.cmd({"do": "select", "id": web})
    time.sleep(1)
    page = sv.cmd({"do": "rate", "seconds": 2})
    sv.cmd({"do": "press", "code": 17, "chars": "t", "mods": ["cmd"]})
    time.sleep(2.5)
    own = sv.cmd({"do": "rate", "seconds": 2})
    return page, own


def main():
    t = sv.T()
    folder = work / "ext"
    folder.mkdir()
    (folder / "manifest.json").write_text(json.dumps({
        "manifest_version": 3, "name": "Shader Tab", "version": "1.0", "description": "A new tab that animates",
        "chrome_url_overrides": {"newtab": "newtab.html"},
    }))
    (folder / "newtab.html").write_text('<!doctype html><title>New Tab</title><body style=margin:0><script src="tab.js"></script>')
    (folder / "tab.js").write_text(SHADER)
    try:
        for mode in ("never", "always"):
            sv.setup()
            subprocess.run(["defaults", "write", sv.SUITE, "pages.120.mode", "-string", mode])
            sv.launch()
            sv.cmd({"do": "ext-answer", "answer": "yes"})
            sv.cmd({"do": "ext-folder", "path": str(folder), "yes": True})
            for _ in range(60):
                if any(x["loaded"] for x in sv.cmd({"do": "extensions"})["extensions"]):
                    break
                time.sleep(0.25)
            page, own = rates()
            t.ok(f"{mode}: the extension's new tab is the one measured", own["url"].endswith("/newtab.html"), own)
            t.ok(f"{mode}: the web page animates ({page['fps']} fps)", page["fps"] >= 50 and not page["timedOut"], page)
            t.ok(f"{mode}: the extension's new tab as often ({own['fps']} vs {page['fps']} fps)",
                 abs(own["fps"] - page["fps"]) <= page["fps"] * 0.1 and not own["timedOut"], own)
            if mode == "always" and page["screenHz"] > 60:
                t.ok(f"always, on a {page['screenHz']} Hz screen: past 60 ({own['fps']} fps)", own["fps"] > 75, own)
            sv.quit()
    finally:
        sv.finish()
        server.shutdown()
        shutil.rmtree(work, ignore_errors=True)
    return t


if __name__ == "__main__":
    t = main()
    t.done()
    sys.exit(1 if t.failed else 0)
