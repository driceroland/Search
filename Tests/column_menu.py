#!/usr/bin/env python3
"""A right-click anywhere in the column (ColumnMenu.swift), in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/column_menu.py [SHOTS_DIR]`.
It uses the split suite's harness in a world of its own: started hidden,
no window shown or brought forward, no menu put on screen, everything
removed afterwards. The bench's `columnmenu` asks the window what a
right-click at a point lands on and the menu it would bring up, so every
point down the column is looked at: the band at the top, the rows, the
gaps between groups, the New tab row, the empty space under it and the
foot. Each must have a menu — a row its own, the rest the column's. Paste
and Go reads a pasteboard of the bench's own, never the Mac's clipboard.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("column-menu")
t = sv.T()
COLUMN = ["New Tab", "Hide Sidebar", "Sidebar Settings…"]


def menu(x, y, **f): return sv.cmd({"do": "columnmenu", "x": x, "y": y, **f})


try:
    sv.setup(sidebar=True); sv.launch()
    a = sv.page("one"); b = sv.page("two"); c = sv.page("three"); d = sv.page("four")
    sv.cmd({"do": "group", "id": a, "new": True, "name": "First"})
    sv.cmd({"do": "group", "id": b, "new": True, "name": "Second"})
    time.sleep(0.8)
    pane = sv.sp("state")["paneFrames"][0]
    bottom = pane["y"] + pane["height"]
    x = 60

    # Every point down the column, two points apart.
    bare, rows, column = [], 0, 0
    for y in range(8, bottom - 4, 2):
        m = menu(x, y)
        if m["items"] == COLUMN: column += 1
        elif m["items"]: rows += 1
        else: bare.append((y, m["hit"]))
    t.ok("every point down the column has a menu", not bare, bare)
    t.ok("…the rows their own, the rest the column's", rows > 10 and column > 50, (rows, column))

    top = menu(x, 20)
    t.ok("the band at the top: the column's menu", top["items"] == COLUMN, top)
    under = menu(x, bottom - 120)
    t.ok("the empty space under the tabs: the column's menu", under["items"] == COLUMN, under)
    foot = menu(200, bottom - 14)
    t.ok("the foot, beside its buttons: the column's menu", foot["items"] == COLUMN, foot)

    # A row keeps its own menu.
    rowmenus = [menu(x, y)["items"] for y in range(40, 200, 4)]
    t.ok("a row keeps its own menu", any("Move to Group" in m for m in rowmenus), rowmenus[:3])

    # What its items do.
    m = menu(x, bottom - 120, pick="New Tab")
    # As ⌘T: a new tab in front, or the empty one already there, or its field.
    t.ok("New Tab: an empty tab in front, or ⌘T's field", m["activeBlank"] or m["launching"], m)
    m = menu(x, bottom - 120, paste="https://example.org/pasted")
    t.ok("an address on the clipboard: Paste and Go", "Paste and Go" in m["items"], m["items"])
    m = menu(x, bottom - 120, paste="some words to search")
    t.ok("words on the clipboard: no Paste and Go", "Paste and Go" not in m["items"], m["items"])
    m = menu(x, bottom - 120, paste="example.org")
    t.ok("a bare name with a dot: Paste and Go", "Paste and Go" in m["items"], m["items"])
    m = menu(x, bottom - 120, paste=f"{sv.BASE}/pasted", pick="Paste and Go")
    t.ok("Paste and Go opens it in a new tab", m["tabsAfter"] == m["tabsBefore"] + 1
         and f"{sv.BASE}/pasted" in m["urls"], m)
    m = menu(x, bottom - 120, pick="Sidebar Settings…")
    t.ok("Sidebar Settings…: Settings › Tabs", m["tuning"] and m["settingsPage"] == "tabs", m)

    # With folders in pinned rows: New Folder and New Live Folder….
    sv.cmd({"do": "pinfolder", "action": "on"})
    time.sleep(0.5)
    m = menu(x, bottom - 120)
    t.ok("with pin folders: New Folder, New Live Folder…",
         "New Folder" in m["items"] and "New Live Folder…" in m["items"], m["items"])
    m = menu(x, bottom - 120, pick="New Folder")
    t.ok("New Folder makes one", "New Folder" in m["folders"], m["folders"])

    if len(sys.argv) > 1:
        sv.cmd({"do": "column", "path": f"{sys.argv[1]}/column.png", "height": bottom})
finally:
    t.done(); sv.finish()
sys.exit(1 if t.failed else 0)
