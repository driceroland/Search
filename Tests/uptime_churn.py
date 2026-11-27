#!/usr/bin/env python3
"""A week of use in minutes: what the app keeps as tabs open, navigate and close (uptime-churn).

Build first (`./build.sh`), then
`python3 Tests/uptime_churn.py [--cycles N] [--every K] [--out FILE]`
UPTIME_APP=/path/to/Search.app measures another build.

A hidden probe in a world of its own, SEARCH_MEASURE=1. N cycles (400 by
default): a bench tab opens a local page with a title and an icon, goes
through three more pages in the same tab, and is closed. Every K cycles
(50) the app's physical footprint and the processes it is responsible for
are read (rsample: Search, WebContent, GPU, Networking), with the size of
history.json and the session file, and `heap -s` of the main process at the
start and the end names the classes whose count grew most.

Nothing here makes, shows, orders in or brings forward a window.
"""
import json
import os
import re
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import perf_tools  # noqa: E402
import split_view as sv  # noqa: E402

sv.use("uptime-churn")
if os.environ.get("UPTIME_APP"):
    sv.APP = os.environ["UPTIME_APP"]
PNG = bytes.fromhex("89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4890000000d49444154789c63f8cfc0f01f0005000201a5f6458c0000000049454e44ae426082")


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/icon"):
            body, kind = PNG, "image/png"
        else:
            body, kind = (f"<!doctype html><title>Churn {self.path}</title><link rel=icon href=/icon{self.path}.png><p>{self.path}"
                          + "<p>x" * 200).encode(), "text/html"
        self.send_response(200)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{srv.server_port}"


def procs(pid):
    got = {}
    for p in perf_tools.sample(pid, 0.2)["procs"]:
        n = p["name"].lower()
        k = "web" if "webcontent" in n else "gpu" if "gpu" in n else "net" if "networking" in n else "app"
        got[k] = got.get(k, 0) + p["mb"]
        got[k + "_n"] = got.get(k + "_n", 0) + 1
    return {k: round(v, 1) for k, v in got.items()}


def heap(pid):
    out = subprocess.run(["heap", "-s", str(pid)], capture_output=True, text=True).stdout
    return {m.group(3): (int(m.group(1)), int(m.group(2))) for m in re.finditer(r"^\s*(\d+)\s+(\d+)\s+[\d.]+\s+(\S.*?)\s*$", out, re.M)}


def size(name):
    try:
        return os.path.getsize(f"{sv.SUPPORT}/{name}")
    except OSError:
        return 0


def main():
    a = sys.argv[1:]
    val = lambda k, d: int(a[a.index(k) + 1]) if k in a else d
    cycles, every = val("--cycles", 400), val("--every", 50)
    outfile = a[a.index("--out") + 1] if "--out" in a else None
    sv.setup()
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
        rows = [{"cycle": 0, **procs(pid), "history": size("history.json"), "session": size("session.json")}]
        print(json.dumps(rows[-1]), flush=True)
        h0 = heap(pid)
        for c in range(1, cycles + 1):
            tab = sv.cmd({"do": "open", "url": f"{BASE}/c{c}"})["id"]
            sv.cmd({"do": "wait", "id": tab, "seconds": 20})
            for j in range(3):
                sv.cmd({"do": "go", "id": tab, "url": f"{BASE}/c{c}-{j}"})
                sv.cmd({"do": "wait", "id": tab, "seconds": 20})
            sv.cmd({"do": "close", "id": tab})
            if c % every == 0:
                time.sleep(3)
                rows.append({"cycle": c, **procs(pid), "history": size("history.json"), "session": size("session.json")})
                print(json.dumps(rows[-1]), flush=True)
        time.sleep(3)
        h1 = heap(pid)
        grew = sorted(((h1[k][0] - h0.get(k, (0, 0))[0], h1[k][1] - h0.get(k, (0, 0))[1], k) for k in h1), reverse=True)[:15]
        print("heap classes by count growth (count, bytes, class):")
        for g in grew:
            print("  ", g)
        heavy = sorted(((h1[k][1] - h0.get(k, (0, 0))[1], h1[k][0] - h0.get(k, (0, 0))[0], k) for k in h1), reverse=True)[:12]
        print("heap classes by bytes growth (bytes, count, class):")
        for g in heavy:
            print("  ", g)
        ours = [(k, h0.get(k, (0, 0))[0], h1[k][0]) for k in h1 if any(w in k for w in ("Tab", "WKWebView", "PageView", "Browser", "Combine.PublishedSubject"))]
        print("our classes (class, count at start, count at end):")
        for o in sorted(ours, key=lambda x: -(x[2] - x[1]))[:15]:
            print("  ", (o[0][:90], o[1], o[2]))
        if outfile:
            Path(outfile).write_text(json.dumps({"rows": rows, "grew": grew}))
    finally:
        sv.finish()


if __name__ == "__main__":
    main()
