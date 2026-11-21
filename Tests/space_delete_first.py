"""Any space can be deleted, the first included, as long as the profile
keeps one (#1326).

Build first (`./build.sh`), then `python3 Tests/space_delete_first.py`. In a
hidden probe with spaces on, two spaces are made beside the first: Work,
signed in with it, and Solo, with cookies of its own. The first space is
deleted from its own screen: Work, next in the order, becomes the home and
is on screen, the first space's session is emptied and Personal's home is
kept in profiles.json across a relaunch. Then Work is deleted: Solo becomes
the home and keeps its own store. The last space has no Delete, and the
bench's delete leaves it.

Nothing here makes, shows or brings forward a window.
"""
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("sp-delete-first")
FIRST = "00000000-0000-0000-0000-000000000001"


def names():
    return [s["name"] for s in json.load(open(f"{sv.SUPPORT}/spaces.json"))]


def personal_home():
    try:
        saved = json.load(open(f"{sv.SUPPORT}/profiles.json"))
    except FileNotFoundError:
        return FIRST
    return next((p["home"] for p in saved if p["id"].endswith("A1")), FIRST)


def main():
    t = sv.T()
    try:
        sv.setup(**{"spaces": True, "start.fresh": False})
        sv.launch()
        sv.page("first-page")
        sv.cmd({"do": "space", "action": "new", "name": "Work"})
        sv.cmd({"do": "space", "action": "new", "name": "Solo", "fresh": True})
        time.sleep(0.5)
        st = sv.cmd({"do": "space", "action": "go", "index": 1})
        time.sleep(1)
        st = sv.cmd({"do": "space"})
        ids = {s["name"]: s["id"] for s in st["spaces"]}
        t.ok("three spaces, the first on screen", [s["name"] for s in st["spaces"]] == ["Personal", "Work", "Solo"]
             and st["current"] == "Personal", st["spaces"])
        menu = [m["title"] for m in st["menu"]]
        t.ok("the first space's menu has Delete", "Delete “Personal”…" in menu, menu)

        sv.cmd({"do": "space", "action": "delete"})
        time.sleep(1)
        st = sv.cmd({"do": "space"})
        t.ok("the first space deleted: Work, next in the order, is on screen", st["current"] == "Work", st["current"])
        t.ok("and is the home now", st["home"] == ids["Work"] and personal_home() == ids["Work"],
             (st["home"], personal_home()))
        t.ok("the list is Work and Solo", names() == ["Work", "Solo"], names())
        session = json.load(open(f"{sv.SUPPORT}/session.json"))
        t.ok("the first space's session is emptied", session["tabs"] == [], session)
        titles = [x["title"] for x in sv.cmd({"do": "tabs"})["tabs"]]
        t.ok("its page didn't move into Work", "first-page" not in titles, titles)
        own = {s["name"]: s["own"] for s in st["spaces"]}
        t.ok("Work still shares the sign-ins, Solo keeps its own", own == {"Work": False, "Solo": True}, own)

        sv.quit()
        time.sleep(1)
        sv.launch()
        time.sleep(1)
        st = sv.cmd({"do": "space"})
        t.ok("after a relaunch the first space stays deleted", [s["name"] for s in st["spaces"]] == ["Work", "Solo"]
             and names() == ["Work", "Solo"], (st["spaces"], names()))
        t.ok("and Work is still the home", st["home"] == ids["Work"], st["home"])

        # The home again: Solo, with cookies of its own, takes its place.
        sv.cmd({"do": "space", "action": "go", "index": 1})
        time.sleep(1)
        sv.cmd({"do": "space", "action": "delete"})
        time.sleep(1)
        st = sv.cmd({"do": "space"})
        t.ok("Work deleted: Solo is the home and on screen", st["current"] == "Solo" and st["home"] == ids["Solo"],
             (st["current"], st["home"]))
        t.ok("Solo keeps its own store as the home", st["spaces"][0]["own"], st["spaces"])
        t.ok("its store was not put up for erasing", ids["Solo"] not in json.dumps(
            sv.cmd({"do": "profile"}).get("erasing", [])), sv.cmd({"do": "profile"}).get("erasing"))

        menu = [m["title"] for m in st["menu"]]
        t.ok("the last space has no Delete", not any(m.startswith("Delete") for m in menu), menu)
        sv.cmd({"do": "space", "action": "delete"})
        time.sleep(0.5)
        t.ok("and stays", names() == ["Solo"], names())
    finally:
        t.done()
        sv.finish()
    sys.exit(1 if t.failed else 0)


main()
