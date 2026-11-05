#!/usr/bin/env python3
"""The row the arrow keys pick in the address field's list says what Return
will do with it: switch to an open tab, open a new tab (⌘T), or go there.

Build first (`./build.sh` or `./build.sh debug`), then
`python3 Tests/picked_row_hint.py`. It uses the split suite's harness: started
hidden in a world of its own, keys pressed through the app's own event queue.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("picked-row-hint")
KEYS = {"t": 17, "l": 37, "k": 40}


def press(key):
    sv.cmd({"do": "press", "code": KEYS[key], "chars": key, "mods": ["cmd"], "letgo": True})
    time.sleep(0.8)


def bare(code, chars):
    sv.cmd({"do": "press", "code": code, "chars": chars, "mods": []})
    time.sleep(0.6)


def hint():
    return sv.cmd({"do": "suggest"})["hint"]


def main():
    t = sv.T()
    try:
        sv.setup(**{"newtab.floating": True})
        sv.launch()
        sv.cmd({"do": "history", "take": f"{sv.BASE}/echo", "count": 5})
        a, b = sv.page("alpha"), sv.page("bravo")
        sv.sp("select", id=b); time.sleep(0.5)

        press("k")
        t.ok("⌘K: the chosen tab says ↩ Switch", hint() == "Switch", hint())
        bare(53, "\x1b")

        press("t")
        sv.cmd({"do": "field", "text": "127.0.0.1"}); time.sleep(0.5)
        t.ok("⌘T, typing: no row picked, no key cap", hint() == "", hint())
        bare(125, "")
        t.ok("⌘T, ↓: ↩ New tab", hint() == "New tab", hint())
        bare(53, "\x1b")

        press("l")
        sv.cmd({"do": "field", "text": "127.0.0.1"}); time.sleep(0.5)
        bare(125, "")
        t.ok("⌘L, ↓: ↩ Open", hint() == "Open", hint())
    finally:
        t.done()
        sv.finish()
    return 1 if t.failed else 0


if __name__ == "__main__":
    sys.exit(main())
