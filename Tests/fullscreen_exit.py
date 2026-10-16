#!/usr/bin/env python3
"""A page's full screen, in and out, moves the page once, in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/fullscreen_exit.py`.
Nothing goes full screen: the bench's `layouts` fakes the page's own word
that it is going, or back (Forms.swift), and records every frame the pages
on screen take after it, looked at every few milliseconds and after each
turn of the run loop. Leaving a YouTube video's full screen, the window
used to correct itself four or five times in a row (Drice, 16 Oct 2026):
the column, the card's gap and corners, the side panel, the bookmarks bar
and Split View's stage each came back on its own, the page resized at
each step, and the column's room was given back 0.42 s after the rest.
Checked here: the page takes one frame going in and one coming back, and
the last is where it was before, alone or as a pair, card or edge to edge,
the tabs down the side or across the top, the bookmarks bar up, an
extension's side panel open. WebKit's own part, the video's window
landing where the page is, is checked by hand on a release candidate.
"""
import json
import os
import shutil
import sys
import tempfile
import time
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("fullscreen-exit")
VERBOSE = "-v" in sys.argv
work = Path(tempfile.mkdtemp(prefix="search-fsexit-"))


def layouts(tab, on, seconds=1.2):
    return sv.cmd({"do": "layouts", "id": tab, "immerse": on, "seconds": seconds})["layouts"]


def moves(seen):
    """The frames the pages took after the change, the first entry being
    where they were."""
    return [s["pages"] for s in seen[1:]]


def panel_extension():
    folder = work / "panel"
    folder.mkdir(exist_ok=True)
    (folder / "manifest.json").write_text(json.dumps({
        "manifest_version": 3, "name": "Panel One", "version": "1.0",
        "permissions": ["sidePanel", "tabs"],
        "action": {"default_title": "Panel One"},
        "side_panel": {"default_path": "panel.html"},
    }))
    (folder / "panel.html").write_text("<!doctype html><title>The panel</title><p>Panel")
    (folder / "page.html").write_text("<!doctype html><title>own</title>")
    return str(folder)


def open_panel(a):
    sv.cmd({"do": "ext-folder", "path": panel_extension(), "yes": True})
    ext = None
    for _ in range(50):
        found = [x for x in sv.cmd({"do": "extensions"})["extensions"] if x["name"] == "Panel One" and x["loaded"]]
        if found: ext = found[0]; break
        time.sleep(0.2)
    if not ext: raise RuntimeError("the panel's extension didn't load")
    page = sv.cmd({"do": "ext-page", "id": ext["id"], "path": "page.html"})["id"]
    time.sleep(1.0)
    sv.cmd({"do": "eval", "id": page, "js": "chrome.sidePanel.setPanelBehavior({openPanelOnActionClick: true}); 1"})
    time.sleep(0.6)
    sv.sp("select", id=a); time.sleep(0.5)
    sv.cmd({"do": "ext-press", "id": ext["id"]}); time.sleep(1.5)
    return sv.cmd({"do": "sidepanel"})["shown"]


node = lambda **f: {"id": str(uuid.uuid4()).upper(), **f}


CASES = [
    # name, prefs, pair, card, bookmarks bar, side panel
    ("alone, card", dict(sidebar=True, splitView=False), False, True, False, False),
    ("alone, edge to edge", dict(sidebar=True, splitView=False), False, False, False, False),
    ("tabs across the top", dict(sidebar=False, splitView=False), False, True, False, False),
    ("Split View on, alone", dict(sidebar=True, splitView=True), False, True, False, False),
    ("a pair", dict(sidebar=True, splitView=True), True, True, False, False),
    ("a pair, edge to edge", dict(sidebar=True, splitView=True), True, False, False, False),
    ("bookmarks bar", dict(sidebar=True, splitView=False, **{"bookmarks.bar": True}), False, True, True, False),
    ("side panel", dict(sidebar=True, splitView=False), False, True, False, True),
    ("a pair, side panel", dict(sidebar=True, splitView=True), True, True, False, True),
]


def main():
    t = sv.T()
    only = [a for a in sys.argv[1:] if not a.startswith("-")]
    try:
        for name, prefs, pair, card, bar, side in CASES:
            if only and not any(o in name for o in only): continue
            sv.setup(**prefs)
            if bar:
                os.makedirs(sv.SUPPORT, exist_ok=True)
                json.dump([node(title="Alpha", url="https://alpha.example/"), node(title="Beta", url="https://beta.example/")],
                          open(f"{sv.SUPPORT}/bookmarks.json", "w"))
            sv.launch()
            a = sv.page("a")
            if pair:
                b = sv.page("b")
                sv.sp("pair", id=b, **{"with": a}, side="right"); time.sleep(0.8)
                sv.sp("focus", id=a); time.sleep(0.4)
            if not card:
                sv.cmd({"do": "ui", "cards": False}); time.sleep(0.8)
            if side:
                t.ok(f"{name}: the side panel is open", open_panel(a))
            time.sleep(0.8)

            going = layouts(a, True)
            back = layouts(a, False)
            before = going[0]["pages"]
            if VERBOSE:
                print(f"  {name}: going in"); [print("     ", s) for s in going]
                print(f"  {name}: coming back"); [print("     ", s) for s in back]
            t.ok(f"{name}: going in, the page moves once", len(moves(going)) == 1, going)
            mine = a[:8].lower()
            full = going[-1]["pages"].get(mine)
            t.ok(f"{name}: going in, the page has the window, alone", full is not None and list(going[-1]["pages"]) == [mine]
                 and full[0] == 0 and full[1] == 0 and full[2] >= before[mine][2] and full[3] >= before[mine][3]
                 and full[2:] != before[mine][2:], (before, going[-1]))
            t.ok(f"{name}: coming back, the page moves once", len(moves(back)) == 1, back)
            t.ok(f"{name}: coming back, it is where it was", back[-1]["pages"] == before, (before, back[-1]))
            sv.quit()
    finally:
        t.done(); sv.finish()
        shutil.rmtree(work, ignore_errors=True)
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
