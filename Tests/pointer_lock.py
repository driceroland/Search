#!/usr/bin/env python3
"""A page asks for the pointer (requestPointerLock, #1305), in a hidden
probe.

Build first (`./build.sh debug`), then `python3 Tests/pointer_lock.py`.
A test run never really locks the pointer, which would take the mouse of
whoever is working beside it: Search answers WebKit no and keeps what it
would have answered, and holds the lock itself as if granted (see
PointerLock). A hidden page is never focused, so WebKit refuses it before
asking Search; the bench asks Search WebKit's question instead
(`pointerlock`), after a real click in the page. Checked here: asked without a click in the page, it is
refused; asked from a real click (the bench's tap, trusted as a hand's
is), it is granted, held, and "Press Esc to show your pointer" is up;
Escape lets it go, takes the pill away, and reaches the page rather than
closing the find bar left up; and a tab no longer in front is refused.
A coding agent's tab is refused in PointerLockTests. The pointer really
hidden, and the pill as it shows, are checked by hand on a release
candidate.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("pointer-lock")
ESC = "\u001b"

GAME = """
window.__keys = [];
addEventListener('keydown', e => window.__keys.push(e.key), true);
const b = document.createElement('button');
b.id = 'play'; b.textContent = 'Play';
b.style = 'position:fixed;left:40px;top:40px;width:160px;height:60px';
b.onclick = () => document.body.requestPointerLock();
document.body.appendChild(b);
1
"""


def lock():
    return sv.cmd({"do": "probe"})["pointerLock"]


def ask(tab):
    """WebKit's question for the page, asked as WebKit asks it: a hidden
    probe's page is never focused, so WebKit itself refuses it first."""
    return sv.cmd({"do": "pointerlock", "id": tab})


def main():
    t = sv.T()
    sv.setup(sidebar=True); sv.launch()
    try:
        a = sv.page("game")
        sv.ev(a, GAME)

        # No click in the page: refused.
        s = ask(a)
        t.ok("asked with no click, it is refused", s["answered"] == "denied: no gesture" and not s["given"], s)
        s = lock()
        t.ok("asked with no click, not held and no pill", not s["held"] and not s["hint"], s)

        # A real click on Play: granted, held, pill up. A test run answers
        # WebKit no all the same, so the real pointer is never taken.
        tapped = sv.cmd({"do": "tap", "id": a, "selector": "#play"}); time.sleep(0.3)
        s = ask(a)
        t.ok("from a click, granted", s["answered"] == "granted", (tapped, s))
        t.ok("a test run never really locks the pointer", s["given"] is False, s)
        s = lock()
        t.ok("from a click, held", s["held"], s)
        t.ok("from a click, the pill says Esc shows the pointer", s["hint"], s)

        # Escape: let go, the pill gone, and the key the page's, not the
        # find bar's.
        sv.cmd({"do": "find", "text": "a"}); time.sleep(0.3)
        sv.ev(a, "window.__keys = []; 1")
        sv.cmd({"do": "press", "code": 53, "chars": ESC}); time.sleep(0.5)
        s = lock()
        t.ok("Escape lets the pointer go", not s["held"], s)
        t.ok("Escape takes the pill away", not s["hint"], s)
        t.ok("Escape reaches the page", "Escape" in (sv.ev(a, "JSON.stringify(window.__keys)") or ""))
        t.ok("Escape leaves the find bar while it frees the pointer", sv.sp("state")["finding"])
        sv.cmd({"do": "press", "code": 53, "chars": ESC}); time.sleep(0.4)
        t.ok("the next Escape is Search's again", not sv.sp("state")["finding"])

        # The pill goes by itself, the pointer still held.
        sv.cmd({"do": "tap", "id": a, "selector": "#play"}); time.sleep(0.3)
        ask(a); time.sleep(3.4)
        s = lock()
        t.ok("the pill goes after a few seconds, the pointer still held", not s["hint"] and s["held"], s)
        sv.cmd({"do": "press", "code": 53, "chars": ESC}); time.sleep(0.4)

        # Clicked, then another tab came to the front before it asked.
        sv.cmd({"do": "tap", "id": a, "selector": "#play"})
        sv.page("other")
        s = ask(a)
        t.ok("a tab no longer in front isn't given the pointer", s["answered"] == "denied: not in front", s)
        s = lock()
        t.ok("a tab no longer in front, not held and no pill", not s["held"] and not s["hint"], s)
    finally:
        sv.finish()
    t.done()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
