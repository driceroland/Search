#!/usr/bin/env python3
"""Escape in the window's own full screen, with Press Esc twice off, goes to
the page and the window stays in full screen, as in Safari (idea 582).

Build first (`./build.sh`), then `python3 Tests/window_fullscreen_escape.py`.
A hidden probe's window never enters full screen, so the bench's `seam`
tells it it is in it (its style mask says so; AppKit is never asked, and a
full-screen ask the window gets is counted and kept). Escape is pressed
through the app's own event queue, so the window's key monitor sees it
first, as a real press. What reached AppKit is what the window itself was
sent (`escapes`): one there is the press AppKit takes the window out on.

Checked, with the switch off: out of full screen, an Escape the page
doesn't use goes on to the window, as it always did (the count works);
in full screen the page has it, the copy WebKit hands back unused never
reaches the window, and nothing asks to leave; a page's own Escape
listener has it too; a find bar up in the window is still put away first,
the page not seeing that press. With the switch on, the first press is
kept and the second asks the window to leave (FullScreenEscape), which
shows the count of asks works too. A page's own full screen
(fullscreen_escape.py) is a separate suite.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("window-fs-escape")
ESC = "\u001b"

LISTEN = """
window.__keys = [];
if (!window.__listening) {
  window.__listening = true;
  ['keydown', 'keyup'].forEach(function (type) {
    window.addEventListener(type, function (e) {
      window.__keys.push(type + ':' + e.key);
      if (window.__keep && e.key === 'Escape') e.preventDefault();
    }, true);
  });
}
window.__keep = KEEP;
1
"""


def listen(tab, keep=False):
    sv.ev(tab, LISTEN.replace("KEEP", "true" if keep else "false"))


def saw(tab):
    keys = sv.ev(tab, "JSON.stringify(window.__keys)")
    sv.ev(tab, "window.__keys = []; 1")
    return keys or ""


def keys_to(tab):
    return sv.cmd({"do": "key", "id": tab, "text": "x"})


def esc():
    sv.cmd({"do": "press", "code": 53, "chars": ESC, "mods": []}); time.sleep(0.5)


def seam(**f):
    return sv.cmd({"do": "seam", **f})


def finding():
    return sv.sp("state")["finding"]


def off(t):
    sv.setup(**{"sidebar": True, "fullscreen.escapeTwice": False}); sv.launch()
    a = sv.page("a"); time.sleep(0.6)
    listen(a)

    # Out of full screen, nothing up: the page doesn't use Escape, and it
    # goes on to the window, as it always did.
    keys_to(a); saw(a); seam(count=True)
    esc(); s = seam()
    t.ok("out of full screen, Escape goes on to the window", s["escapes"] >= 1 and not s["fullScreen"], s)

    on = seam(fullScreen=True, count=True)
    t.ok("the window says it is in full screen", on["fullScreen"] is True, on)

    # In full screen: the page's, and nothing of it reaches the window.
    keys_to(a); saw(a); seam(count=True)
    esc(); s = seam(); seen = saw(a)
    t.ok("full screen: the page has the Escape", "keydown:Escape" in seen, seen)
    t.ok("full screen: neither the press nor the copy WebKit hands back reaches the window",
         s["escapes"] == 0 and s["toggles"] == 0, s)
    t.ok("full screen: the window stays in full screen", s["fullScreen"] is True, s)

    # Twice more, quickly: still the page's each time.
    keys_to(a); saw(a); seam(count=True)
    esc(); esc(); s = seam(); seen = saw(a)
    t.ok("full screen: two quick presses both reach the page, none the window",
         seen.count("keydown:Escape") == 2 and s["escapes"] == 0 and s["toggles"] == 0, (seen, s))

    # The page's own Escape listener, taking the key.
    listen(a, keep=True)
    keys_to(a); saw(a); seam(count=True)
    esc(); s = seam(); seen = saw(a)
    t.ok("full screen: a page's own Escape listener has it, the window nothing",
         "keydown:Escape" in seen and s["escapes"] == 0, (seen, s))
    listen(a)

    # Search's own Escape jobs come first: a find bar up is put away.
    sv.cmd({"do": "find", "text": "a"}); keys_to(a); saw(a); seam(count=True)
    up = finding()
    esc(); s = seam(); seen = saw(a)
    t.ok("full screen: a find bar up is put away first, the page not seeing that press",
         up and not finding() and "keydown:Escape" not in seen and s["toggles"] == 0, (up, seen, s))

    # A key the page doesn't use is still kept quiet (#402).
    quiet = keys_to(a)
    t.ok("full screen: a key the page doesn't use is still kept quiet",
         quiet.get("sentBackUnused") == 1 and quiet.get("quieted") == 1, quiet)

    # Out of full screen again: Escape goes on to the window as before.
    seam(fullScreen=False); keys_to(a); saw(a); seam(count=True)
    esc(); s = seam()
    t.ok("out of full screen again, Escape goes on to the window", s["escapes"] >= 1, s)
    seam(real=True)
    sv.quit()


def twice(t):
    sv.setup(**{"sidebar": True, "fullscreen.escapeTwice": True}); sv.launch()
    a = sv.page("a"); time.sleep(0.6)
    listen(a)
    seam(fullScreen=True, count=True)
    keys_to(a); saw(a)
    esc(); s1 = seam()
    esc(); s2 = seam()
    t.ok("Esc twice on: the first press doesn't ask the window to leave", s1["toggles"] == 0, s1)
    t.ok("Esc twice on: the second asks it to leave (and the ask is counted, not done)", s2["toggles"] == 1, s2)
    seam(real=True)
    sv.quit()


def main():
    t = sv.T()
    try:
        off(t)
        twice(t)
    finally:
        t.done(); sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
