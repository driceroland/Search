#!/usr/bin/env python3
"""What a sleeping tab keeps in the app, and what many of them add up to (sleep-pictures).

Build first (`./build.sh`), then `python3 Tests/sleep_pictures.py [--tabs N] [--out FILE]`.
SLEEP_APP=/path/to/Search.app measures another build.

A hidden probe in a world of its own (SEARCH_MEASURE=1, `sleep.after` 6 s),
with N tabs (40) from the session, each of a page with a photo-like picture
(noise under a gradient, so its JPEG isn't tiny). Each is picked once, so its
page is built, and the app's footprint (physical, as Activity Monitor shows
it) is read with them all awake; then they are left alone until every one has
gone to sleep (a picture of it, its history and place kept: Tab.sleep) and it
is read again. The difference per tab is what a sleeping tab costs the app,
the rest being WebKit's processes, which are gone.

Nothing here makes, shows, orders in or brings forward a window.
"""
import json
import os
import random
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import perf_tools  # noqa: E402
import split_view as sv  # noqa: E402

sv.use("sleep-pictures")
if os.environ.get("SLEEP_APP"):
    sv.APP = os.environ["SLEEP_APP"]

PAGE = """<!doctype html><title>Page {n}</title><body style="margin:0;background:linear-gradient(120deg,hsl({h},70%,45%),hsl({h2},70%,60%))">
<canvas id=c width=1400 height=800 style="width:100%;height:100vh"></canvas>
<script>
var c=document.getElementById('c'),x=c.getContext('2d'),d=x.createImageData(1400,800),s={n}*7919+1;
for(var i=0;i<d.data.length;i+=4){{s=(s*1103515245+12345)&0x7fffffff;var v=(s>>16)&255;d.data[i]=v;d.data[i+1]=(v*3+{n})&255;d.data[i+2]=(v*5)&255;d.data[i+3]=255;}}
x.putImageData(d,0,0);x.fillStyle='rgba(255,255,255,.8)';x.font='48px sans-serif';x.fillText('Page {n}',60,120);
</script>"""


ARTICLE = """<!doctype html><title>Article {n}</title><body style="margin:0;font:17px/1.5 system-ui;background:#fafafa">
<div style="height:64px;background:hsl({h},60%,40%);color:#fff;padding:18px 40px;font-size:24px">Site {n}</div>
<div style="display:flex;gap:40px;padding:30px 60px"><div style="flex:1"><h1>Heading of article {n}</h1>{text}</div>
<div style="width:380px"><div style="height:240px;background:linear-gradient(135deg,hsl({h},70%,50%),hsl({h2},70%,70%));border-radius:12px"></div>
<div style="height:160px;margin-top:20px;background:repeating-linear-gradient(45deg,#ddd 0 10px,#eee 10px 20px)"></div></div></div></body>"""


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        n = int(self.path.strip("/").split("-")[-1] or 0) if self.path.strip("/").split("-")[-1].isdigit() else 0
        if n % 2:
            text = "".join(f"<p>{'The quick brown fox jumps over the lazy dog, again and again. ' * 5}</p>" for _ in range(12))
            body = ARTICLE.format(n=n, h=(n * 37) % 360, h2=(n * 91) % 360, text=text).encode()
        else:
            body = PAGE.format(n=n, h=(n * 37) % 360, h2=(n * 91) % 360).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{srv.server_port}"


def footprint(pid):
    out = perf_tools.sample(pid, 0.2)
    app = sum(p["mb"] for p in out["procs"] if p["pid"] == pid)
    rest = sum(p["mb"] for p in out["procs"] if p["pid"] != pid)
    return round(app, 1), round(rest, 1), len(out["procs"])


def heap_all(pid):
    import re
    out = subprocess.run(["heap", "-s", str(pid)], capture_output=True, text=True).stdout
    return {m.group(3): (int(m.group(1)), int(m.group(2))) for m in re.finditer(r"^\s*(\d+)\s+(\d+)\s+[\d.]+\s+(\S.*?)\s*$", out, re.M)}


def kinds(pid):
    """Live objects of the classes a page's view is made of, from the heap."""
    import re
    out = subprocess.run(["heap", "-s", str(pid)], capture_output=True, text=True).stdout
    got = {}
    for m in re.finditer(r"^\s*(\d+)\s+(\d+)\s+[\d.]+\s+(\S.*?)\s*$", out, re.M):
        name = m.group(3).split()[0]
        if name in ("WKWebView", "PageView", "WKContentView", "WKScrollView", "WKUserContentController", "WKWebViewConfiguration",
                    "WKWebsiteDataStore", "Search.Tab", "Search.PageView") or name.endswith("PageView") or name == "WebKit::WebPageProxy":
            got[name] = int(m.group(1))
    return got


def main():
    a = sys.argv[1:]
    n = int(a[a.index("--tabs") + 1]) if "--tabs" in a else 40
    sv.setup()
    subprocess.run(["defaults", "write", sv.SUITE, "sleep.after", "-float", "6"])
    os.makedirs(sv.SUPPORT, exist_ok=True)
    json.dump({"tabs": [{"url": f"{BASE}/p-{i}", "title": f"Page {i}"} for i in range(n)], "active": 0},
              open(f"{sv.SUPPORT}/session.json", "w"))
    try:
        if os.path.exists(sv.SOCK):
            os.remove(sv.SOCK)
        before = sv.running()
        subprocess.run(["open", "-n", "-g", "-j", "--env", f"SEARCH_PROBE={sv.W}", "--env", "SEARCH_MEASURE=1", sv.APP])
        for _ in range(300):
            if os.path.exists(sv.SOCK):
                break
            time.sleep(0.1)
        time.sleep(3)
        sv.started.update((sv.running() - before) & sv.holding())
        pid = int(sv.pids()[0])
        base = footprint(pid)
        k0 = kinds(pid)
        h0 = heap_all(pid)
        # Visit every tab, then come back to the first, so none but it is on screen.
        for i in range(1, n):
            sv.cmd({"do": "perfselect", "index": i, "seconds": 0.2})
            tabs = sv.cmd({"do": "tabs"})["tabs"]
            sv.cmd({"do": "wait", "id": tabs[i]["id"], "seconds": 20})
        sv.cmd({"do": "perfselect", "index": 0, "seconds": 0.2})
        time.sleep(4)
        awake = footprint(pid)
        k1 = kinds(pid)
        asleep_count = 0
        for _ in range(120):
            time.sleep(2)
            asleep_count = sum(1 for t in sv.cmd({"do": "tabs"})["tabs"] if t.get("asleep"))
            if asleep_count >= n - 1:
                break
        time.sleep(5)
        slept = footprint(pid)
        k2 = kinds(pid)
        h2 = heap_all(pid)
        heavy = sorted(((h2[k][1] - h0.get(k, (0, 0))[1], h2[k][0] - h0.get(k, (0, 0))[0], k[:70]) for k in h2), reverse=True)[:14]
        print("heap by bytes, start -> all asleep:", *heavy, sep="\n  ")
        subprocess.run(["vmmap", "--summary", str(pid)], stdout=open(f"{sv.SUPPORT}/vmmap.txt", "w"))
        print(subprocess.run(["bash", "-c", f"grep -E 'IOSurface|CG image|CoreAnimation|MALLOC_LARGE|MALLOC_SMALL|MALLOC_TINY|TOTAL  ' '{sv.SUPPORT}/vmmap.txt' | head -12"], capture_output=True, text=True).stdout)
        # The pictures kept: their size on disk, noise (even) and article (odd) pages apart.
        sizes = {"noise": [], "article": []}
        for i, t in enumerate(sv.cmd({"do": "tabs"})["tabs"]):
            if not t.get("asleep"):
                continue
            path = f"{sv.SUPPORT}/kept-{i}.jpg"
            info = sv.cmd({"do": "kept", "id": t["id"], "path": path})
            if os.path.exists(path):
                sizes["article" if i % 2 else "noise"].append((os.path.getsize(path), info.get("pixels")))
        res = {"tabs": n, "asleep": asleep_count, "atStart": base, "allAwake": awake, "allAsleep": slept,
               "appPerSleepingTabKB": round((slept[0] - base[0]) * 1024 / max(asleep_count, 1)),
               "appPerAwakeTabKB": round((awake[0] - base[0]) * 1024 / max(n - 1, 1)),
               "objects": {"start": k0, "awake": k1, "asleep": k2}, "pictureKB": {k: (round(sum(x[0] for x in v) / len(v) / 1024), v[0][1]) for k, v in sizes.items() if v}}
        print(json.dumps(res), flush=True)
        if "--out" in a:
            Path(a[a.index("--out") + 1]).write_text(json.dumps(res))
    finally:
        sv.finish()


if __name__ == "__main__":
    main()
