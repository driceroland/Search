#!/usr/bin/env python3
"""Idea 1075: ⌘T or ⌘L over a page with single-key shortcuts, then typing:
the field has every key and the page none, in every way the field can look.

Build first (`./build.sh`), then `python3 Tests/field_page_keys.py`. It uses
the split suite's harness: started hidden in a world of its own, no window
shown, everything removed afterwards.

The page is a review tool's: a keydown listener on the document logs every
key and calls preventDefault on `a` and `j`. The page has the keys (a key is
typed into it first), then ⌘T or ⌘L is pressed and "ajk" typed through the
app's event queue, as a hand would: once right after the shortcut (30 ms
between presses, the first keystroke racing the field) and once after a
pause. Every pairing of New tab in a floating field and The field in the
middle of the window, with the tabs on top and in a column.
"""
import http.server
import subprocess
import sys
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("field-page-keys")
t = sv.T()

PAGE = b"""<!doctype html><title>review</title>
<p>review tool: a adds a comment, j and k move.
<script>
window.keys = [];
document.addEventListener('keydown', function (e) {
  window.keys.push(e.key);
  if (e.key === 'a' || e.key === 'j') e.preventDefault();
});
</script>"""


class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(PAGE))); self.end_headers(); self.wfile.write(PAGE)

    def log_message(self, *a): pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
threading.Thread(target=server.serve_forever, daemon=True).start()
URL = f"http://localhost:{server.server_port}/review"

CODES = {"a": 0, "j": 38, "k": 40}
TYPED = "ajk"


def press(code, chars, cmd=False):
    sv.cmd({"do": "press", "code": code, "chars": chars, "mods": ["cmd"] if cmd else []})


def shortcut_then_type(code, chars, quick):
    """The shortcut, then TYPED: right behind it (each press sent 30 ms after
    the one before, without waiting for its answer) or after a pause."""
    if not quick:
        press(code, chars, cmd=True); time.sleep(0.8)
        for c in TYPED: press(CODES[c], c)
        time.sleep(0.4); return
    threads = []
    for i, (k, c, m) in enumerate([(code, chars, True)] + [(CODES[c], c, False) for c in TYPED]):
        th = threading.Thread(target=press, args=(k, c, m)); th.start(); threads.append(th)
        time.sleep(0.03)
    for th in threads: th.join()
    time.sleep(0.4)


def field_text():
    try:
        sv.cmd({"do": "caret"})
        r = sv.cmd({"do": "caret"})
        return r.get("text")
    except RuntimeError:
        return None


def page_keys(tab):
    return sv.cmd({"do": "eval", "id": tab, "js": "JSON.stringify(window.keys)"}).get("value")


def focus_page(tab):
    """The page has the keys, as after a click on it; its log emptied."""
    sv.cmd({"do": "key", "id": tab, "text": "z"}); time.sleep(0.3)
    sv.cmd({"do": "eval", "id": tab, "js": "window.keys = []; 1"})


def active():
    return sv.cmd({"do": "press", "code": 63, "chars": ""}).get("active", "")  # fn: presses nothing


def back_to(tab):
    """Escape the field; with the plain field ⌘T made a tab: close it."""
    sv.cmd({"do": "press", "code": 53, "chars": "\u001b"}); time.sleep(0.5)
    a = active()
    if a and not tab.startswith(a):
        press(13, "w", cmd=True); time.sleep(0.6)


try:
    for column in (True, False):
        for floating, centred in ((True, False), (True, True), (False, False), (False, True)):
            sv.setup(sidebar=column)
            subprocess.run(["defaults", "write", sv.SUITE, "newtab.floating", "-bool", "true" if floating else "false"])
            subprocess.run(["defaults", "write", sv.SUITE, "field.window", "-bool", "true" if centred else "false"])
            sv.launch()
            tab = sv.sp("open", url=URL)["resultID"]; time.sleep(1.5)
            where = ("floating" if floating else "plain") + (", middle of the window" if centred else ", over the page") \
                + (", tabs in a column" if column else ", tabs on top")
            for name, code, chars in (("⌘T", 17, "t"), ("⌘L", 37, "l")):
                for quick in (True, False):
                    focus_page(tab)
                    shortcut_then_type(code, chars, quick)
                    text, keys = field_text(), page_keys(tab)
                    label = f"{where}: {name} then typing {'at once' if quick else 'after a pause'}"
                    t.ok(f"{label}: the field has the keys", text == TYPED, f"field={text!r}")
                    t.ok(f"{label}: the page has none", keys == "[]", f"page={keys}")
                    back_to(tab)
            sv.finish()
finally:
    t.done(); sv.finish(); server.shutdown()
sys.exit(1 if t.failed else 0)
