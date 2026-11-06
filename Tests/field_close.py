#!/usr/bin/env python3
"""⌘W with the address field raised over a page puts the field away, whichever
key raised it, and leaves the page where it was.

Build first (`./build.sh` or `./build.sh debug`), then
`python3 Tests/field_close.py`. It uses the split suite's harness: started
hidden in a world of its own, keys pressed through the app's own event queue.

Reported as: ⌘T, then ⌘W, put the floating field away; ⌘L or ⌘K, then ⌘W,
closed the page under the field, though the field looks the same.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("field-close")
KEYS = {"t": 17, "l": 37, "k": 40, "w": 13}


def press(key):
    sv.cmd({"do": "press", "code": KEYS[key], "chars": key, "mods": ["cmd"], "letgo": True})
    time.sleep(0.6)


def tabs():
    return [t["id"] for t in sv.cmd({"do": "tabs"})["tabs"]]


def field():
    return sv.cmd({"do": "suggest"})["editing"]


def main():
    t = sv.T()
    try:
        sv.setup(**{"newtab.floating": True})
        sv.launch()
        pages = [sv.page(name) for name in ("a", "b", "c")]
        for key, name in (("t", "⌘T"), ("l", "⌘L"), ("k", "⌘K")):
            sv.sp("select", id=pages[1])
            time.sleep(0.5)
            before = tabs()
            press(key)
            up = field()
            press("w")
            t.ok(f"{name} then ⌘W: the field goes and every tab stays",
                 up and not field() and tabs() == before, {"up": up, "field": field(), "before": before, "after": tabs()})

        # With nothing raised, ⌘W is still Close Tab.
        sv.sp("select", id=pages[2])
        time.sleep(0.5)
        press("w")
        t.ok("⌘W with no field up still closes the tab", pages[2] not in tabs(), tabs())
    finally:
        t.done()
        sv.finish()
    return 1 if t.failed else 0


if __name__ == "__main__":
    sys.exit(main())
