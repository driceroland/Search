#!/usr/bin/env python3
"""1Password's button in a sign-in field, with its real extension, in a
hidden probe (idea 702).

Build first (`./build.sh`), then `SEARCH_1PASSWORD=1 python3
Tests/onepassword_inline.py`. Without SEARCH_1PASSWORD it says so and
passes: it downloads 1Password's extension from the Chrome Web Store
(~18 MB). It runs a copy of build/Search.app under a bundle id of its own,
in a world of its own with split_view.py's harness, started hidden; the
copy, the extension, its WebKit folders and the world are removed
afterwards. No 1Password account and no 1Password app are involved: the
probe copy finds no native host for it, by design.

1Password draws its button only once it holds an account, locked or not —
signed in within the extension, or handed over by the 1Password app it is
connected to. With none, its worker tells every page `inlineDisabled` and
nothing is drawn, in Chrome too. That is the one gate here that a probe
can't pass without an account, so the unpacked copy installed here has that
one expression in its worker replaced by `false`; everything else is
1Password's own. What is checked:

- with no account, the worker's configuration says inline is off (the
  reason a Search whose 1Password isn't connected shows no button);
- with the gate opened, its page script loads in the site (a dynamic
  import from its content script), the field is found on focus and
  1Password's button is put in the page, its icons load, and a picture of
  the page shows its "Unlock 1Password" tip under the field.
"""
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request
import zipfile
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("onepassword-inline")
BUNDLE = "com.officecommun.search.onepasswordinline"
ONEPASSWORD = "aeblfdkhhhdcdjpifhhbdiojplfjncoa"
GATE = "inlineDisabled:!r.inlineEnabled||$a.has(e.tab)||!o,"
# Where the worker's configuration comes back to the page (injected.js).
CONFIGURED = 'n.ok?f.dispatch({type:"configure",payload:n.data}):'
work = Path(tempfile.mkdtemp(prefix="search-onepasswordinline-"))

LOGIN = b"""<!doctype html><html><head><title>sign in</title></head><body>
<form method=post action=/done>
<label>Email <input id=u name=username type=email autocomplete=username></label>
<label>Password <input id=p name=password type=password autocomplete=current-password></label>
<button type=submit>Sign in</button></form></body></html>"""


class Site(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(LOGIN)))
        self.end_headers()
        self.wfile.write(LOGIN)

    def log_message(self, *a):
        pass


def unpacked(gate_open):
    """1Password's extension from the Web Store, unpacked; the worker's
    configuration also written on the page's root element, for the probe."""
    crx = work / "1password.crx"
    if not crx.exists():
        url = ("https://clients2.google.com/service/update2/crx?response=redirect&prodversion=156.0.0.0"
               f"&acceptformat=crx3&x=id%3D{ONEPASSWORD}%26uc")
        with urllib.request.urlopen(url, timeout=120) as r:
            crx.write_bytes(r.read())
    folder = work / ("open" if gate_open else "plain")
    shutil.rmtree(folder, ignore_errors=True)
    with zipfile.ZipFile(crx) as z:
        z.extractall(folder)
    shutil.rmtree(folder / "_metadata", ignore_errors=True)
    page = folder / "inline" / "injected.js"
    text = page.read_text()
    if CONFIGURED not in text:
        return None
    page.write_text(text.replace(CONFIGURED, '(document.documentElement.setAttribute("data-probe-config",'
                                 'JSON.stringify({ok:n.ok,inlineDisabled:n.data&&n.data.inlineDisabled})),n.ok)?'
                                 'f.dispatch({type:"configure",payload:n.data}):', 1))
    if gate_open:
        worker = folder / "background" / "background.js"
        text = worker.read_text()
        if text.count(GATE) != 1:
            return None
        worker.write_text(text.replace(GATE, "inlineDisabled:!1,", 1))
    return folder


def probe_copy():
    app = work / "Search.app"
    shutil.copytree(Path(sv.ROOT, "build", "Search.app"), app, symlinks=True)
    subprocess.run(["/usr/libexec/PlistBuddy", "-c", f"Set :CFBundleIdentifier {BUNDLE}", str(app / "Contents/Info.plist")], check=True)
    (app / "Contents/embedded.provisionprofile").unlink(missing_ok=True)
    subprocess.run(["codesign", "-f", "-s", "-", "--entitlements", str(Path(sv.ROOT, "Search.entitlements")), "--deep", str(app)],
                   check=True, capture_output=True)
    return str(app)


def until(tid, js, within):
    end = time.time() + within
    value = None
    while time.time() < end:
        try: value = sv.ev(tid, js)
        except RuntimeError: value = None
        if value:
            return value
        time.sleep(0.5)
    return value


def install(folder, within=90):
    for x in sv.cmd({"do": "extensions"})["extensions"]:
        sv.cmd({"do": "ext-remove", "id": x["id"]})
    sv.cmd({"do": "ext-folder", "path": str(folder), "yes": True})
    end = time.time() + within
    while time.time() < end:
        ext = next((x for x in sv.cmd({"do": "extensions"})["extensions"] if x["loaded"]), None)
        if ext:
            time.sleep(5)  # its worker sets itself up
            return ext
        time.sleep(0.5)
    return None


def main():
    t = sv.T()
    if os.environ.get("SEARCH_1PASSWORD") != "1":
        print("skipped: set SEARCH_1PASSWORD=1 to download 1Password's extension and check its button")
        return t
    srv = ThreadingHTTPServer(("127.0.0.1", 0), Site)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    login = f"http://localhost:{srv.server_port}/login"
    plain, opened = unpacked(False), unpacked(True)
    t.ok("1Password's extension is as this probe knows it", plain is not None and opened is not None)
    if not plain or not opened:
        return t
    sv.APP = probe_copy()
    try:
        sv.setup()
        sv.launch()
        sv.cmd({"do": "ext-answer", "answer": "yes"})

        ext = install(plain)
        t.ok("it loads", ext is not None)
        if not ext:
            return t
        tid = sv.cmd({"do": "open", "url": login})["id"]
        config = until(tid, "document.documentElement.getAttribute('data-probe-config') || ''", 20)
        t.ok("with no account, its worker turns the button off", config == '{"ok":true,"inlineDisabled":true}', config)

        ext = install(opened)
        t.ok("with the account gate open, it loads", ext is not None)
        if not ext:
            return t
        tid = sv.cmd({"do": "open", "url": login})["id"]
        config = until(tid, "document.documentElement.getAttribute('data-probe-config') || ''", 20)
        t.ok("its page script runs in the site and is configured", config == '{"ok":true,"inlineDisabled":false}', config)
        time.sleep(2)
        before = str(work / "before.png")
        sv.cmd({"do": "shot", "id": tid, "path": before})
        sv.cmd({"do": "tap", "id": tid, "selector": "#p"})
        button = until(tid, "document.getElementsByTagName('com-1password-button').length ? 'yes' : ''", 10)
        t.ok("a click in the password field puts 1Password's button in the page", button == "yes")
        base = f"chrome-extension://{ext['id']}/inline/images/icons/"
        sv.ev(tid, "window.__icons = {}; ['onepassword-stateful-container-right.svg', 'lock.svg'].forEach(function (n) {"
                   f" var i = new Image(); i.onload = function () {{ __icons[n] = i.naturalWidth; }}; i.onerror = function () {{ __icons[n] = 0; }}; i.src = '{base}' + n; }}); 1")
        icons = until(tid, "Object.keys(__icons).length === 2 ? JSON.stringify(__icons) : ''", 5)
        t.ok("its icons load in the page", bool(icons) and '":0' not in icons, icons)
        shot = str(work / "page.png")
        sv.cmd({"do": "shot", "id": tid, "path": shot})
        # The tip is a black box under the field, on a white page: many more
        # near-black pixels than the labels had before.
        def dark(path):
            out = subprocess.run([sys.executable, "-I", "-c", DARK, path], capture_output=True, text=True).stdout.strip()
            return int(out) if out.isdigit() else -1
        was, now = dark(before), dark(shot)
        t.ok("a picture of the page shows its tip under the field", was >= 0 and now - was > 1000, (was, now))
    finally:
        sv.finish()
        for kind in ("WebKit", "Caches", "HTTPStorages"):
            shutil.rmtree(Path.home() / "Library" / kind / BUNDLE, ignore_errors=True)
        shutil.rmtree(work, ignore_errors=True)
    return t


# How many near-black pixels the top of the picture has,
# read with ImageIO through sips's BMP so nothing needs installing.
DARK = r"""
import struct, subprocess, sys, tempfile, os
out = tempfile.mktemp(suffix='.bmp')
subprocess.run(['sips', '-s', 'format', 'bmp', sys.argv[1], '--out', out], capture_output=True)
data = open(out, 'rb').read(); os.remove(out)
offset, = struct.unpack_from('<I', data, 10); w, h = struct.unpack_from('<ii', data, 18); bpp, = struct.unpack_from('<H', data, 28)
step = bpp // 8; row = (w * step + 3) & ~3; top = h > 0; h = abs(h)
dark = 0
for y in range(min(h, 200)):
    r = (h - 1 - y) if top else y
    base = offset + r * row
    for x in range(0, w, 2):
        b, g, red = data[base + x * step], data[base + x * step + 1], data[base + x * step + 2]
        if b < 30 and g < 30 and red < 30: dark += 1
print(dark)
"""

if __name__ == "__main__":
    t = main()
    t.done()
    sys.exit(1 if t.failed else 0)
