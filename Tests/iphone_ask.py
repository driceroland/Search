#!/usr/bin/env python3
"""Search › What's New… (idea 968) and the iPhone beta's quieter places
(IPhoneAsk.swift), in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/iphone_ask.py`. The app is
started hidden in a world of its own, with SEARCH_OPTIN_URL pointing at a
server this script runs: no address ever goes to the real list. No window
is made or shown; the About window and the cards are drawn off screen to
PNGs in the world's folder.
"""
import json
import os
import subprocess
import sys
import threading
import time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

# Where the pictures go: SEARCH_SHOTS, or the world's folder (wiped at the end).
SHOTS = os.environ.get("SEARCH_SHOTS")

sv.use("iphone-ask")

POSTS = []


class Site(BaseHTTPRequestHandler):
    def do_POST(self):
        size = int(self.headers.get("Content-Length") or 0)
        POSTS.append({"path": self.path, "body": json.loads(self.rfile.read(size) or b"{}")})
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers()
        self.wfile.write(b'{"ok":true}')

    def log_message(self, *a): pass


site = ThreadingHTTPServer(("127.0.0.1", 0), Site)
threading.Thread(target=site.serve_forever, daemon=True).start()
OPTIN = f"http://127.0.0.1:{site.server_port}/api/"


def launch():
    if os.path.exists(sv.SOCK): os.remove(sv.SOCK)
    before = sv.running()
    subprocess.run(["open", "-n", "-g", "-j", "--env", f"SEARCH_PROBE={sv.W}", "--env", f"SEARCH_OPTIN_URL={OPTIN}", sv.APP])
    for _ in range(150):
        if os.path.exists(sv.SOCK): break
        time.sleep(0.1)
    time.sleep(2)
    sv.started.update((sv.running() - before) & sv.holding())


def ask(action="state", **f): return sv.cmd({"do": "iphoneask", "action": action, **f})


def blank_tab():
    sv.cmd({"do": "press", "code": 17, "chars": "t", "mods": ["cmd"]})
    time.sleep(0.5)


t = sv.T()
sv.setup()
launch()
try:
    # 968: Search › What's New… brings the card back, as after an update.
    again = sv.cmd({"do": "news", "again": True})
    t.ok("Search menu: About, Check for Updates…, What's New… in that order",
         again["menu"][0] == "About Search" and again["menu"][1].startswith("Check") and again["menu"][2] == "What's New…", again["menu"])
    t.ok("What's New… is enabled and shows the card", again["enabled"] and again["showing"], again)
    sv.cmd({"do": "news", "on": False})
    about = f"{SHOTS or sv.SUPPORT}/about.png"
    t.ok("About window draws (What's New button + iPhone line)", "saved" in sv.cmd({"do": "news", "about": True, "path": about}))

    # The iPhone beta: open on a fresh install, in every place.
    s = ask("reset")
    blank_tab()
    s = ask()
    t.ok("fresh: offered", s["open"], s)
    t.ok("fresh: Help has Search for iPhone…", "Search for iPhone…" in s["helpMenu"], s["helpMenu"])
    t.ok("fresh: a blank tab shows the line", s["newTab"], s)
    for spot in ["about", "help", "newTab"]:
        ask("picture", spot=spot, path=f"{SHOTS or sv.SUPPORT}/ask-{spot}.png")
    ask("picture", spot="newTab", opened=True, path=f"{SHOTS or sv.SUPPORT}/ask-newTab-open.png")

    s = ask("age", days=3.2)
    t.ok("after three days the blank tab's line is gone", not s["newTab"] and s["open"], s)
    s = ask("age", days=1)
    t.ok("within three days it is back", s["newTab"], s)

    s = ask("help")
    t.ok("Help › Search for iPhone… opens the card", s["card"], s)

    # Each place's press: the right endpoint, the right source, nothing else.
    for spot, source in [("about", "app-about"), ("help", "app-help"), ("newTab", "app-newtab")]:
        ask("reset")
        POSTS.clear()
        s = ask("join", email="probe@example.com", spot=spot)
        body = POSTS[-1]["body"] if POSTS else {}
        t.ok(f"{spot}: one POST to /api/ios-beta with source {source}",
             len(POSTS) == 1 and POSTS[0]["path"] == "/api/ios-beta" and body == {"email": "probe@example.com", "source": source}, POSTS)
        t.ok(f"{spot}: after joining, gone everywhere",
             not s["open"] and not s["newTab"] and "Search for iPhone…" not in s["helpMenu"], s)

    ask("reset")
    POSTS.clear()
    s = ask("dismiss")
    t.ok("Not now: gone everywhere", not s["open"] and not s["newTab"] and "Search for iPhone…" not in s["helpMenu"], s)
    t.ok("Not now sends nothing", POSTS == [], POSTS)
finally:
    sv.finish()
t.done()
sys.exit(1 if t.failed else 0)
