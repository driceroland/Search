#!/usr/bin/env python3
"""View › Enter Full Screen is there, on ⌃⌘F (#1176).

Build first (`./build.sh`), then `python3 Tests/full_screen_key.py`. A
hidden probe in a world of its own (split_view.py's harness) reads the menu
bar as SwiftUI filled it (Bench "menus"): View replaces SwiftUI's toolbar
group, and the system's Enter Full Screen went with it, so ⌃⌘F did nothing.
What is checked: one item in the whole menu bar carries ⌃⌘F, in View, named
Enter Full Screen, and it can be chosen. Nothing is pressed: the window going
full screen is checked by hand.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("full-screen-key")

if __name__ == "__main__":
    t = sv.T()
    try:
        sv.setup()
        sv.launch()
        time.sleep(1)
        found = sv.cmd({"do": "menus"})
        items = found.get("fullScreenItems", [])
        t.ok("one item carries ⌃⌘F", len(items) == 1, items)
        item = items[0] if items else {}
        t.ok("in View", item.get("menu") == "View", item)
        t.ok("named Enter Full Screen", item.get("title") == "Enter Full Screen", item)
        t.ok("on ⌃⌘F", item.get("key") == "f" and item.get("control") and item.get("command"), item)
        t.ok("shown and on", not item.get("hidden") and item.get("enabled"), item)
        t.ok("listed in View", "Enter Full Screen" in found["menus"].get("View", []), found["menus"].get("View"))
    finally:
        sv.finish()
        t.done()
    sys.exit(1 if t.failed else 0)
