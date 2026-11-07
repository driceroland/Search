#!/usr/bin/env python3
"""The Bookmarks menu's first item follows the page on screen being kept.

Build first (`./build.sh`), then `python3 Tests/bookmark_menu_title.py`. A
hidden probe opens one page, then Bench "keeppage" keeps it and lets it go
on the bookmarks alone, as the Bookmarks panel does, with nothing else of
the browser changing. The menu's first item reads "Add This Page" for a page
not kept and "Edit Bookmark…" for one that is, each time, as it would open.
The bookmarks bar is on and the world starts with no bookmarks, so the bar
comes up only when the window hears that the first one was kept.
"""
import json
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("bookmark-menu-title")
ADD, EDIT = "Add This Page", "Edit Bookmark…"


def keep(on): return sv.cmd({"do": "keeppage", "keep": on})


if __name__ == "__main__":
    t = sv.T()
    try:
        sv.setup(**{"bookmarks.bar": True})
        os.makedirs(sv.SUPPORT, exist_ok=True)
        json.dump({"tabs": [{"url": f"{sv.BASE}/kept", "title": "Kept"}], "active": 0},
                  open(f"{sv.SUPPORT}/session.json", "w"))
        json.dump([], open(f"{sv.SUPPORT}/bookmarks.json", "w"))
        sv.launch()
        time.sleep(1.5)
        first = sv.cmd({"do": "menus"})["menus"].get("Bookmarks", [])
        t.ok(f"before: {ADD}", first[:1] == [ADD], first[:2])
        for round in (1, 2):
            kept = keep(True)
            t.ok(f"kept ({round}): {EDIT}", kept["kept"] and kept["items"][:1] == [EDIT], kept)
            t.ok(f"kept ({round}): the bookmarks bar comes up ({kept['bar']})", kept["bar"] >= 1, kept)
            gone = keep(False)
            t.ok(f"let go ({round}): {ADD}", not gone["kept"] and gone["items"][:1] == [ADD], gone)
    finally:
        sv.finish()
        t.done()
    sys.exit(1 if t.failed else 0)
