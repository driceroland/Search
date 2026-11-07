#!/usr/bin/env python3
"""A second window opened and closed leaves the first window's pins, in a
hidden probe.

Build first (`./build.sh`), then `python3 Tests/close_window_pins.py`. It
uses the split suite's harness: started hidden, in a world of its own,
everything removed afterwards.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("close-window-pins")


def windows():
    return sv.cmd({"do": "windows"})["windows"]


def main():
    t = sv.T()
    try:
        sv.setup(spaces=True); sv.launch()
        a = sv.page("a"); b = sv.page("b"); sv.page("c")
        sv.cmd({"do": "pin", "id": a}); sv.cmd({"do": "pin", "id": b}); time.sleep(0.8)
        t.ok("two pins to start", windows()[0]["pins"] and len(windows()[0]["pins"]) == 2, windows())

        sv.cmd({"do": "windows", "action": "new"}); time.sleep(1.5)
        t.ok("the new window has them too", len(windows()) == 2 and len(windows()[1]["pins"]) == 2, windows())
        sv.cmd({"do": "windows", "action": "close", "n": 2}); time.sleep(3)
        w = windows()
        t.ok("closed: one window left", len(w) == 1, w)
        t.ok("closed: the first window keeps its pins", len(w[0]["pins"]) == 2, w)

        # Closed straight after a page opened in it, its session not yet
        # written (Browser.rememberSession waits a moment).
        sv.cmd({"do": "windows", "action": "new"}); time.sleep(1.5)
        sv.sp("open", url=f"{sv.BASE}/d", window=2)
        sv.cmd({"do": "windows", "action": "close", "n": 2}); time.sleep(3)
        w = windows()
        t.ok("closed at once: the first window keeps its pins", len(w) == 1 and len(w[0]["pins"]) == 2, w)

        # The oldest closed instead: the newer one keeps them.
        sv.cmd({"do": "windows", "action": "new"}); time.sleep(1.5)
        sv.cmd({"do": "windows", "action": "close", "n": 1}); time.sleep(3)
        w = windows()
        t.ok("oldest closed: the other keeps its pins", len(w) == 1 and len(w[0]["pins"]) == 2, w)
    finally:
        t.done(); sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
