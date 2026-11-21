#!/usr/bin/env python3
"""Correct Spelling Automatically, checked in a hidden probe (idea 743).

Build first (`./build.sh`), then run `python3 Tests/autocorrect.py`.

Switched off, autocorrect stayed on: WebKit keeps one switch for every page,
read from the app's standard defaults once, and Search flipped it whenever
the default disagreed with the choice. Once the default and WebKit had come
apart (another Search sharing the defaults writes it), every flip went the
wrong way: setting and menu off, WebKit on. Checked
here: the setting, the Edit menu's tick, the default and WebKit's own answer
agree after switching from Settings, with the default changed behind
WebKit's back, after a page opened since, and after a relaunch.

Inline predictions (idea 842): the grey rest of a word WebKit offers at the
caret whenever the Mac's "Show inline predictive text" is on, autocorrect or
not. Edit › Spelling and Grammar › Show Inline Predictions is off unless
switched on, and counts over the Mac. The Mac's settings can't be touched
here, so they are played in the copy's own domain, which AppKit reads before
the global one: inline predictions, text completion and autocorrect said on
there before launch (as an app that follows a Mac with them on sees them),
and again behind Search's back before the relaunch. Checked: the setting,
the menu's tick, the default and whether the page's view would show a
prediction at the caret agree, off at launch, on and off from the menu, in a
page opened since and after a relaunch; and a misspelled sentence typed into
a textarea and a contenteditable stays as typed.

As in text_replacement.py, the build is copied under a bundle id of its own,
since the switch lives in the app's standard defaults, and run hidden in a
world of its own; everything is removed afterwards. WebKit only answers for
a field that has the caret, so the field is focused before each look.
Nothing here makes, shows or brings forward a window.
"""

import hashlib
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BUILT = ROOT / "build" / "Search.app"
HOME = os.path.expanduser("~")
ID = "com.officecommun.search.autocorrect"
W = f"ac-{hashlib.sha1(str(ROOT).encode()).hexdigest()[:8]}"
SUPPORT = f"{HOME}/Library/Application Support/Search ({W})"
SUITE = f"com.officecommun.search.test.{W}"
SOCK = f"{SUPPORT}/bench.sock"
COPY = Path(tempfile.mkdtemp(prefix="ac-probe-")) / "Search.app"
EXE = str(COPY / "Contents" / "MacOS" / "Search")

PAGE = b"""<!doctype html><title>typing</title>
<input id=i autocomplete=off><textarea id=t></textarea><div id=e contenteditable></div>"""
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(PAGE))); self.end_headers(); self.wfile.write(PAGE)
    def log_message(self, *a): pass
srv = None
for port in range(8826, 8832):
    try: srv = ThreadingHTTPServer(("127.0.0.1", port), H); break
    except OSError: continue
if not srv: sys.exit("no free port in 8826–8831")
threading.Thread(target=srv.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{srv.server_port}"

def ours():
    """Only the copy this run made, by its own path."""
    out = subprocess.run(["pgrep", "-f", EXE], capture_output=True, text=True).stdout.split()
    return out

def wipe():
    subprocess.run(["rm", "-rf", SUPPORT])
    for domain in (SUITE, ID):
        subprocess.run(["defaults", "delete", domain], capture_output=True)
    for folder in ("WebKit", "Caches", "HTTPStorages", "Saved Application State"):
        name = f"{ID}.savedState" if folder == "Saved Application State" else ID
        subprocess.run(["rm", "-rf", f"{HOME}/Library/{folder}/{name}"])
    subprocess.run(["rm", "-f", f"{HOME}/Library/Preferences/{ID}.plist", f"{HOME}/Library/Preferences/{SUITE}.plist"])

def make_copy():
    shutil.copytree(BUILT, COPY, symlinks=True)
    plist = str(COPY / "Contents" / "Info.plist")
    subprocess.run(["plutil", "-replace", "CFBundleIdentifier", "-string", ID, plist], check=True)
    (COPY / "Contents" / "embedded.provisionprofile").unlink(missing_ok=True)
    subprocess.run(["codesign", "--force", "--deep", "-s", "-", "--entitlements", str(ROOT / "Search.entitlements"), str(COPY)],
                   check=True, capture_output=True)

def cmd(req):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as c:
        c.settimeout(30); c.connect(SOCK); c.sendall(json.dumps(req).encode() + b"\n")
        data = b""
        while True:
            ch = c.recv(65536)
            if not ch: break
            data += ch
    return json.loads(data.split(b"\n", 1)[0] or b"{}")

def ev(id, js): return cmd({"do": "eval", "id": id, "js": js}).get("value")

class T:
    passed = failed = 0
    def ok(self, name, cond, extra=""):
        if cond: self.passed += 1; print(f"  ok   {name}")
        else: self.failed += 1; print(f"  FAIL {name} {extra}")

def typed(t, tab, field, text):
    ev(tab, f"(() => {{ const f = document.getElementById('{field}'); f.value = ''; f.focus(); return document.activeElement.id }})()")
    cmd({"do": "key", "id": tab, "text": text})
    time.sleep(1)
    return ev(tab, f"document.getElementById('{field}').value")

def launch():
    """The copy, hidden, never brought forward → a bench tab on the page,
    behind the tab the window opened with."""
    if os.path.exists(SOCK): os.remove(SOCK)
    subprocess.run(["open", "-n", "-g", "-j", "--env", f"SEARCH_PROBE={W}", str(COPY)], check=True)
    for _ in range(150):
        if os.path.exists(SOCK): break
        time.sleep(0.1)
    time.sleep(2)
    tab = cmd({"do": "open", "url": f"{BASE}/"})["id"]
    cmd({"do": "wait", "id": tab, "seconds": 10})
    time.sleep(0.5)
    return tab

def quit():
    try: cmd({"do": "quit"})
    except Exception: pass
    for _ in range(30):
        if not ours(): break
        time.sleep(0.2)
    for p in ours(): subprocess.run(["kill", p])
    time.sleep(0.5)

def look(tab):
    """Autocorrect as everything sees it, with the textarea's caret in."""
    ev(tab, "document.getElementById('t').focus()")
    time.sleep(0.3)
    return cmd({"do": "textcheck", "id": tab})["autocorrect"]

def agree(t, name, tab, want):
    a = look(tab)
    t.ok(f"{name}: setting, menu, default and WebKit all say {want}",
         a["setting"] is want and a["menu"] is want and a["kept"] is want and a["page"] is want, str(a))

def agree_predictions(t, name, tab, want):
    a = look_all(tab)["predictions"]
    t.ok(f"{name}: inline predictions' setting, menu, default and page all say {want}",
         a["setting"] is want and a["menu"] is want and a["kept"] is want and a["page"] is want, str(a))

def look_all(tab):
    ev(tab, "document.getElementById('t').focus()")
    time.sleep(0.3)
    return cmd({"do": "textcheck", "id": tab})

def mac_says_on():
    """The Mac's settings as the copy sees them, played in its own domain:
    what AppKit reads before the global domain."""
    for key in ("NSAutomaticInlinePredictionEnabled", "NSAutomaticTextCompletionEnabled",
                "NSAutomaticSpellingCorrectionEnabled"):
        subprocess.run(["defaults", "write", ID, key, "-bool", "true"])
    subprocess.run(["defaults", "delete", ID, "WebAutomaticSpellingCorrectionEnabled"], capture_output=True)

def typed_editable(tab, text):
    ev(tab, "(() => { const e = document.getElementById('e'); e.textContent = ''; e.focus(); return document.activeElement.id })()")
    cmd({"do": "key", "id": tab, "text": text})
    time.sleep(1)
    return ev(tab, "document.getElementById('e').textContent")

def front(tab):
    cmd({"do": "select", "id": tab}); time.sleep(0.3)

def settings_front():
    """Settings in front: a tab with no page view of its own."""
    tab = cmd({"do": "open", "url": "search://settings"})["id"]
    front(tab)
    return next((x for x in cmd({"do": "tabs"})["tabs"] if x["id"] == tab), None)

def behind_its_back(value):
    """The default changed where WebKit doesn't look again, as another
    Search sharing the app's defaults writes it at its launch."""
    subprocess.run(["defaults", "write", ID, "WebAutomaticSpellingCorrectionEnabled", "-bool", "true" if value else "false"])
    time.sleep(0.5)

def main():
    if ours(): sys.exit("a copy from this run is already running")
    wipe()
    for k in ["bench", "welcomed", "autocorrect"]: subprocess.run(["defaults", "write", SUITE, k, "-bool", "true"])
    make_copy()
    mac_says_on()
    t = T()
    try:
        tab = launch()
        agree(t, "at launch, on", tab, True)
        agree_predictions(t, "at launch, with the Mac's on", tab, False)
        cmd({"do": "textcheck", "id": tab, "toggle": "predictions"})
        agree_predictions(t, "switched on from the menu", tab, True)
        cmd({"do": "textcheck", "id": tab, "toggle": "predictions"})
        agree_predictions(t, "switched off again", tab, False)
        # Switched from Settings, where no page is in front.
        shown = settings_front()
        t.ok("Settings is in front, with no page view", shown is not None and shown["active"] and shown["view"] == "", str(shown))
        cmd({"do": "textcheck", "id": tab, "toggle": "autocorrect"})
        agree(t, "switched off from Settings", tab, False)
        cmd({"do": "textcheck", "id": tab, "toggle": "autocorrect"})
        agree(t, "back on from Settings", tab, True)
        # The default and WebKit apart: every flip on a guess went the wrong
        # way from there.
        front(tab)
        behind_its_back(False)
        cmd({"do": "textcheck", "id": tab, "toggle": "autocorrect"})
        agree(t, "off with the default already saying off", tab, False)
        behind_its_back(True)
        cmd({"do": "textcheck", "id": tab, "toggle": "autocorrect"})
        agree(t, "on with the default already saying on", tab, True)
        cmd({"do": "textcheck", "id": tab, "toggle": "autocorrect"})
        agree(t, "off again with the page in front", tab, False)
        fresh = cmd({"do": "open", "url": f"{BASE}/fresh"})["id"]
        cmd({"do": "wait", "id": fresh, "seconds": 10})
        agree(t, "a page opened since", fresh, False)
        agree_predictions(t, "a page opened since", fresh, False)
        sentence = "i have an isue would you min teh"
        v = typed(t, fresh, "t", sentence)
        t.ok("typed into a textarea, it stays as typed", v == sentence, repr(v))
        v = typed_editable(fresh, sentence)
        t.ok("typed into a contenteditable, it stays as typed", v == sentence, repr(v))
        quit()
        mac_says_on()
        tab = launch()
        agree(t, "off after a relaunch, with the Mac's on", tab, False)
        agree_predictions(t, "off after a relaunch, with the Mac's on", tab, False)
        cmd({"do": "textcheck", "id": tab, "toggle": "predictions"})
        quit()
        tab = launch()
        agree_predictions(t, "on kept through a relaunch", tab, True)
        settings_front()
        cmd({"do": "textcheck", "id": tab, "toggle": "autocorrect"})
        agree(t, "on again from Settings", tab, True)
    finally:
        quit()
        wipe()
        shutil.rmtree(COPY.parent, ignore_errors=True)
        srv.shutdown()
    print(f"{t.passed} passed, {t.failed} failed")
    sys.exit(1 if t.failed else 0)

main()
