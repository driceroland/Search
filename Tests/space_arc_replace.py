"""Spaces brought over from Arc take the place of an untouched first space.

Build first (`./build.sh`), then `python3 Tests/space_arc_replace.py`. The
made-up Arc profile of spaces_quit_keep.py (two spaces, Work and Study, a
synthetic StorableSidebar.json, never anyone's real Arc data) is imported
into a hidden probe twice:

- into a fresh world, whose first space "Personal" holds nothing but an
  empty tab: it is replaced, the list is Work and Study, Work on screen and
  the profile's home, through a relaunch;
- into a world whose first space has a page open: it stays, beside them.

Nothing here makes, shows or brings forward a window.
"""
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402
import spaces_quit_keep as keep  # noqa: E402

sv.use("sp-arc-replace")


def names():
    return [s["name"] for s in json.load(open(f"{sv.SUPPORT}/spaces.json"))]


def main():
    t = sv.T()
    try:
        sv.setup(**{"tabs.groups": True, "start.fresh": False})
        keep.arc()
        sv.launch()
        out = sv.cmd({"do": "import", "from": "Arc", "what": ["spaces"]}).get("arc") or {}
        t.ok("Arc's two spaces came in", out.get("spaces") == 2, out)
        time.sleep(1.5)
        st = sv.cmd({"do": "space"})
        t.ok("the untouched Personal is replaced: Work and Study", names() == ["Work", "Study"], names())
        t.ok("Work is on screen and the home", st["current"] == "Work" and st["home"] == keep.ids()["Work"],
             (st["current"], st["home"]))
        groups, _ = keep.kept("Study")
        t.ok("Study kept its folder", groups == {keep.FOLDERS["Study"]: keep.PAGES["Study"]}, groups)
        sv.quit()
        time.sleep(1)
        sv.launch()
        time.sleep(1)
        st = sv.cmd({"do": "space"})
        t.ok("after a relaunch, still Work and Study", [s["name"] for s in st["spaces"]] == ["Work", "Study"], st["spaces"])
        sv.quit()

        # A first space with something in it stays.
        sv.setup(**{"tabs.groups": True, "start.fresh": False})
        keep.arc()
        sv.launch()
        sv.page("kept-here")
        sv.cmd({"do": "import", "from": "Arc", "what": ["spaces"]})
        time.sleep(1.5)
        t.ok("a Personal with a page open stays beside them", names() == ["Personal", "Work", "Study"], names())
        titles = [x["title"] for x in sv.cmd({"do": "tabs"})["tabs"]]
        t.ok("and keeps its page", "kept-here" in titles, titles)
    finally:
        t.done()
        sv.finish()
    sys.exit(1 if t.failed else 0)


main()
