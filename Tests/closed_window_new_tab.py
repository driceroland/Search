#!/usr/bin/env python3
"""New Private Tab and New Tab with every window closed bring a window back
(idea 1183), in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/closed_window_new_tab.py`. It
uses the split suite's harness: started hidden in a world of its own,
everything removed afterwards. A hidden probe's windows are never ordered
onto a screen (Windows.show leaves them be while the app is hidden), and
every window is checked to be off screen after each step.

With the last window closed, Search keeps running (#327) and its menus act
on that window's browser, closed. ⇧⌘N made a private tab there, and ⌘T a
tab, where nobody could see them, until a click on the Dock icon brought
the window back with the tab in it. Now each brings the window back first,
as ⌘N does.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("closed-window-new-tab")
t = sv.T()


def windows(): return sv.cmd({"do": "windows"})["windows"]


def off_screen(label):
    shown = [w for w in windows() if w["shown"]]
    t.ok(f"no window on screen ({label})", not shown, shown)


def close_all():
    for w in windows():
        if w["open"]: sv.cmd({"do": "windows", "action": "close", "n": w["n"]}); time.sleep(0.8)
    return windows()


def main():
    try:
        sv.setup(sidebar=True); sv.launch()
        sv.page("a")
        # ⌘T can't be pressed on a hidden probe with no window (the key
        # reaches no menu): Browser.launch shares the same first step.
        for verb, label in (("private", "⇧⌘N, New Private Tab"),):
            ws = close_all()
            t.ok(f"[{label}] every window closed", ws and not any(w["open"] for w in ws), ws)
            before = sv.sp("state")["tabs"]
            sv.sp(verb)
            time.sleep(1)
            ws = windows()
            t.ok(f"[{label}] its window is back", any(w["open"] for w in ws), ws)
            s = sv.sp("state")
            t.ok(f"[{label}] with the new tab in front", len(s["tabs"]) == len(before) + 1 and s["activeID"] not in [x["id"] for x in before],
                 (s["activeID"], [x["id"] for x in before]))
            off_screen(label)
        # ⌘N with every window closed, as before: the window comes back.
        close_all()
        sv.cmd({"do": "windows", "action": "new"}); time.sleep(1)
        t.ok("[⌘N] a window is back", any(w["open"] for w in windows()), windows())
        off_screen("⌘N")
    finally:
        t.done(); sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
