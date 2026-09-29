"""Settings › Appearance › Darken light pages (Dusk.swift), in the real app.

Build first (`./build.sh`), then `python3 Tests/dark_pages.py [SHOTS_DIR]`.
It uses the split suite's harness: started hidden, in a world of its own,
everything removed afterwards. Two sites stand in: a light one on localhost
and one on 127.0.0.1 that goes dark by itself. The page script's own cases
(an app drawn late, a theme switched later, oklch…) are Tests/DuskHarness.swift's;
this is the wiring around it: the keys, the pause, the setting, the look.
What can only be seen is in the shots, when a folder is named.
"""
import plistlib
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.W = "dark-pages"
sv.SUPPORT = f"{sv.HOME}/Library/Application Support/Search ({sv.W})"
sv.SUITE = f"com.officecommun.search.test.{sv.W}"
sv.SOCK = f"{sv.SUPPORT}/bench.sock"
SHOTS = sys.argv[1] if len(sys.argv) > 1 else None

PAGES = {
    "/light": "<style>body{background:#fff;color:#222;font:15px -apple-system}</style>"
              "<h2>A light site</h2><p>Text with a <a href=#>link</a>.</p>",
    "/dark": "<style>body{background:#fff;color:#222}"
             "@media (prefers-color-scheme: dark){body{background:#111;color:#eee}}</style>"
             "<h2>A site with a dark look of its own</h2>",
}


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        body = f"<!doctype html><title>{self.path.strip('/')}</title>{PAGES.get(self.path, '')}".encode()
        self.send_response(200); self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)

    def log_message(self, *a): pass


srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
LIGHT = f"http://localhost:{srv.server_port}/light"
DARK = f"http://127.0.0.1:{srv.server_port}/dark"

t = sv.T()


def tab(id): return next(x for x in sv.cmd({"do": "tabs"})["tabs"] if x["id"] == id)
def dusked(id): return tab(id)["dusked"]
def state(id): return sv.cmd({"do": "eval", "id": id, "js": "window.__officeDusk ? window.__officeDusk.state() : null", "world": "search"}).get("value")
def open_(url, **f):
    id = sv.cmd({"do": "open", "url": url, **f})["id"]
    sv.cmd({"do": "wait", "id": id}); time.sleep(0.8)
    return id
# D is key code 2. ⇧⌘D goes through the window's own key handling with the
# page holding the keys (keyeq): a hidden probe has no key window for a
# posted press to reach. ⌥⇧⌘D is the menu's, which a posted press reaches.
def press(*mods):
    if "opt" in mods: sv.cmd({"do": "press", "code": 2, "chars": "d", "mods": ["cmd", *mods]})
    else: sv.cmd({"do": "keyeq", "code": 2, "chars": "d", "mods": list(mods)})
    time.sleep(0.8)
def ui(**f): sv.cmd({"do": "ui", **f}); time.sleep(0.8)
def sites():
    out = subprocess.run(["defaults", "export", sv.SUITE, "-"], capture_output=True).stdout
    return plistlib.loads(out).get("dusk.sites", {}) if out else {}
def shot(id, name):
    if SHOTS: sv.cmd({"do": "shot", "id": id, "path": f"{SHOTS}/{name}.png", "width": 520})


try:
    # Nothing set but the look: the setting is on unless turned off.
    sv.setup()
    subprocess.run(["defaults", "write", sv.SUITE, "look", "-string", "dark"])
    sv.launch()
    if SHOTS: Path(SHOTS).mkdir(parents=True, exist_ok=True)

    light = open_(LIGHT)
    dark = open_(DARK)
    t.ok("on by default: a light site is darkened", dusked(light), state(light))
    t.ok("a site dark by itself is left alone", not dusked(dark), state(dark))
    t.ok("…because it measured dark, not because nothing ran", (state(dark) or {}).get("native") is True, state(dark))
    shot(light, "light-darkened"); shot(dark, "dark-left-alone")

    sv.cmd({"do": "select", "id": light}); time.sleep(0.4)
    press("shift")
    t.ok("⇧⌘D: the site you're on is let go, at once", not dusked(light), state(light))
    t.ok("…and kept for the site", sites() == {"localhost": False}, sites())
    sv.cmd({"do": "go", "id": light, "url": LIGHT})
    sv.cmd({"do": "wait", "id": light}); time.sleep(0.8)
    t.ok("…its next page too", not dusked(light), state(light))
    press("shift")
    t.ok("⇧⌘D again: darkened again", dusked(light), state(light))
    t.ok("…and the choice, now the same as the measuring, isn't kept", sites() == {}, sites())

    press("shift", "opt")
    t.ok("⌥⇧⌘D: paused, every page as its site made it", not dusked(light), state(light))
    fresh = open_(LIGHT)
    t.ok("…a page opened while paused gets nothing at all", state(fresh) is None, state(fresh))
    press("shift", "opt")
    t.ok("⌥⇧⌘D again: darkened again", dusked(light), state(light))
    t.ok("…the page opened while paused too", dusked(fresh), state(fresh))

    ui(look="light")
    t.ok("a light frame darkens nothing", not dusked(light), state(light))
    ui(look="dark")
    t.ok("dark again: darkened again", dusked(light), state(light))

    ui(dusk=False)
    t.ok("turned off in Settings: let go at once", not dusked(light), state(light))
    off = open_(LIGHT)
    t.ok("…and a new page gets nothing at all", state(off) is None, state(off))
    ui(dusk=True)
    t.ok("turned on again: an open page is darkened without a reload", dusked(off), state(off))

    shy = open_(LIGHT, private=True)
    t.ok("a private tab is darkened too", dusked(shy), state(shy))
    sv.cmd({"do": "select", "id": shy}); time.sleep(0.4)
    press("shift")
    t.ok("⇧⌘D in a private tab: this page is let go", not dusked(shy), state(shy))
    t.ok("…and nothing is kept for the site", sites() == {}, sites())
finally:
    t.done(); sv.finish()
sys.exit(1 if t.failed else 0)
