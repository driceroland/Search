#!/usr/bin/env python3
"""The address field says where Return goes: its placeholder and its name for
VoiceOver follow the key that raised it.

Build first (`./build.sh` or `./build.sh debug`), then
`python3 Tests/field_modes.py`. It uses the split suite's harness: started
hidden in a world of its own, keys pressed through the app's own event queue.

Reported as: ⌘T, ⌘K and a blank tab all showed "Enter a web address", though
Return opens a new tab after ⌘T, a page already open after ⌘K and this tab
after ⌘L. ⌘K only ever finds open tabs.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("field-modes")
KEYS = {"t": 17, "l": 37, "k": 40}


def press(key):
    sv.cmd({"do": "press", "code": KEYS[key], "chars": key, "mods": ["cmd"], "letgo": True})
    time.sleep(0.8)


def bare(code, chars):
    sv.cmd({"do": "press", "code": code, "chars": chars, "mods": []})
    time.sleep(0.8)


def look():
    p = sv.cmd({"do": "probe"})
    return {"placeholder": p["placeholder"], "name": p["fieldName"]}


def main():
    t = sv.T()
    try:
        sv.setup(**{"newtab.floating": True})
        sv.launch()
        blank = next(x["id"] for x in sv.cmd({"do": "tabs"})["tabs"] if not x.get("url"))
        sv.sp("select", id=blank); time.sleep(0.6)
        s = look()
        t.ok("a blank tab: Enter a web address", s["placeholder"] == "Enter a web address" and s["name"] == "Address", s)

        b = sv.page("bravo")
        sv.sp("select", id=b); time.sleep(0.5)
        press("t")
        s = look()
        t.ok("⌘T: New tab", s["placeholder"] == "New tab: enter a web address" and s["name"] == "Address, new tab", s)
        bare(53, "\x1b")

        press("l")
        bare(51, "\x7f")
        s = look()
        t.ok("⌘L, emptied: This tab", s["placeholder"] == "This tab: enter a web address" and s["name"] == "Address, this tab", s)
        bare(53, "\x1b")

        press("k")
        s = look()
        t.ok("⌘K: Switch to an open tab", s["placeholder"] == "Switch to an open tab", s)
        press("t")
        s = look()
        t.ok("⌘K, then ⌘T: New tab again", s["placeholder"] == "New tab: enter a web address", s)
    finally:
        t.done()
        sv.finish()
    return 1 if t.failed else 0


if __name__ == "__main__":
    sys.exit(main())
