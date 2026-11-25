#!/usr/bin/env python3
"""A closed tab's page process still spinning is ended, and nothing else is
(Stuck.swift, #1468), in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/stuck_process.py` from a
worktree. It runs build/Search.app in a world of its own with split_view.py's
harness, started hidden, against pages and an unpacked extension it serves
and writes itself; the world is removed afterwards. About two minutes: each
case waits out Stuck.wait.

- a lone tab spinning in a loop, closed: its process is ended;
- two tabs of the same site, the spinning one closed: the other still
  answers;
- an extension's own page in a tab, with the extension's background busy,
  closed: the background is the same one afterwards (an extension's pages
  share its process, and none of the others are tabs);
- controls: an idle tab closed, and a busy tab left open, aren't ended.
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

sv.use("stuck-process")
work = Path(tempfile.mkdtemp(prefix="search-stuck-"))

# Stuck.wait, and some room for the look it takes then.
SETTLE = 14

PAGES = {
    # Spins for good a moment after it loads, as a page caught in WebKit's
    # accessibility loop does.
    "/spin": "<!doctype html><title>spin</title><script>setTimeout(function(){for(;;){}},800)</script>",
    "/idle": "<!doctype html><title>idle</title><p>idle",
    # Busy, but in short turns: still a page that answers.
    "/busy": "<!doctype html><title>busy</title><script>function c(){var t=Date.now();while(Date.now()-t<45){} setTimeout(c,0)} c()</script>",
}

EXTENSION = {
    "manifest.json": json.dumps({
        "manifest_version": 2, "name": "Stuck Probe", "version": "1.0",
        "background": {"scripts": ["bg.js"], "persistent": True},
        "permissions": ["storage"],
    }),
    # Says which background it is, and on "busy" works in short turns for
    # 25 s, well past the look Stuck takes.
    "bg.js": """
var born = Date.now() + ":" + Math.random();
var until = 0;
function chunk() { var t = Date.now(); while (Date.now() - t < 45) {} if (Date.now() < until) setTimeout(chunk, 0); }
chrome.runtime.onMessage.addListener(function (m, s, reply) {
  if (m === "busy") { until = Date.now() + 25000; chunk(); reply("ok"); }
  else reply(born);
});
""",
    "page.html": "<!doctype html><title>extpage</title><script src='page.js'></script>",
    "page.js": "window.__born = null;\nfunction ask(m) { chrome.runtime.sendMessage(m, function (r) { if (m === 'born') window.__born = r; }); }\n",
}


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        body = PAGES.get(self.path, "<!doctype html>x").encode()
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


def alive(pid):
    return pid > 0 and subprocess.run(["kill", "-0", str(pid)], capture_output=True).returncode == 0


def process(tid):
    for _ in range(40):
        tab = next((x for x in sv.cmd({"do": "tabs"})["tabs"] if x["id"] == tid), None)
        if tab and tab.get("process"):
            return tab["process"]
        time.sleep(0.25)
    return 0


def open_tab(url):
    tid = sv.cmd({"do": "open", "url": url})["id"]
    time.sleep(1.5)
    return tid, process(tid)


def ext_tab(ext, path):
    tid = sv.cmd({"do": "ext-page", "id": ext, "path": path})["id"]
    time.sleep(1.5)
    return tid, process(tid)


def close(tid):
    sv.cmd({"do": "close", "id": tid})


def born(tid):
    sv.ev(tid, "window.__born=null;ask('born'),1")
    for _ in range(30):
        value = sv.ev(tid, "window.__born")
        if value:
            return value
        time.sleep(0.25)
    return None


def main():
    t = sv.T()
    folder = work / "ext"
    folder.mkdir()
    for name, body in EXTENSION.items():
        (folder / name).write_text(body)
    try:
        sv.setup()
        sv.launch()

        # A lone spinning tab, closed.
        a, pa = open_tab(BASE + "/spin")
        time.sleep(2)
        t.ok("a spinning tab has a page process", pa > 0)
        close(a)
        time.sleep(SETTLE)
        t.ok("a lone spinning tab, closed: its process is ended", pa > 0 and not alive(pa), pa)

        # Two tabs of the same site, the spinning one closed.
        b, pb = open_tab(BASE + "/idle")
        a, pa = open_tab(BASE + "/spin")
        time.sleep(2)
        print(f"  (same-site tabs: {'one process' if pa == pb else 'two processes'})")
        close(a)
        time.sleep(SETTLE)
        t.ok("two tabs of a site, the spinning one closed: the other still answers",
             alive(pb) and sv.ev(b, "document.title") == "idle", (pa, pb))
        close(b)

        # Controls: an idle tab closed, a busy one left open.
        busy, pbusy = open_tab(BASE + "/busy")
        idle, pidle = open_tab(BASE + "/idle")
        close(idle)
        # WebKit may end or keep an idle process on its own; what's checked
        # is that it isn't ended while still there right after the wait.
        time.sleep(SETTLE)
        t.ok("a busy tab left open isn't ended", alive(pbusy) and sv.ev(busy, "document.title") == "busy", pbusy)
        if pidle != pbusy and alive(pidle):
            t.ok("an idle tab closed: its process WebKit kept is still there", True)
        elif pidle != pbusy:
            print(f"  (an idle tab's process {pidle} went on its own: WebKit didn't keep it)")
        close(busy)

        # An extension's page in a tab, with its background busy.
        sv.cmd({"do": "ext-folder", "path": str(folder), "yes": True})
        ext = None
        for _ in range(60):
            ext = next((x for x in sv.cmd({"do": "extensions"})["extensions"] if x["name"] == "Stuck Probe" and x["loaded"]), None)
            if ext:
                break
            time.sleep(0.25)
        t.ok("the extension loads", ext is not None)
        if not ext:
            return t
        e, pe = ext_tab(ext["id"], "page.html")
        first = born(e)
        sv.ev(e, "ask('busy'),1")
        time.sleep(3)
        t.ok("the extension's background answers", first is not None)
        close(e)
        time.sleep(SETTLE)
        e2, _ = ext_tab(ext["id"], "page.html")
        later = born(e2)
        t.ok("an extension page closed while its background is busy: the background is the same one",
             first is not None and later == first, (pe, first, later))
        close(e2)
    finally:
        sv.finish()
        shutil.rmtree(work, ignore_errors=True)
    return t


if __name__ == "__main__":
    t = main()
    t.done()
    sys.exit(1 if t.failed else 0)
