#!/usr/bin/env python3
"""The panel bar at the window's right edge (PanelBar.swift), in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/panel_bar.py`. It runs in a
world of its own with split_view.py's harness: started hidden, everything
removed afterwards. Keys are pressed through the app's own event queue
(bench `press`), as close_panel.py presses them; nothing is shown on any
screen and the pointer is never moved.

Off (the default): no bar, the page reaches the window's far gap, ⌘Y opens
the History page and ⇧⌘J Downloads as before, and the bar's commands do
nothing. On: the bar takes its width from the page; ⌘Y, ⇧⌘J, Bookmarks and
the site panel each open the side panel on themselves and close it again;
put away, a panel's key brings the bar out and closing that panel puts it
away again, unless Hide the panel bar again is off.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("panel-bar")
GAP = 8
BAR = 40


def panel(action="state", **f): return sv.cmd({"do": "sidepanel", "action": action, **f})


def run(id, **f):
    panel("command", id=id, **f); time.sleep(0.5)
    return panel()


def press(code, chars, *mods):
    sv.cmd({"do": "press", "code": code, "chars": chars, "mods": ["cmd", *mods]}); time.sleep(0.6)
    return panel()


def cmd_y(): return press(16, "y")


def cmd_shift_j(): return press(38, "j", "shift")


def kind(st): return st["content"]["kind"] if st["shown"] else "none"


def page_right(st):
    """The page's far edge, in points from the window's left."""
    rights = [f[0] + f[2] for f in st["pages"] if len(f) == 4 and f[2] > 0]
    return max(rights) if rights else None


def main():
    t = sv.T()
    try:
        # Off, the default: exactly as before.
        sv.setup(sidebar=True); sv.launch()
        sv.page("a")
        st = panel()
        w = st["windowWidth"]
        t.ok("off by default", st["bar"]["on"] is False, st["bar"])
        t.ok("off: the page reaches the card's far gap", page_right(st) == w - GAP, (page_right(st), w))
        st = cmd_y()
        t.ok("off: ⌘Y opens the History page, not the panel", st["bar"]["historyPage"] is True and not st["shown"], st)
        sv.cmd({"do": "ui", "history": False}); time.sleep(0.4)
        st = cmd_shift_j()
        t.ok("off: ⇧⌘J doesn't open the side panel", not st["shown"], st)
        sv.cmd({"do": "ui", "downloads": False}); time.sleep(0.4)
        st = run("view.bookmarksPanel")
        t.ok("off: Bookmarks in Side Panel does nothing", not st["shown"], st)
        st = run("view.panelBar")
        t.ok("off: Show Panel Bar does nothing", st["bar"]["hidden"] is False and page_right(st) == w - GAP, st["bar"])
        sv.quit()

        sv.setup(sidebar=False); sv.launch()
        sv.page("a")
        st = panel()
        t.ok("off, tabs across the top: the page is the window's full width",
             page_right(st) == st["windowWidth"], (page_right(st), st["windowWidth"]))
        sv.quit()

        # On.
        sv.setup(sidebar=True, **{"panel.bar": True}); sv.launch()
        sv.page("a")
        st = panel()
        w = st["windowWidth"]
        t.ok("on: the bar takes its width from the page", page_right(st) == w - GAP - BAR, (page_right(st), w))
        for name, open_it, want in [("⌘Y", cmd_y, "history"), ("⇧⌘J", cmd_shift_j, "downloads"),
                                    ("Bookmarks", lambda: run("view.bookmarksPanel"), "bookmarks"),
                                    ("the site panel", lambda: run("view.sitePanel"), "site")]:
            st = open_it()
            t.ok(f"on: {name} opens {want} in the side panel", kind(st) == want and not st["bar"]["historyPage"], st)
            if want == "site":
                f = st["frame"]
                t.ok("the panel sits beside the bar", len(f) == 4 and f[0] + f[2] == w - GAP - BAR, (f, w))
            st = open_it()
            t.ok(f"on: {name} again closes it", not st["shown"], st)
        st = cmd_y(); st = run("view.bookmarksPanel")
        t.ok("another panel's key replaces the one open", kind(st) == "bookmarks", st)
        st = run("view.bookmarksPanel")

        # Put away, and the restore memory.
        st = run("view.panelBar")
        t.ok("Show Panel Bar puts the bar away: the page has its room back",
             st["bar"]["hidden"] is True and page_right(st) == w - GAP, (st["bar"], page_right(st)))
        st = cmd_y()
        t.ok("put away: ⌘Y brings the bar out with History",
             kind(st) == "history" and st["bar"]["hidden"] is False and st["bar"]["borrowed"] is True, st)
        st = cmd_y()
        t.ok("closing that panel puts the bar away again", not st["shown"] and st["bar"]["hidden"] is True, st["bar"])
        st = cmd_shift_j()
        panel("close"); time.sleep(0.4); st = panel()
        t.ok("closed by its cross too, the bar goes away again", not st["shown"] and st["bar"]["hidden"] is True, st["bar"])
        panel("command", restores=False)
        st = cmd_y(); st = cmd_y()
        t.ok("Hide the panel bar again off: the bar stays out", not st["shown"] and st["bar"]["hidden"] is False, st["bar"])
        st = run("view.bookmarksPanel"); st = run("view.panelBar")
        t.ok("putting the bar away closes its panel", not st["shown"] and st["bar"]["hidden"] is True, st)
        st = run("view.panelBar")
        t.ok("and Show Panel Bar brings it back", st["bar"]["hidden"] is False and page_right(st) == w - GAP - BAR, st["bar"])

        # Turned off in Settings: as before at once.
        panel("command", bar=False); time.sleep(0.5)
        st = panel()
        t.ok("switched off: the page has its room back", page_right(st) == w - GAP, page_right(st))
        st = cmd_y()
        t.ok("switched off: ⌘Y opens the History page again", st["bar"]["historyPage"] is True and not st["shown"], st)
        sv.quit()

        # Tabs across the top, on: the bar at the edge, no card gap.
        sv.setup(sidebar=False, **{"panel.bar": True}); sv.launch()
        sv.page("a")
        st = panel()
        t.ok("tabs across the top: the bar takes its width", page_right(st) == st["windowWidth"] - BAR,
             (page_right(st), st["windowWidth"]))
        sv.quit()
    finally:
        t.done(); sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
