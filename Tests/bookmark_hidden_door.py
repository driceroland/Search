#!/usr/bin/env python3
"""#1496: ⇧⌘B with the Bookmarks button taken out of the column's foot
(Settings › Buttons under the column) keeps the page and says so, as with
the column folded away, instead of opening a card with nothing to hang from.

Build first (`./build.sh`), then `python3 Tests/bookmark_hidden_door.py`. It
uses the split suite's harness: started hidden in a world of its own, no
window shown, everything removed afterwards.

The card hangs only from the button (BookmarkDoor): hidden, ⇧⌘B set the
dropdown open with no view to show it, so nothing appeared, and the card
came up later, out of nowhere, once the button was put back.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("bookmark-hidden-door")
t = sv.T()


def bookmark():
    sv.cmd({"do": "press", "code": 11, "chars": "B", "mods": ["cmd", "shift"]}); time.sleep(0.8)


try:
    for hidden in (False, True):
        sv.setup(sidebar=True, **{"foot.bookmarks.hidden": hidden})
        sv.launch()
        sv.page("one"); time.sleep(1.5)
        bookmark()
        p, s = sv.cmd({"do": "probe"}), sv.sp("state")
        where = "button hidden" if hidden else "button shown"
        t.ok(f"{where}: ⇧⌘B keeps the page", p.get("bookmarkCount") == 1, p.get("bookmarkCount"))
        if hidden:
            t.ok(f"{where}: no card left open with nothing to hang from", not p.get("bookmarksOpen"), p)
            t.ok(f"{where}: a word says it was kept", s.get("announced", "").startswith("Bookmarked"), s.get("announced"))
            bookmark()
            t.ok(f"{where}: again, it says it's kept already", sv.sp("state").get("announced") == "Already a bookmark")
        else:
            t.ok(f"{where}: the card hangs from the button", p.get("bookmarksOpen") and p.get("bookmarkCard"), p)
        sv.finish()
finally:
    t.done(); sv.finish()
sys.exit(1 if t.failed else 0)
