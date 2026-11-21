#!/usr/bin/env python3
"""A bookmarks folder of 5,000 open in the bookmark button's list (idea
879, #1306), in a hidden probe.

Build first (`./build.sh debug`), then `python3 Tests/bookmarks_large.py`.
A folder of 5,000 bookmarks is taken in from a file, as an import leaves
one ("Imported"), alone at the top so it opens with the list. The list is
made and laid out in the controller a popover is given, off every screen
(bench `dropdown popover`): how long that took, and how many of its rows
were built. Every row was built at once, and the window stalled; now only
the rows in sight are, and the rest as the list scrolls to them. Then the
folder is closed and opened again, and the list still follows it.
"""
import os
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("bookmarks-large")
COUNT = 5000


def take():
    lines = ["<!DOCTYPE NETSCAPE-Bookmark-file-1>", "<TITLE>Bookmarks</TITLE>", "<H1>Bookmarks</H1>", "<DL><p>",
             "    <DT><H3>Imported</H3>", "    <DL><p>"]
    lines += [f'        <DT><A HREF="https://bookmarks-large.test/{i}">Page {i}</A>' for i in range(COUNT)]
    lines += ["    </DL><p>", "</DL><p>"]
    with tempfile.NamedTemporaryFile("w", suffix=".html", delete=False) as f:
        f.write("\n".join(lines))
    try:
        return sv.cmd({"do": "import-file", "path": f.name})
    finally:
        os.remove(f.name)


def main():
    t = sv.T()
    try:
        sv.setup(sidebar=True); sv.launch()
        took = take()
        t.ok(f"a folder of {COUNT} came in", took.get("total") == COUNT, took)
        made = sv.cmd({"do": "dropdown", "popover": "open"})
        print(f"    made and laid out in {made['madeMs']:.0f} ms, {made['rowsBuilt']} rows built")
        t.ok("only the rows in sight are built", 0 < made["rowsBuilt"] < 100, made)
        t.ok("the list is made in well under a second", made["madeMs"] < 400, made)
        t.ok("the list is its full height", made["popover"] > 360, made)
        shut = sv.cmd({"do": "dropdown", "popover": "Imported"})
        t.ok("the folder closed: the list is one row", shut["popover"] < made["popover"] - 300, (made, shut))
        again = sv.cmd({"do": "dropdown", "popover": "Imported"})
        t.ok("opened again: the list is full again", again["popover"] == made["popover"], (made, again))
        sv.cmd({"do": "dropdown", "popover": "close"})
    finally:
        sv.finish()
    t.done()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
