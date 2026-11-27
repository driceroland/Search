#!/usr/bin/env python3
"""⇧⌘N with every window closed opens on the private tab alone (idea 1415), in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/private_window_lone_blank.py`.
With the last window closed Search keeps running and ⇧⌘N brings that window
back with a private tab (idea 1183). A window that held only its empty
tab came back with two: the regular one first, the private one second. It
now opens on the private tab alone; a window with a page, a pin or words
typed in its new tab keeps them. Started hidden in a world of its own; no
window is made on a screen (checked after each step).
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("private-lone-blank")
t = sv.T()


def windows(): return sv.cmd({"do": "windows"})["windows"]


def close_all():
    for w in windows():
        if w["open"]: sv.cmd({"do": "windows", "action": "close", "n": w["n"]}); time.sleep(0.8)


def kinds():
    s = sv.sp("state")
    return [("S" if x["shy"] else "R") + ("b" if x["blank"] else "") for x in s["tabs"]], \
        next((x["shy"] for x in s["tabs"] if x["id"] == s["activeID"]), None)


def main():
    try:
        # A window with a page in it keeps the page and its empty tab.
        sv.setup(sidebar=True); sv.launch()
        sv.page("a"); time.sleep(0.6)
        close_all()
        sv.sp("private"); time.sleep(1.2)
        row, shy = kinds()
        t.ok("a window with a page keeps it, the private tab in front", row.count("R") >= 1 and "Rb" in row and shy, row)
        t.ok("no window on a screen", not [w for w in windows() if w["shown"]], windows())
        # A window holding only its empty tab.
        sv.quit(); sv.setup(sidebar=True); sv.launch()
        close_all()
        sv.sp("private"); time.sleep(1.2)
        row, shy = kinds()
        t.ok("the empty window opens on its private tab alone", row == ["Sb"] and shy, row)
        t.ok("and no window on a screen", not [w for w in windows() if w["shown"]], windows())
    finally:
        t.done(); sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
