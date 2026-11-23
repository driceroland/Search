#!/usr/bin/env python3
"""Window managers can move and size the window from its title bar (idea 744).

Build first (`./build.sh debug`), then `python3 Tests/window_managers.py`.
It uses the split suite's harness in a world of its own
(window-managers-<checkout>): started hidden, no window shown or brought
forward, everything removed afterwards.

Swish, Rectangle, Magnet and macOS's own Move & Resize ask for a movable
window. The window was made unmovable whenever the pointer was over any of
the strips that stand in for the title bar — the whole row of tabs and the
whole column — so that a tab picked up in the row wouldn't carry the window
off (#668). A gesture made on the title bar, where Swish's are made, found a
window that said it couldn't be moved: Swish played its snap and nothing
moved. Now it is unmovable only with the pointer over something in the title
bar a press would pick up — a tab, a button — and movable everywhere else.

A hidden probe has no pointer, so the bench puts it there (`hit … hover`):
each strip under the point is handed the point as the pointer's, the
window's movability read, and the pointer taken away again.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("window-managers")


def at(x, y):
    a = sv.cmd({"do": "hit", "x": x, "y": y})
    return a["view"], a["movableHovered"], a["titleBar"]


def row(y, width):
    return [(x, *at(x, y)) for x in range(4, width - 4, 12)]


def main():
    t = sv.T()
    try:
        # The column of tabs.
        sv.setup(sidebar=True); sv.launch()
        sv.page("a"); sv.page("b"); time.sleep(0.8)
        probe = sv.cmd({"do": "probe"})
        lights = probe.get("lights") or []
        y = lights[0][1] if lights else 20
        v, movable, _ = at(600, y)
        t.ok("column: the band along the top over the page is movable", movable, v)
        v, movable, _ = at(200, y)
        t.ok("column: the column's own band beside the lights is movable", movable, v)
        v, movable, bar = at(60, 140)
        t.ok("column: over the column's rows, under the title bar, the window is movable (was not)",
             movable and not bar, (v, movable, bar))
        v, movable, _ = at(60, 600)
        t.ok("column: over the column's empty foot the window is movable", movable, v)
    finally:
        t.done(); sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
