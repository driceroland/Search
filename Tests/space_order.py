#!/usr/bin/env python3
"""A space, including the profile's home, keeps the place it was moved to.

Build first (`./build.sh`), then `python3 Tests/space_order.py`. A probe
with spaces on moves the first space right, then checks that its order
survives another window and a relaunch. It also adds a space after the home
has moved, which must go at the right-hand end, and checks where a spaces-off
window opens.

The probe starts hidden. Its second-window check goes through the bench's
window command; a probe already on screen can therefore bring that window
forward, as every test that opens one can.
"""
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("space-order")


def space(**request):
    return sv.cmd({"do": "space", **request})


def names():
    return [item["name"] for item in space()["spaces"]]


def saved():
    return [item["name"] for item in json.load(open(f"{sv.SUPPORT}/spaces.json"))]


try:
    t = sv.T()
    sv.setup(spaces=True)
    sv.launch()
    space(action="new", name="Two")
    time.sleep(0.6)
    t.ok("the two spaces start with the home first", names() == ["Personal", "Two"], names())

    space(action="go", index=1)
    space(action="move", index=2)
    time.sleep(0.4)
    t.ok("the home moves right", names() == ["Two", "Personal"], names())
    t.ok("the move reaches spaces.json", saved() == ["Two", "Personal"], saved())

    sv.cmd({"do": "space", "action": "go", "index": 2})
    sv.cmd({"do": "space", "action": "delete"})
    time.sleep(0.4)
    t.ok("the moved home cannot be deleted",
         names() == ["Two", "Personal"], names())

    # Browser.init reads Spaces.read(profile:) afresh; a notification caused
    # by another window must not put the home back at the left.
    space(action="new", name="Three")
    time.sleep(0.6)
    t.ok("a new space follows the chosen order at the end",
         names() == ["Two", "Personal", "Three"], names())
    sv.cmd({"do": "windows", "action": "new"})
    time.sleep(0.8)
    t.ok("another window reads the chosen order",
         sv.cmd({"do": "windows"})["windows"][1]["spaces"] == ["Two", "Personal", "Three"],
         sv.cmd({"do": "windows"})["windows"])

    sv.quit()
    time.sleep(1)
    sv.launch()
    time.sleep(1)
    t.ok("a relaunch keeps the chosen order",
         names() == ["Two", "Personal", "Three"], names())
    t.ok("with spaces on, the last space is restored",
         space()["current"] == "Three", space())
    sv.cmd({"do": "ui", "spaces": False})
    time.sleep(0.5)
    sv.quit()
    time.sleep(1)
    sv.launch()
    time.sleep(1)
    t.ok("with spaces off, the relaunch is the home space",
         space()["current"] == "Personal", space())
finally:
    t.done()
    sv.finish()
sys.exit(1 if t.failed else 0)
