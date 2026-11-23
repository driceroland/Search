#!/usr/bin/env python3
"""Rename a tab left as it was, across the top, down the side and icons only (#1354).

Build first (`./build.sh`), then `python3 Tests/tab_rename_side.py`. The app
is started hidden in a world of its own, once per layout. In each, the tab in
front is opened on a page, Rename is begun as the tab's right-click menu
begins it, and a moment later the field must still be editing that tab, as a
rename. Then a name is typed and kept, and the tab wears it; and a rename let
go of without typing anything leaves the tab following its page, with no name
of its own (the edit ending at once used to save the page's title as one).
In the column, Rename is also chosen from the row's own right-click menu,
as the bench's `columnmenu` takes a right-click, and the field must still be
there a moment later. (`--visible` starts it without -g -j; a probe still keeps
its window off screen, so it changes little.)
"""
import os
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("tab-rename")

LAYOUTS = {
    "top": {"sidebar": False},
    "left": {"sidebar": True},
    "icons": {"sidebar": True, "sidebar.icons": True},
}


VISIBLE = "--visible" in sys.argv


def launch():
    """As split_view's, with the window on screen when asked for."""
    if not VISIBLE:
        return sv.launch()
    if os.path.exists(sv.SOCK):
        os.remove(sv.SOCK)
    before = sv.running()
    subprocess.run(["open", "-n", "--env", f"SEARCH_PROBE={sv.W}", sv.APP])
    for _ in range(150):
        if os.path.exists(sv.SOCK):
            break
        time.sleep(0.1)
    time.sleep(2)
    sv.started.update((sv.running() - before) & sv.holding())


def row_offering(title):
    """The height of the first point down the column whose right-click offers `title`."""
    for y in range(30, 400, 4):
        if title in sv.cmd({"do": "columnmenu", "x": 60, "y": y})["items"]:
            return y
    return None


def ui(**f):
    return sv.cmd({"do": "ui", **f})


def probe():
    return sv.cmd({"do": "probe"})


def check(t, layout):
    sv.setup(**LAYOUTS[layout])
    launch()
    sv.page("alpha")
    time.sleep(0.5)

    ui(renametab=True)
    time.sleep(1.0)
    st = probe()
    if layout == "icons":
        # No row to type in: the name is asked for in a sheet.
        t.ok(f"{layout}: Rename asks for the name in a sheet", st["sheet"] and st["sheetReturn"] == "Rename",
             f"sheet={st['sheet']} return={st['sheetReturn']!r}")
        return
    t.ok(f"{layout}: Rename keeps the field editing", st["tabEditing"] != "" and st["tabRenaming"],
         f"editing={st['tabEditing']!r} renaming={st['tabRenaming']}")
    t.ok(f"{layout}: nothing named before anything is typed", all(n == "" for n in st["tabNames"]), st["tabNames"])

    # Let go of without typing: no name of its own.
    ui(finishedit=True)
    time.sleep(0.5)
    st = probe()
    t.ok(f"{layout}: a rename left as it was gives no name", all(n == "" for n in st["tabNames"]), st["tabNames"])

    if layout != "left":
        return
    # The row's own right-click menu, Rename chosen there.
    y = row_offering("Rename")
    t.ok(f"{layout}: a row's right-click offers Rename", y is not None)
    if y is None:
        return
    sv.cmd({"do": "columnmenu", "x": 60, "y": y, "pick": "Rename"})
    time.sleep(1.0)
    st = probe()
    t.ok(f"{layout}: Rename from the right-click keeps the field editing", st["tabEditing"] != "" and st["tabRenaming"],
         f"editing={st['tabEditing']!r} renaming={st['tabRenaming']}")
    ui(finishedit=True)
    time.sleep(0.5)
    st = probe()
    t.ok(f"{layout}: and left as it was, still no name", all(n == "" for n in st["tabNames"]), st["tabNames"])


def main():
    t = sv.T()
    try:
        for layout in LAYOUTS:
            check(t, layout)
            sv.quit()
    finally:
        sv.finish()
    t.done()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
