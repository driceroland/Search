"""Profiles can be put in any order, Personal no longer always first.

Build first (`./build.sh`), then `python3 Tests/profile_order.py`. In a
hidden probe with Spaces and Settings › Profiles in one window on, a second
profile, School, is made. The space's menu on Personal's only space offers
Move Right, which moves the whole profile past School: the menu, ⌃1–⌃9 and
the profiles list then start with School, kept in profiles.json across a
relaunch. Move Left brings Personal back first.

Nothing here makes, shows or brings forward a window.
"""
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("sp-profile-order")


def saved():
    return [p["name"] for p in json.load(open(f"{sv.SUPPORT}/profiles.json"))]


def main():
    t = sv.T()
    try:
        sv.setup(spaces=True, **{"profiles.oneWindow": True})
        sv.launch()
        sv.cmd({"do": "profile", "action": "new", "name": "School"})
        time.sleep(0.8)
        st = sv.cmd({"do": "space"})
        t.ok("Personal first, then School", st["every"] == ["Personal", "School"], st["every"])
        menu = [m["title"] for m in st["menu"]]
        t.ok("Personal's only space has Move Right, no Move Left", "Move Right" in menu and "Move Left" not in menu, menu)

        sv.cmd({"do": "space", "action": "menu", "title": "Move Right"})
        time.sleep(0.6)
        st = sv.cmd({"do": "space"})
        t.ok("Move Right moves the profile: School first", st["every"] == ["School", "Personal"], st["every"])
        heads = [m["title"] for m in st["menu"] if m["header"]]
        t.ok("one space each: no section headers", heads == [], heads)
        keyed = {m["title"]: m["key"] for m in st["menu"] if m["key"]}
        t.ok("⌃1 is School's space now", keyed.get("School") == "1" and keyed.get("Personal") == "2", keyed)
        t.ok("kept in profiles.json", saved() == ["School", "Personal"], saved())
        names = [p["name"] for p in sv.cmd({"do": "profile"})["profiles"]]
        t.ok("and in the profiles list", names == ["School", "Personal"], names)

        sv.quit()
        time.sleep(1)
        sv.launch()
        time.sleep(1)
        names = [p["name"] for p in sv.cmd({"do": "profile"})["profiles"]]
        t.ok("after a relaunch, School still first", names == ["School", "Personal"], names)

        st = sv.cmd({"do": "space"})
        if st["current"] != "Personal":
            sv.cmd({"do": "space", "action": "menu", "title": "Personal"})
            time.sleep(1.5)
        sv.cmd({"do": "space", "action": "menu", "title": "Move Left"})
        time.sleep(0.6)
        names = [p["name"] for p in sv.cmd({"do": "profile"})["profiles"]]
        t.ok("Move Left brings Personal back first", names == ["Personal", "School"], names)
    finally:
        t.done()
        sv.finish()
    sys.exit(1 if t.failed else 0)


main()
