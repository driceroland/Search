#!/usr/bin/env python3
"""A link's small window (Little.swift) and its keys, in a hidden probe:
copying its address, finding and zooming on its page, closing and keeping it.

Build first (`./build.sh`), then `python3 Tests/little_window.py`. The small
windows are made unseen by `./bench little`, and keys are pressed on them
through the app's own event queue (`press` with "little"), so they meet the
same monitors a real press does.

Its own harness rather than split_view's: that one kills every copy running
from build/, and a copy of this build is often open being looked at. This one
quits and kills only the process it started, and removes its world after.

Copying writes the Mac's pasteboard; the text on it before is put back.
"""
import json
import os
import socket
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APP = str(ROOT / "build" / "Search.app")
W = "little-tests"
SUPPORT = f"{os.path.expanduser('~')}/Library/Application Support/Search ({W})"
SUITE = f"com.officecommun.search.test.{W}"


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        body = f"<!doctype html><title>{self.path.strip('/')}</title><p>{self.path}".encode()
        self.send_response(200); self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass


srv = ThreadingHTTPServer(("127.0.0.1", 0), H); threading.Thread(target=srv.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{srv.server_port}"


def pids(): return set(subprocess.run(["pgrep", "-f", APP + "/Contents/MacOS"], capture_output=True, text=True).stdout.split())
def wipe():
    subprocess.run(["rm", "-rf", SUPPORT]); subprocess.run(["defaults", "delete", SUITE], capture_output=True)
def cmd(req):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as c:
        c.settimeout(30); c.connect(f"{SUPPORT}/bench.sock"); c.sendall(json.dumps(req).encode() + b"\n")
        data = b""
        while True:
            ch = c.recv(65536)
            if not ch: break
            data += ch
    a = json.loads(data.split(b"\n", 1)[0] or b"{}")
    if "error" in a: raise RuntimeError(f"{req}: {a['error']}")
    return a
def little(what): return cmd({"do": "little", "what": what})
def press(code, chars, *mods): cmd({"do": "press", "code": code, "chars": chars, "mods": list(mods), "little": True}); time.sleep(0.3)
def paste(): return subprocess.run(["pbpaste"], capture_output=True, text=True).stdout
def found():
    for _ in range(80):
        status = little("look")["findStatus"]
        if status: return status
        time.sleep(0.05)
    return ""


class T:
    passed = failed = 0
    def ok(self, name, cond, extra=""):
        if cond: self.passed += 1; print("  ok  ", name)
        else: self.failed += 1; print("  FAIL", name, extra)


t = T()
saved = subprocess.run(["pbpaste"], capture_output=True).stdout
probe = set()
try:
    wipe()
    for k in ["bench", "welcomed"]: subprocess.run(["defaults", "write", SUITE, k, "-bool", "true"])
    before = pids(); sock = f"{SUPPORT}/bench.sock"
    subprocess.run(["open", "-n", "-g", "-j", "--env", f"SEARCH_PROBE={W}", APP])
    for _ in range(150):
        if os.path.exists(sock): break
        time.sleep(0.1)
    time.sleep(2); probe = pids() - before

    # ⌘⇧C: this page's address, said at the window's foot — not the tab
    # behind it in the browser's window, which the menu would copy.
    little(f"{BASE}/copied"); time.sleep(2)
    subprocess.run(["pbcopy"], input=b"before")
    press(8, "c", "cmd", "shift")
    t.ok("⌘⇧C copies the small window's address", paste() == f"{BASE}/copied", paste())
    t.ok("⌘⇧C says so in the small window", little("look")["said"] == "Address copied", little("look"))
    time.sleep(2)
    t.ok("and then stops saying it", little("look")["said"] == "")

    # ⌘W and Escape close it; the browser's row is as it was.
    tabs = little("look")["tabs"]
    press(13, "w", "cmd")
    st = little("look")
    t.ok("⌘W closes the small window", st["littles"] == [], st["littles"])
    t.ok("⌘W leaves the browser's tabs alone", st["tabs"] == tabs, (tabs, st["tabs"]))
    little(f"{BASE}/escaped"); time.sleep(1.5)
    press(53, "\u001b")
    t.ok("Escape closes it", little("look")["littles"] == [])

    # ⌘F: a bar of its own, on its own page; Escape puts the bar away
    # before it closes the window.
    little(f"{BASE}/findme"); time.sleep(1.5)
    press(3, "f", "cmd")
    t.ok("⌘F opens the small window's find bar", little("look")["finding"])
    little("find:findme")
    t.ok("it finds on the small window's page", found() == "1 of 1", little("look"))
    press(53, "\u001b")
    st = little("look")
    t.ok("Escape closes the find bar, not the window", not st["finding"] and len(st["littles"]) == 1, st)

    # Zoom: its page, by the browser's steps, said at its own foot.
    press(24, "=", "cmd")
    st = little("look")
    t.ok("⌘+ zooms the small window's page", abs(st["zoom"] - 1.1) < 0.01, st["zoom"])
    t.ok("and says so there", st["said"] == "110%", st["said"])
    press(27, "-", "cmd"); press(27, "-", "cmd")
    t.ok("⌘- zooms it out", little("look")["zoom"] < 1, little("look")["zoom"])
    press(29, "0", "cmd")
    t.ok("⌘0 puts it back", abs(little("look")["zoom"] - 1) < 0.01, little("look")["zoom"])
    press(53, "\u001b")

    # The browser's own find bar, now a FindSession of its own, as before.
    row = cmd({"do": "open", "url": f"{BASE}/inrow"})["id"]
    cmd({"do": "wait", "id": row}); cmd({"do": "select", "id": row})
    r = cmd({"do": "find", "text": "inrow"})
    t.ok("the browser's find bar still finds on its tab", r["status"] == "1 of 1", r)
    t.ok("and the small window's find is its own", not little("look")["finding"])
    cmd({"do": "close", "id": row})

    # Kept: into the row, the small window gone.
    little(f"{BASE}/kept"); time.sleep(1.5)
    st = little("keep"); time.sleep(0.5); st = little("look")
    t.ok("Open in Search moves the page into the row", "127.0.0.1" in st["tabs"] and st["littles"] == [], st)
finally:
    subprocess.run(["pbcopy"], input=saved)
    try: cmd({"do": "quit"})
    except Exception: pass
    for _ in range(30):
        if not (pids() & probe): break
        time.sleep(0.2)
    for p in pids() & probe: subprocess.run(["kill", p])
    wipe()
    print(f"{t.passed} passed, {t.failed} failed")
sys.exit(1 if t.failed else 0)
