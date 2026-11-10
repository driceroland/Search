#!/usr/bin/env python3
"""⌘S makes the column icons only instead of hiding it (idea 620, #1008).

Build first (`./build.sh`), then `python3 Tests/fold_to_icons.py`. It uses the
split suite's harness: started hidden in a world of its own, no window shown
or brought forward, everything removed afterwards.

With Settings › Appearance › Tabs, ⌘S makes the column icons only, turned on,
⌘S takes the column to the Icons only layout and back to its titles: the tabs
stay in sight, the column is never folded away, it stays on its side and gets
the width it had back. The layout is what changes, so it is kept when Search
is opened again. Off, as it is unless turned on, ⌘S folds the column
away as before. It is ⌘S as before too with the tabs across the top, and with
the column hidden until the pointer reaches the edge, where ⌘S is what brings
it out to stay.
"""
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("fold-to-icons")

t = sv.T()


def icons():
    return sv.cmd({"do": "icons"})


def folded():
    return sv.cmd({"do": "probe"})["folded"]


def cmd_s():
    """⌘S as the bench presses it: `foldtime` calls what the key and the View
    menu call (Browser.toggleFold) and waits for the slide."""
    sv.cmd({"do": "foldtime"}); time.sleep(0.4)
    return icons()


def start(position=None, **prefs):
    sv.setup(**prefs)
    if position:
        subprocess.run(["defaults", "write", sv.SUITE, "sidebar.position", position])
    sv.launch()
    return [sv.page(n) for n in ("a", "b", "c")]


try:
    # Off: ⌘S folds the column away, and the layout is left alone.
    start(sidebar=True)
    r = icons()
    t.ok("off: titles in the column to begin with", r["on"] is False and r["layout"] == "left" and not folded(), r["layout"])
    r = cmd_s()
    t.ok("off: ⌘S folds the column away", folded() is True, folded())
    t.ok("off: and it is not icons only", r["on"] is False and r["layout"] == "left", r["layout"])
    sv.quit()

    # On: to icons only and back, never folded.
    tabs = start(sidebar=True, **{"sidebar.foldIcons": True})
    r = icons()
    wide = r["columnWidth"]
    t.ok("on: titles in the column to begin with", r["on"] is False and r["layout"] == "left" and wide >= 176, r)
    r = cmd_s()
    t.ok("on: ⌘S makes the column icons only", r["on"] is True and r["layout"] == "icons", r["layout"])
    t.ok("on: a narrow column, 52 pt", r["columnWidth"] == 52, r["columnWidth"])
    t.ok("on: and it is not folded away", folded() is False, folded())
    drawn = {x["id"] for x in r["tiles"]}
    t.ok("on: every tab still in sight, as a tile", all(x in drawn for x in tabs), (tabs, sorted(drawn)))
    r = cmd_s()
    t.ok("on: ⌘S again brings the titles back", r["on"] is False and r["layout"] == "left", r["layout"])
    t.ok("on: at the width the column had", r["columnWidth"] == wide, (r["columnWidth"], wide))
    t.ok("on: still not folded", folded() is False, folded())

    # Hidden until the pointer reaches the edge: ⌘S is the fold's again.
    sv.cmd({"do": "ui", "hides": True}); time.sleep(0.8)
    t.ok("hidden at the edge: the column rests folded", folded() is True, folded())
    r = cmd_s()
    t.ok("hidden at the edge: ⌘S brings it out to stay", folded() is False and r["on"] is False, (folded(), r["on"]))
    r = cmd_s()
    t.ok("hidden at the edge: and puts it away again", folded() is True and r["on"] is False, (folded(), r["on"]))
    sv.quit()

    # The column on the right stays on the right.
    start(position="right", sidebar=True, **{"sidebar.foldIcons": True})
    r = icons()
    t.ok("right: the column on the right to begin with", r["layout"] == "right", r["layout"])
    r = cmd_s()
    t.ok("right: ⌘S makes it icons only", r["on"] is True and r["layout"] == "icons" and not folded(), r["layout"])
    # It is the layout itself that ⌘S changed, so it is kept: Search opened
    # again has the column as it was left.
    sv.quit(); sv.launch()
    r = icons()
    t.ok("right: opened again, still icons only", r["on"] is True and r["layout"] == "icons", r["layout"])
    r = cmd_s()
    t.ok("right: and back, on the right still", r["on"] is False and r["layout"] == "right", r["layout"])
    sv.quit()

    # Across the top there is no column: the strip folds as before.
    start(sidebar=False, **{"sidebar.foldIcons": True})
    r = cmd_s()
    t.ok("top: ⌘S folds the strip away", folded() is True, folded())
    t.ok("top: and the layout is the same", r["on"] is False and r["layout"] == "top", r["layout"])
finally:
    sv.finish()
t.done()
sys.exit(1 if t.failed else 0)
